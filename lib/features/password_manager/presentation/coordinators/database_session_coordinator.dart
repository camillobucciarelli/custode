import 'dart:math';

import 'package:loggy/loggy.dart';
import 'package:path/path.dart' as p;

import '../../domain/entities/database_record.dart';
import '../../domain/entities/database_security_profile.dart';
import '../../domain/errors/database_access_failure.dart';
import '../../domain/models/create_database_step.dart';
import '../../domain/models/database_dedup_result.dart';
import '../../domain/models/database_import_result.dart';
import '../../domain/models/database_import_transaction.dart';
import '../../domain/models/database_selection_item.dart';
import '../../domain/models/database_sync_mapping.dart';
import '../../domain/models/remote_file_selection_data.dart';
import '../../domain/models/storage_account_summary.dart';
import '../../domain/models/recent_database_removal_mode.dart';
import '../../domain/repositories/database_file_repository.dart';
import '../../domain/repositories/database_registry_repository.dart';
import '../../domain/repositories/database_security_repository.dart';
import '../../domain/repositories/database_session_repository.dart';
import '../../domain/repositories/database_sync_repository.dart';
import '../../domain/repositories/metadata_recovery_repository.dart';
import '../../domain/usecases/create_database_usecase.dart';
import '../../domain/usecases/get_active_database_usecase.dart';
import '../../domain/usecases/link_database_to_remote_usecase.dart';
import '../../domain/usecases/resolve_database_duplicate_usecase.dart';
import '../../domain/usecases/unlock_database_usecase.dart';
import 'apple_autofill_v2_coordinator.dart';
import 'session_secret_holder.dart';

enum DatabaseSessionStatus {
  success,
  error,
  info,
  unselected,
  duplicateDecisionRequired,
}

class DatabaseDuplicatePrompt {
  const DatabaseDuplicatePrompt({
    required this.imported,
    required this.existingRecord,
    required this.clearCredentials,
    this.matchType = DatabaseDuplicateMatchType.none,
    this.canReplaceExisting = true,
    this.stagedImport,
  });

  final DatabaseImportResult imported;
  final DatabaseRecord existingRecord;
  final bool clearCredentials;

  /// What matched the existing record; a [DatabaseDuplicateMatchType.name]
  /// match is a different file that merely shares a name (spec 025 FR-O6).
  final DatabaseDuplicateMatchType matchType;

  /// False when "Replace existing" would put a different database's bytes on
  /// a path that is mapped to a remote file (spec 025 D11).
  final bool canReplaceExisting;
  final StagedDatabaseImport? stagedImport;
}

/// C-1: replaces the former `List<String> recentDatabasePaths` with typed
/// [DatabaseSelectionItem]s built from registry/security/sync metadata plus
/// file existence — never from a directory listing, and never by decrypting
/// the vault.
class DatabaseSelectionSessionResult {
  const DatabaseSelectionSessionResult({
    required this.status,
    required this.items,
    this.path,
    this.message,
    this.duplicatePrompt,
    this.openVault = false,
    this.remoteAccount,
  });

  final DatabaseSessionStatus status;
  final List<DatabaseSelectionItem> items;

  /// Spec 025 FR-L2: the connected account that heads the remote group of
  /// [items]. Best-effort; null renders the bare provider label.
  final StorageAccountSummary? remoteAccount;
  final String? path;
  final String? message;
  final DatabaseDuplicatePrompt? duplicatePrompt;

  /// Spec 025 FR-C6: the session already holds the secret and the profile the
  /// key path, so the screen may open the vault without asking again.
  final bool openVault;
}

/// Shown when the keystore refused the biometric credential. The flow that
/// asked for it (unlock offer, database creation) still succeeded.
const biometricsNotEnabledNotice =
    'Biometrics could not be enabled. You can try again in Settings.';

/// Spec 025 D10: the database decrypted and is open, but something written
/// after that (the remembered key file, the refreshed profile) was not saved.
const unlockSettingsNotSavedNotice =
    'Database unlocked, but its settings could not be saved on this device. '
    'You may be asked for the key file again.';

/// The picked key file is used for this unlock even though the choice could
/// not be written to the database's profile.
const keyFileNotRememberedNotice =
    'This key file will be used now, but the choice could not be saved. '
    'You may need to pick it again next time.';

/// Spec 025 FR-C5: the local database exists but the Drive upload did not.
const remoteCreateFailedNotice =
    'Database created on this device. It could not be uploaded to Google '
    'Drive. You can link it from Sync.';

class UnlockBootstrapResult {
  const UnlockBootstrapResult({
    required this.keyFilePath,
    required this.biometricRequired,
    required this.biometricAvailable,
    this.displayName,
    this.databaseId,
    this.isRemoteLinked = false,
    this.remoteAccount,
    this.fileMissing = false,
  });

  final String? keyFilePath;
  final bool biometricRequired;
  final bool biometricAvailable;

  /// Any registered database with a sync mapping, whatever its
  /// `sourceType` (a vault linked later from Sync is remote too).
  final bool isRemoteLinked;

  /// Best-effort, only when the provider is already connected: bootstrap
  /// never opens an interactive sign-in. Null otherwise.
  final StorageAccountSummary? remoteAccount;

  /// The registered file is no longer on disk; the unlock screen offers
  /// locate / re-download / remove instead of a credential form.
  final bool fileMissing;

  /// spec 014 FR-3: on mobile the file on disk is an opaque identifier, so
  /// the registry holds the only human-readable name. `null` when the path
  /// is not registered — the caller falls back to the basename, which is the
  /// real name on desktop.
  final String? displayName;

  /// Registry id; null when the path is not registered.
  final String? databaseId;
}

/// C-7 coordinator: sequences multi-step selection/unlock/create workflows.
/// Depends only on domain ports/use cases and presentation coordinator
/// contracts — never on `data/`, `dart:io`, Flutter, `FilePicker`, `crypto`
/// or `kdbx`. `database_session_coordinator_imports_test.dart` enforces this
/// with an analyzer-based import-URI gate.
///
/// This is the single concrete coordinator (no `Contract` interface): BLoCs
/// depend on this class directly, and tests fake the domain ports/use cases
/// it is built from instead of faking the coordinator itself.
class DatabaseSessionCoordinator {
  DatabaseSessionCoordinator({
    required this.databaseFileRepository,
    required this.databaseSessionRepository,
    required this.databaseRegistryRepository,
    required this.databaseSecurityRepository,
    required this.databaseSyncRepository,
    required this.linkDatabaseToRemote,
    this.metadataRecoveryRepository = const NoopMetadataRecoveryRepository(),
    required this.getActiveDatabaseUseCase,
    required this.resolveDatabaseDuplicateUseCase,
    required this.unlockDatabaseUseCase,
    required this.createDatabaseUseCase,
    required this.sessionSecretHolder,
    this.appleAutofillV2Coordinator = const NoopAppleAutofillV2Coordinator(),
  });

  final DatabaseFileRepository databaseFileRepository;
  final DatabaseSessionRepository databaseSessionRepository;
  final DatabaseRegistryRepository databaseRegistryRepository;
  final DatabaseSecurityRepository databaseSecurityRepository;
  final DatabaseSyncRepository databaseSyncRepository;
  final LinkDatabaseToRemoteUseCase linkDatabaseToRemote;
  final MetadataRecoveryRepository metadataRecoveryRepository;
  final GetActiveDatabaseUseCase getActiveDatabaseUseCase;
  final ResolveDatabaseDuplicateUseCase resolveDatabaseDuplicateUseCase;
  final UnlockDatabaseUseCase unlockDatabaseUseCase;
  final CreateDatabaseUseCase createDatabaseUseCase;

