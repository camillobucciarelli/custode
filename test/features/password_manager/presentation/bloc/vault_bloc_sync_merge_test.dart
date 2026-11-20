// spec-008 T505 / T507 — the BLoC forwards merge commands and runs pending
// upload recovery before any ordinary sync.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/vault_csv_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_duplicate_service.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_status.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/merge_field_display.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_conflict.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_merge_models.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/sync_merge_repository.dart';
import 'package:password_manager/features/password_manager/domain/services/sync_merge_policy.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_merge_usecases.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/sync_merge_coordinator.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_database_now_usecase.dart';

import 'vault/vault_bloc_harness.dart';

const _dbPath = '/vault/db.kdbx';
final _databaseId = MergeDatabaseId('db-merge-bloc');

void main() {
  late _FakePort port;
  late _FakeSyncRepo sync;
  late VaultBloc bloc;

  setUp(() {
    port = _FakePort();
    sync = _FakeSyncRepo(port);
    port.sharedLog = sync.log;
    bloc = VaultBloc(
      databasePath: _dbPath,
      getSelectedKeyFilePath: () async => null,
      sessionSecretHolder: SessionSecretHolder()..set('secret'),
      vaultKdbxService: FakeVaultKdbxService(snapshot: nestedSnapshot()),
      vaultCsvImportService: VaultCsvImportService(),
      vaultDuplicateService: VaultDuplicateService(),
      databaseSyncRepository: sync,
      linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(sync),
      syncDatabaseNow: SyncDatabaseNowUseCase(sync),
      syncMergeCoordinator: SyncMergeCoordinator(
        startReview: StartSyncMergeReviewUseCase(port),
        updateDecision: UpdateSyncMergeDecisionUseCase(port),
        commit: CommitSyncMergeUseCase(port),
        cancel: CancelSyncMergeUseCase(port),
        invalidate: InvalidateSyncMergeUseCase(port),
        recoverPending: RecoverPendingSyncMergeUploadUseCase(port),
      ),
      resolveDatabaseId: (path) async =>
          path == _dbPath ? _databaseId.value : null,
    );
  });

  tearDown(() => bloc.close());

  group('T505 forwarding', () {
    test('StartSyncMergeReview puts the redacted summary in state', () async {
      bloc.add(const StartSyncMergeReview());
      await _settle(bloc);

      expect(bloc.state.mergeReview, isNotNull);
      expect(bloc.state.mergeReview!.decisions, hasLength(2));
      expect(bloc.state.isMergeBusy, isFalse);
      expect(bloc.state.mergeFailureCode, isNull);
      expect(port.calls, ['startReview']);
    });

    test('UpdateSyncMergeDecision and ApplySyncMergeShortcut refresh the '
        'summary through the coordinator', () async {
      bloc.add(const StartSyncMergeReview());
      await _settle(bloc);
      final first = bloc.state.mergeReview!.decisions.first;

      bloc.add(
        UpdateSyncMergeDecision(
          decisionId: first.decisionId,
          choice: MergeChoice.remote,
        ),
      );
      await _settle(bloc);
      expect(
        bloc.state.mergeReview!.decisions.first.choice,
        MergeChoice.remote,
      );

      bloc.add(const ApplySyncMergeShortcut(MergeShortcut.preferLocal));
      await _settle(bloc);
      expect(
        bloc.state.mergeReview!.decisions.map((d) => d.choice),
        everyElement(MergeChoice.local),
      );
    });

    test('CommitSyncMerge applied: outcome in state, review cleared, sync '
        'status success and conflict cleared', () async {
      bloc.add(const StartSyncMergeReview());
      await _settle(bloc);
      port.commitOutcome = const MergeApplied(
        entryCount: 4,
        backupCreated: true,
        uploadState: MergeUploadState.uploaded,
      );

      bloc.add(const CommitSyncMerge());
      await _settle(bloc);

      expect(bloc.state.mergeCommitOutcome, isA<MergeApplied>());
      expect(bloc.state.mergeReview, isNull);
      expect(bloc.state.syncStatus, DatabaseSyncStatus.success);
      expect(bloc.state.pendingSyncConflict, isNull);
      expect(port.calls, ['startReview', 'commit']);
    });

    test('CommitSyncMerge needs-review keeps the new summary', () async {
      bloc.add(const StartSyncMergeReview());
      await _settle(bloc);
      port.commitOutcome = MergeNeedsReview(
        summary: port.summary(phase: MergeReviewPhase.needsReview),
        newConflictCount: 1,
        reviewReentryCount: 1,
      );

      bloc.add(const CommitSyncMerge());
      await _settle(bloc);

      expect(bloc.state.mergeCommitOutcome, isA<MergeNeedsReview>());
      expect(bloc.state.mergeReview?.phase, MergeReviewPhase.needsReview);
    });

    test('a port failure lands as a safe code, never an exception', () async {
      port.startError = const SyncMergeFailure(
        MergeFailureCode.credentialsRevoked,
      );
      bloc.add(const StartSyncMergeReview());
      await _settle(bloc);

      expect(bloc.state.mergeFailureCode, MergeFailureCode.credentialsRevoked);
      expect(bloc.state.mergeReview, isNull);
      expect(bloc.state.isMergeBusy, isFalse);
    });

    test('CancelSyncMerge clears the review; ClearSyncMergeOutcome clears '
        'outcome and code', () async {
      bloc.add(const StartSyncMergeReview());
      await _settle(bloc);
      bloc.add(const CancelSyncMerge());
      await _settle(bloc);
      expect(bloc.state.mergeReview, isNull);
      expect(port.calls, ['startReview', 'cancel']);

      port.startError = const SyncMergeFailure(MergeFailureCode.staleLocal);
      bloc.add(const StartSyncMergeReview());
      await _settle(bloc);
      expect(bloc.state.mergeFailureCode, isNotNull);
      bloc.add(const ClearSyncMergeOutcome());
      await _settle(bloc);
      expect(bloc.state.mergeFailureCode, isNull);
      expect(bloc.state.mergeCommitOutcome, isNull);
    });

    test('without a coordinator every merge event reports a precondition '
        'failure and nothing else happens', () async {
      final bare = VaultBloc(
        databasePath: _dbPath,
        getSelectedKeyFilePath: () async => null,
        sessionSecretHolder: SessionSecretHolder()..set('secret'),
        vaultKdbxService: FakeVaultKdbxService(snapshot: nestedSnapshot()),
        vaultCsvImportService: VaultCsvImportService(),
        vaultDuplicateService: VaultDuplicateService(),
        databaseSyncRepository: sync,
        linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(sync),
        syncDatabaseNow: SyncDatabaseNowUseCase(sync),
      );
      addTearDown(bare.close);

      bare.add(const StartSyncMergeReview());
      await _settle(bare);

      expect(
        bare.state.mergeFailureCode,
        MergeFailureCode.mergePreconditionFailed,
      );
      expect(port.calls, isEmpty);
    });
  });

  group('T507 auto-sync interaction', () {
    setUp(() {
      sync.connected = true;
      sync.mapping = DatabaseSyncMapping(
        databasePath: _dbPath,
        providerId: 'google_drive',
        remoteFileId: 'drive-1',
        remoteFileName: 'db.kdbx',
      );
      // The bloc only syncs once it believes Drive is connected and linked.
      bloc.add(const BackgroundDriveSync());
    });

    test('pending upload recovery runs BEFORE syncNow, on manual and '
        'background sync alike', () async {
      await _settle(bloc);
      port.calls.clear();
      sync.log.clear();

      bloc.add(const SyncCurrentDatabaseNow());
      await _settle(bloc);
      expect(sync.log, ['recoverPending', 'syncNow']);

      sync.log.clear();
      bloc.add(const BackgroundDriveSync());
      await _settle(bloc);
      expect(sync.log, ['recoverPending', 'syncNow']);
    });

    test('a recovery failure does not block the sync that follows', () async {
      await _settle(bloc);
      port.recoverError = StateError('metadata offline');
      sync.log.clear();

      bloc.add(const SyncCurrentDatabaseNow());
      await _settle(bloc);

      expect(sync.log, ['recoverPending', 'syncNow']);
      expect(bloc.state.syncStatus, DatabaseSyncStatus.success);
    });

    test('a background conflict stays a persistent status with no message '
        'to act on — never a modal while editing', () async {
      await _settle(bloc);
      sync.syncResult = SyncNowConflict(
        SyncConflict(
          databasePath: _dbPath,
          remoteFileId: 'drive-1',
          remoteFileName: 'db.kdbx',
          localChecksum: 'aaa',
          remoteChecksum: 'bbb',
        ),
      );

      bloc.add(const BackgroundDriveSync());
      await _settle(bloc);

      expect(bloc.state.syncStatus, DatabaseSyncStatus.conflict);
      expect(bloc.state.pendingSyncConflict, isNotNull);
      expect(bloc.state.syncError, isNull);
      expect(bloc.state.mergeReview, isNull);
    });
  });
}

