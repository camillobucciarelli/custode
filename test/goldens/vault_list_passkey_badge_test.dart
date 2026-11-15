// spec 024 T006 (023 T211): the records list badging the record that holds
// a passkey (plan.md "Golden inventory": 390x844, dark).
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'passkey_fixture.dart';

void main() {
  setUpPasskeyGoldens();

  testWidgets('vault_list_passkey_badge_390x844_dark.png', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPasskeyVault(tester, themeMode: ThemeMode.dark);

    // Constitution V: the badge is a word, not only a glyph, and only the
    // record with a passkey carries it.
    expect(find.bySemanticsLabel(RegExp('Passkey')), findsOneWidget);
    semantics.dispose();
    await expectPasskeyGolden(
      tester,
      'vault_list_passkey_badge_390x844_dark.png',
    );
  });
}
