import 'package:equatable/equatable.dart';
import 'package:path/path.dart' as p;

import '../../../domain/models/apple_autofill_v2_models.dart';
import '../../../domain/models/database_sync_status.dart';
import '../../../domain/models/remote_file.dart';
import '../../../domain/models/duplicate_group.dart';
import '../../../domain/models/sync_conflict.dart';
import '../../../domain/models/sync_merge_models.dart';
import '../../../domain/models/vault_entry.dart';
import '../../../domain/models/vault_entry_revision.dart';
import '../../../domain/models/vault_group.dart';
import '../../../domain/models/vault_health_report.dart';
import '../../coordinators/android_autofill_save_coordinator.dart';
import '../../coordinators/pending_passkey_adoption_coordinator.dart'
    show PasskeyClashRequest, PendingPasskeyOtherVault;
import '../../../data/services/vault_csv_import_service.dart'
    show CsvImportOutcome;

enum VaultEntrySort { titleAsc, titleDesc, usernameAsc }

class VaultState extends Equatable {
  const VaultState({
    required this.databasePath,
    this.displayName,
    this.rootGroupId,
    this.currentGroupId,
    this.groups = const [],
    this.entries = const [],
    this.allEntries = const [],
    this.visibleEntries = const [],
    this.expandedGroupIds = const [],
    this.folderCounts = const {},
    this.folderDescendantIds = const {},
    this.recycleBinEntries = const [],
    this.isLoading = false,
    this.isSaving = false,
    this.isRecycleBinView = false,
    this.isRecycleBinLoading = false,
    this.searchQuery = '',
    this.sortBy = VaultEntrySort.usernameAsc,
    this.errorMessage,
    this.infoMessage,
    this.isDriveConnected = false,
    this.isDriveLinked = false,
    this.autoSyncEnabled = true,
    this.syncStatus = DatabaseSyncStatus.disconnected,
    this.syncError,
    this.driveReconnectRequired = false,
    this.lastSyncAt,
    this.lastSyncedLocalChecksum,
    this.pendingSyncConflict,
    this.remoteFiles = const [],
    this.isLoadingRemoteFiles = false,
    this.remoteFilesError,
    this.remoteFilesReconnectRequired = false,
    this.linkedRemoteFileName,
    this.isSyncing = false,
    this.isSyncReloadPending = false,
    this.isOffline = false,
    this.duplicateGroups = const [],
    this.isDuplicatesLoading = false,
    this.pendingAppleAutofillAssociations = const [],
    this.pendingAndroidAutofillSave,
    this.passkeyClashes = const [],
    this.passkeyOtherVault = const [],
    this.healthReport = VaultHealthReport.empty,
    this.lastCsvImportOutcome,
    this.mergeReview,
    this.mergeCommitOutcome,
    this.mergeFailureCode,
    this.isMergeBusy = false,
    this.entryHistory,
    this.entryHistoryEntryId,
    this.isEntryHistoryLoading = false,
    this.entryHistoryError,
  });

  factory VaultState.initial({required String databasePath}) {
    return VaultState(databasePath: databasePath, isLoading: true);
  }

  final String databasePath;

  /// spec 014 FR-3: the registry name. The database file rests under an
  /// opaque identifier on mobile, so the basename is not a name to show —
  /// it is only the fallback for storage that is not opaque (desktop).
  final String? displayName;

  /// What the UI shows for the open database.
  String get databaseLabel => displayName ?? p.basename(databasePath);

  final String? rootGroupId;
  final String? currentGroupId;
  final List<VaultGroup> groups;
  final List<VaultEntry> entries;
  final List<VaultEntry> allEntries;
  final List<VaultEntry> visibleEntries;
  final List<String> expandedGroupIds;

  /// spec-019 T007/T008 — records per folder, **inclusive of descendants**.
  ///
  /// Recomputed once per reload from `groups` and `allEntries`, never per row:
  /// the folder column asks for a count on every rebuild of every row, and a
  /// walk per row is a walk of the whole vault per row.
  ///
  /// Recycle-bin groups are absent from the map, so `All items` and the folder
  /// counts add up to the same vault.
  final Map<String, int> folderCounts;

  /// spec-019 T007 — every descendant of a folder, from the same walk that
  /// produced [folderCounts]. Read by the folder filter so that selecting a
  /// folder shows its subtree (FR-006h).
  final Map<String, Set<String>> folderDescendantIds;

