import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../data/datasources/local_data_source.dart';
import '../../data/datasources/secure_data_source.dart';
import '../../data/services/database_rename_transaction.dart';
import '../../data/services/vault_kdbx_service.dart';
import '../../domain/entities/database_record.dart';
import '../../domain/entities/database_security_profile.dart';
import '../../domain/repositories/database_file_repository.dart';
import '../../domain/repositories/database_registry_repository.dart';
import '../../domain/repositories/database_security_repository.dart';
import '../../domain/repositories/database_sync_repository.dart';
import '../../domain/models/sync_merge_models.dart' show MergeDatabaseId;
import '../../../../core/utils/mobile_file_storage.dart';
import 'apple_autofill_v2_coordinator.dart';
import 'dated_backup_path.dart';
import 'session_secret_holder.dart';
import 'sync_merge_coordinator.dart';

class DatabaseSettingsUpdateRequest {
  const DatabaseSettingsUpdateRequest({
    required this.currentDatabasePath,
    required this.fileName,
    required this.keyFilePath,
    required this.biometricProtectionEnabled,
    required this.changePassword,
    required this.inactivityLockTimeoutSeconds,
    this.currentPassword,
    this.newPassword,
  });

  final String currentDatabasePath;
  final String fileName;
  final String? keyFilePath;
  final bool biometricProtectionEnabled;
  final bool changePassword;
  final int? inactivityLockTimeoutSeconds;
  final String? currentPassword;
  final String? newPassword;
}

class DatabaseSettingsUpdateResult {
  const DatabaseSettingsUpdateResult({
    required this.databasePath,
    required this.passwordChanged,
  });

  final String databasePath;
  final bool passwordChanged;
}

class VaultSessionCoordinator {
  VaultSessionCoordinator({
    required this.databaseFileRepository,
    required this.databaseRenameTransaction,
    required this.localDataSource,
    required this.databaseRegistryRepository,
    required this.databaseSecurityRepository,
    required this.secureDataSource,
    required this.databaseSyncRepository,
    required this.vaultKdbxService,
    required this.sessionSecretHolder,
    this.appleAutofillV2Coordinator = const NoopAppleAutofillV2Coordinator(),
    this.syncMergeCoordinator,
  });

  /// spec 008 T102: every database file mutation (rename, rollback rename,
  /// pre-rekey backup copy) goes through this domain port; the coordinator
  /// performs no direct `dart:io` mutation.
  final DatabaseFileRepository databaseFileRepository;

  /// spec 008 T106: forward rename + sync-mapping move happen atomically
  /// under one old+new path lock inside this transaction. The best-effort
  /// inverse restore in the failure path below stays sequential on purpose:
  /// today a failed mapping move-back must not prevent the file rename-back.
  final DatabaseRenameTransaction databaseRenameTransaction;
  final LocalDataSource localDataSource;
  final DatabaseRegistryRepository databaseRegistryRepository;
  final DatabaseSecurityRepository databaseSecurityRepository;
  final SecureDataSource secureDataSource;
  final DatabaseSyncRepository databaseSyncRepository;
  final VaultKdbxService vaultKdbxService;

  /// spec-011 FR-1/FR-2: in-memory session secret, cleared on lock, database
  /// switch and app termination. Keystore behaviour is unchanged in Slice 1.
  final SessionSecretHolder sessionSecretHolder;
  final AppleAutofillV2CoordinatorContract appleAutofillV2Coordinator;

  /// spec-008 T506: invalidated before credentials are cleared on lock or
  /// database switch, so the data side can abort a pre-boundary merge or
  /// finish its durable bookkeeping while it can still open the file.
  final SyncMergeCoordinator? syncMergeCoordinator;

  /// spec 014 FR-8: the per-database security profile is the only source of
  /// a key-file path. The selected key file is the active database's.
  Future<String?> getSelectedKeyFilePath() async {
    final activeId = await databaseRegistryRepository.getActive();
    if (activeId == null) {
      return null;
    }
    final profile = await databaseSecurityRepository.getProfile(activeId);
    return _sessionKeyFilePath(profile?.keyFilePath);
  }

  /// The key file this session was unlocked with wins over a profile the
  /// unlock could not update (see `SessionSecretHolder.keyFileOverride`).
  String? _sessionKeyFilePath(String? profileKeyFilePath) {
    final override = sessionSecretHolder.keyFileOverride;
    return override == null ? profileKeyFilePath : override.path;
  }

