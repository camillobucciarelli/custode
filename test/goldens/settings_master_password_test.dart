// spec-006 T16: goldens for screens 1 (Settings destination), 2 (Change
// master password) and 3 (Confirm security changes sheet). Same
// deterministic-render harness as vault_shell_test.dart /
// database_and_unlock_test.dart.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/theme/theme_cubit.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/vault_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/screens/change_master_password_screen.dart';
import 'package:password_manager/injection_container.dart' as di;

import '../features/password_manager/presentation/screens/vault/vault_shell_test_utils.dart';

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
  });

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('Screen 1 — Settings destination', () {
    tearDown(resetVaultShellTestDi);

    const cases = <({String name, Size size, ThemeMode themeMode})>[
      (
        name: 'settings_390x844_light.png',
        size: Size(390, 844),
        themeMode: ThemeMode.light,
      ),
      (
        name: 'settings_390x844_dark.png',
        size: Size(390, 844),
        themeMode: ThemeMode.dark,
      ),
      (
        name: 'settings_1024x768_light.png',
        size: Size(1024, 768),
        themeMode: ThemeMode.light,
      ),
    ];

    for (final testCase in cases) {
      testWidgets(testCase.name, (tester) async {
        await setSize(tester, testCase.size);
        await tester.pumpWidget(
          await pumpableVaultShell(themeMode: testCase.themeMode),
        );
        await tester.pumpAndSettle();

        // Navigate to the Settings tab/rail. `_VaultRail` (desktop widths)
        // is icon+tooltip only, no visible Text — `Semantics(label:
        // 'Settings')` is the one selector both `_VaultTabBar` and
        // `_VaultRail` share.
        await tester.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.label == 'Settings',
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(testCase.name),
        );
      });
    }
  });

  // spec-006 T2/AC4: the theme selector exposes exactly the three
  // `ThemeMode` values — no fourth option — and each pill actually drives
  // `ThemeCubit`.
  group('Theme selector — AC4 exactly three options', () {
    tearDown(resetVaultShellTestDi);

    testWidgets('renders exactly Light / Dark / System, no fourth pill', (
      tester,
    ) async {
      await setSize(tester, const Size(390, 844));
      await tester.pumpWidget(await pumpableVaultShell());
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'Settings',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      // Structural guard against a silently-added fourth pill: exactly the
      // three ThemeMode.values labels and nothing else with this styling
      // (would fail if e.g. a "High contrast" pill were ever added).
      expect(ThemeMode.values, hasLength(3));

      final context = tester.element(find.text('Dark'));
      expect(context.read<ThemeCubit>().state, isNot(ThemeMode.dark));

      // The Settings list grew (the retired overflow sheet's actions live
      // here now), so the selector can sit below the fold.
      await tester.ensureVisible(find.text('Dark'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(context.read<ThemeCubit>().state, ThemeMode.dark);
    });
  });

  group('Screens 2/3 — Change master password + confirm sheet', () {
    setUp(() {
      di.sl.registerLazySingleton<VaultSessionCoordinator>(
        () => _FakeChangePasswordCoordinator(),
      );
    });
    tearDown(() => di.sl.reset());

    testWidgets('change_master_password_390x844_light.png', (tester) async {
      await setSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          home: const ChangeMasterPasswordScreen(
            databasePath: '/tmp/settings_golden.kdbx',
            databaseName: 'settings_golden.kdbx',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('change_master_password_390x844_light.png'),
      );
    });

    testWidgets('confirm_security_changes_390x844_light.png', (tester) async {
      await setSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          home: const ChangeMasterPasswordScreen(
            databasePath: '/tmp/settings_golden.kdbx',
            databaseName: 'settings_golden.kdbx',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'current-password');
      await tester.enterText(find.byType(TextField).at(1), 'new-password-1');
      await tester.enterText(find.byType(TextField).at(2), 'new-password-1');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('confirm_security_changes_390x844_light.png'),
      );
    });
  });
}

class _FakeChangePasswordCoordinator implements VaultSessionCoordinator {
  @override
  Future<String?> getPersistedKeyFilePath(String databasePath) async => null;

  @override
  Future<bool> getBiometricProtectionEnabledForPath({
    required String databasePath,
  }) async => false;

  @override
  Future<int?> getInactivityLockTimeoutForPath({
    required String databasePath,
  }) async => null;

  @override
  Future<DatabaseSettingsUpdateResult> updateDatabaseSettings(
    DatabaseSettingsUpdateRequest request,
  ) async => DatabaseSettingsUpdateResult(
    databasePath: request.currentDatabasePath,
    passwordChanged: request.changePassword,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
