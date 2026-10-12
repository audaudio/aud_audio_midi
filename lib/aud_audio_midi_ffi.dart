// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The native side of the MIDI bridge on top of `aud_audio_midi.dart`: the
/// registration of the port nodes with an engine and the tap adapter that
/// carries the MIDI of a port into an event source of the graph.
library;

export 'aud_audio_midi.dart';
export 'src/aud_audio_midi_ffi.dart';
export 'src/aud_midi_adapter.dart';
