// spec 023 T104: the editor's per-field Secret switch, light and dark, with
// the toggle label's contrast asserted (Constitution V). Same deterministic-
// render pattern as entry_editor_generator_test.dart.
//
// Order-independence rules (AGENTS.md): `warmUpGoldenAssets()` in
// `setUpAll`; nothing here resolves `di.sl<T>()` in a `dispose()`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/custode_colors.dart';
import 'package:password_manager/core/widgets/kv_switch.dart';
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

  Future<void> openWalletEditor(
    WidgetTester tester, {
    required ThemeMode themeMode,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      await pumpableEntryScreen(
        harness: EntryTestHarness(snapshot: buildSecretFieldSnapshot()),
        themeMode: themeMode,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wallet').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    // The custom fields sit at the foot of the form: bring the secret row
    // (switch on, value obscured) into the frame.
    await tester.ensureVisible(find.byType(KvSwitch).first);
    await tester.pumpAndSettle();
  }

  for (final themeMode in ThemeMode.values.where(
    (m) => m != ThemeMode.system,
  )) {
    final name = 'editor_custom_field_secret_390x844_${themeMode.name}.png';
    testWidgets(name, (tester) async {
      await openWalletEditor(tester, themeMode: themeMode);

      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(name));

      // The toggle label reads at 4.5:1 or better on its card.
      final label = find.text('Secret').first;
      final colors = Theme.of(tester.element(label))
          .extension<CustodeColors>()!;
      final style = tester.widget<Text>(label).style!;
      expect(
        contrastRatio(style.color!, colors.surface),
        greaterThanOrEqualTo(4.5),
        reason: '${themeMode.name}: Secret label on the field card',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
