// Issue #276: system back (Android back / predictive back, iOS swipe-back)
// consumes one Back step (GLOSSARY) inside the vault, and leaves the app only
// when none is left.
//
// `handlePopRoute()` returns false exactly when no route handled the back and
// the binding asked the platform to leave the app. `popDisposition` is read
// before each back: it is what the engine sees when a predictive gesture
// starts, so it must already be right.
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

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

  tearDown(resetVaultShellTestDi);

  Future<NavigationFixtureVaultKdbxService> pumpAt(
    WidgetTester tester,
    Size size, {
    bool locked = false,
  }) async {
    final service = NavigationFixtureVaultKdbxService();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      await pumpableVaultShell(
        vaultKdbxService: service,
        debugInitiallyLocked: locked,
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  const phone = Size(390, 844);
  const tablet = Size(1024, 900);

  VaultBloc bloc(WidgetTester tester) => tester
      .element(
        find
            .descendant(
              of: find.byType(VaultScreen),
              matching: find.byType(Scaffold),
            )
            .first,
      )
      .read<VaultBloc>();

  /// What the top route would do with a back right now.
  Future<RoutePopDisposition> disposition(WidgetTester tester) async {
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    late Route<Object?> top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    return top.popDisposition;
  }

  /// One system back. True when the app handled it, false when it exited.
  Future<bool> systemBack(WidgetTester tester) async {
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    return handled;
  }

  Future<void> expectExits(WidgetTester tester) async {
    expect(await disposition(tester), RoutePopDisposition.bubble);
    expect(await systemBack(tester), isFalse);
    expect(find.byType(VaultScreen), findsOneWidget, reason: 'not locked');
  }

  Future<void> expectStep(WidgetTester tester) async {
    expect(await disposition(tester), RoutePopDisposition.doNotPop);
    expect(await systemBack(tester), isTrue);
  }

  Finder inDetail(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('vault-detail-pane')),
    matching: matching,
  );

  testWidgets('vault root: back leaves the app, the vault stays open', (
    tester,
  ) async {
    await pumpAt(tester, phone);
    await expectExits(tester);
    expect(find.text('Gmail'), findsWidgets);
  });

  testWidgets('a search query is cleared first, then back leaves', (
    tester,
  ) async {
    await pumpAt(tester, phone);
    await tester.enterText(find.byType(TextFormField).first, 'gma');
    await tester.pumpAndSettle();

    await expectStep(tester);
    expect(bloc(tester).state.searchQuery, isEmpty);
    expect(find.text('gma'), findsNothing);

    await expectExits(tester);
  });

  testWidgets('folder browser: back goes to the parent folder, then leaves', (
    tester,
  ) async {
    await pumpAt(tester, phone);
    await tester.tap(find.text('Devs').first);
    await tester.pumpAndSettle();
    expect(
      bloc(tester).state.currentGroupId,
      NavigationFixtureVaultKdbxService.folderId,
    );

    await expectStep(tester);
    expect(
      bloc(tester).state.currentGroupId,
      NavigationFixtureVaultKdbxService.rootId,
    );

    await expectExits(tester);
  });

  testWidgets('with the folder column visible the folder is not a step', (
    tester,
  ) async {
    await pumpAt(tester, tablet);
    bloc(
      tester,
    ).add(const SelectVaultFolder(NavigationFixtureVaultKdbxService.folderId));
    await tester.pumpAndSettle();

    await expectExits(tester);
    expect(
      bloc(tester).state.currentGroupId,
      NavigationFixtureVaultKdbxService.folderId,
    );
  });

  testWidgets('Settings: back returns to the Vault destination, then leaves', (
    tester,
  ) async {
    await pumpAt(tester, phone);
    await tester.enterText(find.byType(TextFormField).first, 'gma');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);

    await expectStep(tester);
    // Back on the records list, with the search the user left there.
    expect(find.text('gma'), findsOneWidget);
    expect(bloc(tester).state.searchQuery, 'gma');
  });

  testWidgets('lock overlay: back leaves the app and changes nothing behind '
      'it', (tester) async {
    await pumpAt(tester, phone, locked: true);
    bloc(tester).add(const UpdateVaultSearchQuery('gma'));
    // The query is debounced.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(bloc(tester).state.searchQuery, 'gma');

    await expectExits(tester);
    expect(bloc(tester).state.searchQuery, 'gma');
  });

  group('wide layout panes', () {
    Future<void> openGmail(WidgetTester tester) async {
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const ValueKey('vault-list-pane')),
              matching: find.text('Gmail'),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an open detail pane is closed by back', (tester) async {
      await pumpAt(tester, tablet);
      await openGmail(tester);
      expect(
        inDetail(find.byKey(const ValueKey('entry-detail-body'))),
        findsOneWidget,
      );

      await expectStep(tester);
      expect(find.byKey(const ValueKey('entry-detail-body')), findsNothing);

      await expectExits(tester);
    });

    testWidgets('a dirty editor pane asks before discarding', (tester) async {
      await pumpAt(tester, tablet);
      await openGmail(tester);
      await tester.tap(inDetail(find.byTooltip('Edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        inDetail(find.byType(TextFormField)).first,
        'Gmail work',
      );
      await tester.pumpAndSettle();

      await expectStep(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Gmail work'), findsOneWidget, reason: 'draft kept');

      await expectStep(tester);
      expect(find.text('Discard changes?'), findsOneWidget, reason: 'once');
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Gmail work'), findsNothing);
      expect(
        inDetail(find.byKey(const ValueKey('entry-detail-body'))),
        findsOneWidget,
        reason: 'one step: back to the record, not out of the vault',
      );
    });

    testWidgets('a dirty editor pane under the lock overlay lets back leave', (
      tester,
    ) async {
      await pumpAt(tester, tablet);
      await openGmail(tester);
      await tester.tap(inDetail(find.byTooltip('Edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        inDetail(find.byType(TextFormField)).first,
        'Gmail work',
      );
      await tester.pumpAndSettle();

      // Background the app long enough ago that resuming locks it.
      final away = DateTime.now().subtract(const Duration(hours: 1));
      debugLockOverlayNowOverride = () => away;
      addTearDown(() => debugLockOverlayNowOverride = DateTime.now);
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
        find.text('Use master password'),
        findsOneWidget,
        reason: 'locked',
      );
      expect(find.text('Gmail work'), findsOneWidget, reason: 'draft mounted');

      await expectExits(tester);
      expect(find.text('Discard changes?'), findsNothing);
    });
  });

  group('phone routes', () {
    Future<void> openGmailEditor(WidgetTester tester) async {
      await tester.tap(find.text('Gmail').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
    }

    testWidgets('a clean editor route pops for real', (tester) async {
      await pumpAt(tester, phone);
      await openGmailEditor(tester);

      // `pop`, not `doNotPop`: predictive back and the iOS swipe can animate.
      expect(await disposition(tester), RoutePopDisposition.pop);
      expect(await systemBack(tester), isTrue);
      expect(find.byTooltip('Edit'), findsOneWidget, reason: 'detail shown');

      expect(await disposition(tester), RoutePopDisposition.pop);
      expect(await systemBack(tester), isTrue);
      expect(find.byKey(const ValueKey('entry-detail-body')), findsNothing);

      await expectExits(tester);
    });

    testWidgets('a dialog over the detail closes first, writing nothing', (
      tester,
    ) async {
      final service = await pumpAt(tester, phone);
      await tester.tap(find.text('Gmail').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Record actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Move this record to recycle bin?'), findsOneWidget);

      expect(await systemBack(tester), isTrue);
      expect(find.text('Move this record to recycle bin?'), findsNothing);
      expect(service.calls, isEmpty);
      expect(find.byKey(const ValueKey('entry-detail-body')), findsOneWidget);

      expect(await systemBack(tester), isTrue);
      expect(find.byKey(const ValueKey('entry-detail-body')), findsNothing);
      await expectExits(tester);
    });

    testWidgets('a dirty editor route asks before discarding', (tester) async {
      await pumpAt(tester, phone);
      await openGmailEditor(tester);
      await tester.enterText(find.byType(TextFormField).first, 'Gmail work');
      await tester.pumpAndSettle();

      await expectStep(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('Gmail work'), findsNothing);
      expect(find.byTooltip('Edit'), findsOneWidget, reason: 'detail shown');
    });
  });
}