  final List<VaultEntry> recycleBinEntries;
  final bool isLoading;
  final bool isSaving;
  final bool isRecycleBinView;
  final bool isRecycleBinLoading;
  final String searchQuery;
  final VaultEntrySort sortBy;
  final String? errorMessage;
  final String? infoMessage;
  final bool isDriveConnected;
  final bool isDriveLinked;
  final bool autoSyncEnabled;
  final DatabaseSyncStatus syncStatus;
  final String? syncError;
  final bool driveReconnectRequired;
  final DateTime? lastSyncAt;

  /// The local file's checksum recorded at the last successful sync
  /// (`DatabaseSyncMapping.lastSyncedLocalChecksum`) — surfaced so the Sync
  /// destination can show it instead of a hard-coded null.
  final String? lastSyncedLocalChecksum;
  final SyncConflict? pendingSyncConflict;
  final List<RemoteFile> remoteFiles;
  final bool isLoadingRemoteFiles;
  final String? remoteFilesError;
  final bool remoteFilesReconnectRequired;
  final String? linkedRemoteFileName;
  final bool isSyncing;
  final bool isSyncReloadPending;

  /// spec-005 T7: true only for connection-level sync failures
  /// (`SocketException`) — never for an HTTP error status. See
  /// `VaultBloc._performSync`.
  final bool isOffline;
  final List<DuplicateGroup> duplicateGroups;
  final bool isDuplicatesLoading;
  final List<AppleAutofillV2PendingAssociation>
  pendingAppleAutofillAssociations;

  /// spec-016 US3: a credential submitted to another app, waiting for the
  /// user to confirm whether it becomes a new entry or updates one. The
  /// captured password lives inside it and is never rendered.
  final AndroidAutofillPendingSave? pendingAndroidAutofillSave;

  /// Passkeys-all-platforms T014: adoption questions still waiting on the
  /// user. Ids and labels only, never key material (SR-1).
  final List<PasskeyClashRequest> passkeyClashes;
  final List<PendingPasskeyOtherVault> passkeyOtherVault;

  /// spec-005 T3: computed on unlock and after every write (never per
  /// keystroke) — see `VaultBloc._computeHealth`.
  final VaultHealthReport healthReport;

  /// spec-005 T16: outcome of the most recent CSV import, shown once by the
  /// outcome screen then cleared via `ClearCsvImportOutcome`.
  final CsvImportOutcome? lastCsvImportOutcome;

  /// spec-008 T504: the redacted review in progress (opaque ids, choices,
  /// counts, phase). Null when no merge review is open.
  final MergeReviewSummary? mergeReview;

  /// The last commit outcome: counts and codes only.
  final MergeCommitOutcome? mergeCommitOutcome;

  /// The last merge failure, as a safe code.
  final MergeFailureCode? mergeFailureCode;

  final bool isMergeBusy;

  /// spec 017 FR-015/D6 — the revisions of exactly one entry, read on demand
  /// and dropped when the history view closes. Never part of the vault load:
  /// historical secrets do not live in long-lived list state (Constitution I).
  final VaultEntryHistory? entryHistory;

  /// Which entry [entryHistory] belongs to. Also set while the read is in
  /// flight, so a second request supersedes the first rather than racing it.
  final String? entryHistoryEntryId;

  final bool isEntryHistoryLoading;

  /// A safe message. The underlying failure never carries a secret and this
  /// never quotes one.
  final String? entryHistoryError;

  int get duplicateGroupCount => duplicateGroups.length;

  /// spec-019 FR-002a — the number `All items` carries.
  ///
  /// This is the root folder's own inclusive count, not a second tally: the
  /// row labelled `All items` IS the root group, so the two readings are the
  /// same number by construction rather than by coincidence.
  int get totalCount => folderCounts[rootGroupId] ?? 0;

  /// spec-019 FR-006h — [groupId] and everything beneath it.
  ///
  /// Returns just [groupId] for a leaf, and for an unknown id — the filter
  /// then matches only entries filed directly under it, which is the safe
  /// answer while a reload is in flight.
  Set<String> descendantIds(String groupId) => {
    groupId,
    ...?folderDescendantIds[groupId],
  };

