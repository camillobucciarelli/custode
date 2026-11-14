import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'update_check_gateway.dart';

/// Marketing version, mirrored by hand from `pubspec.yaml` `version:`.
/// `.github/workflows/release.yml` only bumps the build number after the `+`,
/// so this string changes only on a deliberate release bump. Kept literal so
/// no runtime dependency (e.g. `package_info_plus`) has to be added.
const kApplicationVersion = '0.7.1';

const kDownloadPageUrl = 'https://custode.camillobucciarelli.dev/';

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
    this._gateway, {
    DateTime Function()? now,
    this.supported = !kIsWeb,
  }) : _now = now ?? DateTime.now,
       super(_initial(_gateway, supported));

  static const interval = Duration(hours: 24);

  final UpdateCheckGateway _gateway;
  final DateTime Function() _now;
  final bool supported;

  static UpdateCheckState _initial(UpdateCheckGateway gateway, bool supported) {
    final enabled = supported && gateway.enabled;
    final latest = gateway.latestVersion;
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
    await _gateway.setEnabled(value);
    emit(UpdateCheckState(enabled: value));
    if (value) await _check(force: true);
  }

  Future<void> _check({required bool force}) async {
    if (!supported || !_gateway.enabled) return;
    final nowMs = _now().millisecondsSinceEpoch;
    final last = _gateway.lastCheckMs;
    if (!force && last != null && nowMs - last < interval.inMilliseconds) {
      return;
    }
    final version = await _gateway.fetchLatestVersion();
    if (version == null) return;
    if (isClosed) return;
    await _gateway.setLastCheckMs(nowMs);
    await _gateway.setLatestVersion(version);
    if (!_gateway.enabled) return;
    if (!isNewerVersion(version, kApplicationVersion)) {
      emit(UpdateCheckState(enabled: true));
      return;
    }
    final announce = _gateway.notifiedVersion != version;
    if (announce) await _gateway.setNotifiedVersion(version);
    emit(
      UpdateCheckState(
        enabled: true,
        availableVersion: version,
        announce: announce,
      ),
    );
  }
}
