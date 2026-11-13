// spec-008 Gate 6 fixtures — one fake port and one pumpable merge screen,
// shared by the goldens, the semantics matrix and the dynamic assertions.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/data/services/vault_csv_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_duplicate_service.dart';
import 'package:password_manager/features/password_manager/domain/models/merge_field_display.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_merge_models.dart';
import 'package:password_manager/features/password_manager/domain/repositories/sync_merge_repository.dart';
import 'package:password_manager/features/password_manager/domain/usecases/load_sync_merge_field_display_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_merge_usecases.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/sync_merge_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/sync_merge_screen.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_database_now_usecase.dart';

import '../../bloc/vault/vault_bloc_harness.dart';

const mergeFixtureDatabasePath = '/vault/Personal.kdbx';
final mergeFixtureDatabaseId = MergeDatabaseId('db-merge-golden');

// Plaintext the fake port serves. The dynamic assertions look for these.
const fixtureNotesLocal = 'Call the bank before Friday\nPIN reminder: dog';
const fixtureNotesRemote =
    'Call the bank before Friday\nNew card arrives Monday';
const fixturePasswordLocal = 'correct-horse-battery-staple';
const fixturePasswordRemote = 'Tr0ub4dor&3';

MergeSessionId fixtureSessionId(int n) =>
    MergeSessionId('ms-${n.toRadixString(16).padLeft(32, '0')}');
MergeDecisionId fixtureDecisionId(int n) =>
    MergeDecisionId('md-${n.toRadixString(16).padLeft(32, '0')}');

/// The mixed review: two field conflicts (a credential block and Notes with
/// tied timestamps), a one-sided attachment with deletion evidence, and a
/// record deleted on one side. One-sided counts are non-zero so "preserved"
/// has something to say.
List<RedactedMergeDecision> mixedDecisions() => [
  RedactedMergeDecision(
    decisionId: fixtureDecisionId(1),
    ordinal: 0,
    kind: MergeDecisionKind.fieldConflict,
    category: MergeFieldCategory.password,
    presence: MergePresence.presentBoth,
    choice: MergeChoice.local,
    isDefault: true,
    timestampRelation: TimestampRelation.localNewer,
  ),
  RedactedMergeDecision(
    decisionId: fixtureDecisionId(2),
    ordinal: 1,
    kind: MergeDecisionKind.fieldConflict,
    category: MergeFieldCategory.notes,
    presence: MergePresence.presentBoth,
    choice: MergeChoice.local,
    isDefault: true,
    timestampRelation: TimestampRelation.tie,
  ),
  RedactedMergeDecision(
    decisionId: fixtureDecisionId(3),
    ordinal: 2,
    kind: MergeDecisionKind.fieldDeletionConflict,
    category: MergeFieldCategory.attachment,
    presence: MergePresence.localOnly,
    choice: MergeChoice.keep,
    isDefault: true,
    timestampRelation: TimestampRelation.remoteNewer,
  ),
  RedactedMergeDecision(
    decisionId: fixtureDecisionId(4),
    ordinal: 3,
    kind: MergeDecisionKind.recordDeletionConflict,
    category: MergeFieldCategory.other,
    presence: MergePresence.remoteOnly,
    choice: MergeChoice.keep,
    isDefault: true,
    timestampRelation: TimestampRelation.localNewer,
  ),
];

/// T605: 250 conflicts, generated in memory.
List<RedactedMergeDecision> scaleDecisions() => [
  for (var i = 0; i < 250; i++)
    RedactedMergeDecision(
      decisionId: fixtureDecisionId(100 + i),
      ordinal: i,
      kind: MergeDecisionKind.fieldConflict,
      category: MergeFieldCategory.customField,
      presence: MergePresence.presentBoth,
      choice: MergeChoice.local,
      isDefault: true,
      timestampRelation: TimestampRelation.localNewer,
    ),
];

class FixtureMergePort implements SyncMergeRepository {
  FixtureMergePort({List<RedactedMergeDecision>? decisions})
    : _decisions = decisions ?? mixedDecisions();

  List<RedactedMergeDecision> _decisions;
  final List<String> calls = [];
  final List<MergeFieldDisplay> served = [];
  MergeCommitOutcome commitOutcome = const MergeApplied(
    entryCount: 42,
    backupCreated: true,
    uploadState: MergeUploadState.uploaded,
  );
  Completer<void>? commitGate;
  Completer<void>? updateGate;
  int _sessions = 0;

  MergeReviewSummary summary() => MergeReviewSummary(
    sessionId: fixtureSessionId(_sessions),
    databaseId: mergeFixtureDatabaseId,
    phase: _decisions.every((d) => !d.isDefault)
        ? MergeReviewPhase.ready
        : MergeReviewPhase.reviewing,
    decisions: _decisions,
    localOnlyRecordCount: 2,
    remoteOnlyRecordCount: 1,
    oneSidedFieldCount: 3,
  );

