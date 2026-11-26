// Shared in-memory fake domain ports for spec-003 BLoC-level tests.
//
// Per spec-003 C-7/T2, `DatabaseSessionCoordinator` is a single concrete
// class (no interface). BLoC tests build a *real* coordinator wired with
// these fakes instead of faking the coordinator itself.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:kdbx/kdbx.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_transaction.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_conflict.dart';
import 'package:password_manager/features/password_manager/domain/models/unlocked_database.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_encryption.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_file_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_security_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_session_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/unlock_database_usecase.dart';

class FakeDatabaseFileRepository implements DatabaseFileRepository {
  final Set<String> existingPaths = {};
  Object? Function(String path)? openExistingPathError;
  DatabaseImportResult Function(String path)? openExistingPathResult;

  /// When set, `openExistingPath` waits for it: keeps a busy state on screen.
  Future<void>? openExistingPathGate;
  StagedDatabaseImport? stageResult;
  Object? stageError;
  DatabaseFileCommit? commitResult;
  Object? commitError;
  String? resolveOutputFilePathResult = 'new_database.kdbx';
  String createDatabaseResult = '/tmp/created.kdbx';
  String hashFileResult = 'hash';
  final List<StagedDatabaseImport> discarded = [];
  final List<DatabaseFileCommit> rolledBack = [];
  final List<String?> commitTargets = [];

  @override
  Future<bool> fileExists(String path) async => existingPaths.contains(path);

  final List<UnlockedDatabase> adopted = [];

  @override
  void adoptUnlockedDatabase(UnlockedDatabase unlocked) =>
      adopted.add(unlocked);

  final Map<String, VaultEncryption> encryptionByPath = {};
  final List<String> readEncryptionPaths = [];

  @override
  Future<VaultEncryption?> readEncryption(String path) async {
    readEncryptionPaths.add(path);
    return encryptionByPath[path];
  }

  // spec 008 T102: `VaultSessionCoordinator` renames/copies through the
  // domain port. Its tests run against real temp files, so these perform
  // the real filesystem operation while recording the call.
  final List<({String sourcePath, String targetPath})> copiedFiles = [];
  final List<({String sourcePath, String targetPath})> renamedFiles = [];

  @override
  Future<void> copyFile({
    required String sourcePath,
    required String targetPath,
  }) async {
    copiedFiles.add((sourcePath: sourcePath, targetPath: targetPath));
    await File(sourcePath).copy(targetPath);
  }

  @override
  Future<void> renameFile({
    required String sourcePath,
    required String targetPath,
  }) async {
    renamedFiles.add((sourcePath: sourcePath, targetPath: targetPath));
    await File(sourcePath).rename(targetPath);
  }

  @override
  Future<String> hashFile(String path) async => hashFileResult;

  @override
  Future<DatabaseImportResult> openExistingPath(String path) async {
    await openExistingPathGate;
    final error = openExistingPathError?.call(path);
    if (error != null) {
      throw error;
    }
    if (openExistingPathResult != null) {
      return openExistingPathResult!(path);
    }
    return DatabaseImportResult(
      path: path,
      fileName: path.split('/').last,
      fileHash: hashFileResult,
      sourceType: DatabaseSourceType.local,
    );
  }

  @override
  Future<StagedDatabaseImport> stageLocalSelection({
    required String fileName,
    String? selectedPath,
    List<int>? selectedBytes,
  }) async {
    if (stageError != null) {
      throw stageError!;
    }
    return stageResult ??
        StagedDatabaseImport(
          imported: DatabaseImportResult(
            path: selectedPath ?? '/tmp/$fileName',
            fileName: fileName,
            fileHash: hashFileResult,
            sourceType: DatabaseSourceType.local,
          ),
          preferredFileName: fileName,
        );
  }

  @override
  Future<StagedDatabaseImport> stageDriveDownload({
    required String fileName,
    required Uint8List bytes,
    required String remoteFileId,
  }) async {
    if (stageError != null) {
      throw stageError!;
    }
    return stageResult ??
        StagedDatabaseImport(
          imported: DatabaseImportResult(
            path: '/tmp/$fileName',
            fileName: fileName,
            fileHash: hashFileResult,
            sourceType: DatabaseSourceType.drive,
            sourceRef: remoteFileId,
          ),
          preferredFileName: fileName,
        );
  }

  @override
  Future<void> discardStagedDatabase(StagedDatabaseImport staged) async {
    discarded.add(staged);
  }

  @override
  Future<DatabaseFileCommit> commitStagedDatabase(
    StagedDatabaseImport staged, {
    String? targetPath,
  }) async {
    commitTargets.add(targetPath);
    if (commitError != null) {
      throw commitError!;
    }
    return commitResult ??
        DatabaseFileCommit(databasePath: targetPath ?? staged.imported.path);
  }

