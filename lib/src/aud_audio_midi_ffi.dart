// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_core/aud_audio_core_bindings.dart' as core;

import 'aud_audio_midi_bindings_generated.dart' as bindings;

// #############################################################################
/// The native side of the package: the registration of the port nodes
/// `aud.midi.input` and `aud.midi.output` with an engine.
///
/// The umbrella's package list takes the register function:
///
/// ```dart
/// final engine = AudEngine(packages: [
///   AudNativeNodePackage(AudAudioMidi.name, AudAudioMidi.register),
/// ]);
/// ```
abstract final class AudAudioMidi {
  /// The name of the package, e.g. for an engine's package list.
  static const String name = 'aud_audio_midi';

  /// The register function of the package,
  /// `aud_audio_midi_register(const AudHostApi*)`, which an engine calls
  /// with its host api.
  static core.AudRegisterFunction get register =>
      Native.addressOf<NativeFunction<core.AudRegisterFunctionFunction>>(
        bindings.aud_audio_midi_register,
      );

  /// Registers the node types with the engine behind [host], e.g.
  /// `AudGraphFfi.hostApi`; throws an [AudAudioMidiException] when the
  /// engine refuses them.
  static void registerWith(Pointer<core.AudHostApi> host) {
    final result = bindings.aud_audio_midi_register(host);
    if (result != AUD_OK) throw AudAudioMidiException(code: result);
  }
}

// #############################################################################
/// Thrown when an engine refuses the node types of the package.
class AudAudioMidiException implements Exception {
  /// Creates the exception for a result [code].
  const AudAudioMidiException({required this.code});

  /// The result code, one of the `AUD_ERROR_*` constants.
  final int code;

  @override
  String toString() =>
      'AudAudioMidiException: registration failed with '
      '${AudAbi.resultName(code)}';
}
