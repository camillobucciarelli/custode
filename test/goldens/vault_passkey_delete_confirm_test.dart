// spec 024 T006 (023 T211): the delete-passkey confirmation, which names the
// site and says what is lost (plan.md "Golden inventory": 390x844, light).
import 'package:flutter_test/flutter_test.dart';

import 'passkey_fixture.dart';

void main() {
  setUpPasskeyGoldens();

  testWidgets('vault_passkey_delete_confirm_390x844_light.png', (tester) async {
    await pumpPasskeyVault(tester);
    await openPasskeySection(tester);
    await tester.ensureVisible(find.text('Delete passkey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete passkey'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this passkey?'), findsOneWidget);
    expect(find.textContaining('cannot be recovered'), findsOneWidget);
    await expectPasskeyGolden(
      tester,
      'vault_passkey_delete_confirm_390x844_light.png',
    );
  });
}
