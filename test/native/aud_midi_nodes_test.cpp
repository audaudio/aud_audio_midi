// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The port nodes on the graph engine of aud_audio_graph: the registration,
// the descriptors, the pass-through at the offset, the SysEx rule of the
// output node, the string keys, all under the engine's watchdog; the probe
// node proves that the rtsan build catches an allocation on the audio
// thread. The runner's main lives here.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "aud_audio_graph.h"
#include "aud_audio_midi.h"
#include "aud_test.hpp"
#include "aud_ump.h"

namespace {

constexpr double kRate = 48000.0;
constexpr uint32_t kFrames = 256;

// A graph with the bridge registered: an input node whose outlet feeds an
// output node whose outlet feeds the graph's event input, so that every
// event that passes both arrives as a notification that names the output
// node.
struct Fixture {
  AudGraph* graph = nullptr;
  uint32_t outChannels = 2;
  std::vector<std::vector<float>> out;
  std::vector<float*> outPointers;
  AudAudioBus outBus{};
  int32_t input = 0;
  int32_t output = 0;
  std::vector<AudGraphNotification> notifications;
  uint64_t violationsBefore = aud_graph_watchdog_violations();

  Fixture() {
    AudGraphConfig config{};
    config.struct_size = sizeof(AudGraphConfig);
    config.sample_rate = kRate;
    config.max_frames = kFrames;
    config.num_output_buses = 1;
    config.output_channels = &outChannels;
    graph = aud_graph_create(&config);
    AUD_CHECK(graph != nullptr);
    AUD_CHECK(aud_audio_midi_register(aud_graph_host_api(graph)) == AUD_OK);
    out.assign(outChannels, std::vector<float>(kFrames, 0.0f));
    for (auto& channel : out) outPointers.push_back(channel.data());
    outBus = {sizeof(AudAudioBus), outChannels, outPointers.data()};
  }
  ~Fixture() {
    takeNotifications();
    AUD_CHECK(aud_graph_watchdog_violations() - violationsBefore == 0);
    aud_graph_destroy(graph);
  }

  const AudHostApi* host() const { return aud_graph_host_api(graph); }

  // Creates and wires both nodes; the graph runs.
  void wire() {
    input = aud_graph_create_node(graph, AUD_MIDI_INPUT_TYPE_ID, nullptr);
    output = aud_graph_create_node(graph, AUD_MIDI_OUTPUT_TYPE_ID, nullptr);
    AUD_CHECK(input > 0 && output > 0);
    aud_graph_begin(graph);
    AUD_CHECK(aud_graph_connect_events(graph, input, AUD_MIDI_PORT_OUT, output,
                                       AUD_MIDI_PORT_IN) == AUD_OK);
    AUD_CHECK(aud_graph_connect_events(graph, output, AUD_MIDI_PORT_OUT,
                                       AUD_GRAPH_NODE, 0) == AUD_OK);
    AUD_CHECK(aud_graph_commit(graph) > 0);
    AUD_CHECK(aud_graph_start(graph) == AUD_OK);
  }

  // Sends an event to a node, at an offset of the next block when `offset`
  // is given.
  void send(int32_t node, AudEvent event, int64_t offset = -1) {
    if (offset < 0) {
      AUD_CHECK(aud_graph_send_event(graph, node, &event, nullptr, 0) == AUD_OK);
      return;
    }
    AudTimestamp at{};
    at.struct_size = sizeof(AudTimestamp);
    at.domain = AUD_TIME_SAMPLE;
    at.value = aud_graph_sample_position(graph) + offset;
    AUD_CHECK(aud_graph_send_event(graph, node, &event, &at, 0) == AUD_OK);
  }

  AudEvent ump(uint32_t word0, uint32_t word1 = 0, uint32_t port = 0) {
    const uint32_t words[2] = {word0, word1};
    return aud_event_ump(words, word1 == 0 ? 1 : 2, 0, port);
  }

  // Renders offline; appends the notifications.
  void render(uint32_t frames = kFrames) {
    std::vector<std::vector<float>> buffers(outChannels,
                                            std::vector<float>(frames, 0.0f));
    std::vector<float*> pointers;
    for (auto& channel : buffers) pointers.push_back(channel.data());
    AudAudioBus bus{sizeof(AudAudioBus), outChannels, pointers.data()};
    AudOfflineRequest request{};
    request.struct_size = sizeof(AudOfflineRequest);
    request.frames = frames;
    request.block_frames = kFrames;
    request.outputs = &bus;
    request.start_sample_position = aud_graph_sample_position(graph);
    AUD_CHECK(aud_graph_render_offline(graph, &request) == AUD_OK);
    takeNotifications();
  }

