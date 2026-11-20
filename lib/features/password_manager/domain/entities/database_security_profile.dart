class DatabaseSecurityProfile {
  const DatabaseSecurityProfile({
    required this.databaseId,
    this.keyFilePath,
    // spec-011 FR-7: persisting the master password requires explicit
    // consent, so the implicit default is always `false`.
    this.biometricProtectionEnabled = false,
    this.biometricOfferAnswered = false,
    this.inactivityLockTimeoutSeconds,
    this.updatedAt,
  });

  final String databaseId;
  final String? keyFilePath;
  final bool biometricProtectionEnabled;

  /// Spec 025 FR-U6: the one-time biometric offer was shown and answered (or
  /// dismissed), so it is never offered again for this database.
  final bool biometricOfferAnswered;
  final int? inactivityLockTimeoutSeconds;
  final DateTime? updatedAt;

  DatabaseSecurityProfile copyWith({
    String? keyFilePath,
    bool? biometricProtectionEnabled,
    bool? biometricOfferAnswered,
    int? inactivityLockTimeoutSeconds,
    DateTime? updatedAt,
    bool clearKeyFilePath = false,
    bool clearInactivityTimeout = false,
  }) {
    return DatabaseSecurityProfile(
      databaseId: databaseId,
      keyFilePath: clearKeyFilePath ? null : keyFilePath ?? this.keyFilePath,
      biometricProtectionEnabled:
          biometricProtectionEnabled ?? this.biometricProtectionEnabled,
      biometricOfferAnswered:
          biometricOfferAnswered ?? this.biometricOfferAnswered,
      inactivityLockTimeoutSeconds: clearInactivityTimeout
          ? null
          : inactivityLockTimeoutSeconds ?? this.inactivityLockTimeoutSeconds,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
