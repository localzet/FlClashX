// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

import 'dart:async';
import 'dart:io';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/plugins/usernet.dart';
import 'package:flclashx/services/usernet_account.dart';
import 'package:flclashx/services/usernet_fallback.dart';
import 'package:flclashx/services/usernet_preferences.dart';
import 'package:flclashx/services/usernet_transport.dart';

bool shouldRestartUserNetCarrier(
  String status,
  DateTime unhealthySince,
  DateTime now,
) {
  if (status.startsWith('ERROR:')) return true;
  final establishing = const {
    'STARTING',
    'CONNECTING',
    'CONTROL_CONNECTED',
    'WORK_SESSION_READY',
    'TRANSPORT_STARTING',
    'TRANSPORT_VERIFYING',
  }.contains(status);
  final window =
      establishing ? const Duration(minutes: 2) : const Duration(seconds: 30);
  return now.difference(unhealthySince) >= window;
}

class UserNetFabricCoordinator {
  UserNetFallbackController? _fallback;
  UserNetTransportMode? _mode;
  bool _fabricActive = false;
  bool _busy = false;
  DateTime? _lastProbeAt;
  DateTime? _carrierUnhealthySince;
  int _nextCarrierIndex = 0;
  int _generation = 0;

  bool get fabricActive => _fabricActive;

  Future<bool> ensure(
    UserNetTransportConfig requestedConfig, {
    bool forceProbe = false,
    Future<bool> Function()? directProbe,
  }) async {
    if (!Platform.isAndroid || !requestedConfig.enabled) return false;
    await userNetPreferences.load();
    final config = UserNetTransportConfig(
        enabled: requestedConfig.enabled,
        mode: userNetPreferences.mode ?? requestedConfig.mode,
        socksHost: requestedConfig.socksHost,
        socksPort: requestedConfig.socksPort,
        proxyName: requestedConfig.proxyName);
    if (_busy) return _fabricActive;
    if (!forceProbe &&
        _lastProbeAt != null &&
        DateTime.now().difference(_lastProbeAt!) < const Duration(seconds: 6)) {
      return _fabricActive;
    }
    _busy = true;
    final generation = _generation;
    try {
      _fallback ??= UserNetFallbackController(
        mode: config.mode,
        policy: const UserNetFallbackPolicy(
          failuresBeforeFabric: 2,
          successesBeforeDirect: 3,
          switchCooldown: Duration(seconds: 20),
        ),
      );
      if (_mode != config.mode) {
        _fallback!.setMode(config.mode);
        _mode = config.mode;
      }

      _lastProbeAt = DateTime.now();
      final directWorks = config.mode == UserNetTransportMode.fabric
          ? false
          : await (directProbe?.call() ?? userNetCarrier.probe());
      if (generation != _generation) return false;
      final path = config.mode == UserNetTransportMode.fabric
          ? UserNetPath.fabric
          : _fallback!.recordDirectProbe(succeeded: directWorks);
      commonPrint.log(
        'UserNet path probe: mode=${config.mode.name}, '
        'direct=$directWorks, selected=${path.name}',
      );
      if (path == UserNetPath.direct) {
        if (_fabricActive) await userNetCarrier.stop();
        _fabricActive = false;
        _carrierUnhealthySince = null;
        return false;
      }
      if (_fabricActive && await userNetCarrier.isRunning) {
        final status = await userNetCarrier.currentStatus;
        if (status == 'TUNNEL_CONNECTED') {
          _carrierUnhealthySince = null;
          return true;
        }
        // The relay can remain alive while a call is reconnecting. Give its
        // in-process recovery time to work, then try another cached room.
        _carrierUnhealthySince ??= DateTime.now();
        if (!shouldRestartUserNetCarrier(
            status, _carrierUnhealthySince!, DateTime.now())) {
          return true;
        }
        commonPrint.log('UserNet carrier stalled at $status; rotating room');
        await userNetCarrier.stop();
      }
      _carrierUnhealthySince = null;
      _fabricActive = await _startCachedCarrier(config.socksPort, generation);
      commonPrint.log('UserNet Fabric started: $_fabricActive');
      return _fabricActive;
    } finally {
      _busy = false;
    }
  }

