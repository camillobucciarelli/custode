// spec 017 T202/T203 — the history view: its three states, and the reveal
// going through the same gate as the current password.
//
// Omitted axes (VR-002): behavioural, one width, light theme. The visual
// treatment is the goldens' subject (T501).
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/widgets/kv_letter_avatar.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry_revision.dart';
import 'package:password_manager/features/password_manager/data/datasources/biometric_data_source.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/entry_history_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/vault_session_coordinator.dart';
import 'package:password_manager/injection_container.dart' as di;

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

/// Fixture secrets, written to look like fixtures. No character of
/// [_oldSecret] may appear on screen while the revision is masked.
const _oldSecret = 'Fixture-Old-Pass-9z';
const _olderSecret = 'fixture-older-password';

VaultEntryHistory _gmailHistory() => VaultEntryHistory(
  // Newest first is what the service promises (FR-001); the view must not
  // reorder it, so the fixture hands it over in that order.
  revisions: [
    VaultEntryRevision(
      entryId: NavigationFixtureVaultKdbxService.gmail.id,
      replacedAt: DateTime.utc(2026, 3, 2, 10, 30),
      title: 'Gmail',
      username: 'me@example.com',
      password: _oldSecret,
      url: 'mail.google.com',
      notes: '',
    ),
    VaultEntryRevision(
      entryId: NavigationFixtureVaultKdbxService.gmail.id,
      replacedAt: DateTime.utc(2026, 3, 1, 9, 15),
      // A title-only change relative to the revision that replaced it: it
      // must not read as a password change (spec 017 edge case).
      title: 'Gmail (old)',
      username: 'me@example.com',
      password: _oldSecret,
      url: 'mail.google.com',
      notes: '',
    ),
  ],
  retention: const VaultHistoryRetention(maxItems: 12),
);

/// Two revisions saved in the same second: KDBX timestamps have no
/// sub-second precision, so `replacedAt` cannot tell them apart. Their
/// passwords differ, which is what makes a reveal keyed on the timestamp
/// visible as the leak it is.
VaultEntryHistory _sameSecondHistory() => VaultEntryHistory(
  revisions: [
    VaultEntryRevision(
      entryId: NavigationFixtureVaultKdbxService.gmail.id,
      replacedAt: DateTime.utc(2026, 3, 2, 10, 30),
      title: 'Gmail',
      username: 'me@example.com',
      password: _oldSecret,
      url: 'mail.google.com',
      notes: '',
    ),
    VaultEntryRevision(
      entryId: NavigationFixtureVaultKdbxService.gmail.id,
      replacedAt: DateTime.utc(2026, 3, 2, 10, 30),
      title: 'Gmail (old)',
      username: 'me@example.com',
      password: _olderSecret,
      url: 'mail.google.com',
      notes: '',
    ),
  ],
  retention: const VaultHistoryRetention(maxItems: 12),
);

/// Session settings the shell reads on start: biometric protection (which
/// sends the reveal through `_showBiometricRevealGate`, FR-003/D3) and the
/// inactivity lock timeout.
class _FixtureVaultSessionCoordinator implements VaultSessionCoordinator {
  _FixtureVaultSessionCoordinator({
    this.biometricProtection = false,
    this.inactivitySeconds,
  });

  final bool biometricProtection;
  final int? inactivitySeconds;

  @override
  Future<bool> getBiometricProtectionEnabledForPath({
    required String databasePath,
  }) async => biometricProtection;

  @override
  Future<String?> getSelectedKeyFilePath() async => null;

  @override
  Future<String?> getPersistedKeyFilePath(String databasePath) async => null;

  @override
  Future<Set<String>> getProtectedKeyFilePaths() async => const {};

  /// Recorded, not performed: the test asserts the shell was replaced, and
  /// the real lock needs the session secret holder.
  int lockVaultCalls = 0;

  @override
  Future<void> lockVault({required String currentDatabasePath}) async {
    lockVaultCalls++;
  }

