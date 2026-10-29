// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.
// Runs the integration tests with `flutter drive`, which also reaches an
// iPhone over Wi-Fi (--publish-port):
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/engine_test.dart -d <device> --publish-port

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
