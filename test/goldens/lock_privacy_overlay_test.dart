// spec-006 T4/T5/T16, AC3: goldens for screens 4 (Lock overlay) and 5
// (Privacy overlay), plus the AC3 non-negotiable — the privacy overlay
// renders literally zero `Text` widgets, so the OS app-switcher preview
// cannot leak anything.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart'
    show PrivacyOverlay, debugLockOverlayNowOverride;

import '../features/password_manager/presentation/screens/vault/vault_shell_test_utils.dart';
import 'golden_asset_warmup.dart';

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
    // The app logo decodes on the real event loop; warm it here so no test
    // pays the cold-cache cost and renders a blank logo (see helper doc).
    await warmUpGoldenAssets();
  });

  // "Locked for <n>" is wall-clock-dependent (lockedAt captured on lock,
  // "now" read at build time) — freeze both through the same seam so the
  // elapsed duration, and thus the rendered label, is deterministic
  // regardless of how long pumpAndSettle() takes. Matches the
  // debugEntryDetailNowOverride pattern (entry_editor_generator_test.dart).
  setUp(() {
    debugLockOverlayNowOverride = () => DateTime.utc(2026, 3, 12, 9, 30);
  });

  tearDown(() {
    debugLockOverlayNowOverride = DateTime.now;
  });

  tearDown(resetVaultShellTestDi);

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('lock_overlay_390x844.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      await pumpableVaultShell(debugInitiallyLocked: true),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // FR-3: three actions — biometrics (unavailable in the fake harness,
    // so only the password + close-database actions render), master
    // password, close database.
    expect(find.text('Use master password'), findsOneWidget);
    expect(find.text('Close the database instead'), findsOneWidget);
    expect(find.textContaining('Locked for'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('lock_overlay_390x844.png'),
    );
  });

  // AC3 non-negotiable, verified in true isolation: mounting `PrivacyOverlay`
  // alone (not the full `VaultScreen` behind it, which has plenty of its
  // own Text widgets merely covered up) and asserting a literal zero.
  testWidgets('PrivacyOverlay renders zero Text widgets (AC3)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.lightTheme, home: const PrivacyOverlay()),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('privacy_overlay_390x844.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      await pumpableVaultShell(debugInitiallyBackground: true),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('privacy_overlay_390x844.png'),
    );
  });
}
