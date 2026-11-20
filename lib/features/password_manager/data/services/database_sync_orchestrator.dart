import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:loggy/loggy.dart';

import '../../../../core/utils/portable_path.dart';
import '../../domain/models/cloud_storage_error.dart';
import '../../domain/models/database_sync_mapping.dart';
import '../../domain/models/remote_file.dart';
import '../../domain/models/sync_conflict.dart';
import '../../domain/repositories/cloud_storage_provider.dart';
import '../../domain/repositories/database_registry_repository.dart';
import '../../domain/repositories/database_sync_repository.dart';
import '../datasources/sync_metadata_data_source.dart';
import 'database_file_hash_recorder.dart';
import 'database_path_mutex.dart';
import 'safe_vault_file_writer.dart';

class DatabaseSyncOrchestrator {
  DatabaseSyncOrchestrator({
    required this._syncMetadataDataSource,
    required CloudStorageProvider cloudStorageProvider,
    required this._resolveDatabaseId,
    DatabasePathMutex? mutex,
    SafeVaultFileWriter? safeWriter,
    this._fileHashRecorder,
    this.remoteCallTimeout = const Duration(seconds: 30),
  }) : _provider = cloudStorageProvider,
       _mutex = mutex ?? DatabasePathMutex(),
       _safeWriter = safeWriter ?? SafeVaultFileWriter();

  /// Upper bound on each individual remote call made while `syncNow` holds
  /// the database lock. The mutex is in-process and non-cancellable: a hung
  /// request would otherwise queue EVERY writer on this database until app
  /// restart. Per-call (not a whole-flow budget) so a legitimately slow
  /// large-vault transfer is not killed by time spent in earlier calls;
  /// 30s is far above normal provider API latency. On expiry the pending
  /// [TimeoutException] surfaces through syncNow's existing error path and
  /// the lock is released.
  final Duration remoteCallTimeout;

  final SyncMetadataDataSource _syncMetadataDataSource;

  /// spec 014 FR-6: mappings are keyed by registry identifier. This resolves
  /// a database path to its identifier; `null` means "not registered", which
  /// reads as "no mapping" and refuses a new link.
  final Future<String?> Function(String databasePath) _resolveDatabaseId;
  final CloudStorageProvider _provider;

  /// spec 008 T105: `syncNow` (checksum read, replacement writes and the
  /// `_backupFile` copy) runs entirely inside the shared database lock so a
  /// vault edit and a sync replacement on the same file can never interleave.
  /// `_backupFile` stays lock-free — it only runs inside the `syncNow`
  /// acquisition (the mutex is not reentrant).
  final DatabasePathMutex _mutex;

  /// spec 008 T108/T109: every local replacement below goes through the safe
  /// writer — verified collision-safe backup of the pre-replace database,
  /// then temp + fsync + verify + atomic rename. Lock-free helper, called
  /// only inside the `syncNow` mutex acquisition (the mutex is not
  /// reentrant). Replaces the old `_backupFile` copy + direct `writeAsBytes`
  /// pair; the backup now happens after the download (no backup litter when
  /// the download fails) and still strictly before the target write.
  final SafeVaultFileWriter _safeWriter;

  /// Invalidate/complete/rollback hash protocol around every local
  /// replacement below (P1-4). `null` in tests/callers that do not need
  /// registry hash tracking.
  final DatabaseFileHashRecorder? _fileHashRecorder;

  /// Applies [remoteCallTimeout] to a provider call issued under the lock.
  Future<T> _remote<T>(Future<T> call) => call.timeout(remoteCallTimeout);

