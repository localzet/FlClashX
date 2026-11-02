// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flclashx/plugins/usernet.dart';
import 'package:flclashx/services/usernet_transport.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class UserNetApiException implements Exception {
  const UserNetApiException(this.message, [this.statusCode]);

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class UserNetAccountService {
  UserNetAccountService({
    http.Client? client,
    FlutterSecureStorage? storage,
    Uri? baseUri,
  })  : _client = client ?? http.Client(),
        _storage = storage ?? const FlutterSecureStorage(),
        baseUri = baseUri ??
            Uri.parse(const String.fromEnvironment(
              'USERNET_API_URL',
              defaultValue: 'https://api.userlay.com/app/v1',
            ));

  static const _tokenKey = 'usernet.account.token';
  static const _deviceKey = 'usernet.account.device';
  static const _fabricKey = 'usernet.account.fabric';
  static const _pendingPurchaseKey = 'usernet.account.pendingPurchase';

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final Uri baseUri;

  Future<bool> get isSignedIn async =>
      (await _storage.read(key: _tokenKey)) != null;

  Future<Map<String, dynamic>> register({String? referralCode}) async {
    final response = await _request(
      'POST',
      '/auth/register',
      authenticated: false,
      body: {
        'deviceId': await _deviceId(),
        'deviceName': 'UserNet device',
        'language': 'ru',
        if (referralCode?.trim().isNotEmpty == true)
          'referralCode': referralCode!.trim(),
      },
    );
    await _saveToken(response);
    return response;
  }

  Future<Map<String, dynamic>> claimSubscription(String subscriptionUrl) async {
    final response = await _request(
      'POST',
      '/auth/claim-subscription',
      authenticated: false,
      body: {
        'deviceId': await _deviceId(),
        'deviceName': 'UserNet device',
        'language': 'ru',
        'subscriptionUrl': canonicalUserNetSubscriptionUrl(subscriptionUrl),
      },
    );
    await _saveToken(response);
    return response;
  }

  Future<Map<String, dynamic>> account() async {
    final result = await _request('GET', '/account');
    await _cacheFabric(result);
    return result;
  }

  Future<Map<String, dynamic>?> cachedFabricAccess() async {
    final value = await _storage.read(key: _fabricKey);
    if (value == null || value.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(value) as Map);
    } catch (_) {
      await _storage.delete(key: _fabricKey);
      return null;
    }
  }

  /// Check the account API itself: a reachable proxy endpoint does not imply
  /// that api.userlay.com is reachable on the current network.
  Future<bool> isDirectApiReachable() async {
    try {
      final basePath = baseUri.path.replaceFirst(RegExp(r'/$'), '');
      final response =
          await _client.get(baseUri.replace(path: '$basePath/plans'), headers: {
        'accept': 'application/json',
      }).timeout(const Duration(seconds: 4));
      if (!(response.statusCode >= 200 && response.statusCode < 300 ||
          response.statusCode == 401 ||
          response.statusCode == 403)) {
        return false;
      }
      final decoded = jsonDecode(response.body);
      return decoded is Map || decoded is List;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> plans() async {
    final result = await _request('GET', '/plans');
    final values = result['items'] as List<dynamic>? ?? const [];
    return values.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createCheckout(int months) =>
      _request('POST', '/checkout', body: {'months': months});

  Future<Map<String, dynamic>> purchase(String id) =>
      _request('GET', '/purchases/${Uri.encodeComponent(id)}');

  Future<String?> get pendingPurchaseId =>
      _storage.read(key: _pendingPurchaseKey);

  Future<void> rememberPendingPurchase(
    String id, {
    bool notify = false,
  }) async {
    final value = id.trim();
    if (value.isEmpty) return;
    await _storage.write(key: _pendingPurchaseKey, value: value);
    if (notify) _paymentReturns.add(value);
  }

  Future<void> clearPendingPurchase() =>
      _storage.delete(key: _pendingPurchaseKey);

  final _paymentReturns = StreamController<String>.broadcast();

  Stream<String> get paymentReturns => _paymentReturns.stream;

  Future<Map<String, dynamic>> referrals() => _request('GET', '/referrals');

  Future<Map<String, dynamic>> acceptReferral(String code) =>
      _request('POST', '/referrals/accept', body: {'code': code.trim()});

  Future<void> logout() async {
    try {
      await _request('POST', '/auth/logout');
    } on UserNetApiException {
      // A locally stored expired/revoked token is already logged out remotely.
    } finally {
      await _storage.delete(key: _tokenKey);
      await _storage.delete(key: _fabricKey);
      await _storage.delete(key: _pendingPurchaseKey);
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
  }) async {
    final token = authenticated ? await _storage.read(key: _tokenKey) : null;
    if (authenticated && token == null) {
      throw const UserNetApiException('USERNET_AUTH_REQUIRED', 401);
    }
    final basePath = baseUri.path.replaceFirst(RegExp(r'/$'), '');
    final uri = baseUri.replace(
      path: '$basePath/${path.replaceFirst('/', '')}',
      query: null,
      fragment: null,
    );
    final headers = <String, String>{
      'accept': 'application/json',
      'content-type': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    };
    late _UserNetHttpResponse response;
    final carrierStatus = await userNetCarrier.currentStatus;
    if (carrierStatus == 'TUNNEL_CONNECTED') {
      response = await _sendThroughCarrier(method, uri, headers, body);
    } else {
      try {
        response = await _sendDirect(method, uri, headers, body);
      } on TimeoutException {
        response = await _fallbackAfterDirectFailure(
            method, uri, headers, body, authenticated);
      } on HandshakeException {
        response = await _fallbackAfterDirectFailure(
            method, uri, headers, body, authenticated);
      } on SocketException {
        response = await _fallbackAfterDirectFailure(
            method, uri, headers, body, authenticated);
      } on http.ClientException {
        response = await _fallbackAfterDirectFailure(
            method, uri, headers, body, authenticated);
      }
    }
    final dynamic decoded;
    try {
      decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on FormatException {
      throw const UserNetApiException('USERNET_UNEXPECTED_RESPONSE');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map
          ? decoded['message']?.toString() ?? 'USERNET_REQUEST_FAILED'
          : 'USERNET_REQUEST_FAILED';
      throw UserNetApiException(message, response.statusCode);
    }
    if (decoded is List) {
      return {'items': decoded};
    }
    if (decoded is! Map) {
      throw const UserNetApiException('USERNET_UNEXPECTED_RESPONSE');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<_UserNetHttpResponse> _fallbackAfterDirectFailure(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
    bool authenticated,
  ) async {
    if (!authenticated && !await userNetCarrier.isRunning) {
      throw const UserNetApiException('USERNET_FIRST_SIGNIN_REQUIRES_NETWORK');
    }
    return _sendThroughCarrier(method, uri, headers, body);
  }

  Future<_UserNetHttpResponse> _sendDirect(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    final encodedBody = jsonEncode(body ?? const <String, dynamic>{});
    final result = await switch (method) {
      'GET' => _client.get(uri, headers: headers),
      'POST' => _client.post(uri, headers: headers, body: encodedBody),
      _ => throw ArgumentError.value(method, 'method'),
    }
        .timeout(const Duration(seconds: 12));
    return _UserNetHttpResponse(result.statusCode, result.body);
  }

  Future<_UserNetHttpResponse> _sendThroughCarrier(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (!await userNetCarrier.isRunning) {
          throw const UserNetApiException('USERNET_NETWORK_UNAVAILABLE');
        }
        if (attempt > 0) {
          for (var poll = 0; poll < 20; poll++) {
            if (await userNetCarrier.currentStatus == 'TUNNEL_CONNECTED') {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
        final result = await userNetCarrier.request(
          method: method,
          uri: uri,
          headers: headers,
          body: method == 'POST'
              ? jsonEncode(body ?? const <String, dynamic>{})
              : null,
        );
        return _UserNetHttpResponse(
          result['statusCode'] as int? ?? 0,
          result['body']?.toString() ?? '',
        );
      } catch (error) {
        if (error is UserNetApiException) rethrow;
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }
    throw UserNetApiException(
      'USERNET_NETWORK_UNAVAILABLE${lastError == null ? '' : ': $lastError'}',
    );
  }

  Future<void> _saveToken(Map<String, dynamic> response) async {
    final token = response['token']?.toString();
    if (token == null || token.isEmpty) {
      throw const UserNetApiException('USERNET_TOKEN_MISSING');
    }
    await _storage.write(key: _tokenKey, value: token);
    final account = response['account'];
    if (account is Map) {
      await _cacheFabric(Map<String, dynamic>.from(account));
    }
  }

  Future<void> _cacheFabric(Map<String, dynamic> account) async {
    final fabric = account['fabric'];
    if (fabric is Map && fabric.isNotEmpty) {
      await _storage.write(key: _fabricKey, value: jsonEncode(fabric));
    } else {
      await _storage.delete(key: _fabricKey);
    }
  }

  Future<String> _deviceId() async {
    final existing = await _storage.read(key: _deviceKey);
    if (existing != null) return existing;
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final value = base64UrlEncode(bytes).replaceAll('=', '');
    await _storage.write(key: _deviceKey, value: value);
    return value;
  }
}

final userNetAccountService = UserNetAccountService();

class _UserNetHttpResponse {
  const _UserNetHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
