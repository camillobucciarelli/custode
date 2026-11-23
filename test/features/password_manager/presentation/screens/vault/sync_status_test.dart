// spec-005 T19: iterate DatabaseSyncStatus.values, assert a non-empty hero
// for each (AC2); assert no auth call on first `disconnected` render (AC3).
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/widgets/kv_list_row.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_status.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/sync_status_hero.dart';

import '../../coordinators/fake_database_ports.dart';
import 'vault_shell_test_utils.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(20), child: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    await (FontLoader(
      'Caprasimo',
    )..addFont(rootBundle.load('assets/fonts/Caprasimo-Regular.ttf'))).load();
    await (FontLoader('Figtree')
          ..addFont(rootBundle.load('assets/fonts/Figtree-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-SemiBold.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-Bold.ttf')))
        .load();
  });

  group('AC2: every DatabaseSyncStatus value has a rendered hero', () {
    for (final status in DatabaseSyncStatus.values) {
      testWidgets('$status renders a non-empty hero, not a snackbar', (
        tester,
      ) async {
        // connected+linked for every status except disconnected, so the
        // widget exercises each status branch (not the "not linked" one).
        final isDisconnected = status == DatabaseSyncStatus.disconnected;
        await tester.pumpWidget(
          _wrap(
            SyncStatusHero(
              status: status,
              isDriveConnected: !isDisconnected,
              isDriveLinked: !isDisconnected,
              linkedRemoteFileName: isDisconnected ? null : 'Personal.kdbx',
              lastSyncAt: isDisconnected ? null : DateTime(2026, 1, 1),
              syncError: status == DatabaseSyncStatus.error
                  ? 'Authorization expired'
                  : null,
            ),
          ),
        );
        // `syncing` renders an indeterminate KvSpinner (CircularProgress-
        // Indicator) that animates forever — pumpAndSettle would never
        // converge (same rationale as unlock_decrypting in
        // database_and_unlock_test.dart). Bounded pumps for every status.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull);
        expect(find.byType(SyncStatusHero), findsOneWidget);
        // Non-empty: at least one non-blank Text descendant renders.
        final texts = tester
            .widgetList<Text>(
              find.descendant(
                of: find.byType(SyncStatusHero),
                matching: find.byType(Text),
              ),
            )
            .where((t) => (t.data ?? '').trim().isNotEmpty);
        expect(texts, isNotEmpty, reason: '$status must render visible text');
        // Never a SnackBar-only state.
        expect(find.byType(SnackBar), findsNothing);
      });
    }
  });

  group(
    'Copilot fix (PR #9): stale `disconnected` status after app restart',
    () {
      testWidgets(
        'connected+linked but status still at its disconnected default renders '
        'the success hero, not the disconnected prompt',
        (tester) async {
          // Reproduces VaultBloc._onBackgroundDriveSync: on app restart it
          // updates isDriveConnected/isDriveLinked without touching
          // syncStatus (still at its `disconnected` default) until an
          // explicit sync runs. The hero must not show "Connect Google
          // account" to an already-connected, already-linked user.
          await tester.pumpWidget(
            _wrap(
              const SyncStatusHero(
                status: DatabaseSyncStatus.disconnected,
                isDriveConnected: true,
                isDriveLinked: true,
                linkedRemoteFileName: 'Personal.kdbx',
              ),
            ),
          );
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(find.text('Up to date'), findsOneWidget);
          expect(find.text('Connect Google account'), findsNothing);
          expect(find.text('This database lives only here'), findsNothing);
        },
      );
    },
  );

  group('_relativeTime singular/plural', () {
    testWidgets(
      '1 minute/hour/day ago are singular, not "1 minutes/hours/days ago"',
      (tester) async {
        final now = DateTime(2026, 1, 10, 12, 0, 0);
        SyncStatusHero.debugNowOverride = now;
        addTearDown(() => SyncStatusHero.debugNowOverride = null);

        Future<void> pumpAt(DateTime lastSyncAt) => tester.pumpWidget(
          _wrap(
            SyncStatusHero(
              status: DatabaseSyncStatus.success,
              isDriveConnected: true,
              isDriveLinked: true,
              linkedRemoteFileName: 'Personal.kdbx',
              lastSyncAt: lastSyncAt,
            ),
          ),
        );

        await pumpAt(now.subtract(const Duration(minutes: 1)));
        expect(find.textContaining('Last sync 1 minute ago'), findsOneWidget);
        expect(find.textContaining('1 minutes ago'), findsNothing);

        await pumpAt(now.subtract(const Duration(minutes: 5)));
        expect(find.textContaining('Last sync 5 minutes ago'), findsOneWidget);

        await pumpAt(now.subtract(const Duration(hours: 1)));
        expect(find.textContaining('Last sync 1 hour ago'), findsOneWidget);
        expect(find.textContaining('1 hours ago'), findsNothing);

        await pumpAt(now.subtract(const Duration(hours: 3)));
        expect(find.textContaining('Last sync 3 hours ago'), findsOneWidget);

        await pumpAt(now.subtract(const Duration(days: 1)));
        expect(find.textContaining('Last sync 1 day ago'), findsOneWidget);
        expect(find.textContaining('1 days ago'), findsNothing);

        await pumpAt(now.subtract(const Duration(days: 4)));
        expect(find.textContaining('Last sync 4 days ago'), findsOneWidget);
      },
    );
  });

  group(
    'AC3: disconnected explains the security model before any auth call',
    () {
      testWidgets(
        'first render of the disconnected hero calls zero DatabaseSyncRepository.connect()',
        (tester) async {
          addTearDown(resetVaultShellTestDi);
          final spyRepo = _SpyDatabaseSyncRepository();

          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            await pumpableVaultShell(databaseSyncRepository: spyRepo),
          );
          await tester.pumpAndSettle();

          // Navigate to the Sync tab — the disconnected hero renders because
          // the fake repository reports not-connected.
          await tester.tap(find.text('Sync'));
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(
            find.textContaining('the master password never leaves this device'),
            findsOneWidget,
            reason: 'security explanation must be on screen before any tap',
          );
          expect(
            spyRepo.connectCallCount,
            0,
            reason:
                'no Drive auth call may happen before the user taps '
                'the Google Drive provider tile',
          );

          // Now the user acts — only then is the auth call allowed.
          await tester.tap(find.text('Google Drive'));
          await tester.pumpAndSettle();

          expect(spyRepo.connectCallCount, 1);
        },
      );
    },
  );

  group('Regression: "Create a new file" double-tap must not create two remote '
      'files (Drive does not enforce filename uniqueness)', () {
    testWidgets(
      'a second tap while linking is in flight does not fire a second '
      'linkDatabaseToRemote call',
      (tester) async {
        addTearDown(resetVaultShellTestDi);
        final repo = _SlowLinkDatabaseSyncRepository()..connected = true;

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          await pumpableVaultShell(databaseSyncRepository: repo),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Sync'));
        await tester.pumpAndSettle();

        final createTile = find.text('Create a new file on Google Drive');
        expect(createTile, findsOneWidget);

        await tester.tap(createTile);
        // One pump is enough for the bloc's synchronous "syncing" emit to
        // land and rebuild the hero — the tile stays on screen (the
        // not-linked hero doesn't swap views on `status`) but its tap
        // handler must now be disabled.
        await tester.pump();

        expect(repo.linkCallCount, 1);

        // The UI-level guard in vault_sync.part.dart must itself disable
        // the tile's tap handler while syncing — asserted directly on the
        // widget, not just via the downstream repository call count, so a
        // regression that removes the UI guard (but leaves the bloc's own
        // re-entrancy guard in place) still fails this test.
        expect(
          tester
              .widget<KvListRow>(
                find.ancestor(of: createTile, matching: find.byType(KvListRow)),
              )
              .onTap,
          isNull,
          reason:
              'the "Create a new file" row must disable its own onTap '
              'while syncStatus is syncing, independent of the bloc guard',
        );

        // A second tap while the first `linkDatabaseToRemote` call is
        // still in flight (the fast-double-tap window from the field
        // report) must not fire another one.
        await tester.tap(createTile);
        await tester.pump();

        expect(repo.linkCallCount, 1);

        repo.gate.complete();
        await tester.pumpAndSettle();
      },
    );
  });
}

class _SpyDatabaseSyncRepository extends FakeDatabaseSyncRepository {
  int connectCallCount = 0;

  @override
  Future<void> connect() async {
    connectCallCount += 1;
    await super.connect();
  }
}

/// Never resolves `linkDatabaseToRemote` until the test completes [gate],
/// holding the bloc in `syncStatus: syncing` so a second, near-simultaneous
/// tap can be asserted against without racing a real async gap.
class _SlowLinkDatabaseSyncRepository extends FakeDatabaseSyncRepository {
  int linkCallCount = 0;
  final Completer<void> gate = Completer<void>();

  @override
  Future<DatabaseSyncMapping> linkDatabaseToRemote({
    required String databasePath,
    String? remoteFileId,
    String? remoteFileName,
  }) async {
    linkCallCount += 1;
    await gate.future;
    return super.linkDatabaseToRemote(
      databasePath: databasePath,
      remoteFileId: remoteFileId,
      remoteFileName: remoteFileName,
    );
  }
}