  @override
  Future<void> finalizeDatabaseCommit(DatabaseFileCommit commit) async {}

  @override
  Future<void> rollbackDatabaseCommit(DatabaseFileCommit commit) async {
    rolledBack.add(commit);
  }

  @override
  Future<String> managedDatabasePath(String fileName) async => '/tmp/$fileName';

  @override
  Future<String?> resolveOutputFilePath(String preferredFileName) async =>
      resolveOutputFilePathResult;

  @override
  Future<String> createDatabase({
    required String outputFile,
    required Uint8List databaseBytes,
  }) async => createDatabaseResult;

  @override
  Future<bool> keyFileExists(String keyFilePath) async =>
      existingPaths.contains(keyFilePath);

  @override
  Future<Uint8List> readKeyFileBytes(String keyFilePath) async => Uint8List(0);

  @override
  Future<String> saveKeyFile({
    required String fileName,
    required Uint8List keyFileBytes,
    String? selectedPath,
  }) async => selectedPath ?? '/tmp/$fileName';

  @override
  Future<String?> ensureManagedKeyFilePath(String? keyFilePath) async {
    final error = ensureManagedKeyFileError;
    if (error != null) throw error;
    return keyFilePath;
  }

  /// When set, `ensureManagedKeyFilePath` throws it (managed import failure).
  Object? ensureManagedKeyFileError;

  @override
  Future<void> deleteFile(String path) async {
    existingPaths.remove(path);
  }
}

class FakeDatabaseSessionRepository implements DatabaseSessionRepository {
  String? keyFilePath;

  /// spec-011 FR-4: one stored credential per database id.
  final Map<String, String> masterPasswords = {};

  /// When set, `saveMasterPassword` throws it (keystore failure).
  Object? saveError;

  @override
  Future<void> saveMasterPassword(String databaseId, String password) async {
    final error = saveError;
    if (error != null) throw error;
    masterPasswords[databaseId] = password;
  }

  /// When set, `getMasterPassword` throws it (keystore read failure).
  Object? readError;

  @override
  Future<String?> getMasterPassword(String databaseId) async {
    final error = readError;
    if (error != null) throw error;
    return masterPasswords[databaseId];
  }

  @override
  Future<void> clearMasterPassword(String databaseId) async {
    masterPasswords.remove(databaseId);
  }
}

class FakeDatabaseRegistryRepository implements DatabaseRegistryRepository {
  List<DatabaseRecord> records = [];
  String? activeId;

  @override
  Future<DatabaseRecord?> findByHash(String fileHash) async {
    for (final record in records) {
      if (record.fileHash == fileHash) return record;
    }
    return null;
  }

