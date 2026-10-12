# Changelog

## Unreleased

### Added

- Add the MIDI port nodes, byte parser and tap adapter

- aud.midi.input and aud.midi.output with the string keys port_id and port_fingerprint, registered through aud_audio_midi_register
- A parser from MIDI 1.0 byte streams to UMP: running status, SysEx7 packets, real-time bytes inside SysEx, caps and the half-full rule
- The adapter: the native tap of aud_midi that pushes into an event source of the graph, with a synchronous close
- A build hook, native tests under ASan/UBSan, RealtimeSanitizer and ThreadSanitizer, Dart wrappers, NOTICES and the notices check

## 0.0.2 - 2026-10-08

### Added

- Initial boilerplate

### Changed

- Record the gg commit state
- Set up GitHub repo settings and branch rules
- Update dev dependencies
