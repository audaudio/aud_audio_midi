// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The tap adapter on a fake event source: UMP pass-through with the SysEx
// caps, the byte path, the half-full rule, GONE, the counters, close, and
// the threads - the producer, GONE from a second thread, close from the
// control thread - under the thread sanitizer. The tap is nonblocking, so
// the rtsan build checks every call here.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

#include "aud_audio_midi.h"
#include "aud_midi_parser.h"
#include "aud_test.hpp"
#include "aud_ump.h"

namespace {

// A packet the fake source took.
struct Pushed {
  uint32_t words[4];
  uint32_t count;
  int64_t time;
};

// The fake event source: a fixed table of packets (nothing allocates on
// the tap path), a size the test sets, a refusal switch and a count of
// pushes to refuse as if the queue were full, the releases, and a `dead`
// flag the test raises after close - a push that finds it set is a
// violation of the close guarantee.
struct FakeSource {
  static constexpr uint32_t kCapacity = 1 << 16;
  Pushed packets[kCapacity];
  std::atomic<uint32_t> count{0};
  std::atomic<uint32_t> size{0};
  std::atomic<int32_t> pushResult{AUD_OK};
  std::atomic<uint32_t> refuseNext{0};
  std::atomic<uint32_t> pushCalls{0};
  std::atomic<uint32_t> releases{0};
  bool dead = false;
  std::atomic<uint32_t> violations{0};

  static int32_t push(AudEventSource* source, const uint32_t* words,
                      uint32_t count, int64_t time) {
    FakeSource& s = *reinterpret_cast<FakeSource*>(source);
    if (s.dead) s.violations.fetch_add(1, std::memory_order_relaxed);
    s.pushCalls.fetch_add(1, std::memory_order_relaxed);
    const int32_t result = s.pushResult.load(std::memory_order_relaxed);
    if (result != AUD_OK) return result;
    if (s.refuseNext.load(std::memory_order_relaxed) > 0) {
      s.refuseNext.fetch_sub(1, std::memory_order_relaxed);
      return AUD_ERROR_QUEUE_FULL;
    }
    const uint32_t index = s.count.load(std::memory_order_relaxed);
    if (index >= kCapacity) return AUD_ERROR_QUEUE_FULL;
    Pushed& p = s.packets[index];
    p.count = count;
    p.time = time;
    for (uint32_t i = 0; i < 4; ++i) p.words[i] = i < count ? words[i] : 0;
    s.count.store(index + 1, std::memory_order_release);
    return AUD_OK;
  }
  static void release(AudEventSource* source) {
    FakeSource& s = *reinterpret_cast<FakeSource*>(source);
    if (s.dead) s.violations.fetch_add(1, std::memory_order_relaxed);
    s.releases.fetch_add(1, std::memory_order_relaxed);
  }
  static uint32_t sizeOf(const AudEventSource* source) {
    const FakeSource& s = *reinterpret_cast<const FakeSource*>(source);
    return s.size.load(std::memory_order_relaxed);
  }

  uint32_t pushed() const { return count.load(std::memory_order_acquire); }
  const Pushed& at(uint32_t index) const { return packets[index]; }
};

// Large; one per process, reset per fixture.
FakeSource& fakeSource() {
  static FakeSource source;
  return source;
}

AudMidiAdapterConfig configOf(FakeSource& source, uint32_t capacity = 16,
                              uint32_t maxSysex = 0, uint32_t group = 0) {
  AudMidiAdapterConfig config{};
  config.struct_size = sizeof(AudMidiAdapterConfig);
  config.group = group;
  config.max_sysex_bytes = maxSysex;
  config.capacity = capacity;
  config.source = &source;
  config.push = FakeSource::push;
  config.release = FakeSource::release;
  config.size = FakeSource::sizeOf;
  return config;
}

struct Fixture {
  FakeSource& source = fakeSource();
  AudMidiAdapter* adapter = nullptr;

  explicit Fixture(uint32_t capacity = 16, uint32_t maxSysex = 0,
                   uint32_t group = 0) {
    source.count.store(0);
    source.size.store(0);
    source.pushResult.store(AUD_OK);
    source.refuseNext.store(0);
    source.pushCalls.store(0);
    source.releases.store(0);
    source.dead = false;
    source.violations.store(0);
    const AudMidiAdapterConfig config =
        configOf(source, capacity, maxSysex, group);
    adapter = aud_audio_midi_adapter_create(&config);
    AUD_CHECK(adapter != nullptr);
  }
  ~Fixture() { aud_audio_midi_adapter_destroy(adapter); }

