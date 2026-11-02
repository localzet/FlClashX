// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

import 'dart:convert';
import 'dart:math';

const userNetCarrierProxyName = 'USERNET-CARRIER';
const userNetDirectProbeProxyName = 'USERNET-DIRECT-PROBE';
const _forceFabricForDebug =
    bool.fromEnvironment('USERNET_FORCE_FABRIC', defaultValue: false);

enum UserNetTransportMode {
  auto,
  direct,
  fabric;

  static UserNetTransportMode parse(Object? value) =>
      switch (value?.toString().trim().toLowerCase()) {
        'fabric' => UserNetTransportMode.fabric,
        'direct' => UserNetTransportMode.direct,
        _ => UserNetTransportMode.auto,
      };
}

class UserNetTransportConfig {
  const UserNetTransportConfig({
    required this.enabled,
    required this.mode,
    required this.socksHost,
    required this.socksPort,
    required this.proxyName,
  });

  const UserNetTransportConfig.disabled()
      : enabled = false,
        mode = UserNetTransportMode.direct,
        socksHost = '127.0.0.1',
        socksPort = 17890,
        proxyName = userNetCarrierProxyName;

  factory UserNetTransportConfig.fromJson(Object? value) {
    if (value is! Map) return const UserNetTransportConfig.disabled();
    final port = switch (value['socks-port']) {
      final int number => number,
      final String text => int.tryParse(text),
      _ => null,
    };
    final proxyName = value['proxy-name']?.toString().trim();
    final socksHost = value['socks-host']?.toString().trim();
    return UserNetTransportConfig(
      enabled: value['enabled'] == true,
      mode: _forceFabricForDebug
          ? UserNetTransportMode.fabric
          : UserNetTransportMode.parse(value['mode']),
      socksHost:
          socksHost == null || socksHost.isEmpty ? '127.0.0.1' : socksHost,
      socksPort: port != null && port > 0 && port <= 65535 ? port : 17890,
      proxyName: proxyName == null || proxyName.isEmpty
          ? userNetCarrierProxyName
          : proxyName,
    );
  }

  final bool enabled;
  final UserNetTransportMode mode;
  final String socksHost;
  final int socksPort;
  final String proxyName;
}

class UserNetTransportResult {
  const UserNetTransportResult({
    required this.config,
    required this.fabricActive,
  });

  final UserNetTransportConfig config;
  final bool fabricActive;
}

bool isUserNetSubscription(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      uri.hasScheme &&
      uri.host.toLowerCase() == 'connect.userlay.com';
}

String canonicalUserNetSubscriptionUrl(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.toLowerCase() != 'connect.userlay.com' ||
      uri.port != 2053) {
    return trimmed;
  }
  return trimmed.replaceFirst(
    RegExp(
      r'^https://connect\.userlay\.com:2053',
      caseSensitive: false,
    ),
    'https://connect.userlay.com',
  );
}

void addDefaultUserNetMetadata(
  Map<String, dynamic> rawConfig,
  String subscriptionUrl,
) {
  if (!isUserNetSubscription(subscriptionUrl) || rawConfig['usernet'] != null) {
    return;
  }
  rawConfig['usernet'] = <String, dynamic>{
    'enabled': true,
    'mode': _forceFabricForDebug ? 'fabric' : 'auto',
    'socks-host': '127.0.0.1',
    'socks-port': 17890,
    'proxy-name': userNetCarrierProxyName,
  };
}

