// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Compiled to JavaScript by test/web/web_compile_test.dart: the
// platform-neutral library must not reach dart:ffi.

// ignore_for_file: avoid_print

import 'package:aud_audio_with_midi/aud_audio_with_midi.dart';

void main() {
  print(
    '${AudMidiInputNode.typeId} ${AudMidiOutputNode.typeId} '
    '${AudMidiPortNode.portId} $audAudioMidiVersion',
  );
}
