// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

import 'dart:async';
import 'package:flclashx/services/usernet_connection.dart';

import 'package:flutter/services.dart';

typedef UserNetStatusHandler = void Function(String status);

class UserNetCarrier {
  UserNetCarrier({this.onStatus}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'status') {
        final status = call.arguments?.toString() ?? 'UNKNOWN';
        onStatus?.call(status);
        _statuses.add(status);
      }
    });
  }

  static const _channel = MethodChannel('usernet_transport');
  final _statuses = StreamController<String>.broadcast();
  final UserNetStatusHandler? onStatus;

  Stream<String> get statuses => _statuses.stream;

  Future<void> start({
    required String joinLink,
    String platform = 'wbstream',
    String? serviceUserId,
    String? serviceCredential,
    String workPlatform = 'telemost',
    String egressId = 'auto',
    int socksPort = 17890,
  }) =>
      _channel.invokeMethod<void>('start', <String, Object>{
        'joinLink': joinLink,
        'platform': platform,
        if (serviceUserId != null) 'serviceUserId': serviceUserId,
        if (serviceCredential != null) 'serviceCredential': serviceCredential,
        'workPlatform': workPlatform,
        'egressId': egressId,
        'socksPort': socksPort,
      });

  Future<void> stop() => _channel.invokeMethod<void>('stop');

  Future<bool> get isRunning async =>
      await _channel.invokeMethod<bool>('isRunning') ?? false;

  Future<String> get currentStatus async =>
      await _channel.invokeMethod<String>('getStatus') ?? 'UNKNOWN';

  Future<UserNetConnectionSnapshot> get connectionState async {
    final state =
        await _channel.invokeMapMethod<String, dynamic>('getConnectionState');
    return UserNetConnectionSnapshot.fromMap(state ?? const {});
  }

  Future<bool> probe() async =>
      await _channel.invokeMethod<bool>('probe') ?? false;

  Future<Map<String, dynamic>> request({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
    int socksPort = 17890,
  }) async {
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'request',
      <String, Object>{
        'method': method,
        'url': uri.toString(),
        'headers': headers,
        if (body != null) 'body': body,
        'socksPort': socksPort,
      },
    );
    return response ?? const <String, dynamic>{};
  }
}

final userNetCarrier = UserNetCarrier();
