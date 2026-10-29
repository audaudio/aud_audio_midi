// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_audio_with_midi/aud_audio_with_midi_ffi.dart';
import 'package:aud_dsp_sampler/aud_dsp_sampler_ffi.dart';
import 'package:aud_dsp_sampler/testing.dart';
import 'package:flutter/material.dart';

import 'instruments.dart';
import 'midi_page.dart';

void main() => runApp(const EngineApp());

// #############################################################################
/// The example of `aud_audio_with_midi`: a MIDI keyboard plays the SFZ sampler of
/// `aud_dsp_sampler` through [AudMidiBridge], with the numbers of the
/// engine.
class EngineApp extends StatefulWidget {
  /// Creates the app; [config] replaces the engine's configuration (tests).
  const EngineApp({super.key, this.config = const AudEngineConfig()});

  /// The configuration of the engine.
  final AudEngineConfig config;

  @override
  State<EngineApp> createState() => EngineAppState();
}

// #############################################################################
/// The state of [EngineApp]: the engine the page plays on; public for the
/// integration tests.
class EngineAppState extends State<EngineApp> {
  /// The engine, with the sampler and the port nodes registered.
  late final AudEngine engine = AudEngine(
    config: widget.config,
    packages: [
      AudNativeNodePackage(AudDspSampler.name, AudDspSampler.register),
      AudMidiBridge.package,
    ],
  );

  /// The instrument of the sampler, written once, when the app starts.
  late final Future<AudSfzTestInstrument> instrument = Instruments.write();

  @override
  void dispose() {
    engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'aud_audio_with_midi',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('aud_audio_with_midi keyboard')),
      body: MidiPage(engine: engine, instrument: instrument),
    ),
  );
}
