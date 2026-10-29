// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:flutter/material.dart';

// #############################################################################
/// A small on-screen keyboard of the example (S17b builds the real one in
/// `aud_audio_ui_keyboard`): every finger plays a key, the height of the
/// touch on the key gives the velocity - soft at the top, loud at the
/// bottom -, and a finger that slides to another key plays that one.
class Keyboard extends StatefulWidget {
  /// Creates a keyboard from [lowest] for [keys] keys.
  const Keyboard({
    super.key,
    required this.onNoteOn,
    required this.onNoteOff,
    this.lowest = 48,
    this.keys = 25,
    this.sounding = const {},
  });

  /// Called with the note and the velocity, 1 to 127, when a finger plays a
  /// key.
  final void Function(int note, int velocity) onNoteOn;

  /// Called with the note when the finger leaves the key, and for every key
  /// a finger still holds when the keyboard goes.
  final void Function(int note) onNoteOff;

  /// The note of the lowest key.
  final int lowest;

  /// The number of keys, white and black.
  final int keys;

  /// Notes that sound for other reasons, e.g. an auto-play, shown pressed.
  final Set<int> sounding;

  @override
  State<Keyboard> createState() => _KeyboardState();
}

// #############################################################################
class _KeyboardState extends State<Keyboard> {
  @override
  void dispose() {
    // A note a finger still holds ends with the keyboard.
    for (final note in _fingers.values) {
      widget.onNoteOff(note);
    }
    _fingers.clear();
    super.dispose();
  }

  // ...........................................................................
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final pressed = {..._fingers.values, ...widget.sounding};
      return Listener(
        onPointerDown: (e) => _press(e.pointer, e.localPosition, size),
        onPointerMove: (e) => _press(e.pointer, e.localPosition, size),
        onPointerUp: (e) => _release(e.pointer),
        onPointerCancel: (e) => _release(e.pointer),
        child: CustomPaint(
          size: size,
          painter: _KeyboardPainter(
            notes: _notes,
            pressed: pressed,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    },
  );

  // ...........................................................................
  /// Whether [note] is a black key.
  static bool isBlack(int note) => _black.contains(note % 12);

  /// The width of a black key, relative to a white key.
  static const double blackWidth = 0.6;

  /// The length of a black key, relative to the height of the keyboard.
  static const double blackLength = 0.6;

  /// Where a black key starts on the white key below it, relative to its
  /// width.
  static const double blackOffset = 0.7;

  /// The left edge of the black key [note] between [whites] of
  /// [whiteWidth].
  static double blackLeft(int note, List<int> whites, double whiteWidth) =>
      whites.indexOf(note - 1) * whiteWidth + whiteWidth * blackOffset;

  // ######################
  // Private
  // ######################

  // The pitch classes of the black keys.
  static const Set<int> _black = {1, 3, 6, 8, 10};

  // The velocity at the top and at the bottom of a key.
  static const int _softest = 20;
  static const int _loudest = 127;

  // The note under each finger.
  final Map<int, int> _fingers = {};

  List<int> get _notes => [
    for (var n = widget.lowest; n < widget.lowest + widget.keys; n++) n,
  ];

  // The key under [position] in a keyboard of [size], with the velocity of
  // the touch; null outside the keys.
  (int, int)? _hit(Offset position, Size size) {
    final whites = _notes.where((n) => !isBlack(n)).toList();
    if (whites.isEmpty || position.dy < 0 || position.dy > size.height) {
      return null;
    }
    final whiteWidth = size.width / whites.length;
    final blackHeight = size.height * blackLength;
    if (position.dy < blackHeight) {
      for (final note in _notes.where(isBlack)) {
        final left = blackLeft(note, whites, whiteWidth);
        if (position.dx >= left &&
            position.dx < left + whiteWidth * blackWidth) {
          return (note, _velocity(position.dy, blackHeight));
        }
      }
    }
    final index = (position.dx / whiteWidth).floor();
    if (index < 0 || index >= whites.length) return null;
    return (whites[index], _velocity(position.dy, size.height));
  }

  // The velocity of a touch at [y] on a key of [height].
  static int _velocity(double y, double height) =>
      (_softest + (_loudest - _softest) * (y / height).clamp(0.0, 1.0)).round();

  void _press(int pointer, Offset position, Size size) {
    final hit = _hit(position, size);
    final previous = _fingers[pointer];
    if (hit?.$1 == previous) return;
    if (previous != null) {
      _fingers.remove(pointer);
      widget.onNoteOff(previous);
    }
    if (hit != null) {
      _fingers[pointer] = hit.$1;
      widget.onNoteOn(hit.$1, hit.$2);
    }
    setState(() {});
  }

  void _release(int pointer) {
    final note = _fingers.remove(pointer);
    if (note != null) widget.onNoteOff(note);
    setState(() {});
  }
}

// #############################################################################
class _KeyboardPainter extends CustomPainter {
  _KeyboardPainter({
    required this.notes,
    required this.pressed,
    required this.color,
  });

  final List<int> notes;
  final Set<int> pressed;
  final Color color;

  // ...........................................................................
  @override
  void paint(Canvas canvas, Size size) {
    final whites = notes.where((n) => !_KeyboardState.isBlack(n)).toList();
    final whiteWidth = size.width / whites.length;
    final border = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < whites.length; i++) {
      final rect = Rect.fromLTWH(i * whiteWidth, 0, whiteWidth, size.height);
      canvas.drawRect(
        rect,
        Paint()
          ..color = pressed.contains(whites[i])
              ? color.withValues(alpha: 0.5)
              : Colors.white,
      );
      canvas.drawRect(rect, border);
    }
    for (final note in notes.where(_KeyboardState.isBlack)) {
      canvas.drawRect(
        Rect.fromLTWH(
          _KeyboardState.blackLeft(note, whites, whiteWidth),
          0,
          whiteWidth * _KeyboardState.blackWidth,
          size.height * _KeyboardState.blackLength,
        ),
        Paint()..color = pressed.contains(note) ? color : Colors.black87,
      );
    }
  }

  @override
  bool shouldRepaint(_KeyboardPainter old) =>
      old.notes != notes ||
      old.color != color ||
      old.pressed.length != pressed.length ||
      !old.pressed.containsAll(pressed);
}
