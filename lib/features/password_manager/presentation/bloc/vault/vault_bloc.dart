import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show SocketException;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loggy/loggy.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_transform/stream_transform.dart';

import '../../../data/services/vault_csv_import_service.dart';
import '../../../data/services/vault_duplicate_service.dart';
import '../../../data/services/vault_kdbx_service.dart';
import '../../../domain/models/cloud_storage_error.dart';
import '../../../domain/models/database_sync_status.dart';
import '../../../domain/models/sync_conflict.dart';
import '../../../domain/models/sync_merge_models.dart';
import '../../../domain/repositories/sync_merge_repository.dart'
    show SyncMergeFailure;
import '../../../domain/models/vault_custom_field.dart';
import '../../../domain/repositories/database_sync_repository.dart';
import '../../../domain/models/vault_entry.dart';
import '../../../domain/models/vault_group.dart';
import '../../../domain/models/vault_snapshot.dart';
import '../../../domain/services/url_field_keys.dart';
import '../../../domain/services/vault_health_service.dart';
import '../../../domain/usecases/link_database_to_remote_usecase.dart';
import '../../../domain/usecases/sync_database_now_usecase.dart';
import '../../coordinators/android_autofill_save_coordinator.dart';
import '../../coordinators/apple_autofill_v2_coordinator.dart';
import '../../coordinators/duplicate_merge_coordinator.dart';
import '../../coordinators/entry_history_coordinator.dart';
import '../../coordinators/passkey_coordinator.dart';
import '../../coordinators/session_secret_holder.dart';
import '../../coordinators/sync_merge_coordinator.dart';
import '../../utils/cloud_storage_error_presentation.dart';
import 'vault_event.dart';
import 'vault_state.dart';

/// Appended to a duplicated record's title.
///
/// A suffix rather than a `Copy of ` prefix so the copy sorts next to its
/// original in a title-ordered list, which is where the user is looking when
/// they duplicate something.
const kDuplicateTitleSuffix = ' copy';

const _driveAuthorizationRequiredMessage =
    'Google authorization expired. Reconnect Google Drive to continue.';

class VaultBloc extends Bloc<VaultEvent, VaultState> {
  VaultBloc({
    required String databasePath,
    required this.getSelectedKeyFilePath,
    required this.sessionSecretHolder,
    required this.vaultKdbxService,
    required this.vaultCsvImportService,
    required this.vaultDuplicateService,
    required this.databaseSyncRepository,
    required this.linkDatabaseToRemote,
    required this.syncDatabaseNow,
    this.appleAutofillV2Coordinator = const NoopAppleAutofillV2Coordinator(),
    this.androidAutofillSaveCoordinator,
    this.vaultHealthService = const VaultHealthService(),
    this.folderExpansionPreferences,
    this.syncMergeCoordinator,
    this.entryHistoryCoordinator,
    this.duplicateMergeCoordinator,
    this.passkeyCoordinator,
    this.resolveDatabaseId,
    this.resolveDisplayName,
    this.now = DateTime.now,
  }) : super(VaultState.initial(databasePath: databasePath)) {
    on<InitializeVault>(_onInitializeVault);
    on<RefreshVault>(_onRefreshVault);
    on<UpdateVaultSearchQuery>(
      _onUpdateVaultSearchQuery,
      transformer: (events, mapper) => events
          .debounce(const Duration(milliseconds: 300))
          .distinct((previous, next) => previous.query == next.query)
          .switchMap(mapper),
    );
    on<ClearVaultSearchQuery>(_onClearVaultSearchQuery);
    on<SetVaultSort>(_onSetVaultSort);
    on<LoadRecycleBinEntries>(_onLoadRecycleBinEntries);
    on<OpenGroup>(_onOpenGroup);
    on<SelectVaultFolder>(_onSelectVaultFolder);
    on<SetVaultFolderExpanded>(_onSetVaultFolderExpanded);
    on<OpenParentGroup>(_onOpenParentGroup);
    on<CreateVaultEntry>(_onCreateVaultEntry);
    on<UpdateVaultEntry>(_onUpdateVaultEntry);
    on<DeleteVaultEntry>(_onDeleteVaultEntry);
    on<MoveVaultEntry>(_onMoveVaultEntry);
    on<DuplicateVaultEntry>(_onDuplicateVaultEntry);
    on<CreateVaultGroup>(_onCreateVaultGroup);
    on<RenameVaultGroup>(_onRenameVaultGroup);
    on<DeleteVaultGroup>(_onDeleteVaultGroup);
    on<MoveVaultGroup>(_onMoveVaultGroup);
    on<OpenRecycleBin>(_onOpenRecycleBin);
    on<CloseRecycleBin>(_onCloseRecycleBin);
    on<RestoreVaultEntry>(_onRestoreVaultEntry);
    on<RestoreVaultGroup>(_onRestoreVaultGroup);
    on<DeleteVaultEntryPermanently>(_onDeleteVaultEntryPermanently);
    on<DeleteVaultGroupPermanently>(_onDeleteVaultGroupPermanently);
    on<EmptyRecycleBin>(_onEmptyRecycleBin);
    on<ReportVaultActionAbandoned>(_onReportVaultActionAbandoned);
    on<ClearVaultError>(_onClearVaultError);
    on<ExportVaultAttachment>(_onExportVaultAttachment);
    on<ImportVaultEntriesFromCsv>(_onImportVaultEntriesFromCsv);
    on<ClearVaultInfo>(_onClearVaultInfo);
    on<ConnectGoogleDrive>(_onConnectGoogleDrive);
    on<GoogleDriveReconnectSucceeded>(_onGoogleDriveReconnectSucceeded);
    on<GoogleDriveReconnectFailed>(_onGoogleDriveReconnectFailed);
    on<DisconnectGoogleDrive>(_onDisconnectGoogleDrive);
    on<LinkCurrentDatabaseToDrive>(_onLinkCurrentDatabaseToDrive);
    on<SyncCurrentDatabaseNow>(_onSyncCurrentDatabaseNow);
    on<ToggleCurrentDatabaseAutoSync>(_onToggleCurrentDatabaseAutoSync);
    on<ClearVaultSyncFeedback>(_onClearVaultSyncFeedback);
    on<BackgroundDriveSync>(_onBackgroundDriveSync);
    on<StartSyncMergeReview>(_onStartSyncMergeReview);
    on<UpdateSyncMergeDecision>(_onUpdateSyncMergeDecision);
    on<ApplySyncMergeShortcut>(_onApplySyncMergeShortcut);
    on<CommitSyncMerge>(_onCommitSyncMerge);
    on<CancelSyncMerge>(_onCancelSyncMerge);
    on<ClearSyncMergeOutcome>(_onClearSyncMergeOutcome);
    on<RefreshAppleAutofillPendingAssociations>(
      _onRefreshAppleAutofillPendingAssociations,
    );
    on<ConfirmAppleAutofillPendingAssociation>(
      _onConfirmAppleAutofillPendingAssociation,
    );
    on<RejectAppleAutofillPendingAssociation>(
      _onRejectAppleAutofillPendingAssociation,
    );
    on<CheckAndroidAutofillCapture>(_onCheckAndroidAutofillCapture);
    on<ConfirmAndroidAutofillCapture>(_onConfirmAndroidAutofillCapture);
    on<DeclineAndroidAutofillCapture>(_onDeclineAndroidAutofillCapture);
    on<CancelAndroidAutofillCapture>(_onCancelAndroidAutofillCapture);
    on<LoadEntryHistory>(_onLoadEntryHistory);
    on<ClearEntryHistory>(_onClearEntryHistory);
    on<RestoreEntryRevision>(_onRestoreEntryRevision);
    on<DeleteEntryRevision>(_onDeleteEntryRevision);
    on<ClearEntryHistoryInFile>(_onClearEntryHistoryInFile);
    on<DeletePasskey>(_onDeletePasskey);
    on<LoadDuplicates>(_onLoadDuplicates);
    on<DeleteDuplicateEntry>(_onDeleteDuplicateEntry);
    on<MergeDuplicateEntries>(_onMergeDuplicateEntries);
    on<ClearCsvImportOutcome>(_onClearCsvImportOutcome);
    on<UnlinkCurrentDatabaseFromDrive>(_onUnlinkCurrentDatabaseFromDrive);
    on<LoadRemoteFiles>(
      _onLoadRemoteFiles,
      transformer: (events, mapper) => events
          .debounce(const Duration(milliseconds: 300))
          .distinct(
            (previous, next) => previous.query?.trim() == next.query?.trim(),
          )
          .switchMap(mapper),
    );
  }

  final Future<String?> Function() getSelectedKeyFilePath;

  /// spec-011 FR-1: the session secret comes from the coordinator-owned
  /// in-memory holder, never from `SecureDataSource`. Not part of any
  /// state/props and never logged (constitution principle I).
  final SessionSecretHolder sessionSecretHolder;
  final VaultKdbxService vaultKdbxService;

  /// spec-016 US3. Absent on every platform but Android, where nothing ever
  /// captures a submitted credential.
  final AndroidAutofillSaveCoordinator? androidAutofillSaveCoordinator;
  final VaultCsvImportService vaultCsvImportService;
  final VaultDuplicateService vaultDuplicateService;
  final DatabaseSyncRepository databaseSyncRepository;
  final LinkDatabaseToRemoteUseCase linkDatabaseToRemote;
  final SyncDatabaseNowUseCase syncDatabaseNow;

  /// spec-008 T505: every merge command is forwarded here. Null in hosts and
  /// tests that never merge — the events then report a precondition failure.
  final SyncMergeCoordinator? syncMergeCoordinator;

  /// spec 017: restore and clear sequencing. Null only in tests that never
  /// touch the history.
  final EntryHistoryCoordinator? entryHistoryCoordinator;

  /// spec 023 T207 — writes the pre-merge backup before a duplicate merge.
  final DuplicateMergeCoordinator? duplicateMergeCoordinator;

  /// spec 023: dated backup + delete sequencing for passkeys. Null only in
  /// tests that never delete one.
  final PasskeyCoordinator? passkeyCoordinator;

  /// Maps the open database path to its registry id, the only identity the
  /// merge port accepts. Kept as a callback so this BLoC holds no registry.
  final Future<String?> Function(String databasePath)? resolveDatabaseId;

  /// spec 014 FR-3: maps the open database path to the human-readable name
  /// held in the registry — the file on disk is an opaque identifier on
  /// mobile. A callback for the same reason as [resolveDatabaseId]: this
  /// BLoC holds no registry.
  final Future<String?> Function(String databasePath)? resolveDisplayName;
  final AppleAutofillV2CoordinatorContract appleAutofillV2Coordinator;
  final VaultHealthService vaultHealthService;

  /// spec-019 FR-006g — where the folder expansion set is remembered between
  /// unlocks. Null in tests and in any host that has no preferences: expansion
  /// then behaves exactly as it did before spec 019, in memory only.
  final SharedPreferences? folderExpansionPreferences;

  /// Injected clock (spec-005 non-negotiable): the health report's "old"
  /// category must never call `DateTime.now()` directly, so tests can pass
  /// a fixed `now` and get a deterministic score.
  final DateTime Function() now;

  // Cached copy of the session secret: it survives a holder clear and is
  // only safe because lock/switch dispose this bloc (spec-011 tester note).
  String _password = '';
  String? _keyFilePath;
  String? _lastRegularGroupId;
  Timer? _autoSyncDebounce;

  Future<void> _preloadDriveStateFromLocalMapping(
    Emitter<VaultState> emit,
  ) async {
    final mapping = await databaseSyncRepository.getMapping(state.databasePath);
    if (mapping != null) {
      _safeEmit(
        emit,
        state.copyWith(
          isDriveLinked: true,
          linkedRemoteFileName: mapping.remoteFileName,
          autoSyncEnabled: mapping.autoSyncEnabled,
          lastSyncAt: mapping.lastSyncAt,
          lastSyncedLocalChecksum: mapping.lastSyncedLocalChecksum,
          syncStatus: DatabaseSyncStatus.idle,
        ),
      );
    }
  }

