// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The MIDI 1.0 byte stream parser: every message type, running status,
// real-time bytes inside messages and SysEx, the SysEx packing and caps,
// garbage, and the chunk boundaries - every stream is also fed split at
// every byte and byte by byte, with the same result.

#include <cstdint>
#include <cstring>
#include <vector>

#include "aud_midi_parser.h"
#include "aud_test.hpp"
#include "aud_ump.h"

namespace {

using Bytes = std::vector<uint8_t>;
using Packet = std::vector<uint32_t>;
using Packets = std::vector<Packet>;

// The sink of a parser under test; `refuseAt` and `refuseAlso` refuse the
// packets with those indices.
struct Sink {
  Packets packets;
  size_t refuseAt = SIZE_MAX;
  size_t refuseAlso = SIZE_MAX;
  size_t calls = 0;

  static int32_t emit(void* user, const uint32_t* words, uint32_t count) {
    Sink& sink = *static_cast<Sink*>(user);
    const size_t index = sink.calls++;
    if (index == sink.refuseAt || index == sink.refuseAlso) return 0;
    sink.packets.emplace_back(words, words + count);
    return 1;
  }
};

struct Parsed {
  Packets packets;
  uint64_t malformed;
  uint64_t droppedSize;
  uint64_t cut;
  uint64_t torn;
  bool operator==(const Parsed& other) const {
    return packets == other.packets && malformed == other.malformed &&
           droppedSize == other.droppedSize && cut == other.cut &&
           torn == other.torn;
  }
};

// Parses `bytes` in the chunks `cuts` delimit.
Parsed parseIn(const Bytes& bytes, const std::vector<size_t>& cuts,
               uint32_t group = 0, uint32_t maxSysex = 0) {
  AudMidiParser parser;
  aud_midi_parser_init(&parser, group, maxSysex);
  Sink sink;
  size_t from = 0;
  for (size_t cut : cuts) {
    aud_midi_parser_feed(&parser, bytes.data() + from,
                         static_cast<uint32_t>(cut - from), Sink::emit, &sink);
    from = cut;
  }
  aud_midi_parser_feed(&parser, bytes.data() + from,
                       static_cast<uint32_t>(bytes.size() - from), Sink::emit,
                       &sink);
  return {sink.packets, parser.malformed, parser.sysex_dropped_size,
          parser.sysex_cut, parser.sysex_torn};
}

// Parses `bytes` in one chunk and checks that every split at one byte and
// the byte-wise feed give the same result.
Parsed parse(const Bytes& bytes, uint32_t group = 0, uint32_t maxSysex = 0) {
  const Parsed whole = parseIn(bytes, {}, group, maxSysex);
  for (size_t cut = 1; cut < bytes.size(); ++cut) {
    AUD_CHECK(parseIn(bytes, {cut}, group, maxSysex) == whole);
  }
  std::vector<size_t> every;
  for (size_t i = 1; i < bytes.size(); ++i) every.push_back(i);
  AUD_CHECK(parseIn(bytes, every, group, maxSysex) == whole);
  return whole;
}

uint32_t midi1(uint32_t status, uint32_t d1, uint32_t d2, uint32_t group = 0) {
  return aud_ump_midi1_word(group, status, d1, d2);
}

uint32_t system(uint32_t status, uint32_t d1 = 0, uint32_t d2 = 0,
                uint32_t group = 0) {
  return (1u << 28) | (group << 24) | (status << 16) | (d1 << 8) | d2;
}

Packet sysex(uint32_t status, const Bytes& bytes, uint32_t group = 0) {
  uint8_t b[6] = {0, 0, 0, 0, 0, 0};
  for (size_t i = 0; i < bytes.size() && i < 6; ++i) b[i] = bytes[i];
  return {(3u << 28) | (group << 24) | (status << 20) |
              (static_cast<uint32_t>(bytes.size()) << 16) |
              (static_cast<uint32_t>(b[0]) << 8) | b[1],
          (static_cast<uint32_t>(b[2]) << 24) |
              (static_cast<uint32_t>(b[3]) << 16) |
              (static_cast<uint32_t>(b[4]) << 8) | b[5]};
}

}  // namespace

