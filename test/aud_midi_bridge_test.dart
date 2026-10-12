// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';
import 'package:aud_midi/aud_midi.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// The fake of the running test; Midi.open hosts it in the test's isolate.
late FakeMidiBackend _fake;

MidiBackend _backend() => _fake;

typedef _TapC =
    Void Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32, Int64);
typedef _TapDart = void Function(Pointer<Void>, int, Pointer<Void>, int, int);

const _noteOn = 0x20903C64; // group 0, channel 0, note 60, velocity 100
const _noteOff = 0x20803C00;

AudEngineFfi openEngine({
  AudGraphOptions graphOptions = const AudGraphOptions(),
}) => AudEngineFfi(
  config: AudEngineConfig(
    backend: AudIoBackend.nullDevice,
    outputChannels: 1,
    maxFrames: 256,
    manualClock: true,
    graphOptions: graphOptions,
  ),
  packages: [AudMidiBridge.package],
);

void main() {
  late AudEngineFfi engine;
  late Midi midi;
  late MidiPortInfo keys;
  late MidiPortInfo synth;
  var host = 0;

  setUp(() async {
    _fake = FakeMidiBackend();
    keys = _fake.addPort(
      _fake.portInfo(
        'keys',
        direction: MidiDirection.input,
        name: 'Keys',
        serialNumber: 'K1',
      ),
    );
    synth = _fake.addPort(
      _fake.portInfo(
        'synth',
        direction: MidiDirection.output,
        name: 'Synth',
        protocol: MidiProtocol.midi2,
        capabilities: const MidiPortCapabilities(
          scheduledSend: true,
          cancelPending: true,
          ump: true,
        ),
      ),
    );
    midi = await Midi.open(
      options: const MidiOptions(backend: _backend, inIsolate: true),
    );
    engine = openEngine();
    host = AudClock.nowNs();
  });

  tearDown(() async {
    engine.dispose();
    await midi.close();
  });

  /// Renders [blocks] blocks of 256 frames on the manual clock and takes
  /// the notifications.
  Future<void> play(int blocks) async {
    for (var i = 0; i < blocks; i++) {
      engine.stream.debugProcess(frames: 256, hostTimeNs: host);
      host += (256 * 1e9 / engine.format.sampleRate).round();
    }
    engine.pump();
    await pumpEventQueue();
  }

  /// Renders until the timeline passes [hostNs] by two blocks.
  Future<void> playPast(int hostNs) async {
    final block = (256 * 1e9 / engine.format.sampleRate).round();
    await play(((hostNs - host) / block).ceil().clamp(0, 1000) + 2);
  }

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Starts the engine and renders its first block, so its timing holds.
  Future<AudMidiBridge> start({
    AudMidiBridgeOptions options = const AudMidiBridgeOptions(),
  }) async {
    engine.start();
    await play(1);
    return AudMidiBridge(engine, midi, options: options);
  }

  /// Loops [input] into an output on the fake's synth port.
  Future<AudMidiOutput> loop(AudMidiBridge bridge, AudMidiInput input) async {
    final output = await bridge.openOutput(synth);
    engine.graph.transaction((tx) => tx.connectEvents(input.node, output.node));
    return output;
  }

  List<int> sentWords() => [
    for (final sent in _fake.sent)
      if (sent.packet case MidiUmpPacket(:final words)) ...words,
  ];

  void callTap(MidiNativeTap tap, int kind, List<int> data, int hostNs) {
    final function = Pointer<NativeFunction<_TapC>>.fromAddress(
      tap.function,
    ).asFunction<_TapDart>();
    final words = calloc<Uint32>(data.isEmpty ? 1 : data.length);
    for (var i = 0; i < data.length; i++) {
      words[i] = data[i];
    }
    function(
      Pointer.fromAddress(tap.user),
      kind,
      words.cast(),
      data.length,
      hostNs,
    );
    calloc.free(words);
  }

  group('AudMidiBridge', () {
    test('lists the ports and opens an input on the native path', () async {
      final bridge = await start();
      expect(bridge.name, 'aud_audio_midi');
      expect(engine.extensions, [bridge]);
      expect(bridge.inputPorts.map((p) => p.id), [keys.id]);
      expect(bridge.outputPorts.map((p) => p.id), [synth.id]);
      final input = await bridge.openInput(keys);
      expect(bridge.inputs, [input]);
      expect(input.path, AudMidiPath.native);
      expect(input.isWaiting, isFalse);
      expect(input.timing, AudSourceTiming.fixed);
      expect(input.port.id, keys.id);
      expect(input.source.latencyNs, bridge.fixedLatencyNs);
      expect(input.node.name, 'midi_in_keys');
      expect(engine.graph.stringsOf(input.node), {
        AudMidiPortNode.portId: keys.id.value,
        AudMidiPortNode.portFingerprint: keys.fingerprint,
      });
      final tap = _fake.taps[keys.id]!;
      expect(tap.function, AudMidiAdapter.tapFunction);
      expect(() => bridge.openInput(synth), throwsArgumentError);
      expect(() => bridge.openOutput(keys), throwsArgumentError);
    });

    test('plays native UMP at its timestamp plus C, to the frame', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys);
      final output = await loop(bridge, input);
      final tap = _fake.taps[keys.id]!;
      final at = host + 2000000;
      callTap(tap, 1, [_noteOn], at);
      final target = at + input.source.latencyNs;
      await playPast(target);
      await waitFor(() => _fake.sent.isNotEmpty);
      expect(sentWords(), [_noteOn]);
      final sentAt = bridge.clock.toEngineNs(_fake.sent.single.packet.time);
      expect((sentAt - target).abs(), lessThan(30000));
      expect(output.sent, 1);
      expect(output.heldNotes, hasLength(1));
      final stats = input.stats;
      expect(stats.path, AudMidiPath.native);
      expect(stats.source.delivered, 1);
      expect(stats.source.late, 0);
      expect(stats.adapter!.pushed, 1);
      expect(stats.recentLatencyNs, isNotNull);
      expect(input.stats.recentLatencyNs, isNull);
      expect(stats.toJson()['path'], 'native');
    });

    test('feeds bytes on the Dart path with the MIDI time mapped', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys, path: AudMidiPath.dart);
      expect(input.path, AudMidiPath.dart);
      expect(_fake.taps, isEmpty);
      await loop(bridge, input);
      await waitFor(() => _fake.calls.contains('openPort ${keys.id}'));
      final time = const MidiSystemClock().now();
      _fake.inject(
        keys.id,
        MidiBytesPacket(bytes: MidiBytes([0x90, 60, 100]), time: time),
      );
      _fake.inject(
        keys.id,
        MidiUmpPacket(words: Uint32List.fromList([_noteOff]), time: time),
      );
      await waitFor(() => input.source.stats.pushed == 2);
      await playPast(bridge.clock.toEngineNs(time) + input.source.latencyNs);
      await waitFor(() => _fake.sent.length == 2);
      expect(sentWords(), [_noteOn, _noteOff]);
    });

    test('immediate plays at the block that drains it', () async {
      final bridge = await start();
      final input = await bridge.openInput(
        keys,
        timing: AudSourceTiming.immediate,
      );
      expect(input.source.latencyNs, 0);
      await loop(bridge, input);
      final blockStart = host;
      callTap(_fake.taps[keys.id]!, 1, [_noteOn], host - 100000000);
      await play(1);
      await waitFor(() => _fake.sent.isNotEmpty);
      final sentAt = bridge.clock.toEngineNs(_fake.sent.single.packet.time);
      final outputAt = engine.timing.hostTimeAt(engine.timing.samplePosition);
      expect((sentAt - outputAt).abs(), lessThan(30000));
      expect(sentAt, greaterThanOrEqualTo(blockStart - 30000));
    });

    test('falls back to the Dart path when the tap is refused', () async {
      final bridge = await start();
      _fake.failWith(attachNativeTap: const MidiUnsupported('no taps'));
      final input = await bridge.openInput(keys);
      expect(input.path, AudMidiPath.dart);
      await input.close();
      await expectLater(
        bridge.openInput(keys, path: AudMidiPath.native),
        throwsA(isA<MidiUnsupported>()),
      );
    });

    test('releases a held note when its port goes', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys);
      await loop(bridge, input);
      callTap(_fake.taps[keys.id]!, 1, [_noteOn], host);
      await playPast(host + input.source.latencyNs);
      await waitFor(() => _fake.sent.length == 1);
      _fake.removePort(keys.id);
      await waitFor(() => input.isWaiting);
      await play(2);
      await waitFor(() => _fake.sent.length >= 2);
      // The graph closes the note with velocity 64.
      expect(
        sentWords().skip(1).map((w) => w & 0xFFFFFF00),
        contains(_noteOff),
      );
      expect(input.stats.path, isNull);
      expect(input.stats.adapter, isNull);
    });

    test('rebinds a re-plugged port by its fingerprint (ports-001)', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys);
      _fake.removePort(keys.id);
      await waitFor(() => input.isWaiting);
      final replugged = _fake.addPort(
        _fake.portInfo(
          'keys-2',
          direction: MidiDirection.input,
          name: 'Keys',
          serialNumber: 'K1',
        ),
      );
      await waitFor(() => !input.isWaiting);
      expect(input.port.id, replugged.id);
      expect(_fake.taps.keys, [replugged.id]);
      expect(
        engine.graph.stringsOf(input.node)[AudMidiPortNode.portId],
        replugged.id.value,
      );
    });

    test('a port that returns under its id plays again', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys, path: AudMidiPath.dart);
      _fake.addPort(keys.copyWith(state: MidiPortState.offline));
      await waitFor(() => input.isWaiting);
      _fake.addPort(keys.copyWith(state: MidiPortState.connected));
      await waitFor(() => !input.isWaiting);
      expect(input.path, AudMidiPath.dart);
    });

    test('retargets, changes the timing and closes', () async {
      final bridge = await start();
      final other = _fake.addPort(
        _fake.portInfo('pads', direction: MidiDirection.input, name: 'Pads'),
      );
      final input = await bridge.openInput(keys);
      await input.retarget(other);
      expect(input.port.id, other.id);
      expect(_fake.taps.keys, [other.id]);
      await input.setTiming(AudSourceTiming.immediate);
      await input.setTiming(AudSourceTiming.immediate);
      expect(input.timing, AudSourceTiming.immediate);
      expect(input.source.timing, AudSourceTiming.immediate);
      await input.close();
      await input.close();
      expect(input.isClosed, isTrue);
      expect(bridge.inputs, isEmpty);
      expect(_fake.taps, isEmpty);
      expect(
        engine.graph.nodes.where((n) => n.typeId == AudMidiInputNode.typeId),
        isEmpty,
      );
    });

    test('keeps the latency of the engine', () async {
      final bridge = await start(
        options: const AudMidiBridgeOptions(marginNs: 2000000),
      );
      final input = await bridge.openInput(keys);
      final immediate = await bridge.openInput(
        keys.copyWith(),
        node: engine.graph.createNode(AudMidiInputNode.typeId),
        timing: AudSourceTiming.immediate,
        path: AudMidiPath.dart,
      );
      input.source.latencyNs = 1;
      bridge.refresh();
      expect(input.source.latencyNs, bridge.fixedLatencyNs);
      final raised = input.source.latencyNs + 5000000;
      input.source.latencyNs = raised;
      bridge.refresh();
      expect(input.source.latencyNs, raised);
      bridge.engineTimingChanged(engine);
      expect(input.source.latencyNs, bridge.fixedLatencyNs);
      expect(immediate.source.latencyNs, 0);
    });

    test('a fixed latency before the first block comes from the format', () {
      final bridge = AudMidiBridge(engine, midi);
      final format = engine.format;
      expect(
        bridge.fixedLatencyNs,
        (format.bufferFrames * 1e9 / format.sampleRate).round() + 1000000,
      );
    });

    test('refreshes while the engine runs', () async {
      final bridge = AudMidiBridge(
        engine,
        midi,
        options: const AudMidiBridgeOptions(
          refreshInterval: Duration(milliseconds: 5),
        ),
      );
      engine.start();
      await play(1);
      final input = await bridge.openInput(keys);
      input.source.latencyNs = 1;
      await waitFor(() => input.source.latencyNs > 1);
      engine.stop();
      input.source.latencyNs = 1;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(input.source.latencyNs, 1);
      final running = AudMidiBridge(engine, midi);
      engine.start();
      await running.close();
    });

    test('outputs release their notes when notifications drop', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys);
      final output = await loop(bridge, input);
      callTap(_fake.taps[keys.id]!, 1, [_noteOn], host);
      await playPast(host + input.source.latencyNs);
      await waitFor(() => output.heldNotes.isNotEmpty);
      // Nothing dropped yet: the note stays.
      bridge.refresh();
      expect(output.heldNotes, hasLength(1));
      output.releaseNotes();
      await waitFor(() => sentWords().contains(_noteOff));
      expect(output.heldNotes, isEmpty);
    });

    test(
      'outputs track MIDI 2.0 notes and drop events of a gone port',
      () async {
        final bridge = await start();
        final input = await bridge.openInput(keys);
        final output = await loop(bridge, input);
        final tap = _fake.taps[keys.id]!;
        // A MIDI 2.0 note on and off, and a controller that is no note.
        callTap(tap, 1, [0x40903C00, 0x80000000], host);
        callTap(tap, 1, [0x40B00700, 0x10000000], host);
        await playPast(host + input.source.latencyNs);
        await waitFor(() => output.sent == 2);
        expect(output.heldNotes, hasLength(1));
        callTap(tap, 1, [0x40803C00, 0x00000000], host);
        await playPast(host + input.source.latencyNs);
        await waitFor(() => output.sent == 3);
        expect(output.heldNotes, isEmpty);
        _fake.addPort(synth.copyWith(state: MidiPortState.offline));
        await waitFor(() => output.isWaiting);
        callTap(tap, 1, [_noteOn], host);
        await playPast(host + input.source.latencyNs);
        expect(output.sent, 3);
        final again = _fake.addPort(
          _fake.portInfo(
            'synth-2',
            direction: MidiDirection.output,
            name: 'Synth',
            protocol: MidiProtocol.midi2,
          ),
        );
        _fake.removePort(synth.id);
        await waitFor(() => output.port.id == again.id);
        expect(
          engine.graph.stringsOf(output.node)[AudMidiPortNode.portId],
          again.id.value,
        );
      },
    );

    test('names the nodes after the ports, uniquely', () async {
      final bridge = await start();
      final spaced = _fake.addPort(
        _fake.portInfo(
          'x',
          direction: MidiDirection.input,
          name: ' Loop  out!',
        ),
      );
      final blank = _fake.addPort(
        _fake.portInfo('y', direction: MidiDirection.input, name: '***'),
      );
      final a = await bridge.openInput(spaced, path: AudMidiPath.dart);
      final b = await bridge.openInput(spaced, path: AudMidiPath.dart);
      final c = await bridge.openInput(blank, path: AudMidiPath.dart);
      final out = await bridge.openOutput(synth);
      expect(a.node.name, 'midi_in_loop_out');
      expect(b.node.name, 'midi_in_loop_out_2');
      expect(c.node.name, 'midi_in');
      expect(out.node.name, 'midi_out_synth');
    });

    test('an input on a port that is offline waits for it', () async {
      final bridge = await start();
      final offline = _fake.addPort(
        keys.copyWith(state: MidiPortState.offline),
      );
      await waitFor(() => bridge.inputPorts.single.state == offline.state);
      final input = await bridge.openInput(offline);
      expect(input.isWaiting, isTrue);
      expect(input.path, isNull);
      expect(_fake.taps, isEmpty);
    });

    test('a send that fails leaves the output working', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys);
      final output = await loop(bridge, input);
      _fake.failWith(send: MidiPortGone(synth.id));
      callTap(_fake.taps[keys.id]!, 1, [_noteOn], host);
      await playPast(host + input.source.latencyNs);
      await waitFor(() => output.sent == 1);
      await pumpEventQueue();
      _fake.failWith();
      callTap(_fake.taps[keys.id]!, 1, [_noteOff], host);
      await playPast(host + input.source.latencyNs);
      await waitFor(() => _fake.sent.isNotEmpty);
      expect(sentWords(), [_noteOff]);
    });

    test('dropped notifications release the notes of the outputs', () async {
      engine.dispose();
      engine = openEngine(
        graphOptions: const AudGraphOptions(notificationCapacity: 4),
      );
      host = AudClock.nowNs();
      final bridge = await start();
      final input = await bridge.openInput(keys);
      final output = await loop(bridge, input);
      final tap = _fake.taps[keys.id]!;
      // A chord of 32 notes in one block: more than the ring holds.
      for (var note = 40; note < 72; note++) {
        callTap(tap, 1, [0x20900064 | note << 8], host);
      }
      await playPast(host + input.source.latencyNs);
      expect(engine.stats.notificationsDropped, greaterThan(0));
      await waitFor(() => output.heldNotes.isNotEmpty);
      bridge.refresh();
      expect(output.heldNotes, isEmpty);
      bridge.refresh();
    });

    test('closes and leaves the engine; closed refuses', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys);
      final output = await loop(bridge, input);
      await bridge.close();
      await bridge.close();
      expect(bridge.isClosed, isTrue);
      expect(engine.extensions, isEmpty);
      expect(input.isClosed, isTrue);
      expect(bridge.outputs, isEmpty);
      expect(output.heldNotes, isEmpty);
      expect(() => bridge.openInput(keys), throwsStateError);
    });

    test('the engine closes the bridge before it disposes the graph', () async {
      final bridge = await start();
      final input = await bridge.openInput(keys);
      final dart = await bridge.openInput(
        keys.copyWith(),
        node: engine.graph.createNode(AudMidiInputNode.typeId),
        path: AudMidiPath.dart,
      );
      final tap = _fake.taps[keys.id]!;
      engine.dispose();
      expect(bridge.isClosed, isTrue);
      expect(input.isClosed, isTrue);
      expect(dart.isClosed, isTrue);
      // The closed adapter takes calls until the tap detached.
      callTap(tap, 1, [_noteOn], host);
      await waitFor(() => _fake.taps.isEmpty);
    });

    test('the engine closes a bridge whose detach fails', () async {
      final bridge = await start();
      await bridge.openInput(keys);
      _fake.failWith(detachNativeTap: StateError('gone'));
      engine.dispose();
      await pumpEventQueue();
      expect(bridge.isClosed, isTrue);
    });
  });
}
