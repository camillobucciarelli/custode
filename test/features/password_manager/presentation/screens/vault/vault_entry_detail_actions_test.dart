// spec-019 journey 04 — the detail's action row, its overflow, and the empty
// state beside it (C-04-01, C-04-03, C-04-05).
//
// Omitted axes (VR-002): behavioural, light theme only. The visual treatment
// is the 1024 goldens' subject.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/widgets/kv_icon.dart';

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  Future<void> openRecord(WidgetTester tester, String title) async {
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
  }

  // Amended 2026-08-30: the standalone `Open <host>` pill is gone — opening
  // the site is a button on the Website field itself, like copy.
  group('C-04-03 — opening the site is a button on the Website field', () {
    for (final width in <double>[390, 1024]) {
      testWidgets('at $width, the Website field carries Open website', (
        tester,
      ) async {
        await pumpAt(tester, width);
        await openRecord(tester, 'Gmail');

        expect(find.byTooltip('Copy'), findsWidgets);
        expect(find.byTooltip('Open website'), findsOneWidget);
        // No pill labelled with the host or the URL survives.
        expect(find.textContaining('Open mail.google.com'), findsNothing);
      });
    }

    testWidgets('a bare domain still gets the button', (tester) async {
      // The fixture stores `sella.it` — no scheme, which is what users type.
      await pumpAt(tester, 1024);
      await openRecord(tester, 'Banca Sella');
      expect(find.byTooltip('Open website'), findsOneWidget);
    });

    testWidgets('a record with no URL offers no Open action', (tester) async {
      await pumpAt(tester, 1024);
      await openRecord(tester, 'Gmail');
      expect(find.byTooltip('Open website'), findsOneWidget);

      // Every fixture record ships with a URL, so the negative case is made
      // rather than assumed: clear the field in the editor and the action
      // must go with it.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('vault-detail-pane')),
          matching: find.byTooltip('Edit'),
        ),
      );
      await tester.pumpAndSettle();

      final urlField = find.ancestor(
        of: find.text('mail.google.com'),
        matching: find.byType(TextField),
      );
      await tester.enterText(urlField.first, '');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Open website'), findsNothing);
    });
  });

  group('C-04-05 — Duplicate', () {
    testWidgets('is offered from the list row', (tester) async {
      await pumpAt(tester, 1024);
      await tester.tap(find.byTooltip('Record actions').first);
      await tester.pumpAndSettle();
      expect(find.text('Duplicate'), findsOneWidget);
    });

    testWidgets('is offered from the detail overflow', (tester) async {
      await pumpAt(tester, 1024);
      await openRecord(tester, 'Gmail');
      await tester.tap(find.byTooltip('Record actions').last);
      await tester.pumpAndSettle();

      // The design's normative overflow inventory (DQ-5).
      expect(find.text('Move'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Duplicate'), findsOneWidget);
    });

    testWidgets('duplicating adds the copy to the list', (tester) async {
      await pumpAt(tester, 1024);
      await tester.tap(find.byTooltip('Record actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();

      // No confirmation: duplicating creates, it never destroys.
      expect(find.text('Banca Sella copy'), findsWidgets);
      expect(find.text('Banca Sella'), findsWidgets);
    });
  });

  // spec-020 (C-04-04): attachments have one home — a permanent section.
  // Amended 2026-11-13: the section lists the files themselves; the `Manage`
  // dialog it used to open is retired (vault_attachments_consistency_test).
  group('C-04-04 — attachments are a section, not an overflow item', () {
    for (final width in <double>[390, 1024]) {
      testWidgets('at $width a record with none shows the section, empty', (
        tester,
      ) async {
        await pumpAt(tester, width);
        await openRecord(tester, 'Gmail');

        expect(find.text('No attachments'), findsOneWidget);
        await tester.tap(find.byTooltip('Record actions').last);
        await tester.pumpAndSettle();
        // Once, as the section title — never as a menu item.
        expect(find.text('Attachments'), findsOneWidget);
      });
    }

    testWidgets('a record with two lists both', (tester) async {
      await pumpAt(tester, 1024);
      await openRecord(tester, 'GitHub');
      expect(find.byTooltip('Export attachment'), findsNWidgets(2));
    });
  });

  group('C-04-01 — the empty detail state', () {
    testWidgets('uses the design empty-state recipe', (tester) async {
      await pumpAt(tester, 1024);

      expect(find.text('No item selected'), findsOneWidget);

      // A 74 px feature circle, as the recycle bin's empty state has — not a
      // bare glyph, which is the shape this had drifted into.
      final circles = tester
          .widgetList<Container>(find.byType(Container))
          .where((container) {
            final decoration = container.decoration;
            return decoration is BoxDecoration &&
                decoration.shape == BoxShape.circle &&
                container.constraints?.maxWidth == 74;
          });
      expect(circles, hasLength(1));

      expect(
        find.descendant(
          of: find.byType(Container),
          matching: find.byType(KvIcon),
        ),
        findsWidgets,
      );
    });
  });
}
