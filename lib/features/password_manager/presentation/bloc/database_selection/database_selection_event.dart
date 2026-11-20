import 'package:equatable/equatable.dart';
import 'package:password_manager/core/utils/redacted_value.dart';

import '../../../domain/models/database_dedup_result.dart';
import '../../../domain/models/recent_database_removal_mode.dart';

export '../../../domain/models/recent_database_removal_mode.dart';

abstract class DatabaseSelectionEvent extends Equatable {
  const DatabaseSelectionEvent();

  @override
  List<Object> get props => [];
}

class CheckInitialDatabase extends DatabaseSelectionEvent {}

class SelectExistingDatabase extends DatabaseSelectionEvent {
  const SelectExistingDatabase({
    required this.fileName,
    this.selectedPath,
    this.selectedBytes,
  });

  final String fileName;
  final String? selectedPath;
  final List<int>? selectedBytes;

  @override
  List<Object> get props => [
    fileName,
    selectedPath ?? '',
    selectedBytes?.length ?? -1,
  ];
}

class OpenRecentDatabase extends DatabaseSelectionEvent {
  const OpenRecentDatabase(this.path);

  final String path;

  @override
  List<Object> get props => [path];
}

class CreateNewDatabase extends DatabaseSelectionEvent {
  final String databaseFileName;
  final String password;
  final String? keyFilePath;
  final bool biometricProtectionEnabled;
  final bool generateKeyFile;
  final String? generatedKeyFilePath;

  /// Spec 025 FR-C5: also create the file on Google Drive. Non-secret.
  final bool createOnRemote;

  const CreateNewDatabase({
    required this.databaseFileName,
    required this.password,
    this.keyFilePath,
    this.biometricProtectionEnabled = false,
    this.generateKeyFile = false,
    this.generatedKeyFilePath,
    this.createOnRemote = false,
  });

  @override
  List<Object> get props => [
    databaseFileName,
    RedactedValue<String>(password),
    RedactedValue<String>(
      keyFilePath ?? '',
      redaction: '<redacted keyFilePath>',
    ),
    biometricProtectionEnabled,
    generateKeyFile,
    RedactedValue<String>(
      generatedKeyFilePath ?? '',
      redaction: '<redacted generatedKeyFilePath>',
    ),
    createOnRemote,
  ];
}

class SelectDriveDatabase extends DatabaseSelectionEvent {
  const SelectDriveDatabase({
    required this.remoteProviderId,
    required this.remoteFileId,
    required this.remoteFileName,
  });

  /// Remote identity is the `(providerId, remoteFileId)` tuple (spec 010).
  final String remoteProviderId;
  final String remoteFileId;
  final String remoteFileName;

  @override
  List<Object> get props => [
    remoteProviderId,
    RedactedValue<String>(remoteFileId, redaction: '<redacted remoteFileId>'),
    remoteFileName,
  ];
}

class RemoveRecentDatabase extends DatabaseSelectionEvent {
  const RemoveRecentDatabase({required this.path, required this.mode});

  final String path;
  final RecentDatabaseRemovalMode mode;

  @override
  List<Object> get props => [path, mode];
}

class ResolveDuplicateDecision extends DatabaseSelectionEvent {
  const ResolveDuplicateDecision(this.decision);

  final DatabaseDuplicateResolution decision;

  @override
  List<Object> get props => [decision];
}

/// FR-1 Locate: only valid for an `isMissing` recent item.
class LocateMissingDatabase extends DatabaseSelectionEvent {
  const LocateMissingDatabase({
    required this.databaseId,
    required this.selectedPath,
  });

  final String databaseId;
  final String selectedPath;

  @override
  List<Object> get props => [databaseId, selectedPath];
}

/// C-5 create-flow wizard events. None of these carry plaintext password —
/// only non-secret validation facts (non-empty, confirmation match).
/// [CreateNewDatabase] above remains the sole event carrying the password,
/// transiently, via [RedactedValue].
class StartCreateDatabaseFlow extends DatabaseSelectionEvent {
  const StartCreateDatabaseFlow();
}

class AdvanceCreateDatabaseStep extends DatabaseSelectionEvent {
  const AdvanceCreateDatabaseStep({
    required this.fieldsNonEmpty,
    this.confirmationMatches = true,
  });

  final bool fieldsNonEmpty;
  final bool confirmationMatches;

  @override
  List<Object> get props => [fieldsNonEmpty, confirmationMatches];
}

class GoBackCreateDatabaseStep extends DatabaseSelectionEvent {
  const GoBackCreateDatabaseStep();
}

class CancelCreateDatabaseFlow extends DatabaseSelectionEvent {
  const CancelCreateDatabaseFlow();
}

/// spec 014 FR-5 recovery: the user accepted discarding metadata that no key
/// can open, so writes can resume and the vaults can be re-selected.
class DiscardUnreadableMetadata extends DatabaseSelectionEvent {
  const DiscardUnreadableMetadata();
}
