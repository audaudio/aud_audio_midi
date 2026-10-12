// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The port nodes (ticket 26, scope 3): aud.midi.input, the target of its
// port's event source, and aud.midi.output, whose outlet the bridge
// connects to the graph's event input. Both pass the events of their inlet
// through to their outlet at their offset; the output node drops SysEx
// unless its parameter says otherwise. The process calls allocate nothing
// and take no lock; the strings live on the control thread.

#include <cstring>
#include <new>
#include <string>

#include "aud_audio_midi.h"
#include "aud_midi_parser.h"
#include "aud_ump.h"

namespace {

// ............................................................................
// The instance

struct PortNode {
  PortNode(const AudHostApi* h, bool o) : host(h), output(o) {}

  const AudHostApi* host;
  bool output;
  // [realtime] The sysex parameter of the output node, 0 or 1.
  float sysex = 0;
  // [control] The string settings.
  std::string portId;
  std::string fingerprint;
};

void* create(const AudNodeDescriptor* descriptor, const AudHostApi* host) {
  if (descriptor == nullptr || host == nullptr || host->emit_event == nullptr) {
    return nullptr;
  }
  const bool output =
      std::strcmp(descriptor->type_id, AUD_MIDI_OUTPUT_TYPE_ID) == 0;
  return new (std::nothrow) PortNode(host, output);
}

void destroy(void* instance) { delete static_cast<PortNode*>(instance); }

int32_t prepare(void*, const AudPrepareInfo*) { return AUD_OK; }

void reset(void*, uint32_t) {}

void setParam(void* instance, uint32_t index, float value) {
  PortNode& node = *static_cast<PortNode*>(instance);
  if (node.output && index == AUD_MIDI_OUTPUT_PARAM_SYSEX) {
    node.sysex = value >= 0.5f ? 1.0f : 0.0f;
  }
}

bool isSysex(const AudEvent& event) {
  return event.type == AUD_EVENT_UMP && aud_midi_is_sysex_word(event.words[0]);
}

// [realtime] Passes every event through at its offset; a parameter event
// sets the parameter, a message event stays with the engine.
void process(void* instance, const AudProcessContext* context) {
  PortNode& node = *static_cast<PortNode*>(instance);
  for (uint32_t i = 0; i < context->num_events; ++i) {
    const AudEvent& event = context->events[i];
    if (event.type == AUD_EVENT_PARAM) {
      setParam(instance, event.words[0], aud_event_param_value(&event));
      continue;
    }
    if (event.type == AUD_EVENT_MESSAGE) continue;
    if (node.output && node.sysex == 0 && isSysex(event)) continue;
    AudEvent out = event;
    out.struct_size = sizeof(AudEvent);
    out.port = AUD_MIDI_PORT_OUT;
    node.host->emit_event(node.host->host, instance, &out);
  }
}

// [control] Stores the port id or the fingerprint; NULL clears it.
int32_t setString(void* instance, uint32_t key, const char* value) {
  PortNode& node = *static_cast<PortNode*>(instance);
  const char* text = value == nullptr ? "" : value;
  switch (key) {
    case AUD_MIDI_KEY_PORT_ID:
      node.portId = text;
      return AUD_OK;
    case AUD_MIDI_KEY_PORT_FINGERPRINT:
      node.fingerprint = text;
      return AUD_OK;
    default:
      return AUD_ERROR_INVALID_ARGUMENT;
  }
}

// ............................................................................
// The descriptors

const AudEventPortDescriptor kInlets[] = {
    {sizeof(AudEventPortDescriptor), "in", "Input",
     AUD_EVENT_PORT_MIDI | AUD_EVENT_PORT_CONTROL, 0},
};

const AudEventPortDescriptor kOutlets[] = {
    {sizeof(AudEventPortDescriptor), "out", "Output",
     AUD_EVENT_PORT_MIDI | AUD_EVENT_PORT_CONTROL, 0},
};

const AudStringKeyDescriptor kKeys[AUD_MIDI_NUM_KEYS] = {
    {sizeof(AudStringKeyDescriptor), AUD_MIDI_KEY_PORT_ID, "port_id",
     "Port id"},
    {sizeof(AudStringKeyDescriptor), AUD_MIDI_KEY_PORT_FINGERPRINT,
     "port_fingerprint", "Port fingerprint"},
};

const AudParamDescriptor kOutputParams[AUD_MIDI_OUTPUT_NUM_PARAMS] = {
    {sizeof(AudParamDescriptor), "sysex", "SysEx", "", 0.0f, 1.0f, 0.0f,
     AUD_PARAM_BOOLEAN, 0, 0},
};

const AudNodeVTable kVTable = {
    sizeof(AudNodeVTable), create,  destroy,   prepare, reset,   setParam,
    process,               setString, nullptr, nullptr, nullptr, nullptr,
};

constexpr uint32_t kCapabilities = AUD_NODE_CAP_VARIABLE_BLOCK |
                                   AUD_NODE_CAP_EVENTS |
                                   AUD_NODE_CAP_EVENT_OUTPUT |
                                   AUD_NODE_CAP_STRINGS;

const AudNodeDescriptor kInputDescriptor = {
    sizeof(AudNodeDescriptor),
    AUD_ABI_VERSION_MAJOR,
    AUD_ABI_VERSION_MINOR,
    1,
    AUD_MIDI_INPUT_TYPE_ID,
    "MIDI input",
    "Audanika",
    kCapabilities,
    0,
    0,
    0,
    nullptr,
    nullptr,
    1,
    1,
    kInlets,
    kOutlets,
    0,
    AUD_MIDI_NUM_KEYS,
    nullptr,
    kKeys,
    &kVTable,
};

const AudNodeDescriptor kOutputDescriptor = {
    sizeof(AudNodeDescriptor),
    AUD_ABI_VERSION_MAJOR,
    AUD_ABI_VERSION_MINOR,
    1,
    AUD_MIDI_OUTPUT_TYPE_ID,
    "MIDI output",
    "Audanika",
    kCapabilities,
    0,
    0,
    0,
    nullptr,
    nullptr,
    1,
    1,
    kInlets,
    kOutlets,
    AUD_MIDI_OUTPUT_NUM_PARAMS,
    AUD_MIDI_NUM_KEYS,
    kOutputParams,
    kKeys,
    &kVTable,
};

}  // namespace

AUD_EXPORT int32_t aud_audio_midi_register(const AudHostApi* host) {
  if (host == nullptr || host->register_node_type == nullptr) {
    return AUD_ERROR_INVALID_ARGUMENT;
  }
  if (host->abi_major != AUD_ABI_VERSION_MAJOR) return AUD_ERROR_ABI_MAJOR;
  if (host->struct_size < sizeof(AudHostApi)) return AUD_ERROR_ABI_MINOR;
  const int32_t input = host->register_node_type(host->host, &kInputDescriptor);
  if (input != AUD_OK) return input;
  return host->register_node_type(host->host, &kOutputDescriptor);
}