  // Renders like a stream, on this thread.
  void renderLive() {
    AudRenderRequest request{};
    request.struct_size = sizeof(AudRenderRequest);
    request.frames = kFrames;
    request.num_output_buses = 1;
    request.outputs = &outBus;
    AUD_CHECK(aud_graph_render(graph, &request) == AUD_OK);
    takeNotifications();
  }

  void takeNotifications() {
    AudGraphNotification buffer[64];
    while (true) {
      const int32_t count = aud_graph_take_notifications(graph, buffer, 64);
      for (int32_t i = 0; i < count; ++i) notifications.push_back(buffer[i]);
      if (count < 64) return;
    }
  }

  // The events that reached the graph's event input, from `node`.
  std::vector<AudEvent> arrived(int32_t node) const {
    std::vector<AudEvent> result;
    for (const AudGraphNotification& n : notifications) {
      if (n.type == AUD_NOTIFY_EVENT && n.node == node) result.push_back(n.event);
    }
    return result;
  }
};

uint32_t midi1(uint32_t status, uint32_t d1, uint32_t d2) {
  return aud_ump_midi1_word(0, status, d1, d2);
}

uint32_t sysex7(uint32_t status, uint32_t bytes) {
  return (3u << 28) | (status << 20) | (bytes << 16);
}

uint32_t sysex8(uint32_t status, uint32_t bytes) {
  return (5u << 28) | (status << 20) | (bytes << 16);
}

}  // namespace

// ............................................................................
// Registration and descriptors

AUD_TEST(nodes_register_refuses_a_bad_host) {
  AUD_CHECK(aud_audio_midi_register(nullptr) == AUD_ERROR_INVALID_ARGUMENT);
  AudHostApi host{};
  AUD_CHECK(aud_audio_midi_register(&host) == AUD_ERROR_INVALID_ARGUMENT);
  struct Calls {
    static int32_t registerType(void*, const AudNodeDescriptor*) {
      return AUD_OK;
    }
  };
  host.register_node_type = Calls::registerType;
  host.struct_size = sizeof(AudHostApi);
  host.abi_major = AUD_ABI_VERSION_MAJOR + 1;
  AUD_CHECK(aud_audio_midi_register(&host) == AUD_ERROR_ABI_MAJOR);
  host.abi_major = AUD_ABI_VERSION_MAJOR;
  host.struct_size = 16;
  AUD_CHECK(aud_audio_midi_register(&host) == AUD_ERROR_ABI_MINOR);
  host.struct_size = sizeof(AudHostApi);
  AUD_CHECK(aud_audio_midi_register(&host) == AUD_OK);
}

AUD_TEST(nodes_register_once_per_graph) {
  Fixture f;
  AUD_CHECK(aud_audio_midi_register(f.host()) == AUD_ERROR_DUPLICATE_TYPE);
  const AudNodeDescriptor* input =
      aud_graph_node_type_by_id(f.graph, AUD_MIDI_INPUT_TYPE_ID);
  const AudNodeDescriptor* output =
      aud_graph_node_type_by_id(f.graph, AUD_MIDI_OUTPUT_TYPE_ID);
  AUD_CHECK(input != nullptr && output != nullptr);
  for (const AudNodeDescriptor* d : {input, output}) {
    AUD_CHECK(d->abi_major == AUD_ABI_VERSION_MAJOR);
    AUD_CHECK(d->abi_minor == AUD_ABI_VERSION_MINOR);
    AUD_CHECK(d->num_input_buses == 0 && d->num_output_buses == 0);
    AUD_CHECK(d->num_event_inputs == 1 && d->num_event_outputs == 1);
    AUD_CHECK(std::strcmp(d->event_inputs[0].id, "in") == 0);
    AUD_CHECK(std::strcmp(d->event_outputs[0].id, "out") == 0);
    AUD_CHECK(d->num_string_keys == 2);
    AUD_CHECK(std::strcmp(d->string_keys[0].id, "port_id") == 0);
    AUD_CHECK(d->string_keys[0].key == AUD_MIDI_KEY_PORT_ID);
    AUD_CHECK(std::strcmp(d->string_keys[1].id, "port_fingerprint") == 0);
    AUD_CHECK(d->string_keys[1].key == AUD_MIDI_KEY_PORT_FINGERPRINT);
    AUD_CHECK((d->capabilities & AUD_NODE_CAP_EVENTS) != 0);
    AUD_CHECK((d->capabilities & AUD_NODE_CAP_EVENT_OUTPUT) != 0);
    AUD_CHECK((d->capabilities & AUD_NODE_CAP_STRINGS) != 0);
  }
  AUD_CHECK(input->num_params == 0);
  AUD_CHECK(output->num_params == 1);
  AUD_CHECK(std::strcmp(output->params[0].id, "sysex") == 0);
  AUD_CHECK((output->params[0].flags & AUD_PARAM_BOOLEAN) != 0);
  AUD_CHECK(output->params[0].default_value == 0.0f);
}

