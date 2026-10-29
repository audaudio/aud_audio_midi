<!--
@license
Copyright (c) Audanika. All Rights Reserved.

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Add an example app with a MIDI keyboard

## Motivation

- This package had no example. What it does - ports of `aud_midi` as event
  inlets and outlets of the graph - was only visible in its unit tests and
  in the README snippet.
- A keyboard-to-synth app shows it end to end: a real or virtual MIDI port,
  `AudMidiBridge`, the port nodes, a sampler that plays, and the timing the
  bridge holds.
- The device tests of the budgets (midi-003) and of the native and the
  Dart path (midi-002) need an app to run in.

## Strategy

- Build the example on the engine of `aud_audio` and the SFZ sampler of
  `aud_dsp_sampler`, with one page: the MIDI keyboard.
- Take the existing keyboard page and its integration tests, so the
  measured budgets stay comparable.
- Make the example a member of the pub workspace of the repo from the
  start.
- Leave the library untouched.

## Implementation 1: The app

- `example/` is the Flutter app `aud_audio_midi_example` for iOS and
  Android.
- `main.dart` creates one `AudEngine` with the sampler and
  `AudMidiBridge.package` registered and shows `MidiPage`.
- `MidiPage` opens the ports, offers a port picker, shows the activity of
  the port, switches between fixed and immediate timing and measures the
  input to output time; an on-screen keyboard plays as well.
- `engine_panel.dart`, `keyboard.dart` and `instruments.dart` show the
  state and numbers of the engine, draw the keys and write the test
  instruments of the sampler on the device.
- Android: MIDI and Bluetooth LE features and permissions, and the
  loopback service of `aud_midi_android` for the tests. iOS: the Bluetooth
  and local network usage texts.

## Implementation 2: The integration tests

- `midi_test.dart` plays a recorded performance from a source of the app
  into the input and prints the budgets.
- `midi_paths_test.dart` measures the native tap and the Dart path.
- `midi_keyboard_test.dart` guides a person through a real keyboard, the
  hot-plug and Bluetooth MIDI.
- The tests start on the MIDI page directly; there is no page to switch
  to.

## Implementation 3: The pub workspace

- `pubspec.yaml` declares `workspace: [example]`; one `pubspec.lock` at the
  root resolves both.
- The `test` dev dependency moves from `^1.33.0` to `^1.31.1`, within the
  `test_api` that `flutter_test` of Flutter 3.47 pins.
- README, in English and German, and `index.jsonc` describe the example.

## Result

- Analyzer, formatter and the 60 unit tests are green; the example builds
  for the iOS simulator.

## Open Points

- The integration tests ran on no device in this change.
- `engine_panel.dart`, `keyboard.dart` and `instruments.dart` are copies of
  the files of another example; each example stays self-contained.
