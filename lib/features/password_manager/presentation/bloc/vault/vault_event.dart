import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:password_manager/core/utils/redacted_value.dart';

import '../../../domain/models/vault_custom_field.dart';
import '../../../domain/models/sync_conflict.dart';
import '../../../domain/models/sync_merge_models.dart';
import '../../../domain/services/sync_merge_policy.dart' show MergeShortcut;
import '../../../domain/models/remote_file.dart';
import 'vault_state.dart';

abstract class VaultEvent extends Equatable {
  const VaultEvent();

  @override
  List<Object?> get props => [];
}

class InitializeVault extends VaultEvent {
  const InitializeVault();
}

class OpenGroup extends VaultEvent {
  const OpenGroup(this.groupId);

  final String groupId;

  @override
  List<Object?> get props => [groupId];
}

class OpenParentGroup extends VaultEvent {
  const OpenParentGroup();
}

/// spec-019 T009 / FR-002 — pick the folder the records list filters by.
///
/// Distinct from [OpenGroup], which is mobile's drill-down: that one also
/// rewrites the expansion set so the opened folder's ancestors unfold. Model
/// 1a's folder column selects without navigating, and selecting must never
/// move a chevron (FR-006f).
///
/// [groupId] is never null: `All items` is the root group's id. A null current
/// group makes `CreateVaultEntry` return early without a message, so an
/// `All items` represented by null would leave the add button silently dead in
/// the default state (FR-002a).
class SelectVaultFolder extends VaultEvent {
  const SelectVaultFolder(this.groupId);

  final String groupId;

  @override
  List<Object?> get props => [groupId];
}

// spec-019 T047: `ToggleVaultGroupExpanded` was removed once every caller had
// moved to `SetVaultFolderExpanded`. A toggle and a setter for one piece of
// state are two ways to do one thing, and the three hosts of the folder tree
// are exactly the situation where they drift apart (`data-model.md`).

/// spec-019 T012 / FR-006g — fold or unfold one folder, explicitly.
///
/// The explicit form exists because model 1a has three hosts for the same tree
/// (the desktop column, the phone sheet, and `Manage folders`, which is always
/// fully expanded). A toggle makes each host's chevron mean "whatever the
/// others last did"; a set makes it mean what it says.
class SetVaultFolderExpanded extends VaultEvent {
  const SetVaultFolderExpanded(this.groupId, {required this.expanded});

  final String groupId;
  final bool expanded;

  @override
  List<Object?> get props => [groupId, expanded];
}

class RefreshVault extends VaultEvent {
  const RefreshVault();
}

class UpdateVaultSearchQuery extends VaultEvent {
  const UpdateVaultSearchQuery(this.query);

  final String query;

  @override
  List<Object?> get props => [query];
}

class ClearVaultSearchQuery extends VaultEvent {
  const ClearVaultSearchQuery();
}

class SetVaultSort extends VaultEvent {
  const SetVaultSort(this.sortBy);

  final VaultEntrySort sortBy;

  @override
  List<Object?> get props => [sortBy];
}

class LoadRecycleBinEntries extends VaultEvent {
  const LoadRecycleBinEntries();
}

class CreateVaultEntry extends VaultEvent {
  const CreateVaultEntry({
    required this.title,
    required this.username,
    required this.password,
    required this.url,
    required this.notes,
    this.customFields = const [],
    this.attachmentPaths = const [],
  });

  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;
  final List<VaultCustomField> customFields;
  final List<String> attachmentPaths;

  @override
  List<Object?> get props => [
    title,
    username,
    RedactedValue(password),
    url,
    RedactedValue(notes, redaction: '<redacted notes>'),
    customFields,
    attachmentPaths,
  ];

  @override
  String toString() {
    return 'CreateVaultEntry('
        'title: $title, '
        'username: $username, '
        'password: <redacted>, '
        'url: $url, '
        'notes: <redacted>, '
        'customFields: ${customFields.length}, '
        'attachmentPaths: ${attachmentPaths.length})';
  }
}

class UpdateVaultEntry extends VaultEvent {
  const UpdateVaultEntry({
    required this.entryId,
    required this.title,
    required this.username,
    required this.password,
    required this.url,
    required this.notes,
    this.customFields = const [],
    this.attachmentPaths = const [],
    this.removedAttachmentKeys = const [],
  });

