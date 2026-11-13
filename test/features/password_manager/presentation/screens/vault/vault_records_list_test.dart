// spec-019 T033/T040/T042 — the records list is a list of records.
//
// Omitted axes (VR-002): behavioural, light theme only.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/widgets/kv_folder_tree.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_state.dart';

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

  /// The list pane's own subtree at wide widths; the whole screen on a phone.
  Finder listPane() => find.byKey(const ValueKey('vault-list-pane'));

  group('FR-007 / C-03-03 — no folder is a row of the list', () {
    for (final width in <double>[390, 800, 1024]) {
      testWidgets('at $width the list contains no folder tree', (tester) async {
        await pumpAt(tester, width);
        final inList = find.descendant(
          of: width >= 704 ? listPane() : find.byType(MaterialApp),
          matching: find.byType(KvFolderTree),
        );
        expect(
          inList,
          findsNothing,
          reason: 'the folder tree belongs to the folder surfaces, not here',
        );
      });
    }
  });

  group('FR-006i — the count line', () {
    // 2026-08-31: the count line is gone at every width — the search
    // field's own label ('Search N items') carries the count.
    testWidgets('the count lives in the search placeholder alone', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      expect(find.text('Search 3 items'), findsOneWidget);
      expect(find.textContaining('incl. subfolders'), findsNothing);
      expect(find.textContaining(' items · '), findsNothing);
    });
  });

  testWidgets('FR-008 — the search placeholder carries the count', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    expect(find.text('Search 3 items'), findsOneWidget);
  });

  // 2026-09-05: on a phone the browser lists the current folder's own
  // records, but a search runs over the whole subtree (FR-006h).
  testWidgets('a phone search reaches records in subfolders', (tester) async {
    await pumpAt(tester, 390);
    expect(find.text('GitHub'), findsNothing);

    await tester.enterText(find.byType(TextFormField).first, 'Git');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Gmail'), findsNothing);
  });

  testWidgets('FR-006j — a record on loan from a subfolder says so', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    expect(find.text('dev · in Devs'), findsOneWidget);
  });

  group('FR-009 — the sort control', () {
    testWidgets('offers exactly three orders and marks the active one', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      await tester.tap(find.byTooltip('Sort records'));
      await tester.pumpAndSettle();

      expect(find.text('Title A→Z'), findsOneWidget);
      expect(find.text('Title Z→A'), findsOneWidget);
      // 2026-08-31: the control is a circle button beside the search — the
      // active order is marked in the menu, no longer written next to it.
      expect(find.text('Username A→Z'), findsOneWidget);

      final checked = tester
          .widgetList<CheckedPopupMenuItem<VaultEntrySort>>(
            find.byType(CheckedPopupMenuItem<VaultEntrySort>),
          )
          .where((item) => item.checked);
      expect(checked, hasLength(1));
      expect(checked.single.value, VaultEntrySort.usernameAsc);
    });

    testWidgets('the choice survives a folder change and a search', (
      tester,
    ) async {
      await pumpAt(tester, 1024);
      await tester.tap(find.byTooltip('Sort records'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title Z→A'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Devs').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Git');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // The active order lives in the menu's checked item now.
      await tester.tap(find.byTooltip('Sort records'));
      await tester.pumpAndSettle();
      final checked = tester
          .widgetList<CheckedPopupMenuItem<VaultEntrySort>>(
            find.byType(CheckedPopupMenuItem<VaultEntrySort>),
          )
          .where((item) => item.checked);
      expect(checked.single.value, VaultEntrySort.titleDesc);
    });
  });

  // 2026-08-31: the phone Sort sheet is retired — one popup control beside
  // the search field, the same at every width.
  group('FR-009a / FR-014a / FR-014b — the phone sort control', () {
    testWidgets('opens from the header and offers the same three orders', (
      tester,
    ) async {
      await pumpAt(tester, 390);
      await tester.tap(find.byTooltip('Sort records'));
      await tester.pumpAndSettle();

      expect(
        find.byType(CheckedPopupMenuItem<VaultEntrySort>),
        findsNWidgets(3),
      );
      final selected = tester
          .widgetList<CheckedPopupMenuItem<VaultEntrySort>>(
            find.byType(CheckedPopupMenuItem<VaultEntrySort>),
          )
          .where((item) => item.checked);
      expect(selected, hasLength(1));
      expect(selected.single.value, VaultEntrySort.usernameAsc);
    });

    testWidgets('choosing applies immediately and dismisses', (tester) async {
      await pumpAt(tester, 390);
      await tester.tap(find.byTooltip('Sort records'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title A→Z'));
      await tester.pumpAndSettle();

      expect(find.byType(CheckedPopupMenuItem<VaultEntrySort>), findsNothing);
      // Title ascending. 2026-08-31: the narrow list browses like a file
      // system, so the root shows its OWN records (GitHub lives inside the
      // Devs folder row instead of being flattened into the root).
      final titles = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>()
          .where(
            (data) => const {'Banca Sella', 'GitHub', 'Gmail'}.contains(data),
          )
          .toList();
      expect(titles, ['Banca Sella', 'Gmail']);
      expect(find.text('Devs'), findsOneWidget);
    });

    testWidgets('carries no filter of any kind (FR-014b)', (tester) async {
      await pumpAt(tester, 390);
      await tester.tap(find.byTooltip('Sort records'));
      await tester.pumpAndSettle();

      // Scoped to the menu: the list is still on screen behind it, and the
      // folder rows there are the folder filter, which is exactly where
      // FR-014b says the folder filter belongs.
      final sheet = find.ancestor(
        of: find.byType(CheckedPopupMenuItem<VaultEntrySort>).first,
        matching: find.byType(Column),
      );
      for (final forbidden in const [
        'Folders',
        'Health',
        'Filter',
        'Advanced',
      ]) {
        expect(
          find.descendant(of: sheet, matching: find.text(forbidden)),
          findsNothing,
          reason: '$forbidden is not a sort order (FR-014b)',
        );
      }
    });
  });

  group('FR-010 / C-03-04 — one-tap copy from the row', () {
    testWidgets('copies without opening the record (SC-003)', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpAt(tester, 390);
      await tester.tap(find.byTooltip('Copy password').first);
      await tester.pumpAndSettle();

      expect(copied, [NavigationFixtureVaultKdbxService.bank.password]);
      // The confirmation is the detail's own string, byte for byte.
      expect(find.text('Copied password.'), findsOneWidget);
      // …and the record was never opened.
      expect(find.text('Copy username'), findsNothing);

      // Drain the guard's 30 s clear timer so the binding does not report it
      // as pending. Its presence is the point: the row's copy goes through
      // `ClipboardGuard`, so the same auto-clear covers it as the detail's.
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
    });

    testWidgets('the row still announces its health in words', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAt(tester, 390);

      expect(
        find.bySemanticsLabel(RegExp('Password healthy')),
        findsWidgets,
        reason: 'colour alone is not a signal (Constitution V)',
      );

      handle.dispose();
    });
  });

  group('FR-012 — the record actions survive at every width', () {
    for (final width in <double>[650, 1024]) {
      // The fourth, `Attachments`, was retired with its dialog: a record's
      // files are listed in its detail and edited in its editor.
      testWidgets('a list row still offers all three at $width', (
        tester,
      ) async {
        await pumpAt(tester, width);
        await tester.tap(find.byTooltip('Record actions').first);
        await tester.pumpAndSettle();

        for (final action in const ['Edit', 'Move', 'Delete']) {
          expect(find.text(action), findsWidgets, reason: action);
        }
      });
    }
  });
}