  @override
  Future<MergeReviewSummary> startReview(MergeDatabaseId databaseId) async {
    calls.add('startReview');
    _sessions++;
    return summary();
  }

  @override
  Future<MergeReviewSummary> updateDecision({
    required MergeSessionId sessionId,
    required MergeDecisionId decisionId,
    required MergeChoice choice,
  }) async {
    calls.add('updateDecision');
    await updateGate?.future;
    _decisions = [
      for (final d in _decisions)
        d.decisionId == decisionId ? d.withChoice(choice) : d,
    ];
    return summary();
  }

  @override
  Future<MergeCommitOutcome> commit(MergeSessionId sessionId) async {
    calls.add('commit');
    await commitGate?.future;
    return commitOutcome;
  }

  @override
  Future<void> cancel(MergeSessionId sessionId) async => calls.add('cancel');

  @override
  Future<void> invalidate(MergeDatabaseId databaseId) async =>
      calls.add('invalidate');

  @override
  Future<MergeRecoveryOutcome> recoverPending(
    MergeDatabaseId databaseId,
  ) async => const MergeRecoveryOutcome(MergeRecoveryDisposition.none);

  @override
  Future<MergeFieldDisplay> loadFieldDisplay({
    required MergeSessionId sessionId,
    required MergeDecisionId decisionId,
  }) async {
    calls.add('loadFieldDisplay');
    final decision = _decisions.firstWhere((d) => d.decisionId == decisionId);
    final display = switch (decision.category) {
      MergeFieldCategory.password => MergeFieldDisplay(
        label: 'Password',
        local: MergeDisplaySide.present(
          fixturePasswordLocal,
          changedAt: DateTime.utc(2026, 8, 30),
        ),
        remote: MergeDisplaySide.present(
          fixturePasswordRemote,
          changedAt: DateTime.utc(2026, 8, 12),
        ),
        protected: true,
      ),
      MergeFieldCategory.attachment => MergeFieldDisplay(
        label: 'invoice.pdf',
        local: MergeDisplaySide.present(
          '',
          sizeBytes: 18432,
          changedAt: DateTime.utc(2026, 8, 20),
        ),
        remote: MergeDisplaySide.missing(),
        protected: false,
      ),
      _ => MergeFieldDisplay(
        label: 'Notes',
        local: MergeDisplaySide.present(
          fixtureNotesLocal,
          changedAt: DateTime.utc(2026, 8, 30, 10),
        ),
        remote: MergeDisplaySide.present(
          fixtureNotesRemote,
          changedAt: DateTime.utc(2026, 8, 30, 10),
        ),
        protected: false,
      ),
    };
    served.add(display);
    return display;
  }
}

class MergeScreenHarness {
  MergeScreenHarness({List<RedactedMergeDecision>? decisions})
    : port = FixtureMergePort(decisions: decisions) {
    final syncRepository = FakeSyncRepository();
    bloc = VaultBloc(
      databasePath: mergeFixtureDatabasePath,
      getSelectedKeyFilePath: () async => null,
      sessionSecretHolder: SessionSecretHolder()..set('secret'),
      vaultKdbxService: FakeVaultKdbxService(snapshot: nestedSnapshot()),
      vaultCsvImportService: VaultCsvImportService(),
      vaultDuplicateService: VaultDuplicateService(),
      databaseSyncRepository: syncRepository,
      linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
      syncDatabaseNow: SyncDatabaseNowUseCase(syncRepository),
      syncMergeCoordinator: SyncMergeCoordinator(
        startReview: StartSyncMergeReviewUseCase(port),
        updateDecision: UpdateSyncMergeDecisionUseCase(port),
        commit: CommitSyncMergeUseCase(port),
        cancel: CancelSyncMergeUseCase(port),
        invalidate: InvalidateSyncMergeUseCase(port),
        recoverPending: RecoverPendingSyncMergeUploadUseCase(port),
      ),
      resolveDatabaseId: (_) async => mergeFixtureDatabaseId.value,
    );
  }

  final FixtureMergePort port;
  late final VaultBloc bloc;
  int closeCalls = 0;

  Widget app({ThemeMode themeMode = ThemeMode.light}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    themeMode: themeMode,
    home: BlocProvider<VaultBloc>.value(
      value: bloc,
      child: SyncMergeScreen(
        loadFieldDisplay: LoadSyncMergeFieldDisplayUseCase(port),
        onClose: () => closeCalls++,
      ),
    ),
  );

  Future<void> startReview(WidgetTester tester) async {
    bloc.add(const StartSyncMergeReview());
    await tester.pumpAndSettle();
  }

  Future<void> dispose() => bloc.close();
}

Future<void> setMergeTestSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
