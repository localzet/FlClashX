// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/plugins/usernet.dart';
import 'package:flclashx/services/usernet_account.dart';
import 'package:flclashx/services/usernet_connection.dart';
import 'package:flclashx/services/usernet_fabric_coordinator.dart';
import 'package:flclashx/services/usernet_preferences.dart';
import 'package:flclashx/services/usernet_transport.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/material.dart';

class UserNetConnectionPanel extends StatefulWidget {
  const UserNetConnectionPanel({super.key, this.compact = false});
  final bool compact;
  @override
  State<UserNetConnectionPanel> createState() => _UserNetConnectionPanelState();
}

class _UserNetConnectionPanelState extends State<UserNetConnectionPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  StreamSubscription<String>? _subscription;
  UserNetConnectionSnapshot _state = const UserNetConnectionSnapshot();
  bool _busy = false;
  bool _stopping = false;
  String? _error;
  int _revision = 0;
  int _operation = 0;
  Set<String> _availableControl = const {};
  Set<String> _availableWork = const {};

  @override
  void initState() {
    super.initState();
    _animation =
        AnimationController(vsync: this, duration: const Duration(seconds: 3));
    if (Platform.isAndroid) {
      _subscription =
          userNetCarrier.statuses.listen((_) => unawaited(_refresh()));
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    await userNetPreferences.load();
    await _refresh();
  }

  Future<void> _refresh() async {
    final revision = ++_revision;
    try {
      final state = await userNetCarrier.connectionState;
      final access = await userNetAccountService.cachedFabricAccess();
      final control = ((access?['carriers'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => item['platform'].toString())
          .toSet();
      final work = ((access?['workPlatforms'] as List?) ?? const [])
          .whereType<String>()
          .toSet();
      if (!mounted || revision != _revision) return;
      setState(() {
        _state = state;
        _availableControl = control;
        _availableWork = work;
      });
      _animate();
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _error = 'Не удалось получить состояние транспорта.');
      }
    }
  }

  @override
  void didUpdateWidget(covariant UserNetConnectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Platform.isAndroid) unawaited(_refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate();
  }

  void _animate() {
    final moving = (_state.connected || _state.connecting) &&
        !MediaQuery.disableAnimationsOf(context);
    if (moving && !_animation.isAnimating) {
      _animation.repeat();
    }
    if (!moving && _animation.isAnimating) {
      _animation.stop();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _animation.dispose();
    super.dispose();
  }

  Future<void> _change(
      {UserNetTransportMode? mode, String? control, String? work}) async {
    await _operate((active) async {
      await userNetPreferences.save(mode: mode, control: control, work: work);
      if (!active()) return;
      await userNetFabricCoordinator.reconfigure();
      if (!active()) return;
      if (globalState.startTime != null) {
        await globalState.appController.applyProfile(silence: true);
      }
    });
  }

  Future<void> _connect() async {
    await _operate((active) async {
      if (await userNetAccountService.cachedFabricAccess() == null) {
        throw StateError('Сначала подключите аккаунт по своей подписке.');
      }
      if (!active()) return;
      await userNetPreferences.save(mode: UserNetTransportMode.fabric);
      await userNetFabricCoordinator.reconfigure();
      if (!active()) return;
      final connected = await userNetFabricCoordinator.ensure(
        const UserNetTransportConfig(
            enabled: true,
            mode: UserNetTransportMode.fabric,
            socksHost: '127.0.0.1',
            socksPort: 17890,
            proxyName: userNetCarrierProxyName),
        forceProbe: true,
      );
      if (connected && active() && globalState.startTime != null) {
        await globalState.appController.applyProfile(silence: true);
      }
      if (!connected && active()) {
        throw StateError(
            'Транспорт не подключён. Проверьте выбранные сервисы и повторите.');
      }
    });
  }

  Future<void> _operate(
      Future<void> Function(bool Function()) operation) async {
    if (_busy) return;
    final ticket = ++_operation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation(() => mounted && ticket == _operation);
    } catch (error) {
      if (mounted && ticket == _operation) {
        setState(() => _error = error is StateError
            ? error.message.toString()
            : 'Не удалось переключить транспорт. Повторите попытку.');
      }
    } finally {
      if (mounted && ticket == _operation) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    _operation++;
    setState(() {
      _busy = true;
      _stopping = true;
      _error = null;
    });
    try {
      if (globalState.startTime != null) {
        await globalState.appController.updateStatus(false);
      }
      await userNetFabricCoordinator.stop();
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Не удалось завершить подключение. Повторите остановку.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stopping = false;
        });
        await _refresh();
      }
    }
  }

  static String _provider(String value) => switch (value) {
        'telemost' => 'Телемост',
        'vk' => 'VK Звонки',
        'wbstream' => 'WB Stream',
        _ => 'Авто',
      };

  Widget _stage(String title, UserNetConnectionPhase phase, String carrier) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (phase) {
      UserNetConnectionPhase.idle => 'Ожидание',
      UserNetConnectionPhase.connecting =>
        _state.status == 'TRANSPORT_VERIFYING' && title == 'Транспортный звонок'
            ? 'Проверка передачи данных…'
            : 'Подключение…',
      UserNetConnectionPhase.connected => 'Подключён',
      UserNetConnectionPhase.complete => 'Сессия выделена · звонок завершён',
      UserNetConnectionPhase.failed => 'Ошибка подключения',
    };
    final color = switch (phase) {
      UserNetConnectionPhase.connected ||
      UserNetConnectionPhase.complete =>
        Colors.green,
      UserNetConnectionPhase.failed => colors.error,
      UserNetConnectionPhase.connecting => colors.primary,
      _ => colors.outline,
    };
    return ListTile(
        dense: widget.compact,
        visualDensity:
            widget.compact ? VisualDensity.compact : VisualDensity.standard,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
            switch (phase) {
              UserNetConnectionPhase.connected ||
              UserNetConnectionPhase.complete =>
                Icons.check_circle_outline,
              UserNetConnectionPhase.failed => Icons.error_outline,
              _ => Icons.radio_button_unchecked,
            },
            color: color),
        title: Text(title),
        subtitle:
            Text('$label${carrier.isEmpty ? '' : ' · ${_provider(carrier)}'}'));
  }

  Widget _carrierSelector(
          String label, String value, ValueChanged<String> changed) =>
      DropdownButtonFormField<String>(
        key: ValueKey("$label:$value"),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: ['auto', 'telemost', 'vk', 'wbstream']
            .map((item) => DropdownMenuItem(
                value: item,
                enabled: item == 'auto' ||
                    (label.contains('контрольного')
                            ? _availableControl
                            : _availableWork)
                        .contains(item),
                child: Text(_provider(item), overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: _busy
            ? null
            : (value) {
                if (value != null) changed(value);
              },
      );

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final mode = userNetPreferences.mode ?? UserNetTransportMode.auto;
    return Card(
        child: Padding(
            padding: EdgeInsets.all(widget.compact ? 12 : 18),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('Соединение UserNet',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(_state.connected
                          ? 'Рабочий туннель установлен'
                          : 'Звонковый транспорт ${_state.connecting ? 'подключается' : 'не подключён'}'),
                    ])),
                SizedBox(
                    width: widget.compact ? 70 : 90,
                    height: widget.compact ? 56 : 76,
                    child: CustomPaint(
                        painter: _SignalPainter(
                            _animation, Theme.of(context).colorScheme.primary,
                            control: _state.control,
                            transport: _state.transport)))
              ]),
              _stage(
                  'Контрольный звонок', _state.control, _state.controlCarrier),
              _stage('Транспортный звонок', _state.transport,
                  _state.transportCarrier),
              if (widget.compact)
                TextButton(
                    onPressed: () =>
                        globalState.appController.toPage(PageLabel.account),
                    child: const Text('Настроить транспорт')),
              if (!widget.compact) ...[
                DropdownButtonFormField<UserNetTransportMode>(
                    key: ValueKey(mode),
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: 'Маршрут'),
                    items: const [
                      DropdownMenuItem(
                          value: UserNetTransportMode.auto,
                          child: Text('Автоматически')),
                      DropdownMenuItem(
                          value: UserNetTransportMode.direct,
                          child: Text('Прямой')),
                      DropdownMenuItem(
                          value: UserNetTransportMode.fabric,
                          child: Text('Через звонок'))
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) unawaited(_change(mode: value));
                          }),
                const SizedBox(height: 12),
                _carrierSelector(
                    'Сервис контрольного звонка',
                    userNetPreferences.controlCarrier,
                    (value) => unawaited(_change(control: value))),
                const SizedBox(height: 12),
                _carrierSelector(
                    'Сервис транспортного звонка',
                    userNetPreferences.workCarrier,
                    (value) => unawaited(_change(work: value))),
                const SizedBox(height: 8),
                const Text(
                    'Ручной выбор не подменяется другим сервисом. Доступность зависит от вашей подписки.'),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                const SizedBox(height: 12),
                Wrap(spacing: 8, children: [
                  FilledButton.icon(
                      onPressed: _busy || mode == UserNetTransportMode.direct
                          ? null
                          : _connect,
                      icon: const Icon(Icons.hub_outlined),
                      label: Text(
                          _busy ? 'Подключение…' : 'Подключить транспорт')),
                  OutlinedButton(
                      onPressed: _stopping ? null : _stop,
                      child: const Text('Остановить')),
                ]),
              ],
            ])));
  }
}

