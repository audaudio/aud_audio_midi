// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:isolate';

import 'package:aud_dsp_sampler/testing.dart';
import 'package:path_provider/path_provider.dart';

// #############################################################################
/// The instruments of the sampler page, generated on the device
/// (scope-002): the samples of [AudSfzTestInstrument] with three settings
/// of envelope and filter, each an SFZ text against the instrument's
/// directory.
abstract final class Instruments {
  /// Writes the samples into the temporary directory and completes with
  /// the instrument. Computing them takes a moment, so another isolate
  /// writes them while the UI goes on.
  static Future<AudSfzTestInstrument> write() async {
    final temporary = await getTemporaryDirectory();
    return _writeOnIsolate('${temporary.path}/$_directory');
  }

  /// The SFZ text of the instrument [index]. Throws a [StateError] when
  /// the envelope and the filter of [AudSfzTestInstrument.sfz] are no
  /// longer where the other instruments replace them.
  static String sfz(int index) => switch (index) {
    0 => AudSfzTestInstrument.sfz,
    1 => _withGlobal(
      'ampeg_attack=0.002 ampeg_decay=0.6 ampeg_sustain=0 '
      'ampeg_release=0.15\n'
      'fil_type=lpf_2p cutoff=600 resonance=6 fil_veltrack=3600 '
      'fileg_decay=0.25 fileg_sustain=0 fileg_depth=3600 cutoff_oncc1=2400',
    ),
    _ => _withGlobal(
      'ampeg_attack=0.08 ampeg_decay=0.5 ampeg_sustain=80 '
      'ampeg_release=0.8\n'
      'fil_type=lpf_4p cutoff=350 fil_veltrack=1200 cutoff_oncc1=3600',
    ),
  };

  // ...........................................................................
  /// The names of the instruments.
  static const List<String> names = ['Saw pad', 'Pluck', 'Mellow'];

  // ######################
  // Private
  // ######################

  // The directory of the samples in the temporary directory.
  static const String _directory = 'aud_test_instrument';

  // The envelope and the filter of the test instrument: from its attack to
  // its first region.
  static final RegExp _envelopeAndFilter = RegExp(
    r'ampeg_attack[\s\S]*?(?=<region>)',
  );

  // Writes the samples into [directory] on another isolate. A static
  // method, so that the closure takes nothing to the isolate but the
  // directory.
  static Future<AudSfzTestInstrument> _writeOnIsolate(String directory) =>
      Isolate.run(() => AudSfzTestInstrument.write(directory));

  // The test instrument with [opcodes] for its envelope and its filter.
  static String _withGlobal(String opcodes) {
    final sfz = AudSfzTestInstrument.sfz;
    final replaced = sfz.replaceFirst(_envelopeAndFilter, '$opcodes\n');
    if (replaced == sfz) {
      throw StateError(
        'AudSfzTestInstrument.sfz has no envelope before its regions: '
        'the instruments of the sampler page cannot replace it',
      );
    }
    return replaced;
  }
}
