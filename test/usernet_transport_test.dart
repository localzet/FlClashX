import 'package:flclashx/services/usernet_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public UserNet gateway enables auto metadata', () {
    final raw = <String, dynamic>{};

    addDefaultUserNetMetadata(
      raw,
      'https://connect.userlay.com/subscription',
    );

    expect(raw['usernet'], containsPair('mode', 'auto'));
  });

  test('legacy subscription port is removed before refresh', () {
    expect(
      canonicalUserNetSubscriptionUrl(
        'https://connect.userlay.com:2053/subscription?format=clash',
      ),
      'https://connect.userlay.com/subscription?format=clash',
    );
    expect(
      canonicalUserNetSubscriptionUrl(
        'https://connect.userlay.com/subscription',
      ),
      'https://connect.userlay.com/subscription',
    );
  });

  test('direct mode strips metadata without changing proxies', () {
    final raw = <String, dynamic>{
      'usernet': <String, dynamic>{'enabled': true, 'mode': 'direct'},
      'proxies': <dynamic>[
        <String, dynamic>{'name': 'NL', 'type': 'vless'},
      ],
    };

    final result = applyUserNetTransport(raw);

    expect(result.fabricActive, isFalse);
    expect(raw.containsKey('usernet'), isFalse);
    expect((raw['proxies'] as List).single, isNot(contains('dialer-proxy')));
  });

  test('fabric mode routes inline and provider proxies through carrier', () {
    final raw = <String, dynamic>{
      'usernet': <String, dynamic>{
        'enabled': true,
        'mode': 'fabric',
        'socks-port': 19090,
      },
      'proxies': <dynamic>[
        <String, dynamic>{'name': 'NL', 'type': 'vless'},
        <String, dynamic>{'name': 'DIRECT', 'type': 'direct'},
      ],
      'proxy-providers': <String, dynamic>{
        'subscription': <String, dynamic>{'type': 'http'},
      },
    };

    final result = applyUserNetTransport(raw);

    expect(result.fabricActive, isTrue);
    final proxies = raw['proxies'] as List;
    expect(proxies[0]['dialer-proxy'], 'USERNET-CARRIER');
    expect(proxies[1], isNot(contains('dialer-proxy')));
    expect(proxies.last, containsPair('port', 19090));
    final directProbe = proxies.singleWhere(
      (proxy) => proxy['name'] == userNetDirectProbeProxyName,
    );
    expect(directProbe['type'], 'vless');
    expect(directProbe, isNot(contains('dialer-proxy')));
    expect(
      raw['proxy-providers']['subscription']['override']['dialer-proxy'],
      'USERNET-CARRIER',
    );
  });

  test('call route disables automated health checks', () {
    final raw = <String, dynamic>{
      'usernet': {'enabled': true, 'mode': 'fabric'},
      'proxy-providers': {
        'subscription': <String, dynamic>{
          'health-check': <String, dynamic>{'timeout': 3000}
        },
      },
      'proxy-groups': [
        <String, dynamic>{'name': 'Fast', 'type': 'url-test', 'timeout': 3000},
        <String, dynamic>{
          'name': 'Backup',
          'type': 'fallback',
          'timeout': 45000
        },
        <String, dynamic>{'name': 'Manual', 'type': 'select'},
      ],
    };
    applyUserNetTransport(raw);
    expect(raw['proxy-providers']['subscription']['health-check']['enable'],
        isFalse);
    expect(raw['proxy-providers']['subscription']['health-check']['timeout'],
        30000);
    final groups = raw['proxy-groups'] as List;
    expect(groups[0]['type'], 'select');
    expect(groups[0], isNot(contains('timeout')));
    expect(groups[1]['type'], 'select');
    expect(groups[1], isNot(contains('timeout')));
    expect(groups[0], isNot(contains('interval')));
    expect(groups[1], isNot(contains('interval')));
    expect(groups[0], isNot(contains('lazy')));
    expect(groups[1], isNot(contains('lazy')));
    expect(groups[2]['type'], 'select');
    expect(groups[2], isNot(contains('timeout')));
  });

  test('forced call route fails closed when the carrier is disconnected', () {
    final raw = <String, dynamic>{
      'usernet': {'enabled': true, 'mode': 'fabric'},
      'proxies': [
        <String, dynamic>{'name': 'NL', 'type': 'vless'}
      ],
    };
    final result = applyUserNetTransport(raw, fabricActive: false);
    expect(result.fabricActive, isTrue);
    expect((raw['proxies'] as List).first['dialer-proxy'],
        userNetCarrierProxyName);
  });

  test(
      'manual call mode overrides automatic profile routing even while disconnected',
      () {
    final raw = <String, dynamic>{
      'usernet': {'enabled': true, 'mode': 'auto'},
      'proxies': [
        <String, dynamic>{'name': 'NL', 'type': 'vless'}
      ],
    };
    applyUserNetTransport(raw,
        fabricActive: false, modeOverride: UserNetTransportMode.fabric);
    expect((raw['proxies'] as List).first['dialer-proxy'],
        userNetCarrierProxyName);
  });

  test('manual direct mode overrides a forced profile and stale carrier state',
      () {
    final raw = <String, dynamic>{
      'usernet': {'enabled': true, 'mode': 'fabric'},
      'proxies': [
        <String, dynamic>{'name': 'NL', 'type': 'vless'}
      ],
    };
    final result = applyUserNetTransport(raw,
        fabricActive: true, modeOverride: UserNetTransportMode.direct);
    expect(result.fabricActive, isFalse);
    expect((raw['proxies'] as List).single, isNot(contains('dialer-proxy')));
  });

  test('internal carrier and direct probe are excluded from user groups', () {
    final raw = <String, dynamic>{
      'usernet': {'enabled': true, 'mode': 'fabric'},
      'proxies': [
        <String, dynamic>{'name': 'NL', 'type': 'vless'}
      ],
      'proxy-groups': [
        <String, dynamic>{
          'name': 'Automatic',
          'type': 'url-test',
          'include-all': true,
          'exclude-filter': 'legacy',
        },
        <String, dynamic>{
          'name': 'Manual',
          'type': 'select',
          'proxies': [
            'NL',
            userNetCarrierProxyName,
            userNetDirectProbeProxyName
          ],
        },
      ],
    };
    applyUserNetTransport(raw);
    for (final group in raw['proxy-groups'] as List) {
      final excluded = RegExp(group['exclude-filter'] as String);
      expect(excluded.hasMatch(userNetCarrierProxyName), isTrue);
      expect(excluded.hasMatch(userNetDirectProbeProxyName), isTrue);
      expect(excluded.hasMatch('NL'), isFalse);
    }
    expect(raw['proxy-groups'][0]['exclude-filter'], startsWith('legacy|'));
    expect(raw['proxy-groups'][1]['proxies'], ['NL']);
  });

  test('existing dialer proxy is not overwritten', () {
    final raw = <String, dynamic>{
      'usernet': <String, dynamic>{'enabled': true, 'mode': 'fabric'},
      'proxies': <dynamic>[
        <String, dynamic>{
          'name': 'NL',
          'type': 'vless',
          'dialer-proxy': 'CUSTOM-DIALER',
        },
      ],
    };

    applyUserNetTransport(raw);

    expect((raw['proxies'] as List).first['dialer-proxy'], 'CUSTOM-DIALER');
  });

  test('room link receives a separate client secret', () {
    final link = sealUserNetRoomLink(
      'wbstream://room-id',
      secret: List<int>.filled(32, 7),
    );

    expect(link, startsWith('wbstream://room-id#key='));
    expect(link.split('#key=').last, hasLength(43));
  });
}
