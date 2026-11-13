// spec-018 US1 (T012, T013, T021a, T021b): one selection, one detail, at
// every width — plus the accessibility floor for the selected row.
//
// Omitted axes, stated per VR-002: these are behavioural assertions, so they
// run at light theme only. The visual treatment is covered by the 1024
// goldens; the dark theme by their dark variants.
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

  /// The list row for [title] — `.first`, because at wide widths the detail
  /// pane also renders the record's title.
  Finder listRow(String title) => find.text(title).first;

  /// Selected-marked widgets **inside the records list only**. Scoping
  /// matters: the navigation rail marks its current destination selected too,
  /// and that is not a record row.
  ///
  /// spec-019: the folder chip row moved into this pane below 941, and the
  /// active chip announces its selected state as it must (Constitution V) —
  /// so it is excluded here for the same reason the rail always was. This is
  /// a widening of the existing scope rule, not a change to any assertion:
  /// every expectation below still reads "exactly one **record row**".
  Iterable<Semantics> selectedRowSemantics(WidgetTester tester) => tester
      .widgetList<Semantics>(
        find.descendant(
          of: find.byKey(const ValueKey('vault-list-pane')),
          matching: find.byType(Semantics),
          matchRoot: false,
        ),
      )
      .where((widget) => widget.properties.selected ?? false)
      .where(
        (widget) => !tester
            .elementList(
              find.descendant(
                of: find.byKey(const ValueKey('vault-folder-chips')),
                matching: find.byWidget(widget),
              ),
            )
            .isNotEmpty,
      );

  // ---- T012: one detail, one highlighted row -----------------------------

  for (final width in <double>[704, 941, 1024]) {
    testWidgets('at $width: selecting a record shows exactly one detail', (
      tester,
    ) async {
      await pumpAt(tester, width);

      // FR-002c: the pane is persistent — the empty state is there before
      // anything is selected, not a pane that materialises on demand.
      expect(find.byKey(const ValueKey('vault-detail-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('entry-detail-body')), findsNothing);

      await tester.tap(listRow('Gmail'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('entry-detail-body')),
        findsOneWidget,
        reason: 'exactly one detail surface, never two (FR-001, D1)',
      );
    });

    testWidgets('at $width: exactly one row is marked selected', (
      tester,
    ) async {
      await pumpAt(tester, width);
      expect(selectedRowSemantics(tester), isEmpty);

      // A root-level record: 'GitHub' lives in the Devs folder, which the
      // list renders collapsed, so its row is not on screen.
      await tester.tap(listRow('Banca Sella'));
      await tester.pumpAndSettle();

      expect(
        selectedRowSemantics(tester).length,
        1,
        reason: 'G3.2/G3.3 — one row selected at every wide class (D3)',
      );
    });
  }

  testWidgets('the records card renders no detail of its own (G3.1)', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    await tester.tap(listRow('Gmail'));
    await tester.pumpAndSettle();

    // The detail lives in the shell's pane slot. If the card had kept its own
    // inline split, the copy affordance would appear twice.
    expect(find.byKey(const ValueKey('entry-detail-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-detail-pane')), findsOneWidget);
  });

  testWidgets('selecting another record replaces the detail, never stacks it', (
    tester,
  ) async {
    await pumpAt(tester, 1024);

    await tester.tap(listRow('Gmail'));
    await tester.pumpAndSettle();
    await tester.tap(listRow('Banca Sella'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('entry-detail-body')), findsOneWidget);
    expect(selectedRowSemantics(tester).length, 1);
  });

  // ---- T013: the selection survives a resize -----------------------------

  testWidgets('a selection survives crossing 704 and 941 in both directions', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    await tester.tap(listRow('Gmail'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('entry-detail-body')), findsOneWidget);

    for (final width in <double>[900, 800, 703, 800, 1024]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'resize to $width must not throw (FR-015)',
      );
      expect(
        find.byKey(const ValueKey('entry-detail-body')),
        findsOneWidget,
        reason: 'the record stays open at $width, in one place only',
      );
    }
  });

  // ---- T021a: the 704-940 band keeps every folder reachable --------------

  testWidgets('at 800 there is no folder column but folders stay reachable', (
    tester,
  ) async {
    await pumpAt(tester, 800);

    // FR-002d: the folder column starts at 941, so it is absent here...
    expect(find.byKey(const ValueKey('vault-folder-pane')), findsNothing);
    expect(find.byKey(const ValueKey('vault-detail-pane')), findsOneWidget);

    // ...and this is the assertion that justifies deferring the rail folder
    // switcher: the records list carries the folders itself, so nothing is
    // stranded in this band.
    expect(
      find.text('Devs'),
      findsWidgets,
      reason: 'the folder is reachable from the list in the 704-940 band',
    );

    await tester.tap(find.text('Devs').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // ---- T021b: accessibility floor (FR-016, Constitution V) ---------------

  testWidgets('the selected row publishes its state to semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(tester, 1024);

    await tester.tap(listRow('Gmail'));
    await tester.pumpAndSettle();

    // Not colour alone: a screen reader is told which row is selected.
    expect(selectedRowSemantics(tester).length, 1);
    handle.dispose();
  });

  testWidgets('record rows are reachable by keyboard traversal', (
    tester,
  ) async {
    await pumpAt(tester, 1024);

    // Tab into the list without ever using a pointer.
    var reachedList = false;
    for (var i = 0; i < 30 && !reachedList; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) continue;
      reachedList = find
          .descendant(
            of: find.byKey(const ValueKey('vault-list-pane')),
            matching: find.byWidget(focused.widget),
          )
          .evaluate()
          .isNotEmpty;
    }

    expect(tester.takeException(), isNull);
    expect(
      reachedList,
      isTrue,
      reason: 'FR-016: keyboard traversal must reach the records list',
    );
  });

  testWidgets('a record row is activatable, not just focusable', (
    tester,
  ) async {
    await pumpAt(tester, 1024);

    // Each row is an InkWell with a non-null onTap inside a
    // FocusableActionDetector, which is what makes Enter/Space activate it —
    // that activation is the framework's own contract and is not re-tested
    // here. What this asserts is that the row actually offers it.
    final rowInkWells = tester
        .widgetList<InkWell>(
          find.descendant(
            of: find.byKey(const ValueKey('vault-list-pane')),
            matching: find.byType(InkWell),
          ),
        )
        .where((inkWell) => inkWell.onTap != null);

    expect(rowInkWells, isNotEmpty);
  });

  for (final width in <double>[704, 1024]) {
    testWidgets('at $width the detail pane keeps its 300px minimum', (
      tester,
    ) async {
      await pumpAt(tester, width);

      final pane = tester.getSize(
        find.byKey(const ValueKey('vault-detail-pane')),
      );
      expect(
        pane.width,
        greaterThanOrEqualTo(300),
        reason: 'FR-002b: the detail never goes below its minimum',
      );
    });
  }
}
