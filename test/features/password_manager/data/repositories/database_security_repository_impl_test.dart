import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/database_security_local_data_source.dart';
import 'package:password_manager/features/password_manager/data/repositories/database_security_repository_impl.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseSecurityRepositoryImpl', () {
    late Directory tempDir;
    late _FakeSecurityLocalDataSource localDataSource;
    late DatabaseSecurityRepositoryImpl repository;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('security_repo_test_');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      localDataSource = _FakeSecurityLocalDataSource();
      repository = DatabaseSecurityRepositoryImpl(
        localDataSource: localDataSource,
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('spec-011 FR-7: an absent biometricProtectionEnabled flag '
        'deserialises to false, never true', () async {
      localDataSource.profiles['db-legacy'] = {
        'databaseId': 'db-legacy',
        // Pre-spec-011 profiles have no biometricProtectionEnabled field.
      };

      final profile = await repository.getProfile('db-legacy');

      expect(profile, isNotNull);
      expect(profile!.biometricProtectionEnabled, isFalse);
    });

    test('an explicit flag round-trips unchanged', () async {
      await repository.saveProfile(
        const DatabaseSecurityProfile(
          databaseId: 'db-on',
          biometricProtectionEnabled: true,
        ),
      );

      final profile = await repository.getProfile('db-on');

      expect(profile!.biometricProtectionEnabled, isTrue);
    });

    test('spec 025: an absent biometricOfferAnswered flag decodes to false '
        '(existing installs are offered once)', () async {
      localDataSource.profiles['db-legacy'] = {
        'databaseId': 'db-legacy',
        'biometricProtectionEnabled': false,
      };

      final profile = await repository.getProfile('db-legacy');

      expect(profile!.biometricOfferAnswered, isFalse);
    });

    test('spec 025: biometricOfferAnswered round-trips unchanged', () async {
      await repository.saveProfile(
        const DatabaseSecurityProfile(
          databaseId: 'db-answered',
          biometricOfferAnswered: true,
        ),
      );

      final profile = await repository.getProfile('db-answered');

      expect(profile!.biometricOfferAnswered, isTrue);
      expect(profile.biometricProtectionEnabled, isFalse);
    });
  });
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.basePath);

  final String basePath;

  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;

  @override
  Future<String?> getApplicationSupportPath() async => basePath;
}

class _FakeSecurityLocalDataSource implements DatabaseSecurityLocalDataSource {
  final Map<String, Map<String, dynamic>> profiles = {};

  @override
  Future<Map<String, dynamic>?> getProfile(String databaseId) async =>
      profiles[databaseId];

  @override
  Future<void> saveProfile(
    String databaseId,
    Map<String, dynamic> profile,
  ) async {
    profiles[databaseId] = profile;
  }

  @override
  Future<void> removeProfile(String databaseId) async {
    profiles.remove(databaseId);
  }
}
