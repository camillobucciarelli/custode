// spec-003 C-5/T3: CreateDatabaseUseCase success + partial-output rollback
// through a fake DatabaseFileRepository port (no real disk I/O needed).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_transaction.dart';
import 'package:password_manager/features/password_manager/domain/models/unlocked_database.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_encryption.dart';
import 'package:password_manager/features/password_manager/domain/errors/database_access_failure.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_file_repository.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/vault_credentials.dart';
import 'package:password_manager/features/password_manager/domain/usecases/vault_encryption_kdbx.dart';

void main() {
  group('CreateDatabaseUseCase', () {
    late _FakeDatabaseFileRepository repository;
    late CreateDatabaseUseCase useCase;

    setUp(() {
      repository = _FakeDatabaseFileRepository();
      useCase = CreateDatabaseUseCase(databaseFileRepository: repository);
    });

    test('returns null when the destination picker is cancelled', () async {
      repository.resolveOutputFilePathResult = null;

      final result = await useCase(
        const CreateDatabaseRequest(
          databaseFileName: 'vault',
          password: 'kv-test-only-not-a-real-password',
        ),
      );

      expect(result, isNull);
      expect(repository.createDatabaseCalls, 0);
    });

    test('creates a database and returns its path/hash', () async {
      repository.resolveOutputFilePathResult = 'vault.kdbx';
      repository.createDatabaseResult = '/managed/vault.kdbx';
      repository.hashFileResult = 'hash-123';

      final result = await useCase(
        const CreateDatabaseRequest(
          databaseFileName: 'vault',
          password: 'kv-test-only-not-a-real-password',
        ),
      );

      expect(result, isNotNull);
      expect(result!.databasePath, '/managed/vault.kdbx');
      expect(result.fileHash, 'hash-123');
      expect(repository.createDatabaseCalls, 1);
    });

    test(
      'rolls back (deletes) partial output when post-create hashing fails',
      () async {
        repository.resolveOutputFilePathResult = 'vault.kdbx';
        repository.createDatabaseResult = '/managed/vault.kdbx';
        repository.hashFileError = Exception('disk full');

        await expectLater(
          useCase(
            const CreateDatabaseRequest(
              databaseFileName: 'vault',
              password: 'kv-test-only-not-a-real-password',
            ),
          ),
          throwsException,
        );

        expect(repository.deletedPaths, contains('/managed/vault.kdbx'));
      },
    );

    // spec 015 T003: the FLUTTER_TEST shortcut is gone — the key branches
    // below run for real. `database_session_coordinator_test.dart` covers
    // the coordinator-level transaction separately.

    group('spec 015 FR-2 credential matrix (AC-2)', () {
      test('no factor at all is rejected at the trust boundary', () async {
        await expectLater(
          useCase(
            const CreateDatabaseRequest(databaseFileName: 'v', password: ''),
          ),
          throwsA(isA<MissingCredentialFactorFailure>()),
        );
        expect(repository.createDatabaseCalls, 0);
      });

      test('key-file-only (selected) is a valid combination', () async {
        repository.keyFiles['/picked/my.key'] = [1, 2, 3];
        final result = await useCase(
          const CreateDatabaseRequest(
            databaseFileName: 'v',
            password: '',
            keyFilePath: '/picked/my.key',
          ),
        );
        expect(result, isNotNull);
        expect(result!.keyFilePath, '/managed/keys/opaque-copy');
        expect(repository.ensuredManagedKeyPaths, ['/picked/my.key']);
      });

      test('key-file-only (generated) is a valid combination and the key is '
          'generated at submit (FR-5)', () async {
        final result = await useCase(
          const CreateDatabaseRequest(
            databaseFileName: 'v',
            password: '',
            generateKeyFile: true,
          ),
        );
        expect(result, isNotNull);
        expect(repository.savedKeyFileBytesLength, 64);
        expect(result!.keyFilePath, '/managed/keys/opaque-generated');
      });

      test('password plus selected key is a valid combination', () async {
        repository.keyFiles['/picked/my.key'] = [9];
        final result = await useCase(
          const CreateDatabaseRequest(
            databaseFileName: 'v',
            password: 'kv-test-only-not-a-real-password',
            keyFilePath: '/picked/my.key',
          ),
        );
        expect(result, isNotNull);
      });
    });

    group('spec 015 FR-7 key-file validation', () {
      test('a missing selected key file blocks creation', () async {
        await expectLater(
          useCase(
            const CreateDatabaseRequest(
              databaseFileName: 'v',
              password: '',
              keyFilePath: '/picked/absent.key',
            ),
          ),
          throwsA(isA<KeyFileMissingFailure>()),
        );
        expect(repository.createDatabaseCalls, 0);
      });

      test('an empty selected key file blocks creation', () async {
        repository.keyFiles['/picked/empty.key'] = const [];
        await expectLater(
          useCase(
            const CreateDatabaseRequest(
              databaseFileName: 'v',
              password: '',
              keyFilePath: '/picked/empty.key',
            ),
          ),
          throwsA(isA<InvalidKeyFileFailure>()),
        );
        expect(repository.createDatabaseCalls, 0);
      });

      test('an unreadable selected key file blocks creation', () async {
        repository.keyFiles['/picked/locked.key'] = [1];
        repository.readKeyFileError = Exception('EACCES');
        await expectLater(
          useCase(
            const CreateDatabaseRequest(
              databaseFileName: 'v',
              password: '',
              keyFilePath: '/picked/locked.key',
            ),
          ),
          throwsA(isA<InvalidKeyFileFailure>()),
        );
        expect(repository.createDatabaseCalls, 0);
      });
    });

    group('spec 015 FR-9 key-material cleanup on hashing failure', () {
      test('a generated key created by this attempt is deleted', () async {
        repository.hashFileError = Exception('disk full');
        await expectLater(
          useCase(
            const CreateDatabaseRequest(
              databaseFileName: 'v',
              password: '',
              generateKeyFile: true,
            ),
          ),
          throwsException,
        );
        expect(
          repository.deletedPaths,
          containsAll([
            '/managed/vault.kdbx',
            '/managed/keys/opaque-generated',
          ]),
        );
      });

      test('the user-selected key file is never deleted', () async {
        repository.keyFiles['/picked/my.key'] = [1];
        repository.hashFileError = Exception('disk full');
        await expectLater(
          useCase(
            const CreateDatabaseRequest(
              databaseFileName: 'v',
              password: '',
              keyFilePath: '/picked/my.key',
            ),
          ),
          throwsException,
        );
        expect(repository.deletedPaths, isNot(contains('/picked/my.key')));
        expect(
          repository.deletedPaths,
          isNot(contains('/managed/keys/opaque-copy')),
          reason:
              'the managed copy is content the user still owns; only the '
              'orphan .kdbx goes',
        );
      });
    });

    group('encryption', () {
      const password = 'kv-test-only-not-a-real-password';

      Future<KdbxHeader> createHeader(VaultEncryption? encryption) async {
        await useCase(
          CreateDatabaseRequest(
            databaseFileName: 'vault',
            password: password,
            encryption: encryption,
          ),
        );
        final bytes = repository.createdBytes!;
        // The file really opens with the chosen cipher and KDF.
        await KdbxFormat().read(
          bytes,
          composeVaultCredentials(password: password),
        );
        return KdbxHeader.readFromBytes(bytes);
      }

      test('no encryption requested writes AES-256 + Argon2id defaults', () {
        // Header only: the KeePassXC-cost KDF is not run twice here.
        expect(
          kdbxHeaderFor(VaultEncryption.defaults).kdfConfig,
          const KdbxArgon2KdfConfig(type: KdfType.Argon2id),
        );
      });

      for (final cipher in VaultCipher.values) {
        for (final kdf in VaultKdf.values) {
          test('creates ${cipher.label} + ${kdf.label}', () async {
            // Low cost so the test stays fast.
            final requested = VaultEncryption(
              cipher: cipher,
              kdf: kdf,
              rounds: kdf == VaultKdf.aesKdf ? 10 : null,
              iterations: kdf == VaultKdf.aesKdf ? null : 1,
              memoryBytes: kdf == VaultKdf.aesKdf ? null : 64 * 1024,
              parallelism: kdf == VaultKdf.aesKdf ? null : 1,
            );

            final header = await createHeader(requested);

            final read = vaultEncryptionOf(header);
            expect(read.cipher, cipher);
            expect(read.kdf, kdf);
            expect(read.rounds, requested.rounds);
            expect(read.iterations, requested.iterations);
            expect(read.memoryBytes, requested.memoryBytes);
          });
        }
      }
    });
  });
}