// ............................................................................
// Pass-through

AUD_TEST(nodes_pass_events_through_at_their_offset) {
  Fixture f;
  f.wire();
  f.render();  // the revision is adopted
  f.send(f.input, f.ump(midi1(0x90, 60, 100)), 0);
  f.send(f.input, f.ump(midi1(0xB0, 64, 127)), 100);
  f.send(f.input, aud_event_control_float(7, 0.5f, 0, 0), 200);
  uint32_t words[2];
  aud_ump_midi2_note(0, 0, 0, 60, 0, 0, 0, words);
  f.send(f.input, f.ump(words[0], words[1]), 255);
  f.render();
  const std::vector<AudEvent> events = f.arrived(f.output);
  AUD_CHECK(events.size() == 4);
  if (events.size() != 4) return;
  AUD_CHECK(events[0].type == AUD_EVENT_UMP);
  AUD_CHECK(events[0].words[0] == midi1(0x90, 60, 100));
  AUD_CHECK(events[0].sample_offset == 0);
  AUD_CHECK(events[1].words[0] == midi1(0xB0, 64, 127));
  AUD_CHECK(events[1].sample_offset == 100);
  AUD_CHECK(events[2].type == AUD_EVENT_CONTROL);
  AUD_CHECK(events[2].words[0] == 7);
  AUD_CHECK(events[2].sample_offset == 200);
  AUD_CHECK(events[3].words[0] == words[0]);
  AUD_CHECK(events[3].words[1] == words[1]);
  AUD_CHECK(events[3].sample_offset == 255);
  AUD_CHECK(f.arrived(f.input).empty());
}

AUD_TEST(nodes_pass_a_chord_in_one_block) {
  Fixture f;
  f.wire();
  f.render();
  for (uint32_t note = 0; note < 64; ++note) {
    f.send(f.input, f.ump(midi1(0x90, note, 100)), note);
  }
  f.render();
  const std::vector<AudEvent> events = f.arrived(f.output);
  AUD_CHECK(events.size() == 64);
  for (size_t i = 0; i < events.size(); ++i) {
    AUD_CHECK(aud_ump_note(events[i].words[0]) == i);
    AUD_CHECK(events[i].sample_offset == i);
  }
}

AUD_TEST(nodes_output_drops_sysex_unless_the_parameter_is_on) {
  Fixture f;
  f.wire();
  f.render();
  f.send(f.input, f.ump(sysex7(0, 2), 0x01020000u));
  f.send(f.input, f.ump(sysex8(1, 3), 0x01020300u));
  f.send(f.input, f.ump(midi1(0x90, 60, 100)));
  f.render();
  std::vector<AudEvent> events = f.arrived(f.output);
  AUD_CHECK(events.size() == 1);
  AUD_CHECK(events[0].words[0] == midi1(0x90, 60, 100));
  f.notifications.clear();
  // The parameter, as a parameter event and as a parameter change.
  f.send(f.output, aud_event_param(AUD_MIDI_OUTPUT_PARAM_SYSEX, 1.0f, 0, 0));
  f.send(f.input, f.ump(sysex7(0, 2), 0x01020000u));
  f.send(f.input, f.ump(sysex8(1, 3), 0x01020300u));
  f.render();
  events = f.arrived(f.output);
  AUD_CHECK(events.size() == 2);
  if (events.size() == 2) {
    AUD_CHECK(events[0].words[0] == sysex7(0, 2));
    AUD_CHECK(events[0].words[1] == 0x01020000u);
    AUD_CHECK(events[1].words[0] == sysex8(1, 3));
  }
  f.notifications.clear();
  AUD_CHECK(aud_graph_set_param(f.graph, f.output, AUD_MIDI_OUTPUT_PARAM_SYSEX,
                                0.0f, 0) == AUD_OK);
  f.send(f.input, f.ump(sysex7(0, 2), 0x01020000u));
  f.send(f.input, f.ump(midi1(0x80, 60, 0)));
  f.render();
  events = f.arrived(f.output);
  AUD_CHECK(events.size() == 1);
  AUD_CHECK(events[0].words[0] == midi1(0x80, 60, 0));
}

AUD_TEST(nodes_input_passes_sysex_and_ignores_parameter_events) {
  Fixture f;
  f.input = aud_graph_create_node(f.graph, AUD_MIDI_INPUT_TYPE_ID, nullptr);
  aud_graph_begin(f.graph);
  AUD_CHECK(aud_graph_connect_events(f.graph, f.input, AUD_MIDI_PORT_OUT,
                                     AUD_GRAPH_NODE, 0) == AUD_OK);
  AUD_CHECK(aud_graph_commit(f.graph) > 0);
  AUD_CHECK(aud_graph_start(f.graph) == AUD_OK);
  f.render();
  f.send(f.input, f.ump(sysex7(0, 2), 0x01020000u));
  f.send(f.input, aud_event_param(0, 1.0f, 0, 0));
  f.send(f.input, f.ump(sysex8(3, 1), 0x01000000u));
  f.render();
  const std::vector<AudEvent> events = f.arrived(f.input);
  AUD_CHECK(events.size() == 2);
  if (events.size() == 2) {
    AUD_CHECK(events[0].words[0] == sysex7(0, 2));
    AUD_CHECK(events[1].words[0] == sysex8(3, 1));
  }
}