  @override
  Future<DatabaseRecord?> findBySource({
    required DatabaseSourceType sourceType,
    required String sourceRef,
  }) async {
    for (final record in records) {
      if (record.sourceType == sourceType && record.sourceRef == sourceRef) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<String?> getActive() async => activeId;

  @override
  Future<DatabaseRecord?> getById(String databaseId) async {
    for (final record in records) {
      if (record.databaseId == databaseId) return record;
    }
    return null;
  }

  @override
  Future<List<DatabaseRecord>> list() async => records;

  @override
  Future<void> remove(String databaseId) async {
    records = records
        .where((record) => record.databaseId != databaseId)
        .toList(growable: false);
  }

  @override
  Future<void> setActive(String? databaseId) async {
    activeId = databaseId;
  }

  @override
  Future<void> upsert(DatabaseRecord record) async {
    records = [
      ...records.where((item) => item.databaseId != record.databaseId),
      record,
    ];
  }
}

class FakeDatabaseSecurityRepository implements DatabaseSecurityRepository {
  final Map<String, DatabaseSecurityProfile> profiles = {};

  @override
  Future<DatabaseSecurityProfile?> getProfile(String databaseId) async =>
      profiles[databaseId];

  @override
  Future<void> removeProfile(String databaseId) async {
    profiles.remove(databaseId);
  }

  /// When set, `saveProfile` throws it (metadata storage failure).
  Object? saveError;

  @override
  Future<void> saveProfile(DatabaseSecurityProfile profile) async {
    final error = saveError;
    if (error != null) throw error;
    profiles[profile.databaseId] = profile;
  }
}

class FakeDatabaseSyncRepository implements DatabaseSyncRepository {
  bool connected = false;
  int connectCalls = 0;
  List<RemoteFile> remoteFiles = const [];
  Uint8List downloadBytes = Uint8List(0);
  final Map<String, DatabaseSyncMapping> mappings = {};
  StorageAccountSummary account = const StorageAccountSummary(
    displayLabel: 'Google Drive account',
  );

  @override
  Future<void> connect() async {
    connectCalls += 1;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<Uint8List> downloadRemoteFile(
    String fileId, {
    required String providerId,
  }) async {
    downloadProviderIds.add(providerId);
    return downloadBytes;
  }

  final List<String> downloadProviderIds = [];

  Object? mappingError;

  @override
  Future<DatabaseSyncMapping?> getMapping(String databasePath) async {
    final error = mappingError;
    if (error != null) throw error;
    return mappings[databasePath];
  }

  @override
  Future<List<DatabaseSyncMapping>> getAllMappings() async {
    final error = mappingError;
    if (error != null) throw error;
    return mappings.values.toList(growable: false);
  }

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<DatabaseSyncMapping> linkDatabaseToRemote({
    required String databasePath,
    String? remoteFileId,
    String? remoteFileName,
  }) async {
    final mapping = DatabaseSyncMapping(
      databasePath: databasePath,
      providerId: 'google_drive',
      remoteFileId: remoteFileId ?? 'remote-id',
      remoteFileName: remoteFileName ?? 'remote.kdbx',
      autoSyncEnabled: true,
    );
    mappings[databasePath] = mapping;
    return mapping;
  }

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) async =>
      remoteFiles;

  @override
  Future<DatabaseSyncMappingPathMove> moveMappingPath({
    required String fromDatabasePath,
    required String toDatabasePath,
  }) async {
    final move = DatabaseSyncMappingPathMove(
      fromDatabasePath: fromDatabasePath,
      toDatabasePath: toDatabasePath,
      sourceBefore: mappings[fromDatabasePath],
      destinationBefore: mappings[toDatabasePath],
    );
    final mapping = mappings.remove(fromDatabasePath);
    if (mapping != null) {
      mappings[toDatabasePath] = mapping.copyWith(databasePath: toDatabasePath);
    }
    return move;
  }

  @override
  Future<void> restoreMappingPathMove(DatabaseSyncMappingPathMove move) async {
    mappings
      ..remove(move.fromDatabasePath)
      ..remove(move.toDatabasePath);
    if (move.sourceBefore != null) {
      mappings[move.fromDatabasePath] = move.sourceBefore!;
    }
    if (move.destinationBefore != null) {
      mappings[move.toDatabasePath] = move.destinationBefore!;
    }
  }

  @override
  Future<void> removeMapping(String databasePath) async {
    mappings.remove(databasePath);
  }

  @override
  Future<void> setAutoSync(String databasePath, bool enabled) async {}

  @override
  Future<SyncNowResult> syncNow(
    String databasePath, {
    SyncConflictResolution? resolution,
  }) async => const SyncNowSuccess();

  Object? accountError;

  @override
  Future<StorageAccountSummary> getConnectedAccount() async {
    final error = accountError;
    if (error != null) throw error;
    return account;
  }
}

/// `UnlockDatabaseUseCase` reads real KDBX bytes off disk; tests override
/// `call` instead of faking `dart:io`, avoiding a real `.kdbx` fixture for
/// BLoC-level event/state assertions.
class FakeUnlockDatabaseUseCase extends UnlockDatabaseUseCase {
  int callCount = 0;
  Object? error;
  String? lastDatabasePath;
  String? lastPassword;
  String? lastKeyFilePath;

  /// When true, `call()` never resolves during the test — used to capture a
  /// stable C-4 `decrypting` frame (entered before the KDBX await).
  bool hang = false;
  final Completer<UnlockedDatabase> _hangCompleter =
      Completer<UnlockedDatabase>();

  @override
  Future<UnlockedDatabase> call({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async {
    callCount += 1;
    lastDatabasePath = databasePath;
    lastPassword = password;
    lastKeyFilePath = keyFilePath;
    if (hang) {
      return _hangCompleter.future;
    }
    if (error != null) {
      throw error!;
    }
    return fakeUnlockedDatabase(databasePath);
  }
}

/// A stand-in for what a real unlock decrypts; `create` runs no KDF.
UnlockedDatabase fakeUnlockedDatabase(String databasePath) => UnlockedDatabase(
  databasePath: databasePath,
  bytes: Uint8List(0),
  file: KdbxFormat().create(Credentials(ProtectedValue.fromString('x')), 'f'),
);

/// `CreateDatabaseUseCase` builds and saves a real KDBX, whose key derivation
/// runs off the fake test clock. Widget tests that only assert what the
/// coordinator and the screen do after a successful create override `call`;
/// the use case itself is covered by `create_database_usecase_test.dart`.
class FakeCreateDatabaseUseCase extends CreateDatabaseUseCase {
  FakeCreateDatabaseUseCase({required super.databaseFileRepository});

  CreateDatabaseRequest? lastRequest;

  @override
  Future<CreateDatabaseResult?> call(CreateDatabaseRequest request) async {
    lastRequest = request;
    return CreateDatabaseResult(
      databasePath: '/tmp/created.kdbx',
      fileHash: 'hash',
      keyFilePath: request.generateKeyFile
          ? '/tmp/keys/generated.key'
          : request.keyFilePath,
    );
  }
}
