import 'package:equatable/equatable.dart';

import '../../../domain/errors/database_access_failure.dart';
import '../../../domain/models/create_database_step.dart';
import '../../../domain/models/database_selection_item.dart';
import '../../../domain/models/storage_account_summary.dart';
import '../../coordinators/database_session_coordinator.dart';

abstract class DatabaseSelectionState extends Equatable {
  const DatabaseSelectionState({this.items = const [], this.remoteAccount});

  /// C-1 selection metadata. Replaces the former
  /// `List<String> recentDatabasePaths`.
  final List<DatabaseSelectionItem> items;

  /// Spec 025 FR-L2: the connected account heading the remote group, loaded
  /// best-effort with the list. Null means the bare provider label.
  final StorageAccountSummary? remoteAccount;

  @override
  List<Object?> get props => [items, remoteAccount];
}

class DatabaseSelectionInitial extends DatabaseSelectionState {
  const DatabaseSelectionInitial({super.items, super.remoteAccount});
}

class DatabaseSelectionLoading extends DatabaseSelectionState {
  const DatabaseSelectionLoading({
    this.label,
    super.items,
    super.remoteAccount,
  });

  /// What is happening, shown next to the spinner (`Opening <name>…`).
  final String? label;

  @override
  List<Object?> get props => [label, items, remoteAccount];
}

class DatabaseSelectionUnselected extends DatabaseSelectionState {
  const DatabaseSelectionUnselected({super.items, super.remoteAccount});
}

class DatabaseSelectionSuccess extends DatabaseSelectionState {
  final String path;
  final String? userMessage;

  /// Spec 025 FR-C6: the session can open the vault directly; otherwise the
  /// screen goes through Unlock.
  final bool openVault;

  const DatabaseSelectionSuccess(
    this.path, {
    this.userMessage,
    this.openVault = false,
    super.items,
    super.remoteAccount,
  });

  @override
  List<Object?> get props => [
    path,
    userMessage,
    openVault,
    items,
    remoteAccount,
  ];
}

/// C-3 typed failure surfaced by the coordinator (missing database, invalid
/// selection, corrupt KDBX, missing key file, invalid credentials). `null`
/// [failure] with a non-empty [message] means a generic/unexpected error —
/// the message is still never a raw `e.toString()` or a full path.
class DatabaseSelectionError extends DatabaseSelectionState {
  final String message;
  final DatabaseAccessFailure? failure;

  const DatabaseSelectionError(
    this.message, {
    this.failure,
    super.items,
    super.remoteAccount,
  });

  @override
  List<Object?> get props => [message, failure, items, remoteAccount];
}

class DatabaseSelectionInfo extends DatabaseSelectionState {
  final String message;

  const DatabaseSelectionInfo(this.message, {super.items, super.remoteAccount});

  @override
  List<Object?> get props => [message, items, remoteAccount];
}

class DatabaseSelectionDuplicateDecisionRequired
    extends DatabaseSelectionState {
  const DatabaseSelectionDuplicateDecisionRequired({
    required this.duplicatePrompt,
    required this.message,
    super.items,
    super.remoteAccount,
  });

  final DatabaseDuplicatePrompt duplicatePrompt;
  final String message;

  @override
  List<Object?> get props => [duplicatePrompt, message, items, remoteAccount];
}

/// C-5: non-secret create-database wizard position. The password itself
/// never appears here — see `CreateNewDatabase` event / `RedactedValue`.
class DatabaseSelectionCreateStep extends DatabaseSelectionState {
  const DatabaseSelectionCreateStep(
    this.step, {
    this.submitting = false,
    this.errorMessage,
    super.items,
    super.remoteAccount,
  });

  final CreateDatabaseStep step;

  /// spec 015 FR-10: true while creation runs — the wizard stays mounted
  /// with its controls and Back/Cancel disabled. The BLoC holds neither the
  /// draft nor any secret; the screen owns those.
  final bool submitting;

  /// spec 015 FR-10: an I/O failure rendered in the wizard, with the draft
  /// intact. Field-level errors stay at their field in the screen.
  final String? errorMessage;

  @override
  List<Object?> get props => [
    step,
    submitting,
    errorMessage,
    items,
    remoteAccount,
  ];
}
