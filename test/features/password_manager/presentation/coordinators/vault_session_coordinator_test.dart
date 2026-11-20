import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:password_manager/features/password_manager/data/datasources/secure_data_source.dart';
import 'package:password_manager/features/password_manager/data/services/database_path_mutex.dart';
import 'package:password_manager/features/password_manager/data/services/database_rename_transaction.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_conflict.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/data/datasources/local_data_source.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_security_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/vault_session_coordinator.dart';

import 'fake_database_ports.dart';

import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:path/path.dart' as p;

void main() {
  group('VaultSessionCoordinator', () {
    late _FakeLocalDataSource localDataSource;
    late _FakeRegistryRepository registryRepository;
    late _FakeSecurityRepository securityRepository;
    late _FakeSyncRepository syncRepository;
    late _FakeSecureDataSource secureDataSource;
    late _FakeVaultKdbxService vaultKdbxService;
    late _FakeAppleAutofillV2Coordinator appleAutofillV2Coordinator;
    late SessionSecretHolder sessionSecretHolder;
    late VaultSessionCoordinator coordinator;

    setUp(() {
      localDataSource = _FakeLocalDataSource();
      registryRepository = _FakeRegistryRepository();
      securityRepository = _FakeSecurityRepository();
      syncRepository = _FakeSyncRepository();
      secureDataSource = _FakeSecureDataSource();
      vaultKdbxService = _FakeVaultKdbxService();
      appleAutofillV2Coordinator = _FakeAppleAutofillV2Coordinator();
      sessionSecretHolder = SessionSecretHolder();
      coordinator = VaultSessionCoordinator(
        databaseFileRepository: FakeDatabaseFileRepository(),
        databaseRenameTransaction: DatabaseRenameTransaction(
          mutex: DatabasePathMutex(),
          syncRepository: syncRepository,
        ),
        sessionSecretHolder: sessionSecretHolder,
        localDataSource: localDataSource,
        databaseRegistryRepository: registryRepository,
        databaseSecurityRepository: securityRepository,
        secureDataSource: secureDataSource,
        databaseSyncRepository: syncRepository,
        vaultKdbxService: vaultKdbxService,
        appleAutofillV2Coordinator: appleAutofillV2Coordinator,
      );
    });

    group('spec-011 FR-2 session secret lifetime', () {
      test('lockVault clears the session secret', () async {
        sessionSecretHolder.set('secret');

        await coordinator.lockVault(currentDatabasePath: '/tmp/vault.kdbx');

        expect(sessionSecretHolder.hasSecret, isFalse);
        expect(
          sessionSecretHolder.read,
          throwsA(isA<SessionSecretMissingError>()),
        );
      });

      test('changeDatabase clears the session secret', () async {
        sessionSecretHolder.set('secret');

        await coordinator.changeDatabase(
          currentDatabasePath: '/tmp/vault.kdbx',
        );

        expect(sessionSecretHolder.hasSecret, isFalse);
        expect(
          sessionSecretHolder.read,
          throwsA(isA<SessionSecretMissingError>()),
        );
      });

      test('handleAppDetached clears the session secret without touching the '
          'keystore', () {
        sessionSecretHolder.set('secret');
        secureDataSource.passwords['db-1'] = 'secret';

        coordinator.handleAppDetached();

        expect(sessionSecretHolder.hasSecret, isFalse);
        // The persistent biometric credential must survive termination
        // (spec-011 AC-3).
        expect(secureDataSource.passwords['db-1'], 'secret');
        expect(
          sessionSecretHolder.read,
          throwsA(isA<SessionSecretMissingError>()),
        );
      });

      test('a vault operation after clearing fails with the locked error, '
          'never an empty string', () {
        sessionSecretHolder.set('secret');
        sessionSecretHolder.clear();

        expect(
          sessionSecretHolder.read,
          throwsA(isA<SessionSecretMissingError>()),
        );
      });

      test('password change updates the session secret', () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'vault_session_secret_test_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final databasePath = '${tempDir.path}/vault.kdbx';
        await File(databasePath).writeAsBytes(const [1, 2, 3], flush: true);
        registryRepository.records = [_recordForTest('db-1', databasePath)];
        sessionSecretHolder.set('old-secret');

        await coordinator.updateDatabaseSettings(
          DatabaseSettingsUpdateRequest(
            currentDatabasePath: databasePath,
            fileName: 'vault.kdbx',
            keyFilePath: null,
            biometricProtectionEnabled: false,
            changePassword: true,
            inactivityLockTimeoutSeconds: null,
            currentPassword: 'old-secret',
            newPassword: 'new-secret',
          ),
        );

        expect(sessionSecretHolder.read(), 'new-secret');
      });
    });

    group('spec-011 Slice 2 keystore gating (FR-3/FR-5)', () {
      late Directory tempDir;
      late String databasePath;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('vault_gating_test_');
        addTearDown(() => tempDir.delete(recursive: true));
        databasePath = '${tempDir.path}/vault.kdbx';
        await File(databasePath).writeAsBytes(const [1, 2, 3], flush: true);
        registryRepository.records = [_recordForTest('db-1', databasePath)];
      });

      DatabaseSettingsUpdateRequest changePasswordRequest({
        required bool biometricProtectionEnabled,
      }) => DatabaseSettingsUpdateRequest(
        currentDatabasePath: databasePath,
        fileName: 'vault.kdbx',
        keyFilePath: null,
        biometricProtectionEnabled: biometricProtectionEnabled,
        changePassword: true,
        inactivityLockTimeoutSeconds: null,
        currentPassword: 'old-secret',
        newPassword: 'new-secret',
      );

      test('FR-3: master password change persists the new credential when '
          'biometric protection is enabled', () async {
        sessionSecretHolder.set('old-secret');

        await coordinator.updateDatabaseSettings(
          changePasswordRequest(biometricProtectionEnabled: true),
        );

        expect(secureDataSource.passwords, {'db-1': 'new-secret'});
        expect(sessionSecretHolder.read(), 'new-secret');
      });

      test('FR-3/FR-5: master password change with biometric protection '
          'disabled writes nothing and erases any stale entry', () async {
        sessionSecretHolder.set('old-secret');
        secureDataSource.passwords['db-1'] = 'stale-secret';

        await coordinator.updateDatabaseSettings(
          changePasswordRequest(biometricProtectionEnabled: false),
        );

        expect(secureDataSource.passwords, isEmpty);
        expect(sessionSecretHolder.read(), 'new-secret');
      });

      test('FR-5: disabling biometric protection in settings erases the '
          'stored credential in the same operation', () async {
        securityRepository.profiles['db-1'] = const DatabaseSecurityProfile(
          databaseId: 'db-1',
          biometricProtectionEnabled: true,
        );
        secureDataSource.passwords['db-1'] = 'secret';
        sessionSecretHolder.set('secret');

        await coordinator.updateDatabaseSettings(
          DatabaseSettingsUpdateRequest(
            currentDatabasePath: databasePath,
            fileName: 'vault.kdbx',
            keyFilePath: null,
            biometricProtectionEnabled: false,
            changePassword: false,
            inactivityLockTimeoutSeconds: null,
          ),
        );

        expect(
          securityRepository.profiles['db-1']!.biometricProtectionEnabled,
          isFalse,
        );
        expect(secureDataSource.passwords, isEmpty);
      });

      test('FR-3: enabling biometric protection in settings persists the '
          'current session secret', () async {
        sessionSecretHolder.set('secret');

        await coordinator.updateDatabaseSettings(
          DatabaseSettingsUpdateRequest(
            currentDatabasePath: databasePath,
            fileName: 'vault.kdbx',
            keyFilePath: null,
            biometricProtectionEnabled: true,
            changePassword: false,
            inactivityLockTimeoutSeconds: null,
          ),
        );

        expect(secureDataSource.passwords, {'db-1': 'secret'});
      });
    });

    test('spec 014 FR-3: renaming a database whose at-rest name is opaque '
        'renames it in the registry only, never on disk', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'vault_session_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      // The at-rest shape managed storage allocates: 32 hex, no extension.
      final opaqueFile = File(
        '${tempDir.path}/0123456789abcdef0123456789abcdef',
      );
      await opaqueFile.writeAsBytes(const [1, 2, 3], flush: true);

      registryRepository.records = [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: opaqueFile.path,
          displayName: 'Old name.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
      sessionSecretHolder.set('secret');

      final result = await coordinator.updateDatabaseSettings(
        DatabaseSettingsUpdateRequest(
          currentDatabasePath: opaqueFile.path,
          fileName: 'New name.kdbx',
          keyFilePath: null,
          biometricProtectionEnabled: false,
          changePassword: false,
          inactivityLockTimeoutSeconds: null,
        ),
      );

      expect(result.databasePath, opaqueFile.path);
      expect(opaqueFile.existsSync(), isTrue);
      expect(
        Directory(tempDir.path).listSync().map((e) => p.basename(e.path)),
        ['0123456789abcdef0123456789abcdef'],
        reason: 'the human-readable name must never reach the filesystem',
      );
      expect(syncRepository.movedFrom, isNull);
      expect(
        registryRepository.records.single.displayName,
        'New name.kdbx',
        reason: 'the new name lives in the encrypted registry',
      );
    });

    test(
      'updateDatabaseSettings renames database and updates mapping/profile',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'vault_session_test_',
        );
        addTearDown(() => tempDir.delete(recursive: true));

        final oldFile = File('${tempDir.path}/old.kdbx');
        await oldFile.writeAsBytes(const [1, 2, 3], flush: true);
        final keyFile = File('${tempDir.path}/main.key');
        await keyFile.writeAsBytes(const [4, 5, 6], flush: true);

        registryRepository.records = [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: oldFile.path,
            displayName: 'old.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ];
        sessionSecretHolder.set('secret');

        final result = await coordinator.updateDatabaseSettings(
          DatabaseSettingsUpdateRequest(
            currentDatabasePath: oldFile.path,
            fileName: 'renamed.kdbx',
            keyFilePath: keyFile.path,
            biometricProtectionEnabled: true,
            changePassword: false,
            inactivityLockTimeoutSeconds: null,
          ),
        );

        expect(result.databasePath.endsWith('renamed.kdbx'), isTrue);
        expect(File(result.databasePath).existsSync(), isTrue);
        expect(oldFile.existsSync(), isFalse);
        expect(syncRepository.movedFrom, oldFile.path);
        expect(syncRepository.movedTo, result.databasePath);

        final profile = securityRepository.profiles['db-1'];
        expect(profile, isNotNull);
        expect(profile!.keyFilePath, keyFile.path);
        expect(profile.biometricProtectionEnabled, isTrue);
        expect(vaultKdbxService.currentKeyFilePath, isNull);
        expect(vaultKdbxService.newKeyFilePath, keyFile.path);
        expect(vaultKdbxService.currentPassword, 'secret');
        expect(vaultKdbxService.newPassword, 'secret');
        expect(vaultKdbxService.finalizeCount, 1);
        // spec-011 FR-3: biometric protection enabled ⇒ the credential is
        // persisted under the database's own key.
        expect(secureDataSource.passwords, {'db-1': 'secret'});
      },
    );

    test('updateDatabaseSettings does not persist profile paths when password change fails', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'vault_session_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final oldFile = File('${tempDir.path}/old.kdbx');
      await oldFile.writeAsBytes(const [1, 2, 3], flush: true);
      final keyFile = File('${tempDir.path}/main.key');
      await keyFile.writeAsBytes(const [4, 5, 6], flush: true);

      registryRepository.records = [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: oldFile.path,
          displayName: 'old.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
      vaultKdbxService.shouldThrowOnChangeMasterPassword = true;

      await expectLater(
        coordinator.updateDatabaseSettings(
          DatabaseSettingsUpdateRequest(
            currentDatabasePath: oldFile.path,
            fileName: 'renamed.kdbx',
            keyFilePath: keyFile.path,
            biometricProtectionEnabled: true,
            changePassword: true,
            inactivityLockTimeoutSeconds: null,
            currentPassword: 'old-secret',
            newPassword: 'new-secret',
          ),
        ),
        throwsA(isA<Exception>()),
      );

      // `p.join`, not string interpolation: production builds the renamed
      // path with `p.join`, so on Windows it produces a `\` separator while
      // the interpolated literal kept a `/`. The rollback pair being
      // asserted (rename forward, then rename back) is unchanged.
      final renamedPath = p.join(tempDir.path, 'renamed.kdbx');
      expect(oldFile.existsSync(), isTrue);
      expect(File(renamedPath).existsSync(), isFalse);
      expect(syncRepository.moves, [
        (oldFile.path, renamedPath),
        (renamedPath, oldFile.path),
      ]);
      expect(securityRepository.profiles['db-1'], isNull);
      expect(secureDataSource.passwords, isEmpty);
    });

    test('mapping failure rolls database rename back', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'vault_mapping_rollback_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final oldFile = File('${tempDir.path}/old.kdbx');
      await oldFile.writeAsBytes(const [1]);
      registryRepository.records = [_recordForTest('db-1', oldFile.path)];
      sessionSecretHolder.set('secret');
      syncRepository.failNextMove = true;

      await expectLater(
        coordinator.updateDatabaseSettings(
          DatabaseSettingsUpdateRequest(
            currentDatabasePath: oldFile.path,
            fileName: 'renamed.kdbx',
            keyFilePath: null,
            biometricProtectionEnabled: true,
            changePassword: false,
            inactivityLockTimeoutSeconds: null,
          ),
        ),
        throwsException,
      );

      expect(await oldFile.exists(), isTrue);
      expect(await File('${tempDir.path}/renamed.kdbx').exists(), isFalse);
      expect(registryRepository.records.single.canonicalPath, oldFile.path);
      expect(vaultKdbxService.currentPassword, isNull);
    });

    test('does not remove the last unlock credential', () async {
      const databasePath = '/tmp/key-only.kdbx';
      registryRepository.records = [
        DatabaseRecord(
          databaseId: 'db-key-only',
          canonicalPath: databasePath,
          displayName: 'key-only.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
      // spec 014 FR-8: the security profile is the only key-file source.
      securityRepository.profiles['db-key-only'] =
          const DatabaseSecurityProfile(
            databaseId: 'db-key-only',
            keyFilePath: '/tmp/current.key',
          );
      sessionSecretHolder.set('');

      await expectLater(
        coordinator.updateDatabaseSettings(
          const DatabaseSettingsUpdateRequest(
            currentDatabasePath: databasePath,
            fileName: 'key-only.kdbx',
            keyFilePath: null,
            biometricProtectionEnabled: false,
            changePassword: false,
            inactivityLockTimeoutSeconds: null,
          ),
        ),
        throwsException,
      );

      expect(vaultKdbxService.currentPassword, isNull);
      expect(
        securityRepository.profiles['db-key-only']!.keyFilePath,
        '/tmp/current.key',
      );
    });

    test(
      'profile failure rolls back credentials and pending key metadata',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'vault_session_rollback_test_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final databasePath = '${tempDir.path}/vault.kdbx';
        final currentKey = '${tempDir.path}/current.key';
        final pendingKey = '${tempDir.path}/pending.key';
        await File(databasePath).writeAsBytes(const [1]);
        await File(currentKey).writeAsBytes(const [2]);
        await File(pendingKey).writeAsBytes(const [3]);
        registryRepository.records = [_recordForTest('db-1', databasePath)];
        securityRepository.profiles['db-1'] = DatabaseSecurityProfile(
          databaseId: 'db-1',
          keyFilePath: currentKey,
          // spec-011 FR-3: rollback must re-establish the keystore entry
          // because this profile had biometric protection enabled.
          biometricProtectionEnabled: true,
        );
        sessionSecretHolder.set('old-secret');
        secureDataSource.passwords['db-1'] = 'old-secret';
        securityRepository.failNextSave = true;

        await expectLater(
          coordinator.updateDatabaseSettings(
            DatabaseSettingsUpdateRequest(
              currentDatabasePath: databasePath,
              fileName: 'vault.kdbx',
              keyFilePath: pendingKey,
              biometricProtectionEnabled: true,
              changePassword: true,
              inactivityLockTimeoutSeconds: 60,
              currentPassword: 'old-secret',
              newPassword: 'new-secret',
            ),
          ),
          throwsException,
        );

        expect(vaultKdbxService.rollbackCount, 1);
        expect(secureDataSource.passwords, {'db-1': 'old-secret'});
        expect(sessionSecretHolder.read(), 'old-secret');
        expect(securityRepository.profiles['db-1']!.keyFilePath, currentKey);
        expect(await File(pendingKey).exists(), isTrue);
      },
    );

    test('secure storage failure rolls back credential transaction', () async {
      const databasePath = '/tmp/vault.kdbx';
      registryRepository.records = [_recordForTest('db-1', databasePath)];
      sessionSecretHolder.set('old-secret');
      secureDataSource.failNextSave = true;

      await expectLater(
        coordinator.updateDatabaseSettings(
          const DatabaseSettingsUpdateRequest(
            currentDatabasePath: databasePath,
            fileName: 'vault.kdbx',
            keyFilePath: null,
            biometricProtectionEnabled: true,
            changePassword: true,
            inactivityLockTimeoutSeconds: null,
            currentPassword: 'old-secret',
            newPassword: 'new-secret',
          ),
        ),
        throwsException,
      );

      expect(vaultKdbxService.rollbackCount, 1);
      // No profile existed before, so the restore leaves no credential
      // behind and re-establishes the old session secret in memory.
      expect(secureDataSource.passwords, isEmpty);
      expect(sessionSecretHolder.read(), 'old-secret');
    });

    test('profile failure reopens with old credentials, not new', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'vault_session_real_rollback_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final databasePath = '${tempDir.path}/vault.kdbx';
      await _createTestDatabase(databasePath, 'old-secret');
      registryRepository.records = [_recordForTest('db-1', databasePath)];
      sessionSecretHolder.set('old-secret');
      securityRepository.failNextSave = true;
      final realService = VaultKdbxService();
      coordinator = VaultSessionCoordinator(
        databaseFileRepository: FakeDatabaseFileRepository(),
        databaseRenameTransaction: DatabaseRenameTransaction(
          mutex: DatabasePathMutex(),
          syncRepository: syncRepository,
        ),
        sessionSecretHolder: sessionSecretHolder,
        localDataSource: localDataSource,
        databaseRegistryRepository: registryRepository,
        databaseSecurityRepository: securityRepository,
        secureDataSource: secureDataSource,
        databaseSyncRepository: syncRepository,
        vaultKdbxService: realService,
        appleAutofillV2Coordinator: appleAutofillV2Coordinator,
      );

      await expectLater(
        coordinator.updateDatabaseSettings(
          DatabaseSettingsUpdateRequest(
            currentDatabasePath: databasePath,
            fileName: 'vault.kdbx',
            keyFilePath: null,
            biometricProtectionEnabled: true,
            changePassword: true,
            inactivityLockTimeoutSeconds: null,
            currentPassword: 'old-secret',
            newPassword: 'new-secret',
          ),
        ),
        throwsException,
      );

      await expectLater(
        realService.loadVault(
          databasePath: databasePath,
          password: 'old-secret',
        ),
        completes,
      );
      await expectLater(
        realService.loadVault(
          databasePath: databasePath,
          password: 'new-secret',
        ),
        throwsA(anything),
      );
    });

    // spec-006 T3 / constitution VII: master-password changes write a
    // dated local copy before the re-key, kept (never auto-deleted) —
    // distinct from `beginCredentialChange`'s own transient rollback
    // `.bak`, which IS deleted on success (see the `finalizeCount`
    // assertion in the first test above).
    test('updateDatabaseSettings writes a dated pre-rekey backup before '
        'changing the master password', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'vault_session_backup_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final databasePath = '${tempDir.path}/vault.kdbx';
      final originalBytes = await _createTestDatabase(
        databasePath,
        'old-secret',
      );
      registryRepository.records = [_recordForTest('db-1', databasePath)];
      sessionSecretHolder.set('old-secret');
      final realService = VaultKdbxService();
      coordinator = VaultSessionCoordinator(
        databaseFileRepository: FakeDatabaseFileRepository(),
        databaseRenameTransaction: DatabaseRenameTransaction(
          mutex: DatabasePathMutex(),
          syncRepository: syncRepository,
        ),
        sessionSecretHolder: sessionSecretHolder,
        localDataSource: localDataSource,
        databaseRegistryRepository: registryRepository,
        databaseSecurityRepository: securityRepository,
        secureDataSource: secureDataSource,
        databaseSyncRepository: syncRepository,
        vaultKdbxService: realService,
        appleAutofillV2Coordinator: appleAutofillV2Coordinator,
      );

      final result = await coordinator.updateDatabaseSettings(
        DatabaseSettingsUpdateRequest(
          currentDatabasePath: databasePath,
          fileName: 'vault.kdbx',
          keyFilePath: null,
          biometricProtectionEnabled: false,
          changePassword: true,
          inactivityLockTimeoutSeconds: null,
          currentPassword: 'old-secret',
          newPassword: 'new-secret',
        ),
      );
      expect(result.passwordChanged, isTrue);

      // Exactly one dated backup, named
      // `vault.<yyyyMMdd-HHmmss-ffffff>.pre-rekey.kdbx`, sitting next to
      // the (now re-keyed) database — and it still opens with the OLD
      // password, proving it's the pre-change file, not a copy of the
      // new one.
      final backups = tempDir
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                file.path.contains('.pre-rekey.kdbx') &&
                file.path.contains('vault.'),
          )
          .toList();
      expect(backups, hasLength(1));
      expect(
        RegExp(r'vault\.\d{8}-\d{6}-\d{6}\.pre-rekey\.kdbx$')
            .hasMatch(backups.single.path),
        isTrue,
        reason: 'Backup file name: ${backups.single.path}',
      );
      expect(
        await backups.single.readAsBytes(),
        originalBytes,
        reason: 'The backup must be a copy of the pre-rekey bytes.',
      );

      // The re-keyed database now opens with the NEW password (the
      // backup is a separate, additional file — it does not replace the
      // normal atomic-rekey behaviour already covered above).
      await expectLater(
        realService.loadVault(
          databasePath: databasePath,
          password: 'new-secret',
        ),
        completes,
      );
    });

    test('updateDatabaseSettings does not write a pre-rekey backup when '
        'neither the password nor the key file changes', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'vault_session_no_backup_test_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final databasePath = '${tempDir.path}/vault.kdbx';
      await File(databasePath).writeAsBytes(const [1, 2, 3]);
      registryRepository.records = [_recordForTest('db-1', databasePath)];
      sessionSecretHolder.set('secret');

      await coordinator.updateDatabaseSettings(
        DatabaseSettingsUpdateRequest(
          currentDatabasePath: databasePath,
          fileName: 'vault.kdbx',
          keyFilePath: null,
          biometricProtectionEnabled: true,
          changePassword: false,
          inactivityLockTimeoutSeconds: 120,
        ),
      );

      final backups = tempDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('.pre-rekey.'))
          .toList();
      expect(backups, isEmpty);
    });

    test('persisted key path is read from the database profile', () async {
      final shared = p.join(Directory.systemTemp.path, 'shared.key');
      registryRepository.records = [
        _recordForTest('db-1', '/tmp/a.kdbx'),
        _recordForTest('db-2', '/tmp/b.kdbx'),
      ];
      securityRepository.profiles['db-1'] = DatabaseSecurityProfile(
        databaseId: 'db-1',
        keyFilePath: shared,
      );
      securityRepository.profiles['db-2'] = DatabaseSecurityProfile(
        databaseId: 'db-2',
        keyFilePath: shared,
      );

      expect(await coordinator.getPersistedKeyFilePath('/tmp/a.kdbx'), shared);
    });

    test('changeDatabase clears the selected key file and active database '
        'but keeps the stored biometric credential (spec-011)', () async {
      secureDataSource.passwords['db-1'] = 'secret';
      sessionSecretHolder.set('secret');
      registryRepository.activeId = 'db-1';

      await coordinator.changeDatabase(currentDatabasePath: '/tmp/a.kdbx');

      expect(secureDataSource.passwords['db-1'], 'secret');
      expect(sessionSecretHolder.hasSecret, isFalse);
      expect(registryRepository.activeId, isNull);
      expect(appleAutofillV2Coordinator.clearCallCount, 1);
    });

    test('lockVault clears Apple autofill credentials but keeps the stored '
        'biometric credential (spec-011)', () async {
      secureDataSource.passwords['db-1'] = 'secret';
      sessionSecretHolder.set('secret');

      await coordinator.lockVault(currentDatabasePath: '/tmp/a.kdbx');

      expect(secureDataSource.passwords['db-1'], 'secret');
      expect(sessionSecretHolder.hasSecret, isFalse);
      expect(appleAutofillV2Coordinator.clearCallCount, 1);
    });

    test('getInactivityLockTimeoutForPath returns correct timeout when database is registered', () async {
      const databasePath = '/tmp/test.kdbx';
      registryRepository.records = [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: databasePath,
          displayName: 'test.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
      securityRepository.profiles['db-1'] = DatabaseSecurityProfile(
        databaseId: 'db-1',
        inactivityLockTimeoutSeconds: 300,
      );

      final result = await coordinator.getInactivityLockTimeoutForPath(
        databasePath: databasePath,
      );

      expect(result, 300);
    });

    test('getInactivityLockTimeoutForPath returns null when database path is empty', () async {
      registryRepository.records = [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: '/tmp/test.kdbx',
          displayName: 'test.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      final result = await coordinator.getInactivityLockTimeoutForPath(
        databasePath: '',
      );

      expect(result, isNull);
    });
  });
}

