// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The tap adapter (ticket 26, contract C3): the AudMidiTapFunction of a
// port that pushes UMP into an event source of aud_audio_graph through the
// function pointers of its config. One producer thread calls the data path
// at a time; GONE and close may come from other threads and touch only
// atomics. The data path allocates nothing and takes no lock.

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <new>
#include <thread>

#include "aud_audio_midi.h"
#include "aud_midi_parser.h"
#include "aud_ump.h"

#if defined(__clang__) && defined(__has_cpp_attribute)
#if __has_cpp_attribute(clang::nonblocking)
#define AUD_MIDI_NONBLOCKING [[clang::nonblocking]]
#endif
#endif
#ifndef AUD_MIDI_NONBLOCKING
#define AUD_MIDI_NONBLOCKING
#endif
// The internal functions of the data path: nonblocking and noexcept.
#define AUD_MIDI_RT noexcept AUD_MIDI_NONBLOCKING

namespace {

constexpr uint32_t kDefaultCapacity = 4096;
constexpr uint8_t kClock = 0xF8;
// How long close waits for the tap calls in flight before it logs.
constexpr auto kCloseTimeout = std::chrono::seconds(2);

}  // namespace

struct AudMidiAdapter {
  AudMidiAdapterConfig config{};
  AudMidiParser parser{};
  // The SysEx state of the UMP pass-through (types 3 and 5): whether the
  // rest of the SysEx is dropped, whether a packet of it was pushed (then
  // a cut closes it with an end packet), the first word of its first
  // packet - the type, group and stream id of that end packet - and its
  // bytes so far.
  bool umpSysexDropping = false;
  bool umpSysexOpen = false;
  uint32_t umpSysexHead = 0;
  uint32_t umpSysexBytes = 0;
  // The timestamp of the call in progress, for the packets of the parser.
  int64_t time = 0;
  std::atomic<uint64_t> pushed{0};
  std::atomic<uint64_t> rejected{0};
  std::atomic<uint64_t> sysexDroppedSize{0};
  std::atomic<uint64_t> droppedFill{0};
  std::atomic<uint64_t> gone{0};
  std::atomic<uint64_t> malformed{0};
  std::atomic<uint64_t> droppedClosed{0};
  std::atomic<uint64_t> sysexCut{0};
  std::atomic<uint64_t> sysexTorn{0};
  std::atomic<uint32_t> closed{0};
  std::atomic<uint32_t> inFlight{0};
  // GONE asks the data path to forget the running status and the SysEx
  // of both paths; the next data call of either path takes it.
  std::atomic<uint32_t> resetParser{0};
};