  VaultState copyWith({
    String? displayName,
    String? rootGroupId,
    String? currentGroupId,
    List<VaultGroup>? groups,
    List<VaultEntry>? entries,
    List<VaultEntry>? allEntries,
    List<VaultEntry>? visibleEntries,
    List<String>? expandedGroupIds,
    Map<String, int>? folderCounts,
    Map<String, Set<String>>? folderDescendantIds,
    List<VaultEntry>? recycleBinEntries,
    bool? isLoading,
    bool? isSaving,
    bool? isRecycleBinView,
    bool? isRecycleBinLoading,
    String? searchQuery,
    VaultEntrySort? sortBy,
    String? errorMessage,
    String? infoMessage,
    bool? isDriveConnected,
    bool? isDriveLinked,
    bool? autoSyncEnabled,
    DatabaseSyncStatus? syncStatus,
    String? syncError,
    bool? driveReconnectRequired,
    DateTime? lastSyncAt,
    String? lastSyncedLocalChecksum,
    SyncConflict? pendingSyncConflict,
    List<RemoteFile>? remoteFiles,
    bool? isLoadingRemoteFiles,
    String? remoteFilesError,
    bool? remoteFilesReconnectRequired,
    String? linkedRemoteFileName,
    bool? isSyncing,
    bool? isSyncReloadPending,
    bool? isOffline,
    List<DuplicateGroup>? duplicateGroups,
    bool? isDuplicatesLoading,
    List<AppleAutofillV2PendingAssociation>? pendingAppleAutofillAssociations,
    AndroidAutofillPendingSave? pendingAndroidAutofillSave,
    List<PasskeyClashRequest>? passkeyClashes,
    List<PendingPasskeyOtherVault>? passkeyOtherVault,
    VaultHealthReport? healthReport,
    CsvImportOutcome? lastCsvImportOutcome,
    MergeReviewSummary? mergeReview,
    MergeCommitOutcome? mergeCommitOutcome,
    MergeFailureCode? mergeFailureCode,
    bool? isMergeBusy,
    VaultEntryHistory? entryHistory,
    String? entryHistoryEntryId,
    bool? isEntryHistoryLoading,
    String? entryHistoryError,
    bool clearEntryHistory = false,
    bool clearEntryHistoryError = false,
    bool clearError = false,
    bool clearInfo = false,
    bool clearSyncError = false,
    bool clearRemoteFilesError = false,
    bool clearSyncConflict = false,
    bool clearSyncReloadPending = false,
    bool clearCsvImportOutcome = false,
    bool clearPendingAndroidAutofillSave = false,
    bool clearMergeReview = false,
    bool clearMergeCommitOutcome = false,
    bool clearMergeFailureCode = false,
  }) {
    return VaultState(
      databasePath: databasePath,
      displayName: displayName ?? this.displayName,
      rootGroupId: rootGroupId ?? this.rootGroupId,
      currentGroupId: currentGroupId ?? this.currentGroupId,
      groups: groups ?? this.groups,
      entries: entries ?? this.entries,
      allEntries: allEntries ?? this.allEntries,
      visibleEntries: visibleEntries ?? this.visibleEntries,
      expandedGroupIds: expandedGroupIds ?? this.expandedGroupIds,
      folderCounts: folderCounts ?? this.folderCounts,
      folderDescendantIds: folderDescendantIds ?? this.folderDescendantIds,
      recycleBinEntries: recycleBinEntries ?? this.recycleBinEntries,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      isRecycleBinView: isRecycleBinView ?? this.isRecycleBinView,
      isRecycleBinLoading: isRecycleBinLoading ?? this.isRecycleBinLoading,
      searchQuery: searchQuery ?? this.searchQuery,
      sortBy: sortBy ?? this.sortBy,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      infoMessage: clearInfo ? null : infoMessage ?? this.infoMessage,
      isDriveConnected: isDriveConnected ?? this.isDriveConnected,
      isDriveLinked: isDriveLinked ?? this.isDriveLinked,
      autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
      syncStatus: syncStatus ?? this.syncStatus,
      syncError: clearSyncError ? null : syncError ?? this.syncError,
      driveReconnectRequired:
          driveReconnectRequired ?? this.driveReconnectRequired,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSyncedLocalChecksum:
          lastSyncedLocalChecksum ?? this.lastSyncedLocalChecksum,
      pendingSyncConflict: clearSyncConflict
          ? null
          : pendingSyncConflict ?? this.pendingSyncConflict,
      remoteFiles: remoteFiles ?? this.remoteFiles,
      isLoadingRemoteFiles: isLoadingRemoteFiles ?? this.isLoadingRemoteFiles,
      remoteFilesError: clearRemoteFilesError
          ? null
          : remoteFilesError ?? this.remoteFilesError,
      remoteFilesReconnectRequired: clearRemoteFilesError
          ? false
          : remoteFilesReconnectRequired ?? this.remoteFilesReconnectRequired,
      linkedRemoteFileName: linkedRemoteFileName ?? this.linkedRemoteFileName,
      isSyncing: isSyncing ?? this.isSyncing,
      isSyncReloadPending: clearSyncReloadPending
          ? false
          : isSyncReloadPending ?? this.isSyncReloadPending,
      isOffline: isOffline ?? this.isOffline,
      duplicateGroups: duplicateGroups ?? this.duplicateGroups,
      isDuplicatesLoading: isDuplicatesLoading ?? this.isDuplicatesLoading,
      pendingAppleAutofillAssociations:
          pendingAppleAutofillAssociations ??
          this.pendingAppleAutofillAssociations,
      pendingAndroidAutofillSave: clearPendingAndroidAutofillSave
          ? null
          : pendingAndroidAutofillSave ?? this.pendingAndroidAutofillSave,
      passkeyClashes: passkeyClashes ?? this.passkeyClashes,
      passkeyOtherVault: passkeyOtherVault ?? this.passkeyOtherVault,
      healthReport: healthReport ?? this.healthReport,
      lastCsvImportOutcome: clearCsvImportOutcome
          ? null
          : lastCsvImportOutcome ?? this.lastCsvImportOutcome,
      mergeReview: clearMergeReview ? null : mergeReview ?? this.mergeReview,
      mergeCommitOutcome: clearMergeCommitOutcome
          ? null
          : mergeCommitOutcome ?? this.mergeCommitOutcome,
      mergeFailureCode: clearMergeFailureCode
          ? null
          : mergeFailureCode ?? this.mergeFailureCode,
      isMergeBusy: isMergeBusy ?? this.isMergeBusy,
      entryHistory: clearEntryHistory
          ? null
          : entryHistory ?? this.entryHistory,
      entryHistoryEntryId: clearEntryHistory
          ? null
          : entryHistoryEntryId ?? this.entryHistoryEntryId,
      isEntryHistoryLoading: clearEntryHistory
          ? false
          : isEntryHistoryLoading ?? this.isEntryHistoryLoading,
      entryHistoryError: clearEntryHistory || clearEntryHistoryError
          ? null
          : entryHistoryError ?? this.entryHistoryError,
    );
  }