  void ump(const std::vector<uint32_t>& words, int64_t time = 1000) {
    aud_audio_midi_tap(adapter, AUD_MIDI_TAP_UMP, words.data(),
                       static_cast<uint32_t>(words.size()), time);
  }
  void bytes(const std::vector<uint8_t>& data, int64_t time = 1000) {
    aud_audio_midi_tap(adapter, AUD_MIDI_TAP_BYTES, data.data(),
                       static_cast<uint32_t>(data.size()), time);
  }
  void gone(int64_t time = 1000) {
    aud_audio_midi_tap(adapter, AUD_MIDI_TAP_GONE, nullptr, 0, time);
  }
  AudMidiAdapterStats stats() const {
    AudMidiAdapterStats result{};
    result.struct_size = sizeof(AudMidiAdapterStats);
    AUD_CHECK(aud_audio_midi_adapter_stats(adapter, &result) == AUD_OK);
    return result;
  }
};

uint32_t midi1(uint32_t status, uint32_t d1, uint32_t d2, uint32_t group = 0) {
  return aud_ump_midi1_word(group, status, d1, d2);
}

uint32_t system(uint32_t status, uint32_t group = 0) {
  return (1u << 28) | (group << 24) | (status << 16);
}

// The first word of a type 3 (or 5) SysEx packet with `bytes` bytes.
uint32_t sysex(uint32_t status, uint32_t bytes, uint32_t type = 3) {
  return (type << 28) | (status << 20) | (bytes << 16);
}

// The first word of a type 5 SysEx8 packet on `group` with `bytes` bytes,
// the stream id among them.
uint32_t sysex8(uint32_t status, uint32_t bytes, uint32_t streamId,
                uint32_t group) {
  return (5u << 28) | (group << 24) | (status << 20) | (bytes << 16) |
         (streamId << 8);
}

// A MIDI 2.0 note on: two words.
std::vector<uint32_t> midi2NoteOn() {
  uint32_t words[2];
  aud_ump_midi2_note(0, 0, 1, 60, 0x8000, 0, 0, words);
  return {words[0], words[1]};
}

}  // namespace

// ............................................................................
// Creation and stats

AUD_TEST(adapter_create_refuses_a_bad_config) {
  FakeSource& source = fakeSource();
  AUD_CHECK(aud_audio_midi_adapter_create(nullptr) == nullptr);
  AudMidiAdapterConfig config = configOf(source);
  config.struct_size = 8;
  AUD_CHECK(aud_audio_midi_adapter_create(&config) == nullptr);
  config = configOf(source);
  config.source = nullptr;
  AUD_CHECK(aud_audio_midi_adapter_create(&config) == nullptr);
  config = configOf(source);
  config.push = nullptr;
  AUD_CHECK(aud_audio_midi_adapter_create(&config) == nullptr);
  config = configOf(source);
  config.release = nullptr;
  AUD_CHECK(aud_audio_midi_adapter_create(&config) == nullptr);
  config = configOf(source);
  config.group = 16;
  AUD_CHECK(aud_audio_midi_adapter_create(&config) == nullptr);
  // Without a size function the half-full rule is off.
  config = configOf(source);
  config.size = nullptr;
  AudMidiAdapter* adapter = aud_audio_midi_adapter_create(&config);
  AUD_CHECK(adapter != nullptr);
  source.size.store(1000);
  source.count.store(0);
  const uint32_t clock = system(0xF8);
  aud_audio_midi_tap(adapter, AUD_MIDI_TAP_UMP, &clock, 1, 1);
  AUD_CHECK(source.pushed() == 1);
  aud_audio_midi_adapter_destroy(adapter);
  aud_audio_midi_adapter_destroy(nullptr);
}

AUD_TEST(adapter_stats_refuses_bad_arguments) {
  Fixture f;
  AudMidiAdapterStats stats{};
  stats.struct_size = sizeof(AudMidiAdapterStats);
  AUD_CHECK(aud_audio_midi_adapter_stats(nullptr, &stats) ==
            AUD_ERROR_INVALID_ARGUMENT);
  AUD_CHECK(aud_audio_midi_adapter_stats(f.adapter, nullptr) ==
            AUD_ERROR_INVALID_ARGUMENT);
  stats.struct_size = 8;
  AUD_CHECK(aud_audio_midi_adapter_stats(f.adapter, &stats) ==
            AUD_ERROR_INVALID_ARGUMENT);
  const AudMidiAdapterStats zero = f.stats();
  AUD_CHECK(zero.pushed == 0 && zero.rejected == 0 && zero.gone == 0);
}

// ............................................................................
// UMP pass-through

