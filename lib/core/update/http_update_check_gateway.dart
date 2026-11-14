import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'update_check_gateway.dart';

const kLatestUrl = 'https://custode.camillobucciarelli.dev/latest.json';

final _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

class HttpUpdateCheckGateway implements UpdateCheckGateway {
  HttpUpdateCheckGateway(this._prefs, this._client);

  static const enabledKey = 'update_check_enabled';
  static const lastCheckKey = 'update_check_last_ms';
  static const latestKey = 'update_check_latest_version';
  static const notifiedKey = 'update_check_notified_version';

  final SharedPreferences _prefs;
  final http.Client _client;

  @override
  bool get enabled => _prefs.getBool(enabledKey) ?? false;
  @override
  Future<void> setEnabled(bool value) => _prefs.setBool(enabledKey, value);

  @override
  int? get lastCheckMs => _prefs.getInt(lastCheckKey);
  @override
  Future<void> setLastCheckMs(int value) => _prefs.setInt(lastCheckKey, value);

  @override
  String? get latestVersion => _prefs.getString(latestKey);
  @override
  Future<void> setLatestVersion(String value) =>
      _prefs.setString(latestKey, value);

  @override
  String? get notifiedVersion => _prefs.getString(notifiedKey);
  @override
  Future<void> setNotifiedVersion(String value) =>
      _prefs.setString(notifiedKey, value);

  @override
  Future<String?> fetchLatestVersion() async {
    try {
      final response = await _client
          .get(Uri.parse(kLatestUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final raw = body is Map ? body['version'] : null;
      // The payload is untrusted: only a strict X.Y.Z is ever used.
      if (raw is! String || !_versionPattern.hasMatch(raw)) return null;
      return raw;
    } catch (_) {
      return null;
    }
  }
}
