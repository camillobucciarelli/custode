import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:kdbx/kdbx.dart';

import '../errors/database_access_failure.dart';
import '../models/vault_encryption.dart';
import 'vault_credentials.dart';
import 'vault_encryption_kdbx.dart';

/// spec 015 FR-14: the web create path is download-only. This use case
/// builds both artefacts entirely in memory — no registry entry, no opened
/// vault, no persisted credential, no filesystem access at all.
class CreateDatabaseDownloadRequest {
  const CreateDatabaseDownloadRequest({
    required this.password,
    this.selectedKeyFileBytes,
    this.generateKeyFile = false,
    this.encryption,
  });

  final String password;

  /// Null means [VaultEncryption.defaults].
  final VaultEncryption? encryption;

  /// Bytes of a key file the user picked (`withData: true` — web has no
  /// durable path to read from).
  final Uint8List? selectedKeyFileBytes;
  final bool generateKeyFile;
}

/// The two artefacts, mutually consistent: [databaseBytes] opens with
/// [keyFileBytes] (and/or the password). The caller retains this object so
/// a retry after a failed download reuses the SAME generated key —
/// regenerating would hand the user a key that does not open the database
/// they already downloaded.
class CreateDatabaseDownload {
  const CreateDatabaseDownload({
    required this.databaseBytes,
    this.keyFileBytes,
  });

  final Uint8List databaseBytes;
  final Uint8List? keyFileBytes;
}

class CreateDatabaseDownloadUseCase {
  const CreateDatabaseDownloadUseCase();

  Future<CreateDatabaseDownload> call(
    CreateDatabaseDownloadRequest request,
  ) async {
    final selected = request.selectedKeyFileBytes;
    final hasPassword = request.password.isNotEmpty;
    if (!hasPassword && selected == null && !request.generateKeyFile) {
      throw const MissingCredentialFactorFailure();
    }
    if (selected != null && selected.isEmpty) {
      throw const InvalidKeyFileFailure();
    }

    // FR-14: dart2js `Uint64` behaviour — set at the web boundary.
    if (kIsWeb) {
      KdbxFormat.dartWebWorkaround = true;
    }

    final keyBytes = request.generateKeyFile
        ? _generateRandomKeyFileBytes()
        : selected;
    final credentials = composeVaultCredentials(
      password: request.password,
      keyFileBytes: keyBytes,
    );
    final kdbx = KdbxFormat().create(
      credentials,
      'New Database',
      header: kdbxHeaderFor(request.encryption ?? VaultEncryption.defaults),
    );
    final databaseBytes = await kdbx.save();
    return CreateDatabaseDownload(
      databaseBytes: databaseBytes,
      keyFileBytes: keyBytes,
    );
  }

  Uint8List _generateRandomKeyFileBytes() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(64, (_) => random.nextInt(256)),
    );
  }
}