class _SignalPainter extends CustomPainter {
  _SignalPainter(this.animation, this.color,
      {required this.control, required this.transport})
      : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final UserNetConnectionPhase control;
  final UserNetConnectionPhase transport;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.34;
    final phases = [control, transport];
    for (var index = 0; index < phases.length; index++) {
      final phase = phases[index];
      final ready = phase == UserNetConnectionPhase.connected ||
          phase == UserNetConnectionPhase.complete;
      final active = phase == UserNetConnectionPhase.connecting;
      final r = radius * (index == 0 ? 0.65 : 1);
      final rect = Rect.fromCircle(center: center, radius: r);
      final pen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3
        ..color = color.withValues(alpha: ready ? 0.8 : 0.14);
      canvas.drawArc(rect, -math.pi * 0.8, math.pi * 1.6, false, pen);
      if (active) {
        pen.color = color;
        final start = -math.pi * 0.8 + animation.value * math.pi * 1.2;
        canvas.drawArc(rect, start, math.pi * 0.4, false, pen);
      }
    }
    final pulse = transport == UserNetConnectionPhase.connected
        ? 0.7 + math.sin(animation.value * math.pi * 2) * 0.12
        : 0.25;
    canvas.drawCircle(
        center, 3, Paint()..color = color.withValues(alpha: pulse));
  }

  @override
  bool shouldRepaint(_SignalPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.control != control ||
      oldDelegate.transport != transport;
}