  final String entryId;
  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;
  final List<VaultCustomField> customFields;

  /// Files to attach as part of this save.
  final List<String> attachmentPaths;

  /// Keys of the record's existing attachments to remove as part of this
  /// save.
  final List<String> removedAttachmentKeys;

  @override
  List<Object?> get props => [
    entryId,
    title,
    username,
    RedactedValue(password),
    url,
    RedactedValue(notes, redaction: '<redacted notes>'),
    customFields,
    attachmentPaths,
    removedAttachmentKeys,
  ];

  @override
  String toString() {
    return 'UpdateVaultEntry('
        'entryId: $entryId, '
        'title: $title, '
        'username: $username, '
        'password: <redacted>, '
        'url: $url, '
        'notes: <redacted>, '
        'customFields: ${customFields.length}, '
        'attachmentPaths: ${attachmentPaths.length}, '
        'removedAttachmentKeys: ${removedAttachmentKeys.length})';
  }
}

class DeleteVaultEntry extends VaultEvent {
  const DeleteVaultEntry(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}

/// spec-019 C-04-05 — copy a record beside itself, in its own folder.
///
/// Carries only the id: the copy is made inside the service, where the source
/// record is open, so the plaintext of a password never travels through an
/// event to make a duplicate of it (Constitution I).
class DuplicateVaultEntry extends VaultEvent {
  const DuplicateVaultEntry(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}

class MoveVaultEntry extends VaultEvent {
  const MoveVaultEntry({required this.entryId, required this.targetGroupId});

  final String entryId;
  final String targetGroupId;

  @override
  List<Object?> get props => [entryId, targetGroupId];
}

class CreateVaultGroup extends VaultEvent {
  const CreateVaultGroup(this.name, {this.parentGroupId});

  final String name;

  /// Where to create the folder. Null falls back to the selected folder —
  /// the pre-2026-08-30 behaviour, still what the column header path wants.
  /// The Manage tree's per-row `New folder` passes the row explicitly.
  final String? parentGroupId;

  @override
  List<Object?> get props => [name, parentGroupId];
}

class RenameVaultGroup extends VaultEvent {
  const RenameVaultGroup({required this.groupId, required this.newName});

  final String groupId;
  final String newName;

  @override
  List<Object?> get props => [groupId, newName];
}

class DeleteVaultGroup extends VaultEvent {
  const DeleteVaultGroup(this.groupId);

  final String groupId;

  @override
  List<Object?> get props => [groupId];
}

class MoveVaultGroup extends VaultEvent {
  const MoveVaultGroup({required this.groupId, required this.targetGroupId});

  final String groupId;
  final String targetGroupId;

  @override
  List<Object?> get props => [groupId, targetGroupId];
}

class OpenRecycleBin extends VaultEvent {
  const OpenRecycleBin();
}

class CloseRecycleBin extends VaultEvent {
  const CloseRecycleBin();
}

class RestoreVaultEntry extends VaultEvent {
  const RestoreVaultEntry(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}

class RestoreVaultGroup extends VaultEvent {
  const RestoreVaultGroup(this.groupId);

  final String groupId;

  @override
  List<Object?> get props => [groupId];
}

class DeleteVaultEntryPermanently extends VaultEvent {
  const DeleteVaultEntryPermanently(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}

class DeleteVaultGroupPermanently extends VaultEvent {
  const DeleteVaultGroupPermanently(this.groupId);

  final String groupId;

  @override
  List<Object?> get props => [groupId];
}

class EmptyRecycleBin extends VaultEvent {
  const EmptyRecycleBin();
}

class ExportVaultAttachment extends VaultEvent {
  const ExportVaultAttachment({
    required this.entryId,
    required this.attachmentKey,
    required this.destinationDirectory,
  });

  final String entryId;
  final String attachmentKey;
  final String destinationDirectory;

  @override
  List<Object?> get props => [entryId, attachmentKey, destinationDirectory];
}

class ImportVaultEntriesFromCsv extends VaultEvent {
  const ImportVaultEntriesFromCsv({
    required this.filePath,
    this.avoidDuplicates = true,
  });