DatabaseRecord _recordForTest(String id, String path) => DatabaseRecord(
  databaseId: id,
  canonicalPath: path,
  displayName: path.split('/').last,
  sourceType: DatabaseSourceType.local,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Future<Uint8List> _createTestDatabase(String path, String password) async {
  final file = KdbxFormat().create(
    Credentials.composite(ProtectedValue.fromString(password), null),
    'Test',
  );
  final bytes = await file.save();
  await File(path).writeAsBytes(bytes, flush: true);
  return bytes;
}

class _FakeLocalDataSource implements LocalDataSource {
  String? selectedKeyFilePath;

  @override
  Future<bool> getAutofillPromptSeen() async => false;

  @override
  Future<void> setAutofillPromptSeen(bool seen) async {}
}

class _FakeRegistryRepository implements DatabaseRegistryRepository {
  List<DatabaseRecord> records = [];
  String? activeId;

  @override
  Future<DatabaseRecord?> findByHash(String fileHash) async => null;

  @override
  Future<DatabaseRecord?> findBySource({
    required DatabaseSourceType sourceType,
    required String sourceRef,
  }) async => null;

  @override
  Future<String?> getActive() async => activeId;

  @override
  Future<DatabaseRecord?> getById(String databaseId) async {
    return records
        .where((record) => record.databaseId == databaseId)
        .firstOrNull;
  }

  @override
  Future<List<DatabaseRecord>> list() async => records;

  @override
  Future<void> remove(String databaseId) async {
    records = records
        .where((record) => record.databaseId != databaseId)
        .toList();
  }

  @override
  Future<void> setActive(String? databaseId) async {
    activeId = databaseId;
  }

  @override
  Future<void> upsert(DatabaseRecord record) async {
    records = [
      ...records.where((item) => item.databaseId != record.databaseId),
      record,
    ];
  }
}

class _FakeSecurityRepository implements DatabaseSecurityRepository {
  final Map<String, DatabaseSecurityProfile> profiles = {};
  bool failNextSave = false;

  @override
  Future<DatabaseSecurityProfile?> getProfile(String databaseId) async {
    return profiles[databaseId];
  }

  @override
  Future<void> removeProfile(String databaseId) async {
    profiles.remove(databaseId);
  }

  @override
  Future<void> saveProfile(DatabaseSecurityProfile profile) async {
    if (failNextSave) {
      failNextSave = false;
      throw Exception('Profile write failed.');
    }
    profiles[profile.databaseId] = profile;
  }
}

class _FakeSecureDataSource implements SecureDataSource {
  final Map<String, String> metadataEntries = {};

  @override
  Future<String?> readMetadataKey() async =>
      metadataEntries['METADATA_ENCRYPTION_KEY'];

  @override
  Future<String> createMetadataKey() async {
    // Deterministic non-secret test key, built at runtime so secret
    // scanners never see a base64-looking literal.
    final key = base64Encode(List<int>.generate(32, (i) => i));
    metadataEntries['METADATA_ENCRYPTION_KEY'] = key;
    return key;
  }

  @override
  Future<void> deleteLegacyMasterPassword() async {}

  /// spec-011 FR-4: one entry per database id.
  final Map<String, String> passwords = {};
  bool failNextSave = false;

  @override
  Future<void> clearMasterPassword(String databaseId) async {
    passwords.remove(databaseId);
  }

  @override
  Future<String?> getMasterPassword(String databaseId) async =>
      passwords[databaseId];

  @override
  Future<void> saveMasterPassword(String databaseId, String password) async {
    if (failNextSave) {
      failNextSave = false;
      throw Exception('Secure storage write failed.');
    }
    passwords[databaseId] = password;
  }
}

class _FakeVaultKdbxService extends VaultKdbxService {
  bool shouldThrowOnChangeMasterPassword = false;
  String? currentKeyFilePath;
  String? newKeyFilePath;
  String? currentPassword;
  String? newPassword;
  int rollbackCount = 0;
  int finalizeCount = 0;

  @override
  Future<KdbxCredentialChange> beginCredentialChange({
    required String databasePath,
    required String currentPassword,
    String? currentKeyFilePath,
    required String newPassword,
    String? newKeyFilePath,
  }) async {
    if (shouldThrowOnChangeMasterPassword) {
      throw Exception('Unable to change password.');
    }
    this.currentKeyFilePath = currentKeyFilePath;
    this.newKeyFilePath = newKeyFilePath;
    this.currentPassword = currentPassword;
    this.newPassword = newPassword;
    return KdbxCredentialChange(
      databasePath: databasePath,
      backupPath: '$databasePath.test-backup',
    );
  }

  @override
  Future<void> finalizeCredentialChange(KdbxCredentialChange change) async {
    finalizeCount += 1;
  }

  @override
  Future<void> rollbackCredentialChange(KdbxCredentialChange change) async {
    rollbackCount += 1;
  }
}

class _FakeAppleAutofillV2Coordinator
    implements AppleAutofillV2CoordinatorContract {
  int clearCallCount = 0;
  int publishCallCount = 0;

  @override
  Future<void> clearCredentials({String? databasePath}) async {
    clearCallCount += 1;
  }

  @override
  Future<void> clearPendingAssociations({List<String>? ids}) async {}

  @override
  Future<void> publishVault({
    required String databasePath,
    required List<VaultEntry> entries,
  }) async {
    publishCallCount += 1;
  }

  @override
  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  }) async {
    return const [];
  }
}

