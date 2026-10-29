// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio/aud_audio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// #############################################################################
/// Whether [engine] runs: it plays, or waits suspended for its device.
bool isRunning(AudEngine engine) =>
    engine.state == AudEngineState.running ||
    engine.state == AudEngineState.suspended;

/// Stops [engine] when it runs, starts it otherwise.
void toggleEngine(AudEngine engine) {
  if (isRunning(engine)) {
    engine.stop();
  } else {
    engine.start();
  }
}

/// The nanoseconds [ns] in milliseconds with two decimals; `-` for null.
String ms(num? ns) => ns == null ? '-' : (ns / 1e6).toStringAsFixed(2);

// #############################################################################
/// The head of a page: the state, the route and the format of the engine
/// and the button that starts and stops it.
class EngineHeader extends StatelessWidget {
  /// Creates the head of a page on [engine].
  ///
  /// - [onToggled] called after the button started or stopped the engine
  /// - [keys] the prefix of the keys `state`, `route` and `toggle`, e.g.
  ///   `sampler-`
  /// - [trailing] a widget right of the state
  const EngineHeader({
    super.key,
    required this.engine,
    required this.onToggled,
    this.keys = '',
    this.trailing,
  });

  // ...........................................................................
  /// The engine.
  final AudEngine engine;

  /// Called after the button started or stopped the engine.
  final VoidCallback onToggled;

  /// The prefix of the keys.
  final String keys;

  /// A widget right of the state.
  final Widget? trailing;

  // ...........................................................................
  @override
  Widget build(BuildContext context) {
    final format = engine.format;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'State: ${engine.state.name}',
                key: Key('${keys}state'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ?trailing,
          ],
        ),
        Text('Route: ${engine.route.name}', key: Key('${keys}route')),
        Text(
          'Format: ${format.sampleRate.toStringAsFixed(0)} Hz, '
          '${format.outputChannels} out, buffer ${format.bufferFrames} '
          '(${format.backend})',
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: Key('${keys}toggle'),
          onPressed: () {
            toggleEngine(engine);
            onToggled();
          },
          child: Text(isRunning(engine) ? 'Stop' : 'Start'),
        ),
      ],
    );
  }
}

// #############################################################################
/// The numbers of the engine - render time and callbacks -, [children] of
/// the page below them and a button that copies the report.
class EngineNumbers extends StatelessWidget {
  /// Creates the numbers of [engine].
  ///
  /// - [numbers] the numbers the page read for this build
  /// - [keys] the prefix of the keys `callbacks` and `copy`, e.g. `sampler-`
  /// - [children] what the page shows below the numbers
  const EngineNumbers({
    super.key,
    required this.engine,
    required this.numbers,
    this.keys = '',
    this.children = const [],
  });

  // ...........................................................................
  /// The engine.
  final AudEngine engine;

  /// The numbers the page read for this build.
  final AudEngineNumbers numbers;

  /// The prefix of the keys.
  final String keys;

  /// What the page shows below the numbers.
  final List<Widget> children;

  // ...........................................................................
  /// Copies the report of the engine to the clipboard.
  Future<void> copyReport(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: engine.report()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Report copied')));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Render: max ${ms(numbers.renderTimeMaxNs)} ms, '
        'mean ${ms(numbers.renderTimeMeanNs)} ms',
      ),
      Text(
        'Callbacks: ${numbers.callbacks}, xruns ${numbers.xruns}, '
        'late ${numbers.lateCallbacks}',
        key: Key('${keys}callbacks'),
      ),
      ...children,
      const SizedBox(height: 8),
      OutlinedButton(
        key: Key('${keys}copy'),
        onPressed: () => copyReport(context),
        child: const Text('Copy report'),
      ),
    ],
  );
}
