// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_audio_with_midi/aud_audio_with_midi_ffi.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  group('AudMidiClock', () {
    test('takes the offset of the pair with the smallest gap', () {
      // Engine readings around each MIDI reading: gaps of 900, 100, 500 ns.
      final engine = [
        10000, 10900, // midi 1 µs
        20000, 20100, // midi 2 µs
        30000, 30500, // midi 3 µs
        40000, // the time of the synchronization
        40001, 40002, // the checks of the later reads
      ];
      final midi = [1, 2, 3];
      var e = 0;
      var m = 0;
      final clock = AudMidiClock(
        engineNowNs: () => engine[e++],
        midiNow: () => MidiTime(midi[m++]),
        samples: 3,
      );
      // 20000 + 100 / 2 - 2000
      expect(clock.offsetNs, 18050);
      expect(clock.toEngineNs(const MidiTime(10)), 10000 + 18050);
      expect(clock.toMidiTime(10000 + 18050), const MidiTime(10));
    });

    test('synchronizes again after resyncAfter', () {
      var now = 1000000;
      var offset = 5000;
      final clock = AudMidiClock(
        engineNowNs: () => now,
        midiNow: () => MidiTime((now - offset) ~/ 1000),
        samples: 1,
        resyncAfter: const Duration(milliseconds: 1),
      );
      expect(clock.offsetNs, 5000);
      offset = 9000;
      now += 500000;
      expect(clock.offsetNs, 5000);
      now += 600000;
      expect(clock.offsetNs, 9000);
      expect(clock.samples, 1);
    });

    test('maps the real clocks within a few microseconds', () {
      final clock = AudMidiClock();
      clock.resync();
      final midi = const MidiSystemClock().now();
      final engine = AudClock.nowNs();
      expect(
        (clock.toEngineNs(midi) - engine).abs(),
        lessThan(Duration.microsecondsPerSecond * 1000 ~/ 100),
      );
      expect(clock.resyncAfter, const Duration(seconds: 10));
    });
  });
}
