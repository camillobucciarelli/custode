// spec-003: DatabaseUnlockScreen behaviour/copy/layout.
//
// Successful unlock navigates to `VaultScreen`, which needs its own large
// DI graph (VaultBloc, VaultSessionCoordinator, ...) outside spec-003's
// scope to fake here. Tests that need to observe a "would succeed" submit
// use `FakeUnlockDatabaseUseCase.hang = true` so the bloc reaches
// `decrypting` (proving the submit dispatched with the right arguments)
// without ever completing into `unlocked` and attempting that navigation.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/errors/database_access_failure.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_event.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_state.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/repositories/autofill_ports.dart';
import 'package:password_manager/features/password_manager/domain/services/apple_autofill_v2_payload_mapper.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/android_autofill_save_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/pending_passkey_adoption_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/core/widgets/kv_circle_icon_button.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/screens/database_selection_screen.dart';
import 'package:password_manager/features/password_manager/presentation/utils/platform_utils.dart';
import 'package:password_manager/injection_container.dart' as di;

import '../bloc/vault/vault_bloc_harness.dart'
    show FakePendingPasskeyAdoptionCoordinator;
import 'database_selection_unlock_test_utils.dart';

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

  tearDown(resetDatabaseTestDi);

  const path = '/tmp/personal.kdbx';
  final records = [
    DatabaseRecord(
      databaseId: 'db-1',
      canonicalPath: path,
      displayName: 'personal.kdbx',
      sourceType: DatabaseSourceType.local,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ),
  ];
  const profiles = {
    'db-1': DatabaseSecurityProfile(
      databaseId: 'db-1',
      biometricProtectionEnabled: false,
    ),
  };

  // spec-016, from PR review: `hasPendingCapture()` claims the native token
  // before its future completes, so from that moment this screen owns it. If the
  // screen is gone by the time the answer arrives, nothing shows the notice and
  // nothing runs dispose's abandon — the capture would then outlive the unlock
  // the user walked away from and be offered at the next one, of a possibly
  // different database.
  group('Pending autofill capture', () {
    testWidgets('a capture claimed after the screen is gone is abandoned', (
      tester,
    ) async {
      final client = _CapturingAutofillClient();
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      di.sl.registerLazySingleton<AndroidAutofillSaveCoordinator>(
        () => AndroidAutofillSaveCoordinator(
          client: client,
          mapper: const AppleAutofillV2PayloadMapper(),
          vaultKdbxService: _UnusedVaultKdbxService(),
          sessionSecretHolder: SessionSecretHolder(),
        ),
      );
      addTearDown(() => di.sl.unregister<AndroidAutofillSaveCoordinator>());

      await tester.pumpWidget(result.widget);
      // The screen is mounted and waiting on the claim.
      expect(client.resolved, isEmpty);

      // It goes away before the answer arrives.
      await tester.pumpWidget(const SizedBox.shrink());
      client.tokenCompleter.complete('token-1');
      await tester.pumpAndSettle();

      expect(client.resolved, [
        ('token-1', AndroidAutofillCaptureOutcome.cancelled),
      ]);
    });

    testWidgets('nothing pending resolves nothing', (tester) async {
      final client = _CapturingAutofillClient()..tokenCompleter.complete(null);
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      di.sl.registerLazySingleton<AndroidAutofillSaveCoordinator>(
        () => AndroidAutofillSaveCoordinator(
          client: client,
          mapper: const AppleAutofillV2PayloadMapper(),
          vaultKdbxService: _UnusedVaultKdbxService(),
          sessionSecretHolder: SessionSecretHolder(),
        ),
      );
      addTearDown(() => di.sl.unregister<AndroidAutofillSaveCoordinator>());

      await tester.pumpWidget(result.widget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      expect(client.resolved, isEmpty);
    });
  });

  // Passkeys-all-platforms FR-9: the pre-unlock banner.
  group('Waiting passkeys banner', () {
    Future<void> pumpWith(WidgetTester tester, int? waiting) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      if (waiting != null) {
        di.sl.registerLazySingleton<PendingPasskeyAdoptionCoordinator>(
          () => FakePendingPasskeyAdoptionCoordinator(waiting: waiting),
        );
      }
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
    }

    testWidgets('shows the count before unlock', (tester) async {
      await pumpWith(tester, 2);

      expect(find.text('2 passkeys are waiting'), findsOneWidget);
      expect(find.textContaining('Unlock to add them'), findsOneWidget);
    });

    testWidgets('singular wording for one', (tester) async {
      await pumpWith(tester, 1);

      expect(find.text('1 passkey is waiting'), findsOneWidget);
    });

    testWidgets('hidden at zero', (tester) async {
      await pumpWith(tester, 0);

      expect(find.textContaining('waiting'), findsNothing);
    });

    testWidgets('hidden where no coordinator is registered', (tester) async {
      await pumpWith(tester, null);

      expect(find.textContaining('waiting'), findsNothing);
    });
  });

  group('Submit', () {
    testWidgets('dispatches the entered password to the unlock use case', (
      tester,
    ) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.unlockUseCase.hang = true;

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextFormField),
        'kv-test-only-not-a-real-password',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(result.harness.unlockUseCase.callCount, 1);
      expect(
        result.harness.unlockUseCase.lastPassword,
        'kv-test-only-not-a-real-password',
      );
      expect(result.harness.unlockUseCase.lastDatabasePath, path);
    });

    testWidgets('submit button is disabled with no credentials', (
      tester,
    ) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      final buttonFinder = find.ancestor(
        of: find.text('Unlock'),
        matching: find.byType(ElevatedButton),
      );
      expect(tester.widget<ElevatedButton>(buttonFinder).onPressed, isNull);
    });
  });

  group('Biometric gate', () {
    testWidgets('failed authentication does not unlock and offers Retry', (
      tester,
    ) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: const {
          'db-1': DatabaseSecurityProfile(
            databaseId: 'db-1',
            biometricProtectionEnabled: true,
          ),
        },
        biometricAvailable: true,
        hangBiometricAuthenticate: true,
      );

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(result.harness.unlockUseCase.callCount, 0);
      expect(find.text('Retry'), findsOneWidget);

      final blocContext = tester.element(find.byType(Scaffold).first);
      expect(
        blocContext.read<DatabaseUnlockBloc>().state.phase,
        UnlockPhase.biometricGate,
      );
    });

    testWidgets(
      '"Use master password instead" escapes the gate to the credential form',
      (tester) async {
        final result = await pumpableUnlockScreen(
          databasePath: path,
          records: records,
          securityProfiles: const {
            'db-1': DatabaseSecurityProfile(
              databaseId: 'db-1',
              biometricProtectionEnabled: true,
            ),
          },
          biometricAvailable: true,
          biometricAuthenticateResult: false,
        );
        result.harness.unlockUseCase.hang = true;

        await tester.pumpWidget(result.widget);
        await tester.pumpAndSettle();

        expect(find.text('Use master password instead'), findsOneWidget);
        await tester.tap(find.text('Use master password instead'));
        await tester.pumpAndSettle();

        // Manual credential form is now reachable and submits normally.
        await tester.enterText(find.byType(TextFormField), 'kv-test-only');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Unlock'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(tester.takeException(), isNull);
        expect(result.harness.unlockUseCase.callCount, 1);
        expect(result.harness.unlockUseCase.lastPassword, 'kv-test-only');

        // Persisted biometric requirement untouched.
        expect(
          result
              .harness
              .securityRepository
              .profiles['db-1']!
              .biometricProtectionEnabled,
          isTrue,
        );
      },
    );
  });

  group('Key file flow', () {
    testWidgets('selecting then removing a key file updates the form', (
      tester,
    ) async {
      // Phone viewport: the form is one layout on every width, this just
      // exercises the narrowest one.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      const keyPath = '/tmp/personal.key';
      result.harness.fileRepository.existingPaths.add(keyPath);

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      final bloc = tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseUnlockBloc>();

      bloc.add(const UpdateKeyFilePath(keyPath));
      await tester.pumpAndSettle();
      expect(find.text('personal.key'), findsOneWidget);
      expect(find.byTooltip('Remove key file'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove key file'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Unlock'), findsOneWidget);
      // The slot is always on screen: empty it offers to add one.
      expect(find.text('Add a key file'), findsOneWidget);
    });
  });

  group('Ready-phase error message', () {
    testWidgets('a generic (untyped) unlock error is shown inline', (
      tester,
    ) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.unlockUseCase.error = StateError('boom');

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'x');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.text('Unable to unlock database with provided credentials.'),
        findsOneWidget,
      );
    });
  });

  group('Biometric offer after a manual unlock (spec 025 FR-U6)', () {
    // The screen keeps the vault route out of reach: a hung navigation is
    // not needed because the sheet resolves first and the vault route only
    // needs the DI the harness already registers.
    final localRecord = DatabaseRecord(
      databaseId: 'db-1',
      canonicalPath: path,
      displayName: 'Personal',
      sourceType: DatabaseSourceType.local,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final remoteRecord = DatabaseRecord(
      databaseId: 'db-1',
      canonicalPath: path,
      displayName: 'Personal',
      sourceType: DatabaseSourceType.drive,
      sourceRef: 'remote-1',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    Future<DatabaseTestHarness> pumpAndUnlock(
      WidgetTester tester,
      DatabaseRecord record, {
      bool biometricAvailable = true,
      Map<String, DatabaseSecurityProfile> securityProfiles = profiles,
      String password = 'kv-test-only',
    }) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: [record],
        securityProfiles: securityProfiles,
        biometricAvailable: biometricAvailable,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      if (securityProfiles['db-1']?.biometricProtectionEnabled ?? false) {
        await tester.tap(find.text('Use master password instead'));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byType(TextFormField), password);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock'));
      // The spinner behind the sheet animates forever: no pumpAndSettle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      return result.harness;
    }

    for (final (label, record) in [
      ('local', localRecord),
      ('remote', remoteRecord),
    ]) {
      testWidgets('$label database: Enable stores the credential at once, '
          'once', (tester) async {
        final harness = await pumpAndUnlock(tester, record);

        expect(find.text('Unlock Personal with biometrics?'), findsOneWidget);
        expect(
          find.text('You can change this anytime in Settings.'),
          findsOneWidget,
        );
        expect(harness.sessionRepository.masterPasswords, isEmpty);

        await tester.tap(find.text('Enable'));
        await tester.pumpAndSettle();

        expect(harness.sessionRepository.masterPasswords, {
          'db-1': 'kv-test-only',
        });
        final saved = harness.securityRepository.profiles['db-1']!;
        expect(saved.biometricProtectionEnabled, isTrue);
        expect(saved.biometricOfferAnswered, isTrue);
        expect(find.text('Unlock Personal with biometrics?'), findsNothing);
      });
    }

    testWidgets('Not now counts as answered and writes nothing', (
      tester,
    ) async {
      final harness = await pumpAndUnlock(tester, localRecord);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(harness.sessionRepository.masterPasswords, isEmpty);
      final saved = harness.securityRepository.profiles['db-1']!;
      expect(saved.biometricProtectionEnabled, isFalse);
      expect(saved.biometricOfferAnswered, isTrue);
    });

    testWidgets('dismissing the sheet counts as answered', (tester) async {
      final harness = await pumpAndUnlock(tester, localRecord);

      // Tap the barrier above the sheet.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(harness.sessionRepository.masterPasswords, isEmpty);
      expect(
        harness.securityRepository.profiles['db-1']!.biometricOfferAnswered,
        isTrue,
      );
    });

    testWidgets('not shown again once answered', (tester) async {
      await pumpAndUnlock(
        tester,
        localRecord,
        securityProfiles: const {
          'db-1': DatabaseSecurityProfile(
            databaseId: 'db-1',
            biometricOfferAnswered: true,
          ),
        },
      );

      expect(find.text('Unlock Personal with biometrics?'), findsNothing);
      expect(find.text('vault:$path'), findsOneWidget);
    });

    testWidgets('not shown without device biometrics', (tester) async {
      await pumpAndUnlock(tester, localRecord, biometricAvailable: false);

      expect(find.text('Unlock Personal with biometrics?'), findsNothing);
      expect(find.text('vault:$path'), findsOneWidget);
    });

    testWidgets('not shown on a platform without biometric unlock', (
      tester,
    ) async {
      debugPlatformCapabilities = const PlatformCapabilities(
        supportsRemoteSource: false,
        supportsBiometricUnlock: false,
        persistsDatabases: false,
      );
      addTearDown(() => debugPlatformCapabilities = null);

      await pumpAndUnlock(tester, localRecord);

      expect(find.text('Unlock Personal with biometrics?'), findsNothing);
    });

    testWidgets('a keystore failure still unlocks and tells the user', (
      tester,
    ) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: [localRecord],
        securityProfiles: profiles,
        biometricAvailable: true,
      );
      result.harness.sessionRepository.saveError = StateError('keystore');
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'kv-test-only');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Enable'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Biometrics could not be enabled. You can try again in Settings.',
        ),
        findsOneWidget,
      );
      expect(result.harness.unlockUseCase.callCount, 1);
      expect(
        result
            .harness
            .securityRepository
            .profiles['db-1']!
            .biometricProtectionEnabled,
        isFalse,
      );
    });
  });

  group('Layout and accessibility (spec 025 FR-U1, FR-U3)', () {
    testWidgets('error renders inside the credential group, no snackbar', (
      tester,
    ) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.unlockUseCase.error = const InvalidCredentialsFailure();
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'x');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('unlock-credentials')),
          matching: find.text(
            'Wrong password or key file. Check both and try again.',
          ),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('shows source, name, field, key slot, Unlock in order with '
        '44 px icon targets', (tester) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(
        top(find.text('This device')),
        lessThan(top(find.text('personal.kdbx'))),
      );
      expect(
        top(find.text('personal.kdbx')),
        lessThan(top(find.text('Master password').first)),
      );
      expect(
        top(find.text('Master password').first),
        lessThan(top(find.text('Add a key file'))),
      );
      expect(
        top(find.text('Add a key file')),
        lessThan(top(find.text('Unlock'))),
      );
      for (final tooltip in ['Back to databases', 'Show password']) {
        final size = tester.getSize(
          find.ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(KvCircleIconButton),
          ),
        );
        expect(size.width, greaterThanOrEqualTo(44), reason: tooltip);
        expect(size.height, greaterThanOrEqualTo(44), reason: tooltip);
      }
    });

    testWidgets('a mapped database shows the Google Drive source with the '
        'connected account', (tester) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.syncRepository
        ..mappings[path] = const DatabaseSyncMapping(
          databasePath: path,
          providerId: 'google_drive',
          remoteFileId: 'remote-1',
          remoteFileName: 'personal.kdbx',
        )
        ..connected = true
        ..account = const StorageAccountSummary(
          displayLabel: 'mara@example.com',
          email: 'mara@example.com',
        );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(find.text('Google Drive · mara@example.com'), findsOneWidget);
    });

    testWidgets('the card stays at most 600 wide at 1024', (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const ValueKey('unlock-credentials'))).width,
        lessThanOrEqualTo(600),
      );
    });
  });

  group('Tester findings (spec 025)', () {
    const biometricsOn = {
      'db-1': DatabaseSecurityProfile(
        databaseId: 'db-1',
        biometricProtectionEnabled: true,
      ),
    };

    testWidgets('F9a: Use biometrics is offered whenever biometrics are '
        'enabled and available, and goes through the gate', (tester) async {
      // The gate is passed, but there is no stored credential: the ready form
      // shows without the user ever asking for the manual fallback.
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: biometricsOn,
        biometricAvailable: true,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      final bloc = tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseUnlockBloc>();
      expect(bloc.state.phase, UnlockPhase.ready);
      expect(bloc.state.manualFallbackRequested, isFalse);
      expect(find.text('Use biometrics'), findsOneWidget);

      final phases = <UnlockPhase>[];
      final sub = bloc.stream.listen((s) => phases.add(s.phase));
      await tester.tap(find.text('Use biometrics'));
      await tester.pumpAndSettle();
      // Not awaited: a future from outside the test zone never completes
      // under the fake clock.
      unawaited(sub.cancel());

      expect(phases.first, UnlockPhase.biometricGate);
      expect(result.harness.unlockUseCase.callCount, 0);
    });

    testWidgets('F9a: not offered when biometrics are off for the database '
        'or the device has none', (tester) async {
      final off = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
        biometricAvailable: true,
      );
      await tester.pumpWidget(off.widget);
      await tester.pumpAndSettle();
      expect(find.text('Use biometrics'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await resetDatabaseTestDi();
      final noSensor = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: biometricsOn,
      );
      await tester.pumpWidget(noSensor.widget);
      await tester.pumpAndSettle();
      expect(find.text('Use biometrics'), findsNothing);
    });

    testWidgets('F3: a key file whose choice cannot be saved still fills the '
        'slot, with a notice inside the credential group', (tester) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.fileRepository.existingPaths.add('/tmp/personal.key');
      result.harness.securityRepository.saveError = StateError('storage');
      result.harness.unlockUseCase.hang = true;
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseUnlockBloc>()
          .add(const UpdateKeyFilePath('/tmp/personal.key'));
      await tester.pumpAndSettle();

      expect(find.text('personal.key'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('unlock-credentials')),
          matching: find.text(keyFileNotRememberedNotice),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.text('Unlock'));
      await tester.pump();
      expect(result.harness.unlockUseCase.lastKeyFilePath, '/tmp/personal.key');
    });

    testWidgets('F2: a settings write failure after decryption opens the '
        'vault and says so', (tester) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.securityRepository.saveError = StateError('storage');
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'kv-test-only');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(find.text('vault:$path'), findsOneWidget);
      expect(find.text(unlockSettingsNotSavedNotice), findsOneWidget);
      expect(
        find.text('Unable to unlock database with provided credentials.'),
        findsNothing,
      );
    });

    testWidgets('the database name is a heading', (tester) async {
      final handle = tester.ensureSemantics();
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('personal.kdbx')),
        isSemantics(isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('the missing-file title is a heading', (tester) async {
      final handle = tester.ensureSemantics();
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.fileRepository.existingPaths.remove(path);
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text("personal.kdbx can't be found")),
        isSemantics(isHeader: true),
      );
      handle.dispose();
    });
  });

  group('Missing file view (spec 025 FR-U4)', () {
    Future<DatabaseTestHarness> pumpMissing(
      WidgetTester tester, {
      bool mapped = false,
    }) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.fileRepository.existingPaths.remove(path);
      if (mapped) {
        result.harness.syncRepository.mappings[path] =
            const DatabaseSyncMapping(
              databasePath: path,
              providerId: 'google_drive',
              remoteFileId: 'remote-1',
              remoteFileName: 'personal.kdbx',
            );
      }
      await tester.pumpWidget(
        BlocProvider<DatabaseSelectionBloc>.value(
          value: DatabaseSelectionBloc(
            databaseSessionCoordinator: result.harness.coordinator,
          ),
          child: result.widget,
        ),
      );
      await tester.pumpAndSettle();
      return result.harness;
    }

    testWidgets('without a mapping: locate, remove, back, and no re-download', (
      tester,
    ) async {
      await pumpMissing(tester);

      expect(find.text("personal.kdbx can't be found"), findsOneWidget);
      expect(
        find.text('The file is no longer where Custode last saw it.'),
        findsOneWidget,
      );
      expect(find.text('Locate file'), findsOneWidget);
      expect(find.text('Remove from list'), findsOneWidget);
      expect(find.text('Back to databases'), findsWidgets);
      expect(find.text('Download again from Google Drive'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('with a mapping the re-download restores the file and the '
        'form', (tester) async {
      final harness = await pumpMissing(tester, mapped: true);
      harness.fileRepository.existingPaths.add(path);

      await tester.tap(find.text('Download again from Google Drive'));
      await tester.pumpAndSettle();

      expect(harness.fileRepository.commitTargets, [path]);
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.text("personal.kdbx can't be found"), findsNothing);
    });

    testWidgets('re-download is hidden where remote sources are unsupported', (
      tester,
    ) async {
      debugPlatformCapabilities = const PlatformCapabilities(
        supportsRemoteSource: false,
        supportsBiometricUnlock: false,
        persistsDatabases: false,
      );
      addTearDown(() => debugPlatformCapabilities = null);

      await pumpMissing(tester, mapped: true);

      expect(find.text('Download again from Google Drive'), findsNothing);
      expect(find.text('Locate file'), findsOneWidget);
    });

    testWidgets('a failed re-download keeps the view and says why inline', (
      tester,
    ) async {
      final harness = await pumpMissing(tester, mapped: true);
      harness.fileRepository.stageError = StateError('offline');

      await tester.tap(find.text('Download again from Google Drive'));
      await tester.pumpAndSettle();

      expect(
        find.text('Unable to download the database again.'),
        findsOneWidget,
      );
      expect(find.text("personal.kdbx can't be found"), findsOneWidget);
    });

    testWidgets('remove asks first, then removes and leaves', (tester) async {
      final harness = await pumpMissing(tester);

      await tester.tap(find.text('Remove from list'));
      await tester.pumpAndSettle();
      expect(find.text('Remove personal.kdbx from the list?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(harness.registryRepository.records, isNotEmpty);

      await tester.tap(find.text('Remove from list'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      // The selection screen behind animates forever: no pumpAndSettle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(harness.registryRepository.records, isEmpty);
      expect(find.byType(DatabaseSelectionScreen), findsOneWidget);
    });
  });

  group('C-3 typed failure placement', () {
    Future<({dynamic harness, dynamic tester})> submitWithError(
      WidgetTester tester,
      DatabaseAccessFailure error,
    ) async {
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: records,
        securityProfiles: profiles,
      );
      result.harness.unlockUseCase.error = error;

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'x');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      return (harness: result.harness, tester: tester);
    }

    testWidgets(
      'InvalidCredentialsFailure: inline field error, credential form stays',
      (tester) async {
        await submitWithError(tester, const InvalidCredentialsFailure());

        expect(find.byType(SnackBar), findsNothing);
        expect(
          find.descendant(
            of: find.byType(TextFormField),
            matching: find.text(
              'Wrong password or key file. Check both and try again.',
            ),
          ),
          findsOneWidget,
        );
        expect(find.text('Unlock'), findsOneWidget);
      },
    );

    testWidgets(
      'KeyFileMissingFailure: inline field error naming the required action',
      (tester) async {
        await submitWithError(tester, const KeyFileMissingFailure());

        expect(find.byType(SnackBar), findsNothing);
        expect(
          find.descendant(
            of: find.byType(TextFormField),
            matching: find.text(
              'Key file not found. Locate or select the required key file.',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'DatabaseFileMissingFailure: replaces the credential form with the '
      'missing-file view',
      (tester) async {
        await submitWithError(
          tester,
          const DatabaseFileMissingFailure('personal.kdbx'),
        );

        expect(find.byType(SnackBar), findsNothing);
        expect(find.byType(TextFormField), findsNothing);
        expect(find.text("personal.kdbx can't be found"), findsOneWidget);
        expect(find.text('Locate file'), findsOneWidget);
      },
    );

    testWidgets(
      'InvalidDatabaseFileFailure: replaces the credential form with the '
      'failure surface',
      (tester) async {
        await submitWithError(
          tester,
          const InvalidDatabaseFileFailure('personal.kdbx'),
        );

        expect(find.byType(SnackBar), findsNothing);
        expect(find.byType(TextFormField), findsNothing);
        expect(find.text('Back to database list'), findsOneWidget);
      },
    );

    testWidgets(
      'CorruptDatabaseFailure: failure surface, never phrased as wrong '
      'password',
      (tester) async {
        await submitWithError(
          tester,
          const CorruptDatabaseFailure('personal.kdbx'),
        );

        expect(find.byType(SnackBar), findsNothing);
        expect(find.byType(TextFormField), findsNothing);
        expect(find.textContaining('password'), findsNothing);
        expect(find.text('Back to database list'), findsOneWidget);
      },
    );
  });
}

class _CapturingAutofillClient implements AppleAutofillV2Client {
  final tokenCompleter = Completer<String?>();
  final List<(String, AndroidAutofillCaptureOutcome)> resolved = [];

  @override
  bool get isSupported => true;

  @override
  Future<String?> takePendingCaptureToken() => tokenCompleter.future;

  @override
  Future<AppleAutofillV2ClearPendingAssociationsResult> resolvePendingCapture({
    required String token,
    required AndroidAutofillCaptureOutcome outcome,
  }) async {
    resolved.add((token, outcome));
    return const AppleAutofillV2ClearPendingAssociationsResult(clearedCount: 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The unlock screen never writes; it only asks whether a capture is waiting.
class _UnusedVaultKdbxService implements VaultKdbxService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