  final String filePath;
  final bool avoidDuplicates;

  @override
  List<Object?> get props => [filePath, avoidDuplicates];
}

/// spec-018 FR-006/G5.4: a confirmed record action that cannot be applied
/// because the record disappeared while the dialog was open. The user
/// confirmed something, so they are told something — an action must never
/// end with neither a change nor a message.
class ReportVaultActionAbandoned extends VaultEvent {
  const ReportVaultActionAbandoned();
}

class ClearVaultError extends VaultEvent {
  const ClearVaultError();
}

class ClearVaultInfo extends VaultEvent {
  const ClearVaultInfo();
}

class ConnectGoogleDrive extends VaultEvent {
  const ConnectGoogleDrive();
}

class GoogleDriveReconnectSucceeded extends VaultEvent {
  const GoogleDriveReconnectSucceeded({this.remoteFiles});

  final List<RemoteFile>? remoteFiles;

  @override
  List<Object?> get props => [remoteFiles];
}

class GoogleDriveReconnectFailed extends VaultEvent {
  const GoogleDriveReconnectFailed({
    required this.error,
    required this.stackTrace,
    required this.remoteFiles,
    this.duringRemoteLoad = false,
  });

  final Object error;
  final StackTrace stackTrace;
  final bool remoteFiles;
  final bool duringRemoteLoad;

  // Do not expose provider exception text through Equatable/toString.
  @override
  List<Object?> get props => [remoteFiles, duringRemoteLoad];
}

class DisconnectGoogleDrive extends VaultEvent {
  const DisconnectGoogleDrive();
}

class LinkCurrentDatabaseToDrive extends VaultEvent {
  const LinkCurrentDatabaseToDrive({this.remoteFileId, this.remoteFileName});

  final String? remoteFileId;
  final String? remoteFileName;

  @override
  List<Object?> get props => [remoteFileId, remoteFileName];
}

class SyncCurrentDatabaseNow extends VaultEvent {
  const SyncCurrentDatabaseNow({
    this.resolution,
    this.silentIfConflict = false,
  });

  final SyncConflictResolution? resolution;
  final bool silentIfConflict;

  @override
  List<Object?> get props => [resolution, silentIfConflict];
}

class ToggleCurrentDatabaseAutoSync extends VaultEvent {
  const ToggleCurrentDatabaseAutoSync(this.enabled);

  final bool enabled;

  @override
  List<Object?> get props => [enabled];
}

class ClearVaultSyncFeedback extends VaultEvent {
  const ClearVaultSyncFeedback();
}

class LoadRemoteFiles extends VaultEvent {
  const LoadRemoteFiles({this.query});

  final String? query;

  @override
  List<Object?> get props => [query];
}

class BackgroundDriveSync extends VaultEvent {
  const BackgroundDriveSync();
}

class LoadDuplicates extends VaultEvent {
  const LoadDuplicates();
}

class DeleteDuplicateEntry extends VaultEvent {
  const DeleteDuplicateEntry(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}

class MergeDuplicateEntries extends VaultEvent {
  const MergeDuplicateEntries({
    required this.primaryId,
    required this.secondaryIds,
  });

  final String primaryId;

  /// Every duplicate to fold into the kept entry, merged in order.
  final List<String> secondaryIds;