  Future<bool> _startCachedCarrier(int socksPort, int generation) async {
    final access = await userNetAccountService.cachedFabricAccess();
    if (access == null) {
      commonPrint.log('UserNet Fabric access is not cached');
      return false;
    }
    final userId = access['userId']?.toString() ?? '';
    final credential = access['credential']?.toString() ?? '';
    final egressId = access['egressId']?.toString() ?? 'auto';
    final workPlatforms = (access['workPlatforms'] as List<dynamic>?)
            ?.map((value) => value.toString())
            .where((value) =>
                value == 'telemost' || value == 'vk' || value == 'wbstream')
            .toList() ??
        const <String>['telemost'];
    final carriers = ((access['carriers'] as List<dynamic>?) ?? const [])
        .where((value) =>
            value is Map &&
            (userNetPreferences.controlCarrier == 'auto' ||
                value['platform'] == userNetPreferences.controlCarrier))
        .toList();
    final selectedWork = userNetPreferences.workCarrier == 'auto'
        ? (workPlatforms.isEmpty ? null : workPlatforms.first)
        : (workPlatforms.contains(userNetPreferences.workCarrier)
            ? userNetPreferences.workCarrier
            : null);
    if (selectedWork == null || carriers.isEmpty) return false;
    if (userId.isEmpty || credential.isEmpty) {
      commonPrint.log('UserNet Fabric credentials are incomplete');
      return false;
    }

    final startIndex =
        _nextCarrierIndex % (carriers.isEmpty ? 1 : carriers.length);
    for (var offset = 0; offset < carriers.length; offset++) {
      if (generation != _generation) return false;
      final index = (startIndex + offset) % carriers.length;
      final value = carriers[index];
      if (value is! Map) continue;
      final platform = value['platform']?.toString() ?? '';
      final joinLink = value['joinLink']?.toString() ?? '';
      if (joinLink.isEmpty ||
          (platform != 'telemost' &&
              platform != 'vk' &&
              platform != 'wbstream')) {
        continue;
      }
      late final StreamSubscription<String> subscription;
      var streamStatus = 'UNKNOWN';
      subscription = userNetCarrier.statuses.listen((status) {
        streamStatus = status;
        commonPrint.log('UserNet carrier status: $status');
      });
      try {
        commonPrint.log('UserNet Fabric requesting carrier=$platform');
        await userNetCarrier.start(
          joinLink: joinLink,
          platform: platform,
          serviceUserId: userId,
          serviceCredential: credential,
          workPlatform: selectedWork,
          egressId: egressId,
          socksPort: socksPort,
        );
        // Account for both call handshakes and the verified HTTPS probe.
        final deadline = DateTime.now().add(const Duration(minutes: 2));
        var lastPolledStatus = '';
        while (DateTime.now().isBefore(deadline)) {
          if (generation != _generation) return false;
          final polledStatus = await userNetCarrier.currentStatus;
          if (polledStatus != lastPolledStatus) {
            commonPrint.log('UserNet carrier polled status: $polledStatus');
            lastPolledStatus = polledStatus;
          }
          if (streamStatus == 'TUNNEL_CONNECTED' ||
              polledStatus == 'TUNNEL_CONNECTED') {
            _nextCarrierIndex = index;
            return true;
          }
          if (streamStatus.startsWith('ERROR:') ||
              polledStatus.startsWith('ERROR:')) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      } finally {
        await subscription.cancel();
      }
      await userNetCarrier.stop();
      _nextCarrierIndex = (index + 1) % carriers.length;
    }
    return false;
  }

  Future<void> reconfigure() async {
    await stop();
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _lastProbeAt = null;
    _fallback = null;
    _mode = null;
  }

  Future<void> stop() async {
    _generation++;
    _fabricActive = false;
    _carrierUnhealthySince = null;
    await userNetCarrier.stop();
  }
}

final userNetFabricCoordinator = UserNetFabricCoordinator();
