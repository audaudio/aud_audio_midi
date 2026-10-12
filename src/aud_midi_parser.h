// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The parser of a MIDI 1.0 byte stream into Universal MIDI Packets (ticket
// 26, scope 5): one per port, fed chunk by chunk, with its state kept
// across the chunks, so a message may split at any byte. Internal to the
// package; the adapter of aud_audio_midi.h owns one per port.
//
// - Channel voice messages become type 2 packets (MIDI 1.0 protocol) on
//   the configured group; running status holds until a status byte that
//   is not real-time cancels it. A data byte without a status is thrown
//   away and counted as malformed, as is a message a new status byte cuts
//   short.
// - System common messages (F1, F2, F3, F6) become type 1 packets and
//   cancel running status; the undefined F4 and F5 count as malformed.
// - Real-time bytes (F8, FA, FB, FC, FE, FF) become type 1 packets of
//   their own at once, also inside a SysEx or between the bytes of a
//   message, which they do not disturb; the undefined F9 and FD count as
//   malformed.
// - SysEx7 (F0 ... F7) is packed into type 3 packets of up to 6 bytes:
//   complete, or start, continue and end. A SysEx that grows over the cap
//   is dropped from there through its end and counted, and so is one whose
//   packet the sink refuses. When a packet of the SysEx left before the
//   cut, the cut closes it at once with an end packet without data
//   (counted as cut): the sink always sees a closed SysEx, short when it
//   was cut. Only when the sink refuses that end packet too does a torn
//   SysEx remain (counted as torn). A SysEx a status byte other than F7
//   ends is closed with what it holds and counts as malformed.
//
// Nothing allocates: the state is the struct, the parser is realtime safe.

#ifndef AUD_MIDI_PARSER_H
#define AUD_MIDI_PARSER_H

#include <stdint.h>

#include "aud_ump.h"

#ifdef __cplusplus
extern "C" {
#endif

// The status nibbles of a type 3 packet.
enum {
  AUD_MIDI_SYSEX_COMPLETE = 0,
  AUD_MIDI_SYSEX_START = 1,
  AUD_MIDI_SYSEX_CONTINUE = 2,
  AUD_MIDI_SYSEX_END = 3,
};

// Whether the packet that starts with `word0` is a SysEx: a 64-bit data
// message (SysEx7) or a 128-bit one (SysEx8).
static inline int aud_midi_is_sysex_word(uint32_t word0) {
  const uint32_t type = aud_ump_message_type(word0);
  return type == AUD_UMP_TYPE_DATA64 || type == AUD_UMP_TYPE_DATA128;
}

// The sink of the parser: one packet of `count` words. Returns nonzero when
// it took the packet; a refused SysEx packet drops the rest of its SysEx,
// after the end packet that closes it when an earlier packet of it was
// taken.
typedef int32_t (*AudMidiParserEmitFunction)(void* user, const uint32_t* words,
                                             uint32_t count);

// The parser; aud_midi_parser_init fills it, nothing else reads its fields.
typedef struct AudMidiParser {
  uint32_t group;
  uint32_t max_sysex_bytes;
  // The status whose data bytes are expected, 0 for none; channel voice
  // status bytes hold as running status, system common ones for one
  // message.
  uint8_t status;
  uint8_t data_count;
  uint8_t data[2];
  uint8_t in_sysex;
  uint8_t sysex_dropping;
  uint8_t sysex_started;  // a start packet left already
  uint8_t sysex_pending;  // bytes waiting in the buffer
  uint8_t sysex_buffer[6];
  uint32_t sysex_bytes;  // bytes of the current SysEx
  // The counters: data bytes without a status, messages cut short,
  // undefined status bytes, SysEx without F7; SysEx dropped for their
  // size; SysEx closed short with an end packet after a packet of theirs
  // left; of those, the ones whose end packet the sink refused.
  uint64_t malformed;
  uint64_t sysex_dropped_size;
  uint64_t sysex_cut;
  uint64_t sysex_torn;
} AudMidiParser;

// Fills a parser for `group` with a cap of `max_sysex_bytes` (0: 65536).
void aud_midi_parser_init(AudMidiParser* parser, uint32_t group,
                          uint32_t max_sysex_bytes);

// Forgets the running status and the SysEx in progress; the counters
// stay. For a port that comes back after it was gone.
void aud_midi_parser_reset(AudMidiParser* parser);

// Feeds `count` bytes; every packet they complete reaches `emit`.
void aud_midi_parser_feed(AudMidiParser* parser, const uint8_t* bytes,
                          uint32_t count, AudMidiParserEmitFunction emit,
                          void* user);

#ifdef __cplusplus
}
#endif

#endif  // AUD_MIDI_PARSER_H
