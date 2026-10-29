# aud_audio_midi

English | [Deutsch](README.de.md)

[![CI](https://github.com/audaudio/aud_audio_midi/actions/workflows/quick_check.yaml/badge.svg)](https://github.com/audaudio/aud_audio_midi/actions/workflows/quick_check.yaml)

MIDI bridge of the Audanika Audio Engine: aud_midi ports as event inlets
and outlets of the graph.

`AudMidiBridge` binds the ports of a `Midi` to an engine by port id, with
hot-plug; the package holds the port nodes `aud.midi.input` and
`aud.midi.output`, the parser of MIDI 1.0 byte streams into Universal MIDI
Packets and the tap adapter that pushes the MIDI of a port into an event
source of the graph - on the receive thread of the backend or from a Dart
isolate, through one native function. It needs Flutter and runs on the
native platforms. Part of the Audanika Audio Engine; planned in
[aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Motivation

- A MIDI keyboard plays the SFZ sampler on iOS and Android at a constant
  latency of one block plus the output latency (ticket 26, step S8)
- MIDI reaches the audio thread only through the lock-free event sources
  of the graph, never through Dart (interop-001, interop-003)
- One parser for both paths: the native tap of the backends and the Dart
  path share it, so they behave the same
- SysEx and clock never crowd out notes: a SysEx over 64 KiB and SysEx or
  clock while a source is over half full are dropped and counted, a
  dropped SysEx through its end
- Nothing allocates and nothing blocks on the tap path or in the process
  calls of the nodes; the native tests run under ASan/UBSan, the
  RealtimeSanitizer and the ThreadSanitizer

## Installation

The package is not published to pub.dev. Add it as a git dependency to
`pubspec.yaml` and run `flutter pub get`:

```yaml
dependencies:
  aud_audio_midi:
    git:
      url: git@github.com:audaudio/aud_audio_midi.git
      tag_pattern: "{{version}}"
    version: ^0.1.6
```

An app depends on `aud_audio` and registers the package with its engine
(`AudMidiBridge.package`, family-001). The package depends on `aud_audio`
and on `aud_midi`, `aud_midi_core` and `aud_midi_standard` from pub.dev,
so it needs Flutter. The build hook compiles the nodes, the parser and the
adapter with the C++ toolchain of the target against the headers of
`aud_audio_core`.

## Usage

A MIDI keyboard plays an instrument of an engine:

```dart
import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';
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

`example/` is a keyboard-to-synth app, a member of the pub workspace of
this repo: a port of `aud_midi` plays the SFZ sampler of `aud_dsp_sampler`
through `AudMidiBridge`, with a port picker, Bluetooth MIDI, the activity
of the port, the fixed or immediate timing, the measured input to output
time and the numbers of the engine. `midi_test.dart` plays a recorded
performance from a source of the app into the input, `midi_paths_test.dart`
measures the native and the Dart paths of midi-002, and
`midi_keyboard_test.dart` guides a person through playing a real keyboard,
the hot-plug and Bluetooth MIDI:

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

## Limitations

- The bridge, the nodes and the adapter are native: `aud_audio_midi_ffi.dart`
  works on the native platforms only; the neutral library
  `aud_audio_midi.dart` compiles for the web but drives no port there
- A SysEx over 64 KiB (`maxSysexBytes`) is dropped through its end; SysEx
  and clock are dropped while a source holds more than half its capacity
- The output node drops SysEx unless its parameter `sysex` is on, since
  the notification ring its events travel on is lossy
- The C ABI reads no strings back: the port id and fingerprint live on
  the control thread and in the graph document only
- A Bluetooth LE port calibrates its margin up to 30 ms; rarer, longer
  delays play late
- The native tests need Node.js and `clang++`; their RealtimeSanitizer
  build needs a clang that has it, e.g. LLVM from Homebrew on macOS
  (`brew install llvm`), and is skipped without one

## Documentation

- [The plan of ticket 26](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/tickets/2026-10-12-26-bridge-aud-midi-ports-into-the-engine-on-ios-and-android.md)
  with the scope, the budgets and the decisions of the plan review
- The decisions behind the package:
  [midi-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/midi-001.md)
  (UMP as the event format),
  [interop-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/interop-001.md)
  (Dart never runs on the audio thread),
  [abi-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/abi-001.md)
  (the C ABI of the engine),
  [interop-003](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/interop-003.md)
  (event sources for native producers),
  [midi-002](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/midi-002.md)
  (the native tap as the path),
  [midi-003](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/midi-003.md)
  (the fixed latency), and in aud_midi_pm
  [native-001](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/concepts/decisions/native-001.md)
  and
  [ports-001](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/concepts/decisions/ports-001.md)
- The C API: [src/aud_audio_midi.h](src/aud_audio_midi.h); the parser:
  [src/aud_midi_parser.h](src/aud_midi_parser.h)
- The notices: [NOTICES.md](NOTICES.md) - the package holds no
  third-party code
- The blog posts of the changes in [doc/blog](doc/blog)
- The guides in [doc/guides](doc/guides)

## How it works

### The bridge

- `AudMidiBridge(engine, midi)` is an extension of the engine: the engine
  starts its refresh, tells it when its timing starts again and, before
  it disposes the graph, lets it close every adapter synchronously; the
  taps detach afterwards in the background.
- `openInput(port)` creates an `aud.midi.input` node (named after the
  port), an event source for it and an adapter, and attaches a producer:
  the native tap of the backend where it offers one (midi-002), else the
  Dart path, which pushes the packets of `MidiInput.packets` through the
  same adapter with their MIDI time mapped to host time (`AudMidiClock`).
- The timing (midi-003): `fixed` by default - every event sounds at its
  timestamp plus C = P + L + m: P the 99.9th percentile of the render
  gaps (`periodNs`), L the reported output latency, m at least 1 ms and
  the input's own 99.9th percentile of the delivery delay after 1000
  events (`AudMidiInput.marginNs`). C only grows until the timing starts
  again. `immediate` plays an event at the start of the block that
  drains it.
- Hot-plug: a port that goes raises the source's release - note offs,
  sustain and soft pedal off; the node and its connections stay. A port
  that returns under its id plays again; on Android, where a re-plugged
  device gets a new id, the input rebinds to the port with the same
  fingerprint (ports-001). `retarget(port)` moves an input to another
  port.
- `openOutput(port)` creates an `aud.midi.output` node connected to the
  graph's event input; what reaches it leaves through `aud_midi` at the
  time its frame reaches the audio output. When the graph drops
  notifications, the outputs send note offs for what they hold.
- `AudMidiInput.stats`: the source's counters and histograms (delivered,
  late, delivery delay, input to output time), the adapter's counters and
  the input to output time of the events since the last read.

### The API of the bridge

- `AudMidiBridgeOptions`, passed to `AudMidiBridge(engine, midi,
  options:)`: `timing` is the timing of new inputs (`fixed`);
  `preferNative` takes the native tap where the backend offers one
  (true); `capacity` is the events a source holds (4096);
  `maxSysexBytes` the longest SysEx an input passes on (64 KiB);
  `refreshInterval` how often the bridge looks at the engine's timing
  while it runs (1 s). The margin m: `marginNs` is the smallest m (1 ms),
  `marginSamples` the delivered events after which an input takes its own
  99.9th percentile of the delivery delay as m (1000). A Bluetooth LE
  port starts at `bluetoothMarginNs` (15 ms, one connection interval,
  since BLE MIDI carries the sender's timestamps) and calibrates up to
  `bluetoothMarginCapNs` (30 ms); rarer, longer delays play late.
- `AudMidiPath`: `native` - the backend calls the adapter on its receive
  thread - or `dart` - the bridge receives the packets in Dart and pushes
  them through FFI. `openInput(port, path:)` forces one: `native` throws
  a `MidiException` when the backend has no tap instead of falling back,
  `dart` never attaches a tap. Without `path` the input takes the native
  one where offered and `preferNative` is on. `AudMidiInput.path` is the
  path in use, null while the port is gone.
- `AudMidiInput.setTiming(timing)` creates the source again: the producer
  detaches, the source goes and a new one with the new timing takes its
  place, the producer attaches again. The node and its connections stay;
  the source's statistics and the measured margin start over.
- `AudMidiOutput.sent` counts the packets the output sent; `heldNotes`
  is the notes that sound on the port, each as
  `group << 12 | channel << 8 | note`; `releaseNotes()` sends a note off
  for each of them. The bridge calls it when the graph dropped
  notifications, when the output closes and when the engine disposes.
- `AudMidiBridge.fixedLatencyNs` is C with the smallest margin,
  `baseLatencyNs + marginNs`, the latency of a new fixed input on a port
  that is not Bluetooth; `periodNs` and `baseLatencyNs` are P and P + L.
  `AudMidiBridge.streamPeriodNs(sampleRate:, burstFrames:, bufferFrames:)`
  is the period of a stream: its burst, else its buffer, at the sample
  rate, and 0 without a rate - what `periodNs` is before the first
  render.

### The nodes

The port nodes on a graph of `aud_audio_graph` (`aud_audio_midi_ffi.dart`
on native platforms):

```dart
import 'package:aud_audio_graph/aud_audio_graph_ffi.dart';
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';

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

- `aud.midi.input` and `aud.midi.output` have no audio buses, the event
  inlet `in` and the event outlet `out`. Every event of the inlet leaves
  through the outlet at its offset; a parameter event sets the parameter,
  a message event stays with the engine.
- Both declare `AUD_NODE_CAP_PASSES_EVENTS` (ticket 37): the engine
  refuses them no note on, and after a stop or a prepare the nodes behind
  them close the notes they handed on, the engine those they handed out
  of the graph, one note off per note at each receiver.
- The output node drops SysEx (UMP types 3 and 5) unless its boolean
  parameter `sysex` is on, since the notification ring its events travel
  on is lossy.
- Both keep the string keys `port_id` and `port_fingerprint` on the
  control thread; the graph's Dart side persists them in the graph
  document (`stringsOf`, `toDocument`, `load`). The C ABI reads no
  strings back.
- `aud_audio_midi_register(const AudHostApi*)` registers both types
  (ABI 0.4); `AudAudioMidi.register` hands the function to an engine's
  package list, `AudAudioMidi.registerWith` registers with a graph.

### The parser

- Channel voice messages become type 2 packets on the configured group,
  with running status; system common messages type 1 packets that cancel
  running status; real-time bytes type 1 packets of their own at once,
  also inside a SysEx or between the bytes of a message.
- SysEx7 is packed into type 3 packets of up to 6 bytes: complete, or
  start, continue and end. The state holds across chunks, so a message
  may split at any byte.
- A data byte without a status, a message a status byte cuts short, an
  undefined status byte and a SysEx without F7 count as malformed. A
  SysEx over the cap is dropped from there through its end; when packets
  of it left before, an end packet without data closes it at once, so a
  receiver never sees a torn SysEx.

### The adapter

The adapter on an event source, fed from Dart - the native tap of a
backend calls the same function with `AudMidiAdapter.tapFunction` and
`adapter.address`:

```dart
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';

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

- `aud_audio_midi_tap` is the `AudMidiTapFunction` of contract C2: UMP
  words pass through packet by packet, bytes go through the parser, GONE
  raises the source's release and forgets the running status and an open
  SysEx; one the UMP path had pushed closes with the cut end packet at
  the next data call.
- The half-full rule: a SysEx that begins and a clock (0xF8) are dropped
  while the source holds more than half its capacity. The SysEx cap and a
  packet the source refuses drop a SysEx through its end, in both paths.
- `aud_audio_midi_adapter_close` is synchronous: it raises a flag and
  waits for the tap calls in flight, bounded; afterwards the tap returns
  at once. So the engine may dispose the graph before the asynchronous
  detach of the tap completes; `aud_audio_midi_adapter_destroy` follows
  after the detach.
- The counters: pushed, rejected by the source, SysEx dropped by size,
  dropped by fill, gone, malformed, dropped after close, SysEx cut (closed
  with an end packet) and torn (the end packet refused).
- The tap is marked `[[clang::nonblocking]]` where the compiler has it:
  no allocation, no lock, no system call on the data path. Data calls come
  from one thread at a time; GONE, close and the stats may come from
  others and touch atomics only.

## Status

Version 0.1.6, before 1.0 - the API may change between minor versions.
The nodes register against ABI 0.4 of `aud_audio_core`.

## Contributing

Tickets run through the `gg` workflow: see the
[develop guide](doc/guides/develop-guide.md), the
[code guide](doc/guides/code-guide.md), the
[test guide](doc/guides/test-guide.md) and the
[review guide](doc/guides/for-ai/ai-review-guide.md).

Run the tests:

```bash
flutter test
node scripts/test-native.js
```

- `flutter test` runs the Dart tests - the bridge on `FakeMidiBackend`
  with an engine on the null device (both paths, timing to the frame,
  hot-plug, outputs, disposal), the registration and the nodes on the
  graph, the adapter on a fake source through `NativeCallable`, the web
  compile of the neutral library, the notices check - and the native
  tests.
- `scripts/test-native.js` builds the parser, the adapter, the nodes and
  the engine of `aud_audio_graph` with the address and undefined
  behaviour sanitizers, the RealtimeSanitizer - with a probe that proves
  it catches an allocation on the audio thread - and the thread sanitizer,
  under the engine's watchdog. `--help` lists the options;
  `AUD_TEST_FILTER` runs the tests whose name contains it, `AUD_GRAPH_SRC`
  builds against another `src` of the graph.

## License

MIT - see [LICENSE](LICENSE).
