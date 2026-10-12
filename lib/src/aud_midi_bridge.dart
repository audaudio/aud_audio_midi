// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:math' as math;

import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_midi/aud_midi.dart';

import 'aud_audio_midi_ffi.dart';
import 'aud_midi_adapter.dart';
import 'aud_midi_clock.dart';
import 'aud_midi_nodes.dart';

// #############################################################################
/// How a binding feeds its event source (midi-002).
enum AudMidiPath {
  /// The backend calls the adapter on its receive thread (native-001).
  native,

  /// The bridge receives the packets in Dart and pushes them through FFI.
  dart,
}

// #############################################################################
/// The options of an [AudMidiBridge].
class AudMidiBridgeOptions {
  /// Creates the options.
  const AudMidiBridgeOptions({
    this.timing = AudSourceTiming.fixed,
    this.marginNs = 1000000,
    this.marginSamples = 1000,
    this.bluetoothMarginNs = 15000000,
    this.bluetoothMarginCapNs = 30000000,
    this.preferNative = true,
    this.capacity = 4096,
    this.maxSysexBytes = 65536,
    this.refreshInterval = const Duration(seconds: 1),
  });

  /// The timing of new inputs (midi-003).
  final AudSourceTiming timing;

  /// The smallest m of midi-003: the margin of the fixed latency in
  /// nanoseconds.
  final int marginNs;

  /// The events after which an input takes its own 99.9th percentile of
  /// the delivery delay as m, when it is larger than [marginNs].
  final int marginSamples;

  /// The smallest m of a Bluetooth LE port: one connection interval, since
  /// BLE MIDI carries the sender's timestamps.
  final int bluetoothMarginNs;

  /// The largest m a Bluetooth LE port calibrates to; rarer, longer delays
  /// play late.
  final int bluetoothMarginCapNs;

  /// Whether inputs take the native path where the backend offers it.
  final bool preferNative;

  /// The events an input's source holds.
  final int capacity;

  /// The longest SysEx an input passes on.
  final int maxSysexBytes;

  /// How often the bridge looks at the engine's timing while it runs.
  final Duration refreshInterval;
}

// #############################################################################
/// The bridge between the ports of `aud_midi` and an engine (S8, midi-002).
///
/// An input port becomes an `aud.midi.input` node whose outlet the app
/// connects to its instruments; an event source of the graph feeds the
/// node, from the backend's receive thread through a native tap
/// (native-001) or from Dart. An output port becomes an `aud.midi.output`
/// node; what reaches its inlet leaves through `aud_midi` at the time its
/// frame reaches the audio output. The bridge keeps its bindings by port
/// id: a port that goes releases its notes, and a port that returns - under
/// the same id, or on Android under a new id with the same fingerprint
/// (ports-001) - plays again. It is an extension of the engine, so the
/// engine closes it before it disposes the graph.
class AudMidiBridge extends AudEngineExtension {
  /// Bridges the ports of [midi] into [engine].
  AudMidiBridge(
    this.engine,
    this.midi, {
    this.options = const AudMidiBridgeOptions(),
    AudMidiClock? clock,
  }) : clock = clock ?? AudMidiClock() {
    engine.addExtension(this);
    _changes = midi.changes.listen(_onPortEvent);
    _notifications = engine.graph.notifications.listen(_onNotification);
    if (engine.state == AudEngineState.running) _startRefresh();
  }

  /// The node package of the port nodes for [AudEngine.new].
  static AudNativeNodePackage get package =>
      AudNativeNodePackage(AudAudioMidi.name, AudAudioMidi.register);

  /// The engine.
  final AudEngine engine;

  /// The MIDI ports.
  final Midi midi;

  /// The options.
  final AudMidiBridgeOptions options;

  /// The mapping between MIDI time and host time.
  final AudMidiClock clock;

  @override
  String get name => AudAudioMidi.name;

  /// Whether the bridge is closed.
  bool get isClosed => _isClosed;

