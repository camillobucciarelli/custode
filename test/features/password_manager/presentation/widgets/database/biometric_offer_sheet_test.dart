import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/biometric_offer_sheet.dart';

import '../../screens/database_selection_unlock_test_utils.dart';

void main() {
  testWidgets('the title is a heading', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) =>
            showBiometricOfferSheet(context, databaseName: 'Personal'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('Unlock Personal with biometrics?')),
      isSemantics(isHeader: true),
    );
    handle.dispose();
  });
}
