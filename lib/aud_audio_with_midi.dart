// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The MIDI bridge of the Audanika Audio Engine, platform-neutral: the ids
/// of the port nodes `aud.midi.input` and `aud.midi.output`, their ports,
/// parameters and string keys. Imports no `dart:ffi`, so it compiles for
/// the web (web-001); `aud_audio_with_midi_ffi.dart` registers the nodes with a
/// native engine and drives the tap adapter.
library;

export 'src/aud_audio_with_midi_version.dart';
export 'src/aud_midi_nodes.dart';
