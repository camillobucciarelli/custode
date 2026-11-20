import 'package:password_manager/features/password_manager/presentation/utils/platform_utils.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugPlatformCapabilities = null);

  test('defaults follow the host platform', () {
    expect(supportsRemoteSource, !kIsWeb);
    expect(supportsBiometricUnlock, !kIsWeb);
    expect(persistsDatabases, !kIsWeb);
  });

  test('override applies and reset restores the defaults', () {
    debugPlatformCapabilities = const PlatformCapabilities(
      supportsRemoteSource: false,
      supportsBiometricUnlock: false,
      persistsDatabases: false,
    );
    expect(supportsRemoteSource, isFalse);
    expect(supportsBiometricUnlock, isFalse);
    expect(persistsDatabases, isFalse);

    debugPlatformCapabilities = const PlatformCapabilities(
      supportsRemoteSource: true,
      supportsBiometricUnlock: true,
      persistsDatabases: true,
    );
    expect(supportsRemoteSource, isTrue);
    expect(supportsBiometricUnlock, isTrue);
    expect(persistsDatabases, isTrue);

    debugPlatformCapabilities = null;
    expect(persistsDatabases, !kIsWeb);
  });
}
