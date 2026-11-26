import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_encryption.dart';
import 'package:password_manager/features/password_manager/domain/usecases/vault_encryption_kdbx.dart';

void main() {
  test('defaults are AES-256 + Argon2id at KeePassXC cost', () {
    final header = kdbxHeaderFor(VaultEncryption.defaults);

    expect(header.cipher, Cipher.aes);
    expect(
      header.kdfConfig,
      const KdbxArgon2KdfConfig(
        type: KdfType.Argon2id,
        iterations: 10,
        memoryBytes: 64 * 1024 * 1024,
        parallelism: 4,
      ),
    );
    expect(
      vaultEncryptionOf(header),
      const VaultEncryption(
        cipher: VaultCipher.aes256,
        kdf: VaultKdf.argon2id,
        kdbxVersion: '4.0',
        iterations: 10,
        memoryBytes: 64 * 1024 * 1024,
        parallelism: 4,
      ),
    );
  });

  test('AES-KDF defaults to 1,000,000 rounds', () {
    final header = kdbxHeaderFor(
      const VaultEncryption(cipher: VaultCipher.aes256, kdf: VaultKdf.aesKdf),
    );

    expect(header.kdfConfig, const KdbxAesKdfConfig(rounds: 1000000));
  });

  for (final cipher in VaultCipher.values) {
    for (final kdf in VaultKdf.values) {
      test('round trips ${cipher.label} + ${kdf.label} with custom cost', () {
        final requested = kdf == VaultKdf.aesKdf
            ? VaultEncryption(cipher: cipher, kdf: kdf, rounds: 7)
            : VaultEncryption(
                cipher: cipher,
                kdf: kdf,
                iterations: 2,
                memoryBytes: 1024 * 1024,
                parallelism: 1,
              );

        final read = vaultEncryptionOf(kdbxHeaderFor(requested));

        expect(read.cipher, cipher);
        expect(read.kdf, kdf);
        expect(read.kdbxVersion, '4.0');
        expect(read.rounds, requested.rounds);
        expect(read.iterations, requested.iterations);
        expect(read.memoryBytes, requested.memoryBytes);
        expect(read.parallelism, requested.parallelism);
      });
    }
  }

  test('labels', () {
    expect(VaultCipher.values.map((c) => c.label), [
      'AES-256',
      'ChaCha20',
      'Twofish',
    ]);
    expect(VaultKdf.values.map((k) => k.label), [
      'Argon2id',
      'Argon2d',
      'AES-KDF',
    ]);
  });
}