  /// The input ports `aud_midi` knows, also those that are offline.
  List<MidiPortInfo> get inputPorts => [
    for (final port in midi.ports)
      if (port.direction == MidiDirection.input) port,
  ];

  /// The output ports `aud_midi` knows, also those that are offline.
  List<MidiPortInfo> get outputPorts => [
    for (final port in midi.ports)
      if (port.direction == MidiDirection.output) port,
  ];

  /// The open inputs.
  List<AudMidiInput> get inputs => List.unmodifiable(_inputs);

  /// The open outputs.
  List<AudMidiOutput> get outputs => List.unmodifiable(_outputs.values);

  /// P of midi-003: the 99.9th percentile of the gaps between two renders
  /// since the last reset of the time filter; before there are any, the
  /// stream's period (its burst, else its buffer). The longest gap and the
  /// graph's prepared largest block would let one outlier set the latency.
  int get periodNs {
    final timing = engine.timing;
    final percentile = timing.valid ? timing.periodPercentileNs(0.999) : null;
    if (percentile != null) return percentile;
    final format = engine.format;
    return streamPeriodNs(
      sampleRate: format.sampleRate,
      burstFrames: format.burstFrames,
      bufferFrames: format.bufferFrames,
    );
  }

  /// The period of a stream in nanoseconds: its burst, else its buffer, at
  /// [sampleRate]; 0 without a rate.
  static int streamPeriodNs({
    required double sampleRate,
    required int burstFrames,
    required int bufferFrames,
  }) {
    if (sampleRate <= 0) return 0;
    final frames = burstFrames > 0 ? burstFrames : bufferFrames;
    return (frames * 1e9 / sampleRate).round();
  }

  /// P plus L of midi-003: the period plus the output latency the stream
  /// reported with the last block.
  int get baseLatencyNs {
    final timing = engine.timing;
    final output = timing.valid ? timing.outputLatencyNs.round() : 0;
    return periodNs + output;
  }

  /// C of midi-003 with the smallest margin; an input's own margin may be
  /// larger ([AudMidiInput.marginNs]).
  int get fixedLatencyNs => baseLatencyNs + options.marginNs;

  // ...........................................................................
  /// Opens [port] as an input: an `aud.midi.input` node - [node] when the
  /// graph already has one, e.g. from a document - fed by an event source
  /// with [timing]. [path] forces the path; by default the native one where
  /// the backend offers it.
  Future<AudMidiInput> openInput(
    MidiPortInfo port, {
    AudNode? node,
    AudSourceTiming? timing,
    AudMidiPath? path,
    String? name,
  }) async {
    _checkOpen();
    if (port.direction != MidiDirection.input) {
      throw ArgumentError.value(port.id.value, 'port', 'is not an input');
    }
    final input = AudMidiInput._(
      this,
      _commit(node) ??
          _createNode(AudMidiInputNode.typeId, name ?? _nodeName('in', port)),
      port,
      timing ?? options.timing,
      path,
      node == null,
    );
    try {
      await input._open();
    } catch (_) {
      await input._discard();
      rethrow;
    }
    _inputs.add(input);
    return input;
  }

  /// Opens [port] as an output: an `aud.midi.output` node - [node] when the
  /// graph already has one - whose events leave through `aud_midi`.
  Future<AudMidiOutput> openOutput(
    MidiPortInfo port, {
    AudNode? node,
    String? name,
  }) async {
    _checkOpen();
    if (port.direction != MidiDirection.output) {
      throw ArgumentError.value(port.id.value, 'port', 'is not an output');
    }
    final graph = engine.graph;
    final output = AudMidiOutput._(
      this,
      _commit(node) ??
          _createNode(AudMidiOutputNode.typeId, name ?? _nodeName('out', port)),
      port,
      node == null,
    );
    graph.transaction((tx) => tx.connectEvents(output.node, graph.io));
    _outputs[output.node.handle] = output;
    return output;
  }

