// spec-003 T20: exact golden inventory harness — all 22 named states.
//
// Same deterministic-render pattern as vault_shell_test.dart /
// organic_theme_gallery_test.dart (spec-001/002): fixed physical size/DPR,
// bundled fonts, no text scaling, `en_US` locale, disabled external I/O via
// in-memory fake domain ports (`fake_database_ports.dart`) plus a mocked
// `PathProviderPlatform` for the one surface that reads real app-storage
// listings (the key-file manager sheet).
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/utils/mobile_file_storage.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/errors/database_access_failure.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file_selection_data.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_event.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_selection_sheets.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/drive_picker_sheet.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/biometric_prompt_sheet.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/internal_key_file_manager_sheet.dart';
import 'package:path/path.dart' as p;

import '../features/password_manager/presentation/screens/database_selection_unlock_test_utils.dart';
import 'golden_asset_warmup.dart';

/// Exact 22-file inventory from spec-003 spec.md "Exact golden inventory".
/// Order matches the spec table; used both to drive generation and as the
/// authoritative count/name check at the end of this file.
const exactGoldenInventory = <String>[
  'db_welcome_390x844_light.png',
  'db_welcome_390x844_dark.png',
  'db_recent_390x844_light.png',
  'db_recent_390x844_dark.png',
  'db_recent_1024x768_light.png',
  'db_recent_1024x768_dark.png',
  'db_create_step1_390x844_light.png',
  'db_create_step2_390x844_light.png',
  'db_drive_loading_390x844_light.png',
  'db_drive_empty_390x844_light.png',
  'db_invalid_file_390x844_light.png',
  'db_duplicate_390x844_light.png',
  'unlock_password_390x844_light.png',
  'unlock_password_390x844_dark.png',
  'unlock_password_1024x768_light.png',
  'unlock_biometric_gate_390x844_dark.png',
  'unlock_wrong_password_390x844_light.png',
  'unlock_key_selected_390x844_light.png',
  'unlock_key_manager_390x844_light.png',
  'unlock_decrypting_390x844_light.png',
  'unlock_face_id_prompt_390x844_light.png',
];

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

  tearDown(resetDatabaseTestDi);

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // --- Selection: welcome / recent (mobile + tablet, light + dark) -------
  const selectionCases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'db_welcome_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'db_welcome_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'db_recent_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'db_recent_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'db_recent_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'db_recent_1024x768_dark.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.dark,
    ),
  ];

  for (final testCase in selectionCases) {
    testWidgets(testCase.name, (tester) async {
      await setSize(tester, testCase.size);

      final hasRecentItem = testCase.name.contains('recent');
      final result = await pumpableSelectionScreen(
        themeMode: testCase.themeMode,
        records: hasRecentItem
            ? [
                DatabaseRecord(
                  databaseId: 'db-1',
                  canonicalPath: '/tmp/personal.kdbx',
                  displayName: 'personal.kdbx',
                  sourceType: DatabaseSourceType.local,
                  createdAt: DateTime(2026, 1, 1),
                  updatedAt: DateTime(2026, 1, 1),
                  lastOpenedAt: DateTime(2026, 1, 2),
                ),
              ]
            : const [],
        existingPaths: hasRecentItem ? {'/tmp/personal.kdbx'} : {},
      );

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }

  // --- Create wizard: steps 1-3 (mobile, light) ---------------------------
  testWidgets('db_create_step1_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    final result = await pumpableCreateDatabaseScreen();

    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_create_step1_390x844_light.png'),
    );
  });

  testWidgets('db_create_step2_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    final result = await pumpableCreateDatabaseScreen();

    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();

    // Step 1's database-name field already has a non-empty default value
    // ("new_database.kdbx"), so Continue advances immediately to the merged
    // credentials step (spec 015 FR-1: two steps). The credentials-step
    // state variants (key modes, optional password, inert submit reason,
    // FR-13 warning, failure-keeps-wizard) are covered by named widget
    // assertions in create_database_screen_test.dart; omitted axes per the
    // spec: 1024x768, dark.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_create_step2_390x844_light.png'),
    );
  });

  // --- Drive picker: loading skeleton / empty state -----------------------
  testWidgets('db_drive_loading_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) async {
          await showDrivePickerSheet(
            context,
            // Never resolves during this test: captures the skeleton state.
            loadPickerData: () => Completer<RemoteFileSelectionData>().future,
          );
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_drive_loading_390x844_light.png'),
    );
  });

  testWidgets('db_drive_empty_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) async {
          await showDrivePickerSheet(
            context,
            loadPickerData: () async => const RemoteFileSelectionData(
              files: [],
              account: StorageAccountSummary(
                displayLabel: 'jane@example.com',
                email: 'jane@example.com',
              ),
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_drive_empty_390x844_light.png'),
    );
  });

  // --- Invalid file / duplicate sheets -------------------------------------
  testWidgets('db_invalid_file_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) => showInvalidDatabaseFileDialog(
          context,
          basename: 'not-a-vault.kdbx',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_invalid_file_390x844_light.png'),
    );
  });

  testWidgets('db_duplicate_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) async {
          await showDuplicateDatabaseSheet(
            context,
            importedName: 'family.kdbx',
            existingName: 'family (1).kdbx',
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_duplicate_390x844_light.png'),
    );
  });

  // --- Unlock: password (mobile/tablet, light/dark) ------------------------
  const unlockCases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'unlock_password_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'unlock_password_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'unlock_password_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
  ];

  for (final testCase in unlockCases) {
    testWidgets(testCase.name, (tester) async {
      await setSize(tester, testCase.size);

      const path = '/tmp/personal.kdbx';
      final result = await pumpableUnlockScreen(
        databasePath: path,
        themeMode: testCase.themeMode,
        records: [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: path,
            displayName: 'personal.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ],
        securityProfiles: const {
          'db-1': DatabaseSecurityProfile(
            databaseId: 'db-1',
            biometricProtectionEnabled: false,
          ),
        },
      );

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }

  // --- Unlock: biometric gate (dark) ---------------------------------------
  testWidgets('unlock_biometric_gate_390x844_dark.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    const path = '/tmp/work.kdbx';
    final result = await pumpableUnlockScreen(
      databasePath: path,
      themeMode: ThemeMode.light, // gate forces its own dark theme
      biometricAvailable: true,
      hangBiometricAuthenticate: true,
      records: [
        DatabaseRecord(
          databaseId: 'db-2',
          canonicalPath: path,
          displayName: 'work.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ],
      securityProfiles: const {
        'db-2': DatabaseSecurityProfile(
          databaseId: 'db-2',
          biometricProtectionEnabled: true,
        ),
      },
    );

    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('unlock_biometric_gate_390x844_dark.png'),
    );
  });

  // --- Unlock: wrong password (C-3 InvalidCredentialsFailure) --------------
  testWidgets('unlock_wrong_password_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    const path = '/tmp/personal.kdbx';
    final result = await pumpableUnlockScreen(
      databasePath: path,
      records: [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: path,
          displayName: 'personal.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ],
      securityProfiles: const {
        'db-1': DatabaseSecurityProfile(
          databaseId: 'db-1',
          biometricProtectionEnabled: false,
        ),
      },
    );

    result.harness.unlockUseCase.error = const InvalidCredentialsFailure();

    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'wrong-password');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock vault'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('unlock_wrong_password_390x844_light.png'),
    );
  });

  // --- Unlock: key file selected -------------------------------------------
  testWidgets('unlock_key_selected_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    const path = '/tmp/personal.kdbx';
    const keyPath = '/tmp/personal.key';
    final result = await pumpableUnlockScreen(
      databasePath: path,
      records: [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: path,
          displayName: 'personal.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ],
      securityProfiles: const {
        'db-1': DatabaseSecurityProfile(
          databaseId: 'db-1',
          biometricProtectionEnabled: false,
        ),
      },
    );
    result.harness.fileRepository.existingPaths.add(keyPath);

    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();

    tester
        .element(find.byType(Scaffold).first)
        .read<DatabaseUnlockBloc>()
        .add(const UpdateKeyFilePath(keyPath));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('unlock_key_selected_390x844_light.png'),
    );
  });

  // --- Unlock: decrypting (C-4 indeterminate) -------------------------------
  testWidgets('unlock_decrypting_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    const path = '/tmp/personal.kdbx';
    final result = await pumpableUnlockScreen(
      databasePath: path,
      records: [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: path,
          displayName: 'personal.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ],
      securityProfiles: const {
        'db-1': DatabaseSecurityProfile(
          databaseId: 'db-1',
          biometricProtectionEnabled: false,
        ),
      },
    );
    result.harness.unlockUseCase.hang = true;

    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField),
      'kv-test-only-not-a-real-password',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock vault'));
    // Indeterminate progress animates forever: pump discrete frames instead
    // of pumpAndSettle (which would never converge).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('unlock_decrypting_390x844_light.png'),
    );
  });

  // --- Unlock: key manager sheet --------------------------------------------
  //
  // Uses the `listKeyFiles` injection seam instead of real `dart:io`
  // directory listing: `MobileFileStorage.listFilesInAppDirectory` does not
  // resolve inside `testWidgets`'s fake-async zone without `tester.runAsync`
  // (verified: it hangs indefinitely even with 2 s of pumping), and this
  // sheet's only other collaborator is that real listing call, so a
  // synchronous fake is the correct seam rather than fighting the zone.
  testWidgets('unlock_key_manager_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) async {
          await showInternalKeyFileManagerSheet(
            context,
            listKeyFiles: ({required subdirectory}) async => [
              AppStorageFileEntry(
                name: 'personal.key',
                path: '/managed/keys/personal.key',
                sizeBytes: 64,
                modifiedAt: DateTime(2026, 1, 10),
              ),
              AppStorageFileEntry(
                name: 'shared-vault.key',
                path: '/managed/keys/shared-vault.key',
                sizeBytes: 64,
                modifiedAt: DateTime(2026, 1, 5),
              ),
            ],
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('unlock_key_manager_390x844_light.png'),
    );
  });

  // --- Unlock: post-Drive Face ID prompt ------------------------------------
  testWidgets('unlock_face_id_prompt_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) async {
          await showBiometricPromptDialog(context, basename: 'work.kdbx');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('unlock_face_id_prompt_390x844_light.png'),
    );
  });

  // --- Inventory integrity: exactly 21 named files, all present on disk.
  // Spec 015 collapsed the create wizard to two steps, retiring
  // db_create_step3 with `CreateDatabaseStep.optionalLocks`. ----
  test('exact golden inventory has exactly 21 files, all generated', () {
    expect(exactGoldenInventory.toSet().length, 21);
    expect(exactGoldenInventory.length, 21);

    final goldensDir = Directory(
      p.join(Directory.current.path, 'test', 'goldens'),
    );
    for (final name in exactGoldenInventory) {
      final file = File(p.join(goldensDir.path, name));
      expect(file.existsSync(), isTrue, reason: '$name must exist on disk');
    }
  });
}
