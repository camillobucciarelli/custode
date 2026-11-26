import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:password_manager/features/password_manager/domain/errors/database_access_failure.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_encryption.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_download_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/vault_credentials.dart';
import 'package:password_manager/features/password_manager/domain/usecases/vault_encryption_kdbx.dart';

/// spec 015 FR-14 / AC-8 (T020/T022): the download-only web path, verified
/// without a real browser. The two artefacts must be mutually consistent —
/// the produced database opens with the produced key — and the use case
/// touches no filesystem at all (it has no repository to touch).
void main() {
  const useCase = CreateDatabaseDownloadUseCase();

  Future<void> expectOpens(
    Uint8List databaseBytes, {
    required String password,
    Uint8List? keyFileBytes,
  }) async {
    await KdbxFormat().read(
      databaseBytes,
      composeVaultCredentials(password: password, keyFileBytes: keyFileBytes),
    );
  }

  test('the requested encryption is written to the header', () async {
    const requested = VaultEncryption(
      cipher: VaultCipher.chaCha20,
      kdf: VaultKdf.aesKdf,
      rounds: 10,
    );
    final download = await useCase(
      const CreateDatabaseDownloadRequest(
        password: 'kv-test-only-not-a-real-password',
        encryption: requested,
      ),
    );
    final read = vaultEncryptionOf(
      KdbxHeader.readFromBytes(download.databaseBytes),
    );
    expect(read.cipher, VaultCipher.chaCha20);
    expect(read.kdf, VaultKdf.aesKdf);
    expect(read.rounds, 10);
    await expectOpens(
      download.databaseBytes,
      password: 'kv-test-only-not-a-real-password',
    );
  });

  test('password only: the database opens with the password', () async {
    final download = await useCase(
      const CreateDatabaseDownloadRequest(
        password: 'kv-test-only-not-a-real-password',
      ),
    );
    expect(download.keyFileBytes, isNull);
    await expectOpens(
      download.databaseBytes,
      password: 'kv-test-only-not-a-real-password',
    );
  });

  test('generated key: AC-8 — the downloaded .kdbx opens with the '
      'downloaded key', () async {
    final download = await useCase(
      const CreateDatabaseDownloadRequest(password: '', generateKeyFile: true),
    );
    expect(download.keyFileBytes, hasLength(64));
    await expectOpens(
      download.databaseBytes,
      password: '',
      keyFileBytes: download.keyFileBytes,
    );
  });

  test('selected key bytes: both factors are honoured', () async {
    final selected = Uint8List.fromList(List.generate(64, (i) => i));
    final download = await useCase(
      CreateDatabaseDownloadRequest(
        password: 'kv-test-only-not-a-real-password',
        selectedKeyFileBytes: selected,
      ),
    );
    expect(download.keyFileBytes, selected);
    await expectOpens(
      download.databaseBytes,
      password: 'kv-test-only-not-a-real-password',
      keyFileBytes: selected,
    );
    await expectLater(
      expectOpens(download.databaseBytes, password: ''),
      throwsA(isA<KdbxInvalidKeyException>()),
    );
  });

  test('no factor is rejected at the trust boundary', () async {
    await expectLater(
      useCase(const CreateDatabaseDownloadRequest(password: '')),
      throwsA(isA<MissingCredentialFactorFailure>()),
    );
  });

  test('an empty selected key file is rejected', () async {
    await expectLater(
      useCase(
        CreateDatabaseDownloadRequest(
          password: '',
          selectedKeyFileBytes: Uint8List(0),
        ),
      ),
      throwsA(isA<InvalidKeyFileFailure>()),
    );
  });
}