AUD_TEST(adapter_passes_ump_packets_through_with_their_time) {
  Fixture f;
  const std::vector<uint32_t> two = midi2NoteOn();
  f.ump({midi1(0x90, 60, 100), two[0], two[1], system(0xF8)}, 777);
  AUD_CHECK(f.source.pushed() == 3);
  AUD_CHECK(f.source.at(0).count == 1);
  AUD_CHECK(f.source.at(0).words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(f.source.at(0).time == 777);
  AUD_CHECK(f.source.at(1).count == 2);
  AUD_CHECK(f.source.at(1).words[1] == two[1]);
  AUD_CHECK(f.source.at(2).words[0] == system(0xF8));
  AUD_CHECK(f.stats().pushed == 3);
  AUD_CHECK(f.stats().malformed == 0);
}

AUD_TEST(adapter_counts_a_truncated_ump_packet) {
  Fixture f;
  const std::vector<uint32_t> two = midi2NoteOn();
  f.ump({midi1(0x90, 60, 100), two[0]});
  AUD_CHECK(f.source.pushed() == 1);
  AUD_CHECK(f.stats().malformed == 1);
  f.ump({});
  aud_audio_midi_tap(f.adapter, AUD_MIDI_TAP_UMP, nullptr, 2, 1);
  aud_audio_midi_tap(f.adapter, 99, nullptr, 0, 1);
  aud_audio_midi_tap(nullptr, AUD_MIDI_TAP_UMP, nullptr, 0, 1);
  AUD_CHECK(f.stats().malformed == 3);
}

AUD_TEST(adapter_counts_what_the_source_refuses) {
  Fixture f;
  f.source.pushResult.store(AUD_ERROR_QUEUE_FULL);
  f.ump({midi1(0x90, 60, 100)});
  f.source.pushResult.store(AUD_ERROR_INVALID_ARGUMENT);
  f.bytes({0x90, 60, 100});
  AUD_CHECK(f.stats().rejected == 2);
  AUD_CHECK(f.stats().pushed == 0);
}

AUD_TEST(adapter_caps_a_ump_sysex_through_its_end) {
  Fixture f(16, 8);
  // Start 6, continue 6 (over the cap), end 2: the start stays pushed and
  // the cut closes it with an end packet without data at once, the rest is
  // dropped; a complete one within the cap follows.
  f.ump({sysex(AUD_MIDI_SYSEX_START, 6), 0, sysex(AUD_MIDI_SYSEX_CONTINUE, 6),
         0, sysex(AUD_MIDI_SYSEX_END, 2), 0, sysex(AUD_MIDI_SYSEX_COMPLETE, 6),
         0, midi1(0x90, 60, 100)});
  AUD_CHECK(f.source.pushed() == 4);
  AUD_CHECK(f.source.at(0).words[0] == sysex(AUD_MIDI_SYSEX_START, 6));
  AUD_CHECK(f.source.at(1).words[0] == sysex(AUD_MIDI_SYSEX_END, 0));
  AUD_CHECK(f.source.at(1).words[1] == 0);
  AUD_CHECK(f.source.at(1).count == 2);
  AUD_CHECK(f.source.at(2).words[0] == sysex(AUD_MIDI_SYSEX_COMPLETE, 6));
  AUD_CHECK(f.source.at(3).words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(f.stats().sysex_dropped_size == 1);
  AUD_CHECK(f.stats().sysex_cut == 1);
  AUD_CHECK(f.stats().sysex_torn == 0);
  // SysEx8 (type 5, four words) counts its bytes the same way; a complete
  // packet over the cap pushed nothing, so nothing closes it.
  f.ump({sysex(AUD_MIDI_SYSEX_COMPLETE, 9, 5), 0, 0, 0});
  AUD_CHECK(f.stats().sysex_dropped_size == 2);
  AUD_CHECK(f.stats().sysex_cut == 1);
  AUD_CHECK(f.source.pushed() == 4);
  f.ump({sysex(AUD_MIDI_SYSEX_COMPLETE, 8, 5), 0, 0, 0});
  AUD_CHECK(f.source.pushed() == 5);
}

AUD_TEST(adapter_closes_a_cut_ump_sysex7_with_the_end_packet_of_its_group) {
  Fixture f(16, 8);
  // The start on group 7 is pushed, the continue is over the cap: the end
  // packet carries the type, the group, status end and no bytes - the
  // exact words 0x37300000 0x00000000. The rest is dropped through its
  // end, a note passes.
  f.ump({sysex(AUD_MIDI_SYSEX_START, 6) | (7u << 24), 0x01020304,
         sysex(AUD_MIDI_SYSEX_CONTINUE, 3) | (7u << 24), 0,
         sysex(AUD_MIDI_SYSEX_END, 1) | (7u << 24), 0, midi1(0x90, 60, 100)},
        99);
  AUD_CHECK(f.source.pushed() == 3);
  AUD_CHECK(f.source.at(1).count == 2);
  AUD_CHECK(f.source.at(1).words[0] == 0x37300000u);
  AUD_CHECK(f.source.at(1).words[1] == 0u);
  AUD_CHECK(f.source.at(1).time == 99);
  AUD_CHECK(f.source.at(2).words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(f.stats().sysex_cut == 1);
  AUD_CHECK(f.stats().sysex_dropped_size == 1);
}

AUD_TEST(adapter_closes_a_cut_ump_sysex8_with_the_end_packet_of_its_stream) {
  Fixture f(16, 8);
  // A SysEx8 on group 2 with the stream id 0x2A: the start of 8 bytes is
  // pushed, the continue takes it over the cap. The end packet counts one
  // byte, the stream id, and carries no data - the exact words 0x5231_2A00
  // 0 0 0.
  f.ump({sysex8(AUD_MIDI_SYSEX_START, 8, 0x2A, 2), 0x01020304, 0x05060700, 0,
         sysex8(AUD_MIDI_SYSEX_CONTINUE, 4, 0x2A, 2), 0x08090A00, 0, 0,
         sysex8(AUD_MIDI_SYSEX_END, 2, 0x2A, 2), 0x0B000000, 0, 0,
         midi1(0x90, 60, 100)});
  AUD_CHECK(f.source.pushed() == 3);
  AUD_CHECK(f.source.at(0).words[0] == sysex8(AUD_MIDI_SYSEX_START, 8, 0x2A, 2));
  AUD_CHECK(f.source.at(1).count == 4);
  AUD_CHECK(f.source.at(1).words[0] == 0x52312A00u);
  AUD_CHECK(f.source.at(1).words[1] == 0u);
  AUD_CHECK(f.source.at(1).words[2] == 0u);
  AUD_CHECK(f.source.at(1).words[3] == 0u);
  AUD_CHECK(f.source.at(2).words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(f.stats().sysex_cut == 1);
  AUD_CHECK(f.stats().sysex_torn == 0);
  AUD_CHECK(f.stats().sysex_dropped_size == 1);
  // A whole SysEx8 within the cap afterwards is untouched.
  f.ump({sysex8(AUD_MIDI_SYSEX_COMPLETE, 3, 0x2B, 2), 0x01020000, 0, 0});
  AUD_CHECK(f.source.pushed() == 4);
  AUD_CHECK(f.stats().sysex_cut == 1);
}

AUD_TEST(adapter_closes_a_ump_sysex_the_source_refuses_mid_way) {
  Fixture f;
  f.ump({sysex(AUD_MIDI_SYSEX_START, 6), 0});
  // The continue is refused: the end packet closes the SysEx at once and
  // the rest, the end of 1, is dropped; the note passes.
  f.source.refuseNext.store(1);
  f.ump({sysex(AUD_MIDI_SYSEX_CONTINUE, 6), 0, sysex(AUD_MIDI_SYSEX_END, 1), 0,
         midi1(0x90, 60, 100)});
  AUD_CHECK(f.source.pushCalls.load() == 4);
  AUD_CHECK(f.source.pushed() == 3);
  AUD_CHECK(f.source.at(1).words[0] == sysex(AUD_MIDI_SYSEX_END, 0));
  AUD_CHECK(f.source.at(1).words[1] == 0);
  AUD_CHECK(f.source.at(2).words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(f.stats().rejected == 1);
  AUD_CHECK(f.stats().sysex_cut == 1);
  AUD_CHECK(f.stats().sysex_torn == 0);
  // The source refuses the end packet too: the SysEx stays torn, counted;
  // the rest is still dropped through its end.
  f.ump({sysex(AUD_MIDI_SYSEX_START, 6), 0});
  f.source.refuseNext.store(2);
  f.ump({sysex(AUD_MIDI_SYSEX_CONTINUE, 6), 0, sysex(AUD_MIDI_SYSEX_END, 1), 0,
         midi1(0x80, 60, 0)});
  AUD_CHECK(f.source.pushCalls.load() == 8);
  AUD_CHECK(f.source.pushed() == 5);
  AUD_CHECK(f.source.at(4).words[0] == midi1(0x80, 60, 0));
  AUD_CHECK(f.stats().rejected == 3);
  AUD_CHECK(f.stats().sysex_cut == 2);
  AUD_CHECK(f.stats().sysex_torn == 1);
}

AUD_TEST(adapter_drops_sysex_and_clock_while_the_source_is_over_half_full) {
  Fixture f(16);
  f.source.size.store(8);  // exactly half: nothing is dropped
  f.ump({system(0xF8), sysex(AUD_MIDI_SYSEX_COMPLETE, 1), 0});
  AUD_CHECK(f.source.pushed() == 2);
  f.source.size.store(9);
  f.ump({system(0xF8), sysex(AUD_MIDI_SYSEX_START, 6), 0,
         midi1(0x90, 60, 100), system(0xFA)});
  // The clock and the start are dropped; the note and the start message
  // pass.
  AUD_CHECK(f.source.pushed() == 4);
  AUD_CHECK(f.source.at(2).words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(f.source.at(3).words[0] == system(0xFA));
  AUD_CHECK(f.stats().dropped_fill == 2);
  // The continue and the end of the dropped SysEx go too, also once the
  // source drained.
  f.source.size.store(0);
  f.ump({sysex(AUD_MIDI_SYSEX_CONTINUE, 6), 0, sysex(AUD_MIDI_SYSEX_END, 1), 0,
         sysex(AUD_MIDI_SYSEX_COMPLETE, 2), 0});
  AUD_CHECK(f.source.pushed() == 5);
  AUD_CHECK(f.source.at(4).words[0] == sysex(AUD_MIDI_SYSEX_COMPLETE, 2));
  AUD_CHECK(f.stats().dropped_fill == 2);
  // The default capacity of 4096: 2049 waiting events are too many.
  AudMidiAdapterConfig config = configOf(f.source, 0);
  AudMidiAdapter* adapter = aud_audio_midi_adapter_create(&config);
  const uint32_t clock = system(0xF8);
  f.source.size.store(2048);
  aud_audio_midi_tap(adapter, AUD_MIDI_TAP_UMP, &clock, 1, 1);
  f.source.size.store(2049);
  aud_audio_midi_tap(adapter, AUD_MIDI_TAP_UMP, &clock, 1, 1);
  AUD_CHECK(f.source.pushed() == 6);
  aud_audio_midi_adapter_destroy(adapter);
}

AUD_TEST(adapter_drops_the_rest_of_a_ump_sysex_the_source_refuses) {
  Fixture f;
  f.source.pushResult.store(AUD_ERROR_QUEUE_FULL);
  f.ump({sysex(AUD_MIDI_SYSEX_START, 6), 0});
  f.source.pushResult.store(AUD_OK);
  f.ump({sysex(AUD_MIDI_SYSEX_CONTINUE, 6), 0, sysex(AUD_MIDI_SYSEX_END, 1), 0,
         midi1(0x90, 60, 100)});
  AUD_CHECK(f.source.pushCalls.load() == 2);
  AUD_CHECK(f.source.pushed() == 1);
  AUD_CHECK(f.source.at(0).words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(f.stats().rejected == 1);
  // Nothing of the SysEx was pushed, so nothing closes it.
  AUD_CHECK(f.stats().sysex_cut == 0);
}

// ............................................................................
// The byte path

AUD_TEST(adapter_parses_bytes_across_calls_with_the_group_and_the_time) {
  Fixture f(16, 0, 3);
  f.bytes({0x90, 60}, 10);
  AUD_CHECK(f.source.pushed() == 0);
  f.bytes({100, 62, 0xF8, 100, 0xF0, 1, 2}, 20);
  f.bytes({3, 0xF7}, 30);
  AUD_CHECK(f.source.pushed() == 4);
  AUD_CHECK(f.source.at(0).words[0] == midi1(0x90, 60, 100, 3));
  AUD_CHECK(f.source.at(0).time == 20);
  AUD_CHECK(f.source.at(1).words[0] == system(0xF8, 3));
  AUD_CHECK(f.source.at(2).words[0] == midi1(0x90, 62, 100, 3));
  AUD_CHECK(f.source.at(3).count == 2);
  AUD_CHECK(f.source.at(3).words[0] ==
            ((3u << 28) | (3u << 24) | (3u << 16) | (1u << 8) | 2u));
  AUD_CHECK(f.source.at(3).words[1] == (3u << 24));
  AUD_CHECK(f.source.at(3).time == 30);
  AUD_CHECK(f.stats().pushed == 4);
}

AUD_TEST(adapter_applies_the_rules_to_the_byte_path) {
  Fixture f(16, 8);
  f.bytes({0x3C});  // a data byte without a status
  AUD_CHECK(f.stats().malformed == 1);
  f.bytes({0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xF7});
  AUD_CHECK(f.stats().sysex_dropped_size == 1);
  // The start packet and the end packet that closes the cut SysEx.
  AUD_CHECK(f.source.pushed() == 2);
  AUD_CHECK(f.stats().sysex_cut == 1);
  f.source.size.store(9);
  f.bytes({0xF8, 0xF0, 1, 2, 3, 4, 5, 6, 7, 0xF7, 0x90, 60, 100, 0xF0, 1,
           0xF7});
  // The clock, the start of the long SysEx and the short SysEx are dropped;
  // the note passes. Nothing of the long SysEx was pushed, so nothing
  // closes it.
  AUD_CHECK(f.source.pushed() == 3);
  AUD_CHECK(f.source.at(2).words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(f.stats().dropped_fill == 3);
  AUD_CHECK(f.stats().rejected == 0);
  AUD_CHECK(f.stats().sysex_cut == 1);
  f.source.size.store(0);
  f.source.pushResult.store(AUD_ERROR_QUEUE_FULL);
  f.bytes({0xF0, 1, 2, 3, 4, 5, 6, 7});
  f.source.pushResult.store(AUD_OK);
  f.bytes({8, 9, 10, 11, 12, 13, 14, 0xF7, 0xB0, 7, 0x7F});
  // The refused start packet was the first of its SysEx: dropped through
  // its end, nothing closes it.
  AUD_CHECK(f.stats().rejected == 1);
  AUD_CHECK(f.stats().sysex_cut == 1);
  AUD_CHECK(f.source.pushed() == 4);
  AUD_CHECK(f.source.at(3).words[0] == midi1(0xB0, 7, 0x7F));
  aud_audio_midi_tap(f.adapter, AUD_MIDI_TAP_BYTES, nullptr, 2, 1);
  AUD_CHECK(f.stats().malformed == 2);
  // What the tap counted outside the parser survives the next feed: F7
  // without a SysEx is one more malformed byte.
  f.bytes({0xF7});
  AUD_CHECK(f.stats().malformed == 3);
}

AUD_TEST(adapter_closes_a_cut_byte_sysex_with_an_empty_end_packet) {
  Fixture f(16, 8, 3);
  // The cap of 8 on group 3: the start packet left before the ninth byte,
  // which cuts the SysEx - the end packet carries the type, the group,
  // status end and no bytes, the exact words 0x33300000 0x00000000, at the
  // time of the chunk that cut it.
  f.bytes({0xF0, 1, 2, 3, 4, 5, 6, 7, 8}, 50);
  AUD_CHECK(f.source.pushed() == 1);
  f.bytes({9}, 60);
  AUD_CHECK(f.source.pushed() == 2);
  AUD_CHECK(f.source.at(1).count == 2);
  AUD_CHECK(f.source.at(1).words[0] == 0x33300000u);
  AUD_CHECK(f.source.at(1).words[1] == 0u);
  AUD_CHECK(f.source.at(1).time == 60);
  // The rest is dropped through F7, the note passes.
  f.bytes({10, 11, 0xF7, 0x90, 60, 100}, 70);
  AUD_CHECK(f.source.pushed() == 3);
  AUD_CHECK(f.source.at(2).words[0] == midi1(0x90, 60, 100, 3));
  AUD_CHECK(f.stats().sysex_dropped_size == 1);
  AUD_CHECK(f.stats().sysex_cut == 1);
  AUD_CHECK(f.stats().sysex_torn == 0);
  // Cap 3: the cut comes within the first packet, nothing was pushed, so
  // nothing closes it.
  AudMidiAdapterConfig config = configOf(f.source, 16, 3, 3);
  AudMidiAdapter* small = aud_audio_midi_adapter_create(&config);
  const uint8_t four[] = {0xF0, 1, 2, 3, 4, 0xF7};
  aud_audio_midi_tap(small, AUD_MIDI_TAP_BYTES, four, 6, 80);
  AUD_CHECK(f.source.pushed() == 3);
  AudMidiAdapterStats stats{};
  stats.struct_size = sizeof(AudMidiAdapterStats);
  AUD_CHECK(aud_audio_midi_adapter_stats(small, &stats) == AUD_OK);
  AUD_CHECK(stats.sysex_dropped_size == 1);
  AUD_CHECK(stats.sysex_cut == 0);
  aud_audio_midi_adapter_destroy(small);
}

AUD_TEST(adapter_closes_a_byte_sysex_the_source_refuses_mid_way) {
  Fixture f(16, 0, 3);
  // The source refuses the continue packet after the start was pushed: the
  // end packet without data closes the SysEx at once, the rest is dropped
  // through F7, the control change passes.
  f.bytes({0xF0, 1, 2, 3, 4, 5, 6, 7});
  AUD_CHECK(f.source.pushed() == 1);
  f.source.refuseNext.store(1);
  f.bytes({8, 9, 10, 11, 12, 13, 0xF7, 0xB0, 7, 0x7F});
  AUD_CHECK(f.source.pushed() == 3);
  AUD_CHECK(f.source.at(1).count == 2);
  AUD_CHECK(f.source.at(1).words[0] == 0x33300000u);
  AUD_CHECK(f.source.at(1).words[1] == 0u);
  AUD_CHECK(f.source.at(2).words[0] == midi1(0xB0, 7, 0x7F, 3));
  AUD_CHECK(f.stats().rejected == 1);
  AUD_CHECK(f.stats().sysex_cut == 1);
  AUD_CHECK(f.stats().sysex_torn == 0);
  // The source refuses the end packet too: the SysEx stays torn, counted.
  f.bytes({0xF0, 1, 2, 3, 4, 5, 6, 7});
  f.source.refuseNext.store(2);
  f.bytes({8, 9, 10, 11, 12, 13, 0xF7, 0x80, 60, 0});
  AUD_CHECK(f.source.pushed() == 5);
  AUD_CHECK(f.source.at(4).words[0] == midi1(0x80, 60, 0, 3));
  AUD_CHECK(f.stats().rejected == 3);
  AUD_CHECK(f.stats().sysex_cut == 2);
  AUD_CHECK(f.stats().sysex_torn == 1);
  AUD_CHECK(f.stats().sysex_dropped_size == 0);
  AUD_CHECK(f.stats().malformed == 0);
}

// ............................................................................
// GONE and close

AUD_TEST(adapter_gone_raises_release_and_resets_the_parser) {
  Fixture f;
  f.bytes({0x90, 60, 100});
  f.gone(5);
  AUD_CHECK(f.source.releases.load() == 1);
  AUD_CHECK(f.stats().gone == 1);
  // The running status is gone with the port: data bytes alone are
  // malformed now.
  f.bytes({62, 100});
  AUD_CHECK(f.source.pushed() == 1);
  AUD_CHECK(f.stats().malformed == 2);
  f.gone();
  f.gone();
  AUD_CHECK(f.source.releases.load() == 3);
}

AUD_TEST(adapter_close_stops_the_tap_and_keeps_the_stats) {
  Fixture f;
  f.ump({midi1(0x90, 60, 100)});
  aud_audio_midi_adapter_close(f.adapter);
  f.source.dead = true;
  f.ump({midi1(0x80, 60, 0)});
  f.bytes({0x80, 60, 0});
  f.gone();
  AUD_CHECK(f.source.violations.load() == 0);
  AUD_CHECK(f.source.pushed() == 1);
  AUD_CHECK(f.source.releases.load() == 0);
  const AudMidiAdapterStats stats = f.stats();
  AUD_CHECK(stats.pushed == 1);
  AUD_CHECK(stats.dropped_closed == 3);
  AUD_CHECK(stats.gone == 0);
  aud_audio_midi_adapter_close(f.adapter);
  aud_audio_midi_adapter_close(nullptr);
  AUD_CHECK(f.stats().dropped_closed == 3);
}

// The producer feeds bytes and UMP in a loop, a second thread raises GONE
// and reads the stats, the control thread closes under traffic; after
// close returns the source is dead and nobody touches it.
AUD_TEST(adapter_threads_producer_gone_and_close) {
  Fixture f(1 << 16);
  std::atomic<bool> stop{false};
  std::atomic<uint64_t> calls{0};
  std::atomic<uint64_t> goneCalls{0};
  std::thread producer([&] {
    const uint8_t on[] = {0x90, 60, 100};
    const uint8_t off[] = {0x80, 60, 0};
    const uint8_t sysexHead[] = {0xF0, 1, 2, 3, 4};
    const uint8_t sysexTail[] = {5, 6, 7, 0xF7};
    const uint32_t clock = system(0xF8);
    while (!stop.load(std::memory_order_relaxed)) {
      aud_audio_midi_tap(f.adapter, AUD_MIDI_TAP_BYTES, on, 3, 1);
      aud_audio_midi_tap(f.adapter, AUD_MIDI_TAP_UMP, &clock, 1, 2);
      aud_audio_midi_tap(f.adapter, AUD_MIDI_TAP_BYTES, sysexHead, 5, 3);
      aud_audio_midi_tap(f.adapter, AUD_MIDI_TAP_BYTES, sysexTail, 4, 4);
      aud_audio_midi_tap(f.adapter, AUD_MIDI_TAP_BYTES, off, 3, 5);
      calls.fetch_add(5, std::memory_order_relaxed);
    }
  });
  std::thread watcher([&] {
    while (!stop.load(std::memory_order_relaxed)) {
      aud_audio_midi_tap(f.adapter, AUD_MIDI_TAP_GONE, nullptr, 0, 9);
      goneCalls.fetch_add(1, std::memory_order_relaxed);
      AudMidiAdapterStats stats{};
      stats.struct_size = sizeof(AudMidiAdapterStats);
      aud_audio_midi_adapter_stats(f.adapter, &stats);
      std::this_thread::yield();
    }
  });
  // Both threads have to run before the close: a fast producer would
  // otherwise reach its calls before the watcher raised a single GONE.
  while (calls.load(std::memory_order_relaxed) < 20000 ||
         goneCalls.load(std::memory_order_relaxed) == 0) {
    std::this_thread::yield();
  }
  aud_audio_midi_adapter_close(f.adapter);
  f.source.dead = true;
  // The producer keeps calling the closed tap for a while.
  const uint64_t atClose = calls.load(std::memory_order_relaxed);
  while (calls.load(std::memory_order_relaxed) < atClose + 1000) {
    std::this_thread::yield();
  }
  stop.store(true);
  producer.join();
  watcher.join();
  const AudMidiAdapterStats stats = f.stats();
  AUD_CHECK(f.source.violations.load() == 0);
  AUD_CHECK(stats.pushed > 0);
  AUD_CHECK(stats.gone > 0);
  AUD_CHECK(stats.dropped_closed >= 1000);
  AUD_CHECK(stats.rejected == 0);
  AUD_CHECK(f.source.releases.load() == stats.gone);
}

AUD_TEST(adapter_close_waits_for_a_call_in_flight) {
  Fixture f;
  // A push that takes a while: close must not return before it ends.
  static std::atomic<bool> slow{false};
  static std::atomic<bool> inPush{false};
  struct Slow {
    static int32_t push(AudEventSource* source, const uint32_t* words,
                        uint32_t count, int64_t time) {
      inPush.store(true);
      // A spin without a system call: the tap is nonblocking, and the
      // rtsan build checks what runs inside it.
      while (slow.load()) {
      }
      inPush.store(false);
      return FakeSource::push(source, words, count, time);
    }
  };
  AudMidiAdapterConfig config = configOf(f.source);
  config.push = Slow::push;
  AudMidiAdapter* adapter = aud_audio_midi_adapter_create(&config);
  slow.store(true);
  std::thread producer([&] {
    const uint32_t note = midi1(0x90, 60, 100);
    aud_audio_midi_tap(adapter, AUD_MIDI_TAP_UMP, &note, 1, 1);
  });
  while (!inPush.load()) std::this_thread::yield();
  std::atomic<bool> closed{false};
  std::thread closer([&] {
    aud_audio_midi_adapter_close(adapter);
    closed.store(true);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  AUD_CHECK(!closed.load());
  slow.store(false);
  closer.join();
  producer.join();
  AUD_CHECK(closed.load());
  AUD_CHECK(f.source.pushed() == 1);
  aud_audio_midi_adapter_destroy(adapter);
}

// ............................................................................
// The rtsan probe of the tap

namespace {

// Allocates inside the fake push when AUD_TEST_RTSAN_PROBE is set:
// scripts/test-native.js checks that the rtsan run catches it inside the
// nonblocking tap, so that the run's silence about the adapter means
// something.
const bool g_tapProbe = std::getenv("AUD_TEST_RTSAN_PROBE") != nullptr;
char* volatile g_tapProbeSink = nullptr;

int32_t probePush(AudEventSource* source, const uint32_t* words,
                  uint32_t count, int64_t time) {
  if (g_tapProbe) {
    g_tapProbeSink = new char[16];
    delete[] g_tapProbeSink;
  }
  return FakeSource::push(source, words, count, time);
}

}  // namespace

AUD_TEST(rtsan_tap_probe) {
  Fixture f;
  AudMidiAdapterConfig config = configOf(f.source);
  config.push = probePush;
  AudMidiAdapter* adapter = aud_audio_midi_adapter_create(&config);
  const uint32_t note = midi1(0x90, 60, 100);
  aud_audio_midi_tap(adapter, AUD_MIDI_TAP_UMP, &note, 1, 1);
  AUD_CHECK(f.source.pushed() == 1);
  aud_audio_midi_adapter_destroy(adapter);
}