  /// Looks at the engine's timing: sets the latency of the fixed inputs to
  /// the current P + L + m (it follows the output latency of a new route
  /// both ways), and lets the outputs release their notes when the graph
  /// dropped notifications. The bridge
  /// calls it every [AudMidiBridgeOptions.refreshInterval] while the engine
  /// runs.
  void refresh() {
    if (_isClosed) return;
    _applyLatencies();
    final dropped = engine.stats.notificationsDropped;
    if (dropped > _notificationsDropped) {
      _notificationsDropped = dropped;
      _releaseNotes();
    }
  }

  /// Closes every input and output and leaves the engine; the nodes the
  /// bridge created leave the graph.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _refresh?.cancel();
    await _changes.cancel();
    await _notifications.cancel();
    for (final input in List.of(_inputs)) {
      await input.close();
    }
    for (final output in List.of(_outputs.values)) {
      await output.close();
    }
    engine.removeExtension(this);
  }

  // ...........................................................................
  @override
  void engineStarted(AudEngine engine) => _startRefresh();

  @override
  void engineStopping(AudEngine engine) {
    _refresh?.cancel();
    _refresh = null;
  }

  @override
  void engineTimingChanged(AudEngine engine) => _applyLatencies();

  /// Stops every producer before the graph frees the sources: the adapters
  /// close synchronously, so no tap touches a source afterwards; the taps
  /// detach in the background. The outputs release the notes they hold.
  @override
  void engineDisposing(AudEngine engine) {
    _isClosed = true;
    _refresh?.cancel();
    unawaited(_changes.cancel());
    unawaited(_notifications.cancel());
    for (final input in _inputs) {
      input._disposeSync();
    }
    _inputs.clear();
    _releaseNotes();
    _outputs.clear();
  }

  // ######################
  // Private
  // ######################

  final List<AudMidiInput> _inputs = [];

  /// The outputs by the handle of their node.
  final Map<int, AudMidiOutput> _outputs = {};
  late final StreamSubscription<MidiPortEvent> _changes;
  late final StreamSubscription<AudGraphNotification> _notifications;
  Timer? _refresh;
  bool _isClosed = false;
  int _notificationsDropped = 0;
  int _nextToken = 1;

  void _checkOpen() {
    if (_isClosed) throw StateError('The MIDI bridge is closed');
  }

  /// Sets the latency of the fixed inputs to the current P + L + m.
  void _applyLatencies() {
    final base = baseLatencyNs;
    for (final input in _inputs) {
      input._setLatency(base + input.marginNs);
    }
  }

  /// Lets every output release the notes it holds.
  void _releaseNotes() {
    for (final output in _outputs.values) {
      output.releaseNotes();
    }
  }

  /// Writes the id and the fingerprint of [port] to the strings of [node].
  void _writeStrings(AudNode node, MidiPortInfo port) {
    engine.graph
      ..setString(node, AudMidiPortNode.portId, port.id.value)
      ..setString(node, AudMidiPortNode.portFingerprint, port.fingerprint);
  }

  /// Commits [node], which may come from a transaction still open.
  AudNode? _commit(AudNode? node) {
    if (node != null) engine.graph.transaction((_) {});
    return node;
  }

  /// A node id for [port] that the graph does not use yet, e.g.
  /// `midi_in_loop_out` for the port "loop out".
  String _nodeName(String direction, MidiPortInfo port) {
    final words = port.name
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final base = words.isEmpty ? 'midi_$direction' : 'midi_${direction}_$words';
    final graph = engine.graph;
    var name = base;
    for (var i = 2; graph.nodeNamed(name) != null; i++) {
      name = '${base}_$i';
    }
    return name;
  }

  AudNode _createNode(String typeId, String name) {
    final graph = engine.graph;
    final node = graph.createNode(typeId, name: name);
    graph.transaction((_) {});
    return node;
  }

  void _startRefresh() {
    _refresh?.cancel();
    _refresh = Timer.periodic(options.refreshInterval, (_) => refresh());
  }

  int _token() => _nextToken++;

  void _onPortEvent(MidiPortEvent event) {
    for (final input in List.of(_inputs)) {
      input._onPortEvent(event);
    }
    for (final output in _outputs.values) {
      output._onPortEvent(event);
    }
  }

  void _onNotification(AudGraphNotification notification) {
    if (notification is! AudEventNotification) return;
    _outputs[notification.node]?._send(notification);
  }
}