// ............................................................................
// Channel voice

AUD_TEST(parser_channel_voice_messages_become_type_2_packets) {
  const Parsed p = parse({0x90, 0x3C, 0x64, 0x80, 0x3C, 0x00, 0xB1, 0x07,
                          0x7F, 0xC2, 0x05, 0xD3, 0x40, 0xA4, 0x3C, 0x20,
                          0xE5, 0x00, 0x40});
  AUD_CHECK(p.packets.size() == 7);
  AUD_CHECK(p.packets[0] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(p.packets[1] == Packet{midi1(0x80, 0x3C, 0x00)});
  AUD_CHECK(p.packets[2] == Packet{midi1(0xB1, 0x07, 0x7F)});
  AUD_CHECK(p.packets[3] == Packet{midi1(0xC2, 0x05, 0)});
  AUD_CHECK(p.packets[4] == Packet{midi1(0xD3, 0x40, 0)});
  AUD_CHECK(p.packets[5] == Packet{midi1(0xA4, 0x3C, 0x20)});
  AUD_CHECK(p.packets[6] == Packet{midi1(0xE5, 0x00, 0x40)});
  AUD_CHECK(p.malformed == 0);
}

AUD_TEST(parser_applies_the_group) {
  const Parsed p = parse({0x90, 0x3C, 0x64, 0xF8, 0xF0, 0x01, 0xF7}, 5);
  AUD_CHECK(p.packets.size() == 3);
  AUD_CHECK(p.packets[0] == Packet{midi1(0x90, 0x3C, 0x64, 5)});
  AUD_CHECK(p.packets[1] == Packet{system(0xF8, 0, 0, 5)});
  AUD_CHECK(p.packets[2] == sysex(AUD_MIDI_SYSEX_COMPLETE, {0x01}, 5));
}

AUD_TEST(parser_keeps_running_status) {
  const Parsed p = parse({0x90, 0x3C, 0x64, 0x3E, 0x64, 0x3C, 0x00, 0xC1,
                          0x01, 0x02});
  AUD_CHECK(p.packets.size() == 5);
  AUD_CHECK(p.packets[1] == Packet{midi1(0x90, 0x3E, 0x64)});
  AUD_CHECK(p.packets[2] == Packet{midi1(0x90, 0x3C, 0x00)});
  AUD_CHECK(p.packets[3] == Packet{midi1(0xC1, 0x01, 0)});
  AUD_CHECK(p.packets[4] == Packet{midi1(0xC1, 0x02, 0)});
  AUD_CHECK(p.malformed == 0);
}

AUD_TEST(parser_ignores_data_bytes_without_status) {
  const Parsed p = parse({0x3C, 0x64, 0x90, 0x3C, 0x64});
  AUD_CHECK(p.packets.size() == 1);
  AUD_CHECK(p.packets[0] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(p.malformed == 2);
}

AUD_TEST(parser_drops_a_message_a_status_byte_cuts_short) {
  const Parsed p = parse({0x90, 0x3C, 0xB0, 0x07, 0x7F});
  AUD_CHECK(p.packets.size() == 1);
  AUD_CHECK(p.packets[0] == Packet{midi1(0xB0, 0x07, 0x7F)});
  AUD_CHECK(p.malformed == 1);
}

// ............................................................................
// System common and real-time

AUD_TEST(parser_system_common_becomes_type_1_and_cancels_running_status) {
  const Parsed p = parse({0x90, 0x3C, 0x64, 0xF1, 0x25, 0xF2, 0x10, 0x20,
                          0xF3, 0x03, 0xF6, 0x3C, 0x64});
  AUD_CHECK(p.packets.size() == 5);
  AUD_CHECK(p.packets[1] == Packet{system(0xF1, 0x25)});
  AUD_CHECK(p.packets[2] == Packet{system(0xF2, 0x10, 0x20)});
  AUD_CHECK(p.packets[3] == Packet{system(0xF3, 0x03)});
  AUD_CHECK(p.packets[4] == Packet{system(0xF6)});
  // The data bytes after F6 have no status any more.
  AUD_CHECK(p.malformed == 2);
}

AUD_TEST(parser_emits_real_time_bytes_at_once_inside_a_message) {
  const Parsed p = parse({0x90, 0xF8, 0x3C, 0xFA, 0x64, 0xFB, 0xFC, 0xFE,
                          0xFF});
  AUD_CHECK(p.packets.size() == 7);
  AUD_CHECK(p.packets[0] == Packet{system(0xF8)});
  AUD_CHECK(p.packets[1] == Packet{system(0xFA)});
  AUD_CHECK(p.packets[2] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(p.packets[3] == Packet{system(0xFB)});
  AUD_CHECK(p.packets[6] == Packet{system(0xFF)});
  AUD_CHECK(p.malformed == 0);
}

AUD_TEST(parser_counts_undefined_status_bytes) {
  // F4 cancels running status, F9 and FD do not.
  const Parsed p = parse({0x90, 0x3C, 0x64, 0xF9, 0x3C, 0x64, 0xFD, 0xF4,
                          0x3C, 0x64, 0xF5, 0xF7});
  AUD_CHECK(p.packets.size() == 2);
  AUD_CHECK(p.packets[1] == Packet{midi1(0x90, 0x3C, 0x64)});
  // F9, FD, F4, two data bytes, F5, F7 without a SysEx.
  AUD_CHECK(p.malformed == 7);
}

// ............................................................................
// SysEx

AUD_TEST(parser_packs_sysex_into_type_3_packets) {
  AUD_CHECK(parse({0xF0, 0xF7}).packets ==
            Packets{sysex(AUD_MIDI_SYSEX_COMPLETE, {})});
  AUD_CHECK(parse({0xF0, 0x7E, 0x7F, 0x09, 0xF7}).packets ==
            Packets{sysex(AUD_MIDI_SYSEX_COMPLETE, {0x7E, 0x7F, 0x09})});
  AUD_CHECK(parse({0xF0, 1, 2, 3, 4, 5, 6, 0xF7}).packets ==
            Packets{sysex(AUD_MIDI_SYSEX_COMPLETE, {1, 2, 3, 4, 5, 6})});
  AUD_CHECK((parse({0xF0, 1, 2, 3, 4, 5, 6, 7, 0xF7}).packets ==
             Packets{sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}),
                     sysex(AUD_MIDI_SYSEX_END, {7})}));
  AUD_CHECK((parse({0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0xF7}).packets ==
             Packets{sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}),
                     sysex(AUD_MIDI_SYSEX_END, {7, 8, 9, 10, 11, 12})}));
  const Parsed p = parse({0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 0xF7});
  AUD_CHECK((p.packets == Packets{sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}),
                                  sysex(AUD_MIDI_SYSEX_CONTINUE,
                                        {7, 8, 9, 10, 11, 12}),
                                  sysex(AUD_MIDI_SYSEX_END, {13})}));
  AUD_CHECK(p.malformed == 0);
}

