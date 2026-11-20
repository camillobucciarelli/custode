import 'dart:typed_data';

import '../models/database_import_result.dart';
import '../models/database_import_transaction.dart';

/// C-7 domain port covering every file-system/KDBX-file operation the
/// coordinator previously performed directly (stage/open/commit/rollback/
/// discard, managed-file existence/list/delete/hash, key-file persistence).
///
/// `DatabaseImportService` (data layer) implements this port; the
/// coordinator depends only on this interface and never on `dart:io`,
/// `FilePicker`, `MobileFileStorage` or `crypto` directly.
abstract class DatabaseFileRepository {
  /// Whether a file exists at [path]. Used for recent-item `isMissing` and
  /// for the `removeAndDeleteFile` check.
  Future<bool> fileExists(String path);

  /// Content hash of the file at [path] (used for duplicate detection and
  /// Locate hash-match verification).
  Future<String> hashFile(String path);

  /// Validates and describes an already-resolved local path (existing
  /// database open / Locate target). Throws a typed
  /// `DatabaseAccessFailure` (`DatabaseFileMissingFailure` /
  /// `InvalidDatabaseFileFailure`) on failure.
  Future<DatabaseImportResult> openExistingPath(String path);

  /// Stages a locally-picked file into a temporary/import area, validating
  /// its KDBX structure. Throws a typed failure on invalid selection.
  Future<StagedDatabaseImport> stageLocalSelection({
    required String fileName,
    String? selectedPath,
    List<int>? selectedBytes,
  });

  /// Stages a downloaded Drive file the same way as [stageLocalSelection].
  Future<StagedDatabaseImport> stageDriveDownload({
    required String fileName,
    required Uint8List bytes,
    required String remoteFileId,
  });

  /// Discards a staged import without committing it (duplicate cancel/use
  /// existing outcomes never write to the final location).
  Future<void> discardStagedDatabase(StagedDatabaseImport staged);

  /// Commits a staged import to its managed location, or to [targetPath]
  /// when replacing an existing database (dated backup kept until
  /// [finalizeDatabaseCommit]).
  Future<DatabaseFileCommit> commitStagedDatabase(
    StagedDatabaseImport staged, {
    String? targetPath,
  });

  /// Deletes the backup kept by [commitStagedDatabase] after the rest of the
  /// transaction (registry/security writes) has succeeded.
  Future<void> finalizeDatabaseCommit(DatabaseFileCommit commit);

  /// Restores the pre-commit state (deletes the new file, restores the
  /// backup) after a downstream failure.
  Future<void> rollbackDatabaseCommit(DatabaseFileCommit commit);

  /// Resolves the managed-storage path a database with this file name would
  /// live at (mobile/desktop internal storage), without creating it.
  Future<String> managedDatabasePath(String fileName);

  /// Resolves where a brand-new database should be written: a save-file
  /// picker prompt on desktop, or a managed-storage path on mobile. Returns
  /// null when the user cancels the picker.
  Future<String?> resolveOutputFilePath(String preferredFileName);

  /// Writes freshly-created KDBX bytes to storage and returns the final
  /// path.
  Future<String> createDatabase({
    required String outputFile,
    required Uint8List databaseBytes,
  });

  /// Whether the key file at [keyFilePath] exists on disk.
  Future<bool> keyFileExists(String keyFilePath);

  /// Reads raw key-file bytes (used to build KDBX composite credentials).
  Future<Uint8List> readKeyFileBytes(String keyFilePath);

  /// Persists a key file (imported or freshly generated) to managed storage
  /// on mobile/desktop, or to [selectedPath] on desktop-without-managed-
  /// storage.
  Future<String> saveKeyFile({
    required String fileName,
    required Uint8List keyFileBytes,
    String? selectedPath,
  });

  /// Copies [keyFilePath] into managed key storage if it is not already
  /// there (no-op / passthrough where managed storage does not apply).
  Future<String?> ensureManagedKeyFilePath(String? keyFilePath);

  /// Deletes the file at [path] (used by `removeAndDeleteFile`).
  Future<void> deleteFile(String path);

  /// Copies the file at [sourcePath] to [targetPath], overwriting an
  /// existing target (same semantics as `File.copy`). Used by the
  /// presentation export flows and the dated pre-rekey backup, which per
  /// spec 008 T102 must not touch `dart:io` directly.
  Future<void> copyFile({
    required String sourcePath,
    required String targetPath,
  });

  /// Renames/moves the file at [sourcePath] to [targetPath] (same
  /// semantics as `File.rename`). Used by the database-settings rename and
  /// its rollback (spec 008 T102).
  Future<void> renameFile({
    required String sourcePath,
    required String targetPath,
  });
}
