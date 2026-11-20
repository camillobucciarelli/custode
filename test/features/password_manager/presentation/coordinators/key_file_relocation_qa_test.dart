import 'dart:io';

import '../../data/datasources/in_memory_secure_data_source.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/database_registry_local_data_source.dart';
import 'package:password_manager/features/password_manager/data/datasources/database_security_local_data_source.dart';
import 'package:password_manager/features/password_manager/data/datasources/local_data_source.dart';
import 'package:password_manager/features/password_manager/data/datasources/secure_data_source.dart';
import 'package:password_manager/features/password_manager/data/repositories/database_registry_repository_impl.dart';
import 'package:password_manager/features/password_manager/data/repositories/database_security_repository_impl.dart';
import 'package:password_manager/features/password_manager/data/services/database_path_mutex.dart';
import 'package:password_manager/features/password_manager/data/services/database_rename_transaction.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/get_active_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/resolve_database_duplicate_usecase.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/vault_session_coordinator.dart';

import 'fake_database_ports.dart';

import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end probe: does a key-file path survive an app-container relocation
/// when read back through VaultSessionCoordinator, not just through the data
/// source? Covers both the security-profile path and the `local_state.json`
/// cache fallback used when no profile exists.
class _MutablePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _MutablePathProvider(this.basePath);

  String basePath;

  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;

  @override
  Future<String?> getApplicationSupportPath() async => basePath;
}

