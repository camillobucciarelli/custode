// Spec 024 T036: the autofill id of a vault, through the real registry
// repository (portable `appdocs:` decoding included).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/database_registry_local_data_source.dart';
import 'package:password_manager/features/password_manager/data/repositories/database_registry_repository_impl.dart';
import 'package:password_manager/features/password_manager/domain/services/autofill_database_id.dart';
import 'package:password_manager/features/password_manager/domain/services/host_identity.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _PathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _PathProvider(this.basePath);

  String basePath;

  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;

  @override
  Future<String?> getApplicationSupportPath() async => basePath;
}

class _Records implements DatabaseRegistryLocalDataSource {
  _Records(this.records);

  List<Map<String, dynamic>> records;

  @override
  Future<List<Map<String, dynamic>>> getRecords() async => records;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _stored(String id, String canonicalPath) => {
  'databaseId': id,
  'canonicalPath': canonicalPath,
  'displayName': 'Main',
  'sourceType': 'local',
  'createdAt': '2026-01-01T00:00:00.000Z',
  'updatedAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _PathProvider pathProvider;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('autofill_database_id_');
    pathProvider = _PathProvider(root.path);
    PathProviderPlatform.instance = pathProvider;
  });

  tearDown(() => root.delete(recursive: true));

  Future<String> vaultIn(Directory dir) async {
    final file = File(p.join(dir.path, 'databases', 'vault.kdbx'));
    await file.create(recursive: true);
    return file.path;
  }

  test('a session path spelled differently from the stored portable path '
      'still gets the registry id', () async {
    final stored = await vaultIn(root);
    final registry = DatabaseRegistryRepositoryImpl(
      localDataSource: _Records([
        _stored('vault-1', 'appdocs:databases/vault.kdbx'),
      ]),
    );
    // What a picker hands back: symlinks resolved (on macOS and iOS this is
    // the `/private/var` spelling of `/var`) and not normalized.
    final session = p.join(
      root.resolveSymbolicLinksSync(),
      'databases',
      '..',
      'databases',
      'vault.kdbx',
    );
    expect(session, isNot(stored));

    final ids = await autofillDatabaseIdsFor(session, registry);

    expect(ids.published, 'reg:vault-1');
    expect(ids.legacy, databaseIdForPath(session));
    expect(ids.registryUnavailable, isFalse);
  });

  test(
    'the registry id follows the row when the container relocates',
    () async {
      final registry = DatabaseRegistryRepositoryImpl(
        localDataSource: _Records([
          _stored('vault-1', 'appdocs:databases/vault.kdbx'),
        ]),
      );
      final before = await vaultIn(root);
      final moved = await Directory(p.join(root.path, 'new-container'))
          .create();
      final after = await vaultIn(moved);
      final idsBefore = await autofillDatabaseIdsFor(before, registry);

      pathProvider.basePath = moved.path;
      final idsAfter = await autofillDatabaseIdsFor(after, registry);

      expect(idsAfter.published, idsBefore.published);
      expect(idsAfter.published, 'reg:vault-1');
      expect(idsAfter.legacy, isNot(idsBefore.legacy));
    },
  );

  test(
    'a different file with the same basename is not the registered vault',
    () async {
      await vaultIn(root);
      final elsewhere = await Directory(p.join(root.path, 'elsewhere'))
          .create();
      final other = await vaultIn(elsewhere);
      final registry = DatabaseRegistryRepositoryImpl(
        localDataSource: _Records([
          _stored('vault-1', 'appdocs:databases/vault.kdbx'),
        ]),
      );

      final ids = await autofillDatabaseIdsFor(other, registry);

      expect(ids.published, databaseIdForPath(other));
    },
  );
}
