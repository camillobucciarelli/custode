// spec-019 — a `VaultBloc` with fake edges, for the folder tests.
//
// The bloc's constructor takes eight collaborators; the folder work concerns
// exactly one of them (none). Everything here exists so a test can say "a vault
// shaped like this" and then assert about `visibleEntries`, without a `.kdbx`
// file, a Drive account or a keychain.
//
// The fakes answer only what the paths under test call and `noSuchMethod` the
// rest, so an unrelated method arriving here fails loudly as an unimplemented
// call instead of quietly returning a plausible empty value.
import 'package:password_manager/features/password_manager/data/services/vault_csv_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_duplicate_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry_revision.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_group.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/services/vault_health_service.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/entry_history_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/passkey_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/pending_passkey_adoption_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_database_now_usecase.dart';
import 'package:shared_preferences/shared_preferences.dart';

const testDatabasePath = '/vault.kdbx';

VaultEntry testEntry({
  required String id,
  required String groupId,
  String? title,
  String? username,
  String url = '',
  String notes = '',
}) => VaultEntry(
  id: id,
  groupId: groupId,
  title: title ?? 'Entry $id',
  username: username ?? 'user-$id',
  password: 'p-$id',
  url: url,
  notes: notes,
);

VaultBloc buildTestVaultBloc({
  required VaultSnapshot snapshot,
  List<VaultEntry> recycleBinEntries = const [],
  VaultDuplicateService? duplicateService,
  VaultHealthService? healthService,
  AppleAutofillV2CoordinatorContract? autofill,
  FakeVaultKdbxService? kdbx,
  SharedPreferences? folderExpansionPreferences,
  String databasePath = testDatabasePath,
  EntryHistoryCoordinator? entryHistoryCoordinator,
  PasskeyCoordinator? passkeyCoordinator,
  PendingPasskeyAdoptionCoordinator? pendingPasskeyAdoptionCoordinator,
  SessionSecretHolder? sessionSecretHolder,
}) {
  final syncRepository = FakeSyncRepository();
  return VaultBloc(
    databasePath: databasePath,
    getSelectedKeyFilePath: () async => null,
    sessionSecretHolder:
        sessionSecretHolder ?? (SessionSecretHolder()..set('secret')),
    vaultKdbxService:
        kdbx ??
        FakeVaultKdbxService(
          snapshot: snapshot,
          recycleBinEntries: recycleBinEntries,
        ),
    vaultCsvImportService: VaultCsvImportService(),
    vaultDuplicateService: duplicateService ?? VaultDuplicateService(),
    databaseSyncRepository: syncRepository,
    linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
    syncDatabaseNow: SyncDatabaseNowUseCase(syncRepository),
    appleAutofillV2Coordinator:
        autofill ?? const NoopAppleAutofillV2Coordinator(),
    vaultHealthService: healthService ?? const VaultHealthService(),
    folderExpansionPreferences: folderExpansionPreferences,
    entryHistoryCoordinator: entryHistoryCoordinator,
    passkeyCoordinator: passkeyCoordinator,
    pendingPasskeyAdoptionCoordinator: pendingPasskeyAdoptionCoordinator,
  );
}

class FakeVaultKdbxService implements VaultKdbxService {
  FakeVaultKdbxService({
    required this.snapshot,
    this.recycleBinEntries = const [],
  });

  VaultSnapshot snapshot;
  List<VaultEntry> recycleBinEntries;
  final List<String> createdInGroupIds = <String>[];

  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async {
    // The real service echoes back the group it was asked to open, and the
    // bloc reads the selection out of the snapshot, so a fake that ignored
    // this would silently reset the folder on every reload.
    final wanted = currentGroupId ?? snapshot.currentGroupId;
    return VaultSnapshot(
      rootGroupId: snapshot.rootGroupId,
      currentGroupId: wanted,
      groups: snapshot.groups,
      entries: snapshot.entries,
      allEntries: snapshot.allEntries,
    );
  }

  @override
  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async => recycleBinEntries;

