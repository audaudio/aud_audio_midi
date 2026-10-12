// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// Maps the time of `aud_midi` to the engine's host clock and back.
///
/// A [MidiTime] counts microseconds of the Dart VM's monotonic clock; the
/// engine counts nanoseconds of the platform's monotonic clock (time-001).
/// The offset between the two comes from back-to-back readings of both
/// clocks: of [samples] pairs the one with the smallest gap wins, as in
/// aud_midi's own clock mapper. The offset is taken again after
/// [resyncAfter], so a drift between the clocks stays small. The native
/// taps need no mapping: they deliver host time already (native-001).
class AudMidiClock {
  /// A clock over [engineNowNs] and [midiNow]; tests pass their own.
  AudMidiClock({
    int Function()? engineNowNs,
    MidiTime Function()? midiNow,
    this.samples = 5,
    this.resyncAfter = const Duration(seconds: 10),
  }) : _engineNowNs = engineNowNs ?? AudClock.nowNs,
       _midiNow = midiNow ?? const MidiSystemClock().now;

  /// The pairs of readings per synchronization.
  final int samples;

  /// The time after which the offset is taken again.
  final Duration resyncAfter;

  // ...........................................................................
  /// The engine's host time in nanoseconds of [time].
  int toEngineNs(MidiTime time) => time.microseconds * 1000 + offsetNs;

  /// The [MidiTime] of the engine's host time [hostTimeNs].
  MidiTime toMidiTime(int hostTimeNs) =>
      MidiTime(((hostTimeNs - offsetNs) / 1000).round());

  /// Host time minus MIDI time in nanoseconds; synchronizes when the last
  /// synchronization is older than [resyncAfter].
  int get offsetNs {
    final syncedAt = _syncedAt;
    if (syncedAt == null ||
        _engineNowNs() - syncedAt > resyncAfter.inMicroseconds * 1000) {
      resync();
    }
    return _offsetNs;
  }

  /// Takes the offset again from [samples] pairs of readings.
  void resync() {
    var bestGap = -1;
    var best = 0;
    for (var i = 0; i < samples; i++) {
      final before = _engineNowNs();
      final midi = _midiNow().microseconds * 1000;
      final after = _engineNowNs();
      final gap = after - before;
      if (bestGap < 0 || gap < bestGap) {
        bestGap = gap;
        best = before + gap ~/ 2 - midi;
      }
    }
    _offsetNs = best;
    _syncedAt = _engineNowNs();
  }

  // ######################
  // Private
  // ######################

  final int Function() _engineNowNs;
  final MidiTime Function() _midiNow;
  int _offsetNs = 0;
  int? _syncedAt;
}