// #############################################################################
/// The statistics of an [AudMidiInput].
class AudMidiInputStats {
  /// Creates the statistics.
  const AudMidiInputStats({
    required this.path,
    required this.timing,
    required this.latencyNs,
    required this.marginNs,
    required this.source,
    required this.adapter,
    required this.recentLatencyNs,
  });

  /// The path that feeds the source; null while the port is gone.
  final AudMidiPath? path;

  /// The timing of the source.
  final AudSourceTiming timing;

  /// C of the fixed timing in nanoseconds.
  final int latencyNs;

  /// m of midi-003 for the input in nanoseconds.
  final int marginNs;

  /// The statistics of the source: delivered, late, delays, latencies.
  final AudEventSourceStats source;

  /// The statistics of the adapter: parsed, dropped, gone; null while the
  /// port is gone.
  final AudMidiAdapterStats? adapter;

  /// The median input to output time of the events delivered since the
  /// statistics were read before; null when none arrived.
  final int? recentLatencyNs;

  /// The statistics as JSON.
  Map<String, Object?> toJson() => {
    'path': path?.name,
    'timing': timing.name,
    'latencyNs': latencyNs,
    'marginNs': marginNs,
    'recentLatencyNs': recentLatencyNs,
    'source': source.toJson(),
    'adapter': adapter?.toJson(),
  };
}

// #############################################################################
/// An input port bound to an `aud.midi.input` node.
class AudMidiInput {
  AudMidiInput._(
    this.bridge,
    this.node,
    this._port,
    this._timing,
    this._forcedPath,
    this._ownsNode,
  );

  /// The bridge.
  final AudMidiBridge bridge;

  /// The node whose outlet carries the port's events.
  final AudNode node;

  /// The port, as `aud_midi` last reported it.
  MidiPortInfo get port => _port;

  /// The timing of the source.
  AudSourceTiming get timing => _timing;

  /// The path that feeds the source; null while the port is gone.
  AudMidiPath? get path => _path;

  /// Whether the port is gone and the input waits for it - also while the
  /// tap stays attached to a port that went offline (CoreMIDI keeps it).
  bool get isWaiting => _path == null || _gone;

  /// Whether the input is closed.
  bool get isClosed => _isClosed;

  /// The source of the node.
  AudEventSource get source => _source;

  /// m of midi-003 for this input: the bridge's smallest margin, raised to
  /// the input's own 99.9th percentile of the delivery delay once
  /// [AudMidiBridgeOptions.marginSamples] events measured it, but at most
  /// one period P - a rarer, longer delay (e.g. the burst a keyboard sends
  /// when its port opens) plays late instead of delaying every note. It
  /// never shrinks for the life of the source.
  int get marginNs => _marginOf(_source.stats);

  /// The statistics; [AudMidiInputStats.recentLatencyNs] covers the events
  /// since the last read.
  AudMidiInputStats get stats {
    final stats = _source.stats;
    final histogram = stats.latencyHistogram;
    final previous = _histogram;
    _histogram = histogram;
    final margin = _marginOf(stats);
    return AudMidiInputStats(
      path: _path,
      timing: _timing,
      latencyNs: _source.latencyNs,
      marginNs: margin,
      source: stats,
      adapter: _adapter?.stats,
      recentLatencyNs: _recentMedianNs(previous, histogram),
    );
  }

  // ...........................................................................
  /// Binds the input to [port]; the node and its connections stay.
  Future<void> retarget(MidiPortInfo port) => _serial(() async {
    await _detachProducer();
    _port = port;
    _gone = false;
    bridge._writeStrings(node, _port);
    await _attachProducer();
  });