class _Unused
    implements
        SecureDataSource,
        DatabaseSyncRepository,
        VaultKdbxService,
        AppleAutofillV2CoordinatorContract {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory containerRoot;
  late Directory oldDocs;
  late Directory newDocs;
  late _MutablePathProvider pathProvider;

  late InMemorySecureDataSource secure;

  setUp(() async {
    secure = InMemorySecureDataSource();
    containerRoot = await Directory.systemTemp.createTemp('keyfile_e2e_');
    oldDocs = await Directory(p.join(containerRoot.path, 'UUID-A', 'Documents'))
        .create(recursive: true);
    newDocs = await Directory(p.join(containerRoot.path, 'UUID-B', 'Documents'))
        .create(recursive: true);
    pathProvider = _MutablePathProvider(oldDocs.path);
    PathProviderPlatform.instance = pathProvider;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await containerRoot.delete(recursive: true);
  });

  Future<VaultSessionCoordinator> buildCoordinator() async {
    final unused = _Unused();
    return VaultSessionCoordinator(
      databaseFileRepository: FakeDatabaseFileRepository(),
      databaseRenameTransaction: DatabaseRenameTransaction(
        mutex: DatabasePathMutex(),
        syncRepository: unused,
      ),
      sessionSecretHolder: SessionSecretHolder(),
      localDataSource: LocalDataSourceImpl(secureDataSource: secure),
      databaseRegistryRepository: DatabaseRegistryRepositoryImpl(
        localDataSource: DatabaseRegistryLocalDataSourceImpl(
          sharedPreferences: await SharedPreferences.getInstance(),
          secureDataSource: secure,
        ),
      ),
      databaseSecurityRepository: DatabaseSecurityRepositoryImpl(
        localDataSource: DatabaseSecurityLocalDataSourceImpl(
          secureDataSource: secure,
        ),
      ),
      secureDataSource: unused,
      databaseSyncRepository: unused,
      vaultKdbxService: unused,
      appleAutofillV2Coordinator: unused,
    );
  }

  /// The live coordinator behind the key manager's delete protection
  /// (`pickKeyFile` passes `getProtectedKeyFilePaths` to the sheet), over the
  /// same real registry and security stores as [buildCoordinator].
  Future<DatabaseSessionCoordinator> buildSessionCoordinator() async {
    final registry = DatabaseRegistryRepositoryImpl(
      localDataSource: DatabaseRegistryLocalDataSourceImpl(
        sharedPreferences: await SharedPreferences.getInstance(),
        secureDataSource: secure,
      ),
    );
    final files = FakeDatabaseFileRepository();
    final sync = FakeDatabaseSyncRepository();
    return DatabaseSessionCoordinator(
      sessionSecretHolder: SessionSecretHolder(),
      databaseFileRepository: files,
      databaseSessionRepository: FakeDatabaseSessionRepository(),
      databaseRegistryRepository: registry,
      databaseSecurityRepository: DatabaseSecurityRepositoryImpl(
        localDataSource: DatabaseSecurityLocalDataSourceImpl(
          secureDataSource: secure,
        ),
      ),
      databaseSyncRepository: sync,
      linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(sync),
      getActiveDatabaseUseCase: GetActiveDatabaseUseCase(registry),
      resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
        registry,
        sync,
      ),
      unlockDatabaseUseCase: FakeUnlockDatabaseUseCase(),
      createDatabaseUseCase: CreateDatabaseUseCase(
        databaseFileRepository: files,
      ),
    );
  }

  Future<void> relocate() async {
    final source = Directory(p.join(oldDocs.path, 'metadata'));
    if (await source.exists()) {
      final target = Directory(p.join(newDocs.path, 'metadata'));
      await target.create(recursive: true);
      await for (final entry in source.list(followLinks: false)) {
        if (entry is File) {
          await entry.copy(p.join(target.path, p.basename(entry.path)));
        }
      }
    }
    // Carry the key material across too, like an iOS container migration.
    final keys = Directory(p.join(oldDocs.path, 'keys'));
    if (await keys.exists()) {
      final target = await Directory(p.join(newDocs.path, 'keys'))
          .create(recursive: true);
      await for (final entry in keys.list(followLinks: false)) {
        if (entry is File) {
          await entry.copy(p.join(target.path, p.basename(entry.path)));
        }
      }
    }
    pathProvider.basePath = newDocs.path;
  }

  test('getSelectedKeyFilePath resolves the ACTIVE database profile and '
      'survives relocation (spec 014 FR-8)', () async {
    final keysDir = await Directory(p.join(oldDocs.path, 'keys'))
        .create(recursive: true);
    final keyFile = File(p.join(keysDir.path, 'vault.keyx'));
    await keyFile.writeAsString('key-material');

    final now = DateTime.utc(2024, 1, 1);
    final coordinator = await buildCoordinator();
    await coordinator.databaseRegistryRepository.upsert(
      DatabaseRecord(
        databaseId: 'db-1',
        canonicalPath: p.join(oldDocs.path, 'databases', 'v.kdbx'),
        displayName: 'Vault',
        sourceType: DatabaseSourceType.local,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await coordinator.databaseRegistryRepository.setActive('db-1');
    await coordinator.databaseSecurityRepository.saveProfile(
      DatabaseSecurityProfile(databaseId: 'db-1', keyFilePath: keyFile.path),
    );

    await relocate();

    final selected = await (await buildCoordinator()).getSelectedKeyFilePath();
    final expected = p.join(newDocs.path, 'keys', 'vault.keyx');
    expect(selected, expected);
    expect(
      await File(selected!).exists(),
      isTrue,
      reason: 'the unlock path must point at a file that actually exists',
    );
  });

  test('an unregistered database resolves NO key file — it never borrows '
      'another database\'s (spec 014 FR-8, T014d)', () async {
    final keysDir = await Directory(p.join(oldDocs.path, 'keys'))
        .create(recursive: true);
    final otherKey = File(p.join(keysDir.path, 'other.keyx'));
    await otherKey.writeAsString('key-material');

    final now = DateTime.utc(2024, 1, 1);
    final coordinator = await buildCoordinator();
    await coordinator.databaseRegistryRepository.upsert(
      DatabaseRecord(
        databaseId: 'db-other',
        canonicalPath: p.join(oldDocs.path, 'databases', 'other.kdbx'),
        displayName: 'Other',
        sourceType: DatabaseSourceType.local,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await coordinator.databaseRegistryRepository.setActive('db-other');
    await coordinator.databaseSecurityRepository.saveProfile(
      DatabaseSecurityProfile(
        databaseId: 'db-other',
        keyFilePath: otherKey.path,
      ),
    );

    final resolved = await coordinator.getPersistedKeyFilePath(
      p.join(oldDocs.path, 'databases', 'not-registered.kdbx'),
    );
    expect(
      resolved,
      isNull,
      reason:
          'no profile key means no key — the global cached fallback that '
          'could attach the wrong key to the wrong database is gone',
    );
  });

  test('getPersistedKeyFilePath prefers the security profile and that also '
      'survives relocation', () async {
    final keysDir = await Directory(p.join(oldDocs.path, 'keys'))
        .create(recursive: true);
    final keyFile = File(p.join(keysDir.path, 'profile.keyx'));
    await keyFile.writeAsString('key-material');

    final dbPath = p.join(oldDocs.path, 'databases', 'v.kdbx');
    final now = DateTime.utc(2024, 1, 1);
    final coordinator = await buildCoordinator();
    await coordinator.databaseRegistryRepository.upsert(
      DatabaseRecord(
        databaseId: 'db-1',
        canonicalPath: dbPath,
        displayName: 'Vault',
        sourceType: DatabaseSourceType.local,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await coordinator.databaseSecurityRepository.saveProfile(
      DatabaseSecurityProfile(databaseId: 'db-1', keyFilePath: keyFile.path),
    );

    await relocate();

    final relocated = await buildCoordinator();
    final resolved = await relocated.getPersistedKeyFilePath(
      p.join(newDocs.path, 'databases', 'v.kdbx'),
    );
    expect(resolved, p.join(newDocs.path, 'keys', 'profile.keyx'));
    expect(await File(resolved!).exists(), isTrue);
  });

  test('a key file in use stays protected from deletion after relocation: '
      'getProtectedKeyFilePaths resolves against the new root', () async {
    final keysDir = await Directory(p.join(oldDocs.path, 'keys'))
        .create(recursive: true);
    final keyFile = File(p.join(keysDir.path, 'protected.keyx'));
    await keyFile.writeAsString('key-material');

    final now = DateTime.utc(2024, 1, 1);
    final coordinator = await buildSessionCoordinator();
    await coordinator.databaseRegistryRepository.upsert(
      DatabaseRecord(
        databaseId: 'db-1',
        canonicalPath: p.join(oldDocs.path, 'databases', 'v.kdbx'),
        displayName: 'Vault',
        sourceType: DatabaseSourceType.local,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await coordinator.databaseSecurityRepository.saveProfile(
      DatabaseSecurityProfile(databaseId: 'db-1', keyFilePath: keyFile.path),
    );

    await relocate();

    final paths = await (await buildSessionCoordinator())
        .getProtectedKeyFilePaths();
    final relocatedKey = p.join(newDocs.path, 'keys', 'protected.keyx');
    expect(paths, {relocatedKey});
    expect(
      await File(relocatedKey).exists(),
      isTrue,
      reason: 'the protected path must be the file the key manager lists',
    );
  });
}
