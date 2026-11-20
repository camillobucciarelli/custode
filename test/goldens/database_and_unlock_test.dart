// spec-003 T20 / spec 025: exact golden inventory harness, 25 files since
// spec 025 S4.
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
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file_selection_data.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_event.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_selection_sheets.dart';
import 'package:password_manager/core/widgets/kv_bottom_sheet.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_conflict_sheet.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/remote_file_picker.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/biometric_offer_sheet.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/internal_key_file_manager_sheet.dart';
import 'package:path/path.dart' as p;

import '../features/password_manager/presentation/coordinators/fake_database_ports.dart';
import '../features/password_manager/presentation/screens/database_selection_unlock_test_utils.dart';
import 'golden_asset_warmup.dart';

/// Exact inventory (spec 025 "Golden inventory", 25 files). Order
/// matches the spec table; used both to drive generation and as the
/// authoritative count/name check at the end of this file.
const exactGoldenInventory = <String>[
  'db_welcome_390x844_light.png',
  'db_welcome_390x844_dark.png',
  'db_list_390x844_light.png',
  'db_list_390x844_dark.png',
  'db_list_1024x768_light.png',
  'db_list_1024x768_dark.png',
  'db_add_sheet_390x844_light.png',
  'db_create_step1_390x844_light.png',
  'db_create_step2_390x844_light.png',
  'db_source_sheet_390x844_light.png',
  'db_drive_files_390x844_light.png',
  'db_drive_loading_390x844_light.png',
  'db_drive_empty_390x844_light.png',
  'db_conflict_390x844_light.png',
  'db_invalid_file_390x844_light.png',
  'unlock_password_390x844_light.png',
  'unlock_password_390x844_dark.png',
  'unlock_password_1024x768_light.png',
  'unlock_biometric_gate_390x844_dark.png',
  'unlock_wrong_password_390x844_light.png',
  'unlock_key_selected_390x844_light.png',
  'unlock_key_manager_390x844_light.png',
  'unlock_decrypting_390x844_light.png',
  'unlock_missing_390x844_light.png',
  'unlock_biometric_offer_390x844_light.png',
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

  // --- Selection: welcome / databases list (mobile + tablet, light + dark) --
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
      name: 'db_list_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'db_list_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'db_list_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'db_list_1024x768_dark.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.dark,
    ),
  ];

  /// The `Databases` mockup: one database on this device with both
  /// credential tags, then the Drive group with the active, synced database
  /// and one whose file is gone.
  Future<Widget> pumpableList(ThemeMode themeMode) async {
    DatabaseRecord record(String id, String name, int openedDay) =>
        DatabaseRecord(
          databaseId: id,
          canonicalPath: '/tmp/$id.kdbx',
          displayName: name,
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          lastOpenedAt: DateTime(2026, 1, openedDay),
        );
    DatabaseSyncMapping mapping(String id, {DateTime? lastSyncAt}) =>
        DatabaseSyncMapping(
          databasePath: '/tmp/$id.kdbx',
          providerId: 'google_drive',
          remoteFileId: 'remote-$id',
          remoteFileName: '$id.kdbx',
          lastSyncAt: lastSyncAt,
        );
    final sync = FakeDatabaseSyncRepository()
      ..connected = true
      ..account = const StorageAccountSummary(
        displayLabel: 'mara@example.com',
        email: 'mara@example.com',
      )
      // The status line is relative to the real clock: "Synced today".
      ..mappings['/tmp/personal.kdbx'] = mapping(
        'personal',
        lastSyncAt: DateTime.now(),
      )
      ..mappings['/tmp/family.kdbx'] = mapping('family');
    final result = await pumpableSelectionScreen(
      themeMode: themeMode,
      syncRepository: sync,
      activeDatabaseId: 'personal',
      records: [
        record('work', 'Work', 2),
        record('personal', 'Personal', 4),
        record('family', 'Family', 3),
      ],
      securityProfiles: const {
        'work': DatabaseSecurityProfile(
          databaseId: 'work',
          biometricProtectionEnabled: true,
          keyFilePath: '/managed/keys/work.key',
        ),
        'personal': DatabaseSecurityProfile(
          databaseId: 'personal',
          biometricProtectionEnabled: true,
        ),
      },
      existingPaths: {'/tmp/work.kdbx', '/tmp/personal.kdbx'},
    );
    return result.widget;
  }

  for (final testCase in selectionCases) {
    testWidgets(testCase.name, (tester) async {
      await setSize(tester, testCase.size);

      final widget = testCase.name.contains('db_list')
          ? await pumpableList(testCase.themeMode)
          : (await pumpableSelectionScreen(themeMode: testCase.themeMode))
                .widget;

      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }

  testWidgets('db_add_sheet_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(await pumpableList(ThemeMode.light));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add database'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_add_sheet_390x844_light.png'),
    );
  });

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
    // ("new_database"), so Continue advances immediately to the merged
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

  // --- Source sheet and Drive file list (spec 025 S2) ----------------------
  testWidgets('db_source_sheet_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    final result = await pumpableSelectionScreen();

    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open a database'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_source_sheet_390x844_light.png'),
    );
  });

  Future<void> showPicker(
    BuildContext context,
    Future<RemoteFileSelectionData> Function() load, {
    Future<List<DatabaseSyncMapping>> Function()? loadMappings,
  }) async {
    await KvBottomSheet.show<void>(
      context: context,
      builder: (_) => RemoteFilePickerSheet(
        load: load,
        reconnect: load,
        switchAccount: load,
        loadMappings: loadMappings,
      ),
    );
  }

  testWidgets('db_drive_files_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) => showPicker(
          context,
          () async => RemoteFileSelectionData(
            files: [
              RemoteFile(
                providerId: 'google_drive',
                id: 'f1',
                name: 'Personal.kdbx',
                modifiedTime: DateTime(2026, 11, 18),
                size: 64000,
              ),
              RemoteFile(
                providerId: 'google_drive',
                id: 'f2',
                name: 'Family.kdbx',
                modifiedTime: DateTime(2026, 11, 16),
                size: 48000,
              ),
              RemoteFile(
                providerId: 'google_drive',
                id: 'f3',
                name: 'Work archive.kdbx',
                modifiedTime: DateTime(2026, 9, 12),
                size: 112000,
              ),
            ],
            account: const StorageAccountSummary(
              displayLabel: 'mara@example.com',
              email: 'mara@example.com',
            ),
          ),
          loadMappings: () async => const [
            DatabaseSyncMapping(
              databasePath: '/tmp/personal.kdbx',
              providerId: 'google_drive',
              remoteFileId: 'f1',
              remoteFileName: 'Personal.kdbx',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_drive_files_390x844_light.png'),
    );
  });

  // --- Drive picker: loading skeleton / empty state -----------------------
  testWidgets('db_drive_loading_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) => showPicker(
          context,
          // Never resolves during this test: captures the skeleton state.
          () => Completer<RemoteFileSelectionData>().future,
        ),
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
        onOpen: (context) => showPicker(
          context,
          () async => const RemoteFileSelectionData(
            files: [],
            account: StorageAccountSummary(
              displayLabel: 'jane@example.com',
              email: 'jane@example.com',
            ),
          ),
        ),
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

  testWidgets('db_conflict_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) async {
          await showDatabaseConflictSheet(
            context,
            importedName: 'Personal.kdbx',
            importedRemote: true,
            existingName: 'Personal.kdbx',
            existingRemote: false,
            recommendExisting: true,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('db_conflict_390x844_light.png'),
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

  // --- Unlock: wrong password with a key file (UnlockKeyFile mockup) --------
  testWidgets('unlock_wrong_password_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    const path = '/tmp/personal.kdbx';
    const keyPath = '/tmp/personal.key';
    final result = await pumpableUnlockScreen(
      databasePath: path,
      records: [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: path,
          displayName: 'Personal',
          sourceType: DatabaseSourceType.drive,
          sourceRef: 'remote-1',
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
    result.harness.unlockUseCase.error = const InvalidCredentialsFailure();

    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();

    tester
        .element(find.byType(Scaffold).first)
        .read<DatabaseUnlockBloc>()
        .add(const UpdateKeyFilePath(keyPath));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'wrong-password');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock'));
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
    await tester.tap(find.text('Unlock'));
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

  // --- Unlock: database file missing (UnlockMissing mockup) -----------------
  testWidgets('unlock_missing_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    const path = '/tmp/personal.kdbx';
    final result = await pumpableUnlockScreen(
      databasePath: path,
      records: [
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: path,
          displayName: 'Personal',
          sourceType: DatabaseSourceType.drive,
          sourceRef: 'remote-1',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      ],
    );
    result.harness.fileRepository.existingPaths.remove(path);
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

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('unlock_missing_390x844_light.png'),
    );
  });

  // --- Unlock: one-time biometric offer (BiometricOffer mockup) --------------
  testWidgets('unlock_biometric_offer_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));

    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) async {
          await showBiometricOfferSheet(context, databaseName: 'Personal');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('unlock_biometric_offer_390x844_light.png'),
    );
  });

  // --- Inventory integrity: exactly 25 named files, all present on disk ----
  test('exact golden inventory has exactly 25 files, all generated', () {
    expect(exactGoldenInventory.toSet().length, 25);
    expect(exactGoldenInventory.length, 25);

    final goldensDir = Directory(
      p.join(Directory.current.path, 'test', 'goldens'),
    );
    for (final name in exactGoldenInventory) {
      final file = File(p.join(goldensDir.path, name));
      expect(file.existsSync(), isTrue, reason: '$name must exist on disk');
    }
  });
}
