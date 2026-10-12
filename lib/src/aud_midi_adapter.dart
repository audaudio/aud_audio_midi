// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'aud_audio_midi_bindings_generated.dart' as bindings;

// #############################################################################
/// The tap adapter of a port (contract C3 of ticket 26): it turns the MIDI
/// of an aud_midi port - UMP words or MIDI 1.0 bytes - into UMP packets and
/// pushes them into an event source of the graph through the addresses of
/// the source's push, release and size functions.
///
/// Two paths call the same native function: a backend of aud_midi calls
/// [tapFunction] with [address] as its user on its receive thread (the
/// native tap of `MidiInput.attachNativeTap`), or Dart calls [pushUmp],
/// [pushBytes] and [gone] from its isolate. One producer at a time.
///
/// [close] stops the adapter synchronously, so the graph may go before the
/// tap is detached; [dispose] frees it after the tap detached.
class AudMidiAdapter {
  /// Creates an adapter that pushes into the event source at [source]
  /// through the functions at [push], [release] and [size] (the addresses
  /// `AudEventSource` of aud_audio_graph offers).
  ///
  /// - [group] the UMP group of MIDI 1.0 bytes, 0 to 15
  /// - [maxSysexBytes] a longer SysEx is dropped; 0 means 64 KiB
  /// - [capacity] the source's capacity for the half-full rule; 0 means the
  ///   graph's default of 4096
  /// - [size] 0 switches the half-full rule off
  ///
  /// Throws an [ArgumentError] when the native side refuses the config.
  AudMidiAdapter({
    required int source,
    required int push,
    required int release,
    int size = 0,
    int group = 0,
    int maxSysexBytes = 0,
    int capacity = 0,
  }) {
    final config = calloc<bindings.AudMidiAdapterConfig>();
    try {
      config.ref
        ..struct_size = sizeOf<bindings.AudMidiAdapterConfig>()
        ..group = group
        ..max_sysex_bytes = maxSysexBytes
        ..capacity = capacity
        ..source = Pointer.fromAddress(source)
        ..push = Pointer.fromAddress(push)
        ..release = Pointer.fromAddress(release)
        ..size = Pointer.fromAddress(size);
      _pointer = bindings.aud_audio_midi_adapter_create(config);
    } finally {
      calloc.free(config);
    }
    if (_pointer == nullptr) {
      throw ArgumentError(
        'The adapter was refused: a source, push and release are needed '
        'and the group must be 0 to 15',
      );
    }
    _buffer = calloc<Uint8>(_bufferBytes);
  }

  // ...........................................................................
  /// Pushes the UMP packets in [words] (one or more complete packets) with
  /// their arrival time in host ns.
  void pushUmp(List<int> words, {required int hostTimeNs}) {
    _checkAlive();
    final bytes = _reserve(words.length * 4);
    _buffer.cast<Uint32>().asTypedList(words.length).setAll(0, words);
    bindings.aud_audio_midi_tap(
      _pointer.cast(),
      bindings.AUD_MIDI_TAP_UMP,
      _buffer.cast(),
      bytes ~/ 4,
      hostTimeNs,
    );
  }

  /// Pushes [bytes] of a MIDI 1.0 byte stream with their arrival time in
  /// host ns; a message may span calls.
  void pushBytes(List<int> bytes, {required int hostTimeNs}) {
    _checkAlive();
    _reserve(bytes.length);
    _buffer.asTypedList(bytes.length).setAll(0, bytes);
    bindings.aud_audio_midi_tap(
      _pointer.cast(),
      bindings.AUD_MIDI_TAP_BYTES,
      _buffer.cast(),
      bytes.length,
      hostTimeNs,
    );
  }

  /// Reports that the port disappeared or went offline at [hostTimeNs]:
  /// the source's release is raised.
  void gone({required int hostTimeNs}) {
    _checkAlive();
    bindings.aud_audio_midi_tap(
      _pointer.cast(),
      bindings.AUD_MIDI_TAP_GONE,
      nullptr,
      0,
      hostTimeNs,
    );
  }

