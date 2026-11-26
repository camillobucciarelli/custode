import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/database_import_service.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_encryption.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_download_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/validate_database_usecase.dart';
import 'package:path/path.dart' as p;

/// `readEncryption` reads only the outer header, without credentials, and
/// never throws.
void main() {
  late Directory tempDir;
  late DatabaseImportService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('read_encryption_test_');
    service = DatabaseImportService(
      validateDatabaseUseCase: ValidateDatabaseUseCase(),
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('reads cipher, KDF and cost of a real vault', () async {
    final created = await const CreateDatabaseDownloadUseCase()(
      const CreateDatabaseDownloadRequest(
        password: 'kv-test-only-not-a-real-password',
        encryption: VaultEncryption(
          cipher: VaultCipher.twofish,
          kdf: VaultKdf.argon2d,
          iterations: 1,
          memoryBytes: 64 * 1024,
          parallelism: 1,
        ),
      ),
    );
    final path = p.join(tempDir.path, 'vault.kdbx');
    await File(path).writeAsBytes(created.databaseBytes);

    expect(
      await service.readEncryption(path),
      const VaultEncryption(
        cipher: VaultCipher.twofish,
        kdf: VaultKdf.argon2d,
        kdbxVersion: '4.0',
        iterations: 1,
        memoryBytes: 64 * 1024,
        parallelism: 1,
      ),
    );
  });

  test('missing file is null', () async {
    expect(
      await service.readEncryption(p.join(tempDir.path, 'missing.kdbx')),
      isNull,
    );
  });

  test('garbage bytes are null', () async {
    final path = p.join(tempDir.path, 'garbage.kdbx');
    await File(path).writeAsBytes(List.generate(512, (i) => i % 251));
    expect(await service.readEncryption(path), isNull);
  });

  test('KDBX signature with a truncated header is null', () async {
    final path = p.join(tempDir.path, 'truncated.kdbx');
    await File(path).writeAsBytes([
      0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, //
      0x00, 0x00, 0x04, 0x00, 0x02, 0x10,
    ]);
    expect(await service.readEncryption(path), isNull);
  });

  test('empty file is null', () async {
    final path = p.join(tempDir.path, 'empty.kdbx');
    await File(path).writeAsBytes(const []);
    expect(await service.readEncryption(path), isNull);
  });
}
