import 'package:equatable/equatable.dart';
import 'package:path/path.dart' as p;
import 'package:password_manager/core/utils/redacted_value.dart';

import '../../../domain/errors/database_access_failure.dart';
import '../../../domain/models/storage_account_summary.dart';
import '../../../domain/models/vault_encryption.dart';

/// C-4 unlock phase. `isLoading` is gone — derive it from [phase] via the
/// getters below.
enum UnlockPhase {
  /// Bootstrapping (biometric availability + stored key-file/profile
  /// lookup) before the credential form is usable.
  initializing,

  /// Full-screen biometric gate must be passed before manual credentials
  /// can be submitted.
  biometricGate,

  /// Credential form is interactive and awaiting submission.
  ready,

  /// KDBX read is in flight. Entered *before* the await starts. Submit,
  /// credential edits and back are all disabled in this phase; the read is
  /// not cancellable and the UI must not claim it is.
  decrypting,

  /// Vault opened successfully.
  unlocked,

  /// A database-level typed failure (missing/invalid/corrupt file) makes
  /// the credential form unusable until the user goes back. Wrong
  /// password / missing key file stay in [ready] with an inline field
  /// error instead — see `DatabaseUnlockBloc._phaseForFailure`.
  failure,
}

class DatabaseUnlockState extends Equatable {
  final String databasePath;

  /// spec 014 FR-3: the registry name. The file on disk is an opaque
  /// identifier on mobile, so never render the basename when this is set.
  final String? displayName;

  /// Registry id, needed by the missing-file actions. Null when the path is
  /// not registered.
  final String? databaseId;

  /// The database has a sync mapping (any provider), whatever its source type.
  final bool isRemoteLinked;

  /// Connected account label source, best-effort (spec 025 FR-U2). Null when
  /// not connected or unknown.
  final StorageAccountSummary? remoteAccount;
  final String? keyFilePath;
  final UnlockPhase phase;
  final bool biometricAvailable;
  final bool biometricPrompted;
  final bool biometricVerified;

  /// Session-only escape hatch from the biometric gate: the user chose to
  /// unlock with the master password instead. Never persisted — the
  /// security profile's `biometricProtectionEnabled` is untouched, so the
  /// next launch gates on biometrics again.
  final bool manualFallbackRequested;

  /// C-3 typed failure, when the last error was mappable. Null for
  /// non-typed/business errors (still described in [errorMessage]).
  final DatabaseAccessFailure? failure;
  final String? errorMessage;

  /// C-4: null means indeterminate (always true in spec-003 — the `kdbx`
  /// API exposes no Argon2 progress callback). A non-null value is only
  /// legal in `[0, 1]` and only once a real backend callback exists.
  final double? progress;

  /// Something that did not stop the user: the unlock succeeded but a
  /// credential or setting could not be saved, or a picked key file could not
  /// be remembered. Never an error; the UI tells the user once.
  final String? notice;

  /// Biometric protection is on in this database's security profile. With
  /// [biometricAvailable] it is what offers `Use biometrics` (spec 025 FR-U1).
  final bool biometricEnabled;

  /// The missing database was removed from the list; the screen leaves.
  final bool databaseRemoved;

  /// Key derivation named by the decrypting view. Null when unknown.
  final VaultKdf? kdf;

  const DatabaseUnlockState({
    required this.databasePath,
    this.displayName,
    this.databaseId,
    this.isRemoteLinked = false,
    this.remoteAccount,
    this.keyFilePath,
    this.phase = UnlockPhase.initializing,
    this.biometricAvailable = false,
    this.biometricPrompted = false,
    this.biometricVerified = false,
    this.manualFallbackRequested = false,
    this.failure,
    this.errorMessage,
    this.progress,
    this.notice,
    this.biometricEnabled = false,
    this.databaseRemoved = false,
    this.kdf,
  });

  factory DatabaseUnlockState.initial({required String databasePath}) {
    return DatabaseUnlockState(databasePath: databasePath);
  }

  /// What the UI shows for this database. Falls back to the basename, which
  /// is the real name wherever storage is not opaque (desktop).
  String get databaseLabel => displayName ?? p.basename(databasePath);

  bool get isLoading =>
      phase == UnlockPhase.initializing || phase == UnlockPhase.decrypting;
  bool get isDecrypting => phase == UnlockPhase.decrypting;
  bool get requiresBiometricGate => phase == UnlockPhase.biometricGate;
  bool get unlocked => phase == UnlockPhase.unlocked;

  DatabaseUnlockState copyWith({
    String? databasePath,
    String? displayName,
    String? databaseId,
    bool? isRemoteLinked,
    StorageAccountSummary? remoteAccount,
    String? keyFilePath,
    UnlockPhase? phase,
    bool? biometricAvailable,
    bool? biometricPrompted,
    bool? biometricVerified,
    bool? manualFallbackRequested,
    DatabaseAccessFailure? failure,
    String? errorMessage,
    double? progress,
    String? notice,
    bool? biometricEnabled,
    bool? databaseRemoved,
    VaultKdf? kdf,
    bool clearError = false,
    bool clearKeyFilePath = false,
    bool clearProgress = false,
    bool clearRemoteAccount = false,
    bool clearNotice = false,
  }) {
    return DatabaseUnlockState(
      databasePath: databasePath ?? this.databasePath,
      displayName: displayName ?? this.displayName,
      databaseId: databaseId ?? this.databaseId,
      isRemoteLinked: isRemoteLinked ?? this.isRemoteLinked,
      remoteAccount:
          remoteAccount ?? (clearRemoteAccount ? null : this.remoteAccount),
      keyFilePath: keyFilePath ?? (clearKeyFilePath ? null : this.keyFilePath),
      phase: phase ?? this.phase,
      biometricAvailable: biometricAvailable ?? this.biometricAvailable,
      biometricPrompted: biometricPrompted ?? this.biometricPrompted,
      biometricVerified: biometricVerified ?? this.biometricVerified,
      manualFallbackRequested:
          manualFallbackRequested ?? this.manualFallbackRequested,
      failure: failure ?? (clearError ? null : this.failure),
      errorMessage: errorMessage ?? (clearError ? null : this.errorMessage),
      progress: clearProgress ? null : progress ?? this.progress,
      notice: notice ?? (clearNotice ? null : this.notice),
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
      databaseRemoved: databaseRemoved ?? this.databaseRemoved,
      kdf: kdf ?? this.kdf,
    );
  }

  @override
  List<Object?> get props => [
    databasePath,
    displayName,
    databaseId,
    isRemoteLinked,
    remoteAccount,
    RedactedValue<String?>(keyFilePath, redaction: '<redacted keyFilePath>'),
    phase,
    biometricAvailable,
    biometricPrompted,
    biometricVerified,
    manualFallbackRequested,
    failure,
    errorMessage,
    progress,
    notice,
    biometricEnabled,
    databaseRemoved,
    kdf,
  ];
}
