// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The entry point of aud_audio_with_midi (step S8, ticket 26): the port nodes
// `aud.midi.input` and `aud.midi.output`, registered with an engine through
// the C ABI of aud_audio_core (ABI 0.4), and the tap adapter that carries
// the MIDI of an aud_midi port into an event source of aud_audio_graph.
//
// The nodes pass the events of their inlet through to their outlet at the
// offset they arrive at; the output node drops SysEx (UMP types 3 and 5)
// unless its parameter `sysex` is on. Both declare
// AUD_NODE_CAP_PASSES_EVENTS (ticket 37): after a stop or a prepare of the
// engine the nodes behind them close the notes they handed on and the
// engine those they handed out of the graph, one note off each. Both keep
// the id and the fingerprint of their port as string settings on the
// control thread. Their process calls allocate nothing and take no lock.
//
// The adapter is the AudMidiTapFunction of a port (contract C2 of the
// ticket): a backend of aud_midi calls it on its receive thread with UMP
// words or MIDI 1.0 bytes, or with GONE when the port disappears, and the
// adapter pushes UMP packets into the event source through the function
// pointers it was created with - it includes the graph's header but never
// links the graph. The Dart path calls the same function through FFI, so
// both paths share the parser. The adapter is nonblocking: no allocation,
// no lock, no I/O on the data path.

#ifndef AUD_AUDIO_WITH_MIDI_H
#define AUD_AUDIO_WITH_MIDI_H

#include <stdint.h>

#include "aud_abi.h"

