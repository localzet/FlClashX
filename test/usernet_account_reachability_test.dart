import 'dart:io';

import 'package:flclashx/services/usernet_account.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const transportChannel = MethodChannel('usernet_transport');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transportChannel, (call) async {
      if (call.method == 'getStatus') return 'STOPPED';
      if (call.method == 'isRunning') return false;
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(transportChannel, null));

  test('account API is reachable even when an unauthenticated probe gets 401',
      () async {
    final service = UserNetAccountService(
      baseUri: Uri.parse('https://api.userlay.com/app/v1'),
      client: MockClient((request) async {
        expect(request.url.path, '/app/v1/plans');
        expect(request.headers.containsKey('authorization'), isFalse);
        return http.Response('{}', 401);
      }),
    );
    expect(await service.isDirectApiReachable(), isTrue);
  });

  test('account API probe fails closed when its host cannot be reached',
      () async {
    final service = UserNetAccountService(
      client: MockClient((_) async => throw const SocketException('blocked')),
    );
    expect(await service.isDirectApiReachable(), isFalse);
  });

  test('a gateway error is not account API reachability', () async {
    final service = UserNetAccountService(
        client: MockClient((_) async => http.Response('{}', 503)));
    expect(await service.isDirectApiReachable(), isFalse);
  });
  test('HTML interception is not account API reachability', () async {
    final service = UserNetAccountService(
        client: MockClient(
            (_) async => http.Response('<html>blocked</html>', 200)));
    expect(await service.isDirectApiReachable(), isFalse);
  });

  test('intercepted unauthorized HTML does not invalidate an account token',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        {'usernet.account.token': 'test-token'});
    final service = UserNetAccountService(
      client:
          MockClient((_) async => http.Response('<html>blocked</html>', 401)),
    );
    await expectLater(
        service.account(),
        throwsA(isA<UserNetApiException>()
            .having((error) => error.statusCode, 'statusCode', isNull)));
    expect(await service.isSignedIn, isTrue);
  });

  test('authoritative account response removes revoked cached Fabric access',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'usernet.account.token': 'test-token',
      'usernet.account.fabric': '{"credential":"old"}',
    });
    final service = UserNetAccountService(
      client: MockClient((_) async => http.Response('{"fabric":null}', 200)),
    );
    await service.account();
    expect(await service.cachedFabricAccess(), isNull);
  });

  test('first claim reports the network requirement when API is blocked',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    const channel = MethodChannel('usernet_transport');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') return 'STOPPED';
      if (call.method == 'isRunning') return false;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final service = UserNetAccountService(
      client: MockClient((_) async => throw const SocketException('blocked')),
    );
    await expectLater(
      service.claimSubscription('https://connect.userlay.com/example'),
      throwsA(isA<UserNetApiException>().having(
        (error) => error.message,
        'message',
        'USERNET_FIRST_SIGNIN_REQUIRES_NETWORK',
      )),
    );
  });
}