  /// Gives the input a new timing; the source is created again.
  Future<void> setTiming(AudSourceTiming timing) => _serial(() async {
    if (timing == _timing) return;
    await _detachProducer();
    _source.dispose();
    _timing = timing;
    _source = _createSource();
    await _attachProducer();
  });

  /// Closes the input: the producer detaches, the source goes and the
  /// node leaves the graph when the bridge created it.
  Future<void> close() => _serial(() async {
    if (_isClosed) return;
    _isClosed = true;
    await _detachProducer();
    _source.dispose();
    bridge._inputs.remove(this);
    if (_ownsNode) {
      bridge.engine.graph.transaction((tx) => tx.remove(node));
    }
  });

  // ######################
  // Private
  // ######################

  final AudMidiPath? _forcedPath;
  final bool _ownsNode;
  MidiPortInfo _port;
  AudSourceTiming _timing;
  late AudEventSourceFfi _source;
  AudMidiPath? _path;
  AudMidiAdapter? _adapter;
  MidiNativeTapHandle? _tap;
  StreamSubscription<MidiPacket>? _packets;
  int _producer = 0;
  int _margin = 0;
  bool _hasSource = false;
  bool _gone = false;
  List<int>? _histogram;
  bool _isClosed = false;
  Future<void> _queue = Future.value();

  Future<void> _serial(Future<void> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.catchError((Object _) {});
    return result;
  }

  /// The smallest m of the port's transport.
  int _floorNs() => _port.transport == MidiTransport.bluetoothLe
      ? bridge.options.bluetoothMarginNs
      : bridge.options.marginNs;

  /// m of [marginNs] for [stats]; raises the measured margin, which never
  /// shrinks.
  int _marginOf(AudEventSourceStats stats) {
    final options = bridge.options;
    final bluetooth = _port.transport == MidiTransport.bluetoothLe;
    final floor = _floorNs();
    final cap = bluetooth
        ? options.bluetoothMarginCapNs
        : math.max(options.marginNs, bridge.periodNs);
    if (stats.delivered >= options.marginSamples) {
      final measured = stats.delayPercentileNs(0.999) ?? 0;
      final capped = math.min(measured, cap);
      if (capped > _margin) _margin = capped;
    }
    return math.max(floor, _margin);
  }

  /// Removes what [_open] created after it failed: the source and, when the
  /// bridge created it, the node.
  Future<void> _discard() async {
    _isClosed = true;
    if (_hasSource && !_source.isDisposed) _source.dispose();
    if (_ownsNode) {
      bridge.engine.graph.transaction((tx) => tx.remove(node));
    }
  }

  Future<void> _open() => _serial(() async {
    bridge._writeStrings(node, _port);
    _source = _createSource();
    _hasSource = true;
    await _attachProducer();
  });

  AudEventSourceFfi _createSource() =>
      bridge.engine.graph.createEventSource(
            node,
            timing: _timing,
            latencyNs: _timing == AudSourceTiming.fixed
                ? bridge.baseLatencyNs + _floorNs()
                : 0,
            capacity: bridge.options.capacity,
          )
          as AudEventSourceFfi;

  /// Attaches a producer when the port is there: the native tap where the
  /// backend offers it, else the Dart path.
  Future<void> _attachProducer() async {
    final input = bridge.midi.input(_port.id);
    if (input == null || _port.state != MidiPortState.connected) {
      _path = null;
      return;
    }
    final token = bridge._token();
    _source.attach(token);
    _producer = token;
    final adapter = AudMidiAdapter(
      source: _source.address,
      push: AudEventSourceFfi.pushFunctionAddress,
      release: AudEventSourceFfi.releaseFunctionAddress,
      size: AudEventSourceFfi.sizeFunctionAddress,
      group: _port.group,
      maxSysexBytes: bridge.options.maxSysexBytes,
      capacity: _source.capacity,
    );
    _adapter = adapter;
    // A forced native path always tries the tap, so a backend without one
    // refuses it instead of the input falling back to Dart.
    final native =
        _forcedPath == AudMidiPath.native ||
        (_forcedPath != AudMidiPath.dart &&
            bridge.options.preferNative &&
            input.supportsNativeTap);
    if (native) {
      try {
        _tap = await input.attachNativeTap(
          MidiNativeTap(
            function: AudMidiAdapter.tapFunction,
            user: adapter.address,
          ),
        );
        _path = AudMidiPath.native;
        return;
      } on MidiException {
        if (_forcedPath == AudMidiPath.native) {
          _releaseProducer(adapter);
          rethrow;
        }
      }
    }
    // A port that goes arrives as a port event, which releases the notes.
    _packets = input.packets.listen((packet) => _push(adapter, packet));
    _path = AudMidiPath.dart;
  }