  /// Closes the adapter: when it returns, the tap never touches the source
  /// again - a call in flight on the receive thread is waited for, later
  /// calls return at once and count as [AudMidiAdapterStats.droppedClosed].
  void close() {
    _checkAlive();
    bindings.aud_audio_midi_adapter_close(_pointer);
    _closed = true;
  }

  /// Frees the adapter, after the tap detached; closes it first.
  void dispose() {
    if (isDisposed) return;
    bindings.aud_audio_midi_adapter_destroy(_pointer);
    calloc.free(_buffer);
    _pointer = nullptr;
    _closed = true;
  }

  // ...........................................................................
  /// The counters of the adapter.
  AudMidiAdapterStats get stats {
    _checkAlive();
    final native = calloc<bindings.AudMidiAdapterStats>();
    try {
      native.ref.struct_size = sizeOf<bindings.AudMidiAdapterStats>();
      bindings.aud_audio_midi_adapter_stats(_pointer, native);
      return AudMidiAdapterStats(
        pushed: native.ref.pushed,
        rejected: native.ref.rejected,
        sysexDroppedSize: native.ref.sysex_dropped_size,
        droppedFill: native.ref.dropped_fill,
        gone: native.ref.gone,
        malformed: native.ref.malformed,
        droppedClosed: native.ref.dropped_closed,
      );
    } finally {
      calloc.free(native);
    }
  }

  /// The address of the adapter: the `user` of [tapFunction], e.g. for
  /// aud_midi's `MidiNativeTap`.
  int get address => _pointer.address;

  /// Whether [close] or [dispose] ran.
  bool get isClosed => _closed;

  /// Whether [dispose] ran.
  bool get isDisposed => _pointer == nullptr;

  /// The address of `aud_audio_midi_tap`, the `AudMidiTapFunction` a
  /// backend calls with [address] as its user.
  static int get tapFunction =>
      Native.addressOf<NativeFunction<bindings.AudMidiTapFunctionFunction>>(
        bindings.aud_audio_midi_tap,
      ).address;

  // ...........................................................................
  Pointer<bindings.AudMidiAdapter> _pointer = nullptr;
  Pointer<Uint8> _buffer = nullptr;
  int _bufferBytes = 4096;
  bool _closed = false;

  void _checkAlive() {
    if (isDisposed) throw StateError('The adapter is disposed');
  }

  // Makes the buffer hold `bytes`; returns the bytes.
  int _reserve(int bytes) {
    if (bytes > _bufferBytes) {
      calloc.free(_buffer);
      _bufferBytes = bytes;
      _buffer = calloc<Uint8>(bytes);
    }
    return bytes;
  }
}

// #############################################################################
/// The counters of an [AudMidiAdapter].
class AudMidiAdapterStats {
  /// Creates the counters.
  const AudMidiAdapterStats({
    this.pushed = 0,
    this.rejected = 0,
    this.sysexDroppedSize = 0,
    this.droppedFill = 0,
    this.gone = 0,
    this.malformed = 0,
    this.droppedClosed = 0,
  });

  /// The packets the source accepted.
  final int pushed;

  /// The packets the source refused, e.g. with a full queue.
  final int rejected;

  /// The SysEx dropped for exceeding the cap.
  final int sysexDroppedSize;

  /// The SysEx and clocks dropped while the source was over half full.
  final int droppedFill;

  /// The GONE reports, each of which raised a release.
  final int gone;

  /// The bytes and packets the parser threw away.
  final int malformed;

  /// The calls after [AudMidiAdapter.close], returned at once.
  final int droppedClosed;

  /// The counters as a map, e.g. for a report.
  Map<String, int> toJson() => {
    'pushed': pushed,
    'rejected': rejected,
    'sysexDroppedSize': sysexDroppedSize,
    'droppedFill': droppedFill,
    'gone': gone,
    'malformed': malformed,
    'droppedClosed': droppedClosed,
  };

  @override
  String toString() => 'AudMidiAdapterStats(${toJson()})';
}
