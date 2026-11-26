import 'package:kdbx/kdbx.dart';

import '../models/vault_encryption.dart';

// The one mapping between VaultEncryption and `kdbx` header types, shared by
// the create use cases and the data layer (header read, open vault). Lives
// next to `vault_credentials.dart` because domain use cases already build
// KDBX files directly; presentation never sees `kdbx` types.

/// Header for a new KDBX 4 vault. Null cost fields take the library
/// defaults, which are KeePassXC's.
KdbxHeader kdbxHeaderFor(VaultEncryption encryption) {
  return KdbxHeader.createV4(
    cipher: switch (encryption.cipher) {
      VaultCipher.aes256 => Cipher.aes,
      VaultCipher.chaCha20 => Cipher.chaCha20,
      VaultCipher.twofish => Cipher.twofish,
    },
    kdf: switch (encryption.kdf) {
      VaultKdf.aesKdf => KdbxAesKdfConfig(
        rounds: encryption.rounds ?? KdbxAesKdfConfig.defaultRounds,
      ),
      VaultKdf.argon2id || VaultKdf.argon2d => KdbxArgon2KdfConfig(
        type: encryption.kdf == VaultKdf.argon2id
            ? KdfType.Argon2id
            : KdfType.Argon2,
        iterations:
            encryption.iterations ?? KdbxArgon2KdfConfig.defaultIterations,
        memoryBytes:
            encryption.memoryBytes ?? KdbxArgon2KdfConfig.defaultMemoryBytes,
        parallelism:
            encryption.parallelism ?? KdbxArgon2KdfConfig.defaultParallelism,
      ),
    },
  );
}

/// Encryption of an existing vault from its (outer) header. Throws when the
/// header names an unknown cipher or KDF.
VaultEncryption vaultEncryptionOf(KdbxHeader header) {
  final kdf = header.kdfConfig;
  return VaultEncryption(
    cipher: switch (header.cipher) {
      Cipher.aes => VaultCipher.aes256,
      Cipher.chaCha20 => VaultCipher.chaCha20,
      Cipher.twofish => VaultCipher.twofish,
      null => throw const FormatException('Unknown KDBX cipher.'),
    },
    kdf: switch (kdf.type) {
      KdfType.Argon2id => VaultKdf.argon2id,
      KdfType.Argon2 => VaultKdf.argon2d,
      KdfType.Aes => VaultKdf.aesKdf,
    },
    kdbxVersion: '${header.version.major}.${header.version.minor}',
    iterations: kdf is KdbxArgon2KdfConfig ? kdf.iterations : null,
    memoryBytes: kdf is KdbxArgon2KdfConfig ? kdf.memoryBytes : null,
    parallelism: kdf is KdbxArgon2KdfConfig ? kdf.parallelism : null,
    rounds: kdf is KdbxAesKdfConfig ? kdf.rounds : null,
  );
}
