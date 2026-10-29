// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.
// The hardware test of ticket 26: someone plays a real MIDI keyboard into
// the MIDI keyboard page while the page shows what to do next.
//
//   flutter test integration_test/midi_keyboard_test.dart -d <device> \
//     --dart-define=AUD_PLAY_SECONDS=600 [--dart-define=AUD_BLUETOOTH=true]
//
// 1. The keyboard: the port named AUD_MIDI_PORT, else the first USB or
//    Bluetooth LE input that is connected (waits up to two minutes).
// 2. Playing for AUD_PLAY_SECONDS with the page animated: the input to
//    output time, late events, delivery delays, xruns, late callbacks.
// 3. Hot-plug: a held chord with the pedal down, then the cable out - the
//    time from the port's removal to silence (no note left on; it includes
//    the release of the instrument); the cable back in - the time from the
//    port's return to the input playing again (budget 500 ms), on Android
//    under a new id, found by its fingerprint. AUD_HOT_PLUG=false skips it,
//    AUD_PLAY_SECONDS=0 the playing.
// 4. With AUD_BLUETOOTH=true: a Bluetooth LE MIDI device connected with the
//    page's Bluetooth button and played for AUD_BLUETOOTH_SECONDS.

// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:aud_audio_with_midi_example/main.dart';
import 'package:aud_audio_with_midi_example/midi_page.dart';
import 'package:aud_midi/aud_midi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'midi_support.dart';

const _port = String.fromEnvironment('AUD_MIDI_PORT');
const _playSeconds = int.fromEnvironment('AUD_PLAY_SECONDS', defaultValue: 600);
const _bluetooth = bool.fromEnvironment('AUD_BLUETOOTH');
const _hotPlug = bool.fromEnvironment('AUD_HOT_PLUG', defaultValue: true);
const _bluetoothSeconds = int.fromEnvironment(
  'AUD_BLUETOOTH_SECONDS',
  defaultValue: 60,
);

