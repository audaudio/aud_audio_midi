// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// What both port nodes share: the ids of their event ports and of their
/// string settings.
abstract final class AudMidiPortNode {
  /// The id of the event inlet of both nodes.
  static const String inlet = 'in';

  /// The id of the event outlet of both nodes.
  static const String outlet = 'out';

  /// The string key that holds the id of the aud_midi port the node is
  /// bound to; the graph document persists it.
  static const String portId = 'port_id';

  /// The string key that holds aud_midi's fingerprint of the port
  /// (`manufacturer|name|serialNumber|direction|index`), by which the bridge
  /// finds the device again when its id changed (Android).
  static const String portFingerprint = 'port_fingerprint';
}

// #############################################################################
/// The node `aud.midi.input`: the target of the event source of a port; it
/// passes every event of its inlet to its outlet at its offset.
abstract final class AudMidiInputNode {
  /// The type id of the node.
  static const String typeId = 'aud.midi.input';
}

// #############################################################################
/// The node `aud.midi.output`: the bridge connects its outlet to the graph's
/// event input, so its events reach Dart as notifications that name the
/// node; SysEx is dropped unless [sysex] is on, since the notification ring
/// is lossy.
abstract final class AudMidiOutputNode {
  /// The type id of the node.
  static const String typeId = 'aud.midi.output';

  /// The boolean parameter that lets SysEx (UMP types 3 and 5) through.
  static const String sysex = 'sysex';
}
