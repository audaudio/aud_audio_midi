// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_audio/aud_audio_ffi.dart';
import 'package:aud_audio_midi/aud_audio_midi_ffi.dart';
import 'package:aud_dsp_sampler/aud_dsp_sampler_ffi.dart';
import 'package:aud_dsp_sampler/testing.dart';
import 'package:aud_midi/aud_midi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'engine_panel.dart';
import 'instruments.dart';
import 'keyboard.dart';

// #############################################################################
/// The keyboard-to-synth demo of S8: a MIDI keyboard plays the sampler
/// through `aud_audio_midi`, with a port picker, the activity of the port,
/// the timing of the input and the measured input to output time.
class MidiPage extends StatefulWidget {
  /// Creates the page on [engine]; [instrument] is written once by the app.
  const MidiPage({
    super.key,
    required this.engine,
    required this.instrument,
    this.midi,
  });

  /// The engine, with the port nodes and the sampler registered.
  final AudEngine engine;

  /// The test instrument of the sampler.
  final Future<AudSfzTestInstrument> instrument;

  /// The MIDI ports; the page opens its own when null.
  final Future<Midi>? midi;

  @override
  State<MidiPage> createState() => MidiPageState();
}

// #############################################################################
/// The state of [MidiPage]; public for the integration tests.
class MidiPageState extends State<MidiPage>
    with SingleTickerProviderStateMixin {
  /// The engine.
  AudEngine get engine => widget.engine;

  /// The MIDI ports, once open.
  Midi? midi;

  /// The bridge, once the ports are open.
  AudMidiBridge? bridge;

  /// The sampler the input plays.
  AudNode? sampler;

  /// The input of the port picked, null before a pick.
  AudMidiInput? input;

  /// The statistics of [input] at the last refresh.
  AudMidiInputStats? stats;

  /// The last input to output time seen, in nanoseconds.
  int? lastLatencyNs;

  /// The notes the on-screen keyboard holds.
  final Set<int> sounding = {};

  /// The last error of the page, shown on it; null without one.
  String? get error => _error;

  /// An instruction shown on top of the page, e.g. by a guided test.
  String? get prompt => _prompt;
  set prompt(String? text) {
    _prompt = text;
    _rebuild();
  }

  @override
  void initState() {
    super.initState();
    _spin.repeat();
    unawaited(_setUp());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    unawaited(_changes?.cancel());
    _spin.dispose();
    unawaited(_tearDown());
    super.dispose();
  }

  // ...........................................................................
  /// Plays [port] on the sampler: opens it as an input the first time,
  /// retargets the input afterwards.
  Future<void> pick(MidiPortInfo port) async {
    final bridge = this.bridge;
    final sampler = this.sampler;
    if (bridge == null || sampler == null) return;
    _error = null;
    try {
      final input = this.input;
      if (input == null) {
        final opened = await bridge.openInput(port);
        engine.graph.transaction(
          (tx) => tx.connectEvents(opened.node, sampler, toPort: _samplerInlet),
        );
        this.input = opened;
      } else {
        await input.retarget(port);
      }
    } on Object catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() {});
  }

  /// The instrument the sampler plays, an index into [Instruments.names].
  int instrumentIndex = 2;

  /// Loads the instrument [index] into the sampler.
  void selectInstrument(int index) {
    final sampler = this.sampler;
    final written = _written;
    if (sampler == null || written == null) return;
    final graph = engine.graph;
    graph
      ..setString(sampler, AudSfzSampler.sfzVirtualPath, written.sfzPath)
      ..setString(sampler, AudSfzSampler.sfzText, Instruments.sfz(index));
    instrumentIndex = index;
    _rebuild();
  }

  /// Connects a Bluetooth LE MIDI device; its ports then appear in the
  /// port picker. iOS shows its own device picker, which also handles the
  /// pairing; elsewhere the app scans and connects the device the user
  /// picks.
  Future<void> connectBluetooth() async {
    final bluetooth = midi?.bluetooth;
    if (bluetooth == null) {
      setState(() => _error = 'No Bluetooth MIDI on this platform');
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android &&
        !await _bluetoothPermitted()) {
      setState(
        () =>
            _error = 'Bluetooth MIDI needs the permission to scan and connect',
      );
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      String? error;
      try {
        await bluetooth.showSystemDevicePicker();
      } on Object catch (e) {
        error = '$e';
      }
      if (mounted) setState(() => _error = error);
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<MidiBlePeripheralInfo>(
      context: context,
      builder: (context) => _BluetoothDialog(bluetooth: bluetooth),
    );
    if (picked == null) return;
    try {
      // The first connection of a device waits for the pairing request of
      // the operating system; aud_midi's default of 10 s is too short.
      await bluetooth.connect(picked.id, timeout: const Duration(seconds: 30));
      _error = null;
    } on Object catch (e) {
      _error = '$e';
    }
    _rebuild();
  }

  // Asks Android for what a BLE scan and connection need: the nearby
  // devices, to scan and to connect (Android 12 and later), or the
  // location. The location is only needed below Android 12; the manifest
  // declares it with maxSdkVersion 30.
  static Future<bool> _bluetoothPermitted() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final scan = statuses[Permission.bluetoothScan]!;
    final connect = statuses[Permission.bluetoothConnect]!;
    final location = statuses[Permission.locationWhenInUse]!;
    return (scan.isGranted && connect.isGranted) || location.isGranted;
  }

  /// Switches the timing of the input between fixed and immediate.
  Future<void> setTiming(AudSourceTiming timing) async {
    await input?.setTiming(timing);
    if (mounted) setState(() {});
  }

  /// Plays a note from the on-screen keyboard.
  void noteOn(int note, int velocity) {
    sounding.add(note);
    _send(MidiNoteOn(channel: 0, note: note, velocity: velocity));
  }

  /// Ends a note of the on-screen keyboard.
  void noteOff(int note) {
    sounding.remove(note);
    _send(MidiNoteOff(channel: 0, note: note));
  }

  @override
  Widget build(BuildContext context) {
    final bridge = this.bridge;
    final input = this.input;
    final stats = this.stats;
    final ports = bridge?.inputPorts ?? const <MidiPortInfo>[];
    final selected = input == null
        ? null
        : ports.where((p) => p.id == input.port.id).firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_prompt case final prompt?)
          Card(
            key: const Key('midi-prompt'),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                prompt,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
        EngineHeader(engine: engine, onToggled: _rebuild),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DropdownButton<MidiPortInfo>(
                key: const Key('midi-port'),
                isExpanded: true,
                hint: Text(
                  bridge == null
                      ? 'Opening the MIDI ports ...'
                      : ports.isEmpty
                      ? 'No MIDI input'
                      : 'Pick a MIDI input',
                ),
                value: selected,
                items: [
                  for (final port in ports)
                    DropdownMenuItem(
                      value: port,
                      child: Text(
                        port.state == MidiPortState.connected
                            ? port.name
                            : '${port.name} (${port.state.name})',
                      ),
                    ),
                ],
                onChanged: (port) =>
                    port == null ? null : unawaited(pick(port)),
              ),
            ),
            IconButton(
              key: const Key('midi-bluetooth'),
              tooltip: 'Bluetooth MIDI',
              icon: const Icon(Icons.bluetooth),
              onPressed: midi == null
                  ? null
                  : () => unawaited(connectBluetooth()),
            ),
            const SizedBox(width: 12),
            _Activity(active: _active, waiting: input?.isWaiting ?? false),
            const SizedBox(width: 12),
            RotationTransition(
              turns: _spin,
              child: const Icon(Icons.sync, key: Key('midi-spin')),
            ),
          ],
        ),
        DropdownButton<int>(
          key: const Key('midi-instrument'),
          value: instrumentIndex,
          items: [
            for (var i = 0; i < Instruments.names.length; i++)
              DropdownMenuItem(value: i, child: Text(Instruments.names[i])),
          ],
          onChanged: (i) => i == null ? null : selectInstrument(i),
        ),
        const SizedBox(height: 8),
        SegmentedButton<AudSourceTiming>(
          key: const Key('midi-timing'),
          segments: const [
            ButtonSegment(
              value: AudSourceTiming.fixed,
              label: Text('Fixed latency'),
            ),
            ButtonSegment(
              value: AudSourceTiming.immediate,
              label: Text('Immediate'),
            ),
          ],
          selected: {input?.timing ?? AudSourceTiming.fixed},
          onSelectionChanged: input == null
              ? null
              : (s) => unawaited(setTiming(s.single)),
        ),
        const SizedBox(height: 8),
        if (stats != null) ...[
          Text(
            'Path ${stats.path?.name ?? 'waiting for the port'}, '
            'timing ${stats.timing.name}'
            '${stats.timing == AudSourceTiming.fixed ? ', C ${ms(stats.latencyNs)} ms (m ${ms(stats.marginNs)} ms)' : ''}',
          ),
          Text(
            key: const Key('midi-latency'),
            'Input to output: last ${ms(lastLatencyNs)} ms, '
            'median ${ms(stats.source.latencyMedianNs)} ms, '
            'p99 ${ms(stats.source.latencyP99Ns)} ms',
          ),
          Text(
            'Events ${stats.source.delivered}, late ${stats.source.late} '
            '(max ${ms(stats.source.maxLateNs)} ms), delivery p99 '
            '${ms(stats.source.delayP99Ns)} ms, dropped '
            '${stats.source.dropped + (stats.adapter?.droppedFill ?? 0) + (stats.adapter?.sysexDroppedSize ?? 0)}',
          ),
        ],
        if (_error case final error?)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 16),
        SizedBox(
          height: 160,
          child: Keyboard(
            key: const Key('midi-keyboard'),
            onNoteOn: noteOn,
            onNoteOff: noteOff,
            sounding: sounding,
          ),
        ),
        const Divider(),
        EngineNumbers(engine: engine, numbers: engine.numbers),
      ],
    );
  }

  // ######################
  // Private
  // ######################

  static const Duration _refreshInterval = Duration(milliseconds: 100);
  static const Duration _activityTime = Duration(milliseconds: 150);
  static const int _samplerInlet = 0;

  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  StreamSubscription<MidiPortEvent>? _changes;
  Timer? _refresh;
  bool _ownsMidi = false;
  AudSfzTestInstrument? _written;
  int _delivered = 0;
  DateTime _lastEvent = DateTime.fromMillisecondsSinceEpoch(0);
  String? _error;
  String? _prompt;

  bool get _active => DateTime.now().difference(_lastEvent) < _activityTime;

  void _rebuild() {
    if (mounted) setState(() {});
  }

  // Opens the ports and the bridge, creates the sampler and loads the first
  // instrument.
  Future<void> _setUp() async {
    try {
      final written = await widget.instrument;
      final midi = await (widget.midi ?? Midi.open());
      _ownsMidi = widget.midi == null;
      if (!mounted) {
        if (_ownsMidi) await midi.close();
        return;
      }
      this.midi = midi;
      // The packages register when the engine prepares for the first time.
      if (engine.registrations.isEmpty) engine.prepare();
      final graph = engine.graph;
      final created = graph.createNode(AudSfzSampler.typeId);
      graph.transaction((tx) => tx.connect(created, graph.io));
      sampler = created;
      _written = written;
      selectInstrument(instrumentIndex);
      bridge = AudMidiBridge(engine, midi);
      _changes = midi.changes.listen((_) => _rebuild());
      _refresh = Timer.periodic(_refreshInterval, (_) => _onRefresh());
    } on Object catch (e) {
      _error = '$e';
    }
    _rebuild();
  }

  Future<void> _tearDown() async {
    final sampler = this.sampler;
    await bridge?.close();
    if (sampler != null && !engine.graph.isDisposed) {
      engine.graph.transaction((tx) => tx.remove(sampler));
    }
    if (_ownsMidi) await midi?.close();
  }

  void _onRefresh() {
    final input = this.input;
    if (input == null || input.isClosed) return;
    final stats = input.stats;
    if (stats.source.delivered != _delivered) {
      _delivered = stats.source.delivered;
      _lastEvent = DateTime.now();
    }
    lastLatencyNs = stats.recentLatencyNs ?? lastLatencyNs;
    this.stats = stats;
    _rebuild();
  }

  void _send(MidiMessage message) {
    final sampler = this.sampler;
    if (sampler == null) return;
    for (final event in AudUmpEvent.fromMessage(message)) {
      engine.graph.sendEvent(sampler, event);
    }
    setState(() {});
  }
}