  VaultGroup? get currentGroup {
    if (currentGroupId == null) {
      return null;
    }
    for (final group in groups) {
      if (group.id == currentGroupId) {
        return group;
      }
    }
    return null;
  }

  List<VaultGroup> get currentChildGroups {
    if (currentGroupId == null) {
      return const [];
    }
    return groups
        .where(
          (group) => group.parentId == currentGroupId && !group.isRecycleBin,
        )
        .toList();
  }

  List<VaultGroup> breadcrumbs() {
    final current = currentGroup;
    if (current == null) {
      return const [];
    }

    final byId = {for (final group in groups) group.id: group};
    final path = <VaultGroup>[];
    VaultGroup? cursor = current;
    while (cursor != null) {
      path.insert(0, cursor);
      cursor = cursor.parentId == null ? null : byId[cursor.parentId!];
    }

    return path;
  }

  @override
  List<Object?> get props => [
    databasePath,
    displayName,
    rootGroupId,
    currentGroupId,
    groups,
    entries,
    allEntries,
    visibleEntries,
    expandedGroupIds,
    folderCounts,
    folderDescendantIds,
    recycleBinEntries,
    isLoading,
    isSaving,
    isRecycleBinView,
    isRecycleBinLoading,
    searchQuery,
    sortBy,
    errorMessage,
    infoMessage,
    isDriveConnected,
    isDriveLinked,
    autoSyncEnabled,
    syncStatus,
    syncError,
    driveReconnectRequired,
    lastSyncAt,
    lastSyncedLocalChecksum,
    pendingSyncConflict,
    remoteFiles,
    isLoadingRemoteFiles,
    remoteFilesError,
    remoteFilesReconnectRequired,
    linkedRemoteFileName,
    isSyncing,
    isSyncReloadPending,
    isOffline,
    duplicateGroups,
    isDuplicatesLoading,
    pendingAppleAutofillAssociations,
    pendingAndroidAutofillSave,
    passkeyClashes,
    passkeyOtherVault,
    // Deliberately NOT `healthReport` itself (plan.md risk: "Adding
    // healthReport to VaultState triggers rebuild storms" — its
    // categories carry full entryIds lists that would make every
    // VaultState `==`/hashCode do O(entries) list comparisons). Score +
    // per-category counts are enough to detect a change worth reacting to.
    healthReport.score,
    for (final category in healthReport.categories) category.count,
    lastCsvImportOutcome,
    mergeReview,
    mergeCommitOutcome,
    mergeFailureCode,
    isMergeBusy,
    // Deliberately NOT the revisions themselves, for the same reason
    // `healthReport` is summarised above: equality would walk every revision
    // of the entry on every state comparison. The id plus the count is what
    // distinguishes one loaded history from another — a given entry's history
    // is read once per open of the view.
    entryHistoryEntryId,
    entryHistory?.revisions.length,
    entryHistory?.retention,
    isEntryHistoryLoading,
    entryHistoryError,
  ];

