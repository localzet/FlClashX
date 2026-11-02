// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

import 'dart:async';
import 'dart:io';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/plugins/usernet.dart';
import 'package:flclashx/services/usernet_account.dart';
import 'package:flclashx/services/usernet_fabric_coordinator.dart';
import 'package:flclashx/services/usernet_transport.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/usernet_connection_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class AccountView extends StatefulWidget {
  const AccountView({super.key});

  @override
  State<AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends State<AccountView> with WidgetsBindingObserver {
  final _subscriptionController = TextEditingController();
  final _referralController = TextEditingController();
  bool _loading = true;
  bool _signedIn = false;
  String? _error;
  Map<String, dynamic>? _account;
  Map<String, dynamic>? _referrals;
  List<Map<String, dynamic>> _plans = const [];
  String? _pendingPurchaseId;
  StreamSubscription<String>? _paymentReturnSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _paymentReturnSubscription =
        userNetAccountService.paymentReturns.listen((purchaseId) {
      _pendingPurchaseId = purchaseId;
      unawaited(_refreshPurchase());
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_paymentReturnSubscription?.cancel());
    _subscriptionController.dispose();
    _referralController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    _pendingPurchaseId = await userNetAccountService.pendingPurchaseId;
    await _load();
    if (_pendingPurchaseId != null) await _refreshPurchase();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingPurchaseId != null) {
      unawaited(_refreshPurchase());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final signedIn = await userNetAccountService.isSignedIn;
      if (!mounted) return;
      setState(() => _signedIn = signedIn);
      if (!signedIn) {
        if (mounted) setState(() => _account = null);
        return;
      }
      await _ensureAccountTransport();
      final results = await Future.wait([
        userNetAccountService.account(),
        userNetAccountService
            .plans()
            .catchError((_) => <Map<String, dynamic>>[]),
        userNetAccountService
            .referrals()
            .catchError((_) => <String, dynamic>{}),
      ]);
      if (!mounted) return;
      setState(() {
        _account = results[0] as Map<String, dynamic>;
        _plans = results[1] as List<Map<String, dynamic>>;
        _referrals = results[2] as Map<String, dynamic>;
      });
      // Showing the account must not wait for a subscription download. During
      // censorship that download can span a carrier reconnect; install it in
      // the background and leave the account usable in the meantime.
      unawaited(_installOwnedProfileIfNeeded().catchError((_) {}));
    } on UserNetApiException catch (error) {
      if (error.statusCode == 401) {
        await userNetAccountService.logout();
        if (mounted) {
          setState(() {
            _signedIn = false;
            _account = null;
          });
        }
      } else if (mounted) {
        setState(() => _error = _friendlyError(error));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Не удалось связаться с UserNet: $error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _register() async {
    await _run(() async {
      await userNetAccountService.register(
        referralCode: _referralController.text,
      );
      await _load();
    });
  }

  Future<void> _claim() async {
    final url = _subscriptionController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Вставьте ссылку действующей подписки UserNet.');
      return;
    }
    await _run(() async {
      await userNetAccountService.claimSubscription(url);
      await _load();
    });
  }

  Future<void> _buy(int months) async {
    await _run(() async {
      final checkout = await userNetAccountService.createCheckout(months);
      final url = Uri.tryParse(checkout['confirmationUrl']?.toString() ?? '');
      _pendingPurchaseId = checkout['purchaseId']?.toString();
      if (_pendingPurchaseId != null) {
        await userNetAccountService.rememberPendingPurchase(
          _pendingPurchaseId!,
        );
      }
      if (url == null ||
          !await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const UserNetApiException('USERNET_CANNOT_OPEN_PAYMENT');
      }
    });
  }

  Future<void> _refreshPurchase() async {
    final purchaseId = _pendingPurchaseId;
    if (purchaseId == null) return;
    await _run(() async {
      final purchase = await userNetAccountService.purchase(purchaseId);
      if (purchase['status'] == 'paid' || purchase['status'] == 'cancel') {
        await userNetAccountService.clearPendingPurchase();
        _pendingPurchaseId = null;
        if (purchase['status'] == 'paid') await _load();
      }
    });
  }

  Future<void> _logout() async {
    await _run(() async {
      await userNetAccountService.logout();
      if (mounted) {
        setState(() {
          _signedIn = false;
          _account = null;
          _plans = const [];
          _referrals = null;
        });
      }
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _ensureAccountTransport();
      await operation();
    } on UserNetApiException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _ensureAccountTransport() async {
    if (!Platform.isAndroid ||
        await userNetCarrier.currentStatus == 'TUNNEL_CONNECTED') {
      return;
    }
    // Returning users already have a per-user Fabric credential in secure
    // storage. Their account can reconnect over a call before a profile or
    // VPN session has been started on a censored network.
    if (await userNetAccountService.cachedFabricAccess() == null ||
        await userNetAccountService.isDirectApiReachable()) {
      return;
    }
    await userNetFabricCoordinator.ensure(
      const UserNetTransportConfig(
        enabled: true,
        mode: UserNetTransportMode.fabric,
        socksHost: '127.0.0.1',
        socksPort: 17890,
        proxyName: userNetCarrierProxyName,
      ),
      forceProbe: true,
    );
  }

  Future<void> _installOwnedProfileIfNeeded() async {
    final subscription = _account?['subscription'] as Map<String, dynamic>?;
    final url = subscription?['subscriptionUrl']?.toString();
    if (url == null || url.isEmpty) return;
    final exists =
        globalState.config.profiles.any((profile) => profile.url == url);
    if (!exists) {
      await globalState.appController.addProfileFormURL(url);
    }
  }

  String _friendlyError(UserNetApiException error) => switch (error.message) {
        'USERNET_SUBSCRIPTION_NOT_OWNED' ||
        'USERNET_SUBSCRIPTION_HOST_NOT_ALLOWED' =>
          'Это не подписка UserNet. Профиль можно импортировать, но войти по нему нельзя.',
        'USERNET_DEVICE_ALREADY_REGISTERED' =>
          'Это устройство уже зарегистрировано. Войдите по ссылке своей подписки.',
        'BLACKLISTED' => 'Аккаунт заблокирован.',
        'USERNET_UNEXPECTED_RESPONSE' =>
          'Сервер аккаунта вернул неожиданный ответ. Повторите попытку.',
        'USERNET_CANNOT_OPEN_PAYMENT' => 'Не удалось открыть страницу оплаты.',
        'USERNET_FIRST_SIGNIN_REQUIRES_NETWORK' =>
          'Не удалось подключиться к серверу аккаунта. При действующих белых списках первая привязка возможна только через сеть с доступом к api.userlay.com. После привязки звонковый транспорт сможет обслуживать аккаунт.',
        'USERNET_NETWORK_TIMEOUT' ||
        'USERNET_NETWORK_UNAVAILABLE' =>
          'Не удалось подключиться к серверу аккаунта. Проверьте сеть и состояние звонкового транспорта.',
        _ => error.message,
      };

  @override
  Widget build(BuildContext context) {
    if (_loading && _account == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _buildTransportStatus(context),
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (_error != null) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_account == null && _signedIn)
            _buildOfflineAccount(context)
          else if (_account == null)
            _buildSignIn(context)
          else
            _buildAccount(context),
          const SizedBox(height: 12),
          _buildTransportStatus(context),
          if (_loading) const LinearProgressIndicator(),
        ],
      ),
    );
  }

  Widget _buildOfflineAccount(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Аккаунт подключён',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                  'Привязка сохранена на устройстве. Данные подписки появятся после восстановления связи с сервером.'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить подключение'),
              ),
            ],
          ),
        ),
      );

  Widget _buildSignIn(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Аккаунт UserNet',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Создайте новый аккаунт без Telegram или войдите по ссылке подписки, которую ранее выдал наш сервис.',
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _referralController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Код приглашения (необязательно)',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loading ? null : _register,
            icon: const Icon(Icons.person_add),
            label: const Text('Создать аккаунт'),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: Row(children: [
              Expanded(child: Divider()),
              Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('или')),
              Expanded(child: Divider())
            ]),
          ),
          TextField(
            controller: _subscriptionController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Ссылка существующей подписки',
              suffixIcon: IconButton(
                tooltip: 'Вставить',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    _subscriptionController.text = data!.text!;
                  }
                },
                icon: const Icon(Icons.paste),
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loading ? null : _claim,
            icon: const Icon(Icons.login),
            label: const Text('Войти по подписке'),
          ),
          if (isUserNetSubscription(
              globalState.config.currentProfile?.url ?? ''))
            TextButton.icon(
              onPressed: _loading
                  ? null
                  : () {
                      _subscriptionController.text =
                          canonicalUserNetSubscriptionUrl(
                              globalState.config.currentProfile!.url);
                      unawaited(_claim());
                    },
              icon: const Icon(Icons.link),
              label: const Text('Подключить аккаунт текущей подписки'),
            ),
        ],
      );

  Widget _buildAccount(BuildContext context) {
    final user = _account?['user'] as Map<String, dynamic>? ?? const {};
    final subscription = _account?['subscription'] as Map<String, dynamic>?;
    final capabilities =
        _account?['capabilities'] as Map<String, dynamic>? ?? const {};
    final paymentsEnabled = capabilities['paymentsEnabled'] == true;
    final level = user['level']?.toString().toLowerCase() ?? 'ferrum';
    final isPlatinum = level == 'platinum';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user['displayName']?.toString() ?? 'UserNet',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('Уровень: ${_levelLabel(level)}'),
                const SizedBox(height: 4),
                Text(subscription == null
                    ? 'Подписки пока нет'
                    : isPlatinum
                        ? 'Подписка: навсегда'
                        : 'Статус: ${subscription['status']}\nДействует до: ${_date(subscription['expireAt'])}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (!isPlatinum) ...[
          Text(subscription == null ? 'Купить подписку' : 'Продлить подписку',
              style: Theme.of(context).textTheme.titleMedium),
          if (!paymentsEnabled)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Оплата в приложении временно недоступна. Требуется настройка магазина YooKassa.',
              ),
            ),
          const SizedBox(height: 8),
          ..._plans.map((plan) => Card(
                child: ListTile(
                  title: Text('${plan['months']} мес.'),
                  subtitle: Text('Скидка ${plan['discount']}%'),
                  trailing: FilledButton(
                    onPressed: _loading || !paymentsEnabled
                        ? null
                        : () => _buy(plan['months'] as int),
                    child: Text('${plan['amount']} ₽'),
                  ),
                ),
              )),
        ],
        const SizedBox(height: 16),
        _buildReferral(context),
        if (_pendingPurchaseId != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loading ? null : _refreshPurchase,
            icon: const Icon(Icons.refresh),
            label: const Text('Проверить оплату'),
          ),
        ],
        const SizedBox(height: 24),
        TextButton(
            onPressed: _loading ? null : _logout,
            child: const Text('Выйти из аккаунта')),
      ],
    );
  }

  Widget _buildTransportStatus(BuildContext context) =>
      UserNetConnectionPanel(key: ValueKey(_account));

  Widget _buildReferral(BuildContext context) {
    final data = _referrals ?? const <String, dynamic>{};
    final url = data['inviteUrl']?.toString() ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Пригласить друзей',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
                'Приглашено: ${data['invitedCount'] ?? 0} · текущая скидка ${data['discount'] ?? 0}%'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: url.isEmpty
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: url));
                      if (mounted) {
                        messenger.showSnackBar(const SnackBar(
                            content: Text('Ссылка скопирована')));
                      }
                    },
              icon: const Icon(Icons.copy),
              label: const Text('Скопировать приглашение'),
            ),
          ],
        ),
      ),
    );
  }

  String _date(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return 'неизвестно';
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }

  String _levelLabel(String level) => switch (level) {
        'platinum' => 'Платинум',
        'aurum' => 'Золото',
        'argentum' => 'Серебро',
        _ => 'Железо',
      };
}
