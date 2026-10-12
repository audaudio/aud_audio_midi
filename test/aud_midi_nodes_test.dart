// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_midi/aud_audio_midi.dart';
import 'package:test/test.dart';

void main() {
  group('AudMidiPortNode', () {
    test('names the ports and the string keys', () {
      expect(AudMidiPortNode.inlet, 'in');
      expect(AudMidiPortNode.outlet, 'out');
      expect(AudMidiPortNode.portId, 'port_id');
      expect(AudMidiPortNode.portFingerprint, 'port_fingerprint');
    });
  });

  group('AudMidiInputNode', () {
    test('names the type', () {
      expect(AudMidiInputNode.typeId, 'aud.midi.input');
    });
  });

  group('AudMidiOutputNode', () {
    test('names the type and the parameter', () {
      expect(AudMidiOutputNode.typeId, 'aud.midi.output');
      expect(AudMidiOutputNode.sysex, 'sysex');
    });
  });
}
