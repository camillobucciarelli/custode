import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Marketing version, mirrored by hand from `pubspec.yaml` `version:`.
/// `.github/workflows/release.yml` only bumps the build number after the `+`,
/// so this string changes only on a deliberate release bump. Kept literal so
/// no runtime dependency (e.g. `package_info_plus`) has to be added.
const kApplicationVersion = '0.7.0';

const kDownloadPageUrl = 'https://custode.camillobucciarelli.dev/';
const _latestUrl = 'https://custode.camillobucciarelli.dev/latest.json';

final _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

/// True when [remote] and [local] are both `X.Y.Z` and [remote] is newer,
/// compared per numeric component. Anything malformed is "not newer".
bool isNewerVersion(String remote, String local) {
  if (!_versionPattern.hasMatch(remote) || !_versionPattern.hasMatch(local)) {
    return false;
  }
  final r = remote.split('.').map(int.parse).toList();
  final l = local.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    if (r[i] != l[i]) return r[i] > l[i];
  }
  return false;
}

class UpdateCheckState {
  const UpdateCheckState({
    required this.enabled,
    this.availableVersion,
    this.announce = false,
  });

  final bool enabled;

  /// A validated `X.Y.Z` newer than the running app, or null.
  final String? availableVersion;

  /// True only on the emission that should raise the one-time notice.
  final bool announce;
}

/// Opt-in "new version available" check against a static `latest.json`.
/// No network request is ever made while the setting is off.
class UpdateCheckCubit extends Cubit<UpdateCheckState> {
  UpdateCheckCubit(
    this._prefs,
    this._client, {
    DateTime Function()? now,
    this.supported = !kIsWeb,
  }) : _now = now ?? DateTime.now,
       super(_initial(_prefs, supported));

  static const enabledKey = 'update_check_enabled';
  static const lastCheckKey = 'update_check_last_ms';
  static const latestKey = 'update_check_latest_version';
  static const notifiedKey = 'update_check_notified_version';
  static const interval = Duration(hours: 24);

  final SharedPreferences _prefs;
  final http.Client _client;
  final DateTime Function() _now;
  final bool supported;

  static UpdateCheckState _initial(SharedPreferences prefs, bool supported) {
    final enabled = supported && (prefs.getBool(enabledKey) ?? false);
    final latest = prefs.getString(latestKey);
    return UpdateCheckState(
      enabled: enabled,
      availableVersion:
          enabled &&
              latest != null &&
              isNewerVersion(latest, kApplicationVersion)
          ? latest
          : null,
    );
  }

  /// Call once at app start; throttled to once per [interval].
  Future<void> checkOnStart() => _check(force: false);

  Future<void> setEnabled(bool value) async {
    if (!supported) return;
    await _prefs.setBool(enabledKey, value);
    emit(UpdateCheckState(enabled: value));
    if (value) await _check(force: true);
  }

  Future<void> _check({required bool force}) async {
    if (!supported || !(_prefs.getBool(enabledKey) ?? false)) return;
    final nowMs = _now().millisecondsSinceEpoch;
    final last = _prefs.getInt(lastCheckKey);
    if (!force && last != null && nowMs - last < interval.inMilliseconds) {
      return;
    }
    final String version;
    try {
      final response = await _client
          .get(Uri.parse(_latestUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final raw = body is Map ? body['version'] : null;
      // The payload is untrusted: only a strict X.Y.Z is ever used.
      if (raw is! String || !_versionPattern.hasMatch(raw)) return;
      version = raw;
    } catch (_) {
      return;
    }
    if (isClosed) return;
    await _prefs.setInt(lastCheckKey, nowMs);
    await _prefs.setString(latestKey, version);
    if (!(_prefs.getBool(enabledKey) ?? false)) return;
    if (!isNewerVersion(version, kApplicationVersion)) {
      emit(UpdateCheckState(enabled: true));
      return;
    }
    final announce = _prefs.getString(notifiedKey) != version;
    if (announce) await _prefs.setString(notifiedKey, version);
    emit(
      UpdateCheckState(
        enabled: true,
        availableVersion: version,
        announce: announce,
      ),
    );
  }
}
