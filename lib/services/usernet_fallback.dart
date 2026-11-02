import 'package:flclashx/services/usernet_transport.dart';

enum UserNetPath { direct, fabric }

class UserNetFallbackPolicy {
  const UserNetFallbackPolicy({
    this.failuresBeforeFabric = 3,
    this.successesBeforeDirect = 3,
    this.switchCooldown = const Duration(seconds: 30),
  })  : assert(
          failuresBeforeFabric > 0,
          'failuresBeforeFabric must be positive',
        ),
        assert(
          successesBeforeDirect > 0,
          'successesBeforeDirect must be positive',
        );

  final int failuresBeforeFabric;
  final int successesBeforeDirect;
  final Duration switchCooldown;
}

/// Hysteresis-only state machine. Network probing and Mihomo reloads remain
/// outside this class so they can use platform-specific protected sockets.
class UserNetFallbackController {
  UserNetFallbackController({
    required UserNetTransportMode mode,
    this.policy = const UserNetFallbackPolicy(),
  })  : _mode = mode,
        _path = mode == UserNetTransportMode.fabric
            ? UserNetPath.fabric
            : UserNetPath.direct;

  final UserNetFallbackPolicy policy;
  UserNetTransportMode _mode;
  UserNetPath _path;
  int _directFailures = 0;
  int _directSuccesses = 0;
  DateTime? _lastSwitchAt;

  UserNetTransportMode get mode => _mode;
  UserNetPath get path => _path;

  void setMode(UserNetTransportMode value, {DateTime? now}) {
    _mode = value;
    _directFailures = 0;
    _directSuccesses = 0;
    final forcedPath = switch (value) {
      UserNetTransportMode.fabric => UserNetPath.fabric,
      UserNetTransportMode.direct => UserNetPath.direct,
      UserNetTransportMode.auto => _path,
    };
    if (forcedPath != _path) {
      _path = forcedPath;
      _lastSwitchAt = now ?? DateTime.now();
    }
  }

  UserNetPath recordDirectProbe({
    required bool succeeded,
    DateTime? now,
  }) {
    if (_mode != UserNetTransportMode.auto) return _path;
    final timestamp = now ?? DateTime.now();
    if (_path == UserNetPath.direct) {
      _directSuccesses = 0;
      _directFailures = succeeded ? 0 : _directFailures + 1;
      if (_directFailures >= policy.failuresBeforeFabric &&
          _cooldownElapsed(timestamp)) {
        _switchTo(UserNetPath.fabric, timestamp);
      }
    } else {
      _directFailures = 0;
      _directSuccesses = succeeded ? _directSuccesses + 1 : 0;
      if (_directSuccesses >= policy.successesBeforeDirect &&
          _cooldownElapsed(timestamp)) {
        _switchTo(UserNetPath.direct, timestamp);
      }
    }
    return _path;
  }

  bool _cooldownElapsed(DateTime now) =>
      _lastSwitchAt == null ||
      now.difference(_lastSwitchAt!) >= policy.switchCooldown;

  void _switchTo(UserNetPath value, DateTime now) {
    _path = value;
    _lastSwitchAt = now;
    _directFailures = 0;
    _directSuccesses = 0;
  }
}
