# aud_audio_midi

Die MIDI-Brücke der Audanika Audio Engine: Die Ports der `aud_midi`-Familie
werden zu Event-Eingängen und -Ausgängen des Graphen von `aud_audio`.
`AudMidiBridge` bindet die Ports eines `Midi` über ihre Port-ID an eine
Engine, mit Hot-Plug; das Paket enthält die Port-Knoten `aud.midi.input` und `aud.midi.output`, den
Parser von MIDI-1.0-Bytestrom zu Universal MIDI Packets und den
Tap-Adapter, der das MIDI eines Ports in eine Event-Quelle des Graphen
schiebt - auf dem Empfangs-Thread des Backends oder aus einem Dart-Isolate,
über eine einzige native Funktion.

Teil der Audanika Audio Engine; geplant in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Ziele

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

```yaml
dependencies:
  aud_audio_midi:
    git:
      url: git@github.com:audaudio/aud_audio_midi.git
      tag_pattern: '{{version}}'
    version: ^0.1.0
```

Eine App hängt von `aud_audio` ab und registriert das Paket bei ihrer
Engine (`AudMidiBridge.package`, family-001). Das Paket hängt von
`aud_audio` und von `aud_midi`, `aud_midi_core` und `aud_midi_standard`
aus pub.dev ab und braucht daher Flutter. Der Build-Hook kompiliert die
Knoten, den Parser und den Adapter mit der C++-Toolchain des Ziels gegen
die Header von `aud_audio_core`. Die nativen Tests
brauchen Node.js und `clang++`; ihr RealtimeSanitizer-Build braucht ein
clang, das ihn hat, z. B. LLVM aus Homebrew auf macOS (`brew install
llvm`), und wird ohne eines übersprungen.

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
- Die C-API: [`src/aud_audio_midi.h`](src/aud_audio_midi.h); der Parser:
  [`src/aud_midi_parser.h`](src/aud_midi_parser.h)
- Die Hinweise: [`NOTICES.md`](NOTICES.md) - das Paket enthält keinen
  Fremdcode
- Die Guides in [`doc/guides`](doc/guides)

## Code-Beispiele

Ein MIDI-Keyboard spielt ein Instrument einer Engine:

```dart
import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';
import 'package:aud_midi/aud_midi.dart';

Future<void> play(AudNode instrument, AudEngine engine) async {
  // Die Engine wurde mit AudMidiBridge.package in ihren Paketen erzeugt.
  final midi = await Midi.open();
  final bridge = AudMidiBridge(engine, midi); // eine Erweiterung der Engine
  final keyboard = bridge.inputPorts.first;
  final input = await bridge.openInput(keyboard); // nativer Tap, wo angeboten
  engine.graph.transaction(
    (tx) => tx.connectEvents(input.node, instrument),
  );
  engine.start();
  // Später: das Timing und was ankam.
  final stats = input.stats;
  print('C ${stats.latencyNs / 1e6} ms, late ${stats.source.late}');
}
```

Die Port-Knoten auf einem Graphen von `aud_audio_graph`
(`aud_audio_midi_ffi.dart` auf nativen Plattformen):

```dart
import 'package:aud_audio_graph/aud_audio_graph_ffi.dart';
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';

void main() {
  final graph = AudGraphFfi(maxFrames: 256);
  AudAudioMidi.registerWith(graph.hostApi); // wirft AudAudioMidiException
  final keys = graph.createNode(AudMidiInputNode.typeId, name: 'keys');
  final thru = graph.createNode(AudMidiOutputNode.typeId, name: 'thru');
  graph.setString(keys, AudMidiPortNode.portId, 'coremidi:12345');
  graph.setString(keys, AudMidiPortNode.portFingerprint, 'Acme|Keys|SN1|input|0');
  graph.transaction((tx) {
    tx.connectEvents(keys, thru);
    tx.connectEvents(thru, graph.io); // die Events erreichen Dart als Notifications
  });
  graph.setParam(thru, AudMidiOutputNode.sysex, 1); // SysEx durchlassen
  graph.start();
}
```

Der Adapter auf einer Event-Quelle, aus Dart gefüttert - der native Tap
eines Backends ruft dieselbe Funktion mit `AudMidiAdapter.tapFunction` und
`adapter.address`:

