// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.
// Measures the paths from a MIDI port to the audio thread (ticket 26, step
// 5; the rule of scope 4 of its plan decides midi-002):
//
//   flutter test integration_test/midi_paths_test.dart -d <device> \
//     --dart-define=AUD_MARGIN_SECONDS=60 \
//     --dart-define=AUD_MEASURE_SECONDS=600
//
// The same events of a source of the app reach three event sources at
// once, each with an `aud.midi.input` node of its own; only the native one
// plays the sampler:
//
// - native: the backend's tap on its receive thread (native-001);
// - dart-1: Dart in an isolate that hosts a MIDI engine of its own and
//   pushes what it receives (one hop through Dart);
// - dart-2: the bridge's Dart path in the app's isolate, behind aud_midi's
//   MIDI isolate (two hops, today's API).
//
// First, for AUD_MARGIN_SECONDS, the native path runs without the margin
// m: its late events and its delivery delay give m. Then all three run for
// AUD_MEASURE_SECONDS with m = 1 ms while the page animates and the app's
// isolate allocates garbage. Printed per path: the delivery delay (push
// time minus the event's timestamp), the late share and the drops.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_audio_with_midi_example/main.dart';
import 'package:aud_audio_with_midi_example/midi_page.dart';
import 'package:aud_audio_with_midi/aud_audio_with_midi_ffi.dart';
import 'package:aud_midi/aud_midi.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'midi_support.dart';

const _marginSeconds = int.fromEnvironment(
  'AUD_MARGIN_SECONDS',
  defaultValue: 5,
);
const _seconds = int.fromEnvironment('AUD_MEASURE_SECONDS', defaultValue: 5);

typedef _TapC = Void Function(
  Pointer<Void>,
  Uint32,
  Pointer<Void>,
  Uint32,
  Int64,
);
typedef _TapDart = void Function(Pointer<Void>, int, Pointer<Void>, int, int);

/// What the isolate of the one-hop path needs.
typedef _OneHop = ({SendPort ready, String port, int tap, int adapter});