// #############################################################################
// A dot that lights while events arrive and turns grey while the port is
// gone.
class _Activity extends StatelessWidget {
  const _Activity({required this.active, required this.waiting});

  final bool active;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('midi-activity'),
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: waiting
            ? scheme.outline
            : active
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
    );
  }
}

// #############################################################################
// Lists the Bluetooth LE MIDI devices of a scan; a tap picks one.
class _BluetoothDialog extends StatefulWidget {
  const _BluetoothDialog({required this.bluetooth});

  final MidiBluetooth bluetooth;

  @override
  State<_BluetoothDialog> createState() => _BluetoothDialogState();
}

class _BluetoothDialogState extends State<_BluetoothDialog> {
  final Map<String, MidiBlePeripheralInfo> _found = {};
  StreamSubscription<MidiBlePeripheralInfo>? _scan;
  String? _error;
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _scan = widget.bluetooth
        .scan(timeout: const Duration(seconds: 15))
        .listen(
          (peripheral) => setState(() => _found[peripheral.id] = peripheral),
          onError: (Object e) => setState(() => _error = '$e'),
          onDone: () {
            if (mounted) setState(() => _scanning = false);
          },
        );
  }

  @override
  void dispose() {
    unawaited(_scan?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_scanning ? 'Bluetooth MIDI: scanning ...' : 'Bluetooth MIDI'),
    content: SizedBox(
      width: 320,
      child: ListView(
        shrinkWrap: true,
        children: [
          if (_error case final error?) Text(error),
          if (_found.isEmpty && _error == null) const Text('No device yet'),
          for (final peripheral in _found.values)
            ListTile(
              title: Text(
                peripheral.name.isEmpty ? peripheral.id : peripheral.name,
              ),
              subtitle: Text(
                peripheral.rssi == null ? '' : '${peripheral.rssi} dBm',
              ),
              onTap: () => Navigator.of(context).pop(peripheral),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}