  Future<String?> getPersistedKeyFilePath(String databasePath) async {
    final record = await _findRecordByPath(databasePath);
    if (record == null) {
      return null;
    }
    final profile = await databaseSecurityRepository.getProfile(
      record.databaseId,
    );
    return _sessionKeyFilePath(profile?.keyFilePath);
  }

  /// spec-011 Slice 2: switching database drops only session-scoped state.
  /// The per-database biometric credential is deliberately persistent
  /// (FR-4) and is removed solely by FR-5 (flag off, database removed).
  Future<void> changeDatabase({required String currentDatabasePath}) async {
    await _invalidateSyncMerge(currentDatabasePath);
    sessionSecretHolder.clear();
    await appleAutofillV2Coordinator.clearCredentials();
    await databaseRegistryRepository.setActive(null);
  }

  /// spec-011 Slice 2: locking drops the in-memory session secret; the
  /// stored biometric credential (if any) stays so a biometric unlock of
  /// the same database keeps working.
  Future<void> lockVault({required String currentDatabasePath}) async {
    await _invalidateSyncMerge(currentDatabasePath);
    sessionSecretHolder.clear();
    await appleAutofillV2Coordinator.clearCredentials();
  }

  /// spec-011 FR-2: on `AppLifecycleState.detached` only the in-memory
  /// session secret is dropped. The keystore holds at most the per-database
  /// biometric credential, which must survive termination (AC-3).
  void handleAppDetached() {
    sessionSecretHolder.clear();
  }

  Future<bool> getBiometricProtectionEnabledForPath({
    required String databasePath,
  }) async {
    if (databasePath.trim().isEmpty) {
      return false;
    }

    final records = await databaseRegistryRepository.list();
    for (final record in records) {
      if (record.canonicalPath != databasePath) {
        continue;
      }
      final profile = await databaseSecurityRepository.getProfile(
        record.databaseId,
      );
      return profile?.biometricProtectionEnabled ?? false;
    }
    return false;
  }

  Future<int?> getInactivityLockTimeoutForPath({
    required String databasePath,
  }) async {
    if (databasePath.trim().isEmpty) {
      return null;
    }

    final records = await databaseRegistryRepository.list();
    for (final record in records) {
      if (record.canonicalPath != databasePath) {
        continue;
      }
      final profile = await databaseSecurityRepository.getProfile(
        record.databaseId,
      );
      return profile?.inactivityLockTimeoutSeconds;
    }
    return null;
  }

