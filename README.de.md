# aud_audio_with_midi

[English](README.md) | Deutsch

[![CI](https://github.com/audaudio/aud_audio_with_midi/actions/workflows/quick_check.yaml/badge.svg)](https://github.com/audaudio/aud_audio_with_midi/actions/workflows/quick_check.yaml)

MIDI-Brücke der Audanika Audio Engine: aud_midi-Ports als Event-Eingänge
und -Ausgänge des Graphen.

`AudMidiBridge` bindet die Ports eines `Midi` über ihre Port-ID an eine
Engine, mit Hot-Plug; das Paket enthält die Port-Knoten `aud.midi.input`
und `aud.midi.output`, den Parser von MIDI-1.0-Bytestrom zu Universal MIDI
Packets und den Tap-Adapter, der das MIDI eines Ports in eine Event-Quelle
des Graphen schiebt - auf dem Empfangs-Thread des Backends oder aus einem
Dart-Isolate, über eine einzige native Funktion. Es braucht Flutter und
läuft auf den nativen Plattformen. Teil der Audanika Audio Engine; geplant
in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Motivation

- Ein MIDI-Keyboard spielt den SFZ-Sampler auf iOS und Android mit
  konstanter Latenz von einem Block plus der Ausgabelatenz (Ticket 26,
  Schritt S8)
- MIDI erreicht den Audio-Thread nur über die lock-freien Event-Quellen
  des Graphen, nie über Dart (interop-001, interop-003)
- Ein Parser für beide Wege: Der native Tap der Backends und der Dart-Weg
  teilen ihn, damit sie sich gleich verhalten
- SysEx und Clock verdrängen nie Noten: Ein SysEx über 64 KiB sowie SysEx
  oder Clock, während eine Quelle mehr als halb voll ist, werden verworfen
  und gezählt, ein verworfenes SysEx bis zu seinem Ende
- Auf dem Tap-Pfad und in den Process-Aufrufen der Knoten wird nichts
  alloziert und nichts blockiert; die nativen Tests laufen unter
  ASan/UBSan, dem RealtimeSanitizer und dem ThreadSanitizer

## Installation

Das Paket ist nicht auf pub.dev veröffentlicht. Füge es als
Git-Abhängigkeit in `pubspec.yaml` ein und führe `flutter pub get` aus:

```yaml
dependencies:
  aud_audio_with_midi:
    git:
      url: git@github.com:audaudio/aud_audio_with_midi.git
      tag_pattern: "{{version}}"
    version: ^0.1.6
```

Eine App hängt von `aud_audio` ab und registriert das Paket bei ihrer
Engine (`AudMidiBridge.package`, family-001). Das Paket hängt von
`aud_audio` und von `aud_midi`, `aud_midi_core` und `aud_midi_standard`
aus pub.dev ab und braucht daher Flutter. Der Build-Hook kompiliert die
Knoten, den Parser und den Adapter mit der C++-Toolchain des Ziels gegen
die Header von `aud_audio_core`.

## Verwendung

Ein MIDI-Keyboard spielt ein Instrument einer Engine:

```dart
import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_audio_with_midi/aud_audio_with_midi_ffi.dart';
import 'package:aud_midi/aud_midi.dart';

Future<void> play(AudNode instrument, AudEngine engine) async {
  // The engine was created with AudMidiBridge.package in its packages.
  final midi = await Midi.open();
  final bridge = AudMidiBridge(engine, midi); // an extension of the engine
  final keyboard = bridge.inputPorts.first;
  final input = await bridge.openInput(keyboard); // native tap where offered
  engine.graph.transaction(
    (tx) => tx.connectEvents(input.node, instrument),
  );
  engine.start();
  // Later: the timing and what arrived.
  final stats = input.stats;
  print('C ${stats.latencyNs / 1e6} ms, late ${stats.source.late}');
}
```

`example/` ist eine Keyboard-zu-Synth-App und Mitglied des Pub-Workspace
dieses Repos: Ein Port von `aud_midi` spielt den SFZ-Sampler von
`aud_dsp_sampler` über `AudMidiBridge`, mit Port-Auswahl, Bluetooth-MIDI,
der Aktivität des Ports, dem festen oder sofortigen Timing, der gemessenen
Zeit vom Eingang zum Ausgang und den Zahlen der Engine. `midi_test.dart`
spielt eine aufgenommene Performance aus einer Quelle der App in den
Eingang, `midi_paths_test.dart` misst den nativen und die Dart-Wege von
midi-002, und `midi_keyboard_test.dart` führt eine Person durch das
Spielen eines echten Keyboards, das Hot-Plug und Bluetooth-MIDI:

```bash
cd example
flutter run -d <ios simulator | android emulator | device>
flutter test integration_test/midi_test.dart -d <device> \
  --dart-define=AUD_WARMUP_SECONDS=1200 --dart-define=AUD_MEASURE_SECONDS=600
flutter test integration_test/midi_paths_test.dart -d <device> \
  --dart-define=AUD_MARGIN_SECONDS=60 --dart-define=AUD_MEASURE_SECONDS=600
flutter test integration_test/midi_keyboard_test.dart -d <device> \
  --dart-define=AUD_PLAY_SECONDS=600 --dart-define=AUD_BLUETOOTH=true
```

## Einschränkungen

- Die Brücke, die Knoten und der Adapter sind nativ:
  `aud_audio_with_midi_ffi.dart` funktioniert nur auf den nativen Plattformen;
  die neutrale Bibliothek `aud_audio_with_midi.dart` kompiliert fürs Web,
  treibt dort aber keinen Port
- Ein SysEx über 64 KiB (`maxSysexBytes`) wird bis zu seinem Ende
  verworfen; SysEx und Clock werden verworfen, solange eine Quelle mehr
  als die Hälfte ihrer Kapazität hält
- Der Output-Knoten verwirft SysEx, solange sein Parameter `sysex` aus
  ist, da der Notification-Ring, über den seine Events reisen,
  verlustbehaftet ist
- Die C-ABI liest keine Strings zurück: Port-ID und Fingerprint leben nur
  auf dem Control-Thread und im Graph-Dokument
- Ein Bluetooth-LE-Port kalibriert seine Marge bis 30 ms; seltenere,
  längere Verzögerungen spielen verspätet
- Die nativen Tests brauchen Node.js und `clang++`; ihr
  RealtimeSanitizer-Build braucht ein clang, das ihn hat, z. B. LLVM aus
  Homebrew auf macOS (`brew install llvm`), und wird ohne eines
  übersprungen

## Dokumentation

- [Der Plan von Ticket 26](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/tickets/2026-10-12-26-bridge-aud-midi-ports-into-the-engine-on-ios-and-android.md)
  mit dem Umfang, den Budgets und den Entscheidungen des Plan-Reviews
- Die Entscheidungen hinter dem Paket:
  [midi-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/midi-001.md)
  (UMP als Event-Format),
  [interop-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/interop-001.md)
  (Dart läuft nie auf dem Audio-Thread),
  [abi-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/abi-001.md)
  (die C-ABI der Engine),
  [interop-003](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/interop-003.md)
  (Event-Quellen für native Erzeuger),
  [midi-002](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/midi-002.md)
  (der native Tap als Weg),
  [midi-003](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/midi-003.md)
  (die feste Latenz) und in aud_midi_pm
  [native-001](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/concepts/decisions/native-001.md)
  und
  [ports-001](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/concepts/decisions/ports-001.md)
- Die C-API: [src/aud_audio_with_midi.h](src/aud_audio_with_midi.h); der Parser:
  [src/aud_midi_parser.h](src/aud_midi_parser.h)
- Die Hinweise: [NOTICES.md](NOTICES.md) - das Paket enthält keinen
  Fremdcode
- Die Blog-Posts der Änderungen in [doc/blog](doc/blog)
- Die Guides in [doc/guides](doc/guides)

## Funktionsweise

### Die Brücke

- `AudMidiBridge(engine, midi)` ist eine Erweiterung der Engine: Die Engine
  startet ihr Auffrischen, sagt ihr, wenn ihr Timing neu beginnt, und
  lässt sie vor dem Freigeben des Graphen jeden Adapter synchron
  schließen; die Taps lösen sich danach im Hintergrund.
- `openInput(port)` legt einen `aud.midi.input`-Knoten (nach dem Port
  benannt), eine Event-Quelle und einen Adapter an und hängt einen
  Erzeuger an: den nativen Tap des Backends, wo es einen anbietet
  (midi-002), sonst den Dart-Weg, der die Pakete von `MidiInput.packets`
  durch denselben Adapter schiebt, mit ihrer MIDI-Zeit auf die Host-Zeit
  abgebildet (`AudMidiClock`).
- Das Timing (midi-003): standardmäßig `fixed` - jedes Event klingt zu
  seinem Zeitstempel plus C = P + L + m: P das 99,9. Perzentil der
  Render-Abstände (`periodNs`), L die gemeldete Ausgangslatenz, m
  mindestens 1 ms und das eigene 99,9. Perzentil der Lieferverzögerung des
  Eingangs nach 1000 Events (`AudMidiInput.marginNs`). C wächst nur, bis
  das Timing neu beginnt. `immediate` spielt ein Event zu Beginn des
  Blocks, der es abholt.
- Hot-Plug: Ein Port, der geht, löst das Release der Quelle aus - Note-Offs,
  Sustain- und Soft-Pedal aus; der Knoten und seine Verbindungen bleiben.
  Ein Port, der unter seiner ID zurückkommt, spielt wieder; auf Android,
  wo ein wieder eingestecktes Gerät eine neue ID bekommt, bindet sich der
  Eingang an den Port mit demselben Fingerprint (ports-001).
  `retarget(port)` bewegt einen Eingang zu einem anderen Port.
- `openOutput(port)` legt einen `aud.midi.output`-Knoten an, verbunden mit
  dem Event-Eingang des Graphen; was ihn erreicht, verlässt `aud_midi` zu
  der Zeit, zu der sein Frame den Audioausgang erreicht. Verwirft der
  Graph Benachrichtigungen, senden die Ausgänge Note-Offs für das, was sie
  halten.
- `AudMidiInput.stats`: die Zähler und Histogramme der Quelle (geliefert,
  verspätet, Lieferverzögerung, Zeit vom Eingang zum Ausgang), die Zähler
  des Adapters und die Zeit vom Eingang zum Ausgang der Events seit dem
  letzten Lesen.

### Die API der Brücke

- `AudMidiBridgeOptions`, übergeben an `AudMidiBridge(engine, midi,
  options:)`: `timing` ist das Timing neuer Eingänge (`fixed`);
  `preferNative` nimmt den nativen Tap, wo das Backend einen anbietet
  (true); `capacity` sind die Events, die eine Quelle hält (4096);
  `maxSysexBytes` das längste SysEx, das ein Eingang weitergibt (64 KiB);
  `refreshInterval`, wie oft die Brücke auf das Timing der Engine schaut,
  während sie läuft (1 s). Die Marge m: `marginNs` ist das kleinste m
  (1 ms), `marginSamples` die gelieferten Events, nach denen ein Eingang
  sein eigenes 99,9. Perzentil der Lieferverzögerung als m nimmt (1000).
  Ein Bluetooth-LE-Port beginnt bei `bluetoothMarginNs` (15 ms, ein
  Verbindungsintervall, da BLE MIDI die Zeitstempel des Senders trägt)
  und kalibriert sich bis `bluetoothMarginCapNs` (30 ms); seltenere,
  längere Verzögerungen spielen verspätet.
- `AudMidiPath`: `native` - das Backend ruft den Adapter auf seinem
  Empfangs-Thread - oder `dart` - die Brücke empfängt die Pakete in Dart
  und schiebt sie über FFI. `openInput(port, path:)` erzwingt einen:
  `native` wirft eine `MidiException`, wenn das Backend keinen Tap hat,
  statt zurückzufallen, `dart` hängt nie einen Tap an. Ohne `path` nimmt
  der Eingang den nativen Weg, wo er angeboten wird und `preferNative`
  an ist. `AudMidiInput.path` ist der Weg in Gebrauch, null, solange der
  Port weg ist.
- `AudMidiInput.setTiming(timing)` legt die Quelle neu an: Der Erzeuger
  löst sich, die Quelle geht und eine neue mit dem neuen Timing tritt an
  ihre Stelle, der Erzeuger hängt sich wieder an. Der Knoten und seine
  Verbindungen bleiben; die Statistik der Quelle und die gemessene Marge
  beginnen von vorn.
- `AudMidiOutput.sent` zählt die Pakete, die der Ausgang gesendet hat;
  `heldNotes` sind die Noten, die auf dem Port klingen, jede als
  `group << 12 | channel << 8 | note`; `releaseNotes()` sendet für jede
  ein Note-Off. Die Brücke ruft es, wenn der Graph Benachrichtigungen
  verworfen hat, wenn der Ausgang schließt und wenn die Engine freigibt.
- `AudMidiBridge.fixedLatencyNs` ist C mit der kleinsten Marge,
  `baseLatencyNs + marginNs`, die Latenz eines neuen festen Eingangs auf
  einem Port, der nicht Bluetooth ist; `periodNs` und `baseLatencyNs`
  sind P und P + L.
  `AudMidiBridge.streamPeriodNs(sampleRate:, burstFrames:, bufferFrames:)`
  ist die Periode eines Streams: sein Burst, sonst sein Puffer, bei der
  Abtastrate, und 0 ohne Rate - was `periodNs` vor dem ersten Rendern
  ist.

### Die Knoten

Die Port-Knoten auf einem Graphen von `aud_audio_graph`
(`aud_audio_with_midi_ffi.dart` auf nativen Plattformen):

```dart
import 'package:aud_audio_graph/aud_audio_graph_ffi.dart';
import 'package:aud_audio_with_midi/aud_audio_with_midi_ffi.dart';

void main() {
  final graph = AudGraphFfi(maxFrames: 256);
  AudAudioMidi.registerWith(graph.hostApi); // throws AudAudioMidiException
  final keys = graph.createNode(AudMidiInputNode.typeId, name: 'keys');
  final thru = graph.createNode(AudMidiOutputNode.typeId, name: 'thru');
  graph.setString(keys, AudMidiPortNode.portId, 'coremidi:12345');
  graph.setString(keys, AudMidiPortNode.portFingerprint, 'Acme|Keys|SN1|input|0');
  graph.transaction((tx) {
    tx.connectEvents(keys, thru);
    tx.connectEvents(thru, graph.io); // the events reach Dart as notifications
  });
  graph.setParam(thru, AudMidiOutputNode.sysex, 1); // let SysEx through
  graph.start();
}
```

- `aud.midi.input` und `aud.midi.output` haben keine Audio-Busse, den
  Event-Eingang `in` und den Event-Ausgang `out`. Jedes Event des Eingangs
  verlässt den Knoten über den Ausgang an seinem Offset; ein
  Parameter-Event setzt den Parameter, ein Message-Event bleibt bei der
  Engine.
- Beide deklarieren `AUD_NODE_CAP_PASSES_EVENTS` (Ticket 37): Die Engine
  verwirft ihnen kein Note-On, und nach einem Stopp oder einem Prepare
  schließen die Knoten dahinter die Noten, die sie weitergaben, die Engine
  die, die sie aus dem Graphen gaben, mit einem Note-Off pro Note bei
  jedem Empfänger.
- Der Output-Knoten verwirft SysEx (UMP-Typen 3 und 5), solange sein
  boolescher Parameter `sysex` aus ist, da der Notification-Ring, über
  den seine Events reisen, verlustbehaftet ist.
- Beide halten die String-Schlüssel `port_id` und `port_fingerprint` auf
  dem Control-Thread; die Dart-Seite des Graphen persistiert sie im
  Graph-Dokument (`stringsOf`, `toDocument`, `load`). Die C-ABI liest
  keine Strings zurück.
- `aud_audio_with_midi_register(const AudHostApi*)` registriert beide Typen
  (ABI 0.4); `AudAudioMidi.register` übergibt die Funktion der
  Paketliste einer Engine, `AudAudioMidi.registerWith` registriert bei
  einem Graphen.

### Der Parser

- Channel-Voice-Nachrichten werden zu Typ-2-Paketen auf der konfigurierten
  Gruppe, mit Running Status; System-Common-Nachrichten zu Typ-1-Paketen,
  die den Running Status aufheben; Echtzeit-Bytes sofort zu eigenen
  Typ-1-Paketen, auch innerhalb eines SysEx oder zwischen den Bytes einer
  Nachricht.
- SysEx7 wird in Typ-3-Pakete von bis zu 6 Bytes gepackt: complete, oder
  start, continue und end. Der Zustand hält über Chunks hinweg, eine
  Nachricht darf also an jedem Byte geteilt sein.
- Ein Datenbyte ohne Status, eine von einem Statusbyte abgeschnittene
  Nachricht, ein undefiniertes Statusbyte und ein SysEx ohne F7 zählen
  als malformed. Ein SysEx über der Obergrenze wird von dort bis zu seinem
  Ende verworfen; sind Pakete davon schon unterwegs, schließt ein
  End-Paket ohne Daten ihn sofort, so dass ein Empfänger nie ein
  zerrissenes SysEx sieht.

### Der Adapter

Der Adapter auf einer Event-Quelle, aus Dart gefüttert - der native Tap
eines Backends ruft dieselbe Funktion mit `AudMidiAdapter.tapFunction` und
`adapter.address`:

```dart
import 'package:aud_audio_with_midi/aud_audio_with_midi_ffi.dart';

void feed(int source, int push, int release, int size) {
  final adapter = AudMidiAdapter(
    source: source, // the addresses an AudEventSource of the graph offers
    push: push,
    release: release,
    size: size,
    capacity: 4096,
  );
  adapter.pushBytes([0x90, 60, 100], hostTimeNs: 123456789);
  adapter.pushUmp([0x20803C00], hostTimeNs: 123556789);
  adapter.gone(hostTimeNs: 123656789); // the port went: release is raised
  print(adapter.stats); // pushed, rejected, dropped, gone, malformed
  adapter.close(); // synchronous: the tap never touches the source again
  adapter.dispose(); // after the tap detached
}
```

- `aud_audio_with_midi_tap` ist die `AudMidiTapFunction` des Vertrags C2:
  UMP-Wörter gehen Paket für Paket durch, Bytes durch den Parser, GONE
  löst das Release der Quelle aus und vergisst den Running Status und ein
  offenes SysEx; eines, das der UMP-Pfad schon geschoben hat, schließt
  der nächste Datenaufruf mit dem Endpaket des Schnitts.
- Die Halbvoll-Regel: Ein beginnendes SysEx und eine Clock (0xF8) werden
  verworfen, solange die Quelle mehr als die Hälfte ihrer Kapazität hält.
  Die SysEx-Obergrenze und ein von der Quelle abgelehntes Paket verwerfen
  ein SysEx bis zu seinem Ende, auf beiden Wegen.
- `aud_audio_with_midi_adapter_close` ist synchron: Es setzt ein Flag und
  wartet begrenzt auf die laufenden Tap-Aufrufe; danach kehrt der Tap
  sofort zurück. So darf die Engine den Graphen freigeben, bevor das
  asynchrone Lösen des Taps abgeschlossen ist;
  `aud_audio_with_midi_adapter_destroy` folgt nach dem Lösen.
- Die Zähler: pushed, rejected durch die Quelle, SysEx verworfen wegen
  Größe, verworfen wegen Füllstand, gone, malformed, verworfen nach close,
  SysEx abgeschnitten (mit einem End-Paket geschlossen) und zerrissen (das
  End-Paket abgewiesen).
- Der Tap ist als `[[clang::nonblocking]]` markiert, wo der Compiler es
  kennt: keine Allokation, kein Lock, kein Systemaufruf auf dem
  Datenpfad. Datenaufrufe kommen von einem Thread zur Zeit; GONE, close
  und die Statistik dürfen von anderen kommen und berühren nur Atomics.

## Status

Version 0.1.6, vor 1.0 - die API kann sich zwischen Minor-Versionen
ändern. Die Knoten registrieren sich gegen ABI 0.4 von `aud_audio_core`.

## Mitwirken

Tickets laufen über den `gg`-Workflow: siehe den
[Develop Guide](doc/guides/develop-guide.md), den
[Code Guide](doc/guides/code-guide.md), den
[Test Guide](doc/guides/test-guide.md) und den
[Review Guide](doc/guides/for-ai/ai-review-guide.md).

Die Tests ausführen:

```bash
flutter test
node scripts/test-native.js
```

- `flutter test` führt die Dart-Tests aus - die Brücke auf
  `FakeMidiBackend` mit einer Engine auf dem Null-Gerät (beide Wege,
  Timing auf den Frame, Hot-Plug, Ausgänge, Freigabe), die Registrierung
  und die Knoten auf dem Graphen, den Adapter auf einer Fake-Quelle über
  `NativeCallable`, das Web-Kompilat der neutralen Bibliothek, die
  Hinweis-Prüfung - und die nativen Tests.
- `scripts/test-native.js` baut den Parser, den Adapter, die Knoten und
  die Engine von `aud_audio_graph` mit den Address- und
  Undefined-Behaviour-Sanitizern, dem RealtimeSanitizer - mit einer Probe,
  die beweist, dass er eine Allokation auf dem Audio-Thread fängt - und
  dem Thread-Sanitizer, unter dem Watchdog der Engine. `--help` listet die
  Optionen; `AUD_TEST_FILTER` führt die Tests aus, deren Name ihn enthält,
  `AUD_GRAPH_SRC` baut gegen ein anderes `src` des Graphen.

## Lizenz

MIT - siehe [LICENSE](LICENSE).
