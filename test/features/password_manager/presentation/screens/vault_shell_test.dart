// spec-002 T4/T5: vault shell width-breakpoint geometry.
//
// Verifies the exact arithmetic at every boundary the specs name: no
// overflow, and the expected pane keys present/absent per width.
//
// spec-018 T018 moved two of those boundaries. They are no longer bare
// constants but derivations from the design's column widths (FR-002a):
//
//   detail pane : 72 + 330 + 300 + 2 dividers       = 704  (was a bare 708,
//                 the same arithmetic with the pre-correction rail of 76)
//   folder pane : 72 + 236 + 330 + 300 + 3 dividers = 941  (was Breakpoints
//                 .tablet, i.e. 1024, which is not where the columns fit)
//
// The 600 boundary is unchanged and still swaps the tab bar for the rail.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/navigation/vault_shell_router.dart';

import 'vault/vault_shell_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(resetVaultShellTestDi);

  Future<void> pumpAtWidth(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(await pumpableVaultShell());
    await tester.pumpAndSettle();
  }

  group('mobile / rail boundary (600)', () {
    testWidgets('599 renders mobile tab bar, not rail', (tester) async {
      await pumpAtWidth(tester, 599);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vault-tab-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-rail')), findsNothing);
    });

    testWidgets('600 renders rail, not mobile tab bar', (tester) async {
      await pumpAtWidth(tester, 600);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vault-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-tab-bar')), findsNothing);
    });
  });

  group('single-pane / detail-pane boundary (704, spec-018 FR-002d)', () {
    testWidgets('703 renders one content pane only', (tester) async {
      await pumpAtWidth(tester, 703);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vault-single-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-list-pane')), findsNothing);
      expect(find.byKey(const ValueKey('vault-detail-pane')), findsNothing);
    });

    testWidgets('704 renders list + detail panes', (tester) async {
      await pumpAtWidth(tester, 704);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vault-single-pane')), findsNothing);
      expect(find.byKey(const ValueKey('vault-list-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-detail-pane')), findsOneWidget);
      // Below 1024 the folder column must not reserve space.
      expect(find.byKey(const ValueKey('vault-folder-pane')), findsNothing);
    });

    // The band the previous code got wrong: it handed out a detail pane from
    // 600 up, in widths where the design's columns do not fit.
    testWidgets('the 600-703 band shows the rail but no detail pane', (
      tester,
    ) async {
      await pumpAtWidth(tester, 650);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vault-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-single-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-detail-pane')), findsNothing);
    });
  });

  group('folder-column boundary (1024, spec-018 FR-002d amended '
      '2026-08-31)', () {
    testWidgets('1023 has no folder column', (tester) async {
      await pumpAtWidth(tester, 1023);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vault-folder-pane')), findsNothing);
      expect(find.byKey(const ValueKey('vault-list-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-detail-pane')), findsOneWidget);
    });

    testWidgets('1024 shows the folder column', (tester) async {
      await pumpAtWidth(tester, 1024);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vault-folder-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-list-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-detail-pane')), findsOneWidget);
    });

    testWidgets('1024 still shows the folder column', (tester) async {
      await pumpAtWidth(tester, 1024);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('vault-folder-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-list-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-detail-pane')), findsOneWidget);
    });
  });

  testWidgets('starts at Vault destination for a newly constructed shell', (
    tester,
  ) async {
    await pumpAtWidth(tester, 1024);

    expect(tester.takeException(), isNull);
    final tabBar = find.byKey(const ValueKey('vault-rail'));
    expect(tabBar, findsOneWidget);
    // Vault destination selected: rail is drawn at Vault width (76), and
    // Vault's own content pane (list) is visible rather than a
    // Health/Sync/Settings placeholder.
    expect(find.byKey(const ValueKey('vault-list-pane')), findsOneWidget);
  });

  group('destinations are reachable', () {
    // spec-005: Health/Sync/Settings got first-class screens instead of a
    // placeholder button (FR-4/FR-1/FR-8) — these two cases now assert the
    // real content renders, not the superseded placeholder.
    testWidgets('Health destination shows real health content at rail width', (
      tester,
    ) async {
      await pumpAtWidth(tester, 1024);
      await tester.tap(find.byTooltip('Health'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Weak passwords'), findsOneWidget);
    });

    testWidgets(
      // spec-006 T1: Settings used to alias to the Backups screen (a
      // spec-005 stopgap before Settings had its own content) — it now
      // shows the real Settings destination, and Backups is reached one
      // level deeper via its "Backups & import" row.
      'Settings destination shows real settings content at mobile width',
      (tester) async {
        await pumpAtWidth(tester, 390);
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Change master password'), findsOneWidget);
        expect(find.text('Biometric protection'), findsOneWidget);
        expect(find.text('Import from CSV'), findsNothing);
      },
    );

    testWidgets('"Backups & import" row still reaches the Backups screen', (
      tester,
    ) async {
      await pumpAtWidth(tester, 390);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Backups & import'));
      await tester.tap(find.text('Backups & import'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Import from CSV'), findsOneWidget);
    });
  });

  group('T6: destination change vs. an open sub-surface discard guard', () {
    // Exercises the real consumer wiring (`_VaultViewState._selectDestination`
    // in vault_shell.part.dart), not just `VaultShellRouter` in isolation:
    // proves the shell actually calls `cancelForDestinationChange()` when
    // the user taps a different destination tab/rail item.
    testWidgets(
      'a rejecting discard guard keeps the current destination selected',
      (tester) async {
        await pumpAtWidth(tester, 1024);
        final router = VaultShellRouterScope.of(
          tester.element(find.byKey(const ValueKey('vault-rail'))),
        );

        final future = router.open<VaultDone>(
          context: tester.element(find.byKey(const ValueKey('vault-rail'))),
          surface: EntrySurface<VaultDone>(
            builder: (context) =>
                const SizedBox.shrink(key: ValueKey('surface-child')),
          ),
        );
        await tester.pump();
        final scope = VaultOperationScope.of(
          tester.element(find.byKey(const ValueKey('surface-child'))),
        );
        scope.registerDiscardGuard(() async => false);

        await tester.tap(find.byTooltip('Health'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // Destination unchanged: the Vault list pane is still showing, the
        // Health placeholder content never appears, and the open session
        // survived the (rejected) destination-change attempt.
        expect(find.byKey(const ValueKey('vault-list-pane')), findsOneWidget);
        expect(find.text('Weak passwords'), findsNothing);
        expect(router.debugLiveSessionCount, 1);

        router.cancel(scope.operationId);
        expect(await future, isNull);
      },
    );

    testWidgets(
      'an accepting discard guard cancels the surface and changes destination',
      (tester) async {
        await pumpAtWidth(tester, 1024);
        final router = VaultShellRouterScope.of(
          tester.element(find.byKey(const ValueKey('vault-rail'))),
        );

        final future = router.open<VaultDone>(
          context: tester.element(find.byKey(const ValueKey('vault-rail'))),
          surface: EntrySurface<VaultDone>(
            builder: (context) =>
                const SizedBox.shrink(key: ValueKey('surface-child')),
          ),
        );
        await tester.pump();
        final scope = VaultOperationScope.of(
          tester.element(find.byKey(const ValueKey('surface-child'))),
        );
        scope.registerDiscardGuard(() async => true);

        await tester.tap(find.byTooltip('Health'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Weak passwords'), findsOneWidget);
        expect(router.debugLiveSessionCount, 0);
        expect(await future, isNull);
      },
    );
  });
}
