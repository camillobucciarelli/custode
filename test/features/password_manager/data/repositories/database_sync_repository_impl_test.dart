import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/sync_metadata_data_source.dart';
import 'package:password_manager/features/password_manager/data/repositories/database_sync_repository_impl.dart';
import 'package:password_manager/features/password_manager/data/services/database_sync_orchestrator.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/repositories/cloud_storage_provider.dart';

// spec 010 T303 — the application repository delegates connection/account to
// the provider port and every workflow operation to the orchestrator (which
// reaches the same provider only for remote bytes/metadata).
void main() {
  late _CountingProvider provider;
  late _InMemoryMetadata metadata;
  late DatabaseSyncRepositoryImpl repository;

  setUp(() {
    provider = _CountingProvider();
    metadata = _InMemoryMetadata();
    repository = DatabaseSyncRepositoryImpl(
      cloudStorageProvider: provider,
      databaseSyncOrchestrator: DatabaseSyncOrchestrator(
        syncMetadataDataSource: metadata,
        cloudStorageProvider: provider,
        resolveDatabaseId: (path) async => path,
      ),
    );
  });

  test('connection and account go straight to the provider', () async {
    await repository.connect();
    await repository.disconnect();
    expect(await repository.isConnected(), isTrue);
    expect(
      await repository.getConnectedAccount(),
      const StorageAccountSummary(displayLabel: 'acct'),
    );
    expect(provider.calls, ['connect', 'disconnect', 'isConnected', 'account']);
  });

  test('listing and download route through the orchestrator', () async {
    expect(await repository.listRemoteFiles(query: 'q'), [provider.file]);
    expect(
      await repository.downloadRemoteFile(
        'r1',
        providerId: provider.providerId,
      ),
      Uint8List.fromList([7]),
    );
    expect(provider.calls, ['list:q', 'download:r1']);
  });

  test('link persists a mapping carrying the injected provider id', () async {
    final dir = await Directory.systemTemp.createTemp('sync_repo_impl_');
    addTearDown(() => dir.delete(recursive: true));
    final db = File('${dir.path}/vault.kdbx')
      ..writeAsBytesSync([1, 2, 3], flush: true);

    final mapping = await repository.linkDatabaseToRemote(
      databasePath: db.path,
      remoteFileId: 'r1',
    );

    expect(mapping.providerId, provider.providerId);
    expect(mapping.remoteFileId, 'r1');
    expect(await metadata.getMapping(db.path), isNotNull);
    expect(provider.calls, ['metadata:r1']);
  });

  test('syncNow on an unlinked path fails in the orchestrator', () async {
    await expectLater(repository.syncNow('/nowhere.kdbx'), throwsException);
    expect(provider.calls, isEmpty);
  });
}

class _CountingProvider implements CloudStorageProvider {
  final calls = <String>[];
  final file = const RemoteFile(
    providerId: 'google_drive',
    id: 'r1',
    name: 'vault.kdbx',
  );

  @override
  String get providerId => 'google_drive';

  @override
  Future<bool> isConnected() async {
    calls.add('isConnected');
    return true;
  }

  @override
  Future<void> connect() async => calls.add('connect');

  @override
  Future<void> disconnect() async => calls.add('disconnect');

  @override
  Future<StorageAccountSummary> getConnectedAccount() async {
    calls.add('account');
    return const StorageAccountSummary(displayLabel: 'acct');
  }

  @override
  Future<List<RemoteFile>> listKdbxFiles({String? query}) async {
    calls.add('list:$query');
    return [file];
  }

  @override
  Future<RemoteFile> getFileMetadata(String remoteFileId) async {
    calls.add('metadata:$remoteFileId');
    return file;
  }

  @override
  Future<RemoteFile> createFile({
    required String name,
    required Uint8List bytes,
  }) async {
    calls.add('create:$name');
    return file;
  }

  @override
  Future<RemoteFile> updateFile({
    required String remoteFileId,
    required Uint8List bytes,
  }) async {
    calls.add('update:$remoteFileId');
    return file;
  }

  @override
  Future<Uint8List> downloadFile(String remoteFileId) async {
    calls.add('download:$remoteFileId');
    return Uint8List.fromList([7]);
  }
}

class _InMemoryMetadata implements SyncMetadataDataSource {
  final Map<String, DatabaseSyncMapping> _mappings = {};

  @override
  Future<DatabaseSyncMapping?> getMapping(String databaseId) async =>
      _mappings[databaseId];

  @override
  Future<void> upsertMapping(
    String databaseId,
    DatabaseSyncMapping mapping,
  ) async {
    _mappings[databaseId] = mapping;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}
