import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class VersionCheckService {
  static const _kUrl =
      'https://sarahsforge.dev/api/version.php?slug=pocketaero';

  String _localVersion = '';
  String _remoteVersion = '';
  bool _updateAvailable = false;
  String _productUrl = '';

  bool get updateAvailable => _updateAvailable;
  String get remoteVersion => _remoteVersion;
  String get localVersion => _localVersion;
  String get productUrl => _productUrl;

  Future<void> init() async {
    if (_localVersion.isNotEmpty) return;
    final info = await PackageInfo.fromPlatform();
    _localVersion = info.version;
  }

  Future<void> check() async {
    try {
      final resp = await http.get(Uri.parse(_kUrl));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _remoteVersion = (data['version'] as String?) ?? '';
      _productUrl = (data['product_url'] as String?) ?? '';

      _updateAvailable = _compareVersions(_remoteVersion, _localVersion) > 0;
    } catch (_) {
      // Network errors = no notification
    }
  }

  /// Returns >0 if a > b, <0 if a < b, 0 if equal.
  static int _compareVersions(String a, String b) {
    final aParts = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bParts = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av - bv;
    }
    return 0;
  }
}
