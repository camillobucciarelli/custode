import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

bool get isMobilePlatform {
  if (kIsWeb) {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => false,
  };
}

/// Managed (app-internal) storage exists wherever databases persist; the
/// browser override therefore turns it off too.
bool get isManagedStoragePlatform =>
    _debugCapabilities?.persistsDatabases ?? !kIsWeb;

/// Capability snapshot read through the getters below. Tests override it with
/// [debugPlatformCapabilities] to run the same widget tree as web or native.
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.supportsRemoteSource,
    required this.supportsBiometricUnlock,
    required this.persistsDatabases,
  });

  final bool supportsRemoteSource;
  final bool supportsBiometricUnlock;
  final bool persistsDatabases;
}

PlatformCapabilities? _debugCapabilities;

@visibleForTesting
set debugPlatformCapabilities(PlatformCapabilities? value) =>
    _debugCapabilities = value;

/// Google Drive and other remote sources are unavailable in the browser.
bool get supportsRemoteSource =>
    _debugCapabilities?.supportsRemoteSource ?? !kIsWeb;

/// Device biometric availability is still asked to `BiometricDataSource`.
bool get supportsBiometricUnlock =>
    _debugCapabilities?.supportsBiometricUnlock ?? !kIsWeb;

/// Web creates by downloading; every other platform keeps the database.
bool get persistsDatabases => _debugCapabilities?.persistsDatabases ?? !kIsWeb;
