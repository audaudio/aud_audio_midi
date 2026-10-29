# aud_audio_midi_example

A MIDI keyboard plays the SFZ sampler of `aud_dsp_sampler` through
`AudMidiBridge`, on iOS and Android:

- A port picker with the activity of the port, USB, virtual and Bluetooth
  LE MIDI
- The fixed or immediate timing of the input and the measured input to
  output time
- An on-screen keyboard, the state, route, format and numbers of the
  engine, with a report to copy

```bash
flutter run -d <device>
flutter test integration_test/midi_test.dart -d <device> \
  --dart-define=AUD_WARMUP_SECONDS=1200 --dart-define=AUD_MEASURE_SECONDS=600
flutter test integration_test/midi_paths_test.dart -d <device> \
  --dart-define=AUD_MARGIN_SECONDS=60 --dart-define=AUD_MEASURE_SECONDS=600
flutter test integration_test/midi_keyboard_test.dart -d <device> \
  --dart-define=AUD_PLAY_SECONDS=600 --dart-define=AUD_BLUETOOTH=true
```

`midi_test.dart` plays a recorded performance from a source of the app -
on iOS a CoreMIDI source, on Android the loopback device of
`aud_midi_android` - into the input and prints the budgets.
`midi_paths_test.dart` measures the native and the Dart paths.
`midi_keyboard_test.dart` guides a person through playing a real keyboard,
the hot-plug and Bluetooth MIDI.
