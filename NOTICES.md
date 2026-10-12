# Notices of aud_audio_midi

The package holds no third-party code: the port nodes, the MIDI 1.0 byte
parser and the tap adapter in `src/` are Audanika's own, under the license
in `LICENSE`. It includes the headers of `aud_audio_core` and never links
the core or the graph (interop-001, build-001).

`node scripts/check-notices.js` checks the convention of decision
license-001: every source file carries the license header, and a
`src/third_party` directory, should one come, needs a `NOTICES.md` with a
permissive license per component.
