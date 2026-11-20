import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/local_data_source.dart';
import 'package:password_manager/features/password_manager/data/datasources/secure_data_source.dart';
import 'package:password_manager/features/password_manager/data/repositories/database_session_repository_impl.dart';
import 'package:password_manager/features/password_manager/data/services/database_import_service.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/errors/database_access_failure.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/models/database_dedup_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_selection_item.dart';
import 'package:password_manager/features/password_manager/domain/models/cloud_storage_error.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_conflict.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_security_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/get_active_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/resolve_database_duplicate_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/unlock_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/validate_database_usecase.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_event.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:path/path.dart' as p;

List<String> _paths(List<DatabaseSelectionItem> items) =>
    items.map((item) => item.canonicalPath).toList(growable: false);

class _StubUnlockDatabaseUseCase extends UnlockDatabaseUseCase {
  Object? error;
  int calls = 0;
  String? lastPassword;

  @override
  Future<void> call({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async {
    calls += 1;
    lastPassword = password;
    final pending = error;
    if (pending != null) {
      throw pending;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseSessionCoordinator', () {
    late Directory tempDir;
    late _FakeLocalDataSource localDataSource;
    late _FakeRegistryRepository registryRepository;
    late _FakeSecurityRepository securityRepository;
    late _FakeSyncRepository syncRepository;
    late _FakeSecureDataSource secureDataSource;
    late _FakeAppleAutofillV2Coordinator appleAutofillV2Coordinator;
    late DatabaseImportService databaseImportService;
    late DatabaseSessionCoordinator coordinator;
    late SessionSecretHolder sessionSecretHolder;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('db_session_test_');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);

      localDataSource = _FakeLocalDataSource();
      registryRepository = _FakeRegistryRepository();
      securityRepository = _FakeSecurityRepository();
      syncRepository = _FakeSyncRepository();
      secureDataSource = _FakeSecureDataSource();
      appleAutofillV2Coordinator = _FakeAppleAutofillV2Coordinator();
      sessionSecretHolder = SessionSecretHolder();
      databaseImportService = DatabaseImportService(
        validateDatabaseUseCase: ValidateDatabaseUseCase(),
      );

      coordinator = DatabaseSessionCoordinator(
        sessionSecretHolder: sessionSecretHolder,
        databaseFileRepository: databaseImportService,
        databaseSessionRepository: DatabaseSessionRepositoryImpl(
          localDataSource: localDataSource,
          secureDataSource: secureDataSource,
        ),
        databaseRegistryRepository: registryRepository,
        databaseSecurityRepository: securityRepository,
        getActiveDatabaseUseCase: GetActiveDatabaseUseCase(registryRepository),
        resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
          registryRepository,
          syncRepository,
        ),
        databaseSyncRepository: syncRepository,
        linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
        unlockDatabaseUseCase: UnlockDatabaseUseCase(),
        createDatabaseUseCase: CreateDatabaseUseCase(
          databaseFileRepository: databaseImportService,
        ),
        appleAutofillV2Coordinator: appleAutofillV2Coordinator,
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    group('spec-011 session secret (FR-1/FR-2)', () {
      late _StubUnlockDatabaseUseCase unlockUseCase;
      late DatabaseSessionCoordinator stubbedCoordinator;

      setUp(() {
        unlockUseCase = _StubUnlockDatabaseUseCase();
        stubbedCoordinator = DatabaseSessionCoordinator(
          sessionSecretHolder: sessionSecretHolder,
          databaseFileRepository: databaseImportService,
          databaseSessionRepository: DatabaseSessionRepositoryImpl(
            localDataSource: localDataSource,
            secureDataSource: secureDataSource,
          ),
          databaseRegistryRepository: registryRepository,
          databaseSecurityRepository: securityRepository,
          getActiveDatabaseUseCase: GetActiveDatabaseUseCase(
            registryRepository,
          ),
          resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
            registryRepository,
            syncRepository,
          ),
          databaseSyncRepository: syncRepository,
          linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
          unlockDatabaseUseCase: unlockUseCase,
          createDatabaseUseCase: CreateDatabaseUseCase(
            databaseFileRepository: databaseImportService,
          ),
          appleAutofillV2Coordinator: appleAutofillV2Coordinator,
        );
      });

      test('unlockWithManualCredentials populates the holder', () async {
        await stubbedCoordinator.unlockWithManualCredentials(
          databasePath: '/tmp/db.kdbx',
          password: 'pw',
          keyFilePath: null,
        );

        expect(sessionSecretHolder.read(), 'pw');
      });

      test('unlockWithManualCredentials failure clears the holder', () async {
        sessionSecretHolder.set('stale');
        unlockUseCase.error = const InvalidCredentialsFailure();

        await expectLater(
          stubbedCoordinator.unlockWithManualCredentials(
            databasePath: '/tmp/db.kdbx',
            password: 'wrong',
            keyFilePath: null,
          ),
          throwsA(isA<InvalidCredentialsFailure>()),
        );

        expect(sessionSecretHolder.hasSecret, isFalse);
      });

      test(
        'unlockWithStoredCredentials with no stored password and no key '
        'file fails with the locked error without attempting an unlock',
        () async {
          registryRepository.records = [
            _record(id: 'db-test', path: '/tmp/db.kdbx'),
          ];

          await expectLater(
            stubbedCoordinator.unlockWithStoredCredentials(
              databasePath: '/tmp/db.kdbx',
              keyFilePath: null,
            ),
            throwsA(isA<InvalidCredentialsFailure>()),
          );

          // The removed `?? ''` fallback must not resurface as an
          // empty-password unlock attempt.
          expect(unlockUseCase.calls, 0);
          expect(sessionSecretHolder.hasSecret, isFalse);
        },
      );

      test('unlockWithStoredCredentials with no stored password but a key '
          'file still unlocks with an empty password (key-file-only '
          'vault)', () async {
        registryRepository.records = [
          _record(id: 'db-test', path: '/tmp/db.kdbx'),
        ];
        final keyFile = File('${tempDir.path}/vault.key');
        await keyFile.writeAsBytes(const [1, 2, 3], flush: true);

        await stubbedCoordinator.unlockWithStoredCredentials(
          databasePath: '/tmp/db.kdbx',
          keyFilePath: keyFile.path,
        );

        // The FR-2 guard must not fire when a key file is part of the
        // unlock: '' is the deliberate composite credential here.
        expect(unlockUseCase.calls, 1);
        expect(unlockUseCase.lastPassword, '');
        expect(sessionSecretHolder.read(), '');
      });

      test('unlockWithStoredCredentials success populates the holder from the '
          'stored per-database password', () async {
        registryRepository.records = [
          _record(id: 'db-test', path: '/tmp/db.kdbx'),
        ];
        secureDataSource.passwords['db-test'] = 'stored-pw';

        await stubbedCoordinator.unlockWithStoredCredentials(
          databasePath: '/tmp/db.kdbx',
          keyFilePath: null,
        );

        expect(unlockUseCase.lastPassword, 'stored-pw');
        expect(sessionSecretHolder.read(), 'stored-pw');
        // The persistent biometric credential is untouched by a read.
        expect(secureDataSource.passwords['db-test'], 'stored-pw');
      });

      test('unlockWithStoredCredentials failure clears the holder', () async {
        sessionSecretHolder.set('stale');
        registryRepository.records = [
          _record(id: 'db-test', path: '/tmp/db.kdbx'),
        ];
        secureDataSource.passwords['db-test'] = 'stored-pw';
        unlockUseCase.error = const InvalidCredentialsFailure();

        await expectLater(
          stubbedCoordinator.unlockWithStoredCredentials(
            databasePath: '/tmp/db.kdbx',
            keyFilePath: null,
          ),
          throwsA(isA<InvalidCredentialsFailure>()),
        );

        expect(sessionSecretHolder.hasSecret, isFalse);
      });
    });

    group('spec-011 Slice 2 keystore gating (FR-3/FR-4/FR-5)', () {
      late _StubUnlockDatabaseUseCase unlockUseCase;
      late DatabaseSessionCoordinator gatedCoordinator;

      DatabaseSessionCoordinator buildCoordinator({
        CreateDatabaseUseCase? createDatabaseUseCase,
      }) {
        return DatabaseSessionCoordinator(
          sessionSecretHolder: sessionSecretHolder,
          databaseFileRepository: databaseImportService,
          databaseSessionRepository: DatabaseSessionRepositoryImpl(
            localDataSource: localDataSource,
            secureDataSource: secureDataSource,
          ),
          databaseRegistryRepository: registryRepository,
          databaseSecurityRepository: securityRepository,
          getActiveDatabaseUseCase: GetActiveDatabaseUseCase(
            registryRepository,
          ),
          resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
            registryRepository,
            syncRepository,
          ),
          databaseSyncRepository: syncRepository,
          linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
          unlockDatabaseUseCase: unlockUseCase,
          createDatabaseUseCase:
              createDatabaseUseCase ??
              CreateDatabaseUseCase(
                databaseFileRepository: databaseImportService,
              ),
          appleAutofillV2Coordinator: appleAutofillV2Coordinator,
        );
      }

      setUp(() {
        unlockUseCase = _StubUnlockDatabaseUseCase();
        gatedCoordinator = buildCoordinator();
      });

      test('FR-3: manual unlock persists the credential under the database '
          'key when biometric protection is enabled', () async {
        registryRepository.records = [
          _record(id: 'db-on', path: '/tmp/db.kdbx'),
        ];
        securityRepository.profiles['db-on'] = const DatabaseSecurityProfile(
          databaseId: 'db-on',
          biometricProtectionEnabled: true,
        );

        await gatedCoordinator.unlockWithManualCredentials(
          databasePath: '/tmp/db.kdbx',
          password: 'pw',
          keyFilePath: null,
        );

        expect(secureDataSource.passwords, {'db-on': 'pw'});
      });

      test('FR-3: manual unlock writes nothing when biometric protection is '
          'disabled', () async {
        registryRepository.records = [
          _record(id: 'db-off', path: '/tmp/db.kdbx'),
        ];
        securityRepository.profiles['db-off'] = const DatabaseSecurityProfile(
          databaseId: 'db-off',
          biometricProtectionEnabled: false,
        );

        await gatedCoordinator.unlockWithManualCredentials(
          databasePath: '/tmp/db.kdbx',
          password: 'pw',
          keyFilePath: null,
        );

        expect(secureDataSource.passwords, isEmpty);
        expect(sessionSecretHolder.read(), 'pw');
      });

      test('FR-3/FR-7: manual unlock of a database without a security '
          'profile writes nothing (absent flag is not consent)', () async {
        registryRepository.records = [
          _record(id: 'db-none', path: '/tmp/db.kdbx'),
        ];

        await gatedCoordinator.unlockWithManualCredentials(
          databasePath: '/tmp/db.kdbx',
          password: 'pw',
          keyFilePath: null,
        );

        expect(secureDataSource.passwords, isEmpty);
        expect(
          securityRepository.profiles.values.single.biometricProtectionEnabled,
          isFalse,
          reason: 'the implicitly created profile must default to false',
        );
      });

      test('FR-3: createNewDatabase persists the credential only when created '
          'with biometric protection enabled', () async {
        final createdPath = '${tempDir.path}/databases/created.kdbx';
        final creatingCoordinator = buildCoordinator(
          createDatabaseUseCase: _StubCreateDatabaseUseCase(
            databaseFileRepository: databaseImportService,
            databasePath: createdPath,
          ),
        );

        final result = await creatingCoordinator.createNewDatabase(
          databaseFileName: 'created.kdbx',
          password: 'new-pw',
          biometricProtectionEnabled: true,
          generateKeyFile: false,
        );

        expect(result.status, DatabaseSessionStatus.success);
        final createdId = registryRepository.records
            .firstWhere((record) => record.canonicalPath == createdPath)
            .databaseId;
        expect(secureDataSource.passwords, {createdId: 'new-pw'});
        expect(sessionSecretHolder.read(), 'new-pw');
      });

      test('FR-3: createNewDatabase writes nothing when biometric protection '
          'is off at creation', () async {
        final createdPath = '${tempDir.path}/databases/created.kdbx';
        final creatingCoordinator = buildCoordinator(
          createDatabaseUseCase: _StubCreateDatabaseUseCase(
            databaseFileRepository: databaseImportService,
            databasePath: createdPath,
          ),
        );

        final result = await creatingCoordinator.createNewDatabase(
          databaseFileName: 'created.kdbx',
          password: 'new-pw',
          biometricProtectionEnabled: false,
          generateKeyFile: false,
        );

        expect(result.status, DatabaseSessionStatus.success);
        expect(secureDataSource.passwords, isEmpty);
        expect(sessionSecretHolder.read(), 'new-pw');
      });

      test('FR-3: import rollback restores the session secret without ever '
          'touching the keystore', () async {
        final incomingFile = File('${tempDir.path}/incoming/new.kdbx');
        await incomingFile.parent.create(recursive: true);
        await incomingFile.writeAsBytes(<int>[
          0x03,
          0xD9,
          0xA2,
          0x9A,
          0x67,
          0xFB,
          0x4B,
          0xB5,
          ...utf8.encode('rollback-fixture'),
        ], flush: true);
        sessionSecretHolder.set('original-secret');
        secureDataSource.passwords['db-a'] = 'a-secret';
        registryRepository.failNextUpsert = true;

        await expectLater(
          gatedCoordinator.selectExistingDatabase(
            fileName: 'new.kdbx',
            selectedPath: incomingFile.path,
          ),
          throwsException,
        );

        // Both flag states are covered by the same invariant: the commit
        // transaction never reads or writes the keystore, so rollback
        // leaves every stored credential exactly as it was.
        expect(secureDataSource.passwords, {'db-a': 'a-secret'});
        expect(sessionSecretHolder.read(), 'original-secret');
      });

      test('FR-4: a biometric unlock reads only the entry of the database '
          'being unlocked', () async {
        registryRepository.records = [
          _record(id: 'db-a', path: '/tmp/a.kdbx'),
          _record(id: 'db-b', path: '/tmp/b.kdbx'),
        ];
        secureDataSource.passwords['db-a'] = 'pw-a';
        secureDataSource.passwords['db-b'] = 'pw-b';

        await gatedCoordinator.unlockWithStoredCredentials(
          databasePath: '/tmp/a.kdbx',
          keyFilePath: null,
        );

        expect(unlockUseCase.lastPassword, 'pw-a');
      });

      test('FR-4: a database with no entry fails the stored unlock even when '
          'another database has one', () async {
        registryRepository.records = [
          _record(id: 'db-a', path: '/tmp/a.kdbx'),
          _record(id: 'db-b', path: '/tmp/b.kdbx'),
        ];
        secureDataSource.passwords['db-b'] = 'pw-b';

        await expectLater(
          gatedCoordinator.unlockWithStoredCredentials(
            databasePath: '/tmp/a.kdbx',
            keyFilePath: null,
          ),
          throwsA(isA<InvalidCredentialsFailure>()),
        );

        expect(unlockUseCase.calls, 0);
        expect(secureDataSource.passwords, {'db-b': 'pw-b'});
      });

      test('FR-4: hasStoredMasterPassword answers per database', () async {
        registryRepository.records = [
          _record(id: 'db-a', path: '/tmp/a.kdbx'),
          _record(id: 'db-b', path: '/tmp/b.kdbx'),
        ];
        secureDataSource.passwords['db-a'] = 'pw-a';

        expect(
          await gatedCoordinator.hasStoredMasterPassword(
            databasePath: '/tmp/a.kdbx',
          ),
          isTrue,
        );
        expect(
          await gatedCoordinator.hasStoredMasterPassword(
            databasePath: '/tmp/b.kdbx',
          ),
          isFalse,
        );
      });

      test('FR-5: disabling biometric protection erases the stored '
          'credential in the same operation', () async {
        registryRepository.records = [_record(id: 'db-a', path: '/tmp/a.kdbx')];
        securityRepository.profiles['db-a'] = const DatabaseSecurityProfile(
          databaseId: 'db-a',
          biometricProtectionEnabled: true,
        );
        secureDataSource.passwords['db-a'] = 'pw-a';

        await gatedCoordinator.updateBiometricProtection(
          databasePath: '/tmp/a.kdbx',
          enabled: false,
        );

        expect(
          securityRepository.profiles['db-a']!.biometricProtectionEnabled,
          isFalse,
        );
        expect(secureDataSource.passwords, isEmpty);
      });

      test('FR-5: enabling biometric protection on the (locked) unlock '
          'screen persists only the profile, never a credential', () async {
        registryRepository.records = [_record(id: 'db-a', path: '/tmp/a.kdbx')];

        await gatedCoordinator.updateBiometricProtection(
          databasePath: '/tmp/a.kdbx',
          enabled: true,
        );

        expect(
          securityRepository.profiles['db-a']!.biometricProtectionEnabled,
          isTrue,
        );
        expect(secureDataSource.passwords, isEmpty);
      });
    });

    test(
      'checkInitialDatabase opens active database when many exist',
      () async {
        final pathA = await _writeManagedDatabase(tempDir, 'a.kdbx');
        final pathB = await _writeManagedDatabase(tempDir, 'b.kdbx');
        registryRepository.records = [
          _record(id: 'db-a', path: pathA),
          _record(id: 'db-b', path: pathB, lastOpenedAt: DateTime(2026, 2)),
        ];
        registryRepository.activeId = 'db-b';

        final result = await coordinator.checkInitialDatabase();

        expect(result.status, DatabaseSessionStatus.success);
        expect(result.path, pathB);
        expect(registryRepository.activeId, 'db-b');
        expect(registryRepository.records, hasLength(2));
      },
    );

    test('checkInitialDatabase routes a registered-but-missing active database '
        'to the selection list instead of a generic open failure', () async {
      final pathA = await _writeManagedDatabase(tempDir, 'a.kdbx');
      final missingPath = '${tempDir.path}/missing.kdbx';
      registryRepository.records = [
        _record(id: 'db-a', path: pathA),
        _record(id: 'db-b', path: missingPath),
      ];
      registryRepository.activeId = 'db-b';

      final result = await coordinator.checkInitialDatabase();

      expect(result.status, DatabaseSessionStatus.unselected);
      expect(_paths(result.items), containsAll([pathA, missingPath]));
      final missingItem = result.items.firstWhere(
        (item) => item.canonicalPath == missingPath,
      );
      expect(missingItem.isMissing, isTrue);
      expect(registryRepository.activeId, 'db-b');
    });

    test(
      'checkInitialDatabase routes to the selection list (not an open '
      'attempt) when the active record points at a stale/never-written path',
      () async {
        final pathA = await _writeManagedDatabase(tempDir, 'a.kdbx');
        final stalePathB = '${tempDir.path}/databases/b.kdbx';
        registryRepository.records = [
          _record(id: 'db-a', path: pathA),
          _record(id: 'db-b', path: stalePathB),
        ];
        registryRepository.activeId = 'db-b';

        final result = await coordinator.checkInitialDatabase();

        expect(result.status, DatabaseSessionStatus.unselected);
        final staleItem = result.items.firstWhere(
          (item) => item.canonicalPath == stalePathB,
        );
        expect(staleItem.isMissing, isTrue);
        final presentItem = result.items.firstWhere(
          (item) => item.canonicalPath == pathA,
        );
        expect(presentItem.isMissing, isFalse);
      },
    );

    test(
      'openRecentDatabase failure does not update active database',
      () async {
        registryRepository.activeId = 'db-old';

        await expectLater(
          coordinator.openRecentDatabase('${tempDir.path}/missing.kdbx'),
          throwsException,
        );

        expect(registryRepository.activeId, 'db-old');
      },
    );

    test('checkInitialDatabase does not duplicate the only record', () async {
      final path = await _writeManagedDatabase(tempDir, 'only.kdbx');
      registryRepository.records = [_record(id: 'db-only', path: path)];
      registryRepository.activeId = 'db-only';

      final result = await coordinator.checkInitialDatabase();

      expect(result.status, DatabaseSessionStatus.success);
      expect(result.path, path);
      expect(registryRepository.records, hasLength(1));
      expect(registryRepository.records.single.databaseId, 'db-only');
    });

    test('local duplicate cancel preserves existing database bytes', () async {
      final targetPath = await _writeManagedDatabase(tempDir, 'existing.kdbx');
      final originalBytes = await File(targetPath).readAsBytes();
      final incomingBytes = <int>[
        0x03,
        0xD9,
        0xA2,
        0x9A,
        0x67,
        0xFB,
        0x4B,
        0xB5,
        ...utf8.encode('incoming'),
      ];
      final incomingFile = File('${tempDir.path}/incoming/existing.kdbx');
      await incomingFile.parent.create(recursive: true);
      await incomingFile.writeAsBytes(incomingBytes, flush: true);
      registryRepository.records = [
        _record(
          id: 'db-existing',
          path: targetPath,
        ).copyWith(fileHash: md5.convert(incomingBytes).toString()),
      ];

      final pending = await coordinator.selectExistingDatabase(
        fileName: 'existing.kdbx',
        selectedPath: incomingFile.path,
      );
      expect(pending.status, DatabaseSessionStatus.duplicateDecisionRequired);
      expect(await File(targetPath).readAsBytes(), originalBytes);

      final resolved = await coordinator.resolveDuplicateDecision(
        duplicatePrompt: pending.duplicatePrompt!,
        decision: DatabaseDuplicateResolution.cancel,
      );

      expect(resolved.status, DatabaseSessionStatus.unselected);
      expect(await File(targetPath).readAsBytes(), originalBytes);
      final staging = Directory(p.join(tempDir.path, 'database_imports'));
      expect(await staging.list().isEmpty, isTrue);
    });

    test('corrupt Drive download preserves existing bytes', () async {
      final existingPath = await _writeManagedDatabase(tempDir, 'remote.kdbx');
      final originalBytes = await File(existingPath).readAsBytes();
      syncRepository.downloadBytes = Uint8List.fromList(const [1, 2, 3]);

      await expectLater(
        coordinator.selectDriveDatabase(
          remoteProviderId: 'google_drive',
          remoteFileId: 'remote-id',
          remoteFileName: 'remote.kdbx',
        ),
        throwsException,
      );

      expect(await File(existingPath).readAsBytes(), originalBytes);
      final staging = Directory(p.join(tempDir.path, 'database_imports'));
      expect(
        await staging.exists() ? await staging.list().isEmpty : true,
        isTrue,
      );
    });

    test('Drive listing connects before loading remote files', () async {
      syncRepository.remoteFiles = const [
        RemoteFile(
          providerId: 'google_drive',
          id: 'remote-id',
          name: 'remote.kdbx',
        ),
      ];

      final picker = await coordinator.getRemoteFileSelectionData();

      expect(syncRepository.connectCalls, 1);
      expect(picker.files.single.name, 'remote.kdbx');
      expect(
        picker.account,
        const StorageAccountSummary(displayLabel: 'Google Drive account'),
      );
    });

    test('switchRemoteAccount disconnects, reconnects, then reloads the list '
        'and leaves mappings alone', () async {
      syncRepository.connected = true;
      syncRepository.remoteFiles = const [
        RemoteFile(providerId: 'google_drive', id: 'r1', name: 'r.kdbx'),
      ];
      syncRepository.mappings['/db/a.kdbx'] = const DatabaseSyncMapping(
        databasePath: '/db/a.kdbx',
        providerId: 'google_drive',
        remoteFileId: 'r1',
        remoteFileName: 'r.kdbx',
      );

      final data = await coordinator.switchRemoteAccount();

      expect(syncRepository.connectionCalls, ['disconnect', 'connect']);
      expect(syncRepository.connected, isTrue);
      expect(data.files.single.id, 'r1');
      expect(syncRepository.mappings.keys, ['/db/a.kdbx']);
    });

    test('a failed or cancelled switch leaves the repository disconnected and '
        'rethrows', () async {
      syncRepository.connected = true;
      syncRepository.connectError = Exception('Google sign-in cancelled.');

      await expectLater(coordinator.switchRemoteAccount(), throwsException);

      expect(syncRepository.connectionCalls, ['disconnect', 'connect']);
      expect(syncRepository.connected, isFalse);
    });

    test('connectedAccountOrNull never connects', () async {
      expect(await coordinator.connectedAccountOrNull(), isNull);
      syncRepository.connected = true;
      expect(await coordinator.connectedAccountOrNull(), isNotNull);
      expect(syncRepository.connectCalls, 0);
    });

    test('Drive reconnect re-authorizes even while still signed in', () async {
      // The mobile failure this guards: a lapsed Drive scope leaves the Google
      // account signed in, so `isConnected()` stays true and the plain load
      // never re-authorizes — every retry reproduces the same failure.
      syncRepository.connected = true;
      syncRepository.remoteFiles = const [
        RemoteFile(
          providerId: 'google_drive',
          id: 'remote-id',
          name: 'remote.kdbx',
        ),
      ];

      await coordinator.getRemoteFileSelectionData();
      expect(syncRepository.connectCalls, 0);

      final picker = await coordinator.reconnectRemoteFileSelectionData();

      expect(syncRepository.connectCalls, 1);
      expect(picker.files.single.name, 'remote.kdbx');
    });

    test('Drive duplicate cancel preserves file and mapping', () async {
      final existingPath = await _prepareDriveDuplicate(
        tempDir,
        registryRepository,
        syncRepository,
      );
      final originalBytes = await File(existingPath).readAsBytes();

      final pending = await coordinator.selectDriveDatabase(
        remoteProviderId: 'google_drive',
        remoteFileId: 'remote-id',
        remoteFileName: 'remote.kdbx',
      );

      expect(await File(existingPath).readAsBytes(), originalBytes);
      final resolved = await coordinator.resolveDuplicateDecision(
        duplicatePrompt: pending.duplicatePrompt!,
        decision: DatabaseDuplicateResolution.cancel,
      );

      expect(resolved.status, DatabaseSessionStatus.unselected);
      expect(await File(existingPath).readAsBytes(), originalBytes);
      expect(syncRepository.mappings[existingPath]!.remoteFileId, 'old-remote');
      expect(registryRepository.records, hasLength(1));
    });

    test('Drive duplicate useExisting discards staged file', () async {
      final existingPath = await _prepareDriveDuplicate(
        tempDir,
        registryRepository,
        syncRepository,
      );
      final originalBytes = await File(existingPath).readAsBytes();

      final pending = await coordinator.selectDriveDatabase(
        remoteProviderId: 'google_drive',
        remoteFileId: 'remote-id',
        remoteFileName: 'remote.kdbx',
      );
      final resolved = await coordinator.resolveDuplicateDecision(
        duplicatePrompt: pending.duplicatePrompt!,
        decision: DatabaseDuplicateResolution.useExisting,
      );

      expect(resolved.path, existingPath);
      expect(await File(existingPath).readAsBytes(), originalBytes);
      expect(syncRepository.mappings[existingPath]!.remoteFileId, 'remote-id');
      expect(registryRepository.records, hasLength(1));
    });

    test('Drive duplicate keepBoth preserves existing mapping', () async {
      final existingPath = await _prepareDriveDuplicate(
        tempDir,
        registryRepository,
        syncRepository,
      );

      final pending = await coordinator.selectDriveDatabase(
        remoteProviderId: 'google_drive',
        remoteFileId: 'remote-id',
        remoteFileName: 'remote.kdbx',
      );
      final resolved = await coordinator.resolveDuplicateDecision(
        duplicatePrompt: pending.duplicatePrompt!,
        decision: DatabaseDuplicateResolution.keepBoth,
      );

      expect(resolved.path, isNot(existingPath));
      expect(await File(resolved.path!).exists(), isTrue);
      expect(registryRepository.records, hasLength(2));
      expect(syncRepository.mappings[existingPath]!.remoteFileId, 'old-remote');
      expect(syncRepository.mappings[resolved.path]!.remoteFileId, 'remote-id');
    });

    test(
      'Drive duplicate replace swaps file and mapping after decision',
      () async {
        final existingPath = await _prepareDriveDuplicate(
          tempDir,
          registryRepository,
          syncRepository,
        );
        final originalBytes = await File(existingPath).readAsBytes();

        final pending = await coordinator.selectDriveDatabase(
          remoteProviderId: 'google_drive',
          remoteFileId: 'remote-id',
          remoteFileName: 'remote.kdbx',
        );
        expect(await File(existingPath).readAsBytes(), originalBytes);

        final resolved = await coordinator.resolveDuplicateDecision(
          duplicatePrompt: pending.duplicatePrompt!,
          decision: DatabaseDuplicateResolution.replaceExisting,
        );

        expect(resolved.path, existingPath);
        expect(
          await File(existingPath).readAsBytes(),
          syncRepository.downloadBytes,
        );
        expect(
          syncRepository.mappings[existingPath]!.remoteFileId,
          'remote-id',
        );
        expect(registryRepository.records, hasLength(1));
        expect(registryRepository.records.single.canonicalPath, existingPath);
      },
    );

    group('spec 025 T201 duplicate outcomes (characterization)', () {
      // Pins today's four outcomes of a duplicate import, for a local and a
      // Drive source, BEFORE the name-based overwrite branch is removed
      // (risk R3). They must pass unmodified after that removal.
      late Directory staging;

      setUp(() {
        staging = Directory(p.join(tempDir.path, 'database_imports'));
      });

      Future<bool> stagingIsEmpty() async =>
          !await staging.exists() || await staging.list().isEmpty;

      List<String> backups() =>
          Directory(p.join(tempDir.path, 'databases'))
              .listSync()
              .map((entity) => entity.path)
              .where((path) => path.contains('.import-backup-'))
              .toList(growable: false);

      List<String> databaseFiles() =>
          Directory(p.join(tempDir.path, 'databases'))
              .listSync()
              .map((entity) => entity.path)
              .where((path) => !path.contains('.import-backup-'))
              .toList(growable: false);

      final incomingBytes = <int>[
        0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, //
        ...utf8.encode('incoming'),
      ];

      /// An existing local database whose registered hash equals the bytes
      /// about to be imported, so the import is a hash duplicate.
      Future<({String path, List<int> original})> seedLocalDuplicate() async {
        final targetPath = await _writeManagedDatabase(
          tempDir,
          'existing.kdbx',
        );
        final original = await File(targetPath).readAsBytes();
        registryRepository.records = [
          _record(
            id: 'db-existing',
            path: targetPath,
          ).copyWith(fileHash: md5.convert(incomingBytes).toString()),
        ];
        final incomingFile = File('${tempDir.path}/incoming/existing.kdbx');
        await incomingFile.parent.create(recursive: true);
        await incomingFile.writeAsBytes(incomingBytes, flush: true);
        return (path: targetPath, original: original);
      }

      Future<DatabaseSelectionSessionResult> pendingLocal() =>
          coordinator.selectExistingDatabase(
            fileName: 'existing.kdbx',
            selectedPath: '${tempDir.path}/incoming/existing.kdbx',
          );

      Future<DatabaseSelectionSessionResult> pendingRemote() =>
          coordinator.selectDriveDatabase(
            remoteProviderId: 'google_drive',
            remoteFileId: 'remote-id',
            remoteFileName: 'remote.kdbx',
          );

      Future<DatabaseSelectionSessionResult> resolve(
        DatabaseSelectionSessionResult pending,
        DatabaseDuplicateResolution decision,
      ) {
        expect(pending.status, DatabaseSessionStatus.duplicateDecisionRequired);
        return coordinator.resolveDuplicateDecision(
          duplicatePrompt: pending.duplicatePrompt!,
          decision: decision,
        );
      }

      test(
        'local useExisting opens the existing file and discards staging',
        () async {
          final seed = await seedLocalDuplicate();

          final resolved = await resolve(
            await pendingLocal(),
            DatabaseDuplicateResolution.useExisting,
          );

          expect(resolved.status, DatabaseSessionStatus.success);
          expect(resolved.path, seed.path);
          expect(await File(seed.path).readAsBytes(), seed.original);
          expect(registryRepository.records, hasLength(1));
          expect(await stagingIsEmpty(), isTrue);
        },
      );

      test(
        'local keepBoth adds a second file and leaves the first alone',
        () async {
          final seed = await seedLocalDuplicate();

          final resolved = await resolve(
            await pendingLocal(),
            DatabaseDuplicateResolution.keepBoth,
          );

          expect(resolved.path, isNot(seed.path));
          expect(await File(resolved.path!).readAsBytes(), incomingBytes);
          expect(await File(seed.path).readAsBytes(), seed.original);
          expect(registryRepository.records, hasLength(2));
          expect(await stagingIsEmpty(), isTrue);
        },
      );

      test('local replace backs up first, keeps the id, drops the backup '
          'on success', () async {
        final seed = await seedLocalDuplicate();
        final backupsDuringCommit = <List<String>>[];
        registryRepository.onUpsert = () => backupsDuringCommit.add(backups());

        final resolved = await resolve(
          await pendingLocal(),
          DatabaseDuplicateResolution.replaceExisting,
        );

        expect(backupsDuringCommit.single, hasLength(1));
        expect(resolved.path, seed.path);
        expect(await File(seed.path).readAsBytes(), incomingBytes);
        expect(registryRepository.records.single.databaseId, 'db-existing');
        expect(backups(), isEmpty);
        expect(await stagingIsEmpty(), isTrue);
      });

      test(
        'local replace failing downstream restores the original bytes',
        () async {
          final seed = await seedLocalDuplicate();
          final pending = await pendingLocal();
          registryRepository.failNextUpsert = true;

          await expectLater(
            resolve(pending, DatabaseDuplicateResolution.replaceExisting),
            throwsException,
          );

          expect(await File(seed.path).readAsBytes(), seed.original);
          expect(backups(), isEmpty);
          expect(registryRepository.records.single.databaseId, 'db-existing');
        },
      );

      test('local keepBoth failing downstream leaves no second file', () async {
        final seed = await seedLocalDuplicate();
        final pending = await pendingLocal();
        registryRepository.failNextUpsert = true;

        await expectLater(
          resolve(pending, DatabaseDuplicateResolution.keepBoth),
          throwsException,
        );

        expect(databaseFiles(), [seed.path]);
        expect(await File(seed.path).readAsBytes(), seed.original);
        expect(registryRepository.records, hasLength(1));
      });

      test('Drive cancel and useExisting discard the staged bytes', () async {
        await _prepareDriveDuplicate(
          tempDir,
          registryRepository,
          syncRepository,
        );
        await resolve(
          await pendingRemote(),
          DatabaseDuplicateResolution.cancel,
        );
        expect(await stagingIsEmpty(), isTrue);

        await resolve(
          await pendingRemote(),
          DatabaseDuplicateResolution.useExisting,
        );
        expect(await stagingIsEmpty(), isTrue);
        expect(registryRepository.records, hasLength(1));
      });

      test(
        'Drive keepBoth discards staging and the first file is untouched',
        () async {
          final existingPath = await _prepareDriveDuplicate(
            tempDir,
            registryRepository,
            syncRepository,
          );
          final original = await File(existingPath).readAsBytes();

          await resolve(
            await pendingRemote(),
            DatabaseDuplicateResolution.keepBoth,
          );

          expect(await File(existingPath).readAsBytes(), original);
          expect(await stagingIsEmpty(), isTrue);
        },
      );

      test(
        'Drive replace backs up first and drops the backup on success',
        () async {
          final existingPath = await _prepareDriveDuplicate(
            tempDir,
            registryRepository,
            syncRepository,
          );
          final backupsDuringCommit = <List<String>>[];
          registryRepository.onUpsert = () =>
              backupsDuringCommit.add(backups());

          await resolve(
            await pendingRemote(),
            DatabaseDuplicateResolution.replaceExisting,
          );

          expect(backupsDuringCommit.single, hasLength(1));
          expect(
            await File(existingPath).readAsBytes(),
            syncRepository.downloadBytes,
          );
          expect(backups(), isEmpty);
          expect(await stagingIsEmpty(), isTrue);
        },
      );

      test('Drive replace failing at the link step restores bytes and '
          'registry', () async {
        final existingPath = await _prepareDriveDuplicate(
          tempDir,
          registryRepository,
          syncRepository,
        );
        final original = await File(existingPath).readAsBytes();
        final pending = await pendingRemote();
        syncRepository.linkError = Exception('link failed');

        await expectLater(
          resolve(pending, DatabaseDuplicateResolution.replaceExisting),
          throwsException,
        );

        expect(await File(existingPath).readAsBytes(), original);
        expect(backups(), isEmpty);
        expect(registryRepository.records, hasLength(1));
        expect(registryRepository.records.single.databaseId, 'db-existing');
        expect(
          syncRepository.mappings[existingPath]!.remoteFileId,
          'old-remote',
        );
      });

      test('Drive keepBoth failing at the link step removes the new file '
          'and record', () async {
        final existingPath = await _prepareDriveDuplicate(
          tempDir,
          registryRepository,
          syncRepository,
        );
        final pending = await pendingRemote();
        syncRepository.linkError = Exception('link failed');

        await expectLater(
          resolve(pending, DatabaseDuplicateResolution.keepBoth),
          throwsException,
        );

        expect(databaseFiles(), [existingPath]);
        expect(registryRepository.records, hasLength(1));
      });
    });

    group('spec 025 FR-O6 name-only conflict', () {
      // The registry display name is the only name truth; no hash and no
      // source matches, so the four outcomes run on a different file that
      // merely shares a name.
      late String existingPath;
      late List<int> existingBytes;
      final incomingBytes = <int>[
        0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, //
        ...utf8.encode('name-only incoming'),
      ];

      Future<DatabaseSelectionSessionResult> pending({List<int>? bytes}) async {
        final incoming = File('${tempDir.path}/incoming/existing.kdbx');
        await incoming.parent.create(recursive: true);
        await incoming.writeAsBytes(bytes ?? incomingBytes, flush: true);
        final result = await coordinator.selectExistingDatabase(
          fileName: 'existing.kdbx',
          selectedPath: incoming.path,
        );
        expect(result.status, DatabaseSessionStatus.duplicateDecisionRequired);
        expect(
          result.duplicatePrompt!.matchType,
          DatabaseDuplicateMatchType.name,
        );
        return result;
      }

      Future<DatabaseSelectionSessionResult> resolve(
        DatabaseSelectionSessionResult prompt,
        DatabaseDuplicateResolution decision,
      ) => coordinator.resolveDuplicateDecision(
        duplicatePrompt: prompt.duplicatePrompt!,
        decision: decision,
      );

      Future<bool> stagingIsEmpty() async {
        final staging = Directory(p.join(tempDir.path, 'database_imports'));
        return !await staging.exists() || await staging.list().isEmpty;
      }

      setUp(() async {
        existingPath = await _writeManagedDatabase(tempDir, 'existing.kdbx');
        existingBytes = await File(existingPath).readAsBytes();
        registryRepository.records = [
          _record(
            id: 'db-existing',
            path: existingPath,
          ).copyWith(fileHash: 'unrelated-hash'),
        ];
      });

      test('cancel discards the staged bytes and changes nothing', () async {
        await resolve(await pending(), DatabaseDuplicateResolution.cancel);

        expect(await File(existingPath).readAsBytes(), existingBytes);
        expect(registryRepository.records, hasLength(1));
        expect(await stagingIsEmpty(), isTrue);
      });

      test('useExisting opens the existing file and imports nothing', () async {
        final resolved = await resolve(
          await pending(),
          DatabaseDuplicateResolution.useExisting,
        );

        expect(resolved.path, existingPath);
        expect(resolved.message, isNull);
        expect(await File(existingPath).readAsBytes(), existingBytes);
        expect(registryRepository.records, hasLength(1));
        expect(await stagingIsEmpty(), isTrue);
      });

      test(
        'Drive useExisting does not re-point the existing mapping',
        () async {
          syncRepository.mappings[existingPath] = DatabaseSyncMapping(
            databasePath: existingPath,
            providerId: 'google_drive',
            remoteFileId: 'old-remote',
            remoteFileName: 'old.kdbx',
            autoSyncEnabled: true,
          );
          syncRepository.downloadBytes = Uint8List.fromList(incomingBytes);
          final prompt = await coordinator.selectDriveDatabase(
            remoteProviderId: 'google_drive',
            remoteFileId: 'remote-id',
            remoteFileName: 'existing.kdbx',
          );
          expect(
            prompt.duplicatePrompt!.matchType,
            DatabaseDuplicateMatchType.name,
          );

          await resolve(prompt, DatabaseDuplicateResolution.useExisting);

          expect(
            syncRepository.mappings[existingPath]!.remoteFileId,
            'old-remote',
          );
          expect(await stagingIsEmpty(), isTrue);
        },
      );

      test('keepBoth adds a record with a numeric suffix, then the next free '
          'one', () async {
        final first = await resolve(
          await pending(),
          DatabaseDuplicateResolution.keepBoth,
        );
        expect(first.path, isNot(existingPath));
        expect(await File(existingPath).readAsBytes(), existingBytes);
        expect(registryRepository.records.map((r) => r.displayName).toSet(), {
          'existing.kdbx',
          'existing (2).kdbx',
        });

        // Different content, so only the name matches again.
        await resolve(
          await pending(bytes: [...incomingBytes, 9]),
          DatabaseDuplicateResolution.keepBoth,
        );
        expect(registryRepository.records.map((r) => r.displayName).toSet(), {
          'existing.kdbx',
          'existing (2).kdbx',
          'existing (3).kdbx',
        });
        expect(await stagingIsEmpty(), isTrue);
      });

      test(
        'replace backs up, keeps the id and drops the old profile',
        () async {
          securityRepository.profiles['db-existing'] =
              const DatabaseSecurityProfile(
                databaseId: 'db-existing',
                biometricProtectionEnabled: true,
              );
          final resolved = await resolve(
            await pending(),
            DatabaseDuplicateResolution.replaceExisting,
          );

          expect(resolved.path, existingPath);
          expect(await File(existingPath).readAsBytes(), incomingBytes);
          expect(registryRepository.records.single.databaseId, 'db-existing');
          expect(securityRepository.profiles, isEmpty);
          expect(
            Directory(p.join(tempDir.path, 'databases'))
                .listSync()
                .where((e) => e.path.contains('.import-backup-')),
            isEmpty,
          );
          expect(await stagingIsEmpty(), isTrue);
        },
      );

      test('replace failing downstream restores bytes and profile', () async {
        const profile = DatabaseSecurityProfile(
          databaseId: 'db-existing',
          biometricProtectionEnabled: true,
        );
        securityRepository.profiles['db-existing'] = profile;
        final prompt = await pending();
        registryRepository.failNextUpsert = true;

        await expectLater(
          resolve(prompt, DatabaseDuplicateResolution.replaceExisting),
          throwsException,
        );

        expect(await File(existingPath).readAsBytes(), existingBytes);
        expect(securityRepository.profiles['db-existing'], profile);
      });
    });

    test('protected key paths include shared profiles once', () async {
      // Native absolute path, not the `/tmp/...` literal this used to use.
      // `getProtectedKeyFilePaths` runs every path through `p.normalize`, and
      // on Windows that rewrites `/tmp/shared.key` into `\tmp\shared.key`, so
      // the literal could never match. What the test is actually about — two
      // profiles sharing one key file collapse to a SINGLE protected entry —
      // is unchanged, and now the expected value is spelled the way the host
      // spells it instead of assuming POSIX.
      final sharedPath = p.join(Directory.systemTemp.path, 'shared.key');
      registryRepository.records = [
        _record(id: 'db-a', path: '/tmp/a.kdbx'),
        _record(id: 'db-b', path: '/tmp/b.kdbx'),
      ];
      securityRepository.profiles['db-a'] = DatabaseSecurityProfile(
        databaseId: 'db-a',
        keyFilePath: sharedPath,
      );
      securityRepository.profiles['db-b'] = DatabaseSecurityProfile(
        databaseId: 'db-b',
        keyFilePath: sharedPath,
      );

      expect(await coordinator.getProtectedKeyFilePaths(), {sharedPath});
      expect(
        await coordinator.getProtectedKeyFilePaths(),
        hasLength(1),
        reason: 'one key file shared by two databases is one protected path',
      );
    });

    test('spec 014 FR-3: reopening a database whose at-rest name is opaque '
        'keeps the registry display name instead of the hex', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'db_session_reopen_opaque_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final opaquePath = p.join(
        tempDir.path,
        '0123456789abcdef0123456789abcdef',
      );
      await File(opaquePath).writeAsBytes(<int>[
        0x03,
        0xD9,
        0xA2,
        0x9A,
        0x67,
        0xFB,
        0x4B,
        0xB5,
        ...utf8.encode('fixture'),
      ], flush: true);
      registryRepository.records = [
        DatabaseRecord(
          databaseId: 'db-opaque',
          canonicalPath: opaquePath,
          displayName: 'Personal vault.kdbx',
          sourceType: DatabaseSourceType.drive,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];

      final result = await coordinator.openRecentDatabase(opaquePath);

      expect(result.status, DatabaseSessionStatus.success);
      expect(
        registryRepository.records.single.displayName,
        'Personal vault.kdbx',
      );
    });

