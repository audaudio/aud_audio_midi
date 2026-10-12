// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';
import 'dart:isolate';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

// Builds the MIDI bridge - the port nodes, the byte parser and the tap
// adapter - as C++17 against the header-only ABI of aud_audio_core, whose
// `src` directory is resolved through the package config: packages never
// link the core or the graph, they only include their headers
// (interop-001, build-001). Only the AUD_EXPORT entry points are visible.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final packageName = input.packageName;
    final android = input.config.code.targetOS == OS.android;
    final cbuilder = CBuilder.library(
      name: packageName,
      assetName: 'src/${packageName}_bindings_generated.dart',
      sources: [
        'src/aud_midi_adapter.cpp',
        'src/aud_midi_nodes.cpp',
        'src/aud_midi_parser.cpp',
      ],
      includes: ['src', await packageSrcDirectory('aud_audio_core')],
      language: Language.cpp,
      std: 'c++17',
      flags: ['-fvisibility=hidden'],
      cppLinkStdLib: android ? 'c++_static' : null,
      libraries: [
        if (android) ...['log', 'm'],
      ],
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.ALL
        ..onRecord.listen((record) => stdout.writeln(record.message)),
    );
  });
}

/// The `src` directory of [package], resolved through the package config.
Future<String> packageSrcDirectory(String package) async {
  final lib = await Isolate.resolvePackageUri(Uri.parse('package:$package/'));
  if (lib == null) throw StateError('Package $package is not resolvable');
  return lib.resolve('../src/').toFilePath();
}
