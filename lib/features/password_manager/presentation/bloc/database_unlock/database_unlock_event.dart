import 'package:equatable/equatable.dart';
import 'package:password_manager/core/utils/redacted_value.dart';

abstract class DatabaseUnlockEvent extends Equatable {
  const DatabaseUnlockEvent();

  @override
  List<Object?> get props => [];
}

class InitializeDatabaseUnlock extends DatabaseUnlockEvent {
  const InitializeDatabaseUnlock();
}

class RetryBiometricAuthentication extends DatabaseUnlockEvent {
  const RetryBiometricAuthentication();
}

/// User opts out of the biometric gate for this session and unlocks with
/// the master password instead. The master password is the primary
/// credential (it derives the KDBX key), so this is not a security bypass.
/// Does NOT alter the persisted `biometricProtectionEnabled` profile flag:
/// the next launch gates on biometrics again.
class RequestManualUnlockFallback extends DatabaseUnlockEvent {
  const RequestManualUnlockFallback();
}

class UnlockWithManualCredentials extends DatabaseUnlockEvent {
  final String password;
  final String? keyFilePath;

  const UnlockWithManualCredentials({required this.password, this.keyFilePath});

  @override
  List<Object?> get props => [
    RedactedValue<String>(password),
    RedactedValue<String?>(keyFilePath, redaction: '<redacted keyFilePath>'),
  ];
}

class UpdateKeyFilePath extends DatabaseUnlockEvent {
  final String? keyFilePath;

  const UpdateKeyFilePath(this.keyFilePath);

  @override
  List<Object?> get props => [
    RedactedValue<String?>(keyFilePath, redaction: '<redacted keyFilePath>'),
  ];
}

/// Missing-file recovery (spec 025 FR-U4): the user picked the file again.
class LocateMissingDatabaseFile extends DatabaseUnlockEvent {
  const LocateMissingDatabaseFile(this.selectedPath);

  final String selectedPath;

  @override
  List<Object?> get props => [
    RedactedValue<String>(selectedPath, redaction: '<redacted path>'),
  ];
}

/// Fetch the mapped remote file again for a database whose local file is gone.
class RedownloadMissingDatabase extends DatabaseUnlockEvent {
  const RedownloadMissingDatabase();
}

/// Drop the database from the list (the file is already gone).
class RemoveMissingDatabase extends DatabaseUnlockEvent {
  const RemoveMissingDatabase();
}