AUD_TEST(parser_emits_real_time_inside_sysex_without_breaking_it) {
  const Parsed p = parse({0xF0, 1, 2, 0xF8, 3, 4, 5, 6, 7, 0xFE, 0xF7, 0x90,
                          0x3C, 0x64});
  AUD_CHECK(p.packets.size() == 5);
  AUD_CHECK(p.packets[0] == Packet{system(0xF8)});
  AUD_CHECK(p.packets[1] == sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}));
  AUD_CHECK(p.packets[2] == Packet{system(0xFE)});
  AUD_CHECK(p.packets[3] == sysex(AUD_MIDI_SYSEX_END, {7}));
  AUD_CHECK(p.packets[4] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(p.malformed == 0);
}

AUD_TEST(parser_closes_a_sysex_a_status_byte_ends) {
  const Parsed p = parse({0xF0, 1, 2, 0x90, 0x3C, 0x64, 0xF0, 1, 2, 3, 4, 5, 6,
                          7, 0xF6});
  AUD_CHECK(p.packets.size() == 5);
  AUD_CHECK(p.packets[0] == sysex(AUD_MIDI_SYSEX_COMPLETE, {1, 2}));
  AUD_CHECK(p.packets[1] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(p.packets[2] == sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}));
  AUD_CHECK(p.packets[3] == sysex(AUD_MIDI_SYSEX_END, {7}));
  AUD_CHECK(p.packets[4] == Packet{system(0xF6)});
  AUD_CHECK(p.malformed == 2);
}

