// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'usernet_transport.dart';

class UserNetPreferences {
  UserNetPreferences({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'usernet.transport.preferences';
  UserNetTransportMode? mode;
  String controlCarrier = 'auto';
  String workCarrier = 'auto';
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return;
    try {
      final data = jsonDecode(value) as Map;
      if (data['mode'] != null) mode = UserNetTransportMode.parse(data['mode']);
      controlCarrier = _carrier(data['controlCarrier']);
      workCarrier = _carrier(data['workCarrier']);
    } on FormatException {
      await _storage.delete(key: _key);
    } on TypeError {
      await _storage.delete(key: _key);
    }
  }

  static String _carrier(Object? value) =>
      const ['telemost', 'vk', 'wbstream'].contains(value)
          ? value.toString()
          : 'auto';

  Future<void> save(
      {UserNetTransportMode? mode, String? control, String? work}) async {
    await load();
    final nextMode = mode ?? this.mode;
    final nextControl = control == null ? controlCarrier : _carrier(control);
    final nextWork = work == null ? workCarrier : _carrier(work);
    await _storage.write(
        key: _key,
        value: jsonEncode({
          'mode': nextMode?.name,
          'controlCarrier': nextControl,
          'workCarrier': nextWork,
        }));
    this.mode = nextMode;
    controlCarrier = nextControl;
    workCarrier = nextWork;
  }
}

final userNetPreferences = UserNetPreferences();
