// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_midi_parser.h"

#include <cstring>

#include "aud_ump.h"

namespace {

constexpr uint32_t kDefaultMaxSysexBytes = 65536;
constexpr uint8_t kSysexPacketBytes = 6;

// The data bytes a status byte expects, or -1 for one that carries none
// and is no message of its own: F0, F7, the undefined ones.
int dataBytesOf(uint8_t status) {
  if (status < 0xC0) return 2;  // 8n, 9n, An, Bn
  if (status < 0xE0) return 1;  // Cn, Dn
  if (status < 0xF0) return 2;  // En
  switch (status) {
    case 0xF1:
    case 0xF3:
      return 1;
    case 0xF2:
      return 2;
    case 0xF6:
      return 0;
    default:
      return -1;
  }
}

bool isRealTime(uint8_t byte) { return byte >= 0xF8; }

// The undefined status bytes, which the stream must not carry.
bool isUndefined(uint8_t byte) {
  return byte == 0xF4 || byte == 0xF5 || byte == 0xF9 || byte == 0xFD;
}

uint32_t systemWord(const AudMidiParser& p, uint8_t status, uint8_t d1,
                    uint8_t d2) {
  return (static_cast<uint32_t>(AUD_UMP_TYPE_SYSTEM) << 28) |
         (p.group << 24) | (static_cast<uint32_t>(status) << 16) |
         (static_cast<uint32_t>(d1) << 8) | d2;
}

void emitOne(uint32_t word, AudMidiParserEmitFunction emit, void* user) {
  emit(user, &word, 1);
}

// ............................................................................
// SysEx

// Cuts the SysEx in progress: the rest of it is dropped through its end.
// When a packet of it left already, an end packet without data closes it
// at once, so the sink sees a closed - short - SysEx; one the sink refuses
// leaves the SysEx torn.
void cutSysex(AudMidiParser& p, AudMidiParserEmitFunction emit, void* user) {
  p.sysex_dropping = 1;
  p.sysex_pending = 0;
  if (!p.sysex_started) return;
  p.sysex_started = 0;
  p.sysex_cut += 1;
  const uint32_t words[2] = {
      (static_cast<uint32_t>(AUD_UMP_TYPE_DATA64) << 28) | (p.group << 24) |
          (static_cast<uint32_t>(AUD_MIDI_SYSEX_END) << 20),
      0};
  if (emit(user, words, 2) == 0) p.sysex_torn += 1;
}

// Emits the buffered SysEx bytes as a packet of `status`; a refusal cuts
// the SysEx.
void flushSysex(AudMidiParser& p, uint32_t status,
                AudMidiParserEmitFunction emit, void* user) {
  const uint8_t* b = p.sysex_buffer;
  uint32_t words[2];
  words[0] = (static_cast<uint32_t>(AUD_UMP_TYPE_DATA64) << 28) |
             (p.group << 24) | (status << 20) |
             (static_cast<uint32_t>(p.sysex_pending) << 16) |
             (static_cast<uint32_t>(b[0]) << 8) | b[1];
  words[1] = (static_cast<uint32_t>(b[2]) << 24) |
             (static_cast<uint32_t>(b[3]) << 16) |
             (static_cast<uint32_t>(b[4]) << 8) | b[5];
  std::memset(p.sysex_buffer, 0, sizeof(p.sysex_buffer));
  p.sysex_pending = 0;
  if (emit(user, words, 2) == 0) {
    cutSysex(p, emit, user);
  } else {
    p.sysex_started = 1;
  }
}

void beginSysex(AudMidiParser& p) {
  p.status = 0;
  p.data_count = 0;
  p.in_sysex = 1;
  p.sysex_dropping = 0;
  p.sysex_started = 0;
  p.sysex_pending = 0;
  p.sysex_bytes = 0;
  std::memset(p.sysex_buffer, 0, sizeof(p.sysex_buffer));
}

void endSysex(AudMidiParser& p, AudMidiParserEmitFunction emit, void* user) {
  if (!p.sysex_dropping) {
    flushSysex(p, p.sysex_started ? AUD_MIDI_SYSEX_END : AUD_MIDI_SYSEX_COMPLETE,
               emit, user);
  }
  p.in_sysex = 0;
  p.sysex_dropping = 0;
  p.sysex_started = 0;
  p.sysex_pending = 0;
  p.sysex_bytes = 0;
}

void sysexData(AudMidiParser& p, uint8_t byte, AudMidiParserEmitFunction emit,
               void* user) {
  if (p.sysex_dropping) return;
  p.sysex_bytes += 1;
  if (p.sysex_bytes > p.max_sysex_bytes) {
    p.sysex_dropped_size += 1;
    cutSysex(p, emit, user);
    return;
  }
  // A full buffer leaves when the next byte arrives, not before: six bytes
  // and F7 make one complete packet.
  if (p.sysex_pending == kSysexPacketBytes) {
    flushSysex(p, p.sysex_started ? AUD_MIDI_SYSEX_CONTINUE : AUD_MIDI_SYSEX_START,
               emit, user);
    if (p.sysex_dropping) return;
  }
  p.sysex_buffer[p.sysex_pending++] = byte;
}

// ............................................................................
// Channel voice and system common

void dataByte(AudMidiParser& p, uint8_t byte, AudMidiParserEmitFunction emit,
              void* user) {
  if (p.status == 0) {
    p.malformed += 1;
    return;
  }
  p.data[p.data_count++] = byte;
  if (p.data_count < dataBytesOf(p.status)) return;
  const uint8_t d2 = p.data_count > 1 ? p.data[1] : 0;
  if (p.status < 0xF0) {
    emitOne(aud_ump_midi1_word(p.group, p.status, p.data[0], d2), emit,
            user);
  } else {
    emitOne(systemWord(p, p.status, p.data[0], d2), emit, user);
    p.status = 0;  // system common holds no running status
  }
  p.data_count = 0;
}

// A status byte that is not real-time: it ends a SysEx in progress and a
// message cut short.
void statusByte(AudMidiParser& p, uint8_t byte, AudMidiParserEmitFunction emit,
                void* user) {
  if (p.in_sysex) {
    endSysex(p, emit, user);
    if (byte != 0xF7) p.malformed += 1;
  }
  if (p.data_count > 0) {
    p.malformed += 1;
    p.data_count = 0;
  }
  if (byte == 0xF0) {
    beginSysex(p);
    return;
  }
  const int needed = dataBytesOf(byte);
  if (needed < 0) {
    // F4 and F5, undefined: no message, but they cancel running status.
    p.malformed += 1;
    p.status = 0;
    return;
  }
  if (needed == 0) {
    emitOne(systemWord(p, byte, 0, 0), emit, user);
    p.status = 0;
    return;
  }
  p.status = byte;
}

}  // namespace

