import 'package:flclashx/services/usernet_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const digest =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('accepts a hosted, versioned Android release', () {
    final release = UserNetRelease.parse({
      'version': '0.5.0',
      'build': 2026091601,
      'notes': 'Stability update',
      'apkUrl': 'https://updates.userlay.com/android/usernet-0.5.0.apk',
      'sha256': digest,
    });
    expect(release?.build, 2026091601);
    expect(release?.downloadUrl.host, 'updates.userlay.com');
  });

  test('accepts a Windows installer only from the Windows release path', () {
    final release = UserNetRelease.parse({
      'version': '0.5.1',
      'build': 2026091607,
      'installerUrl':
          'https://updates.userlay.com/windows/usernet-0.5.1-2026091607.exe',
      'sha256': digest,
    }, platform: 'windows');
    expect(release?.downloadUrl.path, '/windows/usernet-0.5.1-2026091607.exe');
    expect(
        UserNetRelease.parse({
          'version': '0.5.1',
          'build': 2026091607,
          'installerUrl': 'https://updates.userlay.com/android/usernet.apk',
          'sha256': digest,
        }, platform: 'windows'),
        isNull);
  });

  test('rejects downloads from another host', () {
    expect(
        UserNetRelease.parse({
          'version': '0.5.0',
          'build': 2026091601,
          'apkUrl': 'https://example.com/usernet.apk',
          'sha256': digest,
        }),
        isNull);
  });

  test('rejects releases without a SHA-256 digest', () {
    expect(
        UserNetRelease.parse({
          'version': '0.5.0',
          'build': 2026091601,
          'apkUrl': 'https://updates.userlay.com/android/usernet.apk',
          'sha256': 'bad',
        }),
        isNull);
  });
}
