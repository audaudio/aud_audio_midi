// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_core/aud_audio_core_bindings.dart' as core;
import 'package:aud_audio_graph/aud_audio_graph_ffi.dart';
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  // A graph of the engine with the bridge registered, disposed at the end
  // of the test. The notifications wait for a pump.
  AudGraphFfi bridgeGraph() {
    final graph = AudGraphFfi(listen: false, maxFrames: 256);
    addTearDown(graph.dispose);
    AudAudioMidi.registerWith(graph.hostApi);
    return graph;
  }

  AudUmpEvent ump(List<int> words, {int sampleOffset = 0}) =>
      AudUmpEvent(Ump(words), sampleOffset: sampleOffset);

  AudUmpEvent noteOn(int note) => ump([0x20900000 | (note << 8) | 100]);

  // A SysEx7 complete packet of two bytes, and a SysEx8 start packet.
  final sysex7 = ump([0x30020102, 0]);
  final sysex8 = ump([0x51030102, 0x03000000, 0, 0]);

  // Renders a block offline and returns the events that reached the
  // graph's event input, by the handle of the node that emitted them.
  List<(int, AudEvent)> renderAndCollect(AudGraphFfi graph) {
    final received = <AudGraphNotification>[];
    final subscription = graph.notifications.listen(received.add);
    addTearDown(subscription.cancel);
    AudOfflineRenderer(graph).render(frames: 256);
    graph.pump();
    return [
      for (final n in received.whereType<AudEventNotification>())
        (n.node, n.event),
    ];
  }

  group('AudAudioMidi', () {
    test('registers both node types with an engine once', () {
      final graph = bridgeGraph();
      final input = graph.nodeType(AudMidiInputNode.typeId)!;
      final output = graph.nodeType(AudMidiOutputNode.typeId)!;
      for (final descriptor in [input, output]) {
        expect(descriptor.abiMajor, AudAbi.major);
        expect(descriptor.abiMinor, AudAbi.minor);
        expect(descriptor.inputBuses, isEmpty);
        expect(descriptor.outputBuses, isEmpty);
        expect(descriptor.eventInputs.single.id, AudMidiPortNode.inlet);
        expect(descriptor.eventOutputs.single.id, AudMidiPortNode.outlet);
        expect(
          [for (final key in descriptor.stringKeys) key.id],
          [AudMidiPortNode.portId, AudMidiPortNode.portFingerprint],
        );
        expect(descriptor.capabilities.events, isTrue);
        expect(descriptor.capabilities.eventOutput, isTrue);
        expect(descriptor.capabilities.strings, isTrue);
        expect(descriptor.capabilities.passesEvents, isTrue);
      }
      expect(input.params, isEmpty);
      expect(output.params.single.id, AudMidiOutputNode.sysex);
      expect(output.params.single.boolean, isTrue);
      expect(
        () => AudAudioMidi.registerWith(graph.hostApi),
        throwsA(
          isA<AudAudioMidiException>()
              .having((e) => e.code, 'code', AUD_ERROR_DUPLICATE_TYPE)
              .having(
                (e) => e.toString(),
                'text',
                'AudAudioMidiException: registration failed with '
                    'AUD_ERROR_DUPLICATE_TYPE',
              ),
        ),
      );
    });

    test('hands its register function to an engine', () {
      final graph = AudGraphFfi(listen: false, maxFrames: 256);
      addTearDown(graph.dispose);
      expect(AudAudioMidi.name, 'aud_audio_midi');
      final register = AudAudioMidi.register
          .asFunction<int Function(Pointer<core.AudHostApi>)>();
      expect(register(graph.hostApi), AUD_OK);
      expect(graph.nodeType(AudMidiInputNode.typeId), isNotNull);
      expect(graph.nodeType(AudMidiOutputNode.typeId), isNotNull);
      expect(register(nullptr), AUD_ERROR_INVALID_ARGUMENT);
    });
  });

  group('aud.midi.input and aud.midi.output', () {
    test('pass events through at their offset', () {
      final graph = bridgeGraph();
      final input = graph.createNode(AudMidiInputNode.typeId, name: 'keys');
      final output = graph.createNode(AudMidiOutputNode.typeId, name: 'thru');
      graph.transaction((tx) {
        tx.connectEvents(input, output);
        tx.connectEvents(output, graph.io);
      });
      graph.start();
      renderAndCollect(graph);
      final position = graph.samplePosition;
      graph.sendEvent(input, noteOn(60));
      graph.sendEvent(
        input,
        noteOn(62),
        at: AudTimestamp.sample(position + 100),
      );
      graph.sendEvent(
        input,
        AudControlEvent(control: 7, value: 0.5),
        at: AudTimestamp.sample(position + 200),
      );
      final events = renderAndCollect(graph);
      expect(events, [
        (output.handle, noteOn(60)),
        (output.handle, ump([0x20903E64], sampleOffset: 100)),
        (
          output.handle,
          AudControlEvent(control: 7, value: 0.5, sampleOffset: 200),
        ),
      ]);
    });

    test('drop SysEx at the output unless the parameter is on', () {
      final graph = bridgeGraph();
      final input = graph.createNode(AudMidiInputNode.typeId);
      final output = graph.createNode(AudMidiOutputNode.typeId);
      graph.transaction((tx) {
        tx.connectEvents(input, output);
        tx.connectEvents(input, graph.io);
        tx.connectEvents(output, graph.io);
      });
      graph.start();
      renderAndCollect(graph);
      graph.sendEvent(input, sysex7);
      graph.sendEvent(input, sysex8);
      graph.sendEvent(input, noteOn(60));
      expect(renderAndCollect(graph), [
        (input.handle, sysex7),
        (input.handle, sysex8),
        (input.handle, noteOn(60)),
        (output.handle, noteOn(60)),
      ]);
      graph.setParam(output, AudMidiOutputNode.sysex, 1);
      graph.sendEvent(input, sysex7);
      expect(renderAndCollect(graph), [
        (input.handle, sysex7),
        (output.handle, sysex7),
      ]);
      graph.setParam(output, AudMidiOutputNode.sysex, 0);
      graph.sendEvent(input, sysex8);
      expect(renderAndCollect(graph), [(input.handle, sysex8)]);
    });

    test('keep the port id and the fingerprint in the document', () {
      final graph = bridgeGraph();
      final input = graph.createNode(AudMidiInputNode.typeId, name: 'keys');
      final output = graph.createNode(AudMidiOutputNode.typeId, name: 'synth');
      graph.setString(input, AudMidiPortNode.portId, 'coremidi:12345');
      graph.setString(
        input,
        AudMidiPortNode.portFingerprint,
        'Acme|Keys|SN1|input|0',
      );
      graph.setString(output, AudMidiPortNode.portId, 'android:3:out:0');
      expect(graph.stringsOf(input), {
        'port_id': 'coremidi:12345',
        'port_fingerprint': 'Acme|Keys|SN1|input|0',
      });
      expect(graph.stringsOf(output), {'port_id': 'android:3:out:0'});
      final document = graph.toDocument();
      final keys = document.nodes.singleWhere((n) => n.id == 'keys');
      expect(keys.preset?.strings, {
        'port_id': 'coremidi:12345',
        'port_fingerprint': 'Acme|Keys|SN1|input|0',
      });
      // A graph restored from the document carries the strings again.
      final restored = AudGraphFfi(listen: false, maxFrames: 256);
      addTearDown(restored.dispose);
      AudAudioMidi.registerWith(restored.hostApi);
      final nodes = restored.load(document);
      expect(restored.stringsOf(nodes['keys']!), {
        'port_id': 'coremidi:12345',
        'port_fingerprint': 'Acme|Keys|SN1|input|0',
      });
    });
  });
}
