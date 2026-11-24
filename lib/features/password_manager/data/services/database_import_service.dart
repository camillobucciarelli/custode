import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../../core/utils/mobile_file_storage.dart';
import '../../domain/entities/database_record.dart';
import '../../domain/errors/database_access_failure.dart';
import '../../domain/models/database_import_result.dart';
import '../../domain/models/database_import_transaction.dart';
import '../../domain/repositories/database_file_repository.dart';
import '../../domain/usecases/validate_database_usecase.dart';
import 'database_file_hash_recorder.dart';
import 'database_path_mutex.dart';
import 'safe_vault_file_writer.dart';

/// Data-layer implementation of the [DatabaseFileRepository] domain port
/// (C-7). Owns every `dart:io`/managed-storage detail that the
/// coordinator used to touch directly.
class DatabaseImportService implements DatabaseFileRepository {
  DatabaseImportService({
    required this.validateDatabaseUseCase,
    DatabasePathMutex? mutex,
    SafeVaultFileWriter? safeWriter,
    this._fileHashRecorder,
    this._afterCommitInstall,
  }) : _mutex = mutex ?? DatabasePathMutex(),
       _safeWriter = safeWriter ?? SafeVaultFileWriter();

  final ValidateDatabaseUseCase validateDatabaseUseCase;

  /// spec 008 T105: every file mutation below acquires this lock. NOT
  /// reentrant — locked methods never call each other from inside their
  /// action; multi-step operations (commit, replace) take every involved
  /// path in a single acquisition and use lock-free private helpers.
  final DatabasePathMutex _mutex;

  /// spec 008 T109: lock-free safe writer (temp + fsync + verify + atomic
  /// rename), invoked only inside the mutex actions of this service.
  final SafeVaultFileWriter _safeWriter;

  /// Invalidate/complete/rollback hash protocol (P1-4) around every raw
  /// replacement below. `null` in callers/tests that do not need registry
  /// hash tracking.
  final DatabaseFileHashRecorder? _fileHashRecorder;

  /// Test-only hook invoked immediately after a commit installs its bytes
  /// but before the method returns its rollback handle (P2). Production
  /// code never sets this; tests use it to prove that a failure in this
  /// window is compensated internally rather than leaving an orphan file.
  final Future<void> Function()? _afterCommitInstall;

  Future<T> _trackDatabaseWrite<T>({
    required String databasePath,
    required Uint8List bytes,
    required Future<T> Function() write,
  }) {
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

  /// Prospective app-storage path used as the lock identity for writes whose
  /// final name is decided inside `MobileFileStorage` (unique-name suffixing).
  ///
  /// ponytail: locking the base name serializes competing writes of the same
  /// file name, which is the only real contention; a `-1` suffixed sibling
  /// picked inside the lock is a brand-new file no other writer can hold.
  Future<String> _prospectiveAppPath(String fileName, String subdirectory) {
    return MobileFileStorage.getPathInAppDirectory(
      fileName: fileName,
      subdirectory: subdirectory,
    );
  }

  Future<DatabaseAccessFailure?> _validationFailure(String path) async {
    final result = await validateDatabaseUseCase(path);
    return switch (result) {
      DatabaseFileValidation.valid => null,
      DatabaseFileValidation.missing => DatabaseFileMissingFailure(
        p.basename(path),
      ),
      DatabaseFileValidation.invalidStructure => InvalidDatabaseFileFailure(
        p.basename(path),
      ),
    };
  }

  @override
  Future<bool> fileExists(String path) => File(path).exists();

  @override
  Future<String> hashFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return md5.convert(bytes).toString();
  }

  Future<DatabaseImportResult> importFromSelection({
    required String fileName,
    String? selectedPath,
    List<int>? selectedBytes,
  }) async {
    final resolvedPath = await _resolveSelectedDatabasePath(
      fileName: fileName,
      selectedPath: selectedPath,
      selectedBytes: selectedBytes,
    );
    if (resolvedPath == null || resolvedPath.trim().isEmpty) {
      throw InvalidDatabaseFileFailure(fileName);
    }

    final failure = await _validationFailure(resolvedPath);
    if (failure != null) {
      // `resolvedPath` is always a file this method just staged itself, via
      // `copyFileToAppDirectory` or `saveBytesToAppDirectory` in
      // `_resolveSelectedDatabasePath`. Gating the cleanup on
      // `isPathInAppDirectory` could therefore only ever be false for a path
      // we could not have produced -- and when it was, the staged file was
      // left behind in `Documents/databases` forever (#46).
      //
      // Deleted directly rather than through `deleteFileFromAppDirectory`,
      // whose own containment guard reintroduces exactly that failure mode.
      try {
        await deleteFile(resolvedPath);
      } catch (_) {
        // Best effort: a cleanup error must never mask the import failure
        // the caller actually needs to see.
      }
      throw failure;
    }

    final bytes = await File(resolvedPath).readAsBytes();
    final fileHash = md5.convert(bytes).toString();
    return DatabaseImportResult(
      path: resolvedPath,
      // spec 014 FR-3: `resolvedPath` carries an opaque name; the
      // human-readable name is the caller's [fileName].
      fileName: p.basename(fileName),
      fileHash: fileHash,
      sourceType: DatabaseSourceType.local,
    );
  }

