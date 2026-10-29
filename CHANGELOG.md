# Changelog

## Unreleased

### Added

- Add an example app with a MIDI keyboard

## 0.2.0 - 2026-10-28

### Changed

- Require Dart 3.13 and Flutter 3.47, upgrade deps

- Require Dart 3.13 and Flutter 3.47

- Upgrade dna_audanika to ^0.1.0

- Upgrade helix to ^1.14.0

- Set the identity the DNA layers ask for in dna/_vars.json

- Reformat 3 files with the Dart 3.13 formatter

- Add the blog post of this change, in English and German

- Bring the README to the README template, in English and German

- Upgrade aud_midi_standard to 0.2.0

- Lift the lock file to the newest resolvable versions

- Upgrade aud_midi_standard to 0.2.0

- Upgrade aud_midi_standard to 0.2.0

- Lift the lock file to the newest resolvable versions

- Upgrade the git dependencies to their published versions


## 0.1.6 - 2026-10-24

### Changed

- Run the native tests on Windows

## 0.1.5 - 2026-10-22

### Added

- Add AUD_NODE_CAP_PASSES_EVENTS to the MIDI port nodes
- Declare the flag on aud.midi.input and aud.midi.output: after a stop or a prepare each node behind them gets one note off per note, and so does the graph's event input behind the output node
- Let the engine refuse no note on for the nodes behind the input node, also beyond 256 notes
- Test both nodes with recorders on a stop and a start and on a prepare while suspended, a MIDI thru out of the graph, and 280 notes through the input into a channel split
- Document the flag in the header, README.md and README.de.md; regenerate the bindings, which catch up with the header's comment on GONE

## 0.1.4 - 2026-10-15

## 0.1.3 - 2026-10-14

## 0.1.2 - 2026-10-14

## 0.1.1 - 2026-10-13

## 0.1.0 - 2026-10-12

### Added

- Add the MIDI port nodes, byte parser and tap adapter

- aud.midi.input and aud.midi.output with the string keys port_id and port_fingerprint, registered through aud_audio_midi_register

- A parser from MIDI 1.0 byte streams to UMP: running status, SysEx7 packets, real-time bytes inside SysEx, caps and the half-full rule

- The adapter: the native tap of aud_midi that pushes into an event source of the graph, with a synchronous close

- A build hook, native tests under ASan/UBSan, RealtimeSanitizer and ThreadSanitizer, Dart wrappers, NOTICES and the notices check

- Add the MIDI bridge between engines and aud_midi ports

- AudMidiBridge, an extension of the engine: inputs and outputs by port id, the native tap or the Dart path, the fixed or immediate timing with C from the engine's timing (midi-003)

- Hot-plug: a port that goes releases its notes, one that returns plays again, on Android by its fingerprint (ports-001)

- Outputs leave through aud_midi at the time their frame reaches the audio output; dropped notifications release their notes

- AudMidiClock maps aud_midi's time to the engine's host time; statistics per input with the recent input to output time

- A SysEx cut after some of its packets left ends with an end packet; sysexCut and sysexTorn count them

- aud_audio, aud_midi, aud_midi_core and aud_midi_standard as dependencies; the nodes are named after their ports

- Add percentile periods and margins per input

- P is the 99.9th percentile of the render gaps, the stream's burst or buffer before there are any (midi-003)

- m is at least the bridge's margin and the input's own 99.9th percentile of the delivery delay after 1000 events; C only grows between resets

- AudMidiBridge.periodNs, baseLatencyNs, streamPeriodNs; AudMidiInput.marginNs; the margin in the statistics

- Add the margin per transport and the review fixes

- C follows P + L + m both ways; m grows at most to one period, for Bluetooth LE from 15 to 30 ms

- isWaiting covers a port that went offline under its tap; a forced native path fails cleanly; a closed MIDI proxy does not stop close

- GONE closes an open UMP SysEx; the notices check is CommonJS

- README for the bridge

- Add review fixes of ticket 26

- Document the options, AudMidiPath, setTiming, the output members and the latencies in both READMEs

- Let the outputs release their notes when the engine disposes

- Read and build the note words of the outputs with AudUmp of aud_audio_core

- Share _applyLatencies, _releaseNotes and _writeStrings in the bridge; keep the outputs by node handle

- Move _floorNs and _marginOf of the input below the private landmark

- Make _reserve of the adapter void and name its initial buffer size

- Share aud_midi_is_sysex_word of the parser header between the nodes and the adapter

- Derive the close timeout log from kCloseTimeout

- Point check-notices.js to NOTICES.md and license-001

- Nest the bridge tests into groups by member

- Let the detach of the disposal test fail with a MidiPortGone, which the MIDI host swallows

- Add review fixes of ticket 26


## 0.0.2 - 2026-10-08

### Added

- Initial boilerplate

### Changed

- Record the gg commit state
- Set up GitHub repo settings and branch rules
- Update dev dependencies
