// spec 023 T211: the entry detail's passkey section (plan.md "Golden
// inventory"): 390x844 and 1024x768 in light and dark, plus one unusable
// passkey at 390x844 light. Same deterministic-render pattern as
// vault_entry_history_test.dart.
//
// Each case also asserts what the picture cannot: the section text and the
// fixed note read at 4.5:1 or better on the colour painted behind them, and
// no character of the fixture private key is on screen.
//
// Order-independence rules (AGENTS.md): `warmUpGoldenAssets()` in
// `setUpAll`; nothing here resolves `di.sl<T>()` in a `dispose()`.
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';
import 'golden_asset_warmup.dart';
import 'passkey_fixture.dart';
import 'secret_field_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    await loadGoldenFonts();
    await warmUpGoldenAssets();
    debugEntryDetailNowOverride = () => DateTime.utc(2026, 3, 12, 9, 30);
  });

  tearDownAll(() {
    debugEntryDetailNowOverride = DateTime.now;
  });

  tearDown(resetEntryTestDi);

  final section = find.byKey(const ValueKey('entry-detail-passkeys'));

  /// Opens the passkey record and brings the whole section into the frame:
  /// it sits below the record's own fields, so on the phone it starts under
  /// the fold.
  Future<void> openSection(
    WidgetTester tester, {
    required Size size,
    required ThemeMode themeMode,
    VaultPasskey? passkey,
  }) async {
    setGoldenViewport(tester, size);
    await tester.pumpWidget(
      await pumpableEntryScreen(
        harness: EntryTestHarness(
          snapshot: buildPasskeySnapshot(passkey: passkey),
        ),
        themeMode: themeMode,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(passkeyRecordTitle).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(section);
    await tester.pumpAndSettle();
  }

  void expectReadable(WidgetTester tester, Finder finder, String what) {
    expect(finder, findsOneWidget, reason: '$what is not on screen');
    final color = tester.widget<Text>(finder).style?.color;
    expect(color, isNotNull, reason: '$what has no explicit colour');
    for (final background in paintedBackgroundsBehind(tester, finder)) {
      expect(
        contrastRatio(color!, background),
        greaterThanOrEqualTo(4.5),
        reason: '$what on $background',
      );
    }
  }

  /// The detail runs a 1 s ticker: unmount before the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  const cases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'vault_entry_passkey_section_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'vault_entry_passkey_section_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'vault_entry_passkey_section_wide_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'vault_entry_passkey_section_wide_1024x768_dark.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.dark,
    ),
  ];

  for (final testCase in cases) {
    testWidgets(testCase.name, (tester) async {
      await openSection(
        tester,
        size: testCase.size,
        themeMode: testCase.themeMode,
      );

      expect(tester.takeException(), isNull);
      expect(section, findsOneWidget);
      // A usable passkey carries no "Unusable" tag.
      expect(find.text('Unusable'), findsNothing);
      expectNoKeyMaterialOnScreen();

      final mode = testCase.themeMode.name;
      expectReadable(
        tester,
        find.descendant(of: section, matching: find.text('Passkeys')),
        '$mode: the section heading',
      );
      expectReadable(
        tester,
        find.descendant(of: section, matching: find.text('webauthn.io')),
        '$mode: the relying party',
      );
      expectReadable(
        tester,
        find.descendant(
          of: section,
          matching: find.textContaining('not held in hardware key isolation'),
        ),
        '$mode: the fixed security note (FR-009)',
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
      await unmount(tester);
    });
  }

  testWidgets('vault_entry_passkey_unusable_390x844_light.png', (tester) async {
    await openSection(
      tester,
      size: const Size(390, 844),
      themeMode: ThemeMode.light,
      passkey: buildUnusableFixturePasskey(),
    );

    expect(tester.takeException(), isNull);
    // FR-012: said in words, with the reason.
    expect(
      find.descendant(of: section, matching: find.text('Unusable')),
      findsOneWidget,
    );
    expectNoKeyMaterialOnScreen();
    expectReadable(
      tester,
      find.descendant(
        of: section,
        matching: find.textContaining('its stored key cannot be read'),
      ),
      'light: the unusable explanation (FR-012)',
    );
    expectReadable(
      tester,
      find.descendant(
        of: section,
        matching: find.textContaining('not held in hardware key isolation'),
      ),
      'light: the fixed security note (FR-009)',
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('vault_entry_passkey_unusable_390x844_light.png'),
    );
    await unmount(tester);
  });
}
