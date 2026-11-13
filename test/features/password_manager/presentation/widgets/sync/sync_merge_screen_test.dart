// spec-008 T607 (12-row layout/semantics matrix) and T608 (four named
// dynamic widget assertions).
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_status.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_conflict.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_merge_models.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/services/sync_merge_policy.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';

import '../../coordinators/fake_database_ports.dart';
import '../../screens/vault/vault_shell_test_utils.dart';
import 'sync_merge_screen_fixtures.dart';

enum _Screen { review, field, ready }

typedef _Row = ({String name, _Screen screen, Size size, ThemeMode theme});

const _phone = Size(390, 844);
const _tablet = Size(1024, 768);

const matrix = <_Row>[
  (
    name: 'review phone light has no overflow and exposes merge review roles',
    screen: _Screen.review,
    size: _phone,
    theme: ThemeMode.light,
  ),
  (
    name: 'review phone dark has no overflow and exposes merge review roles',
    screen: _Screen.review,
    size: _phone,
    theme: ThemeMode.dark,
  ),
  (
    name: 'review tablet light has no overflow and exposes merge review roles',
    screen: _Screen.review,
    size: _tablet,
    theme: ThemeMode.light,
  ),
  (
    name: 'review tablet dark has no overflow and exposes merge review roles',
    screen: _Screen.review,
    size: _tablet,
    theme: ThemeMode.dark,
  ),
  (
    name: 'field phone light has no overflow and exposes field decision roles',
    screen: _Screen.field,
    size: _phone,
    theme: ThemeMode.light,
  ),
  (
    name: 'field phone dark has no overflow and exposes field decision roles',
    screen: _Screen.field,
    size: _phone,
    theme: ThemeMode.dark,
  ),
  (
    name: 'field tablet light has no overflow and exposes field decision roles',
    screen: _Screen.field,
    size: _tablet,
    theme: ThemeMode.light,
  ),
  (
    name: 'field tablet dark has no overflow and exposes field decision roles',
    screen: _Screen.field,
    size: _tablet,
    theme: ThemeMode.dark,
  ),
  (
    name: 'ready phone light has no overflow and exposes merge commit roles',
    screen: _Screen.ready,
    size: _phone,
    theme: ThemeMode.light,
  ),
  (
    name: 'ready phone dark has no overflow and exposes merge commit roles',
    screen: _Screen.ready,
    size: _phone,
    theme: ThemeMode.dark,
  ),
  (
    name: 'ready tablet light has no overflow and exposes merge commit roles',
    screen: _Screen.ready,
    size: _tablet,
    theme: ThemeMode.light,
  ),
  (
    name: 'ready tablet dark has no overflow and exposes merge commit roles',
    screen: _Screen.ready,
    size: _tablet,
    theme: ThemeMode.dark,
  ),
];

