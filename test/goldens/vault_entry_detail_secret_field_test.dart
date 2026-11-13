// spec 023 T104: a secret custom field in the entry detail, masked, beside
// a plain one. Same deterministic-render pattern as
// entry_editor_generator_test.dart.
//
// Order-independence rules (AGENTS.md): `warmUpGoldenAssets()` in
// `setUpAll`; nothing here resolves `di.sl<T>()` in a `dispose()`.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';
import 'golden_asset_warmup.dart';
import 'secret_field_fixture.dart';

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
    await warmUpGoldenAssets();
    debugEntryDetailNowOverride = () => DateTime.utc(2026, 3, 12, 9, 30);
  });

  tearDownAll(() {
    debugEntryDetailNowOverride = DateTime.now;
  });

  tearDown(resetEntryTestDi);

  testWidgets('vault_entry_detail_secret_field_390x844_light.png', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      await pumpableEntryScreen(
        harness: EntryTestHarness(snapshot: buildSecretFieldSnapshot()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wallet').first);
    await tester.pumpAndSettle();

    expect(find.text(secretFieldValue), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('vault_entry_detail_secret_field_390x844_light.png'),
    );
    // The detail runs a 1 s ticker: unmount before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
