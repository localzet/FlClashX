// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

import 'package:flclashx/services/usernet_fabric_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 9, 16);

  test('brief call reconnect does not restart the carrier', () {
    expect(
      shouldRestartUserNetCarrier(
          'RECONNECTING', start, start.add(const Duration(seconds: 29))),
      isFalse,
    );
  });

  test('stalled call rotates after the recovery window', () {
    expect(
      shouldRestartUserNetCarrier(
          'TUNNEL_LOST', start, start.add(const Duration(seconds: 30))),
      isTrue,
    );
  });

  for (final status in [
    'STARTING',
    'CONNECTING',
    'CONTROL_CONNECTED',
    'WORK_SESSION_READY',
    'TRANSPORT_STARTING',
    'TRANSPORT_VERIFYING'
  ]) {
    test('$status allows both call handshakes before rotating', () {
      expect(
          shouldRestartUserNetCarrier(
              status, start, start.add(const Duration(seconds: 119))),
          isFalse);
      expect(
          shouldRestartUserNetCarrier(
              status, start, start.add(const Duration(minutes: 2))),
          isTrue);
    });
  }

  test('fatal relay error rotates immediately', () {
    expect(
      shouldRestartUserNetCarrier('ERROR:RELAY_OUTPUT', start, start),
      isTrue,
    );
  });
}