AUD_TEST(parser_drops_a_sysex_over_the_cap_through_its_end) {
  // The cap of 8: the start packet left before the ninth byte, so the cut
  // closes it with an end packet without data at once, and the rest is
  // dropped; the next SysEx within the cap and the notes are untouched.
  const Parsed p = parse({0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0xF8,
                          13, 0xF7, 0x90, 0x3C, 0x64, 0xF0, 1, 2, 3, 4, 5, 6,
                          7, 8, 0xF7},
                         0, 8);
  AUD_CHECK(p.packets.size() == 6);
  AUD_CHECK(p.packets[0] == sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}));
  AUD_CHECK(p.packets[1] == sysex(AUD_MIDI_SYSEX_END, {}));
  AUD_CHECK(p.packets[2] == Packet{system(0xF8)});
  AUD_CHECK(p.packets[3] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(p.packets[4] == sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}));
  AUD_CHECK(p.packets[5] == sysex(AUD_MIDI_SYSEX_END, {7, 8}));
  AUD_CHECK(p.droppedSize == 1);
  AUD_CHECK(p.cut == 1);
  AUD_CHECK(p.torn == 0);
  AUD_CHECK(p.malformed == 0);
}

AUD_TEST(parser_closes_a_sysex_the_cap_cuts_with_an_empty_end_packet) {
  // The exact words of the end packet: type 3, the group, status end, no
  // bytes - and nothing else of the cut SysEx, at every chunk split.
  const Parsed p = parse({0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
                          15, 16, 17, 18, 19, 20, 0xF7, 0xF0, 1, 0xF7},
                         5, 8);
  AUD_CHECK(p.packets.size() == 3);
  AUD_CHECK(p.packets[0] == sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}, 5));
  AUD_CHECK(p.packets[1] == Packet({0x35300000u, 0u}));
  AUD_CHECK(p.packets[2] == sysex(AUD_MIDI_SYSEX_COMPLETE, {1}, 5));
  AUD_CHECK(p.droppedSize == 1);
  AUD_CHECK(p.cut == 1);
  AUD_CHECK(p.torn == 0);
  // A cap the first packet exceeds: nothing left, so nothing closes it.
  const Parsed q = parse({0xF0, 1, 2, 3, 4, 5, 6, 7, 0xF7, 0x90, 0x3C, 0x64},
                         0, 3);
  AUD_CHECK(q.packets == Packets{Packet{midi1(0x90, 0x3C, 0x64)}});
  AUD_CHECK(q.droppedSize == 1);
  AUD_CHECK(q.cut == 0);
  AUD_CHECK(q.torn == 0);
}