/// The isolate of the one-hop path: a MIDI engine of its own, in this
/// isolate, whose packets go straight into the adapter of the source.
Future<void> _oneHop(_OneHop args) async {
  final commands = ReceivePort();
  final midi = await Midi.open(options: const MidiOptions(inIsolate: true));
  final clock = AudMidiClock();
  final tap = Pointer<NativeFunction<_TapC>>.fromAddress(args.tap)
      .asFunction<_TapDart>();
  final user = Pointer<Void>.fromAddress(args.adapter);
  final buffer = calloc<Uint8>(4096);
  StreamSubscription<MidiPacket>? packets;
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (packets == null && DateTime.now().isBefore(end)) {
    for (final input in midi.inputs) {
      if (input.info.name != args.port) continue;
      packets = input.packets.listen((packet) {
        final time = clock.toEngineNs(packet.time);
        switch (packet) {
          case MidiUmpPacket(:final words):
            final w = buffer.cast<Uint32>();
            for (var i = 0; i < words.length; i++) {
              w[i] = words[i];
            }
            tap(user, 1, buffer.cast(), words.length, time);
          case MidiBytesPacket(:final bytes):
            final b = bytes.bytes;
            for (var i = 0; i < b.length; i++) {
              buffer[i] = b[i];
            }
            tap(user, 2, buffer.cast(), b.length, time);
        }
      });
    }
    if (packets == null) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  args.ready.send(packets == null ? null : commands.sendPort);
  if (packets == null) {
    commands.close();
    await midi.close();
    calloc.free(buffer);
    return;
  }
  await commands.first;
  await packets.cancel();
  await midi.close();
  calloc.free(buffer);
  commands.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  // Pumps the animated page for [seconds]; with [garbage] the app's
  // isolate allocates about 8 MB per frame, so the collector runs.
  Future<void> animate(
    WidgetTester tester,
    int seconds, {
    bool garbage = false,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    var sink = 0;
    while (DateTime.now().isBefore(end)) {
      if (garbage) {
        for (var i = 0; i < 8; i++) {
          sink += List<int>.filled(128 * 1024, i).length;
        }
      }
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    expect(sink, greaterThanOrEqualTo(0));
  }

  testWidgets('measures the native and the Dart paths (midi-002)', (
    tester,
  ) async {
    await tester.pumpWidget(const EngineApp());
    await tester.pump();
    final page = tester.state<MidiPageState>(find.byType(MidiPage));
    final engine = page.engine;
    await until(tester, () => page.bridge != null);
    final bridge = page.bridge!;
    final midi = page.midi!;
    final graph = engine.graph;

    final source = (await tester.runAsync(() => MidiTestSource.open(midi)))!;
    final input = midi.input(source.input.id)!;
    final clock = AudMidiClock();

    // Three sources with a node each, outside the bridge, so that all three
    // keep the same C; only the native one plays the sampler.
    var token = 0x26;
    ({AudEventSourceFfi source, AudMidiAdapter adapter, int token}) measured(
      String name,
    ) {
      final node = graph.createNode(AudMidiInputNode.typeId, name: name);
      graph.transaction((_) {});
      final created = graph.createEventSource(
        node,
        latencyNs: bridge.fixedLatencyNs,
        capacity: bridge.options.capacity,
      ) as AudEventSourceFfi;
      final producer = token++;
      created.attach(producer);
      return (
        token: producer,
        source: created,
        adapter: AudMidiAdapter(
          source: created.address,
          push: AudEventSourceFfi.pushFunctionAddress,
          release: AudEventSourceFfi.releaseFunctionAddress,
          size: AudEventSourceFfi.sizeFunctionAddress,
          capacity: created.capacity,
        ),
      );
    }

    final native = measured('native');
    graph.transaction(
      (tx) => tx.connectEvents(native.source.node, page.sampler!),
    );
    final tap = (await tester.runAsync(
      () => input.attachNativeTap(
        MidiNativeTap(
          function: AudMidiAdapter.tapFunction,
          user: native.adapter.address,
        ),
      ),
    ))!;
    final dart2 = measured('dart-2');
    final packets = input.packets.listen((packet) {
      final time = clock.toEngineNs(packet.time);
      switch (packet) {
        case MidiUmpPacket(:final words):
          dart2.adapter.pushUmp(words, hostTimeNs: time);
        case MidiBytesPacket(:final bytes):
          dart2.adapter.pushBytes(bytes.bytes, hostTimeNs: time);
      }
    });
    final dart1 = measured('dart-1');
    final ready = ReceivePort();
    await tester.runAsync(
      () => Isolate.spawn<_OneHop>(_oneHop, (
        ready: ready.sendPort,
        port: source.input.name,
        tap: AudMidiAdapter.tapFunction,
        adapter: dart1.adapter.address,
      )),
    );
    final oneHop = (await tester.runAsync(() => ready.first)) as SendPort?;
    final sources = <String, AudEventSource>{
      'native': native.source,
      'dart-1': dart1.source,
      'dart-2': dart2.source,
    };

    engine.start();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    final timing = engine.timing;
    final withoutMargin = bridge.baseLatencyNs;

    // A: the native path without the margin.
    for (final s in sources.values) {
      s.latencyNs = withoutMargin;
    }
    final stopA = Completer<void>();
    final playingA = MidiPerformance(source).play(stopA.future);
    final beforeA = native.source.stats;
    await animate(tester, _marginSeconds);
    final windowA = SourceWindow(beforeA, native.source.stats);
    stopA.complete();
    await tester.runAsync(() => playingA);

    // B: all three paths with m = 1 ms, under load.
    final latency = bridge.fixedLatencyNs;
    for (final s in sources.values) {
      s.latencyNs = latency;
    }
    final before = {
      for (final MapEntry(:key, :value) in sources.entries) key: value.stats,
    };
    final numbersBefore = engine.numbers;
    final stopB = Completer<void>();
    final playingB = MidiPerformance(source).play(stopB.future);
    await animate(tester, _seconds, garbage: true);
    stopB.complete();
    await tester.runAsync(() => playingB);
    final numbers = engine.numbers;
    final windows = {
      for (final MapEntry(:key, :value) in sources.entries)
        key: SourceWindow(before[key]!, value.stats),
    };

    // The rule of scope 4: the native tap becomes the default when a Dart
    // path's p99 delay exceeds m or its late share 0.1 %.
    const marginNs = 1000000;
    final dartMisses = [
      for (final name in const ['dart-1', 'dart-2'])
        if (windows[name]!.delivered > 0 &&
            ((windows[name]!.delayNs(0.99) ?? 0) > marginNs ||
                windows[name]!.lateShare > 0.001))
          name,
    ];
    final report = {
      'platform': timing.toJson(),
      'format': {
        'sampleRate': engine.format.sampleRate,
        'bufferFrames': engine.format.bufferFrames,
        'burstFrames': engine.format.burstFrames,
        'maxFrames': engine.format.maxFrames,
      },
      'fixedLatencyMsNow': page.bridge!.fixedLatencyNs / 1e6,
      'blockMs': timing.maxPeriodNs / 1e6,
      'outputLatencyMs': timing.outputLatencyNs / 1e6,
      'withoutMarginMs': withoutMargin / 1e6,
      'periodMs': bridge.periodNs / 1e6,
      'latencyMs': latency / 1e6,
      'marginRun': windowA.toJson(),
      'oneHopRunning': oneHop != null,
      'paths': {
        for (final MapEntry(:key, :value) in windows.entries)
          key: value.toJson(),
      },
      'dartPathsMissing': dartMisses,
      'decision': dartMisses.isEmpty ? 'dart' : 'native',
      'xruns': numbers.xruns - numbersBefore.xruns,
      'lateCallbacks': numbers.lateCallbacks - numbersBefore.lateCallbacks,
      'marginSeconds': _marginSeconds,
      'seconds': _seconds,
    };
    print('MIDI paths report: ${jsonEncode(report)}');

    oneHop?.send('stop');
    await tester.runAsync(() async {
      await tap.detach();
      await packets.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await source.close();
    });
    // The producers stopped: the tap detached, the stream and the isolate
    // ended; then each source lets its producer go.
    for (final m in [native, dart1, dart2]) {
      m.adapter.dispose();
      m.source
        ..detach(m.token)
        ..dispose();
    }
    expect(windows['native']!.delivered, greaterThan(0));
  });
}