/// Removes UserNet metadata before Mihomo sees the profile and, when Fabric is
/// active, routes leaf proxies through the local VConnect SOCKS carrier.
UserNetTransportResult applyUserNetTransport(
  Map<String, dynamic> rawConfig, {
  bool? fabricActive,
  UserNetTransportMode? modeOverride,
}) {
  final config = UserNetTransportConfig.fromJson(rawConfig.remove('usernet'));
  final mode = modeOverride ?? config.mode;
  final shouldUseFabric = config.enabled &&
      (mode == UserNetTransportMode.fabric ||
          mode == UserNetTransportMode.auto && fabricActive == true);
  if (!shouldUseFabric) {
    return UserNetTransportResult(config: config, fabricActive: false);
  }

  final proxies = rawConfig['proxies'];
  if (proxies is List) {
    // Keep one leaf proxy completely outside the carrier path. Mihomo uses
    // this hidden copy to detect when the ordinary VLESS route has recovered
    // while the user's traffic is still safely flowing through Fabric.
    final directProbeSource = proxies.whereType<Map>().firstWhere(
      (proxy) {
        final type = proxy['type']?.toString().toLowerCase();
        final name = proxy['name']?.toString();
        return name != config.proxyName &&
            name != userNetDirectProbeProxyName &&
            !_isBuiltInProxy(type);
      },
      orElse: () => const <dynamic, dynamic>{},
    );
    if (directProbeSource.isNotEmpty) {
      final directProbe = Map<String, dynamic>.from(directProbeSource);
      directProbe['name'] = userNetDirectProbeProxyName;
      directProbe.remove('dialer-proxy');
      proxies.add(directProbe);
    }
    for (final proxy in proxies) {
      if (proxy is! Map) continue;
      final name = proxy['name']?.toString();
      final type = proxy['type']?.toString().toLowerCase();
      if (name == config.proxyName ||
          name == userNetDirectProbeProxyName ||
          _isBuiltInProxy(type)) {
        continue;
      }
      proxy.putIfAbsent('dialer-proxy', () => config.proxyName);
    }
    proxies.add(<String, dynamic>{
      'name': config.proxyName,
      'type': 'socks5',
      'server': config.socksHost,
      'port': config.socksPort,
      'udp': true,
    });
  } else {
    rawConfig['proxies'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'name': config.proxyName,
        'type': 'socks5',
        'server': config.socksHost,
        'port': config.socksPort,
        'udp': true,
      },
    ];
  }

  final providers = rawConfig['proxy-providers'];
  if (providers is Map) {
    for (final provider in providers.values) {
      if (provider is! Map) continue;
      final override = provider['override'];
      if (override is Map) {
        override.putIfAbsent('dialer-proxy', () => config.proxyName);
      } else {
        provider['override'] = <String, dynamic>{
          'dialer-proxy': config.proxyName,
        };
      }

      // Provider health checks can saturate the narrow video carrier before
      // user traffic gets a chance to flow. Direct mode reloads the original
      // provider settings from the subscription.
      final healthCheck = provider['health-check'];
      if (healthCheck is Map) {
        healthCheck['enable'] = false;
        healthCheck['lazy'] = true;
        healthCheck['interval'] = 3600;
        final timeout = healthCheck['timeout'];
        if (timeout is! num || timeout < 30000) {
          healthCheck['timeout'] = 30000;
        }
      }
    }
  }

  final groups = rawConfig['proxy-groups'];
  if (groups is List) {
    final internalNames = {config.proxyName, userNetDirectProbeProxyName};
    final internalFilter = '^(${internalNames.map(RegExp.escape).join('|')})\$';
    for (final group in groups.whereType<Map>()) {
      final members = group['proxies'];
      if (members is List) {
        members.removeWhere((name) => internalNames.contains(name));
      }
      final existingFilter = group['exclude-filter']?.toString() ?? '';
      group['exclude-filter'] = existingFilter.isEmpty
          ? internalFilter
          : '$existingFilter|$internalFilter';
      final type = group['type']?.toString().toLowerCase();
      if (type == 'url-test' || type == 'fallback' || type == 'load-balance') {
        // Automated groups probe every member when they become active. A
        // selector preserves the chosen route without creating a connection
        // storm; direct mode restores the original group from the profile.
        group['type'] = 'select';
        for (final key in const [
          'url',
          'interval',
          'lazy',
          'tolerance',
          'timeout',
          'strategy',
          'expected-status',
        ]) {
          group.remove(key);
        }
      }
    }
  }

  return UserNetTransportResult(config: config, fabricActive: true);
}

bool _isBuiltInProxy(String? type) => switch (type) {
      'direct' || 'reject' || 'reject-drop' || 'pass' || 'compatible' => true,
      _ => false,
    };

/// Adds a client-generated tunnel secret as a URL fragment. Fragments are not
/// sent in HTTP requests to the call provider, but are delivered to the RU
/// relay through the authenticated UserNet control channel.
String sealUserNetRoomLink(String roomLink, {List<int>? secret}) {
  final key = secret ??
      List<int>.generate(32, (_) => Random.secure().nextInt(256),
          growable: false);
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'secret.length', 'must be 32 bytes');
  }
  final publicPart = roomLink.trim().split('#').first;
  if (publicPart.isEmpty) {
    throw ArgumentError.value(roomLink, 'roomLink', 'must not be empty');
  }
  return '$publicPart#key=${base64Url.encode(key).replaceAll('=', '')}';
}
