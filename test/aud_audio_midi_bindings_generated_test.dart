// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_midi/src/aud_audio_midi_bindings_generated.dart'
    as bindings;
import 'package:test/test.dart';

void main() {
  group('aud_audio_midi_bindings_generated.dart', () {
    test('aud_audio_midi_register refuses a null host', () {
      expect(
        bindings.aud_audio_midi_register(nullptr),
        AUD_ERROR_INVALID_ARGUMENT,
      );
    });

    test('the adapter functions take a null adapter', () {
      expect(bindings.aud_audio_midi_adapter_create(nullptr), nullptr);
      bindings.aud_audio_midi_adapter_close(nullptr);
      bindings.aud_audio_midi_adapter_destroy(nullptr);
      bindings.aud_audio_midi_tap(
        nullptr,
        bindings.AUD_MIDI_TAP_GONE,
        nullptr,
        0,
        1,
      );
      expect(
        bindings.aud_audio_midi_adapter_stats(nullptr, nullptr),
        AUD_ERROR_INVALID_ARGUMENT,
      );
    });

    test('carries the ids of the header', () {
      expect(bindings.AUD_MIDI_INPUT_TYPE_ID, 'aud.midi.input');
      expect(bindings.AUD_MIDI_OUTPUT_TYPE_ID, 'aud.midi.output');
      expect(bindings.AUD_MIDI_KEY_PORT_ID, 0);
      expect(bindings.AUD_MIDI_KEY_PORT_FINGERPRINT, 1);
      expect(bindings.AUD_MIDI_OUTPUT_PARAM_SYSEX, 0);
      expect(bindings.AUD_MIDI_TAP_UMP, 1);
      expect(bindings.AUD_MIDI_TAP_BYTES, 2);
      expect(bindings.AUD_MIDI_TAP_GONE, 3);
    });
  });
}
