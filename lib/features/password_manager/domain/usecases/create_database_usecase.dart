import 'dart:math';
import 'dart:typed_data';

import 'package:kdbx/kdbx.dart';
import 'package:path/path.dart' as p;

import '../errors/database_access_failure.dart';
import '../repositories/database_file_repository.dart';
import 'vault_credentials.dart';

/// Non-secret request: [password] is held only transiently for the duration
/// of this call (C-5) and is never copied into BLoC/coordinator state.
class CreateDatabaseRequest {
  const CreateDatabaseRequest({
    required this.databaseFileName,
    required this.password,
    this.keyFilePath,
    this.generateKeyFile = false,
    this.generatedKeyFilePath,
  });

  final String databaseFileName;
  final String password;
  final String? keyFilePath;
  final bool generateKeyFile;
  final String? generatedKeyFilePath;
}

class CreateDatabaseResult {
  const CreateDatabaseResult({
    required this.databasePath,
    required this.fileHash,
    this.keyFilePath,
  });

  final String databasePath;
  final String fileHash;
  final String? keyFilePath;
}

/// KDBX/key generation and partial-output rollback (C-5, C-7). Lives in
/// `domain/usecases` (not the coordinator) so it may use `dart:io`/`kdbx`
/// directly, exactly like `UnlockDatabaseUseCase`; the coordinator only ever
/// calls this use case and never touches file/KDBX APIs itself.
class CreateDatabaseUseCase {
  CreateDatabaseUseCase({required this.databaseFileRepository});

  final DatabaseFileRepository databaseFileRepository;

  /// Returns null when the user cancels the destination picker (desktop
  /// "save file" dialog) — not a failure, nothing was created.
  ///
  /// spec 015 FR-2 (trust boundary): a request with no credential factor is
  /// rejected here with [MissingCredentialFactorFailure], regardless of what
  /// the UI validated. FR-7: a selected key file that is missing, unreadable
  /// or empty is rejected before any byte is written. FR-5: key material is
  /// generated during submission, never earlier.
  Future<CreateDatabaseResult?> call(CreateDatabaseRequest request) async {
    final hasPassword = request.password.isNotEmpty;
    final selectedKeyFilePathRaw = request.keyFilePath?.trim();
    final hasSelectedKey =
        selectedKeyFilePathRaw != null && selectedKeyFilePathRaw.isNotEmpty;
    if (!hasPassword && !hasSelectedKey && !request.generateKeyFile) {
      throw const MissingCredentialFactorFailure();
    }

    // FR-7: validate the selected key BEFORE creating anything. Any readable
    // non-empty file is valid — no format restriction.
    Uint8List? keyFileBytes;
    if (hasSelectedKey) {
      if (!await databaseFileRepository.keyFileExists(selectedKeyFilePathRaw)) {
        throw const KeyFileMissingFailure();
      }
      try {
        keyFileBytes = await databaseFileRepository.readKeyFileBytes(
          selectedKeyFilePathRaw,
        );
      } catch (_) {
        throw const InvalidKeyFileFailure();
      }
      if (keyFileBytes.isEmpty) {
        throw const InvalidKeyFileFailure();
      }
    }

    var outputFile = await databaseFileRepository.resolveOutputFilePath(
      request.databaseFileName,
    );
    if (outputFile == null || outputFile.trim().isEmpty) {
      return null;
    }
    if (!outputFile.toLowerCase().endsWith('.kdbx')) {
      outputFile += '.kdbx';
    }

    // FR-5: generated key bytes are produced at submit, and the branch runs
    // under test like any other code (the FLUTTER_TEST shortcut is gone).
    String? keyFilePath = selectedKeyFilePathRaw;
    if (request.generateKeyFile) {
      final generatedBytes = _generateRandomKeyFileBytes();
      final generatedPath = request.generatedKeyFilePath;
      keyFilePath = await databaseFileRepository.saveKeyFile(
        // The managed on-disk name is opaque (spec 014 FR-3); this name only
        // matters on the non-managed path.
        fileName: generatedPath == null
            ? 'generated-key'
            : p.basename(generatedPath),
        keyFileBytes: generatedBytes,
        selectedPath: generatedPath,
      );
      keyFileBytes = await databaseFileRepository.readKeyFileBytes(keyFilePath);
    } else if (hasSelectedKey) {
      // FR-6: the selected key is copied into managed storage; the user's
      // original file is never modified and never deleted.
      keyFilePath = await databaseFileRepository.ensureManagedKeyFilePath(
        selectedKeyFilePathRaw,
      );
    }

    final credentials = composeVaultCredentials(
      password: request.password,
      keyFileBytes: keyFileBytes,
    );
    final kdbx = KdbxFormat().create(credentials, 'New Database');
    final savedBytes = await kdbx.save();

    final createdPath = await databaseFileRepository.createDatabase(
      outputFile: outputFile,
      databaseBytes: savedBytes,
    );

    try {
      final fileHash = await databaseFileRepository.hashFile(createdPath);
      return CreateDatabaseResult(
        databasePath: createdPath,
        fileHash: fileHash,
        keyFilePath: keyFilePath,
      );
    } catch (_) {
      // Partial output cleanup: creation succeeded but post-processing
      // (hashing) failed. Leave no half-created database behind.
      try {
        await databaseFileRepository.deleteFile(createdPath);
      } catch (_) {}
      // FR-9: delete only key material this attempt created, never the
      // user's selected file.
      if (request.generateKeyFile && keyFilePath != null) {
        try {
          await databaseFileRepository.deleteFile(keyFilePath);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Uint8List _generateRandomKeyFileBytes() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(64, (_) => random.nextInt(256)),
    );
  }
}