  @override
  Future<DatabaseImportResult> openExistingPath(String path) async {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      throw const DatabaseFileMissingFailure('');
    }

    final failure = await _validationFailure(trimmedPath);
    if (failure != null) {
      throw failure;
    }

    final bytes = await File(trimmedPath).readAsBytes();
    final fileHash = md5.convert(bytes).toString();
    return DatabaseImportResult(
      path: trimmedPath,
      fileName: p.basename(trimmedPath),
      fileHash: fileHash,
      sourceType: DatabaseSourceType.local,
    );
  }

  @override
  Future<StagedDatabaseImport> stageDriveDownload({
    required String fileName,
    required Uint8List bytes,
    required String remoteFileId,
  }) async {
    final prospectivePath = await _prospectiveAppPath(
      fileName,
      'database_imports',
    );
    final stagedPath = await _mutex.withDatabaseLock(
      [prospectivePath],
      () async {
        final stagedPath = await MobileFileStorage.saveBytesToAppDirectory(
          bytes: bytes,
          fileName: fileName,
          subdirectory: 'database_imports',
        );
        final failure = await _validationFailure(stagedPath);
        if (failure != null) {
          await MobileFileStorage.deleteFileFromAppDirectory(
            filePath: stagedPath,
            subdirectory: 'database_imports',
          );
          throw failure;
        }
        return stagedPath;
      },
    );

    return StagedDatabaseImport(
      imported: DatabaseImportResult(
        path: stagedPath,
        fileName: p.basename(fileName),
        fileHash: md5.convert(bytes).toString(),
        sourceType: DatabaseSourceType.drive,
        sourceRef: remoteFileId,
      ),
      preferredFileName: p.basename(fileName),
    );
  }

  @override
  Future<StagedDatabaseImport> stageLocalSelection({
    required String fileName,
    String? selectedPath,
    List<int>? selectedBytes,
  }) async {
    final bytes =
        selectedBytes ??
        (selectedPath == null || selectedPath.trim().isEmpty
            ? null
            : await File(selectedPath).readAsBytes());
    if (bytes == null || bytes.isEmpty) {
      throw InvalidDatabaseFileFailure(fileName);
    }

    final prospectivePath = await _prospectiveAppPath(
      fileName,
      'database_imports',
    );
    final stagedPath = await _mutex.withDatabaseLock(
      [prospectivePath],
      () async {
        final stagedPath = await MobileFileStorage.saveBytesToAppDirectory(
          bytes: Uint8List.fromList(bytes),
          fileName: fileName,
          subdirectory: 'database_imports',
        );
        final failure = await _validationFailure(stagedPath);
        if (failure != null) {
          await MobileFileStorage.deleteFileFromAppDirectory(
            filePath: stagedPath,
            subdirectory: 'database_imports',
          );
          throw failure;
        }
        return stagedPath;
      },
    );

    return StagedDatabaseImport(
      imported: DatabaseImportResult(
        path: stagedPath,
        fileName: p.basename(fileName),
        fileHash: md5.convert(bytes).toString(),
        sourceType: DatabaseSourceType.local,
      ),
      preferredFileName: p.basename(fileName),
    );
  }

  @override
  Future<String> managedDatabasePath(String fileName) {
    return MobileFileStorage.getPathInAppDirectory(
      fileName: fileName,
      subdirectory: 'databases',
    );
  }

  @override
  Future<DatabaseFileCommit> commitStagedDatabase(
    StagedDatabaseImport staged, {
    String? targetPath,
  }) async {
    final stagedFile = File(staged.imported.path);
    if (!await stagedFile.exists()) {
      throw InvalidDatabaseFileFailure(staged.preferredFileName);
    }

    if (targetPath == null) {
      final prospectivePath = await _prospectiveAppPath(
        staged.preferredFileName,
        'databases',
      );
      return _mutex.withDatabaseLock(
        [stagedFile.path, prospectivePath],
        () async {
          String? committedPath;
          try {
            committedPath = await MobileFileStorage.saveBytesToAppDirectory(
              bytes: await stagedFile.readAsBytes(),
              fileName: staged.preferredFileName,
              subdirectory: 'databases',
            );
            await _afterCommitInstall?.call();
            // Inline, lock-free discard: calling the public
            // `discardStagedDatabase` here would nest a second acquisition.
            await _discardStagedDatabaseLockFree(staged);
            return DatabaseFileCommit(databasePath: committedPath);
          } catch (error, stackTrace) {
            // P2: a failure after the fresh install (compensation step or
            // any future post-install work) must never surface without
            // first removing the just-installed file — otherwise the
            // caller gets an exception with no commit handle and the
            // installed file becomes an orphan nothing can roll back.
            if (committedPath != null) {
              final committedFile = File(committedPath);
              if (await committedFile.exists()) {
                if (await stagedFile.exists()) {
                  await committedFile.delete();
                } else {
                  await committedFile.rename(stagedFile.path);
                }
              }
            }
            Error.throwWithStackTrace(error, stackTrace);
          }
        },
      );
    }

    return _mutex.withDatabaseLock([stagedFile.path, targetPath], () async {
      final bytes = await stagedFile.readAsBytes();
      return _trackDatabaseWrite(
        databasePath: targetPath,
        bytes: bytes,
        write: () async {
          final targetFile = File(targetPath);
          String? backupPath;
          if (await targetFile.exists()) {
            backupPath =
                '$targetPath.import-backup-${DateTime.now().microsecondsSinceEpoch}';
            await targetFile.rename(backupPath);
          }
          try {
            await _moveStagedFile(stagedFile, targetPath);
            await _afterCommitInstall?.call();
            return DatabaseFileCommit(
              databasePath: targetPath,
              backupPath: backupPath,
            );
          } catch (error, stackTrace) {
            // P2: same orphan guard as above, for the replace-in-place path
            // used by Locate — a post-install failure restores the staged
            // file and the pre-existing target/backup before propagating.
            final installedFile = File(targetPath);
            if (await installedFile.exists()) {
              if (await stagedFile.exists()) {
                await installedFile.delete();
              } else {
                await installedFile.rename(stagedFile.path);
              }
            }
            if (backupPath != null && await File(backupPath).exists()) {
              await File(backupPath).rename(targetPath);
            }
            Error.throwWithStackTrace(error, stackTrace);
          }
        },
      );
    });
  }

  @override
  Future<void> finalizeDatabaseCommit(DatabaseFileCommit commit) {
    return _mutex.withDatabaseLock([commit.databasePath], () async {
      final backupPath = commit.backupPath;
      if (backupPath != null && await File(backupPath).exists()) {
        await File(backupPath).delete();
      }
    });
  }

  @override
  Future<void> rollbackDatabaseCommit(DatabaseFileCommit commit) {
    return _mutex.withDatabaseLock([commit.databasePath], () async {
      final committedFile = File(commit.databasePath);
      final backupPath = commit.backupPath;
      if (backupPath == null) {
        if (await committedFile.exists()) {
          await committedFile.delete();
        }
        return;
      }

      final rollbackFile = File(
        '${commit.databasePath}.import-rollback-${DateTime.now().microsecondsSinceEpoch}',
      );
      final backupFile = File(backupPath);
      final restoredBytes = await backupFile.readAsBytes();
      await _trackDatabaseWrite(
        databasePath: commit.databasePath,
        bytes: restoredBytes,
        write: () async {
          if (await committedFile.exists()) {
            await committedFile.rename(rollbackFile.path);
          }
          try {
            await backupFile.rename(commit.databasePath);
          } catch (_) {
            if (await rollbackFile.exists() && !await committedFile.exists()) {
              await rollbackFile.rename(commit.databasePath);
            }
            rethrow;
          }
        },
      );
      try {
        if (await rollbackFile.exists()) {
          await rollbackFile.delete();
        }
      } catch (_) {
        // Backup restoration is already durable; a stale rollback artifact
        // is safe to leave behind and must not turn a successful rollback
        // into a reported failure.
      }
    });
  }

  @override
  Future<void> discardStagedDatabase(StagedDatabaseImport staged) {
    return _mutex.withDatabaseLock([
      staged.imported.path,
    ], () => _discardStagedDatabaseLockFree(staged));
  }

  Future<void> _discardStagedDatabaseLockFree(
    StagedDatabaseImport staged,
  ) async {
    final stagedFile = File(staged.imported.path);
    if (await stagedFile.exists()) {
      await MobileFileStorage.deleteFileFromAppDirectory(
        filePath: stagedFile.path,
        subdirectory: 'database_imports',
      );
    }
  }

  Future<void> _moveStagedFile(File stagedFile, String targetPath) async {
    try {
      await stagedFile.rename(targetPath);
      return;
    } on FileSystemException {
      // Cross-device fallback: rename failed, so install by bytes. T109: the
      // safe writer replaces the hand-rolled temp+rename (adds fsync,
      // exclusive-create and read-back verify; same cleanup-on-failure).
      await _safeWriter.write(
        targetPath: targetPath,
        bytes: await stagedFile.readAsBytes(),
        operation: 'import install fallback',
      );
      await stagedFile.delete();
    }
  }

  @override
  Future<String> createDatabase({
    required String outputFile,
    required Uint8List databaseBytes,
  }) async {
    final prospectivePath = await _prospectiveAppPath(
      p.basename(outputFile),
      'databases',
    );
    return _mutex.withDatabaseLock([prospectivePath], () {
      return MobileFileStorage.saveBytesToAppDirectory(
        bytes: databaseBytes,
        fileName: p.basename(outputFile),
        subdirectory: 'databases',
      );
    });
  }

  @override
  Future<bool> keyFileExists(String keyFilePath) async {
    try {
      return await File(keyFilePath).exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Uint8List> readKeyFileBytes(String keyFilePath) {
    return File(keyFilePath).readAsBytes();
  }

  @override
  Future<String> saveKeyFile({
    required String fileName,
    required Uint8List keyFileBytes,
    String? selectedPath,
  }) async {
    final normalizedSelectedPath = selectedPath?.trim();
    if (normalizedSelectedPath != null && normalizedSelectedPath.isNotEmpty) {
      final selectedFile = File(normalizedSelectedPath);
      if (await selectedFile.exists()) {
        return MobileFileStorage.copyFileToAppDirectory(
          sourcePath: normalizedSelectedPath,
          fallbackFileName: fileName,
          subdirectory: 'keys',
        );
      }

      return MobileFileStorage.saveBytesToAppDirectory(
        bytes: keyFileBytes,
        fileName: p.basename(normalizedSelectedPath),
        subdirectory: 'keys',
      );
    }

    return MobileFileStorage.saveBytesToAppDirectory(
      bytes: keyFileBytes,
      fileName: fileName,
      subdirectory: 'keys',
    );
  }

  @override
  Future<String?> ensureManagedKeyFilePath(String? keyFilePath) async {
    final normalized = keyFilePath?.trim();
    if (normalized == null || normalized.isEmpty) {
      return normalized;
    }
    try {
      final alreadyManaged = await MobileFileStorage.isPathInAppDirectory(
        filePath: normalized,
        subdirectory: 'keys',
      );
      if (alreadyManaged) {
        return normalized;
      }

      if (!await File(normalized).exists()) {
        return normalized;
      }

      return await MobileFileStorage.copyFileToAppDirectory(
        sourcePath: normalized,
        fallbackFileName: p.basename(normalized),
        subdirectory: 'keys',
      );
    } catch (_) {
      return normalized;
    }
  }

  @override
  Future<void> deleteFile(String path) {
    return _mutex.withDatabaseLock([path], () async {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    });
  }

  @override
  Future<void> copyFile({
    required String sourcePath,
    required String targetPath,
  }) {
    return _mutex.withDatabaseLock([sourcePath, targetPath], () async {
      await File(sourcePath).copy(targetPath);
    });
  }

  @override
  Future<void> renameFile({
    required String sourcePath,
    required String targetPath,
  }) {
    return _mutex.withDatabaseLock([sourcePath, targetPath], () async {
      await File(sourcePath).rename(targetPath);
    });
  }

  @override
  Future<String?> resolveOutputFilePath(String preferredFileName) async {
    return _normalizeDatabaseFileName(preferredFileName);
  }

  String _normalizeDatabaseFileName(String value) {
    final trimmed = value.trim();
    final fallback = 'new_database.kdbx';
    if (trimmed.isEmpty) {
      return fallback;
    }

    final normalized = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (normalized.isEmpty) {
      return fallback;
    }

    return normalized.toLowerCase().endsWith('.kdbx')
        ? normalized
        : '$normalized.kdbx';
  }

  Future<String?> _resolveSelectedDatabasePath({
    required String fileName,
    required String? selectedPath,
    required List<int>? selectedBytes,
  }) async {
    if (selectedPath != null && selectedPath.trim().isNotEmpty) {
      final sourceName = p.basename(selectedPath);
      final prospectivePath = await _prospectiveAppPath(
        sourceName.isEmpty ? fileName : sourceName,
        'databases',
      );
      return _mutex.withDatabaseLock([prospectivePath], () {
        return MobileFileStorage.copyFileToAppDirectory(
          sourcePath: selectedPath,
          fallbackFileName: fileName,
          subdirectory: 'databases',
        );
      });
    }

    if (selectedBytes == null) {
      return null;
    }

    final prospectivePath = await _prospectiveAppPath(fileName, 'databases');
    return _mutex.withDatabaseLock([prospectivePath], () {
      return MobileFileStorage.saveBytesToAppDirectory(
        bytes: Uint8List.fromList(selectedBytes),
        fileName: fileName,
        subdirectory: 'databases',
      );
    });
  }
}
