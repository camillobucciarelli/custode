import '../../domain/models/database_sync_mapping.dart';
import '../../domain/models/remote_file.dart';
import '../../domain/models/storage_account_summary.dart';
import '../../domain/models/sync_conflict.dart';
import '../../domain/repositories/cloud_storage_provider.dart';
import '../../domain/repositories/database_sync_repository.dart';

import 'dart:typed_data';

import '../services/database_sync_orchestrator.dart';

class DatabaseSyncRepositoryImpl implements DatabaseSyncRepository {
  DatabaseSyncRepositoryImpl({
    required CloudStorageProvider cloudStorageProvider,
    required this._databaseSyncOrchestrator,
  }) : _provider = cloudStorageProvider;

  final CloudStorageProvider _provider;
  final DatabaseSyncOrchestrator _databaseSyncOrchestrator;

  @override
  Future<void> connect() {
    return _provider.connect();
  }

  @override
  Future<void> disconnect() {
    return _provider.disconnect();
  }

  @override
  Future<void> removeMapping(String databasePath) {
    return _databaseSyncOrchestrator.removeMapping(databasePath);
  }

  @override
  Future<DatabaseSyncMappingPathMove> moveMappingPath({
    required String fromDatabasePath,
    required String toDatabasePath,
  }) {
    return _databaseSyncOrchestrator.moveMappingPath(
      fromDatabasePath: fromDatabasePath,
      toDatabasePath: toDatabasePath,
    );
  }

  @override
  Future<void> restoreMappingPathMove(DatabaseSyncMappingPathMove move) {
    return _databaseSyncOrchestrator.restoreMappingPathMove(move);
  }

  @override
  Future<DatabaseSyncMapping?> getMapping(String databasePath) {
    return _databaseSyncOrchestrator.getMapping(databasePath);
  }

  @override
  Future<List<DatabaseSyncMapping>> getAllMappings() {
    return _databaseSyncOrchestrator.getAllMappings();
  }

  @override
  Future<bool> isConnected() {
    return _provider.isConnected();
  }

  @override
  Future<StorageAccountSummary> getConnectedAccount() {
    return _provider.getConnectedAccount();
  }

  @override
  Future<DatabaseSyncMapping> linkDatabaseToRemote({
    required String databasePath,
    String? remoteFileId,
    String? remoteFileName,
  }) {
    return _databaseSyncOrchestrator.linkDatabaseToRemote(
      databasePath: databasePath,
      remoteFileId: remoteFileId,
      remoteFileName: remoteFileName,
    );
  }

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) {
    return _databaseSyncOrchestrator.listRemoteFiles(query: query);
  }

  @override
  Future<Uint8List> downloadRemoteFile(
    String fileId, {
    required String providerId,
  }) {
    return _databaseSyncOrchestrator.downloadRemoteFile(
      fileId,
      providerId: providerId,
    );
  }

  @override
  Future<void> setAutoSync(String databasePath, bool enabled) {
    return _databaseSyncOrchestrator.setAutoSync(databasePath, enabled);
  }

  @override
  Future<SyncNowResult> syncNow(
    String databasePath, {
    SyncConflictResolution? resolution,
  }) {
    return _databaseSyncOrchestrator.syncNow(
      databasePath,
      resolution: resolution,
    );
  }
}
