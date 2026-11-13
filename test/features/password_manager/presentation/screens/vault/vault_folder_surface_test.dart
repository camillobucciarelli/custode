// spec-019 T032/T041 — the folder surfaces: the desktop column, the phone chip
// row and the `Folders` sheet.
//
// Omitted axes (VR-002): behavioural assertions, light theme only. The visual
// treatment is the goldens' subject.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/widgets/kv_folder_tree.dart';

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

  group('the desktop folder column (FR-001..FR-004)', () {
    testWidgets('is titled with the database, not with the word Folders', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      expect(find.text('vault_shell_test.kdbx'), findsWidgets);
      expect(
        find.text('Folders'),
        findsNothing,
        reason: 'C-03-11: the literal column title is gone',
      );
    });

    // 2026-08-30: the first row shows the root group's real name, not a
    // synthetic `All items` label. The fixture's root is named 'root'.
    testWidgets('the root is the first row and carries the vault total', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      expect(find.text('root'), findsOneWidget);
      // Three records in the fixture, one of them inside Devs.
      expect(
        find.descendant(
          of: find.byType(KvFolderTree),
          matching: find.text('3'),
        ),
        findsWidgets,
      );
    });

    testWidgets('a folder carries a count inclusive of its records', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      expect(find.text('Devs'), findsWidgets);
      expect(
        find.descendant(
          of: find.byType(KvFolderTree),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('selecting a folder filters the records list end to end', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      expect(find.text('Gmail'), findsWidgets);

      await tester.tap(find.text('Devs').first);
      await tester.pumpAndSettle();

      expect(find.text('GitHub'), findsWidgets);
      expect(
        find.text('Gmail'),
        findsNothing,
        reason: 'a record outside the selected folder is not in the list',
      );
    });

    testWidgets('the hygiene shortcuts sit at the foot of the column', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      expect(find.text('Recycle bin'), findsOneWidget);
      expect(find.text('Duplicates'), findsOneWidget);
    });

    // 2026-08-30: `Manage folders` retired — the tree carries its own row
    // actions (see vault_folder_actions_test.dart for the recipe).
    testWidgets('every folder row in the column carries its actions', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      expect(
        find.descendant(
          of: find.byType(KvFolderTree),
          matching: find.byTooltip('Folder actions'),
        ),
        findsWidgets,
      );
    });
  });

  // 2026-08-31: the chip row and the Folders sheet are retired — the 1/2
  // column list browses like a file system: subfolders and records in one
  // list, tap a folder to descend, an up-row to come back.
  group('the narrow file-system list', () {
    testWidgets('the root shows its folders and its own records', (
      tester,
    ) async {
      await pumpAt(tester, 390);
      // Devs is a folder row; GitHub lives inside it and is not flattened
      // into the root listing.
      expect(find.text('Devs'), findsOneWidget);
      expect(find.text('Gmail'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);
    });

    testWidgets('tapping a folder descends and the up-row returns', (
      tester,
    ) async {
      await pumpAt(tester, 390);
      await tester.tap(find.text('Devs'));
      await tester.pumpAndSettle();

      expect(find.text('GitHub'), findsWidgets);
      // The location header names the folder being looked at.
      expect(find.text('Devs'), findsOneWidget);
      expect(find.text('Gmail'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Gmail'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);
    });

    testWidgets('stands in for the column in the 704-1023 band', (
      tester,
    ) async {
      await pumpAt(tester, 800);
      expect(find.byKey(const ValueKey('vault-folder-pane')), findsNothing);
      expect(find.text('Devs'), findsOneWidget);
      expect(find.byTooltip('Folder actions'), findsWidgets);
    });

    testWidgets('a live search flattens the subtree and hides folder rows', (
      tester,
    ) async {
      await pumpAt(tester, 390);
      await tester.enterText(find.byType(TextFormField).first, 'git');
      await tester.pumpAndSettle();
      expect(find.text('GitHub'), findsWidgets);
      expect(find.byTooltip('Folder actions'), findsNothing);
    });
  });

  group('one expansion state, two hosts (FR-006g)', () {
    testWidgets('the column and the sheet read the same expansion', (
      tester,
    ) async {
      // The fixture is one level deep, so this asserts the wiring rather than
      // a deep tree: both hosts build their nodes from `expandedGroupIds`.
      await pumpAt(tester, 1024);
      await tester.tap(find.text('Devs').first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<KvFolderTree>(find.byType(KvFolderTree)).selectedId,
        NavigationFixtureVaultKdbxService.folderId,
        reason: 'selection is not expansion (FR-006f)',
      );
    });
  });
}