```dart
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';

void feed(int source, int push, int release, int size) {
  final adapter = AudMidiAdapter(
    source: source, // die Adressen, die eine AudEventSource des Graphen bietet
    push: push,
    release: release,
    size: size,
    capacity: 4096,
  );
  adapter.pushBytes([0x90, 60, 100], hostTimeNs: 123456789);
  adapter.pushUmp([0x20803C00], hostTimeNs: 123556789);
  adapter.gone(hostTimeNs: 123656789); // der Port ist weg: Release wird ausgelöst
  print(adapter.stats); // pushed, rejected, dropped, gone, malformed
  adapter.close(); // synchron: der Tap berührt die Quelle nie wieder
  adapter.dispose(); // nachdem der Tap gelöst wurde
}
```

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

### Die Knoten

- `aud.midi.input` und `aud.midi.output` haben keine Audio-Busse, den
  Event-Eingang `in` und den Event-Ausgang `out`. Jedes Event des Eingangs
  verlässt den Knoten über den Ausgang an seinem Offset; ein
  Parameter-Event setzt den Parameter, ein Message-Event bleibt bei der
  Engine.
- Der Output-Knoten verwirft SysEx (UMP-Typen 3 und 5), solange sein
  boolescher Parameter `sysex` aus ist, da der Notification-Ring, über
  den seine Events reisen, verlustbehaftet ist.
- Beide halten die String-Schlüssel `port_id` und `port_fingerprint` auf
  dem Control-Thread; die Dart-Seite des Graphen persistiert sie im
  Graph-Dokument (`stringsOf`, `toDocument`, `load`). Die C-ABI liest
  keine Strings zurück.
- `aud_audio_midi_register(const AudHostApi*)` registriert beide Typen
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

- `aud_audio_midi_tap` ist die `AudMidiTapFunction` des Vertrags C2:
  UMP-Wörter gehen Paket für Paket durch, Bytes durch den Parser, GONE
  löst das Release der Quelle aus und vergisst den Running Status und ein
  offenes SysEx; eines, das der UMP-Pfad schon geschoben hat, schließt
  der nächste Datenaufruf mit dem Endpaket des Schnitts.
- Die Halbvoll-Regel: Ein beginnendes SysEx und eine Clock (0xF8) werden
  verworfen, solange die Quelle mehr als die Hälfte ihrer Kapazität hält.
  Die SysEx-Obergrenze und ein von der Quelle abgelehntes Paket verwerfen
  ein SysEx bis zu seinem Ende, auf beiden Wegen.
- `aud_audio_midi_adapter_close` ist synchron: Es setzt ein Flag und
  wartet begrenzt auf die laufenden Tap-Aufrufe; danach kehrt der Tap
  sofort zurück. So darf die Engine den Graphen freigeben, bevor das
  asynchrone Lösen des Taps abgeschlossen ist;
  `aud_audio_midi_adapter_destroy` folgt nach dem Lösen.
- Die Zähler: pushed, rejected durch die Quelle, SysEx verworfen wegen
  Größe, verworfen wegen Füllstand, gone, malformed, verworfen nach close,
  SysEx abgeschnitten (mit einem End-Paket geschlossen) und zerrissen (das
  End-Paket abgewiesen).
- Der Tap ist als `[[clang::nonblocking]]` markiert, wo der Compiler es
  kennt: keine Allokation, kein Lock, kein Systemaufruf auf dem
  Datenpfad. Datenaufrufe kommen von einem Thread zur Zeit; GONE, close
  und die Statistik dürfen von anderen kommen und berühren nur Atomics.

### Tests

```bash
flutter test
node scripts/test-native.js
```

- `flutter test` führt die Dart-Tests aus - die Brücke auf
  `FakeMidiBackend` mit einer Engine auf dem Null-Gerät (beide Wege,
  Timing auf den Frame, Hot-Plug, Ausgänge, Freigabe), die Registrierung
  und die Knoten
  auf dem Graphen, den Adapter auf einer Fake-Quelle über
  `NativeCallable`, das Web-Kompilat der neutralen Bibliothek, die
  Hinweis-Prüfung - und die nativen Tests.
- `scripts/test-native.js` baut den Parser, den Adapter, die Knoten und
  die Engine von `aud_audio_graph` mit den Address- und
  Undefined-Behaviour-Sanitizern, dem RealtimeSanitizer - mit einer Probe,
  die beweist, dass er eine Allokation auf dem Audio-Thread fängt - und
  dem Thread-Sanitizer, unter dem Watchdog der Engine. `--help` listet die
  Optionen; `AUD_TEST_FILTER` führt die Tests aus, deren Name ihn enthält,
  `AUD_GRAPH_SRC` baut gegen ein anderes `src` des Graphen.

## Mitwirken

Tickets laufen über den `gg`-Workflow: siehe den
[Develop Guide](doc/guides/develop-guide.md) und den
[Review Guide](doc/guides/for-ai/ai-review-guide.md).