AUD_TEST(parser_drops_the_rest_of_a_sysex_the_sink_refuses) {
  AudMidiParser parser;
  aud_midi_parser_init(&parser, 0, 0);
  Sink sink;
  sink.refuseAt = 1;  // the start packet of the second SysEx
  const Bytes bytes = {0xF0, 1, 0xF7, 0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
                       11, 12, 13, 0xF7, 0x90, 0x3C, 0x64};
  aud_midi_parser_feed(&parser, bytes.data(),
                       static_cast<uint32_t>(bytes.size()), Sink::emit, &sink);
  // The complete packet, the refused start, then the note on only: no
  // packet of the SysEx left, so nothing closes it.
  AUD_CHECK(sink.calls == 3);
  AUD_CHECK(sink.packets.size() == 2);
  AUD_CHECK(sink.packets[0] == sysex(AUD_MIDI_SYSEX_COMPLETE, {1}));
  AUD_CHECK(sink.packets[1] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(parser.malformed == 0);
  AUD_CHECK(parser.sysex_cut == 0);
  AUD_CHECK(parser.sysex_torn == 0);
}

AUD_TEST(parser_closes_a_sysex_the_sink_refuses_mid_way) {
  AudMidiParser parser;
  aud_midi_parser_init(&parser, 0, 0);
  Sink sink;
  sink.refuseAt = 1;  // the continue packet, after the start left
  const Bytes bytes = {0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
                       14, 0xF7, 0x90, 0x3C, 0x64};
  aud_midi_parser_feed(&parser, bytes.data(),
                       static_cast<uint32_t>(bytes.size()), Sink::emit, &sink);
  // The start, the refused continue, the end packet that closes the SysEx,
  // the note on; nothing of the SysEx after the refusal.
  AUD_CHECK(sink.calls == 4);
  AUD_CHECK(sink.packets.size() == 3);
  AUD_CHECK(sink.packets[0] == sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}));
  AUD_CHECK(sink.packets[1] == sysex(AUD_MIDI_SYSEX_END, {}));
  AUD_CHECK(sink.packets[2] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(parser.sysex_cut == 1);
  AUD_CHECK(parser.sysex_torn == 0);
  // The sink refuses the end packet too: the SysEx stays torn, counted.
  Sink torn;
  torn.refuseAt = 1;
  torn.refuseAlso = 2;
  aud_midi_parser_feed(&parser, bytes.data(),
                       static_cast<uint32_t>(bytes.size()), Sink::emit, &torn);
  AUD_CHECK(torn.calls == 4);
  AUD_CHECK(torn.packets.size() == 2);
  AUD_CHECK(torn.packets[0] == sysex(AUD_MIDI_SYSEX_START, {1, 2, 3, 4, 5, 6}));
  AUD_CHECK(torn.packets[1] == Packet{midi1(0x90, 0x3C, 0x64)});
  AUD_CHECK(parser.sysex_cut == 2);
  AUD_CHECK(parser.sysex_torn == 1);
  AUD_CHECK(parser.malformed == 0);
  AUD_CHECK(parser.sysex_dropped_size == 0);
}

AUD_TEST(parser_default_cap_is_64_kib) {
  AudMidiParser parser;
  aud_midi_parser_init(&parser, 0, 0);
  AUD_CHECK(parser.max_sysex_bytes == 65536);
  Bytes bytes(1 + 65536 + 1, 0x01);
  bytes.front() = 0xF0;
  bytes.back() = 0xF7;
  Sink sink;
  aud_midi_parser_feed(&parser, bytes.data(),
                       static_cast<uint32_t>(bytes.size()), Sink::emit, &sink);
  AUD_CHECK(sink.packets.size() == 65536 / 6 + 1);
  AUD_CHECK(parser.sysex_dropped_size == 0);
  bytes.insert(bytes.end() - 1, 0x02);
  aud_midi_parser_feed(&parser, bytes.data(),
                       static_cast<uint32_t>(bytes.size()), Sink::emit, &sink);
  AUD_CHECK(parser.sysex_dropped_size == 1);
  // The byte over the cap cut the SysEx after 10922 full packets: the end
  // packet without data closed it.
  AUD_CHECK(parser.sysex_cut == 1);
  AUD_CHECK(sink.packets.size() == 2 * (65536 / 6 + 1));
  AUD_CHECK(sink.packets.back() == sysex(AUD_MIDI_SYSEX_END, {}));
}

// ............................................................................
// State and robustness