  Future<DatabaseSyncMapping> linkDatabaseToRemote({
    required String databasePath,
    String? remoteFileId,
    String? remoteFileName,
  }) async {
    final dbFile = File(databasePath);
    if (!await dbFile.exists()) {
      throw Exception('Database file not found.');
    }

    final bytes = await dbFile.readAsBytes();

    late final RemoteFile remote;
    late final DatabaseSyncMapping mapping;
    if (remoteFileId != null && remoteFileId.trim().isNotEmpty) {
      remote = await _provider.getFileMetadata(remoteFileId);
      mapping = DatabaseSyncMapping(
        databasePath: databasePath,
        providerId: _provider.providerId,
        remoteFileId: remote.id,
        remoteFileName: remote.name,
        lastSyncedLocalChecksum: null,
        lastSyncedRemoteChecksum: null,
        lastSyncedRemoteModifiedTime: remote.modifiedTime,
        lastSyncAt: null,
        autoSyncEnabled: true,
      );
    } else {
      final desiredName = _normalizeFileName(
        remoteFileName,
        fallbackPath: databasePath,
      );
      remote = await _provider.createFile(name: desiredName, bytes: bytes);

      final checksum = md5.convert(bytes).toString();
      mapping = DatabaseSyncMapping(
        databasePath: databasePath,
        providerId: _provider.providerId,
        remoteFileId: remote.id,
        remoteFileName: remote.name,
        lastSyncedLocalChecksum: checksum,
        lastSyncedRemoteChecksum: remote.contentChecksum ?? checksum,
        lastSyncedRemoteModifiedTime: remote.modifiedTime,
        lastSyncAt: DateTime.now(),
        autoSyncEnabled: true,
      );
    }

    await _upsertMappingKeyed(mapping);
    return mapping;
  }

  Future<DatabaseSyncMapping?> _mappingForPath(String databasePath) async {
    final id = await _resolveDatabaseId(databasePath);
    if (id == null || id.trim().isEmpty) {
      return null;
    }
    return _syncMetadataDataSource.getMapping(id);
  }

  /// spec 010 T302: a persisted mapping is executable only by the provider
  /// this build injects. Runs before any auth, remote call, backup, metadata
  /// mutation or local write; the raw stored id is never interpolated.
  void _requireSupportedProvider(String providerId) {
    if (providerId != _provider.providerId) {
      throw const CloudStorageException(
        CloudStorageErrorCode.unsupportedProvider,
      );
    }
  }

  Future<void> _upsertMappingKeyed(DatabaseSyncMapping mapping) async {
    final id =
        mapping.databaseId ?? await _resolveDatabaseId(mapping.databasePath);
    if (id == null || id.trim().isEmpty) {
      throw Exception(
        'Database is not registered; cannot persist a sync mapping.',
      );
    }
    await _syncMetadataDataSource.upsertMapping(id, mapping);
  }

  Future<SyncNowResult> syncNow(
    String databasePath, {
    SyncConflictResolution? resolution,
  }) {
    return _mutex.withDatabaseLock([
      databasePath,
    ], () => _syncNowLocked(databasePath, resolution: resolution));
  }

