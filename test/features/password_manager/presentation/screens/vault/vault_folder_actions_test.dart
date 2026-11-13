// 2026-08-30 — `Manage folders` retired: the folder tree carries its own
// per-row `•••` everywhere it appears. These tests pin what replaced the
// dialog: same actions, same recipe, no separate surface and no `Manage`
// entry point anywhere.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetVaultShellTestDi);

  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      await pumpableVaultShell(
        vaultKdbxService: NavigationFixtureVaultKdbxService(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the Manage entry point is gone on desktop', (tester) async {
    await pumpAt(tester, 1024);
    expect(find.text('Manage'), findsNothing);
  });

  testWidgets('the Manage entry point is gone on the phone', (tester) async {
    await pumpAt(tester, 390);
    expect(find.text('Manage'), findsNothing);
  });

  testWidgets('the desktop column rows carry the one row-action recipe', (
    tester,
  ) async {
    await pumpAt(tester, 1024);

    await tester.tap(find.byTooltip('Folder actions').last);
    await tester.pumpAndSettle();

    expect(find.text('New folder'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    // The retired path: creating a folder *inside* another one.
    expect(find.text('Add subfolder'), findsNothing);
  });

  testWidgets('the root row keeps Rename and drops what cannot apply', (
    tester,
  ) async {
    await pumpAt(tester, 1024);

    // The first row is the vault's own root, under its real name: renamable,
    // but
    // there is nowhere to move it to and deleting it would delete the vault.
    await tester.tap(find.byTooltip('Folder actions').first);
    await tester.pumpAndSettle();

    expect(find.text('New folder'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Move'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('Rename from the column opens the existing dialog', (
    tester,
  ) async {
    await pumpAt(tester, 1024);

    await tester.tap(find.byTooltip('Folder actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(find.text('Rename folder'), findsOneWidget);
  });

  // 2026-08-31: the Folders sheet is retired — on the phone the folder rows
  // live in the list itself, carrying the same `•••` recipe.
  testWidgets('the phone list folder rows carry the same menus', (
    tester,
  ) async {
    await pumpAt(tester, 390);
    expect(find.byTooltip('Folder actions'), findsWidgets);

    await tester.tap(find.byTooltip('Folder actions').last);
    await tester.pumpAndSettle();
    expect(find.text('New folder'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename folder'), findsOneWidget);
  });
}