AUD_TEST(parser_reset_forgets_the_running_status_and_the_sysex) {
  AudMidiParser parser;
  aud_midi_parser_init(&parser, 0, 0);
  Sink sink;
  const Bytes head = {0x90, 0x3C, 0x64, 0xF0, 1, 2};
  aud_midi_parser_feed(&parser, head.data(), static_cast<uint32_t>(head.size()),
                       Sink::emit, &sink);
  aud_midi_parser_reset(&parser);
  const Bytes tail = {3, 0xF7, 0x3C, 0x64};
  aud_midi_parser_feed(&parser, tail.data(), static_cast<uint32_t>(tail.size()),
                       Sink::emit, &sink);
  AUD_CHECK(sink.packets.size() == 1);
  AUD_CHECK(sink.packets[0] == Packet{midi1(0x90, 0x3C, 0x64)});
  // 3, F7, 3C, 64 without a status.
  AUD_CHECK(parser.malformed == 4);
  AUD_CHECK(parser.group == 0);
}

AUD_TEST(parser_ignores_null_arguments) {
  aud_midi_parser_init(nullptr, 0, 0);
  aud_midi_parser_reset(nullptr);
  aud_midi_parser_feed(nullptr, nullptr, 0, Sink::emit, nullptr);
  AudMidiParser parser;
  aud_midi_parser_init(&parser, 20, 0);
  AUD_CHECK(parser.group == 4);
  Sink sink;
  aud_midi_parser_feed(&parser, nullptr, 3, Sink::emit, &sink);
  const Bytes bytes = {0x90, 0x3C, 0x64};
  aud_midi_parser_feed(&parser, bytes.data(), 3, nullptr, &sink);
  aud_midi_parser_feed(&parser, bytes.data(), 0, Sink::emit, &sink);
  AUD_CHECK(sink.packets.empty());
}

AUD_TEST(parser_survives_garbage) {
  AudMidiParser parser;
  aud_midi_parser_init(&parser, 0, 100);
  Sink sink;
  uint32_t state = 12345;
  Bytes bytes(200000);
  for (uint8_t& b : bytes) {
    state = state * 1664525u + 1013904223u;
    b = static_cast<uint8_t>(state >> 24);
  }
  size_t from = 0;
  while (from < bytes.size()) {
    state = state * 1664525u + 1013904223u;
    const size_t chunk = 1 + (state >> 24) % 17;
    const size_t to = std::min(bytes.size(), from + chunk);
    aud_midi_parser_feed(&parser, bytes.data() + from,
                         static_cast<uint32_t>(to - from), Sink::emit, &sink);
    from = to;
  }
  AUD_CHECK(!sink.packets.empty());
  AUD_CHECK(parser.malformed > 0);
  for (const Packet& packet : sink.packets) {
    const uint32_t type = aud_ump_message_type(packet[0]);
    AUD_CHECK(type == 1 || type == 2 || type == 3);
    AUD_CHECK(packet.size() == aud_ump_word_count(packet[0]));
    if (type == 3) AUD_CHECK(((packet[0] >> 16) & 0xF) <= 6);
  }
}

AUD_TEST(parser_result_is_the_same_at_every_chunk_boundary) {
  // One stream with everything: the split checks of parse() cover it.
  const Parsed p = parse({0x90, 0x3C, 0x64, 0x3E, 0x40, 0xF8, 0xB0, 0x40,
                          0x7F, 0xF0, 0x7E, 0xF8, 0x7F, 0x09, 0x01, 0x02,
                          0x03, 0x04, 0x05, 0x06, 0x07, 0xF7, 0xC0, 0x05,
                          0xF2, 0x10, 0xFA, 0x20, 0x3C, 0xF0, 1, 2, 3, 4, 5,
                          6, 7, 8, 9, 10, 0xF7, 0xE0, 0x00, 0x40, 0x12, 0xF6,
                          0x90, 0x3C, 0x00},
                         3, 8);
  // Two SysEx over the cap of 8, each closed by an end packet after its
  // start packet; a data byte after F2 cancelled the running status, and
  // F6 cut a pitch bend short.
  AUD_CHECK(p.packets.size() == 15);
  AUD_CHECK(p.droppedSize == 2);
  AUD_CHECK(p.cut == 2);
  AUD_CHECK(p.torn == 0);
  AUD_CHECK(p.malformed == 2);
}
