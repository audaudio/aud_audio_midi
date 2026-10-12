# aud_audio_midi

The MIDI bridge of the Audanika Audio Engine: the ports of the `aud_midi`
family become event inlets and outlets of the graph of `aud_audio`. The
package holds the port nodes `aud.midi.input` and `aud.midi.output`, the
parser of MIDI 1.0 byte streams into Universal MIDI Packets and the tap
adapter that pushes the MIDI of a port into an event source of the graph -
on the receive thread of the backend or from a Dart isolate, through one
native function.

Part of the Audanika Audio Engine; planned in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Goals

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

```yaml
dependencies:
  aud_audio_midi:
    git:
      url: git@github.com:audaudio/aud_audio_midi.git
      tag_pattern: '{{version}}'
    version: ^0.1.0
```

An app depends on `aud_audio` and registers the package with its engine
(family-001). The build hook compiles the nodes, the parser and the adapter
with the C++ toolchain of the target against the headers of
`aud_audio_core`; the package itself needs no Flutter. The native tests
need Node.js and `clang++`; their RealtimeSanitizer build needs a clang
that has it, e.g. LLVM from Homebrew on macOS (`brew install llvm`), and
is skipped without one.

## Documentation

- [The plan of ticket 26](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/tickets/2026-10-12-26-bridge-aud-midi-ports-into-the-engine-on-ios-and-android.md)
  with the scope, the budgets and the decisions of the plan review
- The decisions behind the package:
  [midi-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/midi-001.md)
  (UMP as the event format),
  [interop-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/interop-001.md)
  (Dart never runs on the audio thread),
  [abi-001](https://github.com/audaudio/aud_audio_pm/blob/main/doc/2026-Q4/concepts/decisions/abi-001.md)
  (the C ABI of the engine)
- The C API: [`src/aud_audio_midi.h`](src/aud_audio_midi.h); the parser:
  [`src/aud_midi_parser.h`](src/aud_midi_parser.h)
- The notices: [`NOTICES.md`](NOTICES.md) - the package holds no
  third-party code
- The guides in [`doc/guides`](doc/guides)

## Code Examples

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

## How It Works

### The nodes

- `aud.midi.input` and `aud.midi.output` have no audio buses, the event
  inlet `in` and the event outlet `out`. Every event of the inlet leaves
  through the outlet at its offset; a parameter event sets the parameter,
  a message event stays with the engine.
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
  SysEx over the cap is dropped from there through its end; the packets
  that left before stay pushed.

### The adapter

- `aud_audio_midi_tap` is the `AudMidiTapFunction` of contract C2: UMP
  words pass through packet by packet, bytes go through the parser, GONE
  raises the source's release and forgets the running status.
- The half-full rule: a SysEx that begins and a clock (0xF8) are dropped
  while the source holds more than half its capacity. The SysEx cap and a
  packet the source refuses drop a SysEx through its end, in both paths.
- `aud_audio_midi_adapter_close` is synchronous: it raises a flag and
  waits for the tap calls in flight, bounded; afterwards the tap returns
  at once. So the engine may dispose the graph before the asynchronous
  detach of the tap completes; `aud_audio_midi_adapter_destroy` follows
  after the detach.
- The counters: pushed, rejected by the source, SysEx dropped by size,
  dropped by fill, gone, malformed, dropped after close.
- The tap is marked `[[clang::nonblocking]]` where the compiler has it:
  no allocation, no lock, no system call on the data path. Data calls come
  from one thread at a time; GONE, close and the stats may come from
  others and touch atomics only.

### Tests

```bash
dart test
node scripts/test-native.js
```

- `dart test` runs the Dart tests - the registration and the nodes on the
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

## Contributing

Tickets run through the `gg` workflow: see the
[Develop Guide](doc/guides/develop-guide.md) and the
[Review Guide](doc/guides/for-ai/ai-review-guide.md).