void main() {
  group('T607 layout/semantics matrix', () {
    test('the matrix has exactly 12 unique rows', () {
      expect(matrix.length, 12);
      expect(matrix.map((r) => r.name).toSet().length, 12);
    });

    for (final row in matrix) {
      testWidgets(row.name, (tester) async {
        final semantics = tester.ensureSemantics();
        await setMergeTestSize(tester, row.size);
        final harness = MergeScreenHarness();
        addTearDown(harness.dispose);
        await tester.pumpWidget(harness.app(themeMode: row.theme));
        await harness.startReview(tester);
        final twoPane = row.size.width >= 840;

        switch (row.screen) {
          case _Screen.review:
            _expectHeader(tester, 'Review merge');
            _expectStatus(tester, 'Unique data preserved');
            _expectStatus(tester, 'Nothing written yet');
            _expectButton(tester, 'Prefer local');
            _expectButton(tester, 'Prefer remote');
            _expectContainer(tester, 'Conflict section: Field conflicts');
            _expectContainer(tester, 'Conflict section: Deletions');
          case _Screen.field:
            await tester.tap(find.textContaining('Credentials'));
            await tester.pumpAndSettle();
            _expectHeader(tester, 'Credentials (username, password, website)');
            _expectRadio(tester, 'This device');
            _expectRadio(tester, 'Drive');
            _expectStatus(tester, 'Missing values are preserved');
            _expectButton(tester, 'Reveal values');
          case _Screen.ready:
            harness.bloc.add(
              const ApplySyncMergeShortcut(MergeShortcut.preferLocal),
            );
            await tester.pumpAndSettle();
            _expectHeader(tester, 'Ready to merge');
            _expectStatus(tester, 'Union summary');
            _expectButton(tester, 'Edit decisions');
            _expectStatus(tester, 'Backup before write');
            _expectStatus(tester, 'Remote write verification');
            _expectButton(tester, 'Merge and sync');
        }
        if (twoPane) {
          _expectContainer(tester, 'Merge decisions');
          _expectContainer(tester, 'Merge detail');
        }

        final exception = tester.takeException();
        expect(exception, isNull, reason: '$exception');
        expect(
          find.byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').contains('overflowed'),
          ),
          findsNothing,
        );
        semantics.dispose();
      });
    }
  });

  group('T608 named dynamic widget assertions', () {
    testWidgets('merge progress hides cancel after atomic boundary', (
      tester,
    ) async {
      await setMergeTestSize(tester, _phone);
      final harness = MergeScreenHarness();
      addTearDown(harness.dispose);
      harness.port.commitGate = Completer<void>();
      await tester.pumpWidget(harness.app());
      await harness.startReview(tester);
      harness.bloc.add(const ApplySyncMergeShortcut(MergeShortcut.preferLocal));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);

      await tester.tap(find.text('Merge and sync'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Cancel'), findsNothing);
      expect(find.byTooltip('Cancel merge'), findsNothing);
      expect(find.text('Merging'), findsOneWidget);
      expect(harness.port.calls, contains('commit'));
      expect(harness.port.calls, isNot(contains('cancel')));

      harness.port.commitGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Merge complete'), findsOneWidget);
    });

    testWidgets('a needs-review re-entry clears the commit flag: the next '
        'busy decision update shows the review, not the progress pane', (
      tester,
    ) async {
      await setMergeTestSize(tester, _phone);
      final harness = MergeScreenHarness();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.app());
      await harness.startReview(tester);
      harness.bloc.add(const ApplySyncMergeShortcut(MergeShortcut.preferLocal));
      await tester.pumpAndSettle();
      // The re-entry summary carries fresh (still-default) conflicts, so the
      // screen must land back on the REVIEW pane, not the ready pane.
      harness.port.commitOutcome = MergeNeedsReview(
        summary: MergeReviewSummary(
          sessionId: fixtureSessionId(9),
          databaseId: mergeFixtureDatabaseId,
          phase: MergeReviewPhase.needsReview,
          decisions: mixedDecisions(),
          localOnlyRecordCount: 2,
          remoteOnlyRecordCount: 1,
          oneSidedFieldCount: 3,
        ),
        newConflictCount: 1,
        reviewReentryCount: 1,
      );

      await tester.tap(find.text('Merge and sync'));
      await tester.pumpAndSettle();
      expect(find.text('Review merge'), findsOneWidget);

      final decision = harness.bloc.state.mergeReview!.decisions.first;
      harness.port.updateGate = Completer<void>();
      harness.bloc.add(
        UpdateSyncMergeDecision(
          decisionId: decision.decisionId,
          choice: MergeChoice.remote,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('Merging'), findsNothing);
      expect(find.text('Review merge'), findsOneWidget);

      harness.port.updateGate!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('field plaintext is absent after widget dispose and lock', (
      tester,
    ) async {
      await setMergeTestSize(tester, _phone);
      final harness = MergeScreenHarness();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.app());
      await harness.startReview(tester);
      await tester.tap(find.text('Notes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('PIN reminder'), findsOneWidget);
      final display = harness.port.served.single;
      expect(display.isDisposed, isFalse);

      // Lock: the vault tree is torn down and the merge invalidated.
      await tester.pumpWidget(const SizedBox.shrink());
      await harness.bloc.syncMergeCoordinator!.invalidate(
        mergeFixtureDatabaseId,
      );

      expect(display.isDisposed, isTrue);
      expect(() => display.local.value, throwsStateError);
      expect(find.textContaining('PIN reminder'), findsNothing);
      expect(
        harness.bloc.state.mergeReview?.toString() ?? '',
        isNot(contains('PIN')),
      );
    });

    testWidgets('background conflict remains status and opens no modal', (
      tester,
    ) async {
      await setMergeTestSize(tester, _phone);
      final repo = _ConflictSyncRepository()
        ..connected = true
        ..mappings[kTestDatabasePath] = DatabaseSyncMapping(
          databasePath: kTestDatabasePath,
          providerId: 'google_drive',
          remoteFileId: 'file-123',
          remoteFileName: 'Personal.kdbx',
          lastSyncAt: DateTime(2026, 8, 8),
        );
      addTearDown(resetVaultShellTestDi);
      await tester.pumpWidget(
        await pumpableVaultShell(databaseSyncRepository: repo),
      );
      await tester.pumpAndSettle();
      final bloc = BlocProvider.of<VaultBloc>(
        tester.element(find.byType(Scaffold).first),
        listen: false,
      );

      final sheetsBefore = find.byType(BottomSheet).evaluate().length;
      final dialogsBefore = find.byType(Dialog).evaluate().length;

      bloc.add(const BackgroundDriveSync());
      await tester.pumpAndSettle();

      expect(bloc.state.syncStatus, DatabaseSyncStatus.conflict);
      expect(bloc.state.pendingSyncConflict, isNotNull);
      expect(bloc.state.syncError, isNull);
      expect(find.byType(Dialog).evaluate().length, dialogsBefore);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet).evaluate().length, sheetsBefore);
      expect(find.text('Both versions changed'), findsNothing);
      expect(
        find
            .byType(ModalBarrier)
            .evaluate()
            .where((e) => (e.widget as ModalBarrier).dismissible),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Prefer local and Prefer remote never remove one-sided rows', (
      tester,
    ) async {
      await setMergeTestSize(tester, _tablet);
      final harness = MergeScreenHarness();
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.app());
      await harness.startReview(tester);
      final before = harness.bloc.state.mergeReview!;

      for (final shortcut in MergeShortcut.values) {
        harness.bloc.add(ApplySyncMergeShortcut(shortcut));
        await tester.pumpAndSettle();
        // If every row is now decided the ready pane replaces the list; go
        // back to the review to look at the rows.
        if (find.text('Edit decisions').evaluate().isNotEmpty) {
          await tester.tap(find.text('Edit decisions'));
          await tester.pumpAndSettle();
        }

        final after = harness.bloc.state.mergeReview!;
        expect(after.localOnlyRecordCount, before.localOnlyRecordCount);
        expect(after.remoteOnlyRecordCount, before.remoteOnlyRecordCount);
        expect(after.oneSidedFieldCount, before.oneSidedFieldCount);
        expect(after.decisions.length, before.decisions.length);
        // One-sided deletion rows are still there, answered with an
        // explicit keep/delete (FR-4) — never dropped, never inferred.
        for (final d in after.decisions.where(
          (d) => d.presence != MergePresence.presentBoth,
        )) {
          expect(d.choice, isIn([MergeChoice.keep, MergeChoice.delete]));
        }
        expect(find.text('Attachment'), findsOneWidget);
        expect(find.text('Record deleted on one side'), findsOneWidget);
        expect(find.textContaining('Unique data preserved'), findsOneWidget);
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Semantics helpers
// ---------------------------------------------------------------------------

/// Every semantics node whose label starts with [label]. A list row and a
/// header can share a label on the two-pane layout, so callers check that
/// SOME candidate carries the required role.
List<SemanticsNode> _nodes(WidgetTester tester, String label) {
  // Walk the real semantics tree from its root: element-level debugSemantics
  // is flaky for nodes hosted under explicitChildNodes containers.
  var root = tester.getSemantics(find.byType(MaterialApp).first);
  while (root.parent != null) {
    root = root.parent!;
  }
  final out = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    // Ancestor containers can absorb descendant labels into one
    // newline-joined label; a row match on any line is the role carrier.
    if (node.label.split('\n').any((line) => line.startsWith(label))) {
      out.add(node);
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  expect(out, isNotEmpty, reason: 'semantics "$label"');
  return out;
}

void _expectAny(
  WidgetTester tester,
  String label,
  bool Function(SemanticsNode node) role,
  String roleName,
) {
  expect(
    _nodes(tester, label).any(role),
    isTrue,
    reason: '"$label" has no node with $roleName',
  );
}

void _expectHeader(WidgetTester tester, String label) =>
    _expectAny(tester, label, (n) => n.flagsCollection.isHeader, 'header');

void _expectStatus(WidgetTester tester, String label) => _expectAny(
  tester,
  label,
  (n) => n.flagsCollection.isReadOnly && !n.flagsCollection.isButton,
  'read-only status',
);

void _expectButton(WidgetTester tester, String label) => _expectAny(
  tester,
  label,
  (n) =>
      n.flagsCollection.isButton &&
      n.flagsCollection.isEnabled == Tristate.isTrue,
  'enabled button',
);

void _expectRadio(WidgetTester tester, String label) =>
    _expectAny(tester, label, (node) {
      // The radio's own flags sit on a merged-up child of the list tile.
      var found = node.flagsCollection.isInMutuallyExclusiveGroup;
      node.visitChildren((child) {
        found = found || child.flagsCollection.isInMutuallyExclusiveGroup;
        return true;
      });
      return found;
    }, 'radio');

void _expectContainer(WidgetTester tester, String label) {
  _nodes(tester, label);
}

class _ConflictSyncRepository extends FakeDatabaseSyncRepository {
  @override
  Future<SyncNowResult> syncNow(
    String databasePath, {
    SyncConflictResolution? resolution,
  }) async => SyncNowConflict(
    SyncConflict(
      databasePath: databasePath,
      remoteFileId: 'file-123',
      remoteFileName: 'Personal.kdbx',
      localChecksum: 'a91f',
      remoteChecksum: '3d0c',
    ),
  );
}
