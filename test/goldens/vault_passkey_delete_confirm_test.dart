// spec 023 T211: the confirmation shown before a passkey is deleted
// (plan.md "Golden inventory": 390x844 light). Same deterministic-render
// pattern as vault_entry_history_test.dart.
//
// The golden stops at the confirmation: nothing is confirmed, so no delete
// event reaches the bloc.
//
// Order-independence rules (AGENTS.md): `warmUpGoldenAssets()` in
// `setUpAll`; nothing here resolves `di.sl<T>()` in a `dispose()`.
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';
import 'golden_asset_warmup.dart';
import 'passkey_fixture.dart';

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

  testWidgets('vault_passkey_delete_confirm_390x844_light.png', (tester) async {
    setGoldenViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      await pumpableEntryScreen(
        harness: EntryTestHarness(snapshot: buildPasskeySnapshot()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(passkeyRecordTitle).first);
    await tester.pumpAndSettle();

    final delete = find.widgetWithText(TextButton, 'Delete passkey');
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // FR-010: the confirmation names the site, the account and the record,
    // and says the passkey cannot be recovered.
    expect(find.text('Delete this passkey?'), findsOneWidget);
    final body = find.textContaining('A passkey cannot be recovered');
    expect(body, findsOneWidget);
    final bodyText = tester.widget<Text>(body).data!;
    expect(bodyText, contains('webauthn.io'));
    expect(bodyText, contains(passkeyRecordUsername));
    expect(bodyText, contains(passkeyRecordTitle));
    expectNoKeyMaterialOnScreen();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('vault_passkey_delete_confirm_390x844_light.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