#ifdef __cplusplus
extern "C" {
#endif

// ............................................................................
// Node types

// The type ids of the port nodes.
#define AUD_MIDI_INPUT_TYPE_ID "aud.midi.input"
#define AUD_MIDI_OUTPUT_TYPE_ID "aud.midi.output"

// The event ports of both node types, by index: the inlet "in" and the
// outlet "out".
enum {
  AUD_MIDI_PORT_IN = 0,
  AUD_MIDI_PORT_OUT = 0,
};

// The parameters of the output node, by index.
enum {
  // "sysex": a boolean; while off, SysEx packets (UMP types 3 and 5) are
  // dropped, since the notification ring they travel on is lossy.
  AUD_MIDI_OUTPUT_PARAM_SYSEX = 0,
  AUD_MIDI_OUTPUT_NUM_PARAMS = 1,
};

// The string settings of both node types (AudNodeVTable.set_string), kept
// on the control thread; the graph document persists them.
enum {
  // "port_id": the id of the aud_midi port the node is bound to.
  AUD_MIDI_KEY_PORT_ID = 0,
  // "port_fingerprint": aud_midi's fingerprint of the port
  // (`manufacturer|name|serialNumber|direction|index`), by which the
  // bridge finds the device again when the port id changed (Android).
  AUD_MIDI_KEY_PORT_FINGERPRINT = 1,
  AUD_MIDI_NUM_KEYS = 2,
};

// [control] Registers the node types with the host api of an engine; AUD_OK
// or the first error code. An AudRegisterFunction.
AUD_EXPORT int32_t aud_audio_with_midi_register(const AudHostApi* host);

// ............................................................................
// The event source of aud_audio_graph (contract C1)

// The function pointers of an event source of aud_audio_graph, declared here
// as the graph declares them, so that the adapter pushes into a source
// without linking the graph: the bridge hands the adapter the addresses.
typedef struct AudEventSource AudEventSource;

// [producer] Pushes one UMP packet of 1 to 4 words with its timestamp in
// host ns; AUD_OK, AUD_ERROR_QUEUE_FULL or AUD_ERROR_INVALID.
typedef int32_t (*AudEventSourcePushFunction)(AudEventSource*,
                                              const uint32_t*, uint32_t,
                                              int64_t);
// [any thread] Raises the release of the source.
typedef void (*AudEventSourceReleaseFunction)(AudEventSource*);
// [producer] The events waiting in the source.
typedef uint32_t (*AudEventSourceSizeFunction)(const AudEventSource*);

// ............................................................................
// The native tap (contract C2)

// The kinds of a tap call.
enum {
  // `data` holds `count` uint32_t words in host byte order: one or more
  // complete UMP packets.
  AUD_MIDI_TAP_UMP = 1,
  // `data` holds `count` bytes of a MIDI 1.0 byte stream; a message may
  // span calls.
  AUD_MIDI_TAP_BYTES = 2,
  // The port disappeared or went offline; `data` NULL, `count` 0.
  AUD_MIDI_TAP_GONE = 3,
};

// What a backend of aud_midi calls with the MIDI of a port: `host_time_ns`
// is the arrival time on the engine's clock (aud_clock.h), never 0; for
// GONE the time of the report. Data calls come from one thread at a time;
// GONE may come from another one.
typedef void (*AudMidiTapFunction)(void* user, uint32_t kind,
                                   const void* data, uint32_t count,
                                   int64_t host_time_ns);

// ............................................................................
// The adapter (contract C3)

typedef struct AudMidiAdapter AudMidiAdapter;

// How an adapter is created. Zero means the default.
typedef struct AudMidiAdapterConfig {
  uint32_t struct_size;
  uint32_t group;            // the UMP group of MIDI 1.0 bytes, 0 to 15
  uint32_t max_sysex_bytes;  // a longer SysEx is dropped; 0: 65536
  uint32_t capacity;         // the source's capacity (half-full rule); 0:
                             // 4096, the default of the graph
  void* source;              // the AudEventSource*
  AudEventSourcePushFunction push;
  AudEventSourceReleaseFunction release;
  AudEventSourceSizeFunction size;  // NULL: no half-full rule
} AudMidiAdapterConfig;

// The counters of an adapter; relaxed, read from any thread.
typedef struct AudMidiAdapterStats {
  uint32_t struct_size;
  uint32_t reserved;
  uint64_t pushed;              // packets the source accepted
  uint64_t rejected;            // packets the source refused
  uint64_t sysex_dropped_size;  // SysEx dropped for exceeding the cap
  uint64_t dropped_fill;        // SysEx and clock dropped by the half-full
                                // rule
  uint64_t gone;                // GONE calls, each raised a release
  uint64_t malformed;           // bytes and packets the parser threw away
  uint64_t dropped_closed;      // calls after close, returned at once
  uint64_t sysex_cut;           // SysEx closed short with an end packet
                                // after a packet of theirs was pushed
  uint64_t sysex_torn;          // of those, the ones whose end packet the
                                // source refused: a torn SysEx got through
} AudMidiAdapterStats;

// [control] Creates an adapter for a source; NULL for a NULL config, a
// short struct, a NULL source, push or release, or a group above 15.
AUD_EXPORT AudMidiAdapter* aud_audio_with_midi_adapter_create(
    const AudMidiAdapterConfig* config);

// [control] Closes the adapter: after it returns, the tap never touches
// the source again - calls in flight are waited for (spinning with a
// yield, bounded; a wait that runs out logs and returns), later calls
// return at once and count as dropped_closed. The engine may then dispose
// the graph before the tap is detached. Calling it again changes nothing.
AUD_EXPORT void aud_audio_with_midi_adapter_close(AudMidiAdapter* adapter);

// [control] Destroys the adapter, after the tap detached; closes it first.
AUD_EXPORT void aud_audio_with_midi_adapter_destroy(AudMidiAdapter* adapter);

// The AudMidiTapFunction of an adapter; `user` is the adapter. Nonblocking.
// UMP passes through packet by packet, MIDI 1.0 bytes become UMP: running
// status and the SysEx state hold across calls, real-time bytes inside a
// SysEx leave as type 1 packets of their own, SysEx7 is packed into type 3
// packets. A SysEx over max_sysex_bytes, and a SysEx or a clock (type 1
// 0xF8) while the source holds more than half its capacity, are dropped
// and counted; a dropped SysEx is dropped through its end, and so is one
// whose packet the source refused. When a packet of the SysEx was pushed
// before the cut, an end packet without data closes it at once (sysex_cut)
// - a type 3 end for SysEx7, a type 5 end with the stream id for SysEx8 -
// so no torn SysEx reaches a node unless the source refuses the end too
// (sysex_torn). GONE raises the source's release and forgets an open
// SysEx; one the UMP path had pushed closes with the cut end packet at
// the next data call.
AUD_EXPORT void aud_audio_with_midi_tap(void* user, uint32_t kind,
                                   const void* data, uint32_t count,
                                   int64_t host_time_ns);

// [any thread] The counters of the adapter; AUD_ERROR_INVALID_ARGUMENT for
// a NULL adapter or stats, or a short struct.
AUD_EXPORT int32_t aud_audio_with_midi_adapter_stats(const AudMidiAdapter* adapter,
                                                AudMidiAdapterStats* stats);

#ifdef __cplusplus
}
#endif

#endif  // AUD_AUDIO_WITH_MIDI_H