Future<void> _settle(VaultBloc bloc) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

MergeSessionId _sessionId(int n) =>
    MergeSessionId('ms-${n.toRadixString(16).padLeft(32, '0')}');
MergeDecisionId _decisionId(int n) =>
    MergeDecisionId('md-${n.toRadixString(16).padLeft(32, '0')}');

class _FakePort implements SyncMergeRepository {
  final List<String> calls = [];
  MergeCommitOutcome commitOutcome = const MergeRejected(
    MergeFailureCode.unresolvedConflict,
    localCommitCompleted: false,
  );
  Object? startError;
  Object? recoverError;
  List<String>? sharedLog;
  MergeReviewSummary? _current;
  int _sessions = 0;

  MergeReviewSummary summary({required MergeReviewPhase phase}) =>
      MergeReviewSummary(
        sessionId: _sessionId(++_sessions),
        databaseId: _databaseId,
        phase: phase,
        decisions: [
          for (var i = 0; i < 2; i++)
            RedactedMergeDecision(
              decisionId: _decisionId(i + 1),
              ordinal: i,
              kind: MergeDecisionKind.fieldConflict,
              category: MergeFieldCategory.username,
              presence: MergePresence.presentBoth,
              choice: MergeChoice.local,
              isDefault: true,
              timestampRelation: TimestampRelation.tie,
            ),
        ],
        localOnlyRecordCount: 0,
        remoteOnlyRecordCount: 0,
        oneSidedFieldCount: 0,
      );