    test(
      'openRecentDatabase succeeds without duplicate decision prompt',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'db_session_open_recent_',
        );
        addTearDown(() => tempDir.delete(recursive: true));

        final currentPath = '${tempDir.path}/managed.kdbx';
        final currentFile = File(currentPath);

        final content = Uint8List.fromList(<int>[
          0x03,
          0xD9,
          0xA2,
          0x9A,
          0x67,
          0xFB,
          0x4B,
          0xB5,
          ...utf8.encode('fixture'),
        ]);
        await currentFile.writeAsBytes(content, flush: true);
        final fileHash = md5.convert(content).toString();

        registryRepository.records = [
          DatabaseRecord(
            databaseId: 'db-current',
            canonicalPath: currentPath,
            displayName: 'managed.kdbx',
            sourceType: DatabaseSourceType.local,
            fileHash: fileHash,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
          DatabaseRecord(
            databaseId: 'db-other',
            canonicalPath: '${tempDir.path}/other.kdbx',
            displayName: 'other.kdbx',
            sourceType: DatabaseSourceType.local,
            fileHash: fileHash,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        ];
        secureDataSource.passwords['db-other'] = 'secret';

        final result = await coordinator.openRecentDatabase(currentPath);

        expect(result.status, DatabaseSessionStatus.success);
        expect(result.path, currentPath);
        expect(result.duplicatePrompt, isNull);
        expect(registryRepository.activeId, 'db-current');
        // spec-011 Slice 2: switching database never erases another
        // database's persistent biometric credential (FR-4/FR-5).
        expect(secureDataSource.passwords['db-other'], 'secret');
        expect(appleAutofillV2Coordinator.clearCallCount, 1);
      },
    );

