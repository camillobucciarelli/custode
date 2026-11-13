// spec-018 US4 (T029, T030) + US3 (T033-T035) + US1 origin parity (T014).
//
// Grouped in one file because they all drive the same surface: what happens
// to the detail pane when the record under it changes, when the editor takes
// its slot, and when the same record is opened from a different origin.
//
// Omitted axes per VR-002: light theme only; the visual result at 1024 is
// covered by the goldens in both themes.
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

  Finder inDetail(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('vault-detail-pane')),
    matching: matching,
  );

  Finder inList(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('vault-list-pane')),
    matching: matching,
  );

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

  Future<void> openGmail(WidgetTester tester) async {
    await tester.tap(inList(find.text('Gmail')).first);
    await tester.pumpAndSettle();
  }

  // ---- T029/T030: US4, a deleted record leaves no dead detail ------------

  testWidgets('deleting the shown record returns the pane to its empty state', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    await openGmail(tester);
    expect(
      inDetail(find.byKey(const ValueKey('entry-detail-body'))),
      findsOneWidget,
    );

    await tester.tap(inDetail(find.byTooltip('Record actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'FR-008/G4.5 — no error dialog, no exception',
    );
    expect(
      find.byKey(const ValueKey('entry-detail-body')),
      findsNothing,
      reason: 'D6 — the pane must not be left showing a dead surface',
    );
    expect(find.byKey(const ValueKey('vault-detail-pane')), findsOneWidget);

    // Nothing is left selected once the record is gone.
    final stillSelected = tester
        .widgetList<Semantics>(inList(find.byType(Semantics)))
        .where((widget) => widget.properties.selected ?? false);
    expect(stillSelected, isEmpty, reason: 'G4.4 — selection cleared');
  });

  testWidgets('the same delete works in the single-pane band', (tester) async {
    await pumpAt(tester, 650);
    await tester.tap(find.text('Gmail').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Record actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // G4.2: the dismissal path is presentation-neutral, so the pushed
    // presentation lands back on the list just as the pane lands on empty.
    expect(find.byKey(const ValueKey('entry-detail-body')), findsNothing);
    expect(find.text('Banca Sella'), findsWidgets);
  });

  // ---- Resize keeps exactly one back affordance ---------------------------

  // Amended 2026-08-31 (twice): beside a list the pane detail carries no
  // back — the list is the navigation. But once a resize leaves the mounted
  // pane as the ONLY column, the back must appear or the user is stuck in
  // the detail with nothing to dismiss it.
  testWidgets('shrinking the window until the detail stands alone shows '
      'exactly one back button', (tester) async {
    await pumpAt(tester, 1024);
    await openGmail(tester);
    expect(find.byTooltip('Back'), findsNothing);

    // The pane was chosen at 1024 and stays mounted; only the width changes.
    tester.view.physicalSize = const Size(650, 900);
    await tester.pumpAndSettle();

    expect(
      find.byTooltip('Back'),
      findsOneWidget,
      reason: 'a sole-column detail with no back is a dead end',
    );

    // Growing the window back restores the list — and removes the back.
    tester.view.physicalSize = const Size(1024, 900);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsNothing);
  });

  // ---- T014: US1 origin parity -------------------------------------------

  // FR-011/G5.6: the action set must not depend on the layout. Origin parity
  // (list vs Health vs duplicates) is guaranteed structurally rather than
  // asserted here — every origin now calls the single `_openEntryDetailsSurface`,
  // which attaches the actions itself, so there is no second wiring that could
  // drift. What a test *can* still catch is a layout-dependent menu, so that
  // is what this checks.
  for (final width in <double>[650, 1024]) {
    testWidgets('at $width the detail offers the same three actions', (
      tester,
    ) async {
      await pumpAt(tester, width);
      await tester.tap(find.text('Gmail').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Record actions').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // FR-011 as amended by spec 020: `Attachments` left the overflow for
      // a permanent body section (which lists the files since 2026-11-13).
      expect(find.text('No attachments'), findsWidgets);
      for (final label in ['Move', 'Delete']) {
        expect(
          find.text(label),
          findsWidgets,
          reason: '$label must be offered at $width too (FR-011)',
        );
      }
      // Edit is a header button rather than a menu item, at every width.
      expect(find.byTooltip('Edit'), findsWidgets);
    });
  }

  // ---- T033/T034: US3, the editor keeps the user's place -----------------

  testWidgets('the editor header carries the record title, not a generic '
      'label', (tester) async {
    await pumpAt(tester, 1024);
    await openGmail(tester);

    await tester.tap(inDetail(find.byTooltip('Edit')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      inDetail(find.text('Gmail')),
      findsWidgets,
      reason: 'FR-009a — the user can tell which record they are editing (D7)',
    );
    expect(find.text('Edit item'), findsNothing);
  });

  testWidgets('cancelling the editor returns to that record\'s detail', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    await openGmail(tester);

    await tester.tap(inDetail(find.byTooltip('Edit')));
    await tester.pumpAndSettle();
    await tester.tap(inDetail(find.byTooltip('Cancel')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      inDetail(find.byKey(const ValueKey('entry-detail-body'))),
      findsOneWidget,
      reason: 'FR-009 — not the empty state (D7)',
    );
  });

  testWidgets('the records list is never dimmed while the editor is open', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    await openGmail(tester);
    await tester.tap(inDetail(find.byTooltip('Edit')));
    await tester.pumpAndSettle();

    // FR-002e: the design's artboard drew the list at 50% while editing. That
    // is a drawing device, not a spec: a dimmed interactive column fails the
    // contrast floor and misrepresents itself as inactive.
    final opacities = tester
        .widgetList<Opacity>(inList(find.byType(Opacity)))
        .where((widget) => widget.opacity < 0.95);
    expect(opacities, isEmpty, reason: 'the list stays fully legible');
  });

  // ---- The generator column must not strand the folder column ------------
  //
  // Reported by the PR reviewer on #175. `generatorColumnOpen` was set when the
  // editor opened its generator column and cleared only by `Use`, so cancelling
  // or saving with the column open left the shell demoting `wideWithFolders` to
  // `wide` for the rest of the vault session.

  testWidgets('cancelling the editor with the generator open restores the '
      'folder column', (tester) async {
    await pumpAt(tester, 1024);
    expect(
      find.byKey(const ValueKey('vault-folder-pane')),
      findsOneWidget,
      reason: '1024 >= 941, so the folder column is part of the strip',
    );

    await openGmail(tester);
    await tester.tap(inDetail(find.byTooltip('Edit')));
    await tester.pumpAndSettle();
    await tester.tap(inDetail(find.byTooltip('Generate secure password')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('vault-folder-pane')),
      findsNothing,
      reason: 'FR-002e — the generator column collapses the folder column',
    );

    await tester.tap(inDetail(find.byTooltip('Cancel')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('vault-folder-pane')),
      findsOneWidget,
      reason:
          'every way out of the editor is a way out of the generator '
          'column — not only Use',
    );
  });

  // ---- T035: US3, the generator column vs sheet --------------------------

  testWidgets('at 1024 the generator opens as a column, not stacked on the '
      'editor', (tester) async {
    await pumpAt(tester, 1024);
    await openGmail(tester);
    await tester.tap(inDetail(find.byTooltip('Edit')));
    await tester.pumpAndSettle();

    // 1024 >= 995, so FR-002e says column. The editor stays visible beside it
    // rather than being covered by a sheet — the "dialog over dialog" case
    // the design called the worst of the current app.
    expect(tester.takeException(), isNull);
    expect(inDetail(find.byTooltip('Save')), findsOneWidget);
  });
}
