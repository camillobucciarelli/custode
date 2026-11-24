import '../../domain/models/vault_encryption.dart';

/// The user-facing wording of a [VaultEncryption], shared by the create
/// wizard, the database card, Settings and its Encryption page.
extension VaultEncryptionFormat on VaultEncryption {
  /// `AES-256 · Argon2id`.
  String get summary => '${cipher.label} · ${kdf.label}';

  /// `64 MiB memory · 10 iterations · parallelism 4` for Argon2,
  /// `1,000,000 rounds` for AES-KDF. Unknown parts are left out; null when
  /// nothing is known.
  String? get kdfSettings {
    final parts = kdf == VaultKdf.aesKdf
        ? [if (rounds != null) '${_thousands(rounds!)} rounds']
        : [
            if (memoryBytes != null) '${_memory(memoryBytes!)} memory',
            if (iterations != null)
              '$iterations iteration${iterations == 1 ? '' : 's'}',
            if (parallelism != null) 'parallelism $parallelism',
          ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// `KDBX 4.1`; null when the version is unknown.
  String? get formatLabel => kdbxVersion == null ? null : 'KDBX $kdbxVersion';
}

String _memory(int bytes) {
  const mib = 1024 * 1024;
  return bytes % mib == 0 ? '${bytes ~/ mib} MiB' : '${bytes ~/ 1024} KiB';
}

String _thousands(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);
