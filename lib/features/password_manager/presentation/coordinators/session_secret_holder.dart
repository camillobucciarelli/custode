/// spec-011 FR-1/FR-2: session-scoped, in-memory owner of the master
/// password for the currently unlocked vault.
///
/// Coordinators populate it on successful unlock and clear it on lock,
/// database switch, unlock failure and app termination. `VaultBloc` reads
/// the secret from here instead of from `SecureDataSource`; an absent
/// secret is an error ([SessionSecretMissingError]), never an empty string.
///
/// Constitution principle I: the secret must never appear in logs, `props`,
/// `toString` or error messages. This class is deliberately not `Equatable`
/// and its `toString` never includes the value. An empty string is a valid
/// secret (key-file-only vaults); only `null` means "locked".
class SessionSecretMissingError extends StateError {
  SessionSecretMissingError()
    : super('Session secret is not available; the vault is locked.');
}

class SessionSecretHolder {
  String? _secret;

  /// The key file that opened this session, set only when the unlock could
  /// not persist it to the security profile (spec 025 D10). While non-null it
  /// wins over the profile; `path` is null for an unlock without a key file.
  ({String? path})? keyFileOverride;

  bool get hasSecret => _secret != null;

  void set(String secret) {
    _secret = secret;
  }

  /// Returns the session secret, or throws [SessionSecretMissingError] when
  /// the session is locked. Never falls back to an empty string.
  String read() {
    final secret = _secret;
    if (secret == null) {
      throw SessionSecretMissingError();
    }
    return secret;
  }

  void clear() {
    _secret = null;
    keyFileOverride = null;
  }

  @override
  String toString() => 'SessionSecretHolder(hasSecret: $hasSecret)';
}