namespace {

bool overHalfFull(const AudMidiAdapter& a) AUD_MIDI_RT {
  if (a.config.size == nullptr) return false;
  const uint32_t size =
      a.config.size(static_cast<const AudEventSource*>(a.config.source));
  return size > a.config.capacity / 2;
}

bool pushPacket(AudMidiAdapter& a, const uint32_t* words,
                uint32_t count) AUD_MIDI_RT {
  const int32_t result = a.config.push(
      static_cast<AudEventSource*>(a.config.source), words, count, a.time);
  if (result == AUD_OK) {
    a.pushed.fetch_add(1, std::memory_order_relaxed);
    return true;
  }
  a.rejected.fetch_add(1, std::memory_order_relaxed);
  return false;
}

bool isClock(uint32_t word0) {
  return aud_ump_message_type(word0) == AUD_UMP_TYPE_SYSTEM &&
         ((word0 >> 16) & 0xFF) == kClock;
}

bool isSysex(uint32_t word0) {
  const uint32_t type = aud_ump_message_type(word0);
  return type == AUD_UMP_TYPE_DATA64 || type == AUD_UMP_TYPE_DATA128;
}

uint32_t sysexStatus(uint32_t word0) { return (word0 >> 20) & 0xF; }

bool sysexBegins(uint32_t status) {
  return status == AUD_MIDI_SYSEX_START || status == AUD_MIDI_SYSEX_COMPLETE;
}

bool sysexEnds(uint32_t status) {
  return status == AUD_MIDI_SYSEX_END || status == AUD_MIDI_SYSEX_COMPLETE;
}

// The reset GONE asked for, taken by the next data call of either path
// (both touch the state of both, so one call clears all of it): the
// parser forgets its running status and its SysEx; an open SysEx of the
// UMP path closes with the cut end packet, so that the source sees it
// closed, and the rest of its state goes.
void takeReset(AudMidiAdapter& a) AUD_MIDI_RT;

// ............................................................................
// The MIDI 1.0 byte path

// The sink of the parser: the half-full rule on a SysEx that begins and on
// a clock; a refusal makes the parser drop the rest of a SysEx.
int32_t emitFromParser(void* user, const uint32_t* words,
                       uint32_t count) AUD_MIDI_RT {
  AudMidiAdapter& a = *static_cast<AudMidiAdapter*>(user);
  const bool sysex = isSysex(words[0]);
  if ((sysex && sysexBegins(sysexStatus(words[0]))) || isClock(words[0])) {
    if (overHalfFull(a)) {
      a.droppedFill.fetch_add(1, std::memory_order_relaxed);
      return 0;
    }
  }
  return pushPacket(a, words, count) ? 1 : 0;
}

// Adds what the parser counted during a feed to the counter the stats read
// from any thread; the UMP path adds to the same counter.
void addCount(std::atomic<uint64_t>& counter, uint64_t before,
              uint64_t after) AUD_MIDI_RT {
  if (after != before) {
    counter.fetch_add(after - before, std::memory_order_relaxed);
  }
}

void feedBytes(AudMidiAdapter& a, const uint8_t* bytes,
               uint32_t count) AUD_MIDI_RT {
  takeReset(a);
  const AudMidiParser before = a.parser;
  aud_midi_parser_feed(&a.parser, bytes, count, emitFromParser, &a);
  addCount(a.malformed, before.malformed, a.parser.malformed);
  addCount(a.sysexDroppedSize, before.sysex_dropped_size,
           a.parser.sysex_dropped_size);
  addCount(a.sysexCut, before.sysex_cut, a.parser.sysex_cut);
  addCount(a.sysexTorn, before.sysex_torn, a.parser.sysex_torn);
}

// ............................................................................
// The UMP path

// Cuts the SysEx of the UMP path at a packet of `status`: the rest of it
// is dropped through its end. When a packet of it was pushed already, an
// end packet without data closes it at once - of the type and group of
// its first packet, and for SysEx8 with its stream id, which the byte
// count of a type 5 packet includes - so the source sees a closed, short
// SysEx; one the source refuses leaves the SysEx torn.
void cutUmpSysex(AudMidiAdapter& a, uint32_t status) AUD_MIDI_RT {
  a.umpSysexDropping = !sysexEnds(status);
  if (!a.umpSysexOpen) return;
  a.umpSysexOpen = false;
  a.sysexCut.fetch_add(1, std::memory_order_relaxed);
  const uint32_t head = a.umpSysexHead;
  uint32_t words[4] = {
      (head & 0xFF000000u) | (static_cast<uint32_t>(AUD_MIDI_SYSEX_END) << 20),
      0, 0, 0};
  if (aud_ump_message_type(head) == AUD_UMP_TYPE_DATA128) {
    words[0] |= (1u << 16) | (head & 0xFF00u);
  }
  if (!pushPacket(a, words, aud_ump_word_count(words[0]))) {
    a.sysexTorn.fetch_add(1, std::memory_order_relaxed);
  }
}

void takeReset(AudMidiAdapter& a) AUD_MIDI_RT {
  if (a.resetParser.exchange(0, std::memory_order_relaxed) == 0) return;
  aud_midi_parser_reset(&a.parser);
  if (a.umpSysexOpen) cutUmpSysex(a, AUD_MIDI_SYSEX_END);
  a.umpSysexDropping = false;
  a.umpSysexBytes = 0;
}

// A type 3 or 5 packet: the half-full rule at the start of a SysEx, the
// cap over its bytes, a refused packet - each cuts the SysEx.
void passSysex(AudMidiAdapter& a, const uint32_t* words,
               uint32_t count) AUD_MIDI_RT {
  const uint32_t status = sysexStatus(words[0]);
  const uint32_t bytes = (words[0] >> 16) & 0xF;
  if (sysexBegins(status)) {
    a.umpSysexDropping = false;
    a.umpSysexOpen = false;
    a.umpSysexHead = words[0];
    a.umpSysexBytes = 0;
    if (overHalfFull(a)) {
      a.droppedFill.fetch_add(1, std::memory_order_relaxed);
      a.umpSysexDropping = !sysexEnds(status);
      return;
    }
  }
  if (a.umpSysexDropping) {
    if (sysexEnds(status)) a.umpSysexDropping = false;
    return;
  }
  a.umpSysexBytes += bytes;
  if (a.umpSysexBytes > a.parser.max_sysex_bytes) {
    a.sysexDroppedSize.fetch_add(1, std::memory_order_relaxed);
    cutUmpSysex(a, status);
    return;
  }
  if (pushPacket(a, words, count)) {
    a.umpSysexOpen = !sysexEnds(status);
  } else {
    cutUmpSysex(a, status);
  }
}

void passUmp(AudMidiAdapter& a, const uint32_t* words,
             uint32_t count) AUD_MIDI_RT {
  takeReset(a);
  while (count > 0) {
    const uint32_t n = aud_ump_word_count(words[0]);
    if (n > count) {
      a.malformed.fetch_add(1, std::memory_order_relaxed);
      return;
    }
    if (isSysex(words[0])) {
      passSysex(a, words, n);
    } else if (isClock(words[0]) && overHalfFull(a)) {
      a.droppedFill.fetch_add(1, std::memory_order_relaxed);
    } else {
      pushPacket(a, words, n);
    }
    words += n;
    count -= n;
  }
}

}  // namespace

