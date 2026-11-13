// P1-1: `VaultShellRouter._buildScoped` used to build a session's content
// with a BuildContext that was NOT yet a descendant of `VaultOperationScope`
// — any callback captured during that build (e.g. a dialog's Cancel/Confirm
// button) called `VaultOperationScope.of(context)` against an ancestor
// context and hit the "No VaultOperationScope found in context" assertion.
// These are live widget-tap tests through the real router, not source
// inspection: they fail on the pre-fix router shape and pass on the fix.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'entry_editor_generator_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetEntryTestDi);

  Future<void> pumpVault(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();
  }

  Future<void> openEntryAction(WidgetTester tester, String action) async {
    await tester.tap(find.text('GitHub').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Record actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(action).last);
    await tester.pumpAndSettle();
  }

  group('live VaultOperationScope callbacks', () {
    // Five widths: two phone breakpoints below the tablet cutoff, the
    // cutoff itself on both sides, and one clearly-tablet width — Delete
    // renders through a different host (route vs. sheet vs. pane) at each.
    for (final width in [390.0, 600.0, 707.0, 708.0, 1024.0]) {
      testWidgets('Delete confirmation cancels at $width', (tester) async {
        await pumpVault(tester, width);
        await openEntryAction(tester, 'Delete');

        expect(find.text('Confirm delete'), findsOneWidget);
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Confirm delete'), findsNothing);
        expect(find.text('GitHub'), findsWidgets);
      });

      testWidgets('Delete confirmation confirms at $width', (tester) async {
        await pumpVault(tester, width);
        await openEntryAction(tester, 'Delete');

        expect(find.text('Confirm delete'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Confirm delete'), findsNothing);
      });
    }

    // spec-019, amended 2026-08-31: the Folders sheet is retired — on the
    // phone the folder rows live in the file-system list, so the path is the
    // list row's `•••` -> `New folder`; what this test asserts — that the
    // create callback completes without leaving a dialog behind — is
    // unchanged.
    testWidgets('folder create callback completes from sheet', (tester) async {
      await pumpVault(tester, 390);
      // The location header's `•••` is the creation entry point.
      await tester.tap(find.byTooltip('Folder actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New folder'));
      await tester.pumpAndSettle();
      await tester.enterText(_folderNameField(), 'Created folder');
      await tester.tap(find.text('Create').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(AlertDialog, 'Create folder'), findsNothing);
    });

    // spec-019, amended 2026-08-30: the row's `•••` lives on the column's
    // own tree. The three row actions kept their exact labels (FR-006d,
    // Constitution VI).
    testWidgets('folder rename callback completes from pane', (tester) async {
      await pumpVault(tester, 1024);
      await tester.tap(find.byTooltip('Folder actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(_folderNameField(), 'Renamed vault');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(AlertDialog, 'Rename folder'), findsNothing);
    });

    testWidgets('Move callback completes from pane', (tester) async {
      await pumpVault(tester, 708);
      await openEntryAction(tester, 'Move');

      expect(find.text('Move to folder'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Move'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Move to folder'), findsNothing);
    });
  });
}

Finder _folderNameField() => find.byType(TextFormField).last;