  /// spec-011 FR-1: in-memory session secret — the only transport for the
  /// master password across the BLoC boundary. Slice 2 (FR-3/FR-4/FR-5):
  /// the keystore holds only the per-database biometric credential, written
  /// exclusively when `biometricProtectionEnabled` is `true` for that
  /// database, and deleted when the flag is turned off or the database is
  /// unregistered.
  final SessionSecretHolder sessionSecretHolder;
  final AppleAutofillV2CoordinatorContract appleAutofillV2Coordinator;

  /// The account read by the latest [_loadSelectionItems], copied into each
  /// result next to its items.
  // ponytail: one provider, one connected account, so one cached value; make
  // it per provider id when a second provider lands (spec 010/012).
  StorageAccountSummary? _listRemoteAccount;

  Future<DatabaseSelectionSessionResult> checkInitialDatabase() async {
    final items = await _loadSelectionItems();
    final activeRecord = await getActiveDatabaseUseCase();
    final activePath = activeRecord?.canonicalPath;
    final validActivePath =
        activePath != null && _itemsContainPath(items, activePath)
        ? activePath
        : null;

    if (items.length > 1 && validActivePath == null) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.unselected,
        items: items,
        remoteAccount: _listRemoteAccount,
      );
    }

    final path =
        validActivePath ??
        (items.length == 1 ? items.first.canonicalPath : null);

    if (path == null || path.isEmpty) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.unselected,
        items: items,
        remoteAccount: _listRemoteAccount,
      );
    }

    // A registered-but-missing active database routes to the selection
    // list (FR-1 Locate), not a generic open failure: nothing was
    // corrupted, the file is simply absent.
    final resolvedItem = items.cast<DatabaseSelectionItem?>().firstWhere(
      (item) => item != null && _containsPath([item.canonicalPath], path),
      orElse: () => null,
    );
    if (resolvedItem != null && resolvedItem.isMissing) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.unselected,
        items: items,
        remoteAccount: _listRemoteAccount,
      );
    }

    try {
      final usesFallback =
          activePath == null ||
          !p.equals(p.normalize(activePath), p.normalize(path));
      if (usesFallback) {
        await _clearSessionCredentials();
      }
      return await _openExistingDatabase(path, clearCredentials: false);
    } catch (e) {
      final updatedItems = await _loadSelectionItems();
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.error,
        message: 'Database file not found or corrupted.',
        items: updatedItems,
        remoteAccount: _listRemoteAccount,
      );
    }
  }

  bool _containsPath(List<String> paths, String target) {
    final normalizedTarget = p.normalize(target.trim());
    return paths.any(
      (path) => p.equals(p.normalize(path.trim()), normalizedTarget),
    );
  }

  bool _itemsContainPath(List<DatabaseSelectionItem> items, String target) {
    return _containsPath(
      items.map((item) => item.canonicalPath).toList(growable: false),
      target,
    );
  }

  Future<DatabaseSelectionSessionResult> selectExistingDatabase({
    required String fileName,
    String? selectedPath,
    List<int>? selectedBytes,
  }) async {
    final staged = await databaseFileRepository.stageLocalSelection(
      fileName: fileName,
      selectedPath: selectedPath,
      selectedBytes: selectedBytes,
    );
    return _commitOrAskAboutDuplicate(staged);
  }

  Future<DatabaseSelectionSessionResult> openRecentDatabase(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.unselected,
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    return _openExistingDatabase(trimmed, clearCredentials: true);
  }

  /// FR-1 Locate: only valid for a missing recent item. Requires a stored
  /// hash match when available; mismatch or invalid/corrupt selection
  /// mutates nothing (the thrown `DatabaseAccessFailure` propagates to the
  /// caller before any registry write).
  Future<DatabaseSelectionSessionResult> locateMissingDatabase({
    required String databaseId,
    required String selectedPath,
  }) async {
    final record = await databaseRegistryRepository.getById(databaseId);
    if (record == null) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.error,
        message: 'Database record not found.',
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    final imported = await databaseFileRepository.openExistingPath(
      selectedPath,
    );

    final storedHash = record.fileHash;
    if (storedHash != null &&
        storedHash.isNotEmpty &&
        storedHash != imported.fileHash) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.error,
        message:
            'Selected file does not match the missing database. Use "Open a '
            'database" instead.',
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    final now = DateTime.now();
    final updatedRecord = record.copyWith(
      canonicalPath: imported.path,
      fileHash: imported.fileHash,
      updatedAt: now,
      lastOpenedAt: now,
    );
    final previousActiveId = await databaseRegistryRepository.getActive();
    DatabaseSyncMappingPathMove? mappingMove;
    var registryWriteAttempted = false;
    try {
      registryWriteAttempted = true;
      await databaseRegistryRepository.upsert(updatedRecord);
      if (record.sourceType == DatabaseSourceType.drive) {
        // P1-2: `moveMappingPath` returns an exact before-snapshot of both
        // the source and destination mapping slots. A failure here (or in
        // `setActive` below) is compensated via `restoreMappingPathMove`,
        // never by inventing a reverse move — that would blindly delete a
        // pre-existing destination mapping or overwrite the source with a
        // foreign remote id.
        mappingMove = await databaseSyncRepository.moveMappingPath(
          fromDatabasePath: record.canonicalPath,
          toDatabasePath: imported.path,
        );
      }
      await databaseRegistryRepository.setActive(updatedRecord.databaseId);
    } catch (error, stackTrace) {
      await _rollbackLocate(
        record: record,
        previousActiveId: previousActiveId,
        registryWriteAttempted: registryWriteAttempted,
        mappingMove: mappingMove,
      );
      logError(
        'Locate transaction failed and was rolled back.',
        error,
        stackTrace,
      );
      rethrow;
    }

    return DatabaseSelectionSessionResult(
      status: DatabaseSessionStatus.success,
      path: updatedRecord.canonicalPath,
      items: await _loadSelectionItems(),
      remoteAccount: _listRemoteAccount,
    );
  }

  /// FR-U5: fetches the mapped remote file again for a database whose local
  /// file is gone. Database id, security profile and sync mapping are kept;
  /// only the bytes and `fileHash` change. Bytes land through the repository's
  /// stage/commit pair, so the shared mutex, backup and rollback apply.
  /// Download or commit failures mutate nothing and propagate.
  Future<DatabaseSelectionSessionResult> redownloadMissingDatabase(
    String databaseId,
  ) async {
    final record = await databaseRegistryRepository.getById(databaseId);
    final mapping = record == null
        ? null
        : await databaseSyncRepository.getMapping(record.canonicalPath);
    if (record == null || mapping == null) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.error,
        message: 'This database is not linked to a remote file.',
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    final bytes = await databaseSyncRepository.downloadRemoteFile(
      mapping.remoteFileId,
      providerId: mapping.providerId,
    );
    final staged = await databaseFileRepository.stageDriveDownload(
      fileName: mapping.remoteFileName,
      bytes: bytes,
      remoteFileId: mapping.remoteFileId,
    );
    DatabaseFileCommit? commit;
    try {
      commit = await databaseFileRepository.commitStagedDatabase(
        staged,
        targetPath: record.canonicalPath,
      );
      await databaseRegistryRepository.upsert(
        record.copyWith(
          fileHash: staged.imported.fileHash,
          updatedAt: DateTime.now(),
        ),
      );
    } catch (_) {
      try {
        if (commit == null) {
          await databaseFileRepository.discardStagedDatabase(staged);
        } else {
          await databaseFileRepository.rollbackDatabaseCommit(commit);
        }
      } catch (_) {}
      rethrow;
    }
    try {
      await databaseFileRepository.finalizeDatabaseCommit(commit);
    } catch (_) {
      // Committed; an undeleted backup is only a leftover.
    }
    return DatabaseSelectionSessionResult(
      status: DatabaseSessionStatus.success,
      path: record.canonicalPath,
      items: await _loadSelectionItems(),
      remoteAccount: _listRemoteAccount,
    );
  }

  Future<void> _rollbackLocate({
    required DatabaseRecord record,
    required String? previousActiveId,
    required bool registryWriteAttempted,
    required DatabaseSyncMappingPathMove? mappingMove,
  }) async {
    Future<void> attempt(String label, Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        logError('Locate rollback failed: $label.', error, stackTrace);
      }
    }

    if (mappingMove != null) {
      await attempt(
        'sync mapping',
        () => databaseSyncRepository.restoreMappingPathMove(mappingMove),
      );
    }
    if (registryWriteAttempted) {
      await attempt(
        'registry record',
        () => databaseRegistryRepository.upsert(record),
      );
    }
    await attempt(
      'active database',
      () => databaseRegistryRepository.setActive(previousActiveId),
    );
  }

  Future<DatabaseSelectionSessionResult> _openExistingDatabase(
    String path, {
    required bool clearCredentials,
  }) async {
    final imported = await databaseFileRepository.openExistingPath(path);
    final existingRecord = await _findRecordByPath(imported.path);
    final now = DateTime.now();
    // spec 014 FR-3: no `displayName` here. `imported.fileName` is the
    // basename, which under managed storage is the opaque identifier — the
    // registry already holds the real name and every reopen was overwriting
    // it with the hex. Only a brand-new record takes the basename as name.
    final recordToSave =
        existingRecord?.copyWith(
          canonicalPath: imported.path,
          fileHash: imported.fileHash,
          updatedAt: now,
          lastOpenedAt: now,
        ) ??
        DatabaseRecord(
          databaseId: _generateDatabaseId(),
          canonicalPath: imported.path,
          displayName: imported.fileName,
          sourceType: imported.sourceType,
          sourceRef: imported.sourceRef,
          fileHash: imported.fileHash,
          createdAt: now,
          updatedAt: now,
          lastOpenedAt: now,
        );

    await databaseRegistryRepository.upsert(recordToSave);
    await databaseRegistryRepository.setActive(recordToSave.databaseId);
    if (clearCredentials) {
      await _clearSessionCredentials();
    }

    return DatabaseSelectionSessionResult(
      status: DatabaseSessionStatus.success,
      path: recordToSave.canonicalPath,
      items: await _loadSelectionItems(),
      remoteAccount: _listRemoteAccount,
    );
  }

  /// C-2: Drive files for the picker plus the connected account summary
  /// (mobile email, or the exact desktop fallback).
  Future<RemoteFileSelectionData> getRemoteFileSelectionData() async {
    if (!await databaseSyncRepository.isConnected()) {
      await databaseSyncRepository.connect();
    }
    return _loadRemoteFileSelectionData();
  }

  /// The picker's reconnect action. A withdrawn or expired Drive grant leaves
  /// the Google account itself signed in on mobile, so `isConnected()` stays
  /// true and [getRemoteFileSelectionData] never re-authorizes — repeating it
  /// just reproduces the same failure. Connecting unconditionally re-requests
  /// the scope interactively.
  Future<RemoteFileSelectionData> reconnectRemoteFileSelectionData() async {
    await databaseSyncRepository.connect();
    return _loadRemoteFileSelectionData();
  }

  /// "Switch account" (spec 025 FR-O4): signs out, signs in again and reloads
  /// the list. If the new sign-in fails or is cancelled the repository stays
  /// disconnected and the error reaches the caller. Existing mappings are
  /// untouched; a database linked under the previous account surfaces the
  /// reconnect-required state at its next sync.
  Future<RemoteFileSelectionData> switchRemoteAccount() async {
    await databaseSyncRepository.disconnect();
    // The list's cached account is the one just signed out of.
    _listRemoteAccount = null;
    await databaseSyncRepository.connect();
    final data = await _loadRemoteFileSelectionData();
    _listRemoteAccount = data.account;
    return data;
  }

  Future<RemoteFileSelectionData> _loadRemoteFileSelectionData() async {
    final files = await databaseSyncRepository.listRemoteFiles();
    final account = await databaseSyncRepository.getConnectedAccount();
    return RemoteFileSelectionData(files: files, account: account);
  }

  /// spec 014 FR-5 recovery, user-initiated only: discards metadata no key
  /// can open, then reloads the (now writable) selection list.
  Future<List<DatabaseSelectionItem>> discardUnreadableMetadata() async {
    await metadataRecoveryRepository.discardUnreadableMetadata();
    return _loadSelectionItems();
  }

  Future<DatabaseSelectionSessionResult> selectDriveDatabase({
    required String remoteProviderId,
    required String remoteFileId,
    required String remoteFileName,
  }) async {
    final bytes = await databaseSyncRepository.downloadRemoteFile(
      remoteFileId,
      providerId: remoteProviderId,
    );
    final staged = await databaseFileRepository.stageDriveDownload(
      fileName: remoteFileName,
      bytes: bytes,
      remoteFileId: remoteFileId,
    );
    return _commitOrAskAboutDuplicate(
      staged,
      remoteProviderId: remoteProviderId,
    );
  }

  /// The one conflict detection for every import source (spec 025 FR-O6):
  /// source, then content hash, then display name, all against the registry.
  /// A match hands the staged bytes to the user's decision, otherwise the
  /// import commits straight away.
  Future<DatabaseSelectionSessionResult> _commitOrAskAboutDuplicate(
    StagedDatabaseImport staged, {
    String? remoteProviderId,
  }) async {
    final dedup = await resolveDatabaseDuplicateUseCase(
      sourceType: staged.imported.sourceType,
      sourceRef: staged.imported.sourceRef,
      fileHash: staged.imported.fileHash,
      displayName: staged.preferredFileName,
      remoteProviderId: remoteProviderId,
    );
    if (dedup.hasDuplicate) {
      // Spec 025 D11: a name-only match is a different database. Replacing a
      // remote-linked one would leave its mapping pointing at the old remote
      // file and sync the new content into it. Fails closed: a linkage that
      // cannot be read is treated as linked, so no best-effort lookup here.
      final canReplaceExisting =
          dedup.matchType != DatabaseDuplicateMatchType.name ||
          await _isKnownUnlinked(dedup.existingRecord!.canonicalPath);
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.duplicateDecisionRequired,
        message: 'This database is already here. Choose how to continue.',
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
        duplicatePrompt: DatabaseDuplicatePrompt(
          imported: staged.imported,
          existingRecord: dedup.existingRecord!,
          clearCredentials: true,
          matchType: dedup.matchType,
          canReplaceExisting: canReplaceExisting,
          stagedImport: staged,
        ),
      );
    }
    return _commitStagedImport(staged: staged);
  }

  Future<DatabaseSelectionSessionResult> _commitStagedImport({
    required StagedDatabaseImport staged,
    DatabaseDuplicateResolution? decision,
    DatabaseRecord? duplicateRecord,
    DatabaseDuplicateMatchType matchType = DatabaseDuplicateMatchType.none,
  }) async {
    if (decision == DatabaseDuplicateResolution.cancel) {
      await databaseFileRepository.discardStagedDatabase(staged);
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.unselected,
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    if (decision == DatabaseDuplicateResolution.useExisting &&
        duplicateRecord != null) {
      try {
        final now = DateTime.now();
        await databaseRegistryRepository.upsert(
          duplicateRecord.copyWith(updatedAt: now, lastOpenedAt: now),
        );
        await databaseRegistryRepository.setActive(duplicateRecord.databaseId);
        await _clearSessionCredentials();
        final items = await _loadSelectionItems();
        // A name-only match is a different file: "open the existing one"
        // must not re-point its sync mapping at this remote file.
        if (staged.imported.sourceType == DatabaseSourceType.drive &&
            matchType != DatabaseDuplicateMatchType.name) {
          await linkDatabaseToRemote(
            databasePath: duplicateRecord.canonicalPath,
            remoteFileId: staged.imported.sourceRef,
          );
        }
        return DatabaseSelectionSessionResult(
          status: DatabaseSessionStatus.success,
          path: duplicateRecord.canonicalPath,
          items: items,
          remoteAccount: _listRemoteAccount,
        );
      } finally {
        try {
          await databaseFileRepository.discardStagedDatabase(staged);
        } catch (_) {}
      }
    }

    final targetPath =
        decision == DatabaseDuplicateResolution.replaceExisting &&
            duplicateRecord != null
        ? duplicateRecord.canonicalPath
        : null;

    final originalRecord = targetPath == null
        ? null
        : await _findRecordByPath(targetPath);
    final recordToReplace = decision == DatabaseDuplicateResolution.keepBoth
        ? originalRecord
        : duplicateRecord ?? originalRecord;
    final originalProfile = recordToReplace == null
        ? null
        : await databaseSecurityRepository.getProfile(
            recordToReplace.databaseId,
          );
    final originalActive = await getActiveDatabaseUseCase();
    // spec-011 FR-3/Slice 2: the keystore is no longer the session
    // transport, so rollback only restores the in-memory session secret.
    final originalSessionSecret = sessionSecretHolder.hasSecret
        ? sessionSecretHolder.read()
        : null;
    // Spec 025 D6: keeping both files of the same name gives the new record a
    // numeric suffix. On-disk names are opaque, so nothing collides there.
    final displayName =
        decision == DatabaseDuplicateResolution.keepBoth &&
            matchType == DatabaseDuplicateMatchType.name
        ? await _nextFreeDisplayName(staged.preferredFileName)
        : staged.preferredFileName;
    final commit = await databaseFileRepository.commitStagedDatabase(
      staged,
      targetPath: targetPath,
    );
    final now = DateTime.now();
    final recordToSave =
        (recordToReplace ??
                DatabaseRecord(
                  databaseId: _generateDatabaseId(),
                  canonicalPath: commit.databasePath,
                  displayName: displayName,
                  sourceType: staged.imported.sourceType,
                  sourceRef: staged.imported.sourceRef,
                  fileHash: staged.imported.fileHash,
                  createdAt: now,
                  updatedAt: now,
                  lastOpenedAt: now,
                ))
            .copyWith(
              canonicalPath: commit.databasePath,
              displayName: displayName,
              sourceType: staged.imported.sourceType,
              sourceRef: staged.imported.sourceRef,
              fileHash: staged.imported.fileHash,
              updatedAt: now,
              lastOpenedAt: now,
            );

    try {
      await databaseRegistryRepository.upsert(recordToSave);
      if (originalRecord != null &&
          originalRecord.fileHash != staged.imported.fileHash) {
        await databaseSecurityRepository.removeProfile(
          originalRecord.databaseId,
        );
        // spec-011 FR-5: dropping the security profile drops the stored
        // biometric credential with it.
        await databaseSessionRepository.clearMasterPassword(
          originalRecord.databaseId,
        );
      }
      await databaseRegistryRepository.setActive(recordToSave.databaseId);
      await _clearSessionCredentials();
      final items = await _loadSelectionItems();
      if (staged.imported.sourceType == DatabaseSourceType.drive) {
        await linkDatabaseToRemote(
          databasePath: recordToSave.canonicalPath,
          remoteFileId: staged.imported.sourceRef,
        );
      }
      try {
        await databaseFileRepository.finalizeDatabaseCommit(commit);
      } catch (_) {
        // Database and metadata are committed. Keep bounded backup for recovery.
      }
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.success,
        path: recordToSave.canonicalPath,
        items: items,
        remoteAccount: _listRemoteAccount,
      );
    } catch (_) {
      try {
        await databaseFileRepository.rollbackDatabaseCommit(commit);
      } catch (_) {}
      try {
        if (recordToReplace == null) {
          await databaseRegistryRepository.remove(recordToSave.databaseId);
        } else {
          await databaseRegistryRepository.upsert(recordToReplace);
        }
        await databaseRegistryRepository.setActive(originalActive?.databaseId);
      } catch (_) {}
      try {
        if (recordToReplace != null) {
          if (originalProfile == null) {
            await databaseSecurityRepository.removeProfile(
              recordToReplace.databaseId,
            );
          } else {
            await databaseSecurityRepository.saveProfile(originalProfile);
          }
        }
      } catch (_) {}
      try {
        // spec-011 FR-3/Slice 2: rollback restores only the in-memory
        // session secret; the per-database biometric credential was never
        // touched by this transaction. spec 014 FR-8: there is no global
        // cached key path to restore — the security profile is the only
        // key-file source and was restored above.
        if (originalSessionSecret == null) {
          sessionSecretHolder.clear();
        } else {
          sessionSecretHolder.set(originalSessionSecret);
        }
      } catch (_) {}
      rethrow;
    }
  }

  /// `Personal.kdbx` -> `Personal (2).kdbx`, then `(3)`, until no record has it.
  Future<String> _nextFreeDisplayName(String name) async {
    final taken = (await databaseRegistryRepository.list())
        .map((record) => record.displayName)
        .toSet();
    final extension = p.extension(name);
    final stem = name.substring(0, name.length - extension.length);
    for (var n = 2; ; n++) {
      final candidate = '$stem ($n)$extension';
      if (!taken.contains(candidate)) {
        return candidate;
      }
    }
  }

  /// spec 015 FR-9/FR-10: all-or-nothing creation. Any failure after the
  /// use case deletes the artefacts this attempt created (never the user's
  /// selected key file) and restores registry, active database, security
  /// profile, secure store, sync metadata (asserted untouched) and session
  /// secret to their pre-attempt values, modelled on `_commitStagedImport`.
  Future<DatabaseSelectionSessionResult> createNewDatabase({
    required String databaseFileName,
    required String password,
    String? keyFilePath,
    required bool biometricProtectionEnabled,
    required bool generateKeyFile,
    String? generatedKeyFilePath,
    bool createOnRemote = false,
  }) async {
    // spec 015 FR-11: biometric activation requires storable credentials,
    // decided BEFORE the vault is created. Refusal is explicit, and an
    // empty string is never written to the secure store (AC-6).
    if (biometricProtectionEnabled && password.isEmpty) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.error,
        message:
            'Biometric unlock needs a master password to store. Set a '
            'password, or turn biometric protection off.',
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    final originalActive = await getActiveDatabaseUseCase();
    final originalSessionSecret = sessionSecretHolder.hasSecret
        ? sessionSecretHolder.read()
        : null;

    // The use case cleans up its own partial output on failure (including
    // key material it generated), so a throw here leaves nothing behind.
    final created = await createDatabaseUseCase(
      CreateDatabaseRequest(
        databaseFileName: databaseFileName,
        password: password,
        keyFilePath: keyFilePath,
        generateKeyFile: generateKeyFile,
        generatedKeyFilePath: generatedKeyFilePath,
      ),
    );

    if (created == null) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.unselected,
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    Future<void> deleteCreatedArtifacts() async {
      try {
        await databaseFileRepository.deleteFile(created.databasePath);
      } catch (_) {}
      // FR-9: only key material this attempt created is deleted. A selected
      // key produced a managed COPY; the user's original is never touched,
      // and the copy goes only when it was made by this attempt.
      final createdKeyPath = created.keyFilePath;
      if (createdKeyPath != null &&
          createdKeyPath.trim().isNotEmpty &&
          createdKeyPath != keyFilePath) {
        try {
          await databaseFileRepository.deleteFile(createdKeyPath);
        } catch (_) {}
      }
    }

    final imported = DatabaseImportResult(
      path: created.databasePath,
      // spec 014 FR-3: the on-disk name is opaque; the display name is the
      // one the user typed.
      fileName: databaseFileName.trim().isEmpty
          ? 'new_database.kdbx'
          : databaseFileName.trim(),
      fileHash: created.fileHash,
      sourceType: DatabaseSourceType.created,
    );

    String? committedDatabaseId;
    try {
      final result = await _applyImportedDatabase(
        imported,
        clearCredentials: false,
      );

      if (result.path == null) {
        // Duplicate prompt or cancellation: this attempt commits nothing,
        // so its artefacts must not linger on disk either.
        await deleteCreatedArtifacts();
        return result;
      }

      final record = await _findRecordByPath(result.path!);
      committedDatabaseId = record?.databaseId;
      await _saveSecurityProfile(
        path: result.path!,
        keyFilePath: created.keyFilePath,
        biometricProtectionEnabled: biometricProtectionEnabled,
        // spec 025 FR-C7: the switch was an explicit answer either way.
        biometricOfferAnswered: true,
      );
      // The vault opens from this secret (FR-C6), exactly as after a manual
      // unlock: a key-file-only vault holds the empty password, a vault with
      // no factor at all (refused upstream) holds nothing.
      if (password.isNotEmpty || created.keyFilePath != null) {
        sessionSecretHolder.set(password);
      } else {
        sessionSecretHolder.clear();
      }
      final notices = <String>[];
      // spec-011 FR-3: persist the biometric credential only when the user
      // enabled biometric protection for this database at creation. The
      // FR-11 guard above proved the password is non-empty. A keystore
      // failure no longer fails the creation: the flag is withdrawn so the
      // profile never claims protection with no credential behind it.
      if (biometricProtectionEnabled && record != null) {
        if (!await _storeBiometricCredential(record.databaseId, password)) {
          notices.add(biometricsNotEnabledNotice);
          await _saveSecurityProfile(
            path: result.path!,
            keyFilePath: created.keyFilePath,
            biometricProtectionEnabled: false,
          );
          await _clearCredentialBestEffort(record.databaseId);
        }
      }

      // spec 025 FR-C5: the upload runs after the local commit and never
      // rolls it back; a failure leaves a valid local vault.
      if (createOnRemote && record != null) {
        try {
          final mapping = await linkDatabaseToRemote(
            databasePath: result.path!,
            remoteFileName: _withKdbxExtension(imported.fileName),
          );
          await databaseRegistryRepository.upsert(
            record.copyWith(
              sourceType: DatabaseSourceType.drive,
              sourceRef: mapping.remoteFileId,
              updatedAt: DateTime.now(),
            ),
          );
        } catch (e, st) {
          logWarning(
            'Drive upload failed after create (${e.runtimeType}).',
            null,
            st,
          );
          notices.add(remoteCreateFailedNotice);
        }
      }

      return DatabaseSelectionSessionResult(
        status: result.status,
        path: result.path,
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
        message: notices.isEmpty ? null : notices.join(' '),
        openVault: sessionSecretHolder.hasSecret,
      );
    } catch (error) {
      // FR-9 compensation, in reverse order of mutation.
      if (committedDatabaseId != null) {
        try {
          await databaseSessionRepository.clearMasterPassword(
            committedDatabaseId,
          );
        } catch (_) {}
        try {
          await databaseSecurityRepository.removeProfile(committedDatabaseId);
        } catch (_) {}
      }
      try {
        await _removeRecordByPath(created.databasePath);
      } catch (_) {}
      try {
        await databaseRegistryRepository.setActive(originalActive?.databaseId);
      } catch (_) {}
      if (originalSessionSecret == null) {
        sessionSecretHolder.clear();
      } else {
        sessionSecretHolder.set(originalSessionSecret);
      }
      await deleteCreatedArtifacts();
      rethrow;
    }
  }

  /// FR-2 create-flow step policy (C-5): pure decision, no I/O. Returns the
  /// next step, or `current` unchanged when the supplied validation facts do
  /// not allow advancing.
  CreateDatabaseStep resolveCreateDatabaseStepAdvance({
    required CreateDatabaseStep current,
    required bool fieldsNonEmpty,
    bool confirmationMatches = true,
  }) {
    if (!fieldsNonEmpty || !confirmationMatches) {
      return current;
    }
    return switch (current) {
      CreateDatabaseStep.nameAndStorage => CreateDatabaseStep.credentials,
      CreateDatabaseStep.credentials => CreateDatabaseStep.credentials,
    };
  }

  CreateDatabaseStep resolveCreateDatabaseStepBack(CreateDatabaseStep current) {
    return switch (current) {
      CreateDatabaseStep.nameAndStorage => CreateDatabaseStep.nameAndStorage,
      CreateDatabaseStep.credentials => CreateDatabaseStep.nameAndStorage,
    };
  }

  Future<DatabaseSelectionSessionResult> removeRecentDatabase({
    required String path,
    required RecentDatabaseRemovalMode mode,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.unselected,
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    var userMessage = 'Database removed from the list.';
    final activeRecord = await getActiveDatabaseUseCase();
    if (activeRecord != null &&
        _containsPath([activeRecord.canonicalPath], trimmed)) {
      sessionSecretHolder.clear();
      await databaseRegistryRepository.setActive(null);
    }

    await _removeRecordByPath(trimmed);
    await appleAutofillV2Coordinator.clearCredentials();
    try {
      await databaseSyncRepository.removeMapping(trimmed);
    } catch (e, st) {
      logWarning(
        'Unable to remove sync mapping while deleting recent DB.',
        e,
        st,
      );
    }

    if (mode == RecentDatabaseRemovalMode.removeAndDeleteFile) {
      if (await databaseFileRepository.fileExists(trimmed)) {
        await databaseFileRepository.deleteFile(trimmed);
        userMessage = 'Database removed from list and file deleted.';
      } else {
        userMessage = 'Database removed from list. File was already missing.';
      }
    }

    return DatabaseSelectionSessionResult(
      status: DatabaseSessionStatus.info,
      message: userMessage,
      items: await _loadSelectionItems(),
      remoteAccount: _listRemoteAccount,
    );
  }

  Future<UnlockBootstrapResult> initializeUnlock({
    required String databasePath,
    required bool biometricAvailable,
  }) async {
    final record = await _findRecordByPath(databasePath);
    final profile = record == null
        ? null
        : await databaseSecurityRepository.getProfile(record.databaseId);

    final profileKeyFilePath = _normalizeKeyFilePath(profile?.keyFilePath);
    var keyFilePath = profileKeyFilePath;
    var profileKeyFileWasMissing = false;

    if (profileKeyFilePath != null &&
        !await databaseFileRepository.keyFileExists(profileKeyFilePath)) {
      keyFilePath = null;
      profileKeyFileWasMissing = true;
    }

    // spec 014 FR-8: the per-database security profile is the only key-file
    // source; the global cached-path fallback is gone. A database with no
    // profile key simply has no pre-selected key file.
    if (record != null && profileKeyFileWasMissing) {
      await _saveSecurityProfile(
        path: record.canonicalPath,
        keyFilePath: null,
        biometricProtectionEnabled: null,
      );
    }

    final biometricRequired = profile?.biometricProtectionEnabled ?? false;
    final mapping = record == null
        ? null
        : await _mappingOrNull(record.canonicalPath);
    return UnlockBootstrapResult(
      keyFilePath: keyFilePath,
      biometricRequired: biometricRequired,
      biometricAvailable: biometricAvailable,
      displayName: record?.displayName,
      databaseId: record?.databaseId,
      isRemoteLinked: mapping != null,
      remoteAccount: mapping == null ? null : await connectedAccountOrNull(),
      fileMissing:
          record != null &&
          !await databaseFileRepository.fileExists(record.canonicalPath),
    );
  }

  Future<bool> _isKnownUnlinked(String databasePath) async {
    try {
      return await databaseSyncRepository.getMapping(databasePath) == null;
    } catch (_) {
      return false;
    }
  }

  /// Sync metadata is best-effort for display: a failure degrades to local.
  Future<DatabaseSyncMapping?> _mappingOrNull(String databasePath) async {
    try {
      return await databaseSyncRepository.getMapping(databasePath);
    } catch (_) {
      return null;
    }
  }

  /// Never calls `connect()`: showing a source label must not open a sign-in.
  Future<StorageAccountSummary?> connectedAccountOrNull() async {
    try {
      if (!await databaseSyncRepository.isConnected()) {
        return null;
      }
      return await databaseSyncRepository.getConnectedAccount();
    } catch (_) {
      return null;
    }
  }

  /// The Create wizard's `Connect`: signs in (the only place the wizard may),
  /// then reads the account back. Null when the user backs out or sign-in
  /// fails, so the caller keeps the source unselected.
  Future<StorageAccountSummary?> connectRemoteAccount() async {
    try {
      await databaseSyncRepository.connect();
    } catch (_) {
      return null;
    }
    return connectedAccountOrNull();
  }

  /// Validates the picked key file and remembers it in the database's profile.
  /// Throws when the key itself cannot be used; returns false when it can but
  /// the choice could not be saved.
  Future<bool> updateKeyFilePath({
    required String databasePath,
    required String? keyFilePath,
  }) async {
    final normalizedKeyFilePath = _normalizeKeyFilePath(keyFilePath);
    if (normalizedKeyFilePath != null &&
        !await databaseFileRepository.keyFileExists(normalizedKeyFilePath)) {
      throw const KeyFileMissingFailure();
    }

    final persistedKeyFilePath = await databaseFileRepository
        .ensureManagedKeyFilePath(normalizedKeyFilePath);

    // The key is valid and in managed storage, so this unlock can use it
    // whatever happens to the profile write.
    try {
      await _saveSecurityProfile(
        path: databasePath,
        keyFilePath: persistedKeyFilePath,
        biometricProtectionEnabled: null,
      );
      return true;
    } catch (e, st) {
      logWarning(
        'Key file choice could not be saved (${e.runtimeType}).',
        null,
        st,
      );
      return false;
    }
  }

  /// Turns biometric protection on or off for one database. Returns false only
  /// when enabling could not store its credential; the flag is then restored
  /// so a profile never claims protection that has no keystore entry.
  Future<bool> updateBiometricProtection({
    required String databasePath,
    required bool enabled,
  }) async {
    final record = await _findRecordByPath(databasePath);
    if (record == null) {
      return false;
    }
    final existing = await databaseSecurityRepository.getProfile(
      record.databaseId,
    );
    final profile =
        (existing ??
                DatabaseSecurityProfile(
                  databaseId: record.databaseId,
                  biometricProtectionEnabled: enabled,
                ))
            .copyWith(
              biometricProtectionEnabled: enabled,
              updatedAt: DateTime.now(),
            );
    await databaseSecurityRepository.saveProfile(profile);
    if (!enabled) {
      // spec-011 FR-5: turning biometric protection off deletes the stored
      // credential in the same operation that persists the profile.
      await databaseSessionRepository.clearMasterPassword(record.databaseId);
      return true;
    }
    // spec 025 FR-U7: the user has just proved the password, so the credential
    // is stored now (FR-3: flag is already true, FR-4: this database's key).
    // With no session secret the flag alone stands and the credential is
    // written at the next manual unlock.
    if (!sessionSecretHolder.hasSecret || sessionSecretHolder.read().isEmpty) {
      return true;
    }
    final stored = await _storeBiometricCredential(
      record.databaseId,
      sessionSecretHolder.read(),
    );
    if (!stored) {
      await databaseSecurityRepository.saveProfile(
        profile.copyWith(
          biometricProtectionEnabled:
              existing?.biometricProtectionEnabled ?? false,
          updatedAt: DateTime.now(),
        ),
      );
      if (existing?.biometricProtectionEnabled != true) {
        await _clearCredentialBestEffort(record.databaseId);
      }
    }
    return stored;
  }

  /// A keystore failure must never read as a failed unlock, so it is reported
  /// as a value. Only the exception type is logged: the secret stays out of
  /// logs (spec-011).
  Future<bool> _storeBiometricCredential(
    String databaseId,
    String secret,
  ) async {
    try {
      await databaseSessionRepository.saveMasterPassword(databaseId, secret);
      return true;
    } catch (e, st) {
      logWarning(
        'Biometric credential could not be stored (${e.runtimeType}).',
        null,
        st,
      );
      return false;
    }
  }

  Future<void> _clearCredentialBestEffort(String databaseId) async {
    try {
      await databaseSessionRepository.clearMasterPassword(databaseId);
    } catch (_) {}
  }

  /// FR-U6: whether to show the one-time biometric offer after a manual
  /// unlock. [biometricAvailable] is the caller's capability decision (platform
  /// support and device sensors). A key-only vault has no password to store.
  Future<bool> shouldOfferBiometricUnlock(
    String databasePath, {
    required bool biometricAvailable,
  }) async {
    if (!biometricAvailable ||
        !sessionSecretHolder.hasSecret ||
        sessionSecretHolder.read().isEmpty) {
      return false;
    }
    final record = await _findRecordByPath(databasePath);
    if (record == null) {
      return false;
    }
    final profile = await databaseSecurityRepository.getProfile(
      record.databaseId,
    );
    return !(profile?.biometricProtectionEnabled ?? false) &&
        !(profile?.biometricOfferAnswered ?? false);
  }

  /// Records the answer (dismissal counts as "not now") and, when [enable],
  /// turns protection on. Returns false only when enabling failed to store the
  /// credential; the answer is recorded either way.
  Future<bool> answerBiometricOffer(
    String databasePath, {
    required bool enable,
  }) async {
    final record = await _findRecordByPath(databasePath);
    if (record == null) {
      return !enable;
    }
    final existing = await databaseSecurityRepository.getProfile(
      record.databaseId,
    );
    await databaseSecurityRepository.saveProfile(
      (existing ?? DatabaseSecurityProfile(databaseId: record.databaseId))
          .copyWith(biometricOfferAnswered: true, updatedAt: DateTime.now()),
    );
    return enable
        ? updateBiometricProtection(databasePath: databasePath, enabled: true)
        : true;
  }

  /// Every unlock starts here. `VaultBloc` reads its key file from the ACTIVE
  /// database's profile, and not every route to the unlock screen selects the
  /// database first (a missing row, the vault's own lock), so the database
  /// being unlocked is made active before it is decrypted. A registry failure
  /// therefore happens before the decrypt, never after it (spec 025 D10).
  Future<DatabaseRecord?> _activateForUnlock(String databasePath) async {
    final record = await _findRecordByPath(databasePath);
    if (record != null &&
        await databaseRegistryRepository.getActive() != record.databaseId) {
      // Same as choosing it from the list: the previous session ends.
      await _clearSessionCredentials();
      await databaseRegistryRepository.setActive(record.databaseId);
    }
    return record;
  }

  /// Returns null, or a notice for the user when the database unlocked but
  /// something written afterwards did not persist (spec 025 D10). Throws only
  /// when the database could not be unlocked.
  Future<String?> unlockWithManualCredentials({
    required String databasePath,
    required String password,
    required String? keyFilePath,
  }) async {
    final persistedKeyFilePath = await databaseFileRepository
        .ensureManagedKeyFilePath(keyFilePath);
    final record = await _activateForUnlock(databasePath);
    try {
      await unlockDatabaseUseCase(
        databasePath: databasePath,
        password: password,
        keyFilePath: persistedKeyFilePath,
      );
    } catch (_) {
      // spec-011 FR-2: unlock failure never leaves a stale session secret.
      sessionSecretHolder.clear();
      rethrow;
    }
    sessionSecretHolder
      ..set(password)
      ..keyFileOverride = null;
    // The database is open. Nothing below may turn that into a failed unlock.
    final notices = <String>[];
    try {
      // spec-011 FR-3: persist the biometric credential only when biometric
      // protection is enabled for this database, under its own key (FR-4),
      // and never an empty secret (a key-file-only unlock has none).
      if (record != null &&
          password.isNotEmpty &&
          await _biometricEnabledFor(record.databaseId) &&
          !await _storeBiometricCredential(record.databaseId, password)) {
        notices.add(biometricsNotEnabledNotice);
      }
      await _saveSecurityProfile(
        path: databasePath,
        keyFilePath: persistedKeyFilePath,
        biometricProtectionEnabled: null,
      );
    } catch (e, st) {
      logWarning(
        'Settings could not be saved after unlock (${e.runtimeType}).',
        null,
        st,
      );
      notices.add(unlockSettingsNotSavedNotice);
      // The profile may still hold the old key file (or none): the vault must
      // open with the one that just decrypted it.
      sessionSecretHolder.keyFileOverride = (path: persistedKeyFilePath);
    }
    return notices.isEmpty ? null : notices.join(' ');
  }

  Future<bool> _biometricEnabledFor(String databaseId) async {
    final profile = await databaseSecurityRepository.getProfile(databaseId);
    return profile?.biometricProtectionEnabled ?? false;
  }

  Future<void> unlockWithStoredCredentials({
    required String databasePath,
    required String? keyFilePath,
  }) async {
    // spec-011 FR-4: a biometric unlock reads only the entry of the
    // database being unlocked, never another database's credential.
    final record = await _activateForUnlock(databasePath);
    final storedPassword = record == null
        ? null
        : await databaseSessionRepository.getMasterPassword(record.databaseId);
    // spec-011 FR-2: no silent empty-string fallback. An empty password is
    // only a deliberate credential when a key file is part of the unlock.
    if (storedPassword == null && keyFilePath == null) {
      sessionSecretHolder.clear();
      throw const InvalidCredentialsFailure();
    }
    final effectivePassword = storedPassword ?? '';
    try {
      await unlockDatabaseUseCase(
        databasePath: databasePath,
        password: effectivePassword,
        keyFilePath: keyFilePath,
      );
    } catch (_) {
      sessionSecretHolder.clear();
      rethrow;
    }
    sessionSecretHolder
      ..set(effectivePassword)
      ..keyFileOverride = null;
  }

  Future<bool> hasStoredMasterPassword({required String databasePath}) async {
    final record = await _findRecordByPath(databasePath);
    if (record == null) {
      return false;
    }
    final value = await databaseSessionRepository.getMasterPassword(
      record.databaseId,
    );
    return value != null && value.isNotEmpty;
  }

  Future<Set<String>> getProtectedKeyFilePaths() async {
    final protectedPaths = <String>{};
    for (final record in await databaseRegistryRepository.list()) {
      final profile = await databaseSecurityRepository.getProfile(
        record.databaseId,
      );
      final path = _normalizeKeyFilePath(profile?.keyFilePath);
      if (path != null) {
        protectedPaths.add(p.normalize(path));
      }
    }
    return protectedPaths;
  }

  /// spec-011 Slice 2: clears only session-scoped state. The per-database
  /// biometric credential is deliberately persistent (FR-4) and is removed
  /// solely by FR-5 (flag turned off, database removed/unregistered).
  Future<void> _clearSessionCredentials() async {
    sessionSecretHolder.clear();
    await appleAutofillV2Coordinator.clearCredentials();
  }

  Future<DatabaseSelectionSessionResult> _applyImportedDatabase(
    DatabaseImportResult imported, {
    required bool clearCredentials,
    DatabaseDuplicateResolution? duplicateResolution,
  }) async {
    final dedup = await resolveDatabaseDuplicateUseCase(
      sourceType: imported.sourceType,
      sourceRef: imported.sourceRef,
      fileHash: imported.fileHash,
    );

    if (dedup.hasDuplicate && duplicateResolution == null) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.duplicateDecisionRequired,
        message: 'A database with the same source or content already exists. Choose how to continue.',
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
        duplicatePrompt: DatabaseDuplicatePrompt(
          imported: imported,
          existingRecord: dedup.existingRecord!,
          clearCredentials: clearCredentials,
        ),
      );
    }

    if (duplicateResolution == DatabaseDuplicateResolution.cancel) {
      return DatabaseSelectionSessionResult(
        status: DatabaseSessionStatus.unselected,
        items: await _loadSelectionItems(),
        remoteAccount: _listRemoteAccount,
      );
    }

    final existingPathRecord = await _findRecordByPath(imported.path);
    final selectedRecord = !dedup.hasDuplicate && existingPathRecord != null
        ? existingPathRecord
        : (!dedup.hasDuplicate ||
              duplicateResolution == DatabaseDuplicateResolution.keepBoth)
        ? DatabaseRecord(
            databaseId: _generateDatabaseId(),
            canonicalPath: imported.path,
            displayName: imported.fileName,
            sourceType: imported.sourceType,
            sourceRef: imported.sourceRef,
            fileHash: imported.fileHash,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            lastOpenedAt: DateTime.now(),
          )
        : dedup.existingRecord!;

    if (!dedup.hasDuplicate &&
        existingPathRecord != null &&
        existingPathRecord.fileHash != imported.fileHash) {
      await databaseSecurityRepository.removeProfile(
        existingPathRecord.databaseId,
      );
      // spec-011 FR-5: dropping the security profile drops the stored
      // biometric credential with it.
      await databaseSessionRepository.clearMasterPassword(
        existingPathRecord.databaseId,
      );
    }

    final useExisting =
        dedup.hasDuplicate &&
        duplicateResolution == DatabaseDuplicateResolution.useExisting;
    final now = DateTime.now();
    final recordToSave = useExisting
        ? selectedRecord.copyWith(updatedAt: now, lastOpenedAt: now)
        : selectedRecord.copyWith(
            canonicalPath: imported.path,
            displayName: imported.fileName,
            sourceType: imported.sourceType,
            sourceRef: imported.sourceRef,
            fileHash: imported.fileHash.isEmpty
                ? selectedRecord.fileHash
                : imported.fileHash,
            updatedAt: now,
            lastOpenedAt: now,
          );

    await databaseRegistryRepository.upsert(recordToSave);
    await databaseRegistryRepository.setActive(recordToSave.databaseId);

    if (clearCredentials) {
      await _clearSessionCredentials();
    }

    return DatabaseSelectionSessionResult(
      status: DatabaseSessionStatus.success,
      path: recordToSave.canonicalPath,
      items: await _loadSelectionItems(),
      remoteAccount: _listRemoteAccount,
    );
  }

  Future<DatabaseSelectionSessionResult> resolveDuplicateDecision({
    required DatabaseDuplicatePrompt duplicatePrompt,
    required DatabaseDuplicateResolution decision,
  }) async {
    final stagedImport = duplicatePrompt.stagedImport;
    if (stagedImport != null) {
      return _commitStagedImport(
        staged: stagedImport,
        // A replace the prompt did not allow mutates nothing (spec 025 D11).
        decision:
            decision == DatabaseDuplicateResolution.replaceExisting &&
                !duplicatePrompt.canReplaceExisting
            ? DatabaseDuplicateResolution.cancel
            : decision,
        duplicateRecord: duplicatePrompt.existingRecord,
        matchType: duplicatePrompt.matchType,
      );
    }

    // Only a create whose bytes hash-match a registered database lands here
    // (every import is staged), so there is no remote file to link.
    return _applyImportedDatabase(
      duplicatePrompt.imported,
      clearCredentials: duplicatePrompt.clearCredentials,
      duplicateResolution: decision,
    );
  }

  /// C-1: builds selection metadata by joining registry/security/sync
  /// records with file existence once — never a directory listing, never a
  /// decrypted read.
  Future<List<DatabaseSelectionItem>> _loadSelectionItems() async {
    try {
      final records = await databaseRegistryRepository.list();
      final activeId = await databaseRegistryRepository.getActive();
      final items = <DatabaseSelectionItem>[];
      for (final record in records) {
        final profile = await databaseSecurityRepository.getProfile(
          record.databaseId,
        );
        final exists = await databaseFileRepository.fileExists(
          record.canonicalPath,
        );
        // FR-L2: any record with a mapping is remote, whatever its
        // `sourceType`; a failed lookup degrades to local.
        final mapping = await _mappingOrNull(record.canonicalPath);
        final keyFilePath = profile?.keyFilePath;
        items.add(
          DatabaseSelectionItem(
            databaseId: record.databaseId,
            canonicalPath: record.canonicalPath,
            displayName: record.displayName,
            sourceType: record.sourceType,
            sourceRef: record.sourceRef,
            isActive: record.databaseId == activeId,
            isMissing: !exists,
            biometricProtectionEnabled:
                profile?.biometricProtectionEnabled ?? false,
            keyFileConfigured:
                keyFilePath != null && keyFilePath.trim().isNotEmpty,
            lastOpenedAt: record.lastOpenedAt,
            remoteProviderId: mapping?.providerId,
            lastSyncAt: mapping?.lastSyncAt,
            lastSyncError: mapping?.lastError,
          ),
        );
      }
      items.sort((a, b) {
        final left = a.lastOpenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.lastOpenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
      // Only looked up when a remote group exists; never an interactive
      // sign-in (`connectedAccountOrNull`).
      _listRemoteAccount = items.any((item) => item.remoteProviderId != null)
          ? await connectedAccountOrNull()
          : null;
      return items;
    } catch (e, st) {
      logWarning('Unable to load database selection metadata.', e, st);
      return const [];
    }
  }

  static String _withKdbxExtension(String name) =>
      name.toLowerCase().endsWith('.kdbx') ? name : '$name.kdbx';

  Future<void> _saveSecurityProfile({
    required String path,
    required String? keyFilePath,
    required bool? biometricProtectionEnabled,
    bool? biometricOfferAnswered,
  }) async {
    final record = await _findRecordByPath(path);
    if (record == null) {
      return;
    }
    final existing = await databaseSecurityRepository.getProfile(
      record.databaseId,
    );
    final profile =
        (existing ??
                // spec-011 FR-7: a profile created implicitly never enables
                // biometric persistence.
                DatabaseSecurityProfile(
                  databaseId: record.databaseId,
                  biometricProtectionEnabled: false,
                ))
            .copyWith(
              keyFilePath: keyFilePath,
              biometricProtectionEnabled:
                  biometricProtectionEnabled ??
                  existing?.biometricProtectionEnabled,
              biometricOfferAnswered: biometricOfferAnswered,
              updatedAt: DateTime.now(),
              clearKeyFilePath: keyFilePath == null,
            );
    await databaseSecurityRepository.saveProfile(profile);
  }

  Future<void> _removeRecordByPath(String path) async {
    final record = await _findRecordByPath(path);
    if (record == null) {
      return;
    }
    await databaseSecurityRepository.removeProfile(record.databaseId);
    // spec-011 FR-5: unregistering a database deletes its stored
    // biometric credential.
    await databaseSessionRepository.clearMasterPassword(record.databaseId);
    await databaseRegistryRepository.remove(record.databaseId);
  }

  Future<DatabaseRecord?> _findRecordByPath(String path) async {
    final records = await databaseRegistryRepository.list();
    for (final record in records) {
      if (_containsPath([record.canonicalPath], path)) {
        return record;
      }
    }
    return null;
  }

  String _generateDatabaseId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final random = Random.secure().nextInt(1 << 32).toRadixString(16);
    return 'db_$now$random';
  }

  String? _normalizeKeyFilePath(String? keyFilePath) {
    final trimmed = keyFilePath?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }
}