  Future<SyncNowResult> _syncNowLocked(
    String databasePath, {
    SyncConflictResolution? resolution,
  }) async {
    final mapping = await _mappingForPath(databasePath);
    if (mapping == null) {
      throw Exception('Current database is not linked to Google Drive.');
    }
    _requireSupportedProvider(mapping.providerId);

    final dbFile = File(databasePath);
    if (!await dbFile.exists()) {
      throw Exception('Database file not found.');
    }

    final localBytes = await dbFile.readAsBytes();
    final localChecksum = md5.convert(localBytes).toString();
    final remote = await _remote(
      _provider.getFileMetadata(mapping.remoteFileId),
    );
    final remoteChecksumSnapshot = await _resolveRemoteChecksum(
      remoteFileId: mapping.remoteFileId,
      metadataChecksum: remote.contentChecksum,
    );
    final remoteChecksum = remoteChecksumSnapshot.value;

    final previousLocal = mapping.lastSyncedLocalChecksum;
    final previousRemote = mapping.lastSyncedRemoteChecksum;

    final firstSyncWithoutBaseline =
        previousLocal == null && previousRemote == null;

    if (firstSyncWithoutBaseline) {
      final checksumsMatch = localChecksum == remoteChecksum;
      if (checksumsMatch) {
        await _upsertMappingKeyed(
          mapping.copyWith(
            lastSyncedLocalChecksum: localChecksum,
            lastSyncedRemoteChecksum: remoteChecksum,
            lastSyncedRemoteModifiedTime: remote.modifiedTime,
            lastSyncAt: DateTime.now(),
            clearError: true,
          ),
        );
        return const SyncNowSuccess();
      }

      _logSyncConflict(
        databasePath: databasePath,
        remoteFileName: mapping.remoteFileName,
        localChecksum: localChecksum,
        remoteChecksum: remoteChecksum,
        previousLocalChecksum: previousLocal,
        previousRemoteChecksum: previousRemote,
        localChanged: true,
        remoteChanged: true,
        firstSyncWithoutBaseline: true,
        remoteChecksumComputedFromDownload:
            remoteChecksumSnapshot.computedFromDownload,
      );

      if (resolution == null || resolution == SyncConflictResolution.cancel) {
        return SyncNowConflict(
          SyncConflict(
            databasePath: databasePath,
            remoteFileId: mapping.remoteFileId,
            remoteFileName: mapping.remoteFileName,
            localChecksum: localChecksum,
            remoteChecksum: remoteChecksum,
            remoteModifiedTime: remote.modifiedTime,
            previousLocalChecksum: previousLocal,
            previousRemoteChecksum: previousRemote,
            localChanged: true,
            remoteChanged: true,
            firstSyncWithoutBaseline: true,
            remoteChecksumComputedFromDownload:
                remoteChecksumSnapshot.computedFromDownload,
          ),
        );
      }

      if (resolution == SyncConflictResolution.keepLocal) {
        final updated = await _remote(
          _provider.updateFile(
            remoteFileId: mapping.remoteFileId,
            bytes: localBytes,
          ),
        );
        await _upsertMappingKeyed(
          mapping.copyWith(
            lastSyncedLocalChecksum: localChecksum,
            lastSyncedRemoteChecksum: updated.contentChecksum ?? localChecksum,
            lastSyncedRemoteModifiedTime: updated.modifiedTime,
            lastSyncAt: DateTime.now(),
            clearError: true,
          ),
        );
        return const SyncNowSuccess();
      }

      final downloaded = await _remote(
        _provider.downloadFile(mapping.remoteFileId),
      );
      await _replaceLocalDatabase(databasePath, downloaded);
      final refreshedLocal = md5.convert(downloaded).toString();

      await _upsertMappingKeyed(
        mapping.copyWith(
          lastSyncedLocalChecksum: refreshedLocal,
          lastSyncedRemoteChecksum: remoteChecksum,
          lastSyncedRemoteModifiedTime: remote.modifiedTime,
          lastSyncAt: DateTime.now(),
          clearError: true,
        ),
      );
      return const SyncNowSuccess();
    }

    final localChanged =
        previousLocal == null || previousLocal != localChecksum;
    final remoteChanged =
        previousRemote == null || previousRemote != remoteChecksum;

    if (localChanged && remoteChanged) {
      _logSyncConflict(
        databasePath: databasePath,
        remoteFileName: mapping.remoteFileName,
        localChecksum: localChecksum,
        remoteChecksum: remoteChecksum,
        previousLocalChecksum: previousLocal,
        previousRemoteChecksum: previousRemote,
        localChanged: localChanged,
        remoteChanged: remoteChanged,
        firstSyncWithoutBaseline: false,
        remoteChecksumComputedFromDownload:
            remoteChecksumSnapshot.computedFromDownload,
      );

      if (resolution == null || resolution == SyncConflictResolution.cancel) {
        return SyncNowConflict(
          SyncConflict(
            databasePath: databasePath,
            remoteFileId: mapping.remoteFileId,
            remoteFileName: mapping.remoteFileName,
            localChecksum: localChecksum,
            remoteChecksum: remoteChecksum,
            remoteModifiedTime: remote.modifiedTime,
            previousLocalChecksum: previousLocal,
            previousRemoteChecksum: previousRemote,
            localChanged: localChanged,
            remoteChanged: remoteChanged,
            firstSyncWithoutBaseline: false,
            remoteChecksumComputedFromDownload:
                remoteChecksumSnapshot.computedFromDownload,
          ),
        );
      }

      if (resolution == SyncConflictResolution.keepLocal) {
        final updated = await _remote(
          _provider.updateFile(
            remoteFileId: mapping.remoteFileId,
            bytes: localBytes,
          ),
        );
        await _upsertMappingKeyed(
          mapping.copyWith(
            lastSyncedLocalChecksum: localChecksum,
            lastSyncedRemoteChecksum: updated.contentChecksum ?? localChecksum,
            lastSyncedRemoteModifiedTime: updated.modifiedTime,
            lastSyncAt: DateTime.now(),
            clearError: true,
          ),
        );
        return const SyncNowSuccess();
      }

      final downloaded = await _remote(
        _provider.downloadFile(mapping.remoteFileId),
      );
      await _replaceLocalDatabase(databasePath, downloaded);
      final refreshedLocal = md5.convert(downloaded).toString();

      await _upsertMappingKeyed(
        mapping.copyWith(
          lastSyncedLocalChecksum: refreshedLocal,
          lastSyncedRemoteChecksum: remoteChecksum,
          lastSyncedRemoteModifiedTime: remote.modifiedTime,
          lastSyncAt: DateTime.now(),
          clearError: true,
        ),
      );
      return const SyncNowSuccess();
    }

    if (localChanged) {
      final updated = await _remote(
        _provider.updateFile(
          remoteFileId: mapping.remoteFileId,
          bytes: localBytes,
        ),
      );
      await _upsertMappingKeyed(
        mapping.copyWith(
          lastSyncedLocalChecksum: localChecksum,
          lastSyncedRemoteChecksum: updated.contentChecksum ?? localChecksum,
          lastSyncedRemoteModifiedTime: updated.modifiedTime,
          lastSyncAt: DateTime.now(),
          clearError: true,
        ),
      );
      return const SyncNowSuccess();
    }

    if (remoteChanged) {
      final downloaded = await _remote(
        _provider.downloadFile(mapping.remoteFileId),
      );
      await _replaceLocalDatabase(databasePath, downloaded);
      final refreshedLocal = md5.convert(downloaded).toString();

      await _upsertMappingKeyed(
        mapping.copyWith(
          lastSyncedLocalChecksum: refreshedLocal,
          lastSyncedRemoteChecksum: remoteChecksum,
          lastSyncedRemoteModifiedTime: remote.modifiedTime,
          lastSyncAt: DateTime.now(),
          clearError: true,
        ),
      );
      return const SyncNowSuccess();
    }

    await _upsertMappingKeyed(
      mapping.copyWith(lastSyncAt: DateTime.now(), clearError: true),
    );
    return const SyncNowSuccess();
  }

