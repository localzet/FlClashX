// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

enum UserNetConnectionPhase { idle, connecting, connected, complete, failed }

class UserNetConnectionSnapshot {
  const UserNetConnectionSnapshot({
    this.status = 'STOPPED',
    this.control = UserNetConnectionPhase.idle,
    this.transport = UserNetConnectionPhase.idle,
    this.controlCarrier = '',
    this.transportCarrier = '',
  });

  factory UserNetConnectionSnapshot.fromMap(Map<String, dynamic> data) {
    UserNetConnectionPhase phase(Object? value) =>
        UserNetConnectionPhase.values.firstWhere((item) => item.name == value,
            orElse: () => UserNetConnectionPhase.idle);
    return UserNetConnectionSnapshot(
      status: data['status']?.toString() ?? 'UNKNOWN',
      control: phase(data['controlState']),
      transport: phase(data['transportState']),
      controlCarrier: data['controlCarrier']?.toString() ?? '',
      transportCarrier: data['transportCarrier']?.toString() ?? '',
    );
  }

  final String status;
  final UserNetConnectionPhase control;
  final UserNetConnectionPhase transport;
  final String controlCarrier;
  final String transportCarrier;
  bool get connected => transport == UserNetConnectionPhase.connected;
  bool get connecting =>
      control == UserNetConnectionPhase.connecting ||
      transport == UserNetConnectionPhase.connecting;
}
