# Changelog

## Unreleased

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

## 0.0.2 - 2026-10-08

### Added

- Initial boilerplate

### Changed

- Record the gg commit state
- Set up GitHub repo settings and branch rules
- Update dev dependencies
