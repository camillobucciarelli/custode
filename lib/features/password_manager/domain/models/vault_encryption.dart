import 'package:equatable/equatable.dart';

/// Payload cipher of a KDBX vault.
enum VaultCipher {
  aes256('AES-256'),
  chaCha20('ChaCha20'),
  twofish('Twofish');

  const VaultCipher(this.label);

  /// User-facing name.
  final String label;
}

/// Key derivation function of a KDBX vault.
enum VaultKdf {
  argon2id('Argon2id'),
  argon2d('Argon2d'),
  aesKdf('AES-KDF');

  const VaultKdf(this.label);

  /// User-facing name.
  final String label;
}

/// Encryption settings of a vault, read from its outer KDBX header (not
/// secret: KeePass shows it before unlock) or requested for a new vault.
///
/// The cost fields are null when unknown or, in a create request, when the
/// KDF's default cost applies (KeePassXC's: Argon2 10 iterations, 64 MiB,
/// parallelism 4; AES-KDF 1,000,000 rounds). Argon2 uses [iterations],
/// [memoryBytes] and [parallelism]; AES-KDF uses [rounds].
class VaultEncryption extends Equatable {
  const VaultEncryption({
    required this.cipher,
    required this.kdf,
    this.kdbxVersion,
    this.iterations,
    this.memoryBytes,
    this.parallelism,
    this.rounds,
  });

  /// KeePassXC's default for new databases.
  static const defaults = VaultEncryption(
    cipher: VaultCipher.aes256,
    kdf: VaultKdf.argon2id,
  );

  final VaultCipher cipher;
  final VaultKdf kdf;

  /// KDBX format version, `major.minor` (for example `4.0`). Null for a
  /// create request.
  final String? kdbxVersion;
  final int? iterations;
  final int? memoryBytes;
  final int? parallelism;
  final int? rounds;

  @override
  List<Object?> get props => [
    cipher,
    kdf,
    kdbxVersion,
    iterations,
    memoryBytes,
    parallelism,
    rounds,
  ];
}
