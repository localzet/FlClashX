import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class UserNetRelease {
  const UserNetRelease({
    required this.version,
    required this.build,
    required this.notes,
    required this.downloadUrl,
    required this.sha256,
  });

  final String version;
  final int build;
  final String notes;
  final Uri downloadUrl;
  final String sha256;

  static UserNetRelease? parse(Map<String, dynamic> json,
      {String platform = 'android'}) {
    final version = json['version']?.toString();
    final build = json['build'];
    final notes = json['notes']?.toString() ?? '';
    final urlField = platform == 'windows' ? 'installerUrl' : 'apkUrl';
    final artifactUrl = Uri.tryParse(json[urlField]?.toString() ?? '');
    final artifactPath = platform == 'windows' ? '/windows/' : '/android/';
    final artifactExtension = platform == 'windows' ? '.exe' : '.apk';
    final sha256 = json['sha256']?.toString().toLowerCase();
    if (version == null ||
        version.isEmpty ||
        build is! int ||
        build <= 0 ||
        artifactUrl == null ||
        artifactUrl.scheme != 'https' ||
        artifactUrl.host != 'updates.userlay.com' ||
        artifactUrl.hasQuery ||
        artifactUrl.hasFragment ||
        !artifactUrl.path.startsWith(artifactPath) ||
        !artifactUrl.path.endsWith(artifactExtension) ||
        sha256 == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      return null;
    }
    return UserNetRelease(
        version: version,
        build: build,
        notes: notes,
        downloadUrl: artifactUrl,
        sha256: sha256);
  }
}

class UserNetUpdateService {
  UserNetUpdateService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  static final _platform = Platform.isWindows
      ? 'windows'
      : Platform.isAndroid
          ? 'android'
          : 'unsupported';
  static final _manifestUrl = Uri.parse(
    const String.fromEnvironment('USERNET_RELEASE_MANIFEST_URL').isNotEmpty
        ? const String.fromEnvironment('USERNET_RELEASE_MANIFEST_URL')
        : 'https://updates.userlay.com/$_platform/stable.json',
  );

  Future<UserNetRelease?> latest() async {
    if (_platform == 'unsupported') return null;
    if (_manifestUrl.scheme != 'https') {
      throw const FormatException('Release manifest must use HTTPS');
    }
    final response = await _client.get(_manifestUrl, headers: {
      'Accept': 'application/json'
    }).timeout(const Duration(seconds: 10));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('Release server returned ${response.statusCode}');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map) {
      throw const FormatException('Invalid release manifest');
    }
    final release = UserNetRelease.parse(Map<String, dynamic>.from(json),
        platform: _platform);
    if (release == null) {
      throw const FormatException('Invalid release metadata');
    }
    return release;
  }

  Future<UserNetRelease?> availableUpdate() async {
    final release = await latest();
    if (release == null) return null;
    final package = await PackageInfo.fromPlatform();
    final installedBuild = int.tryParse(package.buildNumber) ?? 0;
    return release.build > installedBuild ? release : null;
  }
}

final userNetUpdateService = UserNetUpdateService();