  @override
  Future<String> createEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
    required String title,
    required String username,
    required String entryPassword,
    required String url,
    required String notes,
    List<VaultCustomField> customFields = const [],
  }) async {
    createdInGroupIds.add(groupId);
    final created = VaultEntry(
      id: 'created-${createdInGroupIds.length}',
      groupId: groupId,
      title: title,
      username: username,
      password: entryPassword,
      url: url,
      notes: notes,
    );
    final all = [...snapshot.allEntries, created];
    snapshot = VaultSnapshot(
      rootGroupId: snapshot.rootGroupId,
      currentGroupId: snapshot.currentGroupId,
      groups: snapshot.groups,
      entries: all,
      allEntries: all,
    );
    return created.id;
  }

  /// spec-019 C-04-05: records the duplicate the bloc asked for, and grows the
  /// vault by one so the reload after it has something to show.
  final List<({String entryId, String titleSuffix})> duplicated =
      <({String entryId, String titleSuffix})>[];

  @override
  Future<String> duplicateEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String titleSuffix,
  }) async {
    // Recorded only once the record is found, so the list means "duplicates
    // the service actually made", like the real one.
    final source = snapshot.allEntries.firstWhere(
      (entry) => entry.id == entryId,
    );
    duplicated.add((entryId: entryId, titleSuffix: titleSuffix));
    final copy = VaultEntry(
      id: '$entryId-copy',
      groupId: source.groupId,
      title: '${source.title}$titleSuffix',
      username: source.username,
      password: source.password,
      url: source.url,
      notes: source.notes,
      customFields: source.customFields,
    );
    final all = [...snapshot.allEntries, copy];
    snapshot = VaultSnapshot(
      rootGroupId: snapshot.rootGroupId,
      currentGroupId: snapshot.currentGroupId,
      groups: snapshot.groups,
      entries: all,
      allEntries: all,
    );
    return copy.id;
  }

  /// spec 017 T201: what `loadEntryHistory` answers. The default is the
  /// answer the real service gives for a record that was never edited — an
  /// empty list, not an error.
  VaultEntryHistory entryHistory = const VaultEntryHistory(
    revisions: [],
    retention: VaultHistoryRetention(),
  );

  /// Set to make the read fail, the way an unreadable file would.
  Object? entryHistoryError;

  /// Every entry whose history was asked for, in order — so a test can show
  /// the read happened on demand and only then.
  final List<String> historyReads = <String>[];

  @override
  Future<VaultEntryHistory> loadEntryHistory({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
  }) async {
    historyReads.add(entryId);
    final failure = entryHistoryError;
    if (failure != null) {
      throw failure;
    }
    return entryHistory;
  }

  /// spec 017 T403: recorded deletions, and a way to make one fail.
  final List<(String, DateTime)> deletedRevisions = [];
  Object? deleteRevisionError;

  @override
  Future<void> deleteEntryRevision({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required DateTime replacedAt,
    int ordinal = 0,
  }) async {
    final failure = deleteRevisionError;
    if (failure != null) {
      throw failure;
    }
    deletedRevisions.add((entryId, replacedAt));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSyncRepository implements DatabaseSyncRepository {
  @override
  Future<DatabaseSyncMapping?> getMapping(String databasePath) async => null;

  @override
  Future<bool> isConnected() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecordingAutofillCoordinator
    implements AppleAutofillV2CoordinatorContract {
  final List<List<VaultEntry>> published = [];

  @override
  Future<void> publishVault({
    required String databasePath,
    required List<VaultEntry> entries,
  }) async => published.add(List<VaultEntry>.of(entries));

  @override
  Future<void> clearCredentials({String? databasePath}) async {}

  @override
  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  }) async => const [];

  @override
  Future<void> clearPendingAssociations({List<String>? ids}) async {}
}

/// A vault with a root, two top-level folders and one nested folder:
///
///     Vault (root)      e-root
///     ├── Work          e-work
///     │   └── Clients   e-client
///     └── Personal      e-personal
VaultSnapshot nestedSnapshot({String currentGroupId = 'root'}) {
  final entries = <VaultEntry>[
    testEntry(id: 'e-root', groupId: 'root', title: 'Aurora', username: 'ada'),
    testEntry(
      id: 'e-work',
      groupId: 'work',
      title: 'Borealis',
      username: 'ben',
    ),
    testEntry(
      id: 'e-client',
      groupId: 'clients',
      title: 'Cirrus',
      username: 'cy',
    ),
    testEntry(
      id: 'e-personal',
      groupId: 'personal',
      title: 'Delta',
      username: 'dee',
    ),
  ];
  return VaultSnapshot(
    rootGroupId: 'root',
    currentGroupId: currentGroupId,
    groups: const [
      VaultGroup(id: 'root', name: 'Vault', parentId: null),
      VaultGroup(id: 'work', name: 'Work', parentId: 'root'),
      VaultGroup(id: 'clients', name: 'Clients', parentId: 'work'),
      VaultGroup(id: 'personal', name: 'Personal', parentId: 'root'),
      VaultGroup(
        id: 'bin',
        name: 'Recycle Bin',
        parentId: 'root',
        isRecycleBin: true,
      ),
    ],
    entries: entries,
    allEntries: entries,
  );
}

/// Passkeys-all-platforms T014: scripted adoption coordinator. Every result is
/// whatever the test set; calls are recorded so a test can assert the decision
/// the bloc handed over. Carries no key material.
class FakePendingPasskeyAdoptionCoordinator
    implements PendingPasskeyAdoptionCoordinator {
  FakePendingPasskeyAdoptionCoordinator({
    this.waiting = 0,
    this.adoptResult = const PendingPasskeyAdoptionResult(),
    this.actionResult = const PendingPasskeyAdoptionResult(),
  });

  int waiting;
  PendingPasskeyAdoptionResult adoptResult;
  PendingPasskeyAdoptionResult actionResult;
  Object? discardError;
  bool discardResult = true;

  int adoptCalls = 0;
  final List<(String, PasskeyClashDecision, String?)> clashDecisions = [];
  final List<String> moved = [];
  final List<String> discarded = [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<int> waitingCount() async => waiting;

  @override
  Future<PendingPasskeyAdoptionResult> adoptPending({
    required String databasePath,
    String? keyFilePath,
  }) async {
    adoptCalls++;
    return adoptResult;
  }

  @override
  Future<PendingPasskeyAdoptionResult> applyClashDecision({
    required String databasePath,
    String? keyFilePath,
    required String recordId,
    required PasskeyClashDecision decision,
    String? replaceEntryId,
  }) async {
    clashDecisions.add((recordId, decision, replaceEntryId));
    return actionResult;
  }

  @override
  Future<PendingPasskeyAdoptionResult> moveToOpenVault({
    required String databasePath,
    String? keyFilePath,
    required String recordId,
  }) async {
    moved.add(recordId);
    return actionResult;
  }

  @override
  Future<bool> discard(String recordId) async {
    discarded.add(recordId);
    final error = discardError;
    if (error != null) throw error;
    return discardResult;
  }
}
