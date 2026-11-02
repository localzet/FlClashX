import 'package:flclashx/services/usernet_update.dart';
import 'package:flclashx/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutView extends StatefulWidget {
  const AboutView({super.key});

  @override
  State<AboutView> createState() => _AboutViewState();
}

class _AboutViewState extends State<AboutView> {
  bool _checking = false;
  String? _updateMessage;

  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _updateMessage = null;
    });
    try {
      final release = await userNetUpdateService.availableUpdate();
      if (!mounted) return;
      if (release == null) {
        setState(() => _updateMessage = 'Установлена актуальная версия.');
        return;
      }
      final download = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('UserNet ${release.version}'),
          content: Text(
              release.notes.isEmpty ? 'Доступна новая версия.' : release.notes),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Позже')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Скачать обновление')),
          ],
        ),
      );
      if (download == true) {
        await launchUrl(release.downloadUrl,
            mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _updateMessage =
            'Не удалось проверить обновления. Проверьте соединение.');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Center(
                    child: SvgPicture.asset('assets/images/usernet_mark.svg',
                        width: 112, height: 112)),
                const SizedBox(height: 20),
                Text('UserNet',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('от команды userlay.com',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 4),
                Text(
                    'Версия ${globalState.packageInfo.version} '
                    '(${globalState.packageInfo.buildNumber})',
                    textAlign: TextAlign.center),
                const SizedBox(height: 28),
                const Card(
                    child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(
                            'Один клиент для обычного защищённого соединения '
                            'и резервного доступа через звонок, когда прямой путь '
                            'недоступен. Ваш аккаунт, подписка и выбор сервера '
                            'остаются в UserNet.'))),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _checking ? null : _checkUpdate,
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(_checking ? 'Проверяем…' : 'Проверить обновления'),
                ),
                if (_updateMessage != null) ...[
                  const SizedBox(height: 10),
                  Text(_updateMessage!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                ListTile(
                  leading: const Icon(Icons.language),
                  title: const Text('userlay.com'),
                  onTap: () => launchUrl(Uri.parse('https://userlay.com'),
                      mode: LaunchMode.externalApplication),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Лицензии открытых компонентов'),
                  onTap: () => showLicensePage(
                      context: context, applicationName: 'UserNet'),
                ),
                const SizedBox(height: 12),
                Text('© 2026 userlay.com',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          )),
        ],
      );
}
