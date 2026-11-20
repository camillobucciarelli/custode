import '../entities/database_record.dart';
import '../models/database_dedup_result.dart';
import '../repositories/database_registry_repository.dart';
import '../repositories/database_sync_repository.dart';

class ResolveDatabaseDuplicateUseCase {
  ResolveDatabaseDuplicateUseCase(this.repository, this.syncRepository);

  final DatabaseRegistryRepository repository;
  final DatabaseSyncRepository syncRepository;

  Future<DatabaseDedupResult> call({
    required DatabaseSourceType sourceType,
    String? sourceRef,
    String? fileHash,
    String? displayName,
    String? remoteProviderId,
  }) async {
    final normalizedSourceRef = sourceRef?.trim();
    if (normalizedSourceRef != null && normalizedSourceRef.isNotEmpty) {
      final bySource =
          await repository.findBySource(
            sourceType: sourceType,
            sourceRef: normalizedSourceRef,
          ) ??
          await _findByMapping(remoteProviderId, normalizedSourceRef);
      if (bySource != null) {
        return DatabaseDedupResult(
          matchType: DatabaseDuplicateMatchType.source,
          resolution: DatabaseDuplicateResolution.useExisting,
          existingRecord: bySource,
        );
      }
    }

    final normalizedHash = fileHash?.trim();
    if (normalizedHash != null && normalizedHash.isNotEmpty) {
      final byHash = await repository.findByHash(normalizedHash);
      if (byHash != null) {
        return DatabaseDedupResult(
          matchType: DatabaseDuplicateMatchType.hash,
          resolution: DatabaseDuplicateResolution.useExisting,
          existingRecord: byHash,
        );
      }
    }

    // Spec 025 FR-O6: the registry is the only source of truth for "a
    // database with this name"; on-disk names are opaque (spec 014).
    final normalizedName = displayName?.trim();
    if (normalizedName != null && normalizedName.isNotEmpty) {
      for (final record in await repository.list()) {
        if (record.displayName == normalizedName) {
          return DatabaseDedupResult(
            matchType: DatabaseDuplicateMatchType.name,
            resolution: DatabaseDuplicateResolution.useExisting,
            existingRecord: record,
          );
        }
      }
    }

    return DatabaseDedupResult.noDuplicate;
  }

  /// A database linked to a remote file later, from Sync, keeps its local
  /// `sourceType`, so the registry alone cannot tell that the incoming remote
  /// file is already here. Its sync mapping can.
  Future<DatabaseRecord?> _findByMapping(
    String? providerId,
    String remoteFileId,
  ) async {
    if (providerId == null) {
      return null;
    }
    try {
      for (final mapping in await syncRepository.getAllMappings()) {
        if (!mapping.pointsAt(
          providerId: providerId,
          remoteFileId: remoteFileId,
        )) {
          continue;
        }
        for (final record in await repository.list()) {
          if (record.databaseId == mapping.databaseId ||
              record.canonicalPath == mapping.databasePath) {
            return record;
          }
        }
      }
    } catch (_) {
      // Unreadable sync metadata degrades to the hash and name checks.
    }
    return null;
  }
}
