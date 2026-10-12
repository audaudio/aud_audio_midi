// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('scripts/test-native.js', () {
    test('builds and runs the native tests with the sanitizers', () {
      final result = Process.runSync(
        'node',
        [
          'scripts/test-native.js',
          if (Platform.environment['AUD_NO_SANITIZE'] == '1') '--no-sanitize',
        ],
        // Every test runs, whatever filter the shell set.
        environment: {'AUD_TEST_FILTER': ''},
      );
      final output = '${result.stdout}\n${result.stderr}';
      expect(result.exitCode, 0, reason: output);
      // The summary of each build: "113 of 113 native tests passed, 0 checks
      // failed". Every build ran tests, and all of them passed.
      final builds = [
        for (final match in RegExp(
          r'(\d+) of (\d+) native tests passed, (\d+) checks failed',
        ).allMatches('${result.stdout}'))
          (int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!)),
      ];
      expect(builds, isNotEmpty, reason: output);
      expect(builds, [for (final (_, ran, _) in builds) (ran, ran, 0)]);
      expect([for (final (_, ran, _) in builds) ran], everyElement(isPositive));
    }, timeout: const Timeout(Duration(minutes: 15)));
  });
}