  Future<void> _onInitializeVault(
    InitializeVault event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isLoading: true, clearError: true));
    try {
      // spec-011 FR-2: an absent session secret throws
      // (SessionSecretMissingError) and lands in the locked-state error
      // below — never a silent empty-string fallback.
      _password = sessionSecretHolder.read();
      _keyFilePath = await getSelectedKeyFilePath();
      await _loadDisplayName(emit);
      _restoreExpandedGroupIds(emit);
      await _preloadDriveStateFromLocalMapping(emit);
      await _reload(emit);
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _computeDuplicates(emit);
      _computeHealth(emit);
      add(const BackgroundDriveSync());
    } catch (e, st) {
      logError('Failed to initialize vault.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isLoading: false,
          errorMessage: 'Unable to load vault credentials.',
        ),
      );
    }
  }

  /// Best-effort: an unresolvable name leaves the state's basename fallback
  /// in place rather than failing the whole vault load.
  Future<void> _loadDisplayName(Emitter<VaultState> emit) async {
    final resolve = resolveDisplayName;
    if (resolve == null) return;
    try {
      final name = await resolve(state.databasePath);
      if (name != null && name.trim().isNotEmpty) {
        _safeEmit(emit, state.copyWith(displayName: name));
      }
    } catch (e, st) {
      logError('Failed resolving the database display name.', e, st);
    }
  }

  Future<void> _onRefreshVault(
    RefreshVault event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isLoading: true, clearError: true));
    await _reload(
      emit,
      currentGroupId: state.currentGroupId,
      keepLoadingFlag: false,
    );
    await _loadRecycleBinEntries(emit, isInitialLoad: true);
    _computeDuplicates(emit);
    _computeHealth(emit);
  }

  Future<void> _onOpenRecycleBin(
    OpenRecycleBin event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isLoading: true, clearError: true));
    try {
      if (!state.isRecycleBinView) {
        _lastRegularGroupId = state.currentGroupId ?? state.rootGroupId;
      }

      final recycleBinGroupId = await vaultKdbxService.getRecycleBinGroupId(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
      );

      if (recycleBinGroupId == null) {
        _safeEmit(
          emit,
          state.copyWith(
            isLoading: false,
            errorMessage: 'Recycle bin is empty and not created yet.',
          ),
        );
        return;
      }

      await _reload(
        emit,
        currentGroupId: recycleBinGroupId,
        keepLoadingFlag: false,
      );
      _safeEmit(emit, state.copyWith(isRecycleBinView: true, clearError: true));
    } catch (e, st) {
      logError('Failed opening recycle bin.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isLoading: false,
          errorMessage: 'Unable to open recycle bin.',
        ),
      );
    }
  }

  void _onUpdateVaultSearchQuery(
    UpdateVaultSearchQuery event,
    Emitter<VaultState> emit,
  ) {
    final query = event.query;
    _safeEmit(
      emit,
      state.copyWith(
        searchQuery: query,
        visibleEntries: _computeVisibleEntries(
          entries: state.allEntries,
          searchQuery: query,
          sortBy: state.sortBy,
          folderIds: _folderFilterIds(
            state.currentGroupId,
            state.folderDescendantIds,
          ),
        ),
      ),
    );
  }

  void _onClearVaultSearchQuery(
    ClearVaultSearchQuery event,
    Emitter<VaultState> emit,
  ) {
    _safeEmit(
      emit,
      state.copyWith(
        searchQuery: '',
        visibleEntries: _computeVisibleEntries(
          entries: state.allEntries,
          searchQuery: '',
          sortBy: state.sortBy,
          folderIds: _folderFilterIds(
            state.currentGroupId,
            state.folderDescendantIds,
          ),
        ),
      ),
    );
  }

  void _onSetVaultSort(SetVaultSort event, Emitter<VaultState> emit) {
    _safeEmit(
      emit,
      state.copyWith(
        sortBy: event.sortBy,
        visibleEntries: _computeVisibleEntries(
          entries: state.allEntries,
          searchQuery: state.searchQuery,
          sortBy: event.sortBy,
          folderIds: _folderFilterIds(
            state.currentGroupId,
            state.folderDescendantIds,
          ),
        ),
      ),
    );
  }

  Future<void> _onLoadRecycleBinEntries(
    LoadRecycleBinEntries event,
    Emitter<VaultState> emit,
  ) async {
    await _loadRecycleBinEntries(emit);
  }

  Future<void> _onCloseRecycleBin(
    CloseRecycleBin event,
    Emitter<VaultState> emit,
  ) async {
    final fallback = _lastRegularGroupId ?? state.rootGroupId;
    _safeEmit(emit, state.copyWith(isLoading: true, clearError: true));
    await _reload(emit, currentGroupId: fallback, keepLoadingFlag: false);
    _safeEmit(emit, state.copyWith(isRecycleBinView: false, clearError: true));
  }

  Future<void> _onOpenGroup(OpenGroup event, Emitter<VaultState> emit) async {
    final normalizedExpanded = _normalizeExpandedGroupIds(
      groups: state.groups,
      rootGroupId: state.rootGroupId ?? '',
      currentGroupId: event.groupId,
      previousExpanded: state.expandedGroupIds,
    );

    _safeEmit(
      emit,
      state.copyWith(
        currentGroupId: event.groupId,
        expandedGroupIds: normalizedExpanded,
        visibleEntries: _computeVisibleEntries(
          entries: state.allEntries,
          searchQuery: state.searchQuery,
          sortBy: state.sortBy,
          folderIds: _folderFilterIds(event.groupId, state.folderDescendantIds),
        ),
        clearError: true,
      ),
    );
  }

  Future<void> _onOpenParentGroup(
    OpenParentGroup event,
    Emitter<VaultState> emit,
  ) async {
    final current = state.currentGroup;
    if (current?.parentId == null) {
      return;
    }

    final normalizedExpanded = _normalizeExpandedGroupIds(
      groups: state.groups,
      rootGroupId: state.rootGroupId ?? '',
      currentGroupId: current!.parentId!,
      previousExpanded: state.expandedGroupIds,
    );

    _safeEmit(
      emit,
      state.copyWith(
        currentGroupId: current.parentId,
        expandedGroupIds: normalizedExpanded,
        visibleEntries: _computeVisibleEntries(
          entries: state.allEntries,
          searchQuery: state.searchQuery,
          sortBy: state.sortBy,
          folderIds: _folderFilterIds(
            current.parentId,
            state.folderDescendantIds,
          ),
        ),
        clearError: true,
      ),
    );
  }

  /// spec-019 T009 — select a folder without navigating into it.
  ///
  /// Deliberately does not touch `expandedGroupIds`: in model 1a the chevron
  /// and the row are two different controls, and clicking a folder's name must
  /// not fold or unfold anything (FR-006f).
  void _onSelectVaultFolder(SelectVaultFolder event, Emitter<VaultState> emit) {
    final existingIds = state.groups.map((group) => group.id).toSet();
    if (!existingIds.contains(event.groupId)) {
      return;
    }

    _safeEmit(
      emit,
      state.copyWith(
        currentGroupId: event.groupId,
        visibleEntries: _computeVisibleEntries(
          entries: state.allEntries,
          searchQuery: state.searchQuery,
          sortBy: state.sortBy,
          folderIds: _folderFilterIds(event.groupId, state.folderDescendantIds),
        ),
        clearError: true,
      ),
    );
  }

  /// spec-019 T012 — set one folder's expansion and remember it.
  void _onSetVaultFolderExpanded(
    SetVaultFolderExpanded event,
    Emitter<VaultState> emit,
  ) {
    final existingIds = state.groups.map((group) => group.id).toSet();
    if (!existingIds.contains(event.groupId)) {
      return;
    }

    final expanded = state.expandedGroupIds.toSet();
    final changed = event.expanded
        ? expanded.add(event.groupId)
        : expanded.remove(event.groupId);
    if (!changed) {
      return;
    }

    final ids = expanded.toList()..sort();
    _safeEmit(emit, state.copyWith(expandedGroupIds: ids));
    unawaited(_persistExpandedGroupIds(ids));
  }

  /// The preferences key for this database.
  ///
  /// Hashed rather than the path itself: the key survives in plain text in the
  /// preferences store, and a vault's location on disk says more about its
  /// owner than a folder layout should. The hash is stable, which is all the
  /// key needs to be.
  String get _expandedGroupIdsKey =>
      'vault.folders.expanded.'
      '${sha256.convert(utf8.encode(state.databasePath))}';

  Future<void> _persistExpandedGroupIds(List<String> ids) async {
    final preferences = folderExpansionPreferences;
    if (preferences == null) {
      return;
    }
    try {
      await preferences.setStringList(_expandedGroupIdsKey, ids);
    } catch (e, st) {
      // A folder that forgets it was open is not worth failing an unlock over.
      logError('Failed to persist folder expansion.', e, st);
    }
  }

  /// spec-019 FR-006g — restore the folder shape this database was left in.
  ///
  /// Runs before the first load so the reload's own normalisation sees the
  /// restored set rather than an empty one.
  void _restoreExpandedGroupIds(Emitter<VaultState> emit) {
    final preferences = folderExpansionPreferences;
    if (preferences == null) {
      return;
    }
    final stored = preferences.getStringList(_expandedGroupIdsKey);
    if (stored == null || stored.isEmpty) {
      return;
    }
    _safeEmit(emit, state.copyWith(expandedGroupIds: List<String>.of(stored)));
  }

  Future<void> _onCreateVaultEntry(
    CreateVaultEntry event,
    Emitter<VaultState> emit,
  ) async {
    final currentGroupId = state.currentGroupId;
    if (currentGroupId == null) {
      return;
    }

    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      final createdEntryId = await vaultKdbxService.createEntry(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        groupId: currentGroupId,
        title: event.title,
        username: event.username,
        entryPassword: event.password,
        url: event.url,
        notes: event.notes,
        customFields: event.customFields,
      );
      for (final attachmentPath in event.attachmentPaths) {
        await vaultKdbxService.addAttachment(
          databasePath: state.databasePath,
          password: _password,
          keyFilePath: _keyFilePath,
          entryId: createdEntryId,
          filePath: attachmentPath,
        );
      }
      await _reload(
        emit,
        currentGroupId: currentGroupId,
        keepLoadingFlag: false,
      );
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed creating vault entry.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to create entry.',
        ),
      );
    }
  }

  Future<void> _onUpdateVaultEntry(
    UpdateVaultEntry event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.updateEntry(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
        title: event.title,
        username: event.username,
        entryPassword: event.password,
        url: event.url,
        notes: event.notes,
        customFields: event.customFields,
        // The editor stages attachment changes; they land in the same write
        // as the fields, so a save is all or nothing.
        addedAttachmentPaths: event.attachmentPaths,
        removedAttachmentKeys: event.removedAttachmentKeys,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed updating vault entry.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to update entry.',
        ),
      );
    }
  }

  /// spec-019 C-04-05 — `Duplicate`.
  ///
  /// The copy lands in the source's own group, so it appears in the list the
  /// user is looking at, whatever folder that is.
  Future<void> _onDuplicateVaultEntry(
    DuplicateVaultEntry event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.duplicateEntry(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
        titleSuffix: kDuplicateTitleSuffix,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed duplicating vault entry.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to duplicate record.',
        ),
      );
    }
  }

  Future<void> _onDeleteVaultEntry(
    DeleteVaultEntry event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.deleteEntry(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed deleting vault entry.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to delete entry.',
        ),
      );
    }
  }

  Future<void> _onMoveVaultEntry(
    MoveVaultEntry event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.moveEntry(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
        targetGroupId: event.targetGroupId,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed moving vault entry.', e, st);
      _safeEmit(
        emit,
        state.copyWith(isSaving: false, errorMessage: 'Unable to move entry.'),
      );
    }
  }

  Future<void> _onCreateVaultGroup(
    CreateVaultGroup event,
    Emitter<VaultState> emit,
  ) async {
    final parentGroupId = event.parentGroupId ?? state.currentGroupId;
    if (parentGroupId == null) {
      return;
    }

    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.createGroup(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        parentGroupId: parentGroupId,
        name: event.name,
      );
      await _reload(
        emit,
        currentGroupId: parentGroupId,
        keepLoadingFlag: false,
      );
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed creating vault group.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to create group.',
        ),
      );
    }
  }

  Future<void> _onRenameVaultGroup(
    RenameVaultGroup event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.renameGroup(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        groupId: event.groupId,
        newName: event.newName,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed renaming vault group.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to rename group.',
        ),
      );
    }
  }

  Future<void> _onDeleteVaultGroup(
    DeleteVaultGroup event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      final deletedGroup = state.groups
          .where((group) => group.id == event.groupId)
          .firstOrNull;

      final isGroupEmpty = await vaultKdbxService.isGroupEmpty(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        groupId: event.groupId,
      );

      if (!isGroupEmpty) {
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: 'Unable to delete: folder is not empty.',
          ),
        );
        return;
      }

      await vaultKdbxService.deleteGroup(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        groupId: event.groupId,
        permanently: true,
      );

      final fallbackGroupId = state.currentGroupId == event.groupId
          ? deletedGroup?.parentId ?? state.rootGroupId
          : state.currentGroupId;

      await _reload(
        emit,
        currentGroupId: fallbackGroupId,
        keepLoadingFlag: false,
      );
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed deleting vault group.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to delete group.',
        ),
      );
    }
  }

  Future<void> _onMoveVaultGroup(
    MoveVaultGroup event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.moveGroup(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        groupId: event.groupId,
        targetGroupId: event.targetGroupId,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed moving vault group.', e, st);
      _safeEmit(
        emit,
        state.copyWith(isSaving: false, errorMessage: 'Unable to move group.'),
      );
    }
  }

  Future<void> _onRestoreVaultEntry(
    RestoreVaultEntry event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.restoreEntryFromRecycleBin(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed restoring vault entry from recycle bin.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to restore record.',
        ),
      );
    }
  }

  Future<void> _onRestoreVaultGroup(
    RestoreVaultGroup event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.restoreGroupFromRecycleBin(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        groupId: event.groupId,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed restoring vault group from recycle bin.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to restore folder.',
        ),
      );
    }
  }

  Future<void> _onDeleteVaultEntryPermanently(
    DeleteVaultEntryPermanently event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.deleteEntryPermanently(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed permanently deleting vault entry.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to permanently delete record.',
        ),
      );
    }
  }

  Future<void> _onDeleteVaultGroupPermanently(
    DeleteVaultGroupPermanently event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.deleteGroupPermanently(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        groupId: event.groupId,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed permanently deleting vault group.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to permanently delete folder.',
        ),
      );
    }
  }

  Future<void> _onEmptyRecycleBin(
    EmptyRecycleBin event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.emptyRecycleBin(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed emptying recycle bin.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to empty recycle bin.',
        ),
      );
    }
  }

  Future<void> _reload(
    Emitter<VaultState> emit, {
    String? currentGroupId,
    bool keepLoadingFlag = true,
  }) async {
    try {
      final VaultSnapshot snapshot = await vaultKdbxService.loadVault(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        currentGroupId: currentGroupId ?? state.currentGroupId,
      );

      final normalizedExpanded = _normalizeExpandedGroupIds(
        groups: snapshot.groups,
        rootGroupId: snapshot.rootGroupId,
        currentGroupId: snapshot.currentGroupId,
        previousExpanded: state.expandedGroupIds,
      );

      // spec-019 T007: the one place `allEntries` and `groups` change is the
      // one place the folder aggregates are recomputed.
      final aggregates = _computeFolderAggregates(
        groups: snapshot.groups,
        allEntries: snapshot.allEntries,
      );

      _safeEmit(
        emit,
        state.copyWith(
          isLoading: false,
          isSaving: false,
          rootGroupId: snapshot.rootGroupId,
          currentGroupId: snapshot.currentGroupId,
          groups: snapshot.groups,
          entries: snapshot.entries,
          allEntries: snapshot.allEntries,
          visibleEntries: _computeVisibleEntries(
            entries: snapshot.allEntries,
            searchQuery: state.searchQuery,
            sortBy: state.sortBy,
            folderIds: _folderFilterIds(
              snapshot.currentGroupId,
              aggregates.descendants,
            ),
          ),
          expandedGroupIds: normalizedExpanded,
          folderCounts: aggregates.counts,
          folderDescendantIds: aggregates.descendants,
          clearSyncReloadPending: true,
          clearError: true,
          clearInfo: true,
        ),
      );
      await appleAutofillV2Coordinator.publishVault(
        databasePath: state.databasePath,
        entries: snapshot.allEntries,
      );
      await _refreshAppleAutofillPendingAssociations(emit);
    } catch (e, st) {
      logError('Failed loading vault data.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isLoading: false,
          isSaving: false,
          errorMessage: 'Unable to load vault content.',
        ),
      );
    }

    if (!keepLoadingFlag && state.isLoading) {
      _safeEmit(emit, state.copyWith(isLoading: false));
    }
  }

  Future<void> _onCheckAndroidAutofillCapture(
    CheckAndroidAutofillCapture event,
    Emitter<VaultState> emit,
  ) async {
    final coordinator = androidAutofillSaveCoordinator;
    if (coordinator == null || state.pendingAndroidAutofillSave != null) {
      return;
    }

    final pending = await coordinator.takePendingSave(
      entries: state.allEntries,
    );
    if (pending == null) {
      return;
    }
    _safeEmit(emit, state.copyWith(pendingAndroidAutofillSave: pending));
  }

  Future<void> _onConfirmAndroidAutofillCapture(
    ConfirmAndroidAutofillCapture event,
    Emitter<VaultState> emit,
  ) async {
    final coordinator = androidAutofillSaveCoordinator;
    final pending = state.pendingAndroidAutofillSave;
    if (coordinator == null || pending == null) {
      return;
    }

    // The pending save is cleared here, before the write, not after it: the
    // reload below emits intermediate states, and any one of them still holding
    // a pending save re-opens the confirmation the user just answered.
    _safeEmit(
      emit,
      state.copyWith(
        isSaving: true,
        clearPendingAndroidAutofillSave: true,
        clearError: true,
        clearInfo: true,
      ),
    );
    final result = await coordinator.confirm(
      pending: pending,
      databasePath: state.databasePath,
      keyFilePath: _keyFilePath,
      groupId: state.rootGroupId ?? state.currentGroupId ?? '',
    );

    switch (result.status) {
      case AndroidAutofillSaveStatus.created:
      case AndroidAutofillSaveStatus.updated:
        await _reload(
          emit,
          currentGroupId: state.currentGroupId,
          keepLoadingFlag: false,
        );
        _scheduleAutoSync();
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            clearPendingAndroidAutofillSave: true,
            infoMessage: result.status == AndroidAutofillSaveStatus.created
                ? 'Saved to your vault.'
                : 'Password updated in your vault.',
            clearError: true,
          ),
        );
      case AndroidAutofillSaveStatus.notSaved:
      case AndroidAutofillSaveStatus.failed:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            clearPendingAndroidAutofillSave: true,
            errorMessage: 'Not saved. The credential was discarded.',
          ),
        );
    }
  }

  Future<void> _onDeclineAndroidAutofillCapture(
    DeclineAndroidAutofillCapture event,
    Emitter<VaultState> emit,
  ) async {
    await _dismissAndroidAutofillCapture(emit, declined: true);
  }

  Future<void> _onCancelAndroidAutofillCapture(
    CancelAndroidAutofillCapture event,
    Emitter<VaultState> emit,
  ) async {
    await _dismissAndroidAutofillCapture(emit, declined: false);
  }

  Future<void> _dismissAndroidAutofillCapture(
    Emitter<VaultState> emit, {
    required bool declined,
  }) async {
    final coordinator = androidAutofillSaveCoordinator;
    final pending = state.pendingAndroidAutofillSave;
    if (coordinator == null || pending == null) {
      return;
    }

    // Cleared first, for the same reason as the confirm path.
    _safeEmit(
      emit,
      state.copyWith(clearPendingAndroidAutofillSave: true, clearError: true),
    );
    if (declined) {
      await coordinator.decline(pending);
    } else {
      await coordinator.cancel(pending);
    }
  }

  Future<void> _onRefreshAppleAutofillPendingAssociations(
    RefreshAppleAutofillPendingAssociations event,
    Emitter<VaultState> emit,
  ) async {
    await _refreshAppleAutofillPendingAssociations(emit);
  }

  Future<void> _onConfirmAppleAutofillPendingAssociation(
    ConfirmAppleAutofillPendingAssociation event,
    Emitter<VaultState> emit,
  ) async {
    final pending = state.pendingAppleAutofillAssociations
        .where((association) => association.id == event.id)
        .firstOrNull;
    if (pending == null) {
      await _refreshAppleAutofillPendingAssociations(emit);
      return;
    }

    final entry = state.allEntries
        .where((candidate) => candidate.id == pending.entryId)
        .firstOrNull;
    if (entry == null) {
      await appleAutofillV2Coordinator.clearPendingAssociations(
        ids: [event.id],
      );
      await _refreshAppleAutofillPendingAssociations(emit);
      _safeEmit(
        emit,
        state.copyWith(
          infoMessage: 'AutoFill association skipped.',
          clearError: true,
        ),
      );
      return;
    }

    final target = _normalizeAppleAutofillAssociationTarget(
      type: pending.serviceIdentifierType,
      value: pending.serviceIdentifierValue,
    );
    if (target == null) {
      _safeEmit(
        emit,
        state.copyWith(errorMessage: 'Unable to confirm AutoFill association.'),
      );
      return;
    }

    final update = _buildAppleAutofillAssociationUpdate(
      entry: entry,
      target: target,
    );

    if (!update.needsUpdate) {
      await appleAutofillV2Coordinator.clearPendingAssociations(
        ids: [event.id],
      );
      await _refreshAppleAutofillPendingAssociations(emit);
      _safeEmit(
        emit,
        state.copyWith(
          infoMessage: 'AutoFill association already exists.',
          clearError: true,
        ),
      );
      return;
    }

    _safeEmit(
      emit,
      state.copyWith(isSaving: true, clearError: true, clearInfo: true),
    );
    try {
      await vaultKdbxService.updateEntry(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: entry.id,
        title: entry.title,
        username: entry.username,
        entryPassword: entry.password,
        url: update.url,
        notes: entry.notes,
        customFields: update.customFields,
      );
      await appleAutofillV2Coordinator.clearPendingAssociations(
        ids: [event.id],
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
      _safeEmit(
        emit,
        state.copyWith(
          infoMessage: 'AutoFill association added.',
          clearError: true,
        ),
      );
    } catch (e, st) {
      logError('Failed confirming AutoFill association.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to confirm AutoFill association.',
        ),
      );
    }
  }

  Future<void> _onRejectAppleAutofillPendingAssociation(
    RejectAppleAutofillPendingAssociation event,
    Emitter<VaultState> emit,
  ) async {
    await appleAutofillV2Coordinator.clearPendingAssociations(ids: [event.id]);
    await _refreshAppleAutofillPendingAssociations(emit);
  }

  Future<void> _refreshAppleAutofillPendingAssociations(
    Emitter<VaultState> emit,
  ) async {
    final pending = await appleAutofillV2Coordinator.readPendingAssociations(
      databasePath: state.databasePath,
    );
    _safeEmit(emit, state.copyWith(pendingAppleAutofillAssociations: pending));
  }

  Future<void> _loadRecycleBinEntries(
    Emitter<VaultState> emit, {
    bool isInitialLoad = false,
  }) async {
    if (!isInitialLoad) {
      _safeEmit(
        emit,
        state.copyWith(isRecycleBinLoading: true, clearError: true),
      );
    }

    try {
      final recycleBinEntries = await vaultKdbxService.loadRecycleBinEntries(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
      );
      _safeEmit(
        emit,
        state.copyWith(
          recycleBinEntries: recycleBinEntries,
          isRecycleBinLoading: false,
          clearError: true,
        ),
      );
    } catch (e, st) {
      logError('Failed loading recycle bin entries.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isRecycleBinLoading: false,
          errorMessage: 'Unable to load recycle bin.',
        ),
      );
    }
  }

  void _onReportVaultActionAbandoned(
    ReportVaultActionAbandoned event,
    Emitter<VaultState> emit,
  ) {
    _safeEmit(
      emit,
      state.copyWith(
        errorMessage: 'That record is no longer available. Nothing changed.',
      ),
    );
  }

  void _onClearVaultError(ClearVaultError event, Emitter<VaultState> emit) {
    _safeEmit(emit, state.copyWith(clearError: true));
  }

  Future<void> _onExportVaultAttachment(
    ExportVaultAttachment event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(
      emit,
      state.copyWith(isSaving: true, clearError: true, clearInfo: true),
    );
    try {
      final exportedPath = await vaultKdbxService.exportAttachment(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
        attachmentKey: event.attachmentKey,
        destinationDirectory: event.destinationDirectory,
      );

      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          infoMessage: 'Attachment exported: $exportedPath',
        ),
      );
    } catch (e, st) {
      logError('Failed exporting attachment.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to export attachment.',
        ),
      );
    }
  }

  Future<void> _onImportVaultEntriesFromCsv(
    ImportVaultEntriesFromCsv event,
    Emitter<VaultState> emit,
  ) async {
    final targetGroupId = state.currentGroupId;
    if (targetGroupId == null) {
      _safeEmit(
        emit,
        state.copyWith(
          errorMessage: 'Unable to import: no target folder selected.',
        ),
      );
      return;
    }

    _safeEmit(
      emit,
      state.copyWith(isSaving: true, clearError: true, clearInfo: true),
    );

    try {
      final parsed = await vaultCsvImportService.parseFile(event.filePath);
      if (parsed.items.isEmpty) {
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: 'No valid records found in CSV.',
          ),
        );
        return;
      }

      var importedCount = 0;
      var duplicateCount = 0;
      // spec-005 AC8: every skipped row carries a reason, not just a count.
      final skippedRows = <SkippedRow>[...parsed.skippedRowDetails];
      final existingEntryKeys = event.avoidDuplicates
          ? _buildDuplicateKeys(state.allEntries)
          : <String>{};
      for (final item in parsed.items) {
        final duplicateKey = _entryDuplicateKey(
          title: item.title,
          username: item.username,
          url: item.url,
        );
        if (event.avoidDuplicates && existingEntryKeys.contains(duplicateKey)) {
          duplicateCount += 1;
          skippedRows.add(
            SkippedRow(
              index: item.rowIndex,
              reason: 'Duplicate of a record already in this vault.',
            ),
          );
          continue;
        }

        try {
          await vaultKdbxService.createEntry(
            databasePath: state.databasePath,
            password: _password,
            keyFilePath: _keyFilePath,
            groupId: targetGroupId,
            title: item.title,
            username: item.username,
            entryPassword: item.password,
            url: item.url,
            notes: item.notes,
            customFields: item.customFields,
          );
          if (event.avoidDuplicates) {
            existingEntryKeys.add(duplicateKey);
          }
          importedCount += 1;
        } catch (_) {
          skippedRows.add(
            SkippedRow(index: item.rowIndex, reason: 'Could not be saved.'),
          );
        }
      }

      await _reload(
        emit,
        currentGroupId: targetGroupId,
        keepLoadingFlag: false,
      );
      _computeDuplicates(emit);
      _computeHealth(emit);
      _scheduleAutoSync();

      skippedRows.sort((a, b) => a.index.compareTo(b.index));
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          infoMessage: _buildCsvImportMessage(
            importedCount: importedCount,
            skippedTotal: skippedRows.length,
            duplicateCount: duplicateCount,
          ),
          lastCsvImportOutcome: CsvImportOutcome(
            importedCount: importedCount,
            duplicateSkippedCount: duplicateCount,
            skippedRows: skippedRows,
            // spec 023 T208 — reserved passkey columns the parser refused.
            ignoredColumns: parsed.ignoredColumns,
          ),
        ),
      );
    } catch (e, st) {
      logError('Failed importing CSV entries.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to import CSV file.',
        ),
      );
    }
  }

  void _onClearVaultInfo(ClearVaultInfo event, Emitter<VaultState> emit) {
    _safeEmit(emit, state.copyWith(clearInfo: true));
  }

  void _computeDuplicates(Emitter<VaultState> emit) {
    final recycleBinGroupIds = _recycleBinGroupIds(state.groups);
    final recycleBinEntryIds = state.recycleBinEntries
        .map((entry) => entry.id)
        .toSet();
    final activeEntries = state.allEntries
        .where((entry) => !recycleBinGroupIds.contains(entry.groupId))
        .where((entry) => !recycleBinEntryIds.contains(entry.id))
        .toList(growable: false);
    final groups = vaultDuplicateService.findDuplicates(activeEntries);
    _safeEmit(
      emit,
      state.copyWith(duplicateGroups: groups, isDuplicatesLoading: false),
    );
  }

  /// spec-019 FR-006h — [groupId] plus its whole subtree, or null when there
  /// is no folder to filter by.
  ///
  /// Takes the descendants map explicitly: during a reload the new map is not
  /// on `state` yet, and using the stale one would filter the fresh records
  /// through the previous vault's shape.
  Set<String>? _folderFilterIds(
    String? groupId,
    Map<String, Set<String>> descendants,
  ) {
    if (groupId == null) {
      return null;
    }
    return <String>{groupId, ...?descendants[groupId]};
  }

  /// spec-019 T007 / FR-006i — one post-order walk producing both folder
  /// aggregates.
  ///
  /// Counts are **inclusive of descendants**, which is the number the design's
  /// folder column shows. Recycle-bin groups are excluded from both results, so
  /// the root's count is the same vault `All items` claims to hold (FR-002a).
  ///
  /// Cost is O(groups + entries) once per reload. The alternative — asking a
  /// folder for its count while building its row — is that same walk once per
  /// row, which is why this is computed and stored rather than derived on
  /// demand (plan Performance Goals).
  ({Map<String, int> counts, Map<String, Set<String>> descendants})
  _computeFolderAggregates({
    required List<VaultGroup> groups,
    required List<VaultEntry> allEntries,
  }) {
    final excluded = _recycleBinGroupIds(groups);
    final live = groups
        .where((group) => !excluded.contains(group.id))
        .toList(growable: false);

    final liveIds = live.map((group) => group.id).toSet();
    final children = <String, List<String>>{};
    for (final group in live) {
      final parentId = group.parentId;
      if (parentId != null && liveIds.contains(parentId)) {
        (children[parentId] ??= <String>[]).add(group.id);
      }
    }

    final direct = <String, int>{};
    for (final entry in allEntries) {
      if (excluded.contains(entry.groupId)) {
        continue;
      }
      direct[entry.groupId] = (direct[entry.groupId] ?? 0) + 1;
    }

    final counts = <String, int>{};
    final descendants = <String, Set<String>>{};

    // Iterative post-order: a `.kdbx` group tree is user-authored and can be
    // arbitrarily deep, and a recursive walk would put that depth on the
    // stack. `visited` also makes a malformed cycle terminate instead of
    // hanging the vault.
    // A root here is anything with no live parent — the real root, and also
    // any group orphaned by a parent that is gone or in the bin. Rooting the
    // orphans too is what keeps their records inside a count somewhere.
    final stack = <String>[
      for (final group in live)
        if (group.parentId == null || !liveIds.contains(group.parentId))
          group.id,
    ];
    final expanded = <String>{};
    while (stack.isNotEmpty) {
      final id = stack.last;
      if (expanded.add(id)) {
        for (final child in children[id] ?? const <String>[]) {
          if (!expanded.contains(child)) {
            stack.add(child);
          }
        }
        continue;
      }
      stack.removeLast();
      if (counts.containsKey(id)) {
        continue;
      }
      var total = direct[id] ?? 0;
      final subtree = <String>{};
      for (final child in children[id] ?? const <String>[]) {
        total += counts[child] ?? 0;
        subtree.add(child);
        subtree.addAll(descendants[child] ?? const <String>{});
      }
      counts[id] = total;
      descendants[id] = subtree;
    }

    return (counts: counts, descendants: descendants);
  }

  Set<String> _recycleBinGroupIds(List<VaultGroup> groups) {
    final ids = groups
        .where((group) => group.isRecycleBin)
        .map((group) => group.id)
        .toSet();
    if (ids.isEmpty) {
      return ids;
    }

    var added = true;
    while (added) {
      added = false;
      for (final group in groups) {
        if (group.parentId != null &&
            ids.contains(group.parentId) &&
            ids.add(group.id)) {
          added = true;
        }
      }
    }
    return ids;
  }

  /// spec 017 T201 / FR-015 — one read, on demand, for one entry.
  ///
  /// Thin by construction (Constitution II): the service returns revisions and
  /// retention from a single open, so there is nothing to sequence here.
  Future<void> _onLoadEntryHistory(
    LoadEntryHistory event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(
      emit,
      state.copyWith(
        entryHistoryEntryId: event.entryId,
        isEntryHistoryLoading: true,
        clearEntryHistoryError: true,
      ),
    );
    try {
      final history = await vaultKdbxService.loadEntryHistory(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
      );
      // The view moved on (closed, or opened another entry) while the file
      // was being read: its revisions are not this surface's to show.
      if (state.entryHistoryEntryId != event.entryId) {
        return;
      }
      _safeEmit(
        emit,
        state.copyWith(entryHistory: history, isEntryHistoryLoading: false),
      );
    } catch (e, st) {
      logError('Failed loading entry history.', e, st);
      if (state.entryHistoryEntryId != event.entryId) {
        return;
      }
      _safeEmit(
        emit,
        state.copyWith(
          isEntryHistoryLoading: false,
          entryHistoryError: 'Unable to read this record\u2019s history.',
        ),
      );
    }
  }

  void _onClearEntryHistory(ClearEntryHistory event, Emitter<VaultState> emit) {
    _safeEmit(emit, state.copyWith(clearEntryHistory: true));
  }

  /// spec 017 T304 — translate and delegate: the coordinator sequences the
  /// restore, this reloads and tells the user (Constitution II).
  Future<void> _onRestoreEntryRevision(
    RestoreEntryRevision event,
    Emitter<VaultState> emit,
  ) async {
    final coordinator = entryHistoryCoordinator;
    if (coordinator == null) {
      _safeEmit(
        emit,
        state.copyWith(errorMessage: 'Unable to restore this version.'),
      );
      return;
    }
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    final result = await coordinator.restore(
      databasePath: state.databasePath,
      keyFilePath: _keyFilePath,
      entryId: event.entryId,
      replacedAt: event.replacedAt,
      ordinal: event.ordinal,
    );
    switch (result.outcome) {
      case EntryHistoryOutcome.done:
        await _afterHistoryWrite(
          emit,
          entryId: event.entryId,
          info: 'Previous version restored.',
        );
      case EntryHistoryOutcome.vaultLocked:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: 'The vault is locked. Nothing was changed.',
          ),
        );
      case EntryHistoryOutcome.failed:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: 'Unable to restore this version.',
          ),
        );
    }
  }

  /// spec 017 T403 / FR-009 — one service call, no backup (the confirmation
  /// is the safeguard, by design), so nothing to sequence in a coordinator.
  Future<void> _onDeleteEntryRevision(
    DeleteEntryRevision event,
    Emitter<VaultState> emit,
  ) async {
    // The same refusal the coordinator gives restore and clear: the vault
    // locked between the confirmation and the act.
    if (!sessionSecretHolder.hasSecret) {
      _safeEmit(
        emit,
        state.copyWith(
          errorMessage: 'The vault is locked. Nothing was changed.',
        ),
      );
      return;
    }
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.deleteEntryRevision(
        databasePath: state.databasePath,
        password: sessionSecretHolder.read(),
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
        replacedAt: event.replacedAt,
        ordinal: event.ordinal,
      );
    } catch (e, st) {
      logError('Failed deleting entry revision.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to delete this version.',
        ),
      );
      return;
    }
    await _afterHistoryWrite(
      emit,
      entryId: event.entryId,
      info: 'Previous version deleted.',
    );
  }

  /// spec 017 T403 / FR-010 — the coordinator writes the dated backup first.
  Future<void> _onClearEntryHistoryInFile(
    ClearEntryHistoryInFile event,
    Emitter<VaultState> emit,
  ) async {
    final coordinator = entryHistoryCoordinator;
    if (coordinator == null) {
      _safeEmit(
        emit,
        state.copyWith(errorMessage: 'Unable to clear this history.'),
      );
      return;
    }
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    final result = await coordinator.clearHistory(
      databasePath: state.databasePath,
      keyFilePath: _keyFilePath,
      entryId: event.entryId,
    );
    final backup = result.backupPath;
    switch (result.outcome) {
      case EntryHistoryOutcome.done:
        await _afterHistoryWrite(
          emit,
          entryId: event.entryId,
          info:
              'History cleared. A backup was saved as ${p.basename(backup!)}.',
        );
      case EntryHistoryOutcome.vaultLocked:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: 'The vault is locked. Nothing was changed.',
          ),
        );
      case EntryHistoryOutcome.failed:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: backup == null
                ? 'Unable to clear this history. Nothing was changed.'
                : 'Unable to clear this history. The backup '
                      '${p.basename(backup)} was kept.',
          ),
        );
    }
  }

  /// spec 023 T205 / FR-010 — translate and delegate: the coordinator writes
  /// the dated backup and then the delete, this reloads and tells the user
  /// (Constitution II).
  Future<void> _onDeletePasskey(
    DeletePasskey event,
    Emitter<VaultState> emit,
  ) async {
    final coordinator = passkeyCoordinator;
    if (coordinator == null) {
      _safeEmit(
        emit,
        state.copyWith(errorMessage: 'Unable to delete this passkey.'),
      );
      return;
    }
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    final result = await coordinator.deletePasskey(
      databasePath: state.databasePath,
      keyFilePath: _keyFilePath,
      entryId: event.entryId,
      relyingPartyId: event.relyingPartyId,
      credentialId: event.credentialId,
    );
    final backup = result.backupPath;
    switch (result.outcome) {
      case PasskeyOutcome.done:
        await _afterHistoryWrite(
          emit,
          entryId: event.entryId,
          info:
              'Passkey deleted. A backup was saved as ${p.basename(backup!)}.',
        );
      case PasskeyOutcome.vaultLocked:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: 'The vault is locked. Nothing was changed.',
          ),
        );
      case PasskeyOutcome.notFound:
        // Not an error the user caused: the record on screen is stale, so
        // reload rather than leave them looking at a passkey that is gone.
        await _afterHistoryWrite(
          emit,
          entryId: event.entryId,
          info: 'That passkey is no longer on this record.',
        );
      case PasskeyOutcome.alreadyExists:
        // Unreachable on a delete: only `createPasskey` refuses this way.
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: 'Unable to delete this passkey. Nothing was changed.',
          ),
        );
      case PasskeyOutcome.failed:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: backup == null
                ? 'Unable to delete this passkey. Nothing was changed.'
                : 'Unable to delete this passkey. The backup '
                      '${p.basename(backup)} was kept.',
          ),
        );
    }
  }

  /// Reload, tell the user, and re-read the history if its view is still
  /// open on this entry.
  Future<void> _afterHistoryWrite(
    Emitter<VaultState> emit, {
    required String entryId,
    required String info,
  }) async {
    try {
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed reloading after a history write.', e, st);
    }
    _safeEmit(emit, state.copyWith(isSaving: false, infoMessage: info));
    if (state.entryHistoryEntryId == entryId) {
      add(LoadEntryHistory(entryId));
    }
  }

  void _onLoadDuplicates(LoadDuplicates event, Emitter<VaultState> emit) {
    _safeEmit(emit, state.copyWith(isDuplicatesLoading: true));
    _computeDuplicates(emit);
    _computeHealth(emit);
  }

  void _onClearCsvImportOutcome(
    ClearCsvImportOutcome event,
    Emitter<VaultState> emit,
  ) {
    _safeEmit(emit, state.copyWith(clearCsvImportOutcome: true));
  }

  /// spec-005 T3: recomputed on unlock and after every write, alongside
  /// `_computeDuplicates` (same call sites — duplicates feed one of the
  /// five categories). Never per keystroke/rebuild.
  void _computeHealth(Emitter<VaultState> emit) {
    final recycleBinGroupIds = _recycleBinGroupIds(state.groups);
    final recycleBinEntryIds = state.recycleBinEntries
        .map((entry) => entry.id)
        .toSet();
    final activeEntries = state.allEntries
        .where((entry) => !recycleBinGroupIds.contains(entry.groupId))
        .where((entry) => !recycleBinEntryIds.contains(entry.id))
        .toList(growable: false);
    final report = vaultHealthService.buildReport(
      activeEntries: activeEntries,
      duplicateGroups: state.duplicateGroups,
      now: now(),
    );
    _safeEmit(emit, state.copyWith(healthReport: report));
  }

  Future<void> _onDeleteDuplicateEntry(
    DeleteDuplicateEntry event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    try {
      await vaultKdbxService.deleteEntry(
        databasePath: state.databasePath,
        password: _password,
        keyFilePath: _keyFilePath,
        entryId: event.entryId,
      );
      await _reload(
        emit,
        currentGroupId: state.currentGroupId,
        keepLoadingFlag: false,
      );
      await _loadRecycleBinEntries(emit, isInitialLoad: true);
      _computeDuplicates(emit);
      _computeHealth(emit);
      _scheduleAutoSync();
    } catch (e, st) {
      logError('Failed deleting duplicate entry.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isSaving: false,
          errorMessage: 'Unable to delete duplicate.',
        ),
      );
    }
  }

  /// spec 023 T207 — translate and delegate: the coordinator writes the dated
  /// backup and then the merge, this reloads and tells the user.
  Future<void> _onMergeDuplicateEntries(
    MergeDuplicateEntries event,
    Emitter<VaultState> emit,
  ) async {
    final coordinator = duplicateMergeCoordinator;
    if (coordinator == null) {
      _safeEmit(emit, state.copyWith(errorMessage: 'Unable to merge entries.'));
      return;
    }
    _safeEmit(emit, state.copyWith(isSaving: true, clearError: true));
    final result = await coordinator.merge(
      databasePath: state.databasePath,
      keyFilePath: _keyFilePath,
      primaryId: event.primaryId,
      secondaryIds: event.secondaryIds,
    );
    final backup = result.backupPath;
    switch (result.outcome) {
      case DuplicateMergeOutcome.done:
        await _reload(
          emit,
          currentGroupId: state.currentGroupId,
          keepLoadingFlag: false,
        );
        await _loadRecycleBinEntries(emit, isInitialLoad: true);
        _computeDuplicates(emit);
        _computeHealth(emit);
        _scheduleAutoSync();
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            infoMessage:
                'Records merged. A backup was saved as '
                '${p.basename(backup!)}.',
          ),
        );
      case DuplicateMergeOutcome.vaultLocked:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: 'The vault is locked. Nothing was changed.',
          ),
        );
      case DuplicateMergeOutcome.passkeyConflict:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage:
                'These records hold two different passkeys for '
                '${result.relyingPartyId ?? 'the same site'}. Only the site '
                'knows which one it still accepts, so nothing was merged. '
                'Delete the passkey you no longer use, then merge.',
          ),
        );
      case DuplicateMergeOutcome.failed:
        _safeEmit(
          emit,
          state.copyWith(
            isSaving: false,
            errorMessage: backup == null
                ? 'Unable to merge entries. Nothing was changed.'
                : 'Unable to merge entries. The backup '
                      '${p.basename(backup)} was kept.',
          ),
        );
    }
  }

  Future<void> _onConnectGoogleDrive(
    ConnectGoogleDrive event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(
      emit,
      state.copyWith(
        syncStatus: DatabaseSyncStatus.syncing,
        clearSyncError: true,
        driveReconnectRequired: false,
      ),
    );
    try {
      await databaseSyncRepository.connect();
      await _refreshSyncState(emit);
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.success,
          infoMessage: 'Google Drive connected.',
          driveReconnectRequired: false,
        ),
      );
    } catch (e, st) {
      logError('Google Drive connect failed.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.error,
          syncError: _buildDriveConnectErrorMessage(e),
          driveReconnectRequired: false,
        ),
      );
    }
  }

  void _onGoogleDriveReconnectSucceeded(
    GoogleDriveReconnectSucceeded event,
    Emitter<VaultState> emit,
  ) {
    _safeEmit(
      emit,
      state.copyWith(
        isDriveConnected: true,
        syncStatus: DatabaseSyncStatus.success,
        driveReconnectRequired: false,
        remoteFiles: event.remoteFiles,
        isLoadingRemoteFiles: false,
        clearSyncError: true,
        clearRemoteFilesError: event.remoteFiles != null,
      ),
    );
  }

  void _onGoogleDriveReconnectFailed(
    GoogleDriveReconnectFailed event,
    Emitter<VaultState> emit,
  ) {
    logError('Google Drive reconnect failed.', null, event.stackTrace);
    final authorizationRequired = _requiresDrivePermissionReauth(event.error);
    final message = authorizationRequired
        ? _driveAuthorizationRequiredMessage
        : event.duringRemoteLoad
        ? 'Unable to load remote Drive files.'
        : _buildDriveConnectErrorMessage(event.error);
    if (event.remoteFiles) {
      _safeEmit(
        emit,
        state.copyWith(
          isDriveConnected: authorizationRequired
              ? false
              : state.isDriveConnected,
          isLoadingRemoteFiles: false,
          remoteFilesError: message,
          remoteFilesReconnectRequired: authorizationRequired,
          syncStatus: DatabaseSyncStatus.error,
          clearSyncError: true,
        ),
      );
      return;
    }
    _safeEmit(
      emit,
      state.copyWith(
        isDriveConnected: false,
        syncStatus: DatabaseSyncStatus.error,
        syncError: message,
        driveReconnectRequired: true,
        isOffline: false,
        clearSyncConflict: true,
      ),
    );
  }

  Future<void> _onBackgroundDriveSync(
    BackgroundDriveSync event,
    Emitter<VaultState> emit,
  ) async {
    // Silently refresh Drive state without touching syncStatus (no UI flash).
    final connected = await databaseSyncRepository.isConnected();
    final mapping = await databaseSyncRepository.getMapping(state.databasePath);
    _safeEmit(
      emit,
      state.copyWith(
        isDriveConnected: connected,
        isDriveLinked: mapping != null,
        linkedRemoteFileName: mapping?.remoteFileName,
        autoSyncEnabled: mapping?.autoSyncEnabled ?? true,
        lastSyncAt: mapping?.lastSyncAt,
        lastSyncedLocalChecksum: mapping?.lastSyncedLocalChecksum,
      ),
    );

    if (!connected || mapping == null || !state.autoSyncEnabled) {
      return;
    }

    _safeEmit(emit, state.copyWith(isSyncing: true));
    try {
      await _performSync(
        emit,
        silentIfConflict: true,
        emitSyncingStatus: false,
      );

      if (state.syncStatus != DatabaseSyncStatus.conflict) {
        if (!state.isSaving) {
          await _reload(
            emit,
            currentGroupId: state.currentGroupId,
            keepLoadingFlag: false,
          );
        } else {
          _safeEmit(emit, state.copyWith(isSyncReloadPending: true));
        }
      }
    } catch (e, st) {
      if (isCloudAuthorizationRequired(e)) {
        _emitDriveAuthorizationRequired(emit);
      } else {
        logError('Background Drive sync failed.', e, st);
        _safeEmit(emit, state.copyWith(isDriveConnected: false));
      }
    } finally {
      _safeEmit(emit, state.copyWith(isSyncing: false));
    }
  }

  Future<void> _onDisconnectGoogleDrive(
    DisconnectGoogleDrive event,
    Emitter<VaultState> emit,
  ) async {
    _safeEmit(
      emit,
      state.copyWith(
        syncStatus: DatabaseSyncStatus.syncing,
        driveReconnectRequired: false,
      ),
    );
    try {
      await databaseSyncRepository.disconnect();
      _safeEmit(
        emit,
        state.copyWith(
          isDriveConnected: false,
          isDriveLinked: false,
          linkedRemoteFileName: null,
          syncStatus: DatabaseSyncStatus.disconnected,
          infoMessage: 'Google Drive disconnected.',
          clearSyncError: true,
          clearSyncConflict: true,
        ),
      );
    } catch (e, st) {
      logError('Google Drive disconnect failed.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.error,
          syncError: 'Unable to disconnect Google Drive.',
        ),
      );
    }
  }

  Future<void> _onLinkCurrentDatabaseToDrive(
    LinkCurrentDatabaseToDrive event,
    Emitter<VaultState> emit,
  ) async {
    if (!state.isDriveConnected) {
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.error,
          syncError: 'Connect Google Drive first.',
        ),
      );
      return;
    }

    _safeEmit(
      emit,
      state.copyWith(
        syncStatus: DatabaseSyncStatus.syncing,
        clearSyncError: true,
      ),
    );
    try {
      final mapping = await linkDatabaseToRemote(
        databasePath: state.databasePath,
        remoteFileId: event.remoteFileId,
        remoteFileName: event.remoteFileName,
      );
      _safeEmit(
        emit,
        state.copyWith(
          isDriveLinked: true,
          linkedRemoteFileName: mapping.remoteFileName,
          autoSyncEnabled: mapping.autoSyncEnabled,
          lastSyncAt: mapping.lastSyncAt,
          lastSyncedLocalChecksum: mapping.lastSyncedLocalChecksum,
          syncStatus: DatabaseSyncStatus.success,
          infoMessage: 'Database linked to ${mapping.remoteFileName}.',
        ),
      );
    } catch (e, st) {
      if (isCloudAuthorizationRequired(e)) {
        _emitDriveAuthorizationRequired(emit);
        return;
      }
      logError('Link database to Drive failed.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.error,
          syncError: 'Unable to link current database.',
        ),
      );
    }
  }

  Future<void> _onSyncCurrentDatabaseNow(
    SyncCurrentDatabaseNow event,
    Emitter<VaultState> emit,
  ) async {
    await _performSync(
      emit,
      resolution: event.resolution,
      silentIfConflict: event.silentIfConflict,
    );
    await _reload(
      emit,
      currentGroupId: state.currentGroupId,
      keepLoadingFlag: false,
    );
  }

  Future<void> _onToggleCurrentDatabaseAutoSync(
    ToggleCurrentDatabaseAutoSync event,
    Emitter<VaultState> emit,
  ) async {
    try {
      await databaseSyncRepository.setAutoSync(
        state.databasePath,
        event.enabled,
      );
      _safeEmit(
        emit,
        state.copyWith(
          autoSyncEnabled: event.enabled,
          infoMessage: event.enabled
              ? 'Auto-sync enabled.'
              : 'Auto-sync disabled.',
        ),
      );
    } catch (e, st) {
      logError('Toggle auto-sync failed.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.error,
          syncError: 'Unable to update auto-sync setting.',
        ),
      );
    }
  }

  Future<void> _onUnlinkCurrentDatabaseFromDrive(
    UnlinkCurrentDatabaseFromDrive event,
    Emitter<VaultState> emit,
  ) async {
    try {
      await databaseSyncRepository.removeMapping(state.databasePath);
      _safeEmit(
        emit,
        state.copyWith(
          isDriveLinked: false,
          linkedRemoteFileName: null,
          lastSyncAt: null,
          syncStatus: DatabaseSyncStatus.idle,
          infoMessage: 'Database unlinked from Drive.',
          clearSyncError: true,
        ),
      );
    } catch (e, st) {
      logError('Unlink database from Drive failed.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.error,
          syncError: 'Unable to unlink database.',
        ),
      );
    }
  }

  void _onClearVaultSyncFeedback(
    ClearVaultSyncFeedback event,
    Emitter<VaultState> emit,
  ) {
    if (state.driveReconnectRequired) {
      _safeEmit(emit, state.copyWith(clearSyncConflict: true));
      return;
    }
    _safeEmit(
      emit,
      state.copyWith(clearSyncError: true, clearSyncConflict: true),
    );
  }

  Future<void> _onLoadRemoteFiles(
    LoadRemoteFiles event,
    Emitter<VaultState> emit,
  ) async {
    if (!state.isDriveConnected) {
      _safeEmit(
        emit,
        state.copyWith(
          remoteFiles: const [],
          isLoadingRemoteFiles: false,
          clearRemoteFilesError: true,
        ),
      );
      return;
    }

    _safeEmit(
      emit,
      state.copyWith(
        isLoadingRemoteFiles: true,
        clearSyncError: true,
        clearRemoteFilesError: true,
      ),
    );
    try {
      final files = await databaseSyncRepository.listRemoteFiles(
        query: event.query,
      );
      _safeEmit(
        emit,
        state.copyWith(
          remoteFiles: files,
          isLoadingRemoteFiles: false,
          clearSyncError: true,
          clearRemoteFilesError: true,
        ),
      );
    } catch (e, st) {
      if (_requiresDrivePermissionReauth(e)) {
        _safeEmit(
          emit,
          state.copyWith(
            isDriveConnected: false,
            isDriveLinked: false,
            isLoadingRemoteFiles: false,
            remoteFilesError: _driveAuthorizationRequiredMessage,
            remoteFilesReconnectRequired: true,
            syncStatus: DatabaseSyncStatus.error,
            isOffline: false,
            clearSyncError: true,
            clearSyncConflict: true,
          ),
        );
        return;
      }

      logError('Unable to load Drive files.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          isLoadingRemoteFiles: false,
          remoteFilesError: 'Unable to load remote Drive files.',
          remoteFilesReconnectRequired: false,
          syncStatus: DatabaseSyncStatus.error,
          clearSyncError: true,
        ),
      );
    }
  }

  bool _requiresDrivePermissionReauth(Object error) {
    if (isCloudAuthorizationRequired(error)) {
      return true;
    }
    final message = error.toString().toLowerCase();
    return message.contains('authorization is outdated') ||
        message.contains('authorization needs to be renewed') ||
        message.contains('full drive access') ||
        message.contains('google account not connected');
  }

  void _emitDriveAuthorizationRequired(Emitter<VaultState> emit) {
    _safeEmit(
      emit,
      state.copyWith(
        isDriveConnected: false,
        isDriveLinked: false,
        isLoadingRemoteFiles: false,
        syncError: _driveAuthorizationRequiredMessage,
        driveReconnectRequired: true,
        syncStatus: DatabaseSyncStatus.error,
        isOffline: false,
        clearSyncConflict: true,
      ),
    );
  }

  String _buildDriveConnectErrorMessage(Object error) {
    // spec 010: typed provider failures map by code and never render
    // `toString()`; the substring branches below serve untyped exceptions.
    if (error is CloudStorageException) {
      return switch (error.code) {
        CloudStorageErrorCode.cancelled => 'Google sign-in cancelled.',
        CloudStorageErrorCode.forbidden =>
          'Google Drive permission not granted.',
        CloudStorageErrorCode.authorizationRequired =>
          'Google account not connected. Reconnect Google Drive.',
        _ => error.safeMessage,
      };
    }
    final message = error.toString().toLowerCase();
    if (message.contains('google sign-in cancelled')) {
      return 'Google sign-in cancelled.';
    }
    if (message.contains('android google sign-in is not configured') ||
        message.contains('ios google sign-in is not configured')) {
      return error.toString();
    }
    if (message.contains('authorization was not granted')) {
      return 'Google Drive permission not granted.';
    }
    if (message.contains(
      'google account selected, but drive permission was not granted',
    )) {
      return 'Google account selected, but Drive permission not granted.';
    }
    if (message.contains('google account not connected')) {
      return 'Google account not connected. Reconnect Google Drive.';
    }
    if (message.contains('google sign-in failed')) {
      return 'Unable to connect Google Drive. ${_withoutExceptionPrefix(error)}';
    }
    return 'Unable to connect Google Drive.';
  }

  /// Unrecognized Google failures carry the platform code and description,
  /// which is the only thing that tells connect failures apart in the field.
  static String _withoutExceptionPrefix(Object error) =>
      error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

  Future<void> _refreshSyncState(Emitter<VaultState> emit) async {
    final connected = await databaseSyncRepository.isConnected();
    final mapping = await databaseSyncRepository.getMapping(state.databasePath);
    _safeEmit(
      emit,
      state.copyWith(
        isDriveConnected: connected,
        isDriveLinked: mapping != null,
        linkedRemoteFileName: mapping?.remoteFileName,
        autoSyncEnabled: mapping?.autoSyncEnabled ?? true,
        lastSyncAt: mapping?.lastSyncAt,
        lastSyncedLocalChecksum: mapping?.lastSyncedLocalChecksum,
        syncStatus: connected
            ? DatabaseSyncStatus.idle
            : DatabaseSyncStatus.disconnected,
        clearSyncError: true,
      ),
    );
  }

  /// Debounced auto-sync after a vault mutation. The timer outlives the
  /// handler that armed it, so it must NOT capture that handler's emitter
  /// (it is done by then — the old `emit.isDone` guard made auto-sync a
  /// silent no-op). It enqueues a sync event instead, which runs with a
  /// live emitter and shows the non-blocking syncing indicator.
  void _scheduleAutoSync() {
    if (!state.isDriveConnected ||
        !state.isDriveLinked ||
        !state.autoSyncEnabled) {
      return;
    }

    _autoSyncDebounce?.cancel();
    _autoSyncDebounce = Timer(const Duration(seconds: 2), () {
      if (isClosed) {
        return;
      }
      add(const SyncCurrentDatabaseNow(silentIfConflict: true));
    });
  }

  void _safeEmit(Emitter<VaultState> emit, VaultState nextState) {
    if (isClosed || emit.isDone) {
      return;
    }
    emit(nextState);
  }

  _AppleAutofillAssociationUpdate _buildAppleAutofillAssociationUpdate({
    required VaultEntry entry,
    required _AppleAutofillAssociationTarget target,
  }) {
    if (target.isWeb) {
      if (entry.url.trim().isEmpty) {
        return _AppleAutofillAssociationUpdate(
          url: target.value,
          customFields: entry.customFields,
          needsUpdate: true,
        );
      }

      if (_entryContainsAppleAutofillWebTarget(entry, target)) {
        return _AppleAutofillAssociationUpdate(
          url: entry.url,
          customFields: entry.customFields,
          needsUpdate: false,
        );
      }

      final customFields = List<VaultCustomField>.of(entry.customFields)
        ..add(
          VaultCustomField(
            key: _nextAppleAutofillCustomFieldKey(
              entry.customFields,
              target.customFieldBaseKey,
            ),
            value: target.value,
          ),
        );
      return _AppleAutofillAssociationUpdate(
        url: entry.url,
        customFields: customFields,
        needsUpdate: true,
      );
    }

    final containsAppTarget = target.isAndroidPackage
        ? _customFieldsContainAppleAutofillAndroidPackageTarget(
            entry.customFields,
            target.value,
          )
        : _customFieldsContainAppleAutofillBundleTarget(
            entry.customFields,
            target.value,
          );

    if (containsAppTarget) {
      return _AppleAutofillAssociationUpdate(
        url: entry.url,
        customFields: entry.customFields,
        needsUpdate: false,
      );
    }

    final customFields = List<VaultCustomField>.of(entry.customFields)
      ..add(
        VaultCustomField(
          key: _nextAppleAutofillCustomFieldKey(
            entry.customFields,
            target.customFieldBaseKey,
          ),
          value: target.value,
        ),
      );
    return _AppleAutofillAssociationUpdate(
      url: entry.url,
      customFields: customFields,
      needsUpdate: true,
    );
  }

  _AppleAutofillAssociationTarget? _normalizeAppleAutofillAssociationTarget({
    required String type,
    required String value,
  }) {
    final normalizedType = type.trim().toLowerCase().replaceAll(
      RegExp(r'[\s_-]+'),
      '',
    );

    if (normalizedType == 'androidpackage' ||
        normalizedType == 'packagename' ||
        normalizedType == 'androidapp') {
      final normalized = _normalizeAppleAutofillAndroidPackageComparisonValue(
        value,
      );
      if (normalized == null) {
        return null;
      }
      return _AppleAutofillAssociationTarget.androidPackage(normalized);
    }

    if (normalizedType == 'bundleid' ||
        normalizedType == 'iosbundle' ||
        normalizedType == 'iosbundleid') {
      final normalized = _normalizeAppleAutofillBundleComparisonValue(value);
      if (normalized == null) {
        return null;
      }
      return _AppleAutofillAssociationTarget.bundleId(normalized);
    }

    if (normalizedType == 'domain') {
      final target = _normalizeAppleAutofillDomainTarget(value);
      if (target == null) {
        return null;
      }
      return _AppleAutofillAssociationTarget.web(
        target,
        compareAsOrigin: false,
      );
    }

    if (normalizedType == 'url') {
      final target = _normalizeAppleAutofillUrlTarget(value);
      if (target == null) {
        return null;
      }
      return _AppleAutofillAssociationTarget.web(
        target,
        compareAsOrigin: value.trim().contains('://'),
      );
    }

    return null;
  }

  bool _entryContainsAppleAutofillWebTarget(
    VaultEntry entry,
    _AppleAutofillAssociationTarget target,
  ) {
    if (_appleAutofillWebValueMatchesTarget(entry.url, target)) {
      return true;
    }

    for (final field in entry.customFields) {
      if (!_isAppleAutofillWebFieldKey(field.key)) {
        continue;
      }
      for (final value in _splitAppleAutofillCustomFieldValues(field.value)) {
        if (_appleAutofillWebValueMatchesTarget(value, target)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _customFieldsContainAppleAutofillBundleTarget(
    List<VaultCustomField> customFields,
    String target,
  ) {
    final normalizedTarget = _normalizeAppleAutofillBundleComparisonValue(
      target,
    );
    if (normalizedTarget == null) {
      return false;
    }

    for (final field in customFields) {
      if (!_isAppleAutofillBundleFieldKey(field.key)) {
        continue;
      }
      for (final value in _splitAppleAutofillCustomFieldValues(field.value)) {
        if (_normalizeAppleAutofillBundleComparisonValue(value) ==
            normalizedTarget) {
          return true;
        }
      }
    }
    return false;
  }

  bool _customFieldsContainAppleAutofillAndroidPackageTarget(
    List<VaultCustomField> customFields,
    String target,
  ) {
    final normalizedTarget =
        _normalizeAppleAutofillAndroidPackageComparisonValue(target);
    if (normalizedTarget == null) {
      return false;
    }

    for (final field in customFields) {
      if (!_isAppleAutofillAndroidPackageFieldKey(field.key)) {
        continue;
      }
      for (final value in _splitAppleAutofillCustomFieldValues(field.value)) {
        if (_normalizeAppleAutofillAndroidPackageComparisonValue(value) ==
            normalizedTarget) {
          return true;
        }
      }
    }
    return false;
  }

  bool _appleAutofillWebValueMatchesTarget(
    String value,
    _AppleAutofillAssociationTarget target,
  ) {
    final normalized = target.compareWebAsOrigin
        ? _normalizeAppleAutofillUrlTarget(value)
        : _normalizeAppleAutofillDomainTarget(value);
    return normalized != null && normalized == target.value;
  }

  String? _normalizeAppleAutofillUrlTarget(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    if (trimmed.contains('://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null || uri.host.isEmpty) {
        return null;
      }

      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        return null;
      }

      final host = _cleanAppleAutofillHost(uri.host);
      if (host == null) {
        return null;
      }

      return Uri(
        scheme: scheme,
        host: host,
        port: uri.hasPort ? uri.port : null,
      ).toString();
    }

    return _normalizeAppleAutofillRawHost(trimmed);
  }

  String? _normalizeAppleAutofillDomainTarget(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    if (trimmed.contains('://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null || uri.host.isEmpty) {
        return null;
      }
      return _cleanAppleAutofillHost(uri.host);
    }

    return _normalizeAppleAutofillRawHost(trimmed);
  }

  String? _normalizeAppleAutofillRawHost(String rawValue) {
    var value = rawValue.trim();
    if (value.startsWith('//')) {
      value = value.substring(2);
    }

    final delimiterIndex = _firstAppleAutofillDelimiterIndex(value);
    if (delimiterIndex >= 0) {
      value = value.substring(0, delimiterIndex);
    }
    value = value.trim();
    if (value.isEmpty || value.contains('@')) {
      return null;
    }

    try {
      final uri = Uri.tryParse('https://$value');
      if (uri == null || uri.host.isEmpty) {
        return null;
      }
      return _cleanAppleAutofillHost(uri.host);
    } on FormatException {
      return null;
    }
  }

  String? _cleanAppleAutofillHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (host.isEmpty ||
        host.length > 253 ||
        host.contains(RegExp(r'[\s/@:]'))) {
      return null;
    }
    return host;
  }

  int _firstAppleAutofillDelimiterIndex(String value) {
    var result = -1;
    for (final delimiter in const ['/', '?', '#']) {
      final index = value.indexOf(delimiter);
      if (index >= 0 && (result == -1 || index < result)) {
        result = index;
      }
    }
    return result;
  }

  String _nextAppleAutofillCustomFieldKey(
    List<VaultCustomField> customFields,
    String baseKey,
  ) {
    final existingKeys = customFields
        .map((field) => _normalizeAppleAutofillFieldKey(field.key))
        .toSet();
    final normalizedBaseKey = _normalizeAppleAutofillFieldKey(baseKey);
    if (!existingKeys.contains(normalizedBaseKey)) {
      return baseKey;
    }

    var suffix = 2;
    while (existingKeys.contains(
      _normalizeAppleAutofillFieldKey('$baseKey $suffix'),
    )) {
      suffix += 1;
    }
    return '$baseKey $suffix';
  }

  bool _isAppleAutofillWebFieldKey(String key) {
    return _isAppleAutofillUrlFieldKey(key) ||
        _isAppleAutofillDomainFieldKey(key);
  }

  bool _isAppleAutofillUrlFieldKey(String key) => isUrlFieldKey(key);

  bool _isAppleAutofillDomainFieldKey(String key) {
    final normalized = _normalizeAppleAutofillFieldKey(key);
    return normalized == 'domain' ||
        normalized == 'domains' ||
        normalized == 'webdomain' ||
        normalized == 'hostname' ||
        normalized == 'host' ||
        normalized == 'kph:domain' ||
        normalized == 'kph:webdomain' ||
        RegExp(r'^kph:domain\d+$').hasMatch(normalized) ||
        RegExp(r'^kph:webdomain\d+$').hasMatch(normalized);
  }

  bool _isAppleAutofillBundleFieldKey(String key) {
    final normalized = _normalizeAppleAutofillFieldKey(key);
    return normalized == 'iosbundle' ||
        normalized == 'iosbundleid' ||
        normalized == 'bundleid' ||
        normalized == 'applebundleid' ||
        normalized == 'kph:iosbundle' ||
        normalized == 'kph:iosbundleid' ||
        normalized == 'kph:bundleid' ||
        RegExp(r'^kph:iosbundle\d+$').hasMatch(normalized) ||
        RegExp(r'^kph:iosbundleid\d+$').hasMatch(normalized) ||
        RegExp(r'^kph:bundleid\d+$').hasMatch(normalized);
  }

  bool _isAppleAutofillAndroidPackageFieldKey(String key) {
    final normalized = _normalizeAppleAutofillFieldKey(key);
    return normalized == 'androidpackage' ||
        normalized == 'androidpackageid' ||
        normalized == 'packagename' ||
        normalized == 'androidappid' ||
        normalized == 'kph:androidpackage' ||
        normalized == 'kph:androidpackageid' ||
        normalized == 'kph:packagename' ||
        normalized == 'kph:androidappid' ||
        RegExp(r'^kph:androidpackage\d+$').hasMatch(normalized) ||
        RegExp(r'^kph:androidpackageid\d+$').hasMatch(normalized) ||
        RegExp(r'^kph:packagename\d+$').hasMatch(normalized) ||
        RegExp(r'^kph:androidappid\d+$').hasMatch(normalized);
  }

  String _normalizeAppleAutofillFieldKey(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
  }

  Iterable<String> _splitAppleAutofillCustomFieldValues(String value) sync* {
    for (final token in value.split(RegExp(r'[,;\s]+'))) {
      final trimmed = token.trim();
      if (trimmed.isNotEmpty) {
        yield trimmed;
      }
    }
  }

  String? _normalizeAppleAutofillBundleComparisonValue(String value) {
    var normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.startsWith('iosbundleid:')) {
      normalized = normalized.substring('iosbundleid:'.length);
    }
    normalized = normalized.replaceAll(RegExp(r'^/+'), '');
    final delimiterIndex = _firstAppleAutofillDelimiterIndex(normalized);
    if (delimiterIndex >= 0) {
      normalized = normalized.substring(0, delimiterIndex);
    }
    normalized = normalized.replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty || normalized.length > 255) {
      return null;
    }
    if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  String? _normalizeAppleAutofillAndroidPackageComparisonValue(String value) {
    var normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.startsWith('androidapp:')) {
      normalized = normalized.substring('androidapp:'.length);
    }
    normalized = normalized.replaceAll(RegExp(r'^/+'), '');
    final delimiterIndex = _firstAppleAutofillDelimiterIndex(normalized);
    if (delimiterIndex >= 0) {
      normalized = normalized.substring(0, delimiterIndex);
    }
    normalized = normalized.replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty || normalized.length > 255) {
      return null;
    }
    if (!RegExp(r'^[a-z0-9._]+$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  Future<void> _performSync(
    Emitter<VaultState> emit, {
    SyncConflictResolution? resolution,
    bool silentIfConflict = false,
    bool emitSyncingStatus = true,
  }) async {
    if (!state.isDriveConnected || !state.isDriveLinked) {
      return;
    }

    if (emitSyncingStatus) {
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.syncing,
          clearSyncError: true,
        ),
      );
    }

    // spec-008 T507: an interrupted merge upload is triaged before any
    // ordinary sync touches the remote. The disposition is not surfaced
    // here — a stale or handed-off record simply lets `syncNow` find the
    // conflict and keep it as persistent status, never a modal.
    await _recoverPendingMergeUpload();

    try {
      final result = await syncDatabaseNow(
        state.databasePath,
        resolution: resolution,
      );

      if (result is SyncNowConflict) {
        _safeEmit(
          emit,
          state.copyWith(
            syncStatus: DatabaseSyncStatus.conflict,
            pendingSyncConflict: result.conflict,
          ),
        );

        if (!silentIfConflict) {
          _safeEmit(
            emit,
            state.copyWith(
              syncError: 'Sync conflict detected. Choose how to proceed.',
            ),
          );
        }
        return;
      }

      final mapping = await databaseSyncRepository.getMapping(
        state.databasePath,
      );

      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.success,
          linkedRemoteFileName: mapping?.remoteFileName,
          lastSyncAt: mapping?.lastSyncAt ?? DateTime.now(),
          lastSyncedLocalChecksum: mapping?.lastSyncedLocalChecksum,
          isOffline: false,
          clearSyncError: true,
          clearSyncConflict: true,
        ),
      );
    } catch (e, st) {
      if (isCloudAuthorizationRequired(e)) {
        _emitDriveAuthorizationRequired(emit);
        return;
      }
      if (e is SocketException || _isNetworkUnavailable(e)) {
        // T7 non-negotiable: offline is derived ONLY from a connection-level
        // failure (SocketException, or the provider port's typed
        // `networkUnavailable` which wraps exactly that) — never from an
        // HTTP error status, which stays in the `error` branch below. A
        // transient 500 must not be mistaken for "you are offline". Also
        // reset syncStatus away from `syncing` (set just above, before the
        // failed await) — otherwise the UI is stuck showing an
        // indeterminate spinner forever while offline instead of the
        // dedicated offline card.
        logError('Drive sync failed: no connection.', e, st);
        _safeEmit(
          emit,
          state.copyWith(syncStatus: DatabaseSyncStatus.idle, isOffline: true),
        );
        return;
      }
      logError('Drive sync failed.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          syncStatus: DatabaseSyncStatus.error,
          syncError: 'Unable to sync with Google Drive.',
          isOffline: false,
        ),
      );
    }
  }

  static bool _isNetworkUnavailable(Object error) =>
      error is CloudStorageException &&
      error.code == CloudStorageErrorCode.networkUnavailable;

  // ---------------------------------------------------------------------
  // spec-008 T505 — merge commands. Forwarded to the coordinator; no
  // download/open/diff/write/upload workflow lives here.
  // ---------------------------------------------------------------------

  Future<MergeDatabaseId?> _mergeDatabaseId() async {
    final resolve = resolveDatabaseId;
    if (resolve == null) return null;
    final id = await resolve(state.databasePath);
    return id == null ? null : MergeDatabaseId(id);
  }

  Future<void> _recoverPendingMergeUpload() async {
    final coordinator = syncMergeCoordinator;
    if (coordinator == null) return;
    try {
      final databaseId = await _mergeDatabaseId();
      if (databaseId == null) return;
      await coordinator.recoverPending(databaseId);
    } catch (e, st) {
      // ponytail: recovery failing must not block the sync that follows —
      // the record stays on disk and is retried on the next sync.
      logError('Pending merge upload recovery failed.', e, st);
    }
  }

  Future<void> _runMergeCommand(
    Emitter<VaultState> emit,
    Future<void> Function(SyncMergeCoordinator coordinator) body,
  ) async {
    final coordinator = syncMergeCoordinator;
    if (coordinator == null) {
      _safeEmit(
        emit,
        state.copyWith(
          mergeFailureCode: MergeFailureCode.mergePreconditionFailed,
        ),
      );
      return;
    }
    _safeEmit(
      emit,
      state.copyWith(
        isMergeBusy: true,
        clearMergeFailureCode: true,
        clearMergeCommitOutcome: true,
      ),
    );
    try {
      await body(coordinator);
    } on SyncMergeFailure catch (failure) {
      _safeEmit(
        emit,
        state.copyWith(
          mergeFailureCode: failure.code,
          mergeReview: coordinator.currentReview,
          clearMergeReview: coordinator.currentReview == null,
        ),
      );
    } catch (e, st) {
      logError('Merge command failed.', e, st);
      _safeEmit(
        emit,
        state.copyWith(
          mergeFailureCode: MergeFailureCode.mergePreconditionFailed,
        ),
      );
    } finally {
      _safeEmit(emit, state.copyWith(isMergeBusy: false));
    }
  }

  Future<void> _onStartSyncMergeReview(
    StartSyncMergeReview event,
    Emitter<VaultState> emit,
  ) {
    return _runMergeCommand(emit, (coordinator) async {
      final databaseId = await _mergeDatabaseId();
      if (databaseId == null) {
        throw const SyncMergeFailure(MergeFailureCode.mergePreconditionFailed);
      }
      final summary = await coordinator.startReview(databaseId);
      _safeEmit(emit, state.copyWith(mergeReview: summary));
    });
  }

  Future<void> _onUpdateSyncMergeDecision(
    UpdateSyncMergeDecision event,
    Emitter<VaultState> emit,
  ) {
    return _runMergeCommand(emit, (coordinator) async {
      final summary = await coordinator.updateDecision(
        decisionId: event.decisionId,
        choice: event.choice,
      );
      _safeEmit(emit, state.copyWith(mergeReview: summary));
    });
  }

  Future<void> _onApplySyncMergeShortcut(
    ApplySyncMergeShortcut event,
    Emitter<VaultState> emit,
  ) {
    return _runMergeCommand(emit, (coordinator) async {
      final summary = await coordinator.applyShortcut(event.shortcut);
      _safeEmit(emit, state.copyWith(mergeReview: summary));
    });
  }

  Future<void> _onCommitSyncMerge(
    CommitSyncMerge event,
    Emitter<VaultState> emit,
  ) {
    return _runMergeCommand(emit, (coordinator) async {
      final outcome = await coordinator.commit();
      _safeEmit(
        emit,
        state.copyWith(
          mergeCommitOutcome: outcome,
          mergeReview: coordinator.currentReview,
          clearMergeReview: coordinator.currentReview == null,
        ),
      );
      final localChanged = switch (outcome) {
        MergeApplied() => true,
        MergeRejected(:final localCommitCompleted) => localCommitCompleted,
        MergeNeedsReview() => false,
      };
      if (localChanged) {
        if (state.isSaving) {
          _safeEmit(emit, state.copyWith(isSyncReloadPending: true));
        } else {
          await _reload(
            emit,
            currentGroupId: state.currentGroupId,
            keepLoadingFlag: false,
          );
        }
      }
      if (outcome is MergeApplied) {
        final mapping = await databaseSyncRepository.getMapping(
          state.databasePath,
        );
        _safeEmit(
          emit,
          state.copyWith(
            syncStatus: DatabaseSyncStatus.success,
            lastSyncAt: mapping?.lastSyncAt,
            lastSyncedLocalChecksum: mapping?.lastSyncedLocalChecksum,
            clearSyncError: true,
            clearSyncConflict: true,
          ),
        );
      }
    });
  }

  Future<void> _onCancelSyncMerge(
    CancelSyncMerge event,
    Emitter<VaultState> emit,
  ) {
    return _runMergeCommand(emit, (coordinator) async {
      await coordinator.cancel();
      _safeEmit(emit, state.copyWith(clearMergeReview: true));
    });
  }

  void _onClearSyncMergeOutcome(
    ClearSyncMergeOutcome event,
    Emitter<VaultState> emit,
  ) {
    _safeEmit(
      emit,
      state.copyWith(
        clearMergeCommitOutcome: true,
        clearMergeFailureCode: true,
      ),
    );
  }

  @override
  Future<void> close() {
    _autoSyncDebounce?.cancel();
    return super.close();
  }

  /// spec-019 T010 — the records the list shows: the selected folder's
  /// subtree, then the search, then the sort, in that order.
  ///
  /// [folderIds] is the selected folder **and every descendant** (FR-006h), or
  /// null for no folder filter at all. It is passed in rather than read from
  /// `state` because two callers change `currentGroupId` in the same
  /// `copyWith` that sets this list, so `state` still holds the old folder
  /// while this runs.
  List<VaultEntry> _computeVisibleEntries({
    required List<VaultEntry> entries,
    required String searchQuery,
    required VaultEntrySort sortBy,
    required Set<String>? folderIds,
  }) {
    final normalizedQuery = _normalizeSearchText(searchQuery);
    final compactQuery = normalizedQuery.replaceAll(' ', '');

    var filtered = entries
        .where((entry) {
          if (folderIds != null && !folderIds.contains(entry.groupId)) {
            return false;
          }

          if (normalizedQuery.isNotEmpty) {
            final inTitle = _matchesSearchValue(
              entry.title,
              normalizedQuery,
              compactQuery,
            );
            final inUser = _matchesSearchValue(
              entry.username,
              normalizedQuery,
              compactQuery,
            );
            final inUrl = _matchesSearchValue(
              entry.url,
              normalizedQuery,
              compactQuery,
            );
            final inNotes = _matchesSearchValue(
              entry.notes,
              normalizedQuery,
              compactQuery,
            );
            final inCustom = entry.customFields.any(
              (field) =>
                  _matchesSearchValue(
                    field.key,
                    normalizedQuery,
                    compactQuery,
                  ) ||
                  _matchesSearchValue(
                    field.value,
                    normalizedQuery,
                    compactQuery,
                  ),
            );
            if (!(inTitle || inUser || inUrl || inNotes || inCustom)) {
              return false;
            }
          }

          return true;
        })
        .toList(growable: false);

    filtered.sort((a, b) {
      switch (sortBy) {
        case VaultEntrySort.titleAsc:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case VaultEntrySort.titleDesc:
          return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case VaultEntrySort.usernameAsc:
          return a.username.toLowerCase().compareTo(b.username.toLowerCase());
      }
    });

    return filtered;
  }

  bool _matchesSearchValue(
    String value,
    String normalizedQuery,
    String compactQuery,
  ) {
    final normalizedValue = _normalizeSearchText(value);
    if (normalizedValue.contains(normalizedQuery)) {
      return true;
    }

    if (compactQuery.isEmpty) {
      return false;
    }

    final compactValue = normalizedValue.replaceAll(' ', '');
    return compactValue.contains(compactQuery);
  }

  String _normalizeSearchText(String value) {
    final lowered = value.toLowerCase();
    final folded = _foldAccents(lowered);
    final normalized = folded
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    return normalized;
  }

  String _foldAccents(String value) {
    return value
        .replaceAll(RegExp(r'[àáâãäåāăą]'), 'a')
        .replaceAll(RegExp(r'[çćĉċč]'), 'c')
        .replaceAll(RegExp(r'[ďđ]'), 'd')
        .replaceAll(RegExp(r'[èéêëēĕėęě]'), 'e')
        .replaceAll(RegExp(r'[ĝğġģ]'), 'g')
        .replaceAll(RegExp(r'[ĥħ]'), 'h')
        .replaceAll(RegExp(r'[ìíîïĩīĭįı]'), 'i')
        .replaceAll(RegExp(r'[ĵ]'), 'j')
        .replaceAll(RegExp(r'[ķ]'), 'k')
        .replaceAll(RegExp(r'[ĺļľŀł]'), 'l')
        .replaceAll(RegExp(r'[ñńņňŉŋ]'), 'n')
        .replaceAll(RegExp(r'[òóôõöøōŏő]'), 'o')
        .replaceAll(RegExp(r'[ŕŗř]'), 'r')
        .replaceAll(RegExp(r'[śŝşš]'), 's')
        .replaceAll(RegExp(r'[ţťŧ]'), 't')
        .replaceAll(RegExp(r'[ùúûüũūŭůűų]'), 'u')
        .replaceAll(RegExp(r'[ŵ]'), 'w')
        .replaceAll(RegExp(r'[ýÿŷ]'), 'y')
        .replaceAll(RegExp(r'[źżž]'), 'z');
  }

  Set<String> _buildDuplicateKeys(List<VaultEntry> entries) {
    return entries
        .map(
          (entry) => _entryDuplicateKey(
            title: entry.title,
            username: entry.username,
            url: entry.url,
          ),
        )
        .toSet();
  }

  String _entryDuplicateKey({
    required String title,
    required String username,
    required String url,
  }) {
    String normalize(String value) {
      return value.trim().toLowerCase();
    }

    return '${normalize(title)}|${normalize(username)}|${normalize(url)}';
  }

  String _buildCsvImportMessage({
    required int importedCount,
    required int skippedTotal,
    required int duplicateCount,
  }) {
    if (skippedTotal == 0) {
      return 'Imported $importedCount records from CSV.';
    }
    if (duplicateCount == 0) {
      return 'Imported $importedCount records from CSV. Skipped $skippedTotal.';
    }
    return 'Imported $importedCount records from CSV. Skipped $skippedTotal ($duplicateCount duplicates).';
  }

  List<String> _normalizeExpandedGroupIds({
    required List<VaultGroup> groups,
    required String rootGroupId,
    required String currentGroupId,
    required List<String> previousExpanded,
  }) {
    final existingIds = groups.map((group) => group.id).toSet();
    final byId = {for (final group in groups) group.id: group};

    final expanded = <String>{
      for (final id in previousExpanded)
        if (existingIds.contains(id)) id,
      rootGroupId,
    };

    VaultGroup? cursor = byId[currentGroupId];
    while (cursor != null) {
      expanded.add(cursor.id);
      final parentId = cursor.parentId;
      cursor = parentId == null ? null : byId[parentId];
    }

    return expanded.toList()..sort();
  }
}