  Future<List<RemoteFile>> listRemoteFiles({String? query}) {
    return _provider.listKdbxFiles(query: query);
  }

  Future<Uint8List> downloadRemoteFile(
    String fileId, {
    required String providerId,
  }) async {
    _requireSupportedProvider(providerId);
    return _provider.downloadFile(fileId);
  }

  Future<void> setAutoSync(String databasePath, bool enabled) async {
    final mapping = await _mappingForPath(databasePath);
    if (mapping == null) {
      throw Exception('Current database is not linked to Google Drive.');
    }
    // Toggling auto-sync is a mapping mutation, so T302's guard applies here
    // too: a mapping this build cannot execute must not be rewritten.
    _requireSupportedProvider(mapping.providerId);
    await _upsertMappingKeyed(mapping.copyWith(autoSyncEnabled: enabled));
  }

  Future<void> removeMapping(String databasePath) async {
    final id = await _resolveDatabaseId(databasePath);
    if (id == null || id.trim().isEmpty) {
      return;
    }
    return _syncMetadataDataSource.removeMapping(id);
  }

  Future<DatabaseSyncMappingPathMove> moveMappingPath({
    required String fromDatabasePath,
    required String toDatabasePath,
  }) {
    return _syncMetadataDataSource.moveMappingPath(
      fromDatabasePath: fromDatabasePath,
      toDatabasePath: toDatabasePath,
    );
  }

  Future<void> restoreMappingPathMove(DatabaseSyncMappingPathMove move) {
    return _syncMetadataDataSource.restoreMappingPathMove(move);
  }