  @override
  List<Object?> get props => [primaryId, secondaryIds];
}

class RefreshAppleAutofillPendingAssociations extends VaultEvent {
  const RefreshAppleAutofillPendingAssociations();
}

class ConfirmAppleAutofillPendingAssociation extends VaultEvent {
  const ConfirmAppleAutofillPendingAssociation(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

class RejectAppleAutofillPendingAssociation extends VaultEvent {
  const RejectAppleAutofillPendingAssociation(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

class ClearCsvImportOutcome extends VaultEvent {
  const ClearCsvImportOutcome();
}

/// spec-005 T5 ("success" hero, Unlink pill): removes the current
/// database's `DatabaseSyncMapping` without disconnecting the Google
/// account. Distinct from `DisconnectGoogleDrive`, which also revokes the
/// account connection.
class UnlinkCurrentDatabaseFromDrive extends VaultEvent {
  const UnlinkCurrentDatabaseFromDrive();
}

/// spec-016 US3: a credential submitted to another app is waiting to be
/// saved. Emitted when the app is opened by an Android save request.
class CheckAndroidAutofillCapture extends VaultEvent {
  const CheckAndroidAutofillCapture();
}

class ConfirmAndroidAutofillCapture extends VaultEvent {
  const ConfirmAndroidAutofillCapture();
}

class DeclineAndroidAutofillCapture extends VaultEvent {
  const DeclineAndroidAutofillCapture();
}

class CancelAndroidAutofillCapture extends VaultEvent {
  const CancelAndroidAutofillCapture();
}

// ---------------------------------------------------------------------------
// spec-008 T504 — per-field merge commands. Opaque ids and redacted choices
// only; the BLoC forwards each to `SyncMergeCoordinator` (T505).
// ---------------------------------------------------------------------------

class StartSyncMergeReview extends VaultEvent {
  const StartSyncMergeReview();
}

class UpdateSyncMergeDecision extends VaultEvent {
  const UpdateSyncMergeDecision({
    required this.decisionId,
    required this.choice,
  });

  final MergeDecisionId decisionId;
  final MergeChoice choice;

  @override
  List<Object?> get props => [decisionId, choice];
}

class ApplySyncMergeShortcut extends VaultEvent {
  const ApplySyncMergeShortcut(this.shortcut);

  final MergeShortcut shortcut;

  @override
  List<Object?> get props => [shortcut];
}

class CommitSyncMerge extends VaultEvent {
  const CommitSyncMerge();
}

class CancelSyncMerge extends VaultEvent {
  const CancelSyncMerge();
}

class ClearSyncMergeOutcome extends VaultEvent {
  const ClearSyncMergeOutcome();
}

/// spec 017 T201 / FR-015 — read one entry's previous versions.
///
/// On demand only: history is never part of the vault load, so an entry with
/// hundreds of revisions costs nothing until the user asks to see them (D6).
class LoadEntryHistory extends VaultEvent {
  const LoadEntryHistory(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}

/// spec 017 T201 / D6 — the history view closed; drop the revisions.
///
/// Historical secrets do not outlive the surface that showed them.
class ClearEntryHistory extends VaultEvent {
  const ClearEntryHistory();
}

/// spec 017 T304 / FR-006 — put a confirmed revision back on the entry.
///
/// The confirmation happened in the view; this is the act.
class RestoreEntryRevision extends VaultEvent {
  const RestoreEntryRevision({
    required this.entryId,
    required this.replacedAt,
    this.ordinal = 0,
  });

  final String entryId;
  final DateTime replacedAt;

  /// Tells same-second revisions apart; see [VaultEntryRevision.ordinal].
  final int ordinal;

  @override
  List<Object?> get props => [entryId, replacedAt, ordinal];
}

/// spec 017 T403 / FR-009 — remove one confirmed revision from the file.
class DeleteEntryRevision extends VaultEvent {
  const DeleteEntryRevision({
    required this.entryId,
    required this.replacedAt,
    this.ordinal = 0,
  });

  final String entryId;
  final DateTime replacedAt;
  final int ordinal;

  @override
  List<Object?> get props => [entryId, replacedAt, ordinal];
}

/// spec 017 T403 / FR-010 — empty an entry's history in the file, after the
/// warning. Distinct from [ClearEntryHistory], which only drops the
/// revisions from state when the view closes.
class ClearEntryHistoryInFile extends VaultEvent {
  const ClearEntryHistoryInFile(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}

/// spec 023 T205 / FR-010 — remove one confirmed passkey from an entry.
///
/// Carries the credential, not the field suffix: the suffix is the group's
/// position in the `KPEX_PASSKEY_*` namespace, and a sync between the read
/// that drew the section and this write can renumber it.
class DeletePasskey extends VaultEvent {
  const DeletePasskey({
    required this.entryId,
    required this.relyingPartyId,
    required this.credentialId,
  });

  final String entryId;
  final String relyingPartyId;
  final Uint8List credentialId;

  @override
  List<Object?> get props => [entryId, relyingPartyId, credentialId];
}