// ............................................................................
// Strings

AUD_TEST(nodes_keep_the_port_id_and_the_fingerprint) {
  Fixture f;
  f.wire();
  for (int32_t node : {f.input, f.output}) {
    AUD_CHECK(aud_graph_set_string(f.graph, node, AUD_MIDI_KEY_PORT_ID,
                                   "coremidi:12345") == AUD_OK);
    AUD_CHECK(aud_graph_set_string(f.graph, node, AUD_MIDI_KEY_PORT_FINGERPRINT,
                                   "Acme|Keys|SN1|input|0") == AUD_OK);
    AUD_CHECK(aud_graph_set_string(f.graph, node, AUD_MIDI_KEY_PORT_ID, "") ==
              AUD_OK);
    AUD_CHECK(aud_graph_set_string(f.graph, node, AUD_MIDI_NUM_KEYS, "x") !=
              AUD_OK);
  }
  // The strings live on the control thread; a block in between changes
  // nothing.
  f.render();
  f.send(f.input, f.ump(midi1(0x90, 60, 100)));
  f.render();
  AUD_CHECK(f.arrived(f.output).size() == 1);
}

// ............................................................................
// The rtsan probe

namespace {

// aud.test.probe: allocates on the audio thread when AUD_TEST_RTSAN_PROBE
// is set; scripts/test-native.js checks that the rtsan run catches it, so
// that the run's silence about the nodes means something.
const bool g_probe = std::getenv("AUD_TEST_RTSAN_PROBE") != nullptr;
char* volatile g_probeSink = nullptr;

void* probeCreate(const AudNodeDescriptor*, const AudHostApi*) {
  return new int(0);
}
void probeDestroy(void* instance) { delete static_cast<int*>(instance); }
int32_t probePrepare(void*, const AudPrepareInfo*) { return AUD_OK; }
void probeReset(void*, uint32_t) {}
void probeSetParam(void*, uint32_t, float) {}
void probeProcess(void*, const AudProcessContext*) {
  if (g_probe) {
    g_probeSink = new char[16];
    delete[] g_probeSink;
  }
}

const AudEventPortDescriptor kProbeInlets[] = {
    {sizeof(AudEventPortDescriptor), "in", "Input", AUD_EVENT_PORT_MIDI, 0},
};

const AudNodeVTable kProbeVTable = {
    sizeof(AudNodeVTable), probeCreate, probeDestroy, probePrepare,
    probeReset,            probeSetParam, probeProcess, nullptr,
    nullptr,               nullptr,     nullptr,      nullptr,
};

const AudNodeDescriptor kProbeDescriptor = {
    sizeof(AudNodeDescriptor),
    AUD_ABI_VERSION_MAJOR,
    AUD_ABI_VERSION_MINOR,
    1,
    "aud.test.probe",
    "Probe",
    "Audanika",
    AUD_NODE_CAP_VARIABLE_BLOCK | AUD_NODE_CAP_EVENTS,
    0,
    0,
    0,
    nullptr,
    nullptr,
    1,
    0,
    kProbeInlets,
    nullptr,
    0,
    0,
    nullptr,
    nullptr,
    &kProbeVTable,
};

}  // namespace

AUD_TEST(rtsan_probe) {
  Fixture f;
  const AudHostApi* host = f.host();
  AUD_CHECK(host->register_node_type(host->host, &kProbeDescriptor) == AUD_OK);
  f.input = aud_graph_create_node(f.graph, AUD_MIDI_INPUT_TYPE_ID, nullptr);
  const int32_t probe = aud_graph_create_node(f.graph, "aud.test.probe", nullptr);
  AUD_CHECK(f.input > 0 && probe > 0);
  aud_graph_begin(f.graph);
  AUD_CHECK(aud_graph_connect_events(f.graph, f.input, AUD_MIDI_PORT_OUT, probe,
                                     0) == AUD_OK);
  AUD_CHECK(aud_graph_commit(f.graph) > 0);
  AUD_CHECK(aud_graph_start(f.graph) == AUD_OK);
  f.renderLive();
  f.send(f.input, f.ump(midi1(0x90, 60, 100)));
  f.renderLive();
  f.renderLive();
}

int main() { return aud_test::run(); }