// ............................................................................
// The C API

AUD_EXPORT AudMidiAdapter* aud_audio_midi_adapter_create(
    const AudMidiAdapterConfig* config) {
  if (config == nullptr || config->struct_size < sizeof(AudMidiAdapterConfig) ||
      config->source == nullptr || config->push == nullptr ||
      config->release == nullptr || config->group > 15) {
    return nullptr;
  }
  AudMidiAdapter* adapter = new (std::nothrow) AudMidiAdapter();
  if (adapter == nullptr) return nullptr;
  adapter->config = *config;
  if (adapter->config.capacity == 0) adapter->config.capacity = kDefaultCapacity;
  aud_midi_parser_init(&adapter->parser, config->group,
                       config->max_sysex_bytes);
  return adapter;
}

AUD_EXPORT void aud_audio_midi_adapter_close(AudMidiAdapter* adapter) {
  if (adapter == nullptr) return;
  if (adapter->closed.exchange(1, std::memory_order_seq_cst) != 0) return;
  const auto start = std::chrono::steady_clock::now();
  while (adapter->inFlight.load(std::memory_order_seq_cst) > 0) {
    if (std::chrono::steady_clock::now() - start > kCloseTimeout) {
      std::fprintf(stderr,
                   "aud_audio_midi: a tap call did not return within 2 s; "
                   "the adapter is closed anyway\n");
      return;
    }
    std::this_thread::yield();
  }
}

AUD_EXPORT void aud_audio_midi_adapter_destroy(AudMidiAdapter* adapter) {
  if (adapter == nullptr) return;
  aud_audio_midi_adapter_close(adapter);
  delete adapter;
}

AUD_EXPORT void aud_audio_midi_tap(void* user, uint32_t kind, const void* data,
                                   uint32_t count,
                                   int64_t host_time_ns) AUD_MIDI_NONBLOCKING {
  if (user == nullptr) return;
  AudMidiAdapter& a = *static_cast<AudMidiAdapter*>(user);
  // The count in flight rises before the closed flag is read, and close
  // raises the flag before it reads the count: one of the two sees the
  // other.
  a.inFlight.fetch_add(1, std::memory_order_seq_cst);
  if (a.closed.load(std::memory_order_seq_cst) != 0) {
    a.droppedClosed.fetch_add(1, std::memory_order_relaxed);
    a.inFlight.fetch_sub(1, std::memory_order_release);
    return;
  }
  // Only the data calls, which come from one thread at a time, touch the
  // time and the parser; GONE may come from another thread.
  switch (kind) {
    case AUD_MIDI_TAP_UMP:
      a.time = host_time_ns;
      if (data != nullptr) {
        passUmp(a, static_cast<const uint32_t*>(data), count);
      } else if (count > 0) {
        a.malformed.fetch_add(1, std::memory_order_relaxed);
      }
      break;
    case AUD_MIDI_TAP_BYTES:
      a.time = host_time_ns;
      if (data != nullptr) {
        feedBytes(a, static_cast<const uint8_t*>(data), count);
      } else if (count > 0) {
        a.malformed.fetch_add(1, std::memory_order_relaxed);
      }
      break;
    case AUD_MIDI_TAP_GONE:
      a.gone.fetch_add(1, std::memory_order_relaxed);
      a.resetParser.store(1, std::memory_order_relaxed);
      a.config.release(static_cast<AudEventSource*>(a.config.source));
      break;
    default:
      a.malformed.fetch_add(1, std::memory_order_relaxed);
      break;
  }
  a.inFlight.fetch_sub(1, std::memory_order_release);
}

AUD_EXPORT int32_t aud_audio_midi_adapter_stats(const AudMidiAdapter* adapter,
                                                AudMidiAdapterStats* stats) {
  if (adapter == nullptr || stats == nullptr ||
      stats->struct_size < sizeof(AudMidiAdapterStats)) {
    return AUD_ERROR_INVALID_ARGUMENT;
  }
  const AudMidiAdapter& a = *adapter;
  stats->pushed = a.pushed.load(std::memory_order_relaxed);
  stats->rejected = a.rejected.load(std::memory_order_relaxed);
  stats->sysex_dropped_size = a.sysexDroppedSize.load(std::memory_order_relaxed);
  stats->dropped_fill = a.droppedFill.load(std::memory_order_relaxed);
  stats->gone = a.gone.load(std::memory_order_relaxed);
  stats->malformed = a.malformed.load(std::memory_order_relaxed);
  stats->dropped_closed = a.droppedClosed.load(std::memory_order_relaxed);
  stats->sysex_cut = a.sysexCut.load(std::memory_order_relaxed);
  stats->sysex_torn = a.sysexTorn.load(std::memory_order_relaxed);
  return AUD_OK;
}