  /// Lets the producer of a failed attach go: the source forgets its token,
  /// the adapter goes.
  void _releaseProducer(AudMidiAdapter adapter) {
    _source.detach(_producer);
    _producer = 0;
    _adapter = null;
    adapter.dispose();
  }

  void _push(AudMidiAdapter adapter, MidiPacket packet) {
    final time = bridge.clock.toEngineNs(packet.time);
    switch (packet) {
      case MidiUmpPacket(:final words):
        adapter.pushUmp(words, hostTimeNs: time);
      case MidiBytesPacket(:final bytes):
        adapter.pushBytes(bytes.bytes, hostTimeNs: time);
    }
  }

  /// Detaches the producer: the tap returns after its last call, the
  /// stream stops; then the source lets the producer go and the adapter
  /// goes.
  Future<void> _detachProducer() async {
    final tap = _tap;
    final packets = _packets;
    final adapter = _adapter;
    _tap = null;
    _packets = null;
    _adapter = null;
    _path = null;
    if (tap != null) {
      try {
        await tap.detach();
      } on MidiException {
        // The backend detached it already: the port went (Android).
      } on StateError {
        // The MIDI proxy closed first; its host detached the tap.
      }
    }
    await packets?.cancel();
    adapter?.close();
    if (_producer != 0 && !_source.isDisposed) {
      _source.detach(_producer);
    }
    _producer = 0;
    adapter?.dispose();
  }

  void _onPortEvent(MidiPortEvent event) {
    if (_isClosed) return;
    final info = event.port;
    if (info.id == _port.id) {
      _port = info;
      final gone =
          event is MidiPortRemoved || info.state != MidiPortState.connected;
      if (gone) {
        _gone = true;
        _source.release();
        if (event is MidiPortRemoved || _path == AudMidiPath.dart) {
          unawaited(_serial(_detachProducer));
        }
      } else {
        _gone = false;
        if (_path == null) unawaited(_serial(_attachProducer));
      }
      return;
    }
    if (isWaiting &&
        event is MidiPortAdded &&
        info.direction == MidiDirection.input &&
        info.fingerprint == _port.fingerprint &&
        info.state == MidiPortState.connected) {
      unawaited(retarget(info));
    }
  }

  void _setLatency(int latencyNs) {
    if (_isClosed || _timing != AudSourceTiming.fixed) return;
    _source.latencyNs = latencyNs;
  }

  void _disposeSync() {
    _isClosed = true;
    _adapter?.close();
    final packets = _packets;
    final tap = _tap;
    final adapter = _adapter;
    _packets = null;
    _tap = null;
    _adapter = null;
    unawaited(packets?.cancel());
    // The tap may still be called until it detached; the closed adapter
    // returns at once and is freed only after the detach.
    unawaited(
      Future(() async {
        try {
          await tap?.detach();
        } on Object {
          // The MIDI isolate or the port went first.
        }
        adapter?.dispose();
      }),
    );
  }

