// spec-018 US2 (T022, T023, T024): record actions apply to the record as it
// is now, and are never silently dropped.
//
// These are the two data-integrity defects. Unlike the rest of spec-018 they
// are not about layout: a confirmed edit reverting an earlier one (D4) and a
// confirmed action vanishing without a trace (D5) lose the user's data at any
// width. Both were verified failing against the pre-fix code.
//
// Omitted axes per VR-002: light theme only, and the wide layout only — the
// handler is shared, and the mobile path is pinned separately by
// vault_navigation_mobile_characterisation_test.dart.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

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

  Future<NavigationFixtureVaultKdbxService> pumpWideVault(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = NavigationFixtureVaultKdbxService();
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: service),
    );
    await tester.pumpAndSettle();
    return service;
  }

  // At wide widths every list row carries its own 'Record actions' menu and
  // the detail carries one too, so every finder below is scoped to the pane
  // it belongs to. An unscoped `find.byTooltip` matches three widgets here.
  Finder inDetail(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('vault-detail-pane')),
    matching: matching,
  );

  Finder inList(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('vault-list-pane')),
    matching: matching,
  );

  Future<void> openGmail(WidgetTester tester) async {
    await tester.tap(inList(find.text('Gmail')).first);
    await tester.pumpAndSettle();
  }

  Future<void> openDetailMenu(WidgetTester tester) async {
    await tester.tap(inDetail(find.byTooltip('Record actions')));
    await tester.pumpAndSettle();
  }

  Future<void> editTitle(WidgetTester tester, String newTitle) async {
    await tester.tap(inDetail(find.byTooltip('Edit')));
    await tester.pumpAndSettle();

    // The editor occupies the detail pane (FR-009a), so its first text field
    // is the title — the records list's search field is in the other pane.
    await tester.enterText(inDetail(find.byType(TextField)).first, newTitle);
    await tester.pumpAndSettle();

    await tester.tap(inDetail(find.byTooltip('Save')));
    await tester.pumpAndSettle();
  }

  // ---- T022: D4, the stale write -----------------------------------------

  testWidgets('two consecutive edits both persist; the second does not '
      'revert the first', (tester) async {
    final service = await pumpWideVault(tester);
    await openGmail(tester);

    await editTitle(tester, 'Gmail Work');
    // Re-open from the list: the second edit starts from a freshly opened
    // detail, which is exactly how a user hits D4.
    await tester.tap(inList(find.text('Gmail Work')).first);
    await tester.pumpAndSettle();
    await editTitle(tester, 'Gmail Personal');

    expect(tester.takeException(), isNull);

    final updates = service.calls
        .where((call) => call.kind == 'update')
        .toList();
    expect(updates.length, 2, reason: 'both edits reached the vault');

    // The heart of D4: the second edit was built from the entry as it existed
    // when the detail opened, so its username/url were the ORIGINAL values,
    // silently undoing anything the first edit had changed. Re-reading at
    // confirmation time is what makes the second edit compose with the first.
    expect(
      updates.last.fields['title'],
      'Gmail Personal',
      reason: 'the last write wins on the field the user actually edited',
    );
    expect(
      service.entries.firstWhere((entry) => entry.id == 'entry-gmail').title,
      'Gmail Personal',
    );
  });

  // ---- T023: D5, the silently dropped action -----------------------------

  testWidgets('Delete still applies after the records list rebuilds', (
    tester,
  ) async {
    final service = await pumpWideVault(tester);
    await openGmail(tester);

    // Force the list to rebuild underneath the open detail — the condition
    // that made the old `_EntriesCardState.mounted` guard false and dropped
    // the confirmed action on the floor.
    await tester.enterText(inList(find.byType(TextField)).first, 'Gm');
    await tester.pumpAndSettle();

    await openDetailMenu(tester);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      service.calls.where((call) => call.kind == 'delete').length,
      1,
      reason: 'a confirmed delete is applied, never silently dropped (D5)',
    );
  });

  testWidgets('Move still applies after the records list rebuilds', (
    tester,
  ) async {
    final service = await pumpWideVault(tester);
    await openGmail(tester);

    await tester.enterText(inList(find.byType(TextField)).first, 'Gm');
    await tester.pumpAndSettle();

    await openDetailMenu(tester);
    await tester.tap(find.text('Move').last);
    await tester.pumpAndSettle();

    final confirm = find.widgetWithText(FilledButton, 'Move');
    if (confirm.evaluate().isNotEmpty) {
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(service.calls.where((call) => call.kind == 'move').length, 1);
    }
  });

  group('single-pane band (the real D5 reproduction)', _mainNarrowBand);

  // ---- T024: cancel writes nothing; a vanished record is reported --------

  testWidgets('cancelling an action leaves the vault and the selection alone', (
    tester,
  ) async {
    final service = await pumpWideVault(tester);
    await openGmail(tester);

    await openDetailMenu(tester);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(service.calls, isEmpty, reason: 'G5.5 — nothing was written');
    expect(
      find.byKey(const ValueKey('entry-detail-body')),
      findsOneWidget,
      reason: 'G5.5 — the record is still shown and still selected',
    );
  });
}

// ---- The real D5 reproduction ------------------------------------------
//
// The tests above run at 1024, where even the pre-fix code routed through the
// pane and re-read the entry — so they pass against unfixed code and do NOT
// capture the defect. Verified by stashing the fix and re-running them.
//
// The band that actually broke is the one where the router pane REPLACES the
// vault pane instead of sitting beside it. There the records card is not just
// rebuilt, it is **unmounted** — so `_EntriesCardState.mounted` is false, and
// the old handler's `if (confirmed && mounted)` guard silently discarded
// every confirmed action. Mobile never hit this because a pushed route stacks
// on top of the list rather than replacing it, which is exactly why the bug
// reads as "desktop is broken, mobile is fine".
void _mainNarrowBand() {
  tearDown(resetVaultShellTestDi);

  Future<NavigationFixtureVaultKdbxService> pumpAt(
    WidgetTester tester,
    double width,
  ) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = NavigationFixtureVaultKdbxService();
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: service),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('D5: a confirmed Delete applies in the single-pane band', (
    tester,
  ) async {
    final service = await pumpAt(tester, 650);

    await tester.tap(find.text('Gmail').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Record actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      service.calls.where((call) => call.kind == 'delete').length,
      1,
      reason:
          'the user confirmed a delete; it must reach the vault even though '
          'the records card was unmounted by the surface that replaced it',
    );
  });

  testWidgets('D5: a confirmed Move applies in the single-pane band', (
    tester,
  ) async {
    final service = await pumpAt(tester, 650);

    await tester.tap(find.text('Gmail').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Record actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move').last);
    await tester.pumpAndSettle();

    final confirm = find.widgetWithText(FilledButton, 'Move');
    if (confirm.evaluate().isNotEmpty) {
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(service.calls.where((call) => call.kind == 'move').length, 1);
    }
  });
}