void main() {
  // The person taps the page (the Bluetooth button): the binding hands
  // the device's touches to the app instead of only listing finders.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
          .shouldPropagateDevicePointerEvents =
      true;

  Future<void> until(
    WidgetTester tester,
    bool Function() condition, {
    int seconds = 120,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> animate(WidgetTester tester, int seconds) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
  }

  bool isKeyboard(MidiPortInfo port) =>
      port.direction == MidiDirection.input &&
      port.state == MidiPortState.connected &&
      !port.isOwn &&
      (_port.isNotEmpty
          ? port.name == _port
          : port.transport == MidiTransport.usb ||
                port.transport == MidiTransport.bluetoothLe);

  // Plays for [seconds] and returns the numbers of that window.
  Future<Map<String, Object?>> playing(
    WidgetTester tester,
    MidiPageState page,
    String text,
    int seconds,
  ) async {
    final input = page.input!;
    final engine = page.engine;
    page.prompt = text;
    final before = input.source.stats;
    final numbers = engine.numbers;
    await animate(tester, seconds);
    final window = SourceWindow(before, input.source.stats);
    final after = engine.numbers;
    return {
      'port': input.port.name,
      'transport': input.port.transport.name,
      'path': input.path?.name,
      'latencyMs': input.source.latencyNs / 1e6,
      'marginMs': input.marginNs / 1e6,
      'periodMs': page.bridge!.periodNs / 1e6,
      'outputLatencyMs': engine.timing.outputLatencyNs / 1e6,
      'window': window.toJson(),
      'xruns': after.xruns - numbers.xruns,
      'lateCallbacks': after.lateCallbacks - numbers.lateCallbacks,
      'seconds': seconds,
    };
  }

  testWidgets('a person plays a keyboard; hot-plug and Bluetooth', (
    tester,
  ) async {
    await tester.pumpWidget(const EngineApp());
    await tester.pump();
    final page = tester.state<MidiPageState>(find.byType(MidiPage));
    final engine = page.engine;
    await until(tester, () => page.bridge != null, seconds: 15);
    final bridge = page.bridge!;
    final midi = page.midi!;
    final report = <String, Object?>{};

    // 1. The keyboard; a run of Bluetooth alone starts the engine only.
    MidiPortInfo? keyboard;
    if (_playSeconds > 0 || _hotPlug) {
      page.prompt = 'Connect the MIDI keyboard';
      await until(tester, () => bridge.inputPorts.any(isKeyboard));
      final picked = bridge.inputPorts.firstWhere(isKeyboard);
      keyboard = picked;
      await tester.runAsync(() => page.pick(picked));
      await tester.pump();
      expect(page.input, isNotNull, reason: page.error);
    }
    engine.start();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );

    // 2. Playing.
    if (_playSeconds > 0) {
      report['playing'] = await playing(
        tester,
        page,
        'Play ${keyboard!.name} for ${_playSeconds ~/ 60} minutes: chords, '
        'the sustain pedal, fast repeats',
        _playSeconds,
      );
      print('MIDI keyboard report (playing): ${jsonEncode(report['playing'])}');
    }

    if (_hotPlug) {
      final input = page.input!;
      final port = keyboard!;
      // 3. Hot-plug: the times of the port's events, as Dart sees them.
      final events = <(MidiPortEvent, DateTime)>[];
      final changes = midi.changes.listen(
        (e) => events.add((e, DateTime.now())),
      );
      page.prompt =
          'Hold a chord with the sustain pedal down, then pull the cable of '
          '${port.name}';
      await until(tester, () => input.isWaiting);
      final gone = events.lastWhere(
        (e) => e.$1.port.fingerprint == port.fingerprint,
      );
      // Silence: the output's peak stays below -80 dB for half a second.
      var silentSince = DateTime.now();
      DateTime? silent;
      while (silent == null) {
        engine.graph.resetStats();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        final now = DateTime.now();
        if (engine.stats.outputPeak > 1e-4) {
          silentSince = now;
        } else if (now.difference(silentSince).inMilliseconds >= 500) {
          silent = silentSince;
        }
        if (now.difference(gone.$2).inSeconds > 20) fail('A note stays on');
      }
      page.prompt = 'Plug ${port.name} in again';
      await until(tester, () => !input.isWaiting);
      final bound = DateTime.now();
      final back = events.lastWhere(
        (e) =>
            e.$1.port.fingerprint == port.fingerprint &&
            e.$1.port.state == MidiPortState.connected &&
            e.$1 is! MidiPortRemoved,
      );
      final delivered = input.source.stats.delivered;
      page.prompt = 'Play a key';
      await until(tester, () => input.source.stats.delivered > delivered);
      final played = DateTime.now();
      await changes.cancel();
      report['hotPlug'] = {
        'event': gone.$1.runtimeType.toString(),
        'silentAfterMs': silent.difference(gone.$2).inMilliseconds,
        'boundAfterMs': bound.difference(back.$2).inMilliseconds,
        'firstEventAfterMs': played.difference(back.$2).inMilliseconds,
        'sameId': input.port.id == port.id,
        'releases': input.source.stats.releases,
      };
      print(
        'MIDI keyboard report (hot-plug): ${jsonEncode(report['hotPlug'])}',
      );
      expect(
        bound.difference(back.$2).inMilliseconds,
        lessThanOrEqualTo(500),
        reason: 'the input plays again within 500 ms of the port',
      );
    }

    // 4. Bluetooth.
    if (_bluetooth) {
      page.prompt =
          'Tap the Bluetooth button and connect the Bluetooth MIDI device';
      bool isBle(MidiPortInfo port) =>
          port.direction == MidiDirection.input &&
          port.state == MidiPortState.connected &&
          port.transport == MidiTransport.bluetoothLe;
      await until(tester, () => bridge.inputPorts.any(isBle), seconds: 300);
      await tester.runAsync(
        () => page.pick(bridge.inputPorts.firstWhere(isBle)),
      );
      await tester.pump();
      report['bluetooth'] = await playing(
        tester,
        page,
        'Play the Bluetooth device for $_bluetoothSeconds seconds',
        _bluetoothSeconds,
      );
      print(
        'MIDI keyboard report (Bluetooth): ${jsonEncode(report['bluetooth'])}',
      );
    }
    page.prompt = 'Done - thank you';
    await animate(tester, 2);
    print('MIDI keyboard report: ${jsonEncode(report)}');
  });
}