  Future<DatabaseSyncMapping?> getMapping(String databasePath) {
    return _mappingForPath(databasePath);
  }

  Future<List<DatabaseSyncMapping>> getAllMappings() {
    return _syncMetadataDataSource.getAllMappings();
  }

  /// Every `syncNow` branch that installs remote bytes locally converges
  /// here: one guarded writer path so hash invalidation and backup can
  /// never be skipped by a branch (GAP 4).
  Future<void> _replaceLocalDatabase(String databasePath, Uint8List bytes) {
    Future<void> write() => _safeWriter.write(
      targetPath: databasePath,
      bytes: bytes,
      backupExistingTarget: true,
      operation: 'sync replace from remote',
    );

    final recorder = _fileHashRecorder;
    if (recorder == null) {
      return write();
    }
    return recorder.trackWrite(
      databasePath: databasePath,
      bytes: bytes,
      write: write,
    );
  }

  String _normalizeFileName(String? custom, {required String fallbackPath}) {
    final candidate = (custom == null || custom.trim().isEmpty)
        ? fallbackPath.split(Platform.pathSeparator).last
        : custom.trim();
    return candidate.toLowerCase().endsWith('.kdbx')
        ? candidate
        : '$candidate.kdbx';
  }

  Future<_RemoteChecksumSnapshot> _resolveRemoteChecksum({
    required String remoteFileId,
    required String? metadataChecksum,
  }) async {
    final normalizedMetadataChecksum = metadataChecksum?.trim();
    if (normalizedMetadataChecksum != null &&
        normalizedMetadataChecksum.isNotEmpty) {
      return _RemoteChecksumSnapshot(
        value: normalizedMetadataChecksum,
        computedFromDownload: false,
      );
    }

    final downloaded = await _remote(_provider.downloadFile(remoteFileId));
    final checksum = md5.convert(downloaded).toString();
    return _RemoteChecksumSnapshot(value: checksum, computedFromDownload: true);
  }

  void _logSyncConflict({
    required String databasePath,
    required String remoteFileName,
    required String localChecksum,
    required String remoteChecksum,
    required String? previousLocalChecksum,
    required String? previousRemoteChecksum,
    required bool localChanged,
    required bool remoteChanged,
    required bool firstSyncWithoutBaseline,
    required bool remoteChecksumComputedFromDownload,
  }) {
    logWarning(
      'Sync conflict details '
      '(db: $databasePath, file: $remoteFileName, '
      'localChanged: $localChanged, remoteChanged: $remoteChanged, '
      'firstSyncWithoutBaseline: $firstSyncWithoutBaseline, '
      'remoteChecksumComputedFromDownload: '
      '$remoteChecksumComputedFromDownload, '
      'previousLocalChecksum: ${previousLocalChecksum ?? 'null'}, '
      'previousRemoteChecksum: ${previousRemoteChecksum ?? 'null'}, '
      'localChecksum: $localChecksum, remoteChecksum: $remoteChecksum)',
    );
  }
}

class _RemoteChecksumSnapshot {
  const _RemoteChecksumSnapshot({
    required this.value,
    required this.computedFromDownload,
  });

  final String value;
  final bool computedFromDownload;
}

/// spec 014 FR-6: resolves a database path to its registry identifier;
/// `null` means "not registered", which reads as "no mapping" and refuses a
/// new Drive link.
///
/// Reads through the repository, never the raw data source: the stored
/// `canonicalPath` is PortablePath-encoded (`{documents}/vault.kdbx`), so
/// comparing the record as written against an absolute path never matched
/// wherever the vault lives under the documents root — on mobile that made
/// every Drive link fail with "Database is not registered".
Future<String?> resolveDatabaseIdForSync(
  String databasePath,
  DatabaseRegistryRepository registry,
) async {
  final resolved = PortablePath.resolveForComparison(databasePath);
  for (final record in await registry.list()) {
    if (PortablePath.resolveForComparison(record.canonicalPath) == resolved) {
      return record.databaseId;
    }
  }
  return null;
}