  @override
  Future<int?> getInactivityLockTimeoutForPath({
    required String databasePath,
  }) async => inactivitySeconds;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records restores instead of performing them: the assertion is "called
/// once, with this revision", not the file's contents (T301 covers those).
class _RecordingEntryHistoryCoordinator implements EntryHistoryCoordinator {
  final List<(String, DateTime)> restores = [];
  final List<String> clears = [];

  @override
  Future<EntryHistoryRestoreResult> restore({
    required String databasePath,
    String? keyFilePath,
    required String entryId,
    required DateTime replacedAt,
    int ordinal = 0,
  }) async {
    restores.add((entryId, replacedAt));
    return const EntryHistoryRestoreResult(EntryHistoryOutcome.done);
  }

  @override
  Future<EntryHistoryClearResult> clearHistory({
    required String databasePath,
    String? keyFilePath,
    required String entryId,
  }) async {
    clears.add(entryId);
    return const EntryHistoryClearResult(
      EntryHistoryOutcome.done,
      backupPath: '/tmp/vault.20260301.pre-clear-history.kdbx',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Enough of the coordinator for `DatabaseUnlockScreen` to reach its idle
/// state; the unlock itself is not this test's subject.
class _StubDatabaseSessionCoordinator implements DatabaseSessionCoordinator {
  @override
  Future<UnlockBootstrapResult> initializeUnlock({
    required String databasePath,
    required bool biometricAvailable,
  }) async => const UnlockBootstrapResult(
    keyFilePath: null,
    biometricRequired: false,
    biometricAvailable: false,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The view formats in local time (`_formatEntryDateTime`), so the expected
/// label is computed the same way — CI runs in UTC, a desk does not.
String _saved(DateTime utc) {
  final l = utc.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}-${two(l.month)}-${l.year} ${two(l.hour)}:${two(l.minute)}';
}

final _newestSaved = _saved(DateTime.utc(2026, 3, 2, 10, 30));
final _olderSaved = _saved(DateTime.utc(2026, 3, 1, 9, 15));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetVaultShellTestDi);

  Future<NavigationFixtureVaultKdbxService> pumpVault(
    WidgetTester tester, {
    VaultSessionCoordinator? sessionCoordinator,
    EntryHistoryCoordinator? historyCoordinator,
    Size size = const Size(1024, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = NavigationFixtureVaultKdbxService();
    await tester.pumpWidget(
      await pumpableVaultShell(
        vaultKdbxService: service,
        vaultSessionCoordinator: sessionCoordinator,
        entryHistoryCoordinator: historyCoordinator,
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  // 2 s everywhere below, not 1: under the pane threshold the pushed detail
  // route's transition alone eats most of a second of `pumpAndSettle`, so a
  // 1 s timeout locked the vault while the history was still opening.
  Future<void> openHistory(WidgetTester tester, String title) async {
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
    final chip = find.text('View history');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  testWidgets('the list shows every revision, newest first and labelled', (
    tester,
  ) async {
    final service = await pumpVault(tester);
    service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
        _gmailHistory();

    await openHistory(tester, 'Gmail');

    // FR-015: read only when asked for, and then exactly once.
    expect(service.historyReads, [NavigationFixtureVaultKdbxService.gmail.id]);

    final newest = find.text('Saved $_newestSaved');
    final older = find.text('Saved $_olderSaved');
    expect(newest, findsOneWidget);
    expect(older, findsOneWidget);
    // FR-001: newest first.
    expect(tester.getTopLeft(newest).dy, lessThan(tester.getTopLeft(older).dy));

    // FR-002 / Constitution V: what changed is a label. The newest revision
    // differs from the record as it stands now by its password; the older
    // one differs from the newest only by its title, and must not claim a
    // password change.
    expect(find.text('Password changed'), findsOneWidget);
    expect(find.text('Changed: title'), findsOneWidget);

    // FR-012: the effective retention limit is stated.
    expect(
      find.text('This vault keeps up to 12 previous versions per record.'),
      findsOneWidget,
    );
  });

  testWidgets('a record never edited gets an empty state, not an error', (
    tester,
  ) async {
    await pumpVault(tester);
    await openHistory(tester, 'Gmail');

    expect(find.text('No previous versions'), findsOneWidget);
    expect(find.textContaining('nothing earlier to show'), findsOneWidget);
    // FR-012 holds in the empty state too.
    expect(
      find.text('This vault keeps up to 10 previous versions per record.'),
      findsOneWidget,
    );
  });

  testWidgets('a masked revision renders no character of the secret', (
    tester,
  ) async {
    final service = await pumpVault(tester);
    service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
        _gmailHistory();

    await openHistory(tester, 'Gmail');

    for (final rendered in tester.widgetList<Text>(find.byType(Text))) {
      final data = rendered.data;
      if (data == null) continue;
      expect(data, isNot(contains(_oldSecret)));
      expect(data, isNot(contains(_olderSecret)));
      // Not merely "not the whole string": no fragment of it either.
      expect(data, isNot(contains('Fixture-Old')));
    }
    // One masked row per revision, inside the history dialog — the record's
    // own masked password sits behind it and is not counted here.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('•' * 12),
      ),
      findsNWidgets(2),
    );
  });

  // spec 017 T303 / FR-005: the copy goes through `ClipboardGuard`, with the
  // detail's own toast and the same 30 s clear.
  testWidgets('copying a revision goes through the clipboard guard', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final service = await pumpVault(tester);
    service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
        _gmailHistory();

    await openHistory(tester, 'Gmail');
    await tester.tap(find.byTooltip('Copy this version’s password').first);
    await tester.pumpAndSettle();

    expect(copied, [_oldSecret]);
    expect(find.text('Copied password.'), findsOneWidget);
    // Nothing was revealed by copying.
    expect(find.text(_oldSecret), findsNothing);

    // Drain the guard's 30 s clear timer: its presence is the point.
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
  });

  // spec 017 T304 / FR-008: confirmed first, naming what is replaced.
  group('restore', () {
    Future<_RecordingEntryHistoryCoordinator> openAndTapRestore(
      WidgetTester tester, {
      VaultEntryHistory? history,
    }) async {
      final coordinator = _RecordingEntryHistoryCoordinator();
      final service = await pumpVault(tester, historyCoordinator: coordinator);
      service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
          history ?? _gmailHistory();
      await openHistory(tester, 'Gmail');
      await tester.tap(find.text('Restore this version').first);
      await tester.pumpAndSettle();
      return coordinator;
    }

    testWidgets('the confirmation names the record and the version', (
      tester,
    ) async {
      await openAndTapRestore(tester);

      expect(find.text('Restore this version?'), findsOneWidget);
      expect(find.textContaining('“Gmail”'), findsOneWidget);
      expect(find.textContaining('saved $_newestSaved'), findsOneWidget);
      // Gmail has no attachments and neither does the revision: no
      // attachment warning (FR-006a says "whenever they differ").
      expect(find.textContaining('Attachments are not restored'), findsNothing);
    });

    testWidgets('the confirmation warns when attachments differ', (
      tester,
    ) async {
      final history = _gmailHistory();
      await openAndTapRestore(
        tester,
        history: VaultEntryHistory(
          revisions: [
            VaultEntryRevision(
              entryId: NavigationFixtureVaultKdbxService.gmail.id,
              replacedAt: DateTime.utc(2026, 3, 2, 10, 30),
              title: 'Gmail',
              username: 'me@example.com',
              password: _oldSecret,
              url: 'mail.google.com',
              notes: '',
              attachmentNames: const ['old-recovery-codes.txt'],
            ),
          ],
          retention: history.retention,
        ),
      );

      expect(
        find.textContaining('Attachments are not restored'),
        findsOneWidget,
      );
    });

    testWidgets('dismissing writes nothing', (tester) async {
      final coordinator = await openAndTapRestore(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(coordinator.restores, isEmpty);
      expect(find.text('Restore this version?'), findsNothing);
    });

    testWidgets('confirming calls the coordinator once and tells the user', (
      tester,
    ) async {
      final coordinator = await openAndTapRestore(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(coordinator.restores, [
        (
          NavigationFixtureVaultKdbxService.gmail.id,
          DateTime.utc(2026, 3, 2, 10, 30),
        ),
      ]);
      expect(find.text('Previous version restored.'), findsOneWidget);
    });
  });

  // spec 017 T403 / FR-009, FR-010, SC-005: every path that destroys history
  // warns first, in words and with a glyph — never by colour alone.
  group('delete and clear', () {
    testWidgets('deleting one version is confirmed and then performed', (
      tester,
    ) async {
      final coordinator = _RecordingEntryHistoryCoordinator();
      final service = await pumpVault(tester, historyCoordinator: coordinator);
      service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
          _gmailHistory();
      await openHistory(tester, 'Gmail');

      await tester.tap(find.text('Delete this version').first);
      await tester.pumpAndSettle();

      expect(find.text('Delete this version?'), findsOneWidget);
      expect(find.textContaining('saved $_newestSaved'), findsOneWidget);
      expect(find.bySemanticsLabel('Warning'), findsOneWidget);
      // No backup for a single deletion (FR-009), and the dialog says
      // nothing of one.
      expect(find.textContaining('backup'), findsNothing);

      // Dismissing writes nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.calls, isEmpty);

      await tester.tap(find.text('Delete this version').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete version'));
      await tester.pumpAndSettle();

      expect(service.calls.map((call) => call.kind), ['deleteRevision']);
      expect(
        service.calls.single.fields['replacedAt'],
        DateTime.utc(2026, 3, 2, 10, 30).toIso8601String(),
      );
      expect(find.text('Previous version deleted.'), findsOneWidget);
      // The list reflects the file: one revision left.
      expect(find.text('Saved $_newestSaved'), findsNothing);
      expect(find.text('Saved $_olderSaved'), findsOneWidget);
    });

    testWidgets('clearing warns, names what goes, promises a backup', (
      tester,
    ) async {
      final coordinator = _RecordingEntryHistoryCoordinator();
      final service = await pumpVault(tester, historyCoordinator: coordinator);
      service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
          _gmailHistory();
      await openHistory(tester, 'Gmail');

      await tester.tap(find.byKey(const ValueKey('entry-history-clear')));
      await tester.pumpAndSettle();

      expect(find.text('Clear this record’s history?'), findsOneWidget);
      expect(find.textContaining('All 2 previous versions'), findsOneWidget);
      expect(find.textContaining('“Gmail”'), findsOneWidget);
      expect(find.textContaining('dated backup'), findsOneWidget);
      expect(find.bySemanticsLabel('Warning'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(coordinator.clears, isEmpty);

      await tester.tap(find.byKey(const ValueKey('entry-history-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear history'));
      await tester.pumpAndSettle();

      expect(coordinator.clears, [NavigationFixtureVaultKdbxService.gmail.id]);
      expect(find.textContaining('History cleared.'), findsOneWidget);
      expect(
        find.textContaining('vault.20260301.pre-clear-history.kdbx'),
        findsOneWidget,
      );
    });

    testWidgets('an empty history offers nothing to clear', (tester) async {
      await pumpVault(tester);
      await openHistory(tester, 'Gmail');

      expect(find.byKey(const ValueKey('entry-history-clear')), findsNothing);
      expect(find.text('Delete this version'), findsNothing);
    });
  });

  testWidgets('without biometric protection the eye reveals in place', (
    tester,
  ) async {
    final service = await pumpVault(tester);
    service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
        _gmailHistory();

    await openHistory(tester, 'Gmail');
    await tester.tap(find.byTooltip('Show this version’s password').first);
    await tester.pumpAndSettle();

    expect(find.text(_oldSecret), findsOneWidget);
    // The same auto-hide countdown the current password uses.
    expect(find.text('12s'), findsOneWidget);
  });

  testWidgets('with biometric protection the gate is shown before the reveal', (
    tester,
  ) async {
    final service = await pumpVault(
      tester,
      sessionCoordinator: _FixtureVaultSessionCoordinator(
        biometricProtection: true,
      ),
    );
    service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
        _gmailHistory();

    await openHistory(tester, 'Gmail');
    await tester.tap(find.byTooltip('Show this version’s password').first);
    await tester.pumpAndSettle();

    // The shell's fake biometric source declines, so the shared fallback
    // sheet appears — and nothing is revealed behind it.
    expect(find.text('Confirm it’s you'), findsOneWidget);
    expect(find.text(_oldSecret), findsNothing);
  });

  // F4: `replacedAt` is not an identity here. Two revisions of the same
  // second share it, and a reveal keyed on it unmasked both for one pass
  // through the gate.
  testWidgets('revealing one revision leaves a same-second sibling masked', (
    tester,
  ) async {
    final service = await pumpVault(tester);
    service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
        _sameSecondHistory();

    await openHistory(tester, 'Gmail');
    await tester.tap(find.byTooltip('Show this version’s password').first);
    await tester.pumpAndSettle();

    expect(find.text(_oldSecret), findsOneWidget);
    // The sibling is still masked, and its secret is nowhere on screen.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('•' * 12),
      ),
      findsOneWidget,
    );
    for (final rendered in tester.widgetList<Text>(find.byType(Text))) {
      expect(rendered.data ?? '', isNot(contains(_olderSecret)));
      expect(rendered.data ?? '', isNot(contains('Fixture-Older')));
    }
  });

  // F1/N1: the dialog is a route, so it renders above `_LockOverlay` — which
  // is a widget inside the shell's body. Left as it was, the history stayed
  // visible and revealable on a locked vault.
  //
  // Run at both widths on purpose. Below `VaultLayoutWidths.detailPane` (704)
  // the entry detail is itself a route pushed on the shared Navigator, so the
  // shell is not an ancestor of the history at all: the first fix resolved it
  // with `findAncestorStateOfType` and was inert on every phone while the
  // 1024 dp test stayed green.
  for (final size in const [Size(1024, 900), Size(390, 844)]) {
    final label = '${size.width.toInt()}dp';

    testWidgets(
      'the vault locking closes the history and its reveal ($label)',
      (tester) async {
        final service = await pumpVault(
          tester,
          size: size,
          sessionCoordinator: _FixtureVaultSessionCoordinator(
            inactivitySeconds: 2,
          ),
        );
        service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
            _gmailHistory();

        await openHistory(tester, 'Gmail');
        expect(find.byType(AlertDialog), findsOneWidget);

        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        // The history went with the lock, revealed or not.
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byTooltip('Show this version’s password'), findsNothing);
        for (final rendered in tester.widgetList<Text>(find.byType(Text))) {
          expect(rendered.data ?? '', isNot(contains('Fixture-Old')));
        }
        // `skipOffstage: false`: under the pane threshold the overlay is a
        // widget in the shell's body and the pushed detail route covers it —
        // a separate, pre-existing defect, out of this change's scope. That
        // the lock engaged at all is still assertable, and has to be: it is
        // what makes the closing mean something.
        expect(
          find.textContaining('is still open in memory', skipOffstage: false),
          findsOneWidget,
        );
      },
    );

    // F1/N1, second half: the shell's pointer listener sits below the overlay
    // `Stack`, so taps inside the dialog never reached the inactivity timer
    // and reading the history counted as being idle. The dialog closing on
    // lock is what makes this readable at both widths.
    testWidgets('a tap inside the history keeps the session alive ($label)', (
      tester,
    ) async {
      final service = await pumpVault(
        tester,
        size: size,
        // 2 s, not 1: below the pane threshold the pushed detail route's
        // transition alone eats most of a second of `pumpAndSettle`, so a 1 s
        // timeout locked the vault while the history was still opening.
        sessionCoordinator: _FixtureVaultSessionCoordinator(
          inactivitySeconds: 2,
        ),
      );
      service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
          _gmailHistory();

      await openHistory(tester, 'Gmail');
      final dialogTitle = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Password history'),
      );
      for (var tap = 0; tap < 3; tap++) {
        await tester.tap(dialogTitle);
        await tester.pump(const Duration(milliseconds: 700));
      }

      expect(find.byType(AlertDialog), findsOneWidget);
      // The activity never reaching the shell is the half of F1 that the
      // dialog staying open does not catch on its own.
      expect(
        find.textContaining('is still open in memory', skipOffstage: false),
        findsNothing,
      );
    });
  }

  // N2: `pop()` removes the top route, which is not necessarily this dialog.
  // With the reveal gate open above it the pop ate the gate and left the
  // history alive over a locked vault — and the notifier, already true, never
  // fired a second time.
  testWidgets('the vault locking closes the history from under an open gate', (
    tester,
  ) async {
    final service = await pumpVault(
      tester,
      sessionCoordinator: _FixtureVaultSessionCoordinator(
        biometricProtection: true,
        inactivitySeconds: 2,
      ),
    );
    service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
        _gmailHistory();

    await openHistory(tester, 'Gmail');
    await tester.tap(find.byTooltip('Show this version’s password').first);
    await tester.pumpAndSettle();
    expect(find.text('Confirm it’s you'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Confirm it’s you'), findsNothing);
    for (final rendered in tester.widgetList<Text>(find.byType(Text))) {
      expect(rendered.data ?? '', isNot(contains('Fixture-Old')));
    }
  });

  // N3: "Use password" pops the gate and then replaces a route. Called from
  // the history's gate, the route on top after the pop is the dialog, so the
  // shell survived underneath the unlock screen — unlocked, one back away.
  testWidgets('Use password from the history gate replaces the shell', (
    tester,
  ) async {
    final service = await pumpVault(
      tester,
      sessionCoordinator: _FixtureVaultSessionCoordinator(
        biometricProtection: true,
      ),
    );
    service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
        _gmailHistory();

    // The unlock screen this hands off to builds for real, so its bloc has to
    // be resolvable — nothing else about it is under test.
    di.sl.registerFactoryParam<DatabaseUnlockBloc, String, void>(
      (path, _) => DatabaseUnlockBloc(
        databasePath: path,
        biometricDataSource: di.sl<BiometricDataSource>(),
        databaseSessionCoordinator: _StubDatabaseSessionCoordinator(),
      ),
    );

    await openHistory(tester, 'Gmail');
    await tester.tap(find.byTooltip('Show this version’s password').first);
    await tester.pumpAndSettle();
    expect(find.text('Confirm it’s you'), findsOneWidget);

    await tester.tap(find.text('Use password'));
    await tester.pumpAndSettle();

    // The shell is `MaterialApp.home`, so nothing is left to pop once it has
    // been replaced. Replacing the dialog instead leaves the shell below it.
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    expect(navigator.canPop(), isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  // Q2: the same bridge one route up. Below `VaultLayoutWidths.detailPane` the
  // entry detail is itself a route pushed on the shared Navigator, so it sits
  // outside the shell's pointer `Listener` too — reading a record counted as
  // being idle and the vault locked under the user's finger. The tap target is
  // the record's avatar: inert, and inside the detail at both widths.
  for (final size in const [Size(1024, 900), Size(390, 844)]) {
    final label = '${size.width.toInt()}dp';

    testWidgets('a tap inside the entry detail keeps the session alive '
        '($label)', (tester) async {
      await pumpVault(
        tester,
        size: size,
        sessionCoordinator: _FixtureVaultSessionCoordinator(
          inactivitySeconds: 2,
        ),
      );
      await tester.tap(find.text('Gmail').first);
      await tester.pumpAndSettle();

      final avatar = find.descendant(
        of: find.byKey(const ValueKey('entry-detail-body')),
        matching: find.byType(KvLetterAvatar),
      );
      expect(avatar, findsOneWidget);
      // 4 x 700 ms = 2.8 s, past the 2 s timeout: only a tap that reaches the
      // shell keeps this from locking.
      for (var tap = 0; tap < 4; tap++) {
        await tester.tap(avatar);
        await tester.pump(const Duration(milliseconds: 700));
      }

      expect(
        find.textContaining('is still open in memory', skipOffstage: false),
        findsNothing,
      );
    });

    // Q4: N3's fix, from the gate the *detail* opens rather than the
    // history's. Both widths, because below the pane threshold the detail is
    // a route and popping the gate leaves that route — not the shell — on
    // top, which is exactly what N3 was.
    testWidgets('Use password from the detail gate replaces the shell '
        '($label)', (tester) async {
      await pumpVault(
        tester,
        size: size,
        sessionCoordinator: _FixtureVaultSessionCoordinator(
          biometricProtection: true,
        ),
      );
      di.sl.registerFactoryParam<DatabaseUnlockBloc, String, void>(
        (path, _) => DatabaseUnlockBloc(
          databasePath: path,
          biometricDataSource: di.sl<BiometricDataSource>(),
          databaseSessionCoordinator: _StubDatabaseSessionCoordinator(),
        ),
      );

      await tester.tap(find.text('Gmail').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm it\u2019s you'), findsOneWidget);

      await tester.tap(find.text('Use password'));
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      expect(navigator.canPop(), isFalse);
      expect(find.text('Confirm it\u2019s you'), findsNothing);
    });

    // N4: `KvBottomSheet.show` hosts on the root navigator, so the reveal
    // gate is a sibling of whatever opened it — outside the shell's pointer
    // `Listener` and outside the route host's. Typing the master password in
    // here read as being idle and the vault locked mid-entry. Same gate the
    // history reuses via `_resolveRevealPermission`.
    testWidgets('a tap inside the reveal gate keeps the session alive '
        '($label)', (tester) async {
      await pumpVault(
        tester,
        size: size,
        sessionCoordinator: _FixtureVaultSessionCoordinator(
          biometricProtection: true,
          inactivitySeconds: 2,
        ),
      );

      await tester.tap(find.text('Gmail').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();

      // Inert target, inside the sheet at both widths.
      final gateTitle = find.text('Confirm it\u2019s you');
      expect(gateTitle, findsOneWidget);
      // 4 x 700 ms = 2.8 s, past the 2 s timeout.
      for (var tap = 0; tap < 4; tap++) {
        await tester.tap(gateTitle);
        await tester.pump(const Duration(milliseconds: 700));
      }

      expect(gateTitle, findsOneWidget);
      expect(
        find.textContaining('is still open in memory', skipOffstage: false),
        findsNothing,
      );
    });

    // F2: the same gate, opened from the *history* rather than the detail.
    // `_showBiometricRevealGate` is shared, so one `Listener` covers both —
    // but the hop history -> `_resolveRevealPermission` -> gate is its own
    // route stack (dialog under a root-navigator sheet) and nothing else
    // asserts it. Both widths: `KvBottomSheet.show` uses the root navigator
    // at either one, so neither is a control.
    testWidgets('a tap inside the history\'s reveal gate keeps the session '
        'alive ($label)', (tester) async {
      final service = await pumpVault(
        tester,
        size: size,
        sessionCoordinator: _FixtureVaultSessionCoordinator(
          biometricProtection: true,
          inactivitySeconds: 2,
        ),
      );
      service.histories[NavigationFixtureVaultKdbxService.gmail.id] =
          _gmailHistory();

      await openHistory(tester, 'Gmail');
      await tester.tap(
        find.byTooltip('Show this version\u2019s password').first,
      );
      await tester.pumpAndSettle();

      // The sheet carries no text field, so the tap target is inert text.
      final gateTitle = find.text('Confirm it\u2019s you');
      expect(gateTitle, findsOneWidget);
      // 4 x 700 ms = 2.8 s, past the 2 s timeout.
      for (var tap = 0; tap < 4; tap++) {
        await tester.tap(gateTitle);
        await tester.pump(const Duration(milliseconds: 700));
      }

      expect(gateTitle, findsOneWidget);
      expect(
        find.textContaining('is still open in memory', skipOffstage: false),
        findsNothing,
      );
    });
  }
}
