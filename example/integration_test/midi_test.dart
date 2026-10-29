// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.
// Runs the MIDI keyboard page (ticket 26) on a simulator, an emulator or a
// device and prints the numbers of S8's budgets (ticket 17, Verification;
// the plan of ticket 26, Budgets):
//
//   flutter test integration_test/midi_test.dart -d <device> \
//     --dart-define=AUD_WARMUP_SECONDS=1200 \
//     --dart-define=AUD_MEASURE_SECONDS=600
//
// A source of the app plays a recorded keyboard performance - chords, the
// sustain pedal, fast repeats - into the page's input, which plays the
// sampler (on iOS a CoreMIDI source of the app, on Android the loopback
// device of aud_midi_android), first for AUD_WARMUP_SECONDS, then for the
// measured AUD_MEASURE_SECONDS with the page's animation running. With
// AUD_MIDI_PORT=<name> the input is the port of that name instead - a real
// keyboard someone plays - and nothing is generated.
//
// Printed: the path (native or Dart), C of the fixed timing, the input to
// output time, the late events and the delivery delay of the measured
// part, the xruns and the late callbacks. AUD_ASSERT_BUDGETS=true turns
// the budgets into expectations.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:aud_audio_midi_example/main.dart';
import 'package:aud_audio_midi_example/midi_page.dart';
import 'package:aud_midi/aud_midi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'midi_support.dart';

const _warmUpSeconds = int.fromEnvironment('AUD_WARMUP_SECONDS');
const _seconds = int.fromEnvironment('AUD_MEASURE_SECONDS', defaultValue: 5);
const _port = String.fromEnvironment('AUD_MIDI_PORT');
const _assertBudgets = bool.fromEnvironment('AUD_ASSERT_BUDGETS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Pumps until [condition] holds, at most [seconds].
  Future<void> until(
    WidgetTester tester,
    bool Function() condition, {
    int seconds = 15,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  // Pumps the frames of the animated page for [seconds].
  Future<void> animate(WidgetTester tester, int seconds) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
  }

  testWidgets('a MIDI source plays the sampler at a fixed latency', (
    tester,
  ) async {
    await tester.pumpWidget(const EngineApp());
    await tester.pump();
    final page = tester.state<MidiPageState>(find.byType(MidiPage));
    final engine = page.engine;
    await until(tester, () => page.bridge != null);
    final midi = page.midi!;

    // The source and the input.
    MidiTestSource? source;
    final MidiPortInfo port;
    if (_port.isEmpty) {
      source = (await tester.runAsync(() => MidiTestSource.open(midi)))!;
      port = source.input;
    } else {
      await until(
        tester,
        () => page.bridge!.inputPorts.any((p) => p.name == _port),
        seconds: 60,
      );
      port = page.bridge!.inputPorts.firstWhere((p) => p.name == _port);
    }
    await tester.runAsync(() => page.pick(port));
    await tester.pump();
    expect(page.input, isNotNull, reason: page.error);
    final input = page.input!;
    expect(input.isWaiting, isFalse);
    engine.start();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    page.bridge!.refresh();

    // The performance plays through the warm-up and the measured part.
    final stop = Completer<void>();
    Future<void>? playing;
    if (source != null) {
      playing = MidiPerformance(source).play(stop.future);
    }
    if (_warmUpSeconds > 0) await animate(tester, _warmUpSeconds);
    page.bridge!.refresh();
    final before = input.source.stats;
    final numbersBefore = engine.numbers;
    await animate(tester, _seconds);
    final after = input.source.stats;
    final numbers = engine.numbers;
    stop.complete();
    await tester.runAsync(() async {
      await playing;
      await source?.close();
    });

    final window = SourceWindow(before, after);
    final timing = engine.timing;
    final report = {
      'port': port.name,
      'format': {
        'sampleRate': engine.format.sampleRate,
        'bufferFrames': engine.format.bufferFrames,
        'burstFrames': engine.format.burstFrames,
        'maxFrames': engine.format.maxFrames,
      },
      'fixedLatencyMsNow': page.bridge!.fixedLatencyNs / 1e6,
      'path': input.path?.name,
      'timing': input.timing.name,
      'latencyMs': input.source.latencyNs / 1e6,
      'marginMs': input.marginNs / 1e6,
      'periodMs': page.bridge!.periodNs / 1e6,
      'blockMs': timing.maxPeriodNs / 1e6,
      'nominalBlockMs': timing.nominalPeriodNs / 1e6,
      'outputLatencyMs': timing.outputLatencyNs / 1e6,
      'window': window.toJson(),
      'adapter': input.stats.adapter?.toJson(),
      'xruns': numbers.xruns - numbersBefore.xruns,
      'lateCallbacks': numbers.lateCallbacks - numbersBefore.lateCallbacks,
      'renderTimeMaxMs': numbers.renderTimeMaxNs / 1e6,
      'warmUpSeconds': _warmUpSeconds,
      'seconds': _seconds,
    };
    print('MIDI report: ${jsonEncode(report)}');

    expect(window.delivered, greaterThan(0));
    if (_assertBudgets) {
      expect(numbers.xruns - numbersBefore.xruns, 0);
      expect(window.lateShare, lessThanOrEqualTo(0.001));
      expect(window.delayNs(0.99), lessThanOrEqualTo(1000000));
    }
  });
}
