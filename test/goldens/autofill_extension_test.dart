// spec-006 T16: goldens for screens 6 (iOS autofill enablement), 7 (Link
// AutoFill credential sheet), 8 (Browser setup, 3 steps) and 9
// (Host-not-found diagnostic).
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/data/services/browser_setup_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/screens/autofill_enablement_screen.dart';
import 'package:password_manager/features/password_manager/presentation/screens/browser_setup_screen.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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

  testWidgets('autofill_enablement_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: const AutofillEnablementScreen(entryCount: 128),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('autofill_enablement_390x844_light.png'),
    );
  });

  group('Screen 7 — Link AutoFill credential sheet', () {
    tearDown(resetVaultShellTestDi);

    testWidgets('link_autofill_credential_390x844_light.png', (tester) async {
      await setSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        await pumpableVaultShell(
          vaultKdbxService: _OneEntryVaultKdbxService(),
          appleAutofillV2Coordinator: _OnePendingAssociationCoordinator(),
        ),
      );
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold).first);
      context.read<VaultBloc>().add(
        const RefreshAppleAutofillPendingAssociations(),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Link AutoFill credential?'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(find.text('Link'), findsOneWidget);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('link_autofill_credential_390x844_light.png'),
      );
    });
  });

  testWidgets('browser_setup_1024x768_light.png', (tester) async {
    await setSize(tester, const Size(1024, 768));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: BrowserSetupScreen(service: _FakeBrowserSetupService()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('browser_setup_1024x768_light.png'),
    );
  });

  testWidgets('host_not_found_diagnostic_1024x768_light.png', (tester) async {
    await setSize(tester, const Size(1024, 768));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: HostNotFoundDiagnosticScreen(service: _FakeBrowserSetupService()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // T9: names the real native-host id, not a placeholder.
    expect(
      find.textContaining('dev.camillobucciarelli.keyvault_native_host'),
      findsOneWidget,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('host_not_found_diagnostic_1024x768_light.png'),
    );
  });
}

// Same shape as `_FakeBrowserSetupService` in
// `browser_setup_screen_test.dart` — subclassing (not implementing) lets the
// pure/no-IO members (like `nativeHostInstallCommandText`) run for real
// while stubbing out the ones that would otherwise touch a socket/process.
class _FakeBrowserSetupService extends BrowserSetupService {
  @override
  bool get canRunNativeHostInstaller => true;

  @override
  Future<BridgeCheckResult> checkBridgeConnection() async {
    return BridgeCheckResult.notRunning;
  }
}

class _OneEntryVaultKdbxService implements VaultKdbxService {
  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async {
    const entry = VaultEntry(
      id: 'entry-1',
      groupId: 'root',
      title: 'Trenitalia',
      username: 'camillo@bucciarelli.dev',
      password: 'test-fixture-value-001',
      url: 'https://app.trenitalia.it',
      notes: '',
    );
    return const VaultSnapshot(
      rootGroupId: 'root',
      currentGroupId: 'root',
      groups: [],
      entries: [entry],
      allEntries: [entry],
    );
  }

  @override
  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OnePendingAssociationCoordinator
    implements AppleAutofillV2CoordinatorContract {
  @override
  Future<void> publishVault({
    required String databasePath,
    required List<VaultEntry> entries,
  }) async {}

  @override
  Future<void> clearCredentials({String? databasePath}) async {}

  @override
  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  }) async => [
    AppleAutofillV2PendingAssociation(
      id: 'assoc-1',
      databaseId: 'db-1',
      entryId: 'entry-1',
      serviceIdentifierType: 'domain',
      serviceIdentifierValue: 'app.trenitalia.it',
      displayService: 'app.trenitalia.it',
      createdAtEpochMs: DateTime(2024).millisecondsSinceEpoch,
    ),
  ];

  @override
  Future<void> clearPendingAssociations({List<String>? ids}) async {}
}
