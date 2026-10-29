// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_with_midi/aud_audio_with_midi_ffi.dart';
import 'package:aud_audio_with_midi/src/aud_audio_with_midi_bindings_generated.dart'
    as bindings;
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// A fake event source: its push, release and size functions are Dart
// callbacks the native tap calls back on this isolate's thread, so the
// Dart path through the adapter is exercised end to end.
class FakeSource {
  FakeSource() {
    _memory = calloc<Uint8>(1);
    _push = NativeCallable.isolateLocal(_onPush, exceptionalReturn: -9);
    _release = NativeCallable.isolateLocal(_onRelease);
    _size = NativeCallable.isolateLocal(_onSize, exceptionalReturn: 0);
  }

  final List<(List<int>, int)> packets = [];
  int releases = 0;
  int size = 0;
  int pushResult = AUD_OK;

  // The packets as nested lists, which a matcher compares deeply.
  List<List<Object>> get pushedAsLists => [
    for (final (words, time) in packets) [words, time],
  ];

  int get address => _memory.address;
  int get push => _push.nativeFunction.address;
  int get release => _release.nativeFunction.address;
  int get sizeFunction => _size.nativeFunction.address;

  void dispose() {
    _push.close();
    _release.close();
    _size.close();
    calloc.free(_memory);
  }

  late final Pointer<Uint8> _memory;
  late final NativeCallable<bindings.AudEventSourcePushFunctionFunction> _push;
  late final NativeCallable<bindings.AudEventSourceReleaseFunctionFunction>
  _release;
  late final NativeCallable<bindings.AudEventSourceSizeFunctionFunction> _size;

  int _onPush(
    Pointer<bindings.AudEventSource> source,
    Pointer<Uint32> words,
    int count,
    int time,
  ) {
    if (pushResult != AUD_OK) return pushResult;
    packets.add((words.asTypedList(count).toList(), time));
    return AUD_OK;
  }

  void _onRelease(Pointer<bindings.AudEventSource> source) => releases += 1;

  int _onSize(Pointer<bindings.AudEventSource> source) => size;
}