  @override
  Future<MergeReviewSummary> startReview(MergeDatabaseId databaseId) async {
    calls.add('startReview');
    final error = startError;
    if (error != null) throw error;
    return _current = summary(phase: MergeReviewPhase.reviewing);
  }

  @override
  Future<MergeReviewSummary> updateDecision({
    required MergeSessionId sessionId,
    required MergeDecisionId decisionId,
    required MergeChoice choice,
  }) async {
    calls.add('updateDecision');
    final current = _current!;
    return _current = MergeReviewSummary(
      sessionId: current.sessionId,
      databaseId: current.databaseId,
      phase: current.phase,
      decisions: [
        for (final d in current.decisions)
          d.decisionId == decisionId ? d.withChoice(choice) : d,
      ],
      localOnlyRecordCount: 0,
      remoteOnlyRecordCount: 0,
      oneSidedFieldCount: 0,
    );
  }

  @override
  Future<MergeCommitOutcome> commit(MergeSessionId sessionId) async {
    calls.add('commit');
    return commitOutcome;
  }

  @override
  Future<void> cancel(MergeSessionId sessionId) async {
    calls.add('cancel');
    _current = null;
  }

  @override
  Future<void> invalidate(MergeDatabaseId databaseId) async {
    calls.add('invalidate');
  }

  @override
  Future<MergeRecoveryOutcome> recoverPending(
    MergeDatabaseId databaseId,
  ) async {
    calls.add('recoverPending');
    sharedLog?.add('recoverPending');
    final error = recoverError;
    if (error != null) throw error;
    return const MergeRecoveryOutcome(MergeRecoveryDisposition.none);
  }

  @override
  Future<MergeFieldDisplay> loadFieldDisplay({
    required MergeSessionId sessionId,
    required MergeDecisionId decisionId,
  }) => throw UnimplementedError('the BLoC must never ask for this');
}

/// Records the ORDER of recovery vs sync: the port's `recoverPending` and this
/// repository's `syncNow` write into the same log.
class _FakeSyncRepo implements DatabaseSyncRepository {
  _FakeSyncRepo(this.port) {
    port.calls; // keep the reference obvious
  }

  final _FakePort port;
  final List<String> log = [];
  bool connected = false;
  DatabaseSyncMapping? mapping;
  SyncNowResult syncResult = const SyncNowSuccess();

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<DatabaseSyncMapping?> getMapping(String path) async => mapping;

  @override
  Future<SyncNowResult> syncNow(
    String path, {
    SyncConflictResolution? resolution,
  }) async {
    log.add('syncNow');
    return syncResult;
  }

  @override
  Future<StorageAccountSummary> getConnectedAccount() async =>
      const StorageAccountSummary(displayLabel: 'Google Drive account');

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) async => [];

  @override
  Future<Uint8List> downloadRemoteFile(
    String id, {
    required String providerId,
  }) async => Uint8List(0);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