  static int? _recentMedianNs(List<int>? previous, List<int> current) {
    var total = 0;
    final delta = List<int>.filled(current.length, 0);
    for (var i = 0; i < current.length; i++) {
      final before = previous == null || i >= previous.length ? 0 : previous[i];
      delta[i] = current[i] - before;
      total += delta[i];
    }
    if (total == 0) return null;
    final half = (total + 1) ~/ 2;
    var seen = 0;
    for (var i = 0; i < delta.length; i++) {
      seen += delta[i];
      if (seen >= half) return i * AudEventSourceStats.latencyBinNs;
    }
    // coverage:ignore-start
    return null;
    // coverage:ignore-end
  }
}

// #############################################################################
/// An output port bound to an `aud.midi.output` node.
class AudMidiOutput {
  AudMidiOutput._(this.bridge, this.node, this._port, this._ownsNode) {
    bridge._writeStrings(node, _port);
  }

  /// The bridge.
  final AudMidiBridge bridge;

  /// The node whose inlet takes the events for the port.
  final AudNode node;

  /// The port, as `aud_midi` last reported it.
  MidiPortInfo get port => _port;

  /// Whether the port is gone and the output drops its events.
  bool get isWaiting => _port.state != MidiPortState.connected;

  /// The packets the output sent.
  int get sent => _sent;

  /// The notes that sound on the port: group << 12 | channel << 8 | note.
  Set<int> get heldNotes => Set.unmodifiable(_held);

  // ...........................................................................
  /// Sends a note off for every note that sounds on the port.
  void releaseNotes() {
    final output = bridge.midi.output(_port.id);
    for (final key in _held) {
      final word = AudUmp.midi1Word(
        group: (key >> 12) & 0xF,
        statusByte: (AudUmp.statusNoteOff << 4) | ((key >> 8) & 0xF),
        data1: key & 0x7F,
        data2: 0,
      );
      unawaited(_guard(output?.sendUmp([word])));
    }
    _held.clear();
  }

  /// Closes the output; the node leaves the graph when the bridge created
  /// it.
  Future<void> close() async {
    releaseNotes();
    bridge._outputs.remove(node.handle);
    if (_ownsNode) {
      bridge.engine.graph.transaction((tx) => tx.remove(node));
    }
  }

  // ######################
  // Private
  // ######################

  final bool _ownsNode;
  final Set<int> _held = {};
  MidiPortInfo _port;
  int _sent = 0;

  void _onPortEvent(MidiPortEvent event) {
    final info = event.port;
    if (info.id == _port.id) {
      _port = info;
      if (event is MidiPortRemoved || isWaiting) _held.clear();
      return;
    }
    if (isWaiting &&
        event is MidiPortAdded &&
        info.direction == MidiDirection.output &&
        info.fingerprint == _port.fingerprint) {
      _port = info;
      bridge._writeStrings(node, _port);
    }
  }

  /// Sends the event of [notification] at the host time its frame reaches
  /// the audio output, so an external synth sounds with the engine.
  void _send(AudEventNotification notification) {
    if (isWaiting) return;
    final event = notification.event;
    if (event is! AudUmpEvent) return;
    final words = event.packet.words;
    if (words.isEmpty) return;
    _track(words);
    final timing = bridge.engine.timing;
    final at = timing.valid
        ? bridge.clock.toMidiTime(
            timing.hostTimeAt(notification.samplePosition + event.sampleOffset),
          )
        : null;
    _sent += 1;
    unawaited(_guard(bridge.midi.output(_port.id)?.sendUmp(words, at: at)));
  }

  /// Keeps [heldNotes] up to date with a note on or off in [words].
  void _track(List<int> words) {
    final word0 = words[0];
    if (!AudUmp.isChannelVoice(word0)) return;
    final word1 = words.length > 1 ? words[1] : 0;
    final key =
        AudUmp.group(word0) << 12 |
        AudUmp.channel(word0) << 8 |
        AudUmp.note(word0);
    if (AudUmp.isNoteOn(word0, word1)) {
      _held.add(key);
    } else if (AudUmp.isNoteOff(word0, word1)) {
      _held.remove(key);
    }
  }

  static Future<void> _guard(Future<void>? sending) async {
    try {
      await sending;
    } on MidiException {
      // The port went while the packet travelled; its notes are released.
    }
  }
}