class _AppleAutofillAssociationTarget {
  const _AppleAutofillAssociationTarget._({
    required this.value,
    required this.customFieldBaseKey,
    required this.isWeb,
    this.isAndroidPackage = false,
    this.compareWebAsOrigin = false,
  });

  const _AppleAutofillAssociationTarget.web(
    String value, {
    required bool compareAsOrigin,
  }) : this._(
         value: value,
         customFieldBaseKey: 'KPH: URL',
         isWeb: true,
         compareWebAsOrigin: compareAsOrigin,
       );

  const _AppleAutofillAssociationTarget.bundleId(String value)
    : this._(value: value, customFieldBaseKey: 'KPH: iosBundle', isWeb: false);

  const _AppleAutofillAssociationTarget.androidPackage(String value)
    : this._(
        value: value,
        customFieldBaseKey: 'KPH: androidPackage',
        isWeb: false,
        isAndroidPackage: true,
      );

  final String value;
  final String customFieldBaseKey;
  final bool isWeb;
  final bool isAndroidPackage;
  final bool compareWebAsOrigin;
}

class _AppleAutofillAssociationUpdate {
  const _AppleAutofillAssociationUpdate({
    required this.url,
    required this.customFields,
    required this.needsUpdate,
  });

  final String url;
  final List<VaultCustomField> customFields;
  final bool needsUpdate;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    if (isEmpty) {
      return null;
    }
    return first;
  }
}