  @override
  String toString() {
    return 'VaultState('
        'databasePath: $databasePath, '
        'rootGroupId: $rootGroupId, '
        'currentGroupId: $currentGroupId, '
        'groups: ${groups.length}, '
        'entries: ${entries.length}, '
        'allEntries: ${allEntries.length}, '
        'visibleEntries: ${visibleEntries.length}, '
        'expandedGroupIds: $expandedGroupIds, '
        'recycleBinEntries: ${recycleBinEntries.length}, '
        'isLoading: $isLoading, '
        'isSaving: $isSaving, '
        'isRecycleBinView: $isRecycleBinView, '
        'isRecycleBinLoading: $isRecycleBinLoading, '
        'searchQuery: $searchQuery, '
        'sortBy: $sortBy, '
        'errorMessage: $errorMessage, '
        'infoMessage: $infoMessage, '
        'isDriveConnected: $isDriveConnected, '
        'isDriveLinked: $isDriveLinked, '
        'autoSyncEnabled: $autoSyncEnabled, '
        'syncStatus: $syncStatus, '
        'syncError: $syncError, '
        'driveReconnectRequired: $driveReconnectRequired, '
        'lastSyncAt: $lastSyncAt, '
        'pendingSyncConflict: $pendingSyncConflict, '
        'remoteFiles: ${remoteFiles.length}, '
        'isLoadingRemoteFiles: $isLoadingRemoteFiles, '
        'remoteFilesError: $remoteFilesError, '
        'remoteFilesReconnectRequired: '
        '$remoteFilesReconnectRequired, '
        'linkedRemoteFileName: $linkedRemoteFileName, '
        'isSyncing: $isSyncing, '
        'isSyncReloadPending: $isSyncReloadPending, '
        'isOffline: $isOffline, '
        'duplicateGroups: ${duplicateGroups.length}, '
        'isDuplicatesLoading: $isDuplicatesLoading, '
        'pendingAppleAutofillAssociations: '
        '${pendingAppleAutofillAssociations.length}, '
        'pendingAndroidAutofillSave: '
        '${pendingAndroidAutofillSave != null}, '
        'healthReport.score: ${healthReport.score}, '
        'lastCsvImportOutcome: ${lastCsvImportOutcome != null}, '
        'mergeReview: ${mergeReview?.phase}, '
        'mergeCommitOutcome: ${mergeCommitOutcome?.runtimeType}, '
        'mergeFailureCode: $mergeFailureCode, '
        'isMergeBusy: $isMergeBusy, '
        // A count, never a revision (Constitution I / FR-004).
        'entryHistoryEntryId: $entryHistoryEntryId, '
        'entryHistoryRevisions: ${entryHistory?.revisions.length}, '
        'isEntryHistoryLoading: $isEntryHistoryLoading, '
        'entryHistoryError: $entryHistoryError)';
  }
}