class _FakeDatabaseFileRepository implements DatabaseFileRepository {
  String? resolveOutputFilePathResult = 'vault.kdbx';
  String createDatabaseResult = '/managed/vault.kdbx';
  String hashFileResult = 'hash';
  Object? hashFileError;
  String? saveKeyFileResult;
  int createDatabaseCalls = 0;
  Uint8List? createdBytes;
  int? savedKeyFileBytesLength;
  final List<String> deletedPaths = [];

  @override
  Future<String> createDatabase({
    required String outputFile,
    required Uint8List databaseBytes,
  }) async {
    createDatabaseCalls += 1;
    createdBytes = databaseBytes;
    return createDatabaseResult;
  }

  @override
  Future<void> deleteFile(String path) async {
    deletedPaths.add(path);
  }

  @override
  Future<VaultEncryption?> readEncryption(String path) async => null;

  @override
  void adoptUnlockedDatabase(UnlockedDatabase unlocked) {}

  @override
  Future<void> copyFile({
    required String sourcePath,
    required String targetPath,
  }) async {
    throw UnimplementedError('copyFile is not exercised by this use case');
  }

  @override
  Future<void> renameFile({
    required String sourcePath,
    required String targetPath,
  }) async {
    throw UnimplementedError('renameFile is not exercised by this use case');
  }