    test('removeRecentDatabase clears Apple autofill credentials', () async {
      const currentPath = '/tmp/active.kdbx';
      registryRepository.records = [
        DatabaseRecord(
          databaseId: 'db-current',
          canonicalPath: currentPath,
          displayName: 'active.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
      registryRepository.activeId = 'db-current';
      securityRepository.profiles['db-current'] = const DatabaseSecurityProfile(
        databaseId: 'db-current',
        keyFilePath: '/tmp/key.key',
      );
      secureDataSource.passwords['db-current'] = 'secret';

      final result = await coordinator.removeRecentDatabase(
        path: currentPath,
        mode: RecentDatabaseRemovalMode.removeOnly,
      );

      expect(result.status, DatabaseSessionStatus.info);
      expect(registryRepository.records, isEmpty);
      expect(securityRepository.profiles, isEmpty);
      // spec-011 FR-5: unregistering deletes the database's stored
      // credential.
      expect(secureDataSource.passwords, isEmpty);
      expect(appleAutofillV2Coordinator.clearCallCount, 1);
    });

    test('initializeUnlock resolves no key for a registered database without a '
        'profile key (spec 014 FR-8)', () async {
      final databasePath = await _writeManagedDatabase(tempDir, 'plain.kdbx');
      registryRepository.records = [
        _record(id: 'db-plain', path: databasePath),
      ];

      final result = await coordinator.initializeUnlock(
        databasePath: databasePath,
        biometricAvailable: false,
      );

      expect(result.keyFilePath, isNull);
    });

    test('initializeUnlock resolves the profile key file (the only source, '
        'spec 014 FR-8)', () async {
      final databasePath = await _writeManagedDatabase(tempDir, 'keyed.kdbx');
      final keyPath = '${tempDir.path}/keys/database.key';
      await File(keyPath).create(recursive: true);
      registryRepository.records = [
        _record(id: 'db-keyed', path: databasePath),
      ];
      securityRepository.profiles['db-keyed'] = DatabaseSecurityProfile(
        databaseId: 'db-keyed',
        keyFilePath: keyPath,
        biometricProtectionEnabled: false,
      );

      final result = await coordinator.initializeUnlock(
        databasePath: databasePath,
        biometricAvailable: false,
      );

      expect(result.keyFilePath, keyPath);
    });

    test('initializeUnlock resolves no key for an unregistered database — the '
        'global cached fallback is gone (spec 014 FR-8)', () async {
      final result = await coordinator.initializeUnlock(
        databasePath: '${tempDir.path}/legacy.kdbx',
        biometricAvailable: false,
      );

      expect(result.keyFilePath, isNull);
    });

    // spec-003 AC-7 / plan.md risk "Locate points metadata at another
    // vault" — mitigation "Require stored hash match when available;
    // reject mismatch" is verified explicitly here at the coordinator
    // level (not just via the file-repository/use-case layers).
    group('locateMissingDatabase (FR-1)', () {
      test('hash match updates canonicalPath/registry/sync mapping atomically '
          'and preserves the database ID and security profile', () async {
        final missingPath = '${tempDir.path}/databases/missing.kdbx';
        final foundPath = await _writeManagedDatabase(tempDir, 'found.kdbx');
        final foundHash = md5
            .convert(await File(foundPath).readAsBytes())
            .toString();

        registryRepository.records = [
          _record(
            id: 'db-1',
            path: missingPath,
            fileHash: foundHash,
            sourceType: DatabaseSourceType.drive,
          ),
        ];
        securityRepository.profiles['db-1'] = const DatabaseSecurityProfile(
          databaseId: 'db-1',
          keyFilePath: '/tmp/db-1.key',
        );
        syncRepository.mappings[missingPath] = DatabaseSyncMapping(
          databasePath: missingPath,
          providerId: 'google_drive',
          remoteFileId: 'remote-1',
          remoteFileName: 'missing.kdbx',
          autoSyncEnabled: true,
        );

        final result = await coordinator.locateMissingDatabase(
          databaseId: 'db-1',
          selectedPath: foundPath,
        );

        expect(result.status, DatabaseSessionStatus.success);
        expect(result.path, foundPath);

        final updated = registryRepository.records.single;
        expect(
          updated.databaseId,
          'db-1',
          reason: 'database ID must be preserved, never rebound',
        );
        expect(updated.canonicalPath, foundPath);
        expect(updated.fileHash, foundHash);
        expect(registryRepository.activeId, 'db-1');

        expect(
          securityRepository.profiles['db-1']?.keyFilePath,
          '/tmp/db-1.key',
          reason: 'security profile must be preserved untouched',
        );

        expect(
          syncRepository.mappings.containsKey(missingPath),
          isFalse,
          reason: 'the stale mapping key must be moved, not duplicated',
        );
        expect(syncRepository.mappings[foundPath]?.remoteFileId, 'remote-1');

        final locatedItem = result.items.firstWhere(
          (item) => item.databaseId == 'db-1',
        );
        expect(locatedItem.isMissing, isFalse);
      });

      test('hash mismatch mutates nothing and instructs the user to use Open '
          'instead', () async {
        final missingPath = '${tempDir.path}/databases/missing.kdbx';
        final wrongPath = await _writeManagedDatabase(tempDir, 'wrong.kdbx');

        registryRepository.records = [
          _record(id: 'db-1', path: missingPath, fileHash: 'expected-hash'),
        ];
        securityRepository.profiles['db-1'] = const DatabaseSecurityProfile(
          databaseId: 'db-1',
          keyFilePath: '/tmp/db-1.key',
        );
        registryRepository.activeId = 'db-previous-active';
        localDataSource.selectedKeyFilePath = '/tmp/previous.key';
        secureDataSource.passwords['db-previous-active'] = 'previous-secret';

        // Full pre-call snapshot so the "zero mutations" claim is
        // checked exhaustively, not just for the fields the happy path
        // touches.
        final recordsBefore = List<DatabaseRecord>.of(
          registryRepository.records,
        );
        final activeIdBefore = registryRepository.activeId;
        final profilesBefore = Map<String, DatabaseSecurityProfile>.of(
          securityRepository.profiles,
        );
        final mappingsBefore = Map<String, DatabaseSyncMapping>.of(
          syncRepository.mappings,
        );
        final selectedKeyPathBefore = localDataSource.selectedKeyFilePath;
        final passwordsBefore = Map<String, String>.of(
          secureDataSource.passwords,
        );

        final result = await coordinator.locateMissingDatabase(
          databaseId: 'db-1',
          // A real file with a real (different) hash than the stored
          // 'expected-hash' — any genuine md5 sum will differ from that
          // placeholder string.
          selectedPath: wrongPath,
        );

        expect(result.status, DatabaseSessionStatus.error);
        expect(result.message, contains('does not match the missing database'));

        expect(registryRepository.records, recordsBefore);
        expect(registryRepository.records.single.canonicalPath, missingPath);
        expect(registryRepository.records.single.fileHash, 'expected-hash');
        expect(registryRepository.activeId, activeIdBefore);
        expect(securityRepository.profiles, profilesBefore);
        expect(syncRepository.mappings, mappingsBefore);
        expect(localDataSource.selectedKeyFilePath, selectedKeyPathBefore);
        expect(secureDataSource.passwords, passwordsBefore);
      });

      test('a legacy item with no stored hash accepts a valid selection '
          'unconditionally (C-1: hash compared "when present")', () async {
        final missingPath = '${tempDir.path}/databases/missing.kdbx';
        final foundPath = await _writeManagedDatabase(
          tempDir,
          'legacy-found.kdbx',
        );

        registryRepository.records = [
          _record(id: 'db-legacy', path: missingPath), // fileHash: null
        ];

        final result = await coordinator.locateMissingDatabase(
          databaseId: 'db-legacy',
          selectedPath: foundPath,
        );

        expect(result.status, DatabaseSessionStatus.success);
        expect(result.path, foundPath);
        expect(registryRepository.records.single.canonicalPath, foundPath);
      });

      test(
        'an unknown database ID returns a typed error and mutates nothing',
        () async {
          final result = await coordinator.locateMissingDatabase(
            databaseId: 'does-not-exist',
            selectedPath: '${tempDir.path}/whatever.kdbx',
          );

          expect(result.status, DatabaseSessionStatus.error);
          expect(result.message, 'Database record not found.');
        },
      );

      // P1-2: a mapping-move failure must restore BOTH mapping slots
      // exactly (never a blind reverse move), and must never mutate the
      // registry record or active id it had already changed.
      for (final failurePoint in _MappingMoveFailurePoint.values) {
        test('mapping failure at ${failurePoint.name} restores registry, '
            'active id and both mapping slots exactly', () async {
          final missingPath = '${tempDir.path}/databases/missing.kdbx';
          final foundPath = await _writeManagedDatabase(
            tempDir,
            'found-${failurePoint.name}.kdbx',
          );
          final foundHash = md5
              .convert(await File(foundPath).readAsBytes())
              .toString();
          final source = DatabaseSyncMapping(
            databasePath: missingPath,
            providerId: 'google_drive',
            remoteFileId: 'source-remote-id',
            remoteFileName: 'source.kdbx',
          );
          // Destination already has a mapping to a DIFFERENT Drive file —
          // a blind reverse move would overwrite it with the source's
          // remote id instead of restoring it.
          final destination = DatabaseSyncMapping(
            databasePath: foundPath,
            providerId: 'google_drive',
            remoteFileId: 'destination-remote-id',
            remoteFileName: 'destination.kdbx',
          );
          registryRepository.records = [
            _record(
              id: 'db-1',
              path: missingPath,
              fileHash: foundHash,
              sourceType: DatabaseSourceType.drive,
            ),
          ];
          registryRepository.activeId = 'previous-active-id';
          syncRepository.mappings
            ..[missingPath] = source
            ..[foundPath] = destination;
          syncRepository.failNextMoveAt = failurePoint;

          await expectLater(
            coordinator.locateMissingDatabase(
              databaseId: 'db-1',
              selectedPath: foundPath,
            ),
            throwsException,
          );

          expect(registryRepository.records.single.canonicalPath, missingPath);
          expect(registryRepository.activeId, 'previous-active-id');
          expect(syncRepository.mappings[missingPath], source);
          expect(syncRepository.mappings[foundPath], destination);
        });
      }

      test('registry activation failure after a successful mapping move '
          'restores both mapping slots exactly', () async {
        final missingPath = '${tempDir.path}/databases/missing.kdbx';
        final foundPath = await _writeManagedDatabase(
          tempDir,
          'found-registry-failure.kdbx',
        );
        final foundHash = md5
            .convert(await File(foundPath).readAsBytes())
            .toString();
        final source = DatabaseSyncMapping(
          databasePath: missingPath,
          providerId: 'google_drive',
          remoteFileId: 'source-remote-id',
          remoteFileName: 'source.kdbx',
        );
        final destination = DatabaseSyncMapping(
          databasePath: foundPath,
          providerId: 'google_drive',
          remoteFileId: 'destination-remote-id',
          remoteFileName: 'destination.kdbx',
        );
        registryRepository.records = [
          _record(
            id: 'db-1',
            path: missingPath,
            fileHash: foundHash,
            sourceType: DatabaseSourceType.drive,
          ),
        ];
        registryRepository.activeId = 'previous-active-id';
        registryRepository.failNextSetActive = true;
        syncRepository.mappings
          ..[missingPath] = source
          ..[foundPath] = destination;

        await expectLater(
          coordinator.locateMissingDatabase(
            databaseId: 'db-1',
            selectedPath: foundPath,
          ),
          throwsException,
        );

        expect(registryRepository.records.single.canonicalPath, missingPath);
        expect(registryRepository.activeId, 'previous-active-id');
        expect(syncRepository.mappings[missingPath], source);
        expect(syncRepository.mappings[foundPath], destination);
      });
    });

    // plan.md "Transaction rules": "Create failure removes partial
    // output/key material created by that attempt and leaves prior active
    // database/credentials unchanged." Verified at the coordinator level:
    // `create_database_usecase_test.dart` already proves the use case
    // itself deletes partial file output; this proves the coordinator adds
    // no further mutation when that use case fails/throws.
    group('createNewDatabase failure cleanup', () {
      test('a failing create leaves the prior active database and credentials '
          'unchanged', () async {
        final activePath = await _writeManagedDatabase(tempDir, 'active.kdbx');
        final activeKeyPath = '${tempDir.path}/keys/active.key';
        registryRepository.records = [
          _record(id: 'db-active', path: activePath),
        ];
        registryRepository.activeId = 'db-active';
        localDataSource.selectedKeyFilePath = activeKeyPath;
        secureDataSource.passwords['db-active'] = 'active-secret';
        securityRepository.profiles['db-active'] =
            const DatabaseSecurityProfile(
              databaseId: 'db-active',
              keyFilePath: '/tmp/keys/active.key',
            ).copyWith(keyFilePath: activeKeyPath);

        final failingCoordinator = DatabaseSessionCoordinator(
          sessionSecretHolder: sessionSecretHolder,
          databaseFileRepository: databaseImportService,
          databaseSessionRepository: DatabaseSessionRepositoryImpl(
            localDataSource: localDataSource,
            secureDataSource: secureDataSource,
          ),
          databaseRegistryRepository: registryRepository,
          databaseSecurityRepository: securityRepository,
          getActiveDatabaseUseCase: GetActiveDatabaseUseCase(
            registryRepository,
          ),
          resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
            registryRepository,
            syncRepository,
          ),
          databaseSyncRepository: syncRepository,
          linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
          unlockDatabaseUseCase: UnlockDatabaseUseCase(),
          createDatabaseUseCase: _FailingCreateDatabaseUseCase(
            databaseFileRepository: databaseImportService,
          ),
          appleAutofillV2Coordinator: appleAutofillV2Coordinator,
        );

        await expectLater(
          failingCoordinator.createNewDatabase(
            databaseFileName: 'new-vault.kdbx',
            password: 'new-secret',
            biometricProtectionEnabled: false,
            generateKeyFile: false,
          ),
          throwsException,
        );

        expect(registryRepository.records, hasLength(1));
        expect(registryRepository.records.single.databaseId, 'db-active');
        expect(registryRepository.activeId, 'db-active');
        expect(localDataSource.selectedKeyFilePath, activeKeyPath);
        expect(secureDataSource.passwords['db-active'], 'active-secret');
        expect(
          securityRepository.profiles['db-active']?.keyFilePath,
          activeKeyPath,
        );
      });
    });

    // spec 015 FR-9 / AC-3 (T007): a failure induced at each stage of the
    // transaction leaves no .kdbx, no generated key, no registry record, no
    // changed active id, no security profile, no secure-store entry, no
    // sync mapping — and the user's selected key file still exists.
    group('spec 015 T007 transactional create (FR-9)', () {
      late DatabaseSessionCoordinator realCoordinator;

      setUp(() {
        realCoordinator = DatabaseSessionCoordinator(
          sessionSecretHolder: sessionSecretHolder,
          databaseFileRepository: databaseImportService,
          databaseSessionRepository: DatabaseSessionRepositoryImpl(
            localDataSource: localDataSource,
            secureDataSource: secureDataSource,
          ),
          databaseRegistryRepository: registryRepository,
          databaseSecurityRepository: securityRepository,
          getActiveDatabaseUseCase: GetActiveDatabaseUseCase(
            registryRepository,
          ),
          resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
            registryRepository,
            syncRepository,
          ),
          databaseSyncRepository: syncRepository,
          linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
          unlockDatabaseUseCase: UnlockDatabaseUseCase(),
          createDatabaseUseCase: CreateDatabaseUseCase(
            databaseFileRepository: databaseImportService,
          ),
          appleAutofillV2Coordinator: appleAutofillV2Coordinator,
        );
      });

      Future<List<String>> managedFiles(String sub) async {
        final dir = Directory('${tempDir.path}/$sub');
        if (!await dir.exists()) return const [];
        return dir
            .listSync()
            .map((entity) => entity.path)
            .toList(growable: false);
      }

      Future<void> seedPriorState() async {
        final activePath = await _writeManagedDatabase(tempDir, 'prior.kdbx');
        registryRepository.records = [
          _record(id: 'db-prior', path: activePath),
        ];
        registryRepository.activeId = 'db-prior';
        secureDataSource.passwords['db-prior'] = 'prior-secret';
        sessionSecretHolder.set('prior-secret');
      }

      Future<void> expectNothingCommitted({
        required int expectedDatabaseCount,
      }) async {
        expect(
          await managedFiles('databases'),
          hasLength(expectedDatabaseCount),
        );
        expect(await managedFiles('keys'), isEmpty);
        expect(registryRepository.records.map((r) => r.databaseId), [
          'db-prior',
        ]);
        expect(registryRepository.activeId, 'db-prior');
        expect(securityRepository.profiles, isEmpty);
        expect(secureDataSource.passwords, {'db-prior': 'prior-secret'});
        expect(
          syncRepository.mappings,
          isEmpty,
          reason: 'no sync mapping may be created by a failed create',
        );
        expect(sessionSecretHolder.read(), 'prior-secret');
      }

      test('registry upsert failure rolls everything back', () async {
        await seedPriorState();
        registryRepository.failNextUpsert = true;

        await expectLater(
          realCoordinator.createNewDatabase(
            databaseFileName: 'fresh.kdbx',
            password: '',
            biometricProtectionEnabled: false,
            generateKeyFile: true,
          ),
          throwsException,
        );

        await expectNothingCommitted(expectedDatabaseCount: 1);
      });

      test('security profile failure rolls everything back', () async {
        await seedPriorState();
        securityRepository.failNextSave = true;

        await expectLater(
          realCoordinator.createNewDatabase(
            databaseFileName: 'fresh.kdbx',
            password: 'fresh-secret',
            biometricProtectionEnabled: false,
            generateKeyFile: true,
          ),
          throwsException,
        );

        await expectNothingCommitted(expectedDatabaseCount: 1);
      });

      test('keystore failure during biometric persistence keeps the vault, '
          'withdraws the flag and reports the notice (spec 025)', () async {
        await seedPriorState();
        secureDataSource.failNextSaveMasterPassword = true;

        final result = await realCoordinator.createNewDatabase(
          databaseFileName: 'fresh.kdbx',
          password: 'fresh-secret',
          biometricProtectionEnabled: true,
          generateKeyFile: false,
        );

        expect(result.status, DatabaseSessionStatus.success);
        expect(result.openVault, isTrue);
        expect(result.message, biometricsNotEnabledNotice);
        final created = registryRepository.records.firstWhere(
          (r) => r.databaseId != 'db-prior',
        );
        final profile = securityRepository.profiles[created.databaseId]!;
        expect(profile.biometricProtectionEnabled, isFalse);
        expect(profile.biometricOfferAnswered, isTrue);
        expect(secureDataSource.passwords.keys, ['db-prior']);
        expect(sessionSecretHolder.read(), 'fresh-secret');
      });

      test('T006: the user-selected key file survives every failure', () async {
        await seedPriorState();
        final selectedKey = File('${tempDir.path}/picked/user.key');
        await selectedKey.create(recursive: true);
        await selectedKey.writeAsBytes(const [7, 7, 7], flush: true);
        securityRepository.failNextSave = true;

        await expectLater(
          realCoordinator.createNewDatabase(
            databaseFileName: 'fresh.kdbx',
            password: '',
            keyFilePath: selectedKey.path,
            biometricProtectionEnabled: false,
            generateKeyFile: false,
          ),
          throwsException,
        );

        expect(await selectedKey.exists(), isTrue);
        expect(await selectedKey.readAsBytes(), const [7, 7, 7]);
        expect(await managedFiles('databases'), hasLength(1));
        expect(registryRepository.activeId, 'db-prior');
      });

      test('FR-11: biometric activation without a password is refused before '
          'anything is created', () async {
        await seedPriorState();

        final result = await realCoordinator.createNewDatabase(
          databaseFileName: 'fresh.kdbx',
          password: '',
          biometricProtectionEnabled: true,
          generateKeyFile: true,
        );

        expect(result.status, DatabaseSessionStatus.error);
        expect(result.message, contains('master password'));
        await expectNothingCommitted(expectedDatabaseCount: 1);
      });

      test('a successful key-only create holds the empty password like a '
          'manual key-only unlock and never writes to the secure store '
          '(AC-6)', () async {
        await seedPriorState();

        final result = await realCoordinator.createNewDatabase(
          databaseFileName: 'fresh.kdbx',
          password: '',
          biometricProtectionEnabled: false,
          generateKeyFile: true,
        );

        expect(result.status, DatabaseSessionStatus.success);
        expect(result.openVault, isTrue);
        expect(sessionSecretHolder.read(), '');
        expect(secureDataSource.passwords, {'db-prior': 'prior-secret'});
        expect(await managedFiles('keys'), hasLength(1));
      });

      test('a created database marks the biometric offer answered whether '
          'the switch was on or off', () async {
        await seedPriorState();

        final result = await realCoordinator.createNewDatabase(
          databaseFileName: 'fresh.kdbx',
          password: 'fresh-secret',
          biometricProtectionEnabled: false,
          generateKeyFile: false,
        );

        expect(result.message, isNull);
        final created = registryRepository.records.firstWhere(
          (r) => r.databaseId != 'db-prior',
        );
        expect(
          securityRepository
              .profiles[created.databaseId]!
              .biometricOfferAnswered,
          isTrue,
        );
      });

      group('create on Google Drive (spec 025 FR-C5)', () {
        test('links once with a null id and the .kdbx name, then stamps the '
            'record drive', () async {
          await seedPriorState();
          syncRepository.linkCalls.clear();

          final result = await realCoordinator.createNewDatabase(
            databaseFileName: 'Personal',
            password: 'fresh-secret',
            biometricProtectionEnabled: false,
            generateKeyFile: false,
            createOnRemote: true,
          );

          expect(result.status, DatabaseSessionStatus.success);
          expect(result.message, isNull);
          expect(syncRepository.linkCalls, hasLength(1));
          expect(syncRepository.linkCalls.single.remoteFileId, isNull);
          expect(
            syncRepository.linkCalls.single.remoteFileName,
            'Personal.kdbx',
          );
          final created = registryRepository.records.firstWhere(
            (r) => r.databaseId != 'db-prior',
          );
          expect(created.sourceType, DatabaseSourceType.drive);
          expect(created.sourceRef, 'remote-id');
          expect(syncRepository.mappings, hasLength(1));
        });

        for (final failure in <Object>[
          Exception('boom'),
          const CloudStorageException(
            CloudStorageErrorCode.authorizationRequired,
          ),
        ]) {
          test('a link failure (${failure.runtimeType}) keeps the local '
              'vault, session and profile and returns the notice', () async {
            await seedPriorState();
            syncRepository.linkError = failure;

            final result = await realCoordinator.createNewDatabase(
              databaseFileName: 'fresh.kdbx',
              password: 'fresh-secret',
              biometricProtectionEnabled: false,
              generateKeyFile: false,
              createOnRemote: true,
            );

            expect(result.status, DatabaseSessionStatus.success);
            expect(result.openVault, isTrue);
            expect(result.message, remoteCreateFailedNotice);
            expect(await managedFiles('databases'), hasLength(2));
            final created = registryRepository.records.firstWhere(
              (r) => r.databaseId != 'db-prior',
            );
            expect(created.sourceType, DatabaseSourceType.created);
            expect(securityRepository.profiles[created.databaseId], isNotNull);
            expect(registryRepository.activeId, created.databaseId);
            expect(sessionSecretHolder.read(), 'fresh-secret');
            expect(syncRepository.mappings, isEmpty);
          });
        }

        test('a local create never touches the sync repository', () async {
          await seedPriorState();
          syncRepository.linkCalls.clear();

          await realCoordinator.createNewDatabase(
            databaseFileName: 'fresh.kdbx',
            password: 'fresh-secret',
            biometricProtectionEnabled: false,
            generateKeyFile: false,
          );

          expect(syncRepository.linkCalls, isEmpty);
        });
      });

      test('connectRemoteAccount signs in and reads the account; a refused '
          'sign-in yields null', () async {
        expect(await realCoordinator.connectRemoteAccount(), isNotNull);
        expect(syncRepository.connectCalls, 1);

        syncRepository.connected = false;
        syncRepository.connectError = Exception('cancelled');
        expect(await realCoordinator.connectRemoteAccount(), isNull);
      });
    });
  });
}