class _FakeSyncRepository implements DatabaseSyncRepository {
  String? movedFrom;
  String? movedTo;
  final List<(String, String)> moves = [];
  bool failNextMove = false;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<Uint8List> downloadRemoteFile(String fileId) async {
    throw UnimplementedError();
  }

  @override
  Future<DatabaseSyncMapping?> getMapping(String databasePath) async => null;

  @override
  Future<List<DatabaseSyncMapping>> getAllMappings() async => const [];

  @override
  Future<bool> isConnected() async => false;

  @override
  Future<DatabaseSyncMapping> linkDatabaseToRemote({
    required String databasePath,
    String? remoteFileId,
    String? remoteFileName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) async {
    return const [];
  }

  @override
  Future<DatabaseSyncMappingPathMove> moveMappingPath({
    required String fromDatabasePath,
    required String toDatabasePath,
  }) async {
    if (failNextMove) {
      failNextMove = false;
      throw Exception('Mapping move failed.');
    }
    movedFrom = fromDatabasePath;
    movedTo = toDatabasePath;
    moves.add((fromDatabasePath, toDatabasePath));
    return DatabaseSyncMappingPathMove(
      fromDatabasePath: fromDatabasePath,
      toDatabasePath: toDatabasePath,
      sourceBefore: null,
      destinationBefore: null,
    );
  }

  @override
  Future<void> restoreMappingPathMove(DatabaseSyncMappingPathMove move) async {}

  @override
  Future<void> removeMapping(String databasePath) async {}

  @override
  Future<void> setAutoSync(String databasePath, bool enabled) async {}

  @override
  Future<SyncNowResult> syncNow(
    String databasePath, {
    SyncConflictResolution? resolution,
  }) async {
    return const SyncNowSuccess();
  }

  @override
  Future<StorageAccountSummary> getConnectedAccount() async =>
      const StorageAccountSummary(displayLabel: 'Google Drive account');
}