  Future<DatabaseSettingsUpdateResult> updateDatabaseSettings(
    DatabaseSettingsUpdateRequest request,
  ) async {
    final normalizedName = _normalizeFileName(request.fileName);
    final normalizedKeyFilePath = _normalizeKeyFilePath(request.keyFilePath);
    if (normalizedKeyFilePath != null &&
        !await _keyFileExists(normalizedKeyFilePath)) {
      throw Exception('Selected key file not found. Please choose it again.');
    }
    final persistedKeyFilePath = await _ensureManagedKeyFilePath(
      normalizedKeyFilePath,
    );
    final currentPath = request.currentDatabasePath;
    final parentDir = p.dirname(currentPath);
    // spec 014 FR-3: a database in managed storage rests under an opaque
    // identifier, so a rename there changes the registry name only —
    // renaming the file would write the human-readable name back onto disk,
    // which is what FR-3 forbids. Elsewhere (desktop, user-chosen paths) the
    // file name IS the name, so it is renamed as before.
    final atRestNameIsOpaque = MobileFileStorage.isOpaqueFileName(
      p.basename(currentPath),
    );
    final targetPath = atRestNameIsOpaque
        ? currentPath
        : p.join(parentDir, normalizedName);
    final records = await databaseRegistryRepository.list();
    final record = records
        .where((item) => item.canonicalPath == currentPath)
        .firstOrNull;
    if (record == null) {
      throw Exception('Current database is not registered.');
    }
    final existingProfile = await databaseSecurityRepository.getProfile(
      record.databaseId,
    );
    final currentKeyFilePath = _normalizeKeyFilePath(
      _sessionKeyFilePath(existingProfile?.keyFilePath),
    );
    final keyFileChanged = !_samePath(currentKeyFilePath, persistedKeyFilePath);

    if (!p.equals(targetPath, currentPath)) {
      final targetFile = File(targetPath);
      if (await targetFile.exists()) {
        throw Exception('A database file with this name already exists.');
      }
    }

    // spec-011: the session secret holder — not the keystore — is the
    // source of the current vault password.
    final storedPassword = sessionSecretHolder.hasSecret
        ? sessionSecretHolder.read()
        : null;
    var currentPassword = storedPassword;
    var newPassword = storedPassword;
    if (request.changePassword || keyFileChanged) {
      currentPassword = request.changePassword
          ? request.currentPassword ?? ''
          : storedPassword;
      newPassword = request.changePassword
          ? request.newPassword ?? ''
          : storedPassword;
      if (currentPassword == null || newPassword == null) {
        throw Exception('Current vault credentials are unavailable.');
      }
      if (request.changePassword && newPassword.isEmpty) {
        throw Exception('New password is required.');
      }
      if (newPassword.isEmpty && persistedKeyFilePath == null) {
        throw Exception('At least one unlock credential is required.');
      }
    }

    var effectivePath = currentPath;
    var mappingMoved = false;
    if (!p.equals(targetPath, currentPath)) {
      final currentFile = File(currentPath);
      if (!await currentFile.exists()) {
        throw Exception('Current database file not found.');
      }
      // spec 008 T106: rename + mapping move (and the rename-back when the
      // mapping move fails) run atomically under the old+new path lock.
      await databaseRenameTransaction.renameDatabase(
        sourcePath: currentPath,
        targetPath: targetPath,
      );
      effectivePath = targetPath;
      mappingMoved = true;
    }

    final profile =
        (existingProfile ??
                DatabaseSecurityProfile(databaseId: record.databaseId))
            .copyWith(
              keyFilePath: persistedKeyFilePath,
              biometricProtectionEnabled: request.biometricProtectionEnabled,
              inactivityLockTimeoutSeconds:
                  request.inactivityLockTimeoutSeconds,
              updatedAt: DateTime.now(),
              clearKeyFilePath: persistedKeyFilePath == null,
              clearInactivityTimeout:
                  request.inactivityLockTimeoutSeconds == null,
            );
    KdbxCredentialChange? credentialChange;
    try {
      if (request.changePassword || keyFileChanged) {
        // spec-006 T3 / constitution VII: master-password (and key-file)
        // changes re-encrypt the whole file, so a dated local copy is kept
        // *in addition to* `beginCredentialChange`'s own transient rollback
        // `.bak` (which is deleted on success). This one is never deleted
        // automatically — it is the durable "you can always go back" copy.
        await _writeDatedPreRekeyBackup(effectivePath);
        credentialChange = await vaultKdbxService.beginCredentialChange(
          databasePath: effectivePath,
          currentPassword: currentPassword!,
          currentKeyFilePath: currentKeyFilePath,
          newPassword: newPassword!,
          newKeyFilePath: persistedKeyFilePath,
        );
      }

      if (request.changePassword) {
        sessionSecretHolder.set(newPassword!);
      }
      // spec-011 FR-3/FR-5: the keystore mirrors the biometric flag being
      // persisted in this same operation — enabled writes the (possibly
      // new) password under the database's own key, disabled deletes it.
      if (request.biometricProtectionEnabled) {
        if (newPassword != null) {
          await secureDataSource.saveMasterPassword(
            record.databaseId,
            newPassword,
          );
        }
      } else {
        await secureDataSource.clearMasterPassword(record.databaseId);
      }
      await databaseRegistryRepository.upsert(
        record.copyWith(
          canonicalPath: effectivePath,
          // The name the user typed, never the at-rest file name: on mobile
          // that is an opaque identifier (spec 014 FR-3).
          displayName: normalizedName,
          updatedAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        ),
      );
      await databaseSecurityRepository.saveProfile(profile);
      sessionSecretHolder.keyFileOverride = null;

      if (credentialChange != null) {
        try {
          await vaultKdbxService.finalizeCredentialChange(credentialChange);
        } catch (_) {
          // Vault and metadata are committed. Keep bounded backup for recovery.
        }
      }
      return DatabaseSettingsUpdateResult(
        databasePath: effectivePath,
        passwordChanged: request.changePassword,
      );
    } catch (_) {
      if (credentialChange != null) {
        try {
          await vaultKdbxService.rollbackCredentialChange(credentialChange);
        } catch (_) {}
      }
      await _restoreSettingsMetadata(
        record: record,
        profile: existingProfile,
        databasePath: currentPath,
        keyFilePath: currentKeyFilePath,
        password: storedPassword,
      );
      if (mappingMoved) {
        try {
          await databaseSyncRepository.moveMappingPath(
            fromDatabasePath: effectivePath,
            toDatabasePath: currentPath,
          );
        } catch (_) {}
      }
      if (!p.equals(effectivePath, currentPath) &&
          await File(effectivePath).exists()) {
        try {
          await databaseFileRepository.renameFile(
            sourcePath: effectivePath,
            targetPath: currentPath,
          );
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _restoreSettingsMetadata({
    required DatabaseRecord record,
    required DatabaseSecurityProfile? profile,
    required String databasePath,
    required String? keyFilePath,
    required String? password,
  }) async {
    try {
      await databaseRegistryRepository.upsert(record);
    } catch (_) {}
    try {
      if (profile == null) {
        await databaseSecurityRepository.removeProfile(record.databaseId);
      } else {
        await databaseSecurityRepository.saveProfile(profile);
      }
    } catch (_) {}
    try {
      if (password == null) {
        sessionSecretHolder.clear();
      } else {
        sessionSecretHolder.set(password);
      }
      // spec-011 FR-3: re-establish the keystore entry only when the
      // restored profile has biometric protection enabled (FR-5 keeps it
      // erased otherwise).
      if (password != null && (profile?.biometricProtectionEnabled ?? false)) {
        await secureDataSource.saveMasterPassword(record.databaseId, password);
      } else {
        await secureDataSource.clearMasterPassword(record.databaseId);
      }
    } catch (_) {}
  }

  /// spec-006 T3 / constitution VII ("Destructive and irreversible
  /// operations ask first and back up"): writes a dated, kept-forever copy
  /// of the current `.kdbx` bytes next to the database before a
  /// master-password or key-file re-key, so the pre-change file is always
  /// recoverable even after the re-key succeeds. Same dated-suffix
  /// convention as spec-008's `.pre-merge.kdbx` backups
  /// (`<name>.<yyyyMMdd-HHmmss-ffffff>.pre-rekey.kdbx`). Best-effort: a
  /// failure here must not block the credential change itself, since the
  /// transient rollback `.bak` written by `beginCredentialChange` already
  /// covers crash-safety for the write.
  Future<void> _writeDatedPreRekeyBackup(String databasePath) async {
    try {
      final source = File(databasePath);
      if (!await source.exists()) {
        return;
      }
      final backupPath = datedBackupPath(databasePath, suffix: 'pre-rekey');
      await databaseFileRepository.copyFile(
        sourcePath: databasePath,
        targetPath: backupPath,
      );
    } catch (_) {
      // Best-effort — see doc comment.
    }
  }

  Future<void> _invalidateSyncMerge(String databasePath) async {
    final coordinator = syncMergeCoordinator;
    if (coordinator == null) return;
    try {
      final record = await _findRecordByPath(databasePath);
      if (record != null) {
        await coordinator.invalidate(MergeDatabaseId(record.databaseId));
      }
    } on Object {
      // The lock must clear credentials no matter what the merge side does.
    }
  }

  Future<DatabaseRecord?> _findRecordByPath(String databasePath) async {
    for (final record in await databaseRegistryRepository.list()) {
      if (p.equals(
        p.normalize(record.canonicalPath),
        p.normalize(databasePath),
      )) {
        return record;
      }
    }
    return null;
  }

  String _normalizeFileName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw Exception('Database file name is required.');
    }
    if (trimmed.contains(RegExp(r'[\\/:*?"<>|]'))) {
      throw Exception('Invalid characters in file name.');
    }
    return trimmed.toLowerCase().endsWith('.kdbx') ? trimmed : '$trimmed.kdbx';
  }

  String? _normalizeKeyFilePath(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  bool _samePath(String? left, String? right) {
    if (left == null || right == null) {
      return left == right;
    }
    return p.equals(p.normalize(left), p.normalize(right));
  }

  Future<bool> _keyFileExists(String keyFilePath) async {
    try {
      return await File(keyFilePath).exists();
    } catch (_) {
      return false;
    }
  }

  Future<String?> _ensureManagedKeyFilePath(String? keyFilePath) async {
    final normalized = _normalizeKeyFilePath(keyFilePath);
    if (normalized == null) {
      return null;
    }
    try {
      final alreadyManaged = await MobileFileStorage.isPathInAppDirectory(
        filePath: normalized,
        subdirectory: 'keys',
      );
      if (alreadyManaged) {
        return normalized;
      }

      final keyBytes = await File(normalized).readAsBytes();
      return await MobileFileStorage.saveBytesToAppDirectory(
        bytes: Uint8List.fromList(keyBytes),
        fileName: p.basename(normalized),
        subdirectory: 'keys',
      );
    } catch (_) {
      return normalized;
    }
  }
}
