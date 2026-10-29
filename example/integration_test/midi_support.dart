// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// What the MIDI integration tests of ticket 26 share: a source that plays
// into the app, a recorded keyboard performance and the statistics of a
// window of time.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_midi/aud_midi.dart';

// #############################################################################
/// A source that plays into the app: on Android the loopback device of
/// `aud_midi_android` (its input comes back out of its output); elsewhere a
/// CoreMIDI source of a second MIDI host in an isolate of its own, so that
/// the app's host sees it as the port of another app, not as its own.
class MidiTestSource {
  MidiTestSource._(this.input, this._send, this._close);

  /// The name of the source.
  static const String name = 'aud_audio test';

  /// Creates the source of the platform and waits until the app's [midi]
  /// lists its input port.
  static Future<MidiTestSource> open(Midi midi) async {
    if (Platform.isAndroid) {
      final input = await _port(midi, MidiDirection.input, 'loop out');
      final output = await _port(midi, MidiDirection.output, 'loop in');
      final sending = midi.output(output.id)!;
      return MidiTestSource._(input, sending.send, () async {});
    }
    final ready = ReceivePort();
    await Isolate.spawn(_host, ready.sendPort);
    final commands = await ready.first as SendPort;
    final input = await _port(midi, MidiDirection.input, name);
    return MidiTestSource._(
      input,
      (message) async => commands.send(message.toBytes()!.bytes.toList()),
      () async => commands.send(null),
    );
  }

  /// The input port the app plays from.
  final MidiPortInfo input;

  /// Sends [message] now.
  Future<void> send(MidiMessage message) => _send(message);

  /// Removes the source.
  Future<void> close() => _close();

  // ######################
  // Private
  // ######################

  final Future<void> Function(MidiMessage) _send;
  final Future<void> Function() _close;

  // The second MIDI host: creates the source and sends the bytes it gets
  // until it gets null.
  static Future<void> _host(SendPort ready) async {
    final midi = await Midi.open(options: const MidiOptions(inIsolate: true));
    final source = await midi.virtualPorts!.createSource(name);
    final commands = ReceivePort();
    ready.send(commands.sendPort);
    await for (final bytes in commands) {
      if (bytes == null) break;
      await source.sendBytes(bytes as List<int>);
    }
    await midi.virtualPorts!.remove(source.id);
    await midi.close();
    commands.close();
  }

  static Future<MidiPortInfo> _port(
    Midi midi,
    MidiDirection direction,
    String name,
  ) async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(end)) {
      for (final port in midi.ports) {
        if (port.direction == direction &&
            port.name == name &&
            port.state == MidiPortState.connected) {
          return port;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('No $direction port "$name" in ${midi.ports}');
  }
}

// #############################################################################
/// A recorded keyboard performance, played step by step: single notes of
/// different lengths, a chord every few steps, the sustain pedal down for
/// a phrase, fast repeats of one key; deterministic from its seed.
class MidiPerformance {
  /// A performance on [source].
  MidiPerformance(this.source, {int seed = 26}) : _random = Random(seed);

  /// The source it plays on.
  final MidiTestSource source;

  /// The interval of the steps.
  static const Duration step = Duration(milliseconds: 120);

  /// Plays until [stop] completes, then releases what sounds.
  Future<void> play(Future<void> stop) async {
    var stopped = false;
    unawaited(stop.then((_) => stopped = true));
    var i = 0;
    while (!stopped) {
      await _step(i++);
      await Future<void>.delayed(step);
    }
    for (final note in List.of(_held)) {
      await source.send(MidiNoteOff(channel: 0, note: note));
    }
    _held.clear();
    await source.send(
      const MidiControlChange(channel: 0, controller: 64, value: 0),
    );
  }

  // ######################
  // Private
  // ######################

  final Random _random;
  final List<int> _held = [];

  Future<void> _step(int i) async {
    // The pedal: down for 16 steps of every 48.
    if (i % 48 == 0) {
      await source.send(
        const MidiControlChange(channel: 0, controller: 64, value: 127),
      );
    } else if (i % 48 == 16) {
      await source.send(
        const MidiControlChange(channel: 0, controller: 64, value: 0),
      );
    }
    // Release the oldest notes: at most eight sound.
    while (_held.length > 8) {
      await source.send(MidiNoteOff(channel: 0, note: _held.removeAt(0)));
    }
    final root = 48 + _random.nextInt(24);
    if (i % 8 == 0) {
      // A chord.
      for (final interval in const [0, 4, 7, 12]) {
        await _on(root + interval);
      }
    } else if (i % 30 == 15) {
      // Fast repeats of one key: four notes within one step.
      for (var r = 0; r < 4; r++) {
        await _on(root);
        await source.send(MidiNoteOff(channel: 0, note: root));
        _held.remove(root);
      }
    } else {
      await _on(root);
    }
  }

  Future<void> _on(int note) async {
    await source.send(
      MidiNoteOn(channel: 0, note: note, velocity: 40 + _random.nextInt(80)),
    );
    _held.add(note);
  }
}

// #############################################################################
/// The statistics of a source between two readings.
class SourceWindow {
  /// The window from [before] to [after].
  SourceWindow(this.before, this.after);

  /// The statistics at the start.
  final AudEventSourceStats before;

  /// The statistics at the end.
  final AudEventSourceStats after;

  /// Events delivered in the window.
  int get delivered => after.delivered - before.delivered;

  /// Late events in the window.
  int get late => after.late - before.late;

  /// The share of late events.
  double get lateShare => delivered == 0 ? 0 : late / delivered;

  /// The percentile [fraction] of the delivery delay in the window.
  int? delayNs(double fraction) => _percentile(
    before.delayHistogram,
    after.delayHistogram,
    AudEventSourceStats.delayBinNs,
    fraction,
  );

  /// The percentile [fraction] of the input to output time in the window.
  int? latencyNs(double fraction) => _percentile(
    before.latencyHistogram,
    after.latencyHistogram,
    AudEventSourceStats.latencyBinNs,
    fraction,
  );

  /// The window as JSON, times in milliseconds.
  Map<String, Object?> toJson() => {
    'delivered': delivered,
    'late': late,
    'lateShare': lateShare,
    'maxLateMs': after.maxLateNs / 1e6,
    'delayP50Ms': _ms(delayNs(0.5)),
    'delayP99Ms': _ms(delayNs(0.99)),
    'delayP999Ms': _ms(delayNs(0.999)),
    'maxDelayMs': after.maxDelayNs / 1e6,
    'latencyP50Ms': _ms(latencyNs(0.5)),
    'latencyP99Ms': _ms(latencyNs(0.99)),
    'dropped': after.dropped - before.dropped,
    'rejected': after.rejected - before.rejected,
  };

  static double? _ms(int? ns) => ns == null ? null : ns / 1e6;

  static int? _percentile(
    List<int> before,
    List<int> after,
    int binNs,
    double fraction,
  ) {
    final delta = [for (var i = 0; i < after.length; i++) after[i] - before[i]];
    final total = delta.fold(0, (a, b) => a + b);
    if (total == 0) return null;
    final rank = (total * fraction).ceil();
    var seen = 0;
    for (var i = 0; i < delta.length; i++) {
      seen += delta[i];
      if (seen >= rank) return (i + 1) * binNs;
    }
    return delta.length * binNs;
  }
}