void main() {
  late FakeSource source;
  late AudMidiAdapter adapter;

  setUp(() {
    source = FakeSource();
    adapter = AudMidiAdapter(
      source: source.address,
      push: source.push,
      release: source.release,
      size: source.sizeFunction,
      capacity: 16,
      maxSysexBytes: 8,
      group: 2,
    );
  });

  tearDown(() {
    adapter.dispose();
    source.dispose();
  });

  group('AudMidiAdapter', () {
    test('refuses a config without a source', () {
      expect(
        () => AudMidiAdapter(source: 0, push: source.push, release: 1),
        throwsArgumentError,
      );
    });

    test('pushes UMP packets with their time', () {
      adapter.pushUmp([0x20903C64, 0x40903C00, 0x80000000], hostTimeNs: 42);
      expect(source.pushedAsLists, [
        [
          [0x20903C64],
          42,
        ],
        [
          [0x40903C00, 0x80000000],
          42,
        ],
      ]);
      expect(adapter.stats.pushed, 2);
      expect(adapter.stats.malformed, 0);
    });

    test('parses MIDI 1.0 bytes across calls on the group', () {
      adapter.pushBytes([0x90, 60], hostTimeNs: 1);
      adapter.pushBytes([100, 0xF8, 0xF0, 1, 2], hostTimeNs: 2);
      adapter.pushBytes([0xF7, 0x3C], hostTimeNs: 3);
      expect(source.pushedAsLists, [
        [
          [0x22903C64],
          2,
        ],
        [
          [0x12F80000],
          2,
        ],
        [
          [0x32020102, 0],
          3,
        ],
      ]);
      final stats = adapter.stats;
      expect(stats.pushed, 3);
      // 3C after F7: a data byte without a status.
      expect(stats.malformed, 1);
    });

    test('applies the SysEx cap and the half-full rule', () {
      adapter.pushBytes([0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xF7], hostTimeNs: 1);
      // The start packet, and the end packet without data that closes the
      // SysEx the cap cut: type 3, group 2, status end, no bytes.
      expect(source.pushedAsLists, [
        [
          [0x32160102, 0x03040506],
          1,
        ],
        [
          [0x32300000, 0],
          1,
        ],
      ]);
      expect(adapter.stats.sysexDroppedSize, 1);
      expect(adapter.stats.sysexCut, 1);
      expect(adapter.stats.sysexTorn, 0);
      source.size = 9;
      adapter.pushUmp([0x12F80000, 0x30010100, 0, 0x22903C64], hostTimeNs: 2);
      expect(source.packets, hasLength(3));
      expect(source.packets.last.$1, [0x22903C64]);
      expect(adapter.stats.droppedFill, 2);
      source.pushResult = AUD_ERROR_QUEUE_FULL;
      adapter.pushUmp([0x22903C64], hostTimeNs: 3);
      expect(adapter.stats.rejected, 1);
    });

    test('closes a UMP SysEx the source refuses mid-way', () {
      // A SysEx within the cap: the start of 2 bytes is pushed.
      adapter.pushUmp([0x30120102, 0], hostTimeNs: 1);
      // The continue packet is refused with a full queue, the end packet
      // that closes the SysEx is refused too: the SysEx stays torn.
      source.pushResult = AUD_ERROR_QUEUE_FULL;
      adapter.pushUmp([0x30230304, 0x05000000], hostTimeNs: 2);
      source.pushResult = AUD_OK;
      adapter.pushUmp([0x30310600, 0, 0x22903C64], hostTimeNs: 3);
      expect(source.pushedAsLists, [
        [
          [0x30120102, 0],
          1,
        ],
        [
          [0x22903C64],
          3,
        ],
      ]);
      final stats = adapter.stats;
      expect(stats.rejected, 2);
      expect(stats.sysexCut, 1);
      expect(stats.sysexTorn, 1);
    });

    test('raises release on gone', () {
      adapter.gone(hostTimeNs: 5);
      expect(source.releases, 1);
      expect(adapter.stats.gone, 1);
    });

    test('grows its buffer for a long chunk', () {
      final bytes = [0xF0, ...List.filled(6000, 1), 0xF7];
      final big = AudMidiAdapter(
        source: source.address,
        push: source.push,
        release: source.release,
      );
      addTearDown(big.dispose);
      big.pushBytes(bytes, hostTimeNs: 1);
      expect(source.packets, hasLength(1000));
      big.pushUmp(List.filled(2000, 0x12F80000), hostTimeNs: 2);
      expect(source.packets, hasLength(3000));
      expect(big.stats.sysexDroppedSize, 0);
      expect(big.stats.droppedFill, 0);
    });

    test('close stops the tap, dispose frees it', () {
      adapter.pushUmp([0x22903C64], hostTimeNs: 1);
      expect(adapter.isClosed, isFalse);
      adapter.close();
      expect(adapter.isClosed, isTrue);
      expect(adapter.isDisposed, isFalse);
      adapter.pushUmp([0x22803C00], hostTimeNs: 2);
      adapter.gone(hostTimeNs: 3);
      expect(source.packets, hasLength(1));
      expect(source.releases, 0);
      final stats = adapter.stats;
      expect(stats.droppedClosed, 2);
      expect(stats.toJson(), {
        'pushed': 1,
        'rejected': 0,
        'sysexDroppedSize': 0,
        'droppedFill': 0,
        'gone': 0,
        'malformed': 0,
        'droppedClosed': 2,
        'sysexCut': 0,
        'sysexTorn': 0,
      });
      expect(stats.toString(), 'AudMidiAdapterStats(${stats.toJson()})');
      final address = adapter.address;
      expect(address, isPositive);
      adapter.dispose();
      expect(adapter.isDisposed, isTrue);
      expect(adapter.isClosed, isTrue);
      expect(() => adapter.pushUmp([], hostTimeNs: 1), throwsStateError);
      expect(() => adapter.pushBytes([], hostTimeNs: 1), throwsStateError);
      expect(() => adapter.gone(hostTimeNs: 1), throwsStateError);
      expect(() => adapter.close(), throwsStateError);
      expect(() => adapter.stats, throwsStateError);
      adapter.dispose();
    });

    test('offers the tap function for a native tap', () {
      // A backend calls the function with the adapter as its user: the
      // same path, called from Dart here.
      final tap =
          Pointer<
                NativeFunction<bindings.AudMidiTapFunctionFunction>
              >.fromAddress(AudMidiAdapter.tapFunction)
              .asFunction<bindings.DartAudMidiTapFunctionFunction>();
      tap(
        Pointer.fromAddress(adapter.address),
        bindings.AUD_MIDI_TAP_GONE,
        nullptr,
        0,
        7,
      );
      expect(source.releases, 1);
    });
  });

  group('AudMidiAdapterStats', () {
    test('defaults to zero', () {
      const stats = AudMidiAdapterStats();
      expect(stats.toJson().values, everyElement(0));
    });
  });
}
