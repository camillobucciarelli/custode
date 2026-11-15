// spec 024 T006 (023 T211): the entry detail's passkey section, phone and
// wide in both themes, plus the unusable state (plan.md "Golden inventory").
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';

import 'passkey_fixture.dart';

void main() {
  setUpPasskeyGoldens();

  const cases = <({String name, Size size})>[
    (name: 'vault_entry_passkey_section_390x844', size: Size(390, 844)),
    (name: 'vault_entry_passkey_section_wide_1024x768', size: Size(1024, 768)),
  ];

  for (final testCase in cases) {
    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      final name = '${testCase.name}_${themeMode.name}.png';
      testWidgets(name, (tester) async {
        await pumpPasskeyVault(
          tester,
          size: testCase.size,
          themeMode: themeMode,
        );
        await openPasskeySection(tester);

        expect(find.text('ES256 (ECDSA P-256)'), findsOneWidget);
        await expectPasskeyGolden(tester, name);
      });
    }
  }

  testWidgets('vault_entry_passkey_unusable_390x844_light.png', (tester) async {
    await pumpPasskeyVault(
      tester,
      unusableReason: VaultPasskeyUnusableReason.badKey,
    );
    await openPasskeySection(tester);

    expect(find.text('Unusable'), findsOneWidget);
    await expectPasskeyGolden(
      tester,
      'vault_entry_passkey_unusable_390x844_light.png',
    );
  });
}
