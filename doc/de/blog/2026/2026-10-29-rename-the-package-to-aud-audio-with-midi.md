<!--
@license
Copyright (c) Audanika. All Rights Reserved.

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Das Paket heißt jetzt aud_audio_with_midi

## Motivation

- Der alte Name `aud_audio_midi` klang wie ein Teil von `aud_audio`. Das
  Paket ist aber die Audanika Audio Engine mit MIDI: Es hängt von
  `aud_audio` ab und ergänzt die Ports von `aud_midi`.
- Der neue Name `aud_audio_with_midi` macht diese Schichtung sichtbar.

## Strategie

- Alles umbenennen, was den Paketnamen trägt: Paket, Repo, Dateien,
  C-API und Example.
- Die Node-Typ-IDs `aud.midi.input` und `aud.midi.output` bleiben:
  Damit gespeicherte Graphen bleiben gültig.
- Kein Verhalten ändern.

## Umsetzung 1: Dart

- `pubspec.yaml` nennt das Paket `aud_audio_with_midi`; homepage und
  repository zeigen auf `github.com/audaudio/aud_audio_with_midi`.
- `lib/aud_audio_with_midi.dart` und `lib/aud_audio_with_midi_ffi.dart`
  sind die neuen Einstiegspunkte; Imports wechseln von
  `package:aud_audio_midi/...` zu `package:aud_audio_with_midi/...`.
- Version, FFI, generierte Bindings und ihre Tests folgen dem neuen Namen.

## Umsetzung 2: Nativ

- Der Header ist `src/aud_audio_with_midi.h`, sein Include-Guard
  `AUD_AUDIO_WITH_MIDI_H`.
- Die C-Funktionen `aud_audio_midi_*` heißen jetzt
  `aud_audio_with_midi_*`; `ffigen.yaml` und die Bindings passen dazu.

## Umsetzung 3: Example, Doku und Repo

- Die Example-App heißt `aud_audio_with_midi_example`, samt Android
  Application-ID, Kotlin-Paket und iOS-Bundle-Name.
- README (Englisch und Deutsch), `NOTICES.md` und `index.jsonc` nutzen den
  neuen Namen.
- Das GitHub-Repo ist umbenannt; GitHub leitet die alte URL weiter.

## Migration

- `aud_audio_with_midi` statt `aud_audio_midi` als Abhängigkeit.
- `package:aud_audio_midi/` durch `package:aud_audio_with_midi/` ersetzen.
- Native Aufrufer binden `aud_audio_with_midi.h` ein und rufen
  `aud_audio_with_midi_*` auf.
- Node-Typ-IDs und die Namen der Dart-API bleiben gleich.

## Ergebnis

- Analyzer sauber, die 60 Unit-Tests grün, das Example analysiert sauber.

## Offene Punkte

- Die Integrationstests des Examples liefen in dieser Änderung auf keinem
  Gerät.