void aud_midi_parser_init(AudMidiParser* parser, uint32_t group,
                          uint32_t max_sysex_bytes) {
  if (parser == nullptr) return;
  std::memset(parser, 0, sizeof(*parser));
  parser->group = group & 0xF;
  parser->max_sysex_bytes =
      max_sysex_bytes == 0 ? kDefaultMaxSysexBytes : max_sysex_bytes;
}

void aud_midi_parser_reset(AudMidiParser* parser) {
  if (parser == nullptr) return;
  parser->status = 0;
  parser->data_count = 0;
  parser->in_sysex = 0;
  parser->sysex_dropping = 0;
  parser->sysex_started = 0;
  parser->sysex_pending = 0;
  parser->sysex_bytes = 0;
}

void aud_midi_parser_feed(AudMidiParser* parser, const uint8_t* bytes,
                          uint32_t count, AudMidiParserEmitFunction emit,
                          void* user) {
  if (parser == nullptr || emit == nullptr || (bytes == nullptr && count > 0)) {
    return;
  }
  AudMidiParser& p = *parser;
  for (uint32_t i = 0; i < count; ++i) {
    const uint8_t byte = bytes[i];
    if (byte < 0x80) {
      if (p.in_sysex) {
        sysexData(p, byte, emit, user);
      } else {
        dataByte(p, byte, emit, user);
      }
    } else if (isRealTime(byte)) {
      if (isUndefined(byte)) {
        p.malformed += 1;
      } else {
        emitOne(systemWord(p, byte, 0, 0), emit, user);
      }
    } else if (byte == 0xF7) {
      if (p.in_sysex) {
        endSysex(p, emit, user);
      } else {
        p.malformed += 1;
      }
      p.status = 0;
      p.data_count = 0;
    } else {
      statusByte(p, byte, emit, user);
    }
  }
}
