<!--
@license
Copyright (c) Audanika. All Rights Reserved.

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Eine Beispiel-App mit MIDI-Keyboard

## Motivation

- Dieses Paket hatte kein Beispiel. Was es tut - Ports von `aud_midi` als
  Event-Ein- und -Ausgänge des Graphen - war nur in den Unit-Tests und im
  Codebeispiel der README zu sehen.
- Eine Keyboard-zu-Synth-App zeigt es von Ende zu Ende: ein echter oder
  virtueller MIDI-Port, `AudMidiBridge`, die Port-Knoten, ein Sampler, der
  spielt, und das Timing, das die Brücke hält.
- Die Gerätetests der Budgets (midi-003) und des nativen und des Dart-Wegs
  (midi-002) brauchen eine App, in der sie laufen.

## Strategie

- Das Beispiel auf der Engine von `aud_audio` und dem SFZ-Sampler von
  `aud_dsp_sampler` bauen, mit einer Seite: dem MIDI-Keyboard.
- Die bestehende Keyboard-Seite und ihre Integrationstests übernehmen,
  damit die gemessenen Budgets vergleichbar bleiben.
- Das Beispiel von Anfang an zum Mitglied des Pub-Workspace des Repos
  machen.
- Die Bibliothek bleibt unverändert.

## Realisierung 1: Die App

- `example/` ist die Flutter-App `aud_audio_midi_example` für iOS und
  Android.
- `main.dart` erzeugt eine `AudEngine` mit dem Sampler und
  `AudMidiBridge.package` und zeigt `MidiPage`.
- `MidiPage` öffnet die Ports, bietet eine Port-Auswahl, zeigt die
  Aktivität des Ports, schaltet zwischen festem und sofortigem Timing um
  und misst die Zeit vom Eingang zum Ausgang; eine Bildschirmtastatur
  spielt ebenfalls.
- `engine_panel.dart`, `keyboard.dart` und `instruments.dart` zeigen
  Zustand und Zahlen der Engine, zeichnen die Tasten und schreiben die
  Testinstrumente des Samplers auf das Gerät.
- Android: MIDI- und Bluetooth-LE-Features und -Berechtigungen sowie der
  Loopback-Service von `aud_midi_android` für die Tests. iOS: die Texte für
  Bluetooth und das lokale Netzwerk.

## Realisierung 2: Die Integrationstests

- `midi_test.dart` spielt eine aufgenommene Performance aus einer Quelle
  der App in den Eingang und gibt die Budgets aus.
- `midi_paths_test.dart` misst den nativen Tap und den Dart-Weg.
- `midi_keyboard_test.dart` führt eine Person durch ein echtes Keyboard,
  das Hot-Plug und Bluetooth-MIDI.
- Die Tests starten direkt auf der MIDI-Seite; es gibt keine Seite, zu der
  sie wechseln müssten.

## Realisierung 3: Der Pub-Workspace

- `pubspec.yaml` deklariert `workspace: [example]`; eine `pubspec.lock` im
  Root löst beide auf.
- Die Dev-Abhängigkeit `test` geht von `^1.33.0` auf `^1.31.1`, innerhalb
  der `test_api`, die `flutter_test` von Flutter 3.47 pinnt.
- README, auf Englisch und Deutsch, und `index.jsonc` beschreiben das
  Beispiel.

## Ergebnis

- Analyzer, Formatter und die 60 Unit-Tests sind grün; das Beispiel baut
  für den iOS-Simulator.

## Offene Punkte

- Die Integrationstests liefen in dieser Änderung auf keinem Gerät.
- `engine_panel.dart`, `keyboard.dart` und `instruments.dart` sind Kopien
  der Dateien eines anderen Beispiels; jedes Beispiel bleibt für sich
  vollständig.
