import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/database_registry_local_data_source.dart';
import 'package:password_manager/features/password_manager/data/datasources/secure_data_source.dart';
import 'package:password_manager/features/password_manager/data/services/legacy_database_registry_migration.dart';
import 'package:password_manager/features/password_manager/data/services/database_sync_orchestrator.dart';
import 'package:password_manager/features/password_manager/data/services/database_path_mutex.dart';
import 'package:password_manager/features/password_manager/data/services/google_drive_storage_provider.dart';
import 'package:password_manager/features/password_manager/domain/repositories/cloud_storage_provider.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_database_now_usecase.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/repositories/autofill_ports.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/pending_passkey_adoption_coordinator.dart';
import 'package:password_manager/injection_container.dart' as di;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// spec-011 FR-6 wiring test: the startup migration must run from `di.init()`
/// itself, before any widget exists. Removing the call in `init()` makes this
/// test fail — it kills the "delete the migration call" mutation that the
/// data-source unit tests cannot see.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  final deletedKeys = <String>[];
  // Stateful keystore mock: spec 014's encrypted metadata needs reads to
  // return what was written, or every registry read decrypts with no key
  // and comes back empty.
  final storedValues = <String, String>{};
  late Directory documentsDirectory;

  setUp(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'injection_container_test_',
    );
    PathProviderPlatform.instance = _FakePathProvider(documentsDirectory.path);
    deletedKeys.clear();
    storedValues.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>?;
          switch (call.method) {
            case 'delete':
              final key = arguments!['key']! as String;
              deletedKeys.add(key);
              storedValues.remove(key);
              return null;
            case 'write':
              storedValues[arguments!['key']! as String] =
                  arguments['value']! as String;
              return null;
            case 'read':
              return storedValues[arguments!['key']! as String];
            case 'readAll':
              return Map<String, String>.from(storedValues);
            case 'containsKey':
              return storedValues.containsKey(arguments!['key']! as String);
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    await di.sl.reset();
    await documentsDirectory.delete(recursive: true);
  });

  test('di.init() deletes the legacy global master password entry', () async {
    await di.init();

    expect(deletedKeys, contains(SecureDataSourceImpl.legacyMasterPasswordKey));
  });

  test('di.init() migrates legacy database paths before UI startup', () async {
    final missingPath = p.join(documentsDirectory.path, 'missing.kdbx');
    // The migration canonicalizes via p.normalize(p.absolute(path)), which on
    // Windows also converts any forward slashes to the native separator.
    // Compare against that same transform instead of the raw string so this
    // assertion holds identically on POSIX and Windows.
    final expectedCanonicalPath = p.normalize(p.absolute(missingPath));
    SharedPreferences.setMockInitialValues({
      LegacyDatabaseRegistryMigration.recentDatabasePathsKey: [missingPath],
      LegacyDatabaseRegistryMigration.cachedDatabasePathKey: missingPath,
    });

    await di.init();

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.containsKey(
        LegacyDatabaseRegistryMigration.recentDatabasePathsKey,
      ),
      isFalse,
    );
    final records = await di.sl<DatabaseRegistryRepository>().list();
    expect(records, hasLength(1));
    expect(records.single.canonicalPath, expectedCanonicalPath);
    expect(await di.sl<DatabaseRegistryRepository>().getActive(), isNotNull);
  });

  test(
    'di.init() reconciles a missing registry hash before UI startup',
    () async {
      final database = File('${documentsDirectory.path}/vault.kdbx');
      await database.writeAsBytes([1, 2, 3], flush: true);
      // Seed through the encrypted data source (spec 014 FR-4): a plaintext
      // registry file is unreadable by design since FR-9.
      final now = DateTime.utc(2026).toIso8601String();
      await DatabaseRegistryLocalDataSourceImpl(
        sharedPreferences: await SharedPreferences.getInstance(),
        secureDataSource: SecureDataSourceImpl(
          secureStorage: const FlutterSecureStorage(),
        ),
      ).saveRecords([
        {
          'databaseId': 'db-1',
          'canonicalPath': database.path,
          'displayName': 'vault.kdbx',
          'sourceType': 'local',
          'sourceRef': null,
          'fileHash': null,
          'createdAt': now,
          'updatedAt': now,
          'lastOpenedAt': null,
          'isFavorite': false,
        },
      ]);

      await di.init();

      final records = await di.sl<DatabaseRegistryRepository>().list();
      expect(records.single.fileHash, md5.convert([1, 2, 3]).toString());
    },
  );

  test('a vault under the documents root resolves to its registry id, so '
      'linking it to Drive is not refused as unregistered', () async {
    await di.init();

    final database = File(p.join(documentsDirectory.path, 'vault.kdbx'));
    await database.writeAsBytes([1, 2, 3], flush: true);
    final now = DateTime.now();
    final registry = di.sl<DatabaseRegistryRepository>();
    await registry.upsert(
      DatabaseRecord(
        databaseId: 'db-1',
        canonicalPath: database.path,
        displayName: 'vault.kdbx',
        sourceType: DatabaseSourceType.drive,
        createdAt: now,
        updatedAt: now,
      ),
    );

    // The record is stored PortablePath-encoded, which is exactly what a
    // raw data-source read cannot compare against an absolute path.
    expect(
      (await di.sl<DatabaseRegistryLocalDataSource>().getRecords())
          .single['canonicalPath'],
      isNot(database.path),
    );
    expect(
      await resolveDatabaseIdForSync(database.path, registry),
      'db-1',
      reason: 'the encoded record must still match the absolute path',
    );
    expect(
      await resolveDatabaseIdForSync(
        p.join(documentsDirectory.path, 'other.kdbx'),
        registry,
      ),
      isNull,
    );
  });

  test('di.init() completes and every other dependency stays usable when the '
      'legacy migration fails, so a persistent migration failure never '
      'bricks startup', () async {
    final missingPath = p.join(documentsDirectory.path, 'missing.kdbx');
    SharedPreferences.setMockInitialValues({
      LegacyDatabaseRegistryMigration.recentDatabasePathsKey: [missingPath],
    });
    // Force the registry write inside `migrate()` to fail with a real
    // filesystem error, without touching production code: pre-create a
    // FILE where the registry's own metadata directory needs to go, so
    // `Directory(...).create()` throws when the migration tries to
    // persist the first legacy record.
    await File(p.join(documentsDirectory.path, 'metadata'))
        .create(recursive: true);

    await expectLater(di.init(), completes);

    // Startup did not stop: every other dependency this test can reach is
    // still registered and answers normally.
    expect(deletedKeys, contains(SecureDataSourceImpl.legacyMasterPasswordKey));
    expect(di.sl.isRegistered<DatabaseRegistryRepository>(), isTrue);

    // The migration rolled itself back before this test's failure point
    // ever ran, and the marker was never written — the legacy key is
    // still there for the next launch to retry.
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.containsKey(
        LegacyDatabaseRegistryMigration.recentDatabasePathsKey,
      ),
      isTrue,
    );
  });

  test('spec 010 T501/T502: one Google adapter is the sole provider port, '
      'shared by the repository and the orchestrator', () async {
    await di.init();

    final adapter = di.sl<GoogleDriveStorageProvider>();
    final port = di.sl<CloudStorageProvider>();

    // One instance, bound directly — not a second construction and not a
    // registry lookup.
    expect(identical(port, adapter), isTrue);
    expect(port.providerId, 'google_drive');
    expect(identical(di.sl<CloudStorageProvider>(), port), isTrue);

    // The two meaningful use cases resolve; no pass-through use case was
    // added for the repository's simple getters.
    expect(di.sl<LinkDatabaseToRemoteUseCase>(), isNotNull);
    expect(di.sl<SyncDatabaseNowUseCase>(), isNotNull);

    // The shared writer mutex stays one process-wide instance.
    expect(
      identical(di.sl<DatabasePathMutex>(), di.sl<DatabasePathMutex>()),
      isTrue,
    );
  });

  test('the production VaultBloc gets the pending-passkey adoption '
      'coordinator, so adoption is not a silent no-op', () async {
    await di.init();

    expect(di.sl<PendingPasskeyRegistrationPort>(), isNotNull);
    final coordinator = di.sl<PendingPasskeyAdoptionCoordinator>();
    final bloc = di.sl<VaultBloc>(param1: '/vaults/vault.kdbx');
    addTearDown(bloc.close);

    expect(bloc.pendingPasskeyAdoptionCoordinator, same(coordinator));
  });
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => documentsPath;
}