Future<String> _prepareDriveDuplicate(
  Directory root,
  _FakeRegistryRepository registryRepository,
  _FakeSyncRepository syncRepository,
) async {
  final existingPath = await _writeManagedDatabase(root, 'existing.kdbx');
  registryRepository.records = [
    DatabaseRecord(
      databaseId: 'db-existing',
      canonicalPath: existingPath,
      displayName: 'existing.kdbx',
      sourceType: DatabaseSourceType.drive,
      sourceRef: 'remote-id',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  ];
  syncRepository.downloadBytes = Uint8List.fromList([
    0x03,
    0xD9,
    0xA2,
    0x9A,
    0x67,
    0xFB,
    0x4B,
    0xB5,
    ...utf8.encode('downloaded'),
  ]);
  syncRepository.mappings[existingPath] = DatabaseSyncMapping(
    databasePath: existingPath,
    providerId: 'google_drive',
    remoteFileId: 'old-remote',
    remoteFileName: 'old.kdbx',
    lastSyncAt: null,
    autoSyncEnabled: true,
  );
  return existingPath;
}

Future<String> _writeManagedDatabase(Directory root, String fileName) async {
  // `p.join`, not interpolation: production returns this path built with
  // `p.join`, so an interpolated `/` could never equal it on Windows. The
  // fixture is otherwise identical.
  final directory = Directory(p.join(root.path, 'databases'));
  await directory.create(recursive: true);
  final path = p.join(directory.path, fileName);
  await File(path).writeAsBytes(<int>[
    0x03,
    0xD9,
    0xA2,
    0x9A,
    0x67,
    0xFB,
    0x4B,
    0xB5,
    ...utf8.encode(fileName),
  ], flush: true);
  return path;
}

DatabaseRecord _record({
  required String id,
  required String path,
  DateTime? lastOpenedAt,
  String? fileHash,
  DatabaseSourceType sourceType = DatabaseSourceType.local,
}) {
  return DatabaseRecord(
    databaseId: id,
    canonicalPath: path,
    displayName: p.basename(path),
    sourceType: sourceType,
    fileHash: fileHash,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    lastOpenedAt: lastOpenedAt,
  );
}

class _FailingCreateDatabaseUseCase extends CreateDatabaseUseCase {
  _FailingCreateDatabaseUseCase({required super.databaseFileRepository});

  @override
  Future<CreateDatabaseResult?> call(CreateDatabaseRequest request) async {
    throw Exception('Simulated create failure.');
  }
}

class _StubCreateDatabaseUseCase extends CreateDatabaseUseCase {
  _StubCreateDatabaseUseCase({
    required super.databaseFileRepository,
    required this.databasePath,
  });

  final String databasePath;

  @override
  Future<CreateDatabaseResult?> call(CreateDatabaseRequest request) async {
    return CreateDatabaseResult(
      databasePath: databasePath,
      fileHash: 'created-hash',
    );
  }
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

class _FakeLocalDataSource implements LocalDataSource {
  String? selectedKeyFilePath;
  bool autofillPromptSeen = false;

  @override
  Future<bool> getAutofillPromptSeen() async => autofillPromptSeen;

  @override
  Future<void> setAutofillPromptSeen(bool seen) async {
    autofillPromptSeen = seen;
  }
}

class _FakeRegistryRepository implements DatabaseRegistryRepository {
  List<DatabaseRecord> records = [];
  String? activeId;
  bool failNextUpsert = false;
  bool failNextSetActive = false;

  /// Runs on every upsert, before it is applied (spec 025 T201 observes the
  /// replace backup at the instant the commit is still reversible).
  void Function()? onUpsert;

  @override
  Future<DatabaseRecord?> findByHash(String fileHash) async {
    for (final record in records) {
      if (record.fileHash == fileHash) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<DatabaseRecord?> findBySource({
    required DatabaseSourceType sourceType,
    required String sourceRef,
  }) async {
    for (final record in records) {
      if (record.sourceType == sourceType && record.sourceRef == sourceRef) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<String?> getActive() async => activeId;

  @override
  Future<DatabaseRecord?> getById(String databaseId) async {
    for (final record in records) {
      if (record.databaseId == databaseId) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<List<DatabaseRecord>> list() async => records;

  @override
  Future<void> remove(String databaseId) async {
    records = records
        .where((record) => record.databaseId != databaseId)
        .toList(growable: false);
  }

  @override
  Future<void> setActive(String? databaseId) async {
    if (failNextSetActive) {
      failNextSetActive = false;
      throw Exception('Simulated active registry failure.');
    }
    activeId = databaseId;
  }

  @override
  Future<void> upsert(DatabaseRecord record) async {
    onUpsert?.call();
    if (failNextUpsert) {
      failNextUpsert = false;
      throw Exception('Simulated registry upsert failure.');
    }
    records = [
      ...records.where((item) => item.databaseId != record.databaseId),
      record,
    ];
  }
}

class _FakeSecurityRepository implements DatabaseSecurityRepository {
  final Map<String, DatabaseSecurityProfile> profiles =
      <String, DatabaseSecurityProfile>{};
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
      throw Exception('Simulated profile save failure.');
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
  bool failNextSaveMasterPassword = false;

  @override
  Future<void> clearMasterPassword(String databaseId) async {
    passwords.remove(databaseId);
  }

  @override
  Future<String?> getMasterPassword(String databaseId) async =>
      passwords[databaseId];

  @override
  Future<void> saveMasterPassword(String databaseId, String password) async {
    if (failNextSaveMasterPassword) {
      failNextSaveMasterPassword = false;
      throw Exception('Simulated keystore failure.');
    }
    passwords[databaseId] = password;
  }
}

class _FakeAppleAutofillV2Coordinator
    implements AppleAutofillV2CoordinatorContract {
  int clearCallCount = 0;

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
  }) async {}

  @override
  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  }) async {
    return const [];
  }
}

class _FakeSyncRepository implements DatabaseSyncRepository {
  Uint8List downloadBytes = Uint8List(0);
  final Map<String, DatabaseSyncMapping> mappings = {};
  List<RemoteFile> remoteFiles = const [];
  bool connected = false;
  int connectCalls = 0;
  _MappingMoveFailurePoint? failNextMoveAt;
  Object? linkError;
  final List<({String? remoteFileId, String? remoteFileName})> linkCalls = [];

  /// Connection calls in order, for the switch-account sequencing test.
  final List<String> connectionCalls = [];
  Object? connectError;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    connectionCalls.add('connect');
    final error = connectError;
    if (error != null) throw error;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connectionCalls.add('disconnect');
    connected = false;
  }

  @override
  Future<Uint8List> downloadRemoteFile(String fileId) async {
    return downloadBytes;
  }

  @override
  Future<DatabaseSyncMapping?> getMapping(String databasePath) async {
    return mappings[databasePath];
  }

  @override
  Future<List<DatabaseSyncMapping>> getAllMappings() async =>
      mappings.values.toList(growable: false);

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<DatabaseSyncMapping> linkDatabaseToRemote({
    required String databasePath,
    String? remoteFileId,
    String? remoteFileName,
  }) async {
    linkCalls.add((remoteFileId: remoteFileId, remoteFileName: remoteFileName));
    final linkFailure = linkError;
    if (linkFailure != null) throw linkFailure;
    final mapping = DatabaseSyncMapping(
      databasePath: databasePath,
      providerId: 'google_drive',
      remoteFileId: remoteFileId ?? 'remote-id',
      remoteFileName: remoteFileName ?? 'remote.kdbx',
      lastSyncAt: null,
      autoSyncEnabled: true,
    );
    mappings[databasePath] = mapping;
    return mapping;
  }

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) async {
    return remoteFiles;
  }

  @override
  Future<DatabaseSyncMappingPathMove> moveMappingPath({
    required String fromDatabasePath,
    required String toDatabasePath,
  }) async {
    final move = DatabaseSyncMappingPathMove(
      fromDatabasePath: fromDatabasePath,
      toDatabasePath: toDatabasePath,
      sourceBefore: mappings[fromDatabasePath],
      destinationBefore: mappings[toDatabasePath],
    );
    final failurePoint = failNextMoveAt;
    failNextMoveAt = null;
    try {
      if (failurePoint == _MappingMoveFailurePoint.beforeMutation) {
        throw Exception('Simulated mapping move failure before mutation.');
      }
      final mapping = mappings.remove(fromDatabasePath);
      if (failurePoint == _MappingMoveFailurePoint.afterSourceRemoval) {
        throw Exception('Simulated mapping move failure after source removal.');
      }
      if (mapping != null) {
        mappings[toDatabasePath] = mapping.copyWith(
          databasePath: toDatabasePath,
        );
      }
      if (failurePoint == _MappingMoveFailurePoint.afterDestinationWrite) {
        throw Exception(
          'Simulated mapping move failure after destination write.',
        );
      }
      return move;
    } catch (_) {
      // Mirrors the real data source: a failed move never leaves the
      // in-memory mapping half-mutated relative to the returned token.
      await restoreMappingPathMove(move);
      rethrow;
    }
  }

  @override
  Future<void> restoreMappingPathMove(DatabaseSyncMappingPathMove move) async {
    mappings
      ..remove(move.fromDatabasePath)
      ..remove(move.toDatabasePath);
    if (move.sourceBefore != null) {
      mappings[move.fromDatabasePath] = move.sourceBefore!;
    }
    if (move.destinationBefore != null) {
      mappings[move.toDatabasePath] = move.destinationBefore!;
    }
  }

  @override
  Future<void> removeMapping(String databasePath) async {
    mappings.remove(databasePath);
  }

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

enum _MappingMoveFailurePoint {
  beforeMutation,
  afterSourceRemoval,
  afterDestinationWrite,
}
