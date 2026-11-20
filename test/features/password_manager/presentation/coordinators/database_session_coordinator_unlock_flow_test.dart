// Spec 025 S1: unlock bootstrap (source/account/missing), missing-file
// re-download, and the one-time biometric offer with its immediate keystore
// write; S4: the selection list's source grouping. Built on the in-memory
// domain fakes, like the bloc tests.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/local_data_source.dart';
import 'package:password_manager/features/password_manager/data/datasources/secure_data_source.dart';
import 'package:password_manager/features/password_manager/data/services/database_path_mutex.dart';
import 'package:password_manager/features/password_manager/data/services/database_rename_transaction.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/errors/database_access_failure.dart';
import 'package:password_manager/features/password_manager/domain/models/database_dedup_result.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/vault_session_coordinator.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_transaction.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/get_active_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/resolve_database_duplicate_usecase.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';

import 'fake_database_ports.dart';

void main() {
  late FakeDatabaseFileRepository files;
  late FakeDatabaseSessionRepository keystore;
  late FakeDatabaseRegistryRepository registry;
  late FakeDatabaseSecurityRepository security;
  late FakeDatabaseSyncRepository sync;
  late FakeUnlockDatabaseUseCase unlock;
  late SessionSecretHolder secret;
  late DatabaseSessionCoordinator coordinator;

  DatabaseRecord record(String id, String path) => DatabaseRecord(
    databaseId: id,
    canonicalPath: path,
    displayName: 'Vault $id',
    sourceType: DatabaseSourceType.local,
    fileHash: 'old-hash',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  DatabaseSyncMapping mapping(String path) => DatabaseSyncMapping(
    databasePath: path,
    providerId: 'google_drive',
    remoteFileId: 'remote-1',
    remoteFileName: 'vault.kdbx',
  );

  setUp(() {
    files = FakeDatabaseFileRepository();
    keystore = FakeDatabaseSessionRepository();
    registry = FakeDatabaseRegistryRepository();
    security = FakeDatabaseSecurityRepository();
    sync = FakeDatabaseSyncRepository();
    unlock = FakeUnlockDatabaseUseCase();
    secret = SessionSecretHolder();
    coordinator = DatabaseSessionCoordinator(
      sessionSecretHolder: secret,
      databaseFileRepository: files,
      databaseSessionRepository: keystore,
      databaseRegistryRepository: registry,
      databaseSecurityRepository: security,
      databaseSyncRepository: sync,
      linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(sync),
      getActiveDatabaseUseCase: GetActiveDatabaseUseCase(registry),
      resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
        registry,
        sync,
      ),
      unlockDatabaseUseCase: unlock,
      createDatabaseUseCase: CreateDatabaseUseCase(
        databaseFileRepository: files,
      ),
    );
  });

  group('selection list grouping (spec 025 FR-L2)', () {
    const account = StorageAccountSummary(
      displayLabel: 'mara@example.com',
      email: 'mara@example.com',
    );

    setUp(() {
      // Two records: no single-database auto-open, so the list is returned.
      registry.records = [
        record('db-1', '/tmp/a.kdbx'),
        record('db-2', '/tmp/b.kdbx'),
      ];
      files.existingPaths.addAll(['/tmp/a.kdbx', '/tmp/b.kdbx']);
      sync.account = account;
    });

    test(
      'a local record linked later is remote; an unlinked one is not',
      () async {
        sync.mappings['/tmp/a.kdbx'] = mapping('/tmp/a.kdbx')
            .copyWith(lastSyncAt: DateTime(2026, 3, 1));
        sync.connected = true;

        final result = await coordinator.checkInitialDatabase();

        final byId = {for (final item in result.items) item.databaseId: item};
        expect(byId['db-1']!.sourceType, DatabaseSourceType.local);
        expect(byId['db-1']!.remoteProviderId, 'google_drive');
        expect(byId['db-1']!.lastSyncAt, DateTime(2026, 3, 1));
        expect(byId['db-2']!.remoteProviderId, isNull);
        expect(result.remoteAccount, account);
      },
    );

    test('a mapping lookup failure degrades every row to local', () async {
      sync.mappings['/tmp/a.kdbx'] = mapping('/tmp/a.kdbx');
      sync.connected = true;
      sync.mappingError = Exception('mapping store unreadable');

      final result = await coordinator.checkInitialDatabase();

      expect(result.items, hasLength(2));
      expect(
        result.items.map((item) => item.remoteProviderId),
        everyElement(isNull),
      );
      expect(result.remoteAccount, isNull);
    });

    test('the account is read only when already connected, never by '
        'connecting', () async {
      sync.mappings['/tmp/a.kdbx'] = mapping('/tmp/a.kdbx');

      final result = await coordinator.checkInitialDatabase();

      expect(
        result.items.first.remoteProviderId ??
            result.items.last.remoteProviderId,
        'google_drive',
      );
      expect(result.remoteAccount, isNull);
      expect(sync.connectCalls, 0);
    });

    test('an account lookup failure yields the bare header', () async {
      sync.mappings['/tmp/a.kdbx'] = mapping('/tmp/a.kdbx');
      sync.connected = true;
      sync.accountError = Exception('offline');

      final result = await coordinator.checkInitialDatabase();

      expect(result.remoteAccount, isNull);
      expect(sync.connectCalls, 0);
    });

    test('no remote row means no account lookup result', () async {
      sync.connected = true;

      final result = await coordinator.checkInitialDatabase();

      expect(result.remoteAccount, isNull);
    });
  });

  group('initializeUnlock source and account (FR-U2)', () {
    setUp(() {
      registry.records = [record('db-1', '/tmp/a.kdbx')];
      files.existingPaths.add('/tmp/a.kdbx');
    });

    Future<UnlockBootstrapResult> boot() => coordinator.initializeUnlock(
      databasePath: '/tmp/a.kdbx',
      biometricAvailable: false,
    );

    test('a mapped database is remote, whatever its source type', () async {
      sync.mappings['/tmp/a.kdbx'] = mapping('/tmp/a.kdbx');
      sync.connected = true;
      sync.account = const StorageAccountSummary(
        displayLabel: 'mara@example.com',
        email: 'mara@example.com',
      );

      final result = await boot();

      expect(result.isRemoteLinked, isTrue);
      expect(result.remoteAccount?.email, 'mara@example.com');
      expect(result.databaseId, 'db-1');
    });

    test('an unmapped database is local with no account', () async {
      sync.connected = true;

      final result = await boot();

      expect(result.isRemoteLinked, isFalse);
      expect(result.remoteAccount, isNull);
    });

    test('a failing account lookup degrades to no account', () async {
      sync.mappings['/tmp/a.kdbx'] = mapping('/tmp/a.kdbx');
      sync.connected = true;
      sync.accountError = StateError('offline');

      final result = await boot();

      expect(result.isRemoteLinked, isTrue);
      expect(result.remoteAccount, isNull);
    });

    test('a failing mapping lookup degrades to local', () async {
      sync.mappingError = StateError('unreadable');

      final result = await boot();

      expect(result.isRemoteLinked, isFalse);
    });

    test('never connects and never asks for the account while '
        'disconnected', () async {
      sync.mappings['/tmp/a.kdbx'] = mapping('/tmp/a.kdbx');
      sync.connected = false;

      final result = await boot();

      expect(result.isRemoteLinked, isTrue);
      expect(result.remoteAccount, isNull);
      expect(sync.connectCalls, 0);
    });

    test('flags a registered file that is gone', () async {
      files.existingPaths.clear();

      expect((await boot()).fileMissing, isTrue);
    });
  });

  group('redownloadMissingDatabase (FR-U5)', () {
    const path = '/tmp/a.kdbx';

    setUp(() {
      registry.records = [record('db-1', path)];
      security.profiles['db-1'] = const DatabaseSecurityProfile(
        databaseId: 'db-1',
        keyFilePath: '/tmp/a.key',
        biometricProtectionEnabled: true,
      );
      sync.downloadBytes = Uint8List.fromList(const [1, 2, 3]);
      files.stageResult = StagedDatabaseImport(
        imported: const DatabaseImportResult(
          path: '/tmp/staged.kdbx',
          fileName: 'vault.kdbx',
          fileHash: 'new-hash',
          sourceType: DatabaseSourceType.drive,
          sourceRef: 'remote-1',
        ),
        preferredFileName: 'vault.kdbx',
      );
    });

    test('commits to the same path and keeps id, profile and mapping, '
        'updating only the hash', () async {
      sync.mappings[path] = mapping(path);

      final result = await coordinator.redownloadMissingDatabase('db-1');

      expect(result.status, DatabaseSessionStatus.success);
      expect(result.path, path);
      expect(files.commitTargets, [path]);
      final saved = registry.records.single;
      expect(saved.databaseId, 'db-1');
      expect(saved.canonicalPath, path);
      expect(saved.fileHash, 'new-hash');
      expect(security.profiles['db-1']!.keyFilePath, '/tmp/a.key');
      expect(sync.mappings[path]!.remoteFileId, 'remote-1');
    });

    test('a download failure mutates nothing', () async {
      sync.mappings[path] = mapping(path);
      files.stageError = StateError('bad bytes');

      await expectLater(
        coordinator.redownloadMissingDatabase('db-1'),
        throwsStateError,
      );

      expect(files.commitTargets, isEmpty);
      expect(registry.records.single.fileHash, 'old-hash');
    });

    test('a commit failure discards the staged file and mutates '
        'nothing', () async {
      sync.mappings[path] = mapping(path);
      files.commitError = StateError('disk full');

      await expectLater(
        coordinator.redownloadMissingDatabase('db-1'),
        throwsStateError,
      );

      expect(files.discarded, hasLength(1));
      expect(registry.records.single.fileHash, 'old-hash');
    });

    test('a registry failure after the commit rolls the file back', () async {
      sync.mappings[path] = mapping(path);
      final failing = _FailingUpsertRegistry()..records = registry.records;
      final rolling = DatabaseSessionCoordinator(
        sessionSecretHolder: secret,
        databaseFileRepository: files,
        databaseSessionRepository: keystore,
        databaseRegistryRepository: failing,
        databaseSecurityRepository: security,
        databaseSyncRepository: sync,
        linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(sync),
        getActiveDatabaseUseCase: GetActiveDatabaseUseCase(failing),
        resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
          failing,
          sync,
        ),
        unlockDatabaseUseCase: unlock,
        createDatabaseUseCase: CreateDatabaseUseCase(
          databaseFileRepository: files,
        ),
      );

      await expectLater(
        rolling.redownloadMissingDatabase('db-1'),
        throwsStateError,
      );

      expect(files.rolledBack, hasLength(1));
      expect(failing.records.single.fileHash, 'old-hash');
    });

    test('no mapping is a typed error and nothing is fetched', () async {
      final result = await coordinator.redownloadMissingDatabase('db-1');

      expect(result.status, DatabaseSessionStatus.error);
      expect(files.commitTargets, isEmpty);
    });
  });

  group('biometric offer (FR-U6, FR-U7)', () {
    const path = '/tmp/a.kdbx';

    setUp(() {
      registry.records = [record('db-a', path), record('db-b', '/tmp/b.kdbx')];
      secret.set('pw-a');
    });

    Future<bool> shouldOffer({bool available = true}) => coordinator
        .shouldOfferBiometricUnlock(path, biometricAvailable: available);

    test('offered when nothing blocks it', () async {
      expect(await shouldOffer(), isTrue);
    });

    test('not offered when the capability is off or no sensor', () async {
      expect(await shouldOffer(available: false), isFalse);
    });

    test('not offered when biometrics are already enabled', () async {
      security.profiles['db-a'] = const DatabaseSecurityProfile(
        databaseId: 'db-a',
        biometricProtectionEnabled: true,
      );
      expect(await shouldOffer(), isFalse);
    });

    test('not offered once answered', () async {
      security.profiles['db-a'] = const DatabaseSecurityProfile(
        databaseId: 'db-a',
        biometricOfferAnswered: true,
      );
      expect(await shouldOffer(), isFalse);
    });

    test('not offered for a key-only vault (empty password)', () async {
      secret.set('');
      expect(await shouldOffer(), isFalse);
    });

    test('not offered when locked (no session secret)', () async {
      secret.clear();
      expect(await shouldOffer(), isFalse);
    });

    test('enable writes exactly one entry, for that database only', () async {
      final ok = await coordinator.answerBiometricOffer(path, enable: true);

      expect(ok, isTrue);
      expect(keystore.masterPasswords, {'db-a': 'pw-a'});
      final profile = security.profiles['db-a']!;
      expect(profile.biometricProtectionEnabled, isTrue);
      expect(profile.biometricOfferAnswered, isTrue);
      expect(await shouldOffer(), isFalse);
    });

    test('not now writes nothing and is never asked again', () async {
      final ok = await coordinator.answerBiometricOffer(path, enable: false);

      expect(ok, isTrue);
      expect(keystore.masterPasswords, isEmpty);
      final profile = security.profiles['db-a']!;
      expect(profile.biometricProtectionEnabled, isFalse);
      expect(profile.biometricOfferAnswered, isTrue);
      expect(await shouldOffer(), isFalse);
    });

    test('enable with no session secret stores the flag only', () async {
      secret.clear();

      final ok = await coordinator.updateBiometricProtection(
        databasePath: path,
        enabled: true,
      );

      expect(ok, isTrue);
      expect(keystore.masterPasswords, isEmpty);
      expect(security.profiles['db-a']!.biometricProtectionEnabled, isTrue);
    });

    test('a keystore failure reports false, keeps the answer and restores '
        'the flag', () async {
      keystore.saveError = StateError('keystore unavailable');

      final ok = await coordinator.answerBiometricOffer(path, enable: true);

      expect(ok, isFalse);
      expect(keystore.masterPasswords, isEmpty);
      final profile = security.profiles['db-a']!;
      expect(profile.biometricProtectionEnabled, isFalse);
      expect(profile.biometricOfferAnswered, isTrue);
    });

    test(
      'enabling one database never touches another (spec 011 AC-5)',
      () async {
        keystore.masterPasswords['db-b'] = 'pw-b';

        await coordinator.answerBiometricOffer(path, enable: true);

        expect(keystore.masterPasswords, {'db-a': 'pw-a', 'db-b': 'pw-b'});
      },
    );
  });

  group('the unlocked database is the active one (finding F1)', () {
    const a = '/tmp/a.kdbx';
    const b = '/tmp/b.kdbx';

    // What `VaultBloc` reads when the vault opens: the ACTIVE database's
    // profile, through the live `VaultSessionCoordinator`.
    Future<String?> keyFileTheVaultReads() {
      final unused = _Unused();
      return VaultSessionCoordinator(
        databaseFileRepository: files,
        databaseRenameTransaction: DatabaseRenameTransaction(
          mutex: DatabasePathMutex(),
          syncRepository: sync,
        ),
        sessionSecretHolder: secret,
        localDataSource: unused,
        databaseRegistryRepository: registry,
        databaseSecurityRepository: security,
        secureDataSource: unused,
        databaseSyncRepository: sync,
        vaultKdbxService: unused,
        appleAutofillV2Coordinator: unused,
      ).getSelectedKeyFilePath();
    }

    setUp(() {
      registry
        ..records = [record('db-a', a), record('db-b', b)]
        ..activeId = 'db-b';
      // `a` is the missing row: only `b` and the two key files are on disk.
      files.existingPaths.addAll([b, '/keys/a.key', '/keys/b.key']);
      security.profiles
        ..['db-a'] = const DatabaseSecurityProfile(
          databaseId: 'db-a',
          keyFilePath: '/keys/a.key',
        )
        ..['db-b'] = const DatabaseSecurityProfile(
          databaseId: 'db-b',
          keyFilePath: '/keys/b.key',
        );
      keystore.masterPasswords['db-a'] = 'pw-a';
    });

    test('missing row, download again, unlock: the vault reads this '
        "database's key file, not the previously active one's", () async {
      sync.mappings[a] = mapping(a);
      sync.downloadBytes = Uint8List.fromList(const [1, 2, 3]);
      files.stageResult = StagedDatabaseImport(
        imported: const DatabaseImportResult(
          path: '/tmp/staged.kdbx',
          fileName: 'vault.kdbx',
          fileHash: 'new-hash',
          sourceType: DatabaseSourceType.drive,
          sourceRef: 'remote-1',
        ),
        preferredFileName: 'vault.kdbx',
      );

      // The row tap opens Unlock with no bloc event, so nothing has made
      // `a` active by the time the user repairs and unlocks it.
      final boot = await coordinator.initializeUnlock(
        databasePath: a,
        biometricAvailable: false,
      );
      expect(boot.fileMissing, isTrue);
      await coordinator.redownloadMissingDatabase('db-a');
      expect(await keyFileTheVaultReads(), '/keys/b.key');

      await coordinator.unlockWithManualCredentials(
        databasePath: a,
        password: 'pw-a',
        keyFilePath: '/keys/a.key',
      );

      expect(registry.activeId, 'db-a');
      expect(await keyFileTheVaultReads(), '/keys/a.key');
      expect(security.profiles['db-b']!.keyFilePath, '/keys/b.key');
    });

    test('a stored-credentials (biometric) unlock activates it too', () async {
      files.existingPaths.add(a);

      await coordinator.unlockWithStoredCredentials(
        databasePath: a,
        keyFilePath: '/keys/a.key',
      );

      expect(registry.activeId, 'db-a');
      expect(await keyFileTheVaultReads(), '/keys/a.key');
    });

    test('unlocking the database that is already active writes nothing to '
        'the registry', () async {
      final counting = _CountingRegistry()
        ..records = registry.records
        ..activeId = 'db-b';
      final same = DatabaseSessionCoordinator(
        sessionSecretHolder: secret,
        databaseFileRepository: files,
        databaseSessionRepository: keystore,
        databaseRegistryRepository: counting,
        databaseSecurityRepository: security,
        databaseSyncRepository: sync,
        linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(sync),
        getActiveDatabaseUseCase: GetActiveDatabaseUseCase(counting),
        resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
          counting,
          sync,
        ),
        unlockDatabaseUseCase: unlock,
        createDatabaseUseCase: CreateDatabaseUseCase(
          databaseFileRepository: files,
        ),
      );

      await same.unlockWithManualCredentials(
        databasePath: b,
        password: 'pw-b',
        keyFilePath: '/keys/b.key',
      );

      expect(counting.setActiveCalls, 0);
    });
  });

  group('persistence after a successful decrypt (finding F2, D10)', () {
    const path = '/tmp/a.kdbx';

    setUp(() => registry.records = [record('db-a', path)]);

    Future<String?> unlockManually({String password = 'pw'}) =>
        coordinator.unlockWithManualCredentials(
          databasePath: path,
          password: password,
          keyFilePath: null,
        );

    test('a keystore failure is the biometrics notice, the vault is '
        'unlocked', () async {
      security.profiles['db-a'] = const DatabaseSecurityProfile(
        databaseId: 'db-a',
        biometricProtectionEnabled: true,
      );
      keystore.saveError = StateError('keystore unavailable');

      expect(await unlockManually(), biometricsNotEnabledNotice);
      expect(secret.hasSecret, isTrue, reason: 'the vault is unlocked');
    });

    test('a profile write failure is the settings notice, never a failed '
        'unlock', () async {
      security.saveError = StateError('metadata store unavailable');

      expect(await unlockManually(), unlockSettingsNotSavedNotice);
      expect(secret.read(), 'pw');
      expect(unlock.callCount, 1);
    });

    test('nothing to report when nothing failed', () async {
      expect(await unlockManually(), isNull);
    });

    test('a wrong credential is still a failure and leaves no secret', () {
      unlock.error = const InvalidCredentialsFailure();

      expect(unlockManually(), throwsA(isA<InvalidCredentialsFailure>()));
      expect(secret.hasSecret, isFalse);
    });

    test('spec 011: the credential is stored only with the flag on, and an '
        'empty secret never', () async {
      await unlockManually();
      expect(keystore.masterPasswords, isEmpty, reason: 'flag off');

      security.profiles['db-a'] = const DatabaseSecurityProfile(
        databaseId: 'db-a',
        biometricProtectionEnabled: true,
      );
      await unlockManually(password: '');
      expect(keystore.masterPasswords, isEmpty, reason: 'key-only unlock');

      await unlockManually();
      expect(keystore.masterPasswords, {'db-a': 'pw'});
    });
  });

  group('updateKeyFilePath (finding F3)', () {
    const path = '/tmp/a.kdbx';

    setUp(() {
      registry.records = [record('db-a', path)];
      files.existingPaths.add('/keys/a.key');
    });

    Future<bool> pick() => coordinator.updateKeyFilePath(
      databasePath: path,
      keyFilePath: '/keys/a.key',
    );

    test('remembers the choice in the profile', () async {
      expect(await pick(), isTrue);
      expect(security.profiles['db-a']!.keyFilePath, '/keys/a.key');
    });

    test('a storage failure reports the choice was not remembered instead '
        'of throwing', () async {
      security.saveError = StateError('metadata store unavailable');

      expect(await pick(), isFalse);
    });

    test('a key file that is gone is still a typed failure', () {
      files.existingPaths.clear();

      expect(pick(), throwsA(isA<KeyFileMissingFailure>()));
    });
  });

  group('import conflicts and sync mappings (findings F5, F6)', () {
    const existingPath = '/tmp/a.kdbx';

    StagedDatabaseImport staged({
      required DatabaseSourceType sourceType,
      String? sourceRef,
    }) => StagedDatabaseImport(
      imported: DatabaseImportResult(
        path: '/tmp/staged.kdbx',
        fileName: 'Vault db-a',
        fileHash: 'incoming-hash',
        sourceType: sourceType,
        sourceRef: sourceRef,
      ),
      preferredFileName: 'Vault db-a',
    );

    setUp(() {
      registry.records = [record('db-a', existingPath)];
      files.existingPaths.add(existingPath);
    });

    test('F5: re-opening the remote file a local database was linked to '
        'from Sync is a source match', () async {
      sync.mappings[existingPath] = mapping(existingPath);
      files.stageResult = staged(
        sourceType: DatabaseSourceType.drive,
        sourceRef: 'remote-1',
      );

      final result = await coordinator.selectDriveDatabase(
        remoteProviderId: 'google_drive',
        remoteFileId: 'remote-1',
        remoteFileName: 'Other name.kdbx',
      );

      expect(result.status, DatabaseSessionStatus.duplicateDecisionRequired);
      expect(
        result.duplicatePrompt!.matchType,
        DatabaseDuplicateMatchType.source,
      );
      expect(result.duplicatePrompt!.existingRecord.databaseId, 'db-a');
      expect(registry.records, hasLength(1), reason: 'no second database');
    });

    test('F6: a name-only match on a remote-linked database cannot be '
        'replaced', () async {
      sync.mappings[existingPath] = mapping(existingPath);
      files.stageResult = staged(sourceType: DatabaseSourceType.local);

      final result = await coordinator.selectExistingDatabase(
        fileName: 'Vault db-a',
        selectedPath: '/downloads/other.kdbx',
      );

      final prompt = result.duplicatePrompt!;
      expect(prompt.matchType, DatabaseDuplicateMatchType.name);
      expect(prompt.canReplaceExisting, isFalse);

      // Even if asked anyway, the different file never lands on the path
      // that is mapped to the remote file.
      final forced = await coordinator.resolveDuplicateDecision(
        duplicatePrompt: prompt,
        decision: DatabaseDuplicateResolution.replaceExisting,
      );

      expect(forced.status, DatabaseSessionStatus.unselected);
      expect(files.commitTargets, isEmpty);
      expect(files.discarded, hasLength(1));
      expect(registry.records.single.fileHash, 'old-hash');
      expect(sync.mappings[existingPath]!.remoteFileId, 'remote-1');
    });

    test('F6: a name-only match on a local database can still be '
        'replaced', () async {
      files.stageResult = staged(sourceType: DatabaseSourceType.local);

      final result = await coordinator.selectExistingDatabase(
        fileName: 'Vault db-a',
        selectedPath: '/downloads/other.kdbx',
      );

      expect(result.duplicatePrompt!.canReplaceExisting, isTrue);
    });

    test('F6: a source match on a remote-linked database can still be '
        'replaced', () async {
      sync.mappings[existingPath] = mapping(existingPath);
      files.stageResult = staged(
        sourceType: DatabaseSourceType.drive,
        sourceRef: 'remote-1',
      );

      final result = await coordinator.selectDriveDatabase(
        remoteProviderId: 'google_drive',
        remoteFileId: 'remote-1',
        remoteFileName: 'Vault db-a',
      );

      expect(result.duplicatePrompt!.canReplaceExisting, isTrue);
    });
  });

  group('switchRemoteAccount (finding F7)', () {
    test('the account copied next to the list is the new one', () async {
      const before = StorageAccountSummary(
        displayLabel: 'old@example.com',
        email: 'old@example.com',
      );
      const after = StorageAccountSummary(
        displayLabel: 'new@example.com',
        email: 'new@example.com',
      );
      final flaky = _FlakyListRegistry()
        ..records = [
          record('db-1', '/tmp/a.kdbx'),
          record('db-2', '/tmp/b.kdbx'),
        ];
      final switching = DatabaseSessionCoordinator(
        sessionSecretHolder: secret,
        databaseFileRepository: files,
        databaseSessionRepository: keystore,
        databaseRegistryRepository: flaky,
        databaseSecurityRepository: security,
        databaseSyncRepository: sync,
        linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(sync),
        getActiveDatabaseUseCase: GetActiveDatabaseUseCase(flaky),
        resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
          flaky,
          sync,
        ),
        unlockDatabaseUseCase: unlock,
        createDatabaseUseCase: CreateDatabaseUseCase(
          databaseFileRepository: files,
        ),
      );
      files.existingPaths.addAll(['/tmp/a.kdbx', '/tmp/b.kdbx']);
      sync
        ..mappings['/tmp/a.kdbx'] = mapping('/tmp/a.kdbx')
        ..connected = true
        ..account = before;
      expect((await switching.checkInitialDatabase()).remoteAccount, before);

      sync.account = after;
      await switching.switchRemoteAccount();
      // A list reload that fails keeps whatever account was cached: it must
      // not be the one the user just signed out of.
      flaky.failList = true;

      expect((await switching.openRecentDatabase('')).remoteAccount, after);
    });
  });
}

class _FailingUpsertRegistry extends FakeDatabaseRegistryRepository {
  @override
  Future<void> upsert(DatabaseRecord record) async {
    throw StateError('registry write failed');
  }
}

class _CountingRegistry extends FakeDatabaseRegistryRepository {
  int setActiveCalls = 0;

  @override
  Future<void> setActive(String? databaseId) {
    setActiveCalls += 1;
    return super.setActive(databaseId);
  }
}

class _FlakyListRegistry extends FakeDatabaseRegistryRepository {
  bool failList = false;

  @override
  Future<List<DatabaseRecord>> list() async {
    if (failList) throw StateError('registry unreadable');
    return records;
  }
}

class _Unused
    implements
        LocalDataSource,
        SecureDataSource,
        VaultKdbxService,
        AppleAutofillV2CoordinatorContract {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}
