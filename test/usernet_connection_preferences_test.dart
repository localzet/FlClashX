// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX
import 'package:flclashx/services/usernet_connection.dart';
import 'package:flclashx/services/usernet_preferences.dart';
import 'package:flclashx/services/usernet_transport.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('control allocation does not imply a connected work tunnel', () {
    final state = UserNetConnectionSnapshot.fromMap({
      'status': 'WORK_SESSION_READY',
      'controlState': 'complete',
      'transportState': 'connecting',
      'controlCarrier': 'telemost',
    });
    expect(state.control, UserNetConnectionPhase.complete);
    expect(state.connected, isFalse);
    expect(state.connecting, isTrue);
  });
  test('data verification cannot display a connected tunnel', () {
    final state = UserNetConnectionSnapshot.fromMap({
      'status': 'TRANSPORT_VERIFYING',
      'controlState': 'complete',
      'transportState': 'connecting',
    });
    expect(state.connected, isFalse);
    expect(state.connecting, isTrue);
  });
  test('unknown native phases cannot report a successful tunnel', () {
    final state =
        UserNetConnectionSnapshot.fromMap({'transportState': 'future-value'});
    expect(state.connected, isFalse);
    expect(state.transport, UserNetConnectionPhase.idle);
  });
  test('manual mode and both providers survive a fresh preferences instance',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final first = UserNetPreferences();
    await first.save(
        mode: UserNetTransportMode.fabric, control: 'vk', work: 'telemost');
    final next = UserNetPreferences();
    await next.load();
    expect(next.mode, UserNetTransportMode.fabric);
    expect(next.controlCarrier, 'vk');
    expect(next.workCarrier, 'telemost');
    await next.save(mode: UserNetTransportMode.direct);
    final last = UserNetPreferences();
    await last.load();
    expect(last.mode, UserNetTransportMode.direct);
    expect(last.controlCarrier, 'vk');
  });
  test('corrupt preferences do not prevent startup', () async {
    FlutterSecureStorage.setMockInitialValues(
        {'usernet.transport.preferences': 'null'});
    final prefs = UserNetPreferences();
    await prefs.load();
    expect(prefs.mode, isNull);
    expect(prefs.workCarrier, 'auto');
  });
}
