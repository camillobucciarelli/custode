// spec 023 T211: the records list with the passkey badge on the one record
// that holds a passkey (plan.md "Golden inventory": 390x844 dark). Same
// deterministic-render pattern as vault_entry_history_test.dart.
//
// Order-independence rules (AGENTS.md): `warmUpGoldenAssets()` in
// `setUpAll`; nothing here resolves `di.sl<T>()` in a `dispose()`.
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';
import 'golden_asset_warmup.dart';
import 'passkey_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    await loadGoldenFonts();
    await warmUpGoldenAssets();
  });

  tearDown(resetEntryTestDi);

  testWidgets('vault_list_passkey_badge_390x844_dark.png', (tester) async {
    final semantics = tester.ensureSemantics();
    setGoldenViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      await pumpableEntryScreen(
        harness: EntryTestHarness(snapshot: buildPasskeySnapshot()),
        themeMode: ThemeMode.dark,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(passkeyRecordTitle), findsOneWidget);
    // FR-011: exactly one of the five records holds a passkey, and the badge
    // is a word for assistive technology, not only a glyph (Constitution V).
    // Matched as a pattern because the badge merges into the row's label.
    expect(find.bySemanticsLabel(RegExp(r'\bPasskey\b')), findsOneWidget);
    expectNoKeyMaterialOnScreen();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('vault_list_passkey_badge_390x844_dark.png'),
    );
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