  final List<String?> ensuredManagedKeyPaths = [];

  @override
  Future<String?> ensureManagedKeyFilePath(String? keyFilePath) async {
    ensuredManagedKeyPaths.add(keyFilePath);
    if (keyFilePath == null) return null;
    final managed = '/managed/keys/opaque-copy';
    keyFiles[managed] = keyFiles[keyFilePath] ?? const [1];
    return managed;
  }

  @override
  Future<String> hashFile(String path) async {
    if (hashFileError != null) {
      throw hashFileError!;
    }
    return hashFileResult;
  }

  Map<String, List<int>> keyFiles = {};
  Object? readKeyFileError;

  @override
  Future<Uint8List> readKeyFileBytes(String keyFilePath) async {
    if (readKeyFileError != null) {
      throw readKeyFileError!;
    }
    return Uint8List.fromList(keyFiles[keyFilePath] ?? const []);
  }

  @override
  Future<String> saveKeyFile({
    required String fileName,
    required Uint8List keyFileBytes,
    String? selectedPath,
  }) async {
    savedKeyFileBytesLength = keyFileBytes.length;
    final path = saveKeyFileResult ?? '/managed/keys/opaque-generated';
    keyFiles[path] = keyFileBytes;
    return path;
  }

  @override
  Future<String?> resolveOutputFilePath(String preferredFileName) async =>
      resolveOutputFilePathResult;

  // Unused by CreateDatabaseUseCase; not exercised by these tests.
  @override
  Future<DatabaseFileCommit> commitStagedDatabase(
    StagedDatabaseImport staged, {
    String? targetPath,
  }) => throw UnimplementedError();

  @override
  Future<void> discardStagedDatabase(StagedDatabaseImport staged) =>
      throw UnimplementedError();

  @override
  Future<bool> fileExists(String path) => throw UnimplementedError();

  @override
  Future<void> finalizeDatabaseCommit(DatabaseFileCommit commit) =>
      throw UnimplementedError();

  @override
  Future<bool> keyFileExists(String keyFilePath) async =>
      keyFiles.containsKey(keyFilePath);

  @override
  Future<String> managedDatabasePath(String fileName) =>
      throw UnimplementedError();

  @override
  Future<DatabaseImportResult> openExistingPath(String path) =>
      throw UnimplementedError();

  @override
  Future<void> rollbackDatabaseCommit(DatabaseFileCommit commit) =>
      throw UnimplementedError();

  @override
  Future<StagedDatabaseImport> stageDriveDownload({
    required String fileName,
    required Uint8List bytes,
    required String remoteFileId,
  }) => throw UnimplementedError();

  @override
  Future<StagedDatabaseImport> stageLocalSelection({
    required String fileName,
    String? selectedPath,
    List<int>? selectedBytes,
  }) => throw UnimplementedError();
}
