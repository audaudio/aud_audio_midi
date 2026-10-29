<!--
@license
Copyright (c) Audanika. All Rights Reserved.

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Rename the package to aud_audio_with_midi

## Motivation

- The old name `aud_audio_midi` read like a part of `aud_audio`. The
  package is the Audanika Audio Engine with MIDI: it depends on
  `aud_audio` and adds the ports of `aud_midi` to it.
- The new name `aud_audio_with_midi` says that layering.

## Strategy

- Rename everything that carries the package name: the package, the
  repo, the files, the C API and the example.
- Keep the node type IDs `aud.midi.input` and `aud.midi.output`: graphs
  saved with them stay valid.
- Change no behavior.

## Implementation 1: Dart

- `pubspec.yaml` names the package `aud_audio_with_midi`; homepage and
  repository point to `github.com/audaudio/aud_audio_with_midi`.
- `lib/aud_audio_with_midi.dart` and `lib/aud_audio_with_midi_ffi.dart`
  are the new entry points; imports change from
  `package:aud_audio_midi/...` to `package:aud_audio_with_midi/...`.
- The version, FFI and generated binding files and their tests follow
  the new name.

## Implementation 2: Native

- The header is `src/aud_audio_with_midi.h`, its include guard
  `AUD_AUDIO_WITH_MIDI_H`.
- The C functions `aud_audio_midi_*` are now `aud_audio_with_midi_*`;
  `ffigen.yaml` and the generated bindings match.

## Implementation 3: Example, docs and repo

- The example app is `aud_audio_with_midi_example`, with the Android
  application ID, the Kotlin package and the iOS bundle name renamed.
- README (English and German), `NOTICES.md` and `index.jsonc` use the
  new name.
- The GitHub repo is renamed; GitHub redirects the old URL.

## Migration

- Depend on `aud_audio_with_midi` instead of `aud_audio_midi`.
- Replace `package:aud_audio_midi/` by `package:aud_audio_with_midi/`.
- Native callers include `aud_audio_with_midi.h` and call
  `aud_audio_with_midi_*`.
- Node type IDs and the Dart API names stay the same.

## Result

- Analyzer is clean, the 60 unit tests are green, the example analyzes
  clean.

## Open Points

- The integration tests of the example ran on no device in this change.
