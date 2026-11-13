// spec-002 T13: the four shell goldens (spec.md "Exact golden inventory").
//
// spec-018 VR-001 adds three wide cases at 1024x768 in light and dark, using
// the same deterministic harness: a record selected in the persistent detail
// pane, the empty detail state, and the editor hosted in that pane. The two
// existing 1024 goldens were re-recorded because the vault rail is now 72
// (was a drifted 76) and the list column a fixed 330 (was a 330-352 clamp).
// Every 390x844 golden is FROZEN by VR-003 — a mobile golden that moves is a
// US5 regression, not a golden to re-record.
//
// Uses the same deterministic-render harness pattern as
// organic_theme_gallery_test.dart (spec-001): fixed physical size/DPR,
// disabled animations, no text scaling, explicit font loading.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import '../features/password_manager/presentation/screens/vault/vault_navigation_fixture.dart';
import '../features/password_manager/presentation/screens/vault/vault_shell_test_utils.dart';

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

  const cases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'vault_shell_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'vault_shell_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'vault_shell_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'vault_shell_1024x768_dark.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.dark,
    ),
  ];

  // VR-001: the wide cases. `vault_wide_empty_detail` is the same pump as
  // `vault_shell_1024x768` but named for what it proves — FR-002c, that the
  // detail pane is persistent and shows its empty state before anything is
  // selected, rather than appearing only once a surface opens.
  const wideCases = <({String name, ThemeMode themeMode, bool selectRecord})>[
    (
      name: 'vault_wide_empty_detail_1024x768_light.png',
      themeMode: ThemeMode.light,
      selectRecord: false,
    ),
    (
      name: 'vault_wide_empty_detail_1024x768_dark.png',
      themeMode: ThemeMode.dark,
      selectRecord: false,
    ),
    (
      name: 'vault_wide_record_selected_1024x768_light.png',
      themeMode: ThemeMode.light,
      selectRecord: true,
    ),
    (
      name: 'vault_wide_record_selected_1024x768_dark.png',
      themeMode: ThemeMode.dark,
      selectRecord: true,
    ),
  ];

  for (final testCase in wideCases) {
    testWidgets(testCase.name, (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        await pumpableVaultShell(
          themeMode: testCase.themeMode,
          vaultKdbxService: NavigationFixtureVaultKdbxService(),
        ),
      );
      await tester.pumpAndSettle();

      if (testCase.selectRecord) {
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

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }

  testWidgets('vault_wide_editor_in_pane_1024x768_light.png', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      await pumpableVaultShell(
        themeMode: ThemeMode.light,
        vaultKdbxService: NavigationFixtureVaultKdbxService(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .descendant(
            of: find.byKey(const ValueKey('vault-list-pane')),
            matching: find.text('Gmail'),
          )
          .first,
    );
    await tester.pumpAndSettle();

    // FR-009a: the editor takes the detail pane, carries the record's title
    // in its header, and the row stays selected in the list beside it.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('vault-detail-pane')),
        matching: find.byTooltip('Edit'),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('vault_wide_editor_in_pane_1024x768_light.png'),
    );
  });

  testWidgets('vault_wide_editor_in_pane_1024x768_dark.png', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      await pumpableVaultShell(
        themeMode: ThemeMode.dark,
        vaultKdbxService: NavigationFixtureVaultKdbxService(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .descendant(
            of: find.byKey(const ValueKey('vault-list-pane')),
            matching: find.text('Gmail'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('vault-detail-pane')),
        matching: find.byTooltip('Edit'),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('vault_wide_editor_in_pane_1024x768_dark.png'),
    );
  });

  for (final testCase in cases) {
    testWidgets(testCase.name, (tester) async {
      tester.view.physicalSize = testCase.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        await pumpableVaultShell(themeMode: testCase.themeMode),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }
}
