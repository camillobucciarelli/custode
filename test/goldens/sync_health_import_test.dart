// spec-005 T22: exact 22-file golden inventory for the 17 screens in
// spec.md's "Screens" table (some screens need light+dark and/or a tablet
// variant, per that table's "Golden" column).
//
// Same deterministic-render harness pattern as vault_shell_test.dart /
// database_and_unlock_test.dart: fixed physical size/DPR, bundled fonts, no
// text scaling, in-memory fake domain ports via `vault_shell_test_utils.dart`
// (spec-002/003) plus this file's own fakes for sync-repository / vault
// content states specific to spec-005.
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:password_manager/features/password_manager/data/services/vault_csv_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_conflict.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_group.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/csv/csv_import_screens.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/sync_status_hero.dart';

import '../features/password_manager/presentation/coordinators/fake_database_ports.dart';
import '../features/password_manager/presentation/screens/vault/vault_shell_test_utils.dart';

/// Exact 22-file inventory: 17 screens from spec.md's table, expanded by its
/// "Golden" column (light+dark and/or a 1024×768 tablet variant per row).
const exactGoldenInventory = <String>[
  'sync_disconnected_390x844_light.png',
  'sync_disconnected_390x844_dark.png',
  'sync_not_linked_390x844_light.png',
  'sync_picker_390x844_light.png',
  'sync_success_390x844_light.png',
  'sync_success_390x844_dark.png',
  'sync_success_1024x768_light.png',
  'sync_syncing_390x844_light.png',
  'sync_offline_390x844_light.png',
  'sync_error_390x844_light.png',
  'sync_conflict_390x844_light.png',
  'health_390x844_light.png',
  'health_390x844_dark.png',
  'health_1024x768_light.png',
  'dup_groups_390x844_light.png',
  'dup_merge_preview_390x844_light.png',
  'dup_empty_390x844_light.png',
  'bin_list_390x844_light.png',
  'bin_empty_confirm_390x844_light.png',
  'csv_preview_390x844_light.png',
  'csv_outcome_390x844_light.png',
  'backups_390x844_light.png',
];

/// Sync repository with switchable `syncNow` behaviour, for the
/// syncing/offline/error/conflict states — plain field mutation covers the
/// rest (`FakeDatabaseSyncRepository.connected`/`mappings`/`remoteFiles`).
class _ScenarioSyncRepository extends FakeDatabaseSyncRepository {
  _SyncNowBehavior syncNowBehavior = _SyncNowBehavior.success;

  @override
  Future<SyncNowResult> syncNow(
    String databasePath, {
    SyncConflictResolution? resolution,
  }) {
    switch (syncNowBehavior) {
      case _SyncNowBehavior.success:
        return super.syncNow(databasePath, resolution: resolution);
      case _SyncNowBehavior.hang:
        return Completer<SyncNowResult>().future;
      case _SyncNowBehavior.offline:
        throw const SocketException('Failed host lookup');
      case _SyncNowBehavior.error:
        throw Exception('Unexpected server response');
      case _SyncNowBehavior.conflict:
        return Future.value(
          SyncNowConflict(
            SyncConflict(
              databasePath: databasePath,
              remoteFileId: 'file-123',
              remoteFileName: 'Personal.kdbx',
              localChecksum: 'a91f000000000000000000000000007c40',
              remoteChecksum: '3d0c0000000000000000000000000000b18e',
              remoteModifiedTime: DateTime(2026, 8, 2, 8, 41),
            ),
          ),
        );
    }
  }
}

enum _SyncNowBehavior { success, hang, offline, error, conflict }

/// A vault with one entry in each FR-4 category, plus a duplicate group and
/// two recycle-bin entries — used for the Health/Duplicates/Recycle-bin
/// goldens (cases 9-14).
class _PopulatedVaultKdbxService implements VaultKdbxService {
  static const rootId = 'root';

  static VaultEntry _e({
    required String id,
    String title = '',
    String url = 'example.com',
    String username = 'user',
    String password = 'Qx7#mPz9Lk2\$Vw8', // ~97 bits: never weak/reused here.
    DateTime? lastPasswordChangedAt,
  }) {
    return VaultEntry(
      id: id,
      groupId: rootId,
      title: title.isEmpty ? id : title,
      username: username,
      password: password,
      url: url,
      notes: '',
      lastPasswordChangedAt: lastPasswordChangedAt,
    );
  }

  static final entries = [
    // Distinct url+username per entry below (except the deliberate dup-a/
    // dup-b pair) — VaultDuplicateService groups by url+username, and the
    // `_e()` default would otherwise silently collide every entry that
    // doesn't override it into one big accidental "duplicate" group.
    _e(
      id: 'weak-1',
      title: 'Old router admin',
      url: '192.168.1.1',
      username: 'admin',
      password: 'admin',
    ),
    _e(
      id: 'reused-1',
      title: 'GitHub',
      url: 'github.com',
      username: 'dev',
      password: 'Tr0ub4dor&Zx9!Qp',
    ),
    _e(
      id: 'reused-2',
      title: 'GitLab',
      url: 'gitlab.com',
      username: 'dev',
      password: 'Tr0ub4dor&Zx9!Qp',
    ),
    _e(
      id: 'old-1',
      title: 'Spotify',
      url: 'spotify.com',
      username: 'listener',
      password: 'Zn5!qLp8Rk3@Tx6a',
      lastPasswordChangedAt: DateTime(2020, 1, 1),
    ),
    _e(id: 'unmatchable-1', title: 'Loose note', url: '', username: ''),
    _e(
      id: 'dup-a',
      title: 'Netflix',
      url: 'netflix.com',
      username: 'family@example.com',
      password: 'Hl1!Nb6\$Wq4@Zt9c',
    ),
    _e(
      id: 'dup-b',
      title: 'Netflix family',
      url: 'netflix.com',
      username: 'family@example.com',
      password: 'Hl2!Nb7\$Wq5@Zt0c',
      lastPasswordChangedAt: DateTime(2024, 1, 4),
    ),
  ];

  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async {
    return VaultSnapshot(
      rootGroupId: rootId,
      currentGroupId: currentGroupId ?? rootId,
      groups: const [VaultGroup(id: rootId, name: 'root', parentId: null)],
      entries: entries,
      allEntries: entries,
    );
  }

  @override
  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async => [
    _e(
      id: 'bin-1',
      title: 'Netflix famiglia',
      username: 'famiglia@example.com',
    ),
    _e(id: 'bin-2', title: '', url: '', username: ''),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// `_VaultTabBar` (mobile, <600 px) shows text labels; `_VaultRail` (wide)
/// shows icon-only buttons with a matching tooltip — tap whichever exists.
Future<void> _tapDestination(WidgetTester tester, String label) async {
  final textFinder = find.text(label);
  if (textFinder.evaluate().isNotEmpty) {
    await tester.tap(textFinder.first);
  } else {
    await tester.tap(find.byTooltip(label).first);
  }
}

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

  tearDown(() {
    resetVaultShellTestDi();
    SyncStatusHero.debugNowOverride = null;
  });

  // Fixed clock for every case that shows a "Last sync X ago" relative-time
  // string — real `DateTime.now()` at golden-generation time vs. at
  // verification time (even seconds apart) can flip the rendered bucket
  // ("2 hours ago" -> "3 hours ago"), which is a real, observed source of
  // golden flakiness (a single-glyph pixel diff). `SyncStatusHero.now` /
  // `debugNowOverride` makes the render fully deterministic instead.
  final fixedNow = DateTime(2026, 8, 8, 12, 0);

  // --- 1. Sync — disconnected (390×844 L+D) --------------------------------
  for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
    final name =
        'sync_disconnected_390x844_${themeMode == ThemeMode.dark ? 'dark' : 'light'}.png';
    testWidgets(name, (tester) async {
      await _setSize(tester, const Size(390, 844));
      await tester.pumpWidget(await pumpableVaultShell(themeMode: themeMode));
      await tester.pumpAndSettle();

      await _tapDestination(tester, 'Sync');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(name));
    });
  }

  // --- 2. Sync — connected, not linked (390×844 L) -------------------------
  testWidgets('sync_not_linked_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    final repo = _ScenarioSyncRepository()..connected = true;
    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repo),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Sync');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('sync_not_linked_390x844_light.png'),
    );
  });

  // --- 3. Sync — remote file picker (390×844 L) ----------------------------
  testWidgets('sync_picker_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    final repo = _ScenarioSyncRepository()
      ..connected = true
      ..remoteFiles = [
        RemoteFile(
          providerId: 'google_drive',
          id: 'f1',
          name: 'Personal.kdbx',
          modifiedTime: DateTime(2026, 3, 12),
          size: 312000,
        ),
        RemoteFile(
          providerId: 'google_drive',
          id: 'f2',
          name: 'Personal-old.kdbx',
          modifiedTime: DateTime(2024, 8, 4),
          size: 2400000,
        ),
        RemoteFile(
          providerId: 'google_drive',
          id: 'f3',
          name: 'Work.kdbx',
          modifiedTime: DateTime(2026, 8, 2),
        ),
      ]
      ..mappings['/other/work.kdbx'] = const DatabaseSyncMapping(
        databasePath: '/other/work.kdbx',
        providerId: 'google_drive',
        remoteFileId: 'f3',
        remoteFileName: 'Work.kdbx',
      );
    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repo),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Sync');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick an existing .kdbx'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('sync_picker_390x844_light.png'),
    );
  });

  // --- 4. Sync — success (390×844 L+D, 1024×768 L) -------------------------
  const successCases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'sync_success_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'sync_success_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'sync_success_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
  ];
  for (final testCase in successCases) {
    testWidgets(testCase.name, (tester) async {
      SyncStatusHero.debugNowOverride = fixedNow;
      await _setSize(tester, testCase.size);
      final repo = _ScenarioSyncRepository()
        ..connected = true
        ..mappings[kTestDatabasePath] = DatabaseSyncMapping(
          databasePath: kTestDatabasePath,
          providerId: 'google_drive',
          remoteFileId: 'file-123',
          remoteFileName: 'Personal.kdbx',
          lastSyncAt: fixedNow.subtract(const Duration(hours: 2)),
          lastSyncedLocalChecksum: 'a91f00000000000000000000000000007c40',
        );
      await tester.pumpWidget(
        await pumpableVaultShell(
          databaseSyncRepository: repo,
          themeMode: testCase.themeMode,
        ),
      );
      await tester.pumpAndSettle();

      await _tapDestination(tester, 'Sync');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }

  // --- 5. Sync — syncing (390×844 L) ----------------------------------------
  testWidgets('sync_syncing_390x844_light.png', (tester) async {
    SyncStatusHero.debugNowOverride = fixedNow;
    await _setSize(tester, const Size(390, 844));
    final repo = _ScenarioSyncRepository()
      ..connected = true
      ..mappings[kTestDatabasePath] = DatabaseSyncMapping(
        databasePath: kTestDatabasePath,
        providerId: 'google_drive',
        remoteFileId: 'file-123',
        remoteFileName: 'Personal.kdbx',
        lastSyncAt: fixedNow.subtract(const Duration(hours: 2)),
      );
    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repo),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Sync');
    await tester.pumpAndSettle();

    repo.syncNowBehavior = _SyncNowBehavior.hang;
    await tester.tap(find.byTooltip('Sync now'));
    // Indeterminate spinner: bounded pumps, not pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('sync_syncing_390x844_light.png'),
    );
  });

  // --- 6. Sync — offline (390×844 L, T7 proposal) ---------------------------
  testWidgets('sync_offline_390x844_light.png', (tester) async {
    SyncStatusHero.debugNowOverride = fixedNow;
    await _setSize(tester, const Size(390, 844));
    final repo = _ScenarioSyncRepository()
      ..connected = true
      ..mappings[kTestDatabasePath] = DatabaseSyncMapping(
        databasePath: kTestDatabasePath,
        providerId: 'google_drive',
        remoteFileId: 'file-123',
        remoteFileName: 'Personal.kdbx',
        lastSyncAt: fixedNow.subtract(const Duration(hours: 2)),
      );
    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repo),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Sync');
    await tester.pumpAndSettle();

    repo.syncNowBehavior = _SyncNowBehavior.offline;
    await tester.tap(find.byTooltip('Sync now'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('sync_offline_390x844_light.png'),
    );
  });

  // --- 7. Sync — error + Reconnect (390×844 L) ------------------------------
  testWidgets('sync_error_390x844_light.png', (tester) async {
    SyncStatusHero.debugNowOverride = fixedNow;
    await _setSize(tester, const Size(390, 844));
    final repo = _ScenarioSyncRepository()
      ..connected = true
      ..mappings[kTestDatabasePath] = DatabaseSyncMapping(
        databasePath: kTestDatabasePath,
        providerId: 'google_drive',
        remoteFileId: 'file-123',
        remoteFileName: 'Personal.kdbx',
        lastSyncAt: fixedNow.subtract(const Duration(days: 3)),
      );
    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repo),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Sync');
    await tester.pumpAndSettle();

    repo.syncNowBehavior = _SyncNowBehavior.error;
    await tester.tap(find.byTooltip('Sync now'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('sync_error_390x844_light.png'),
    );
  });

  // --- 8. Sync — conflict sheet (390×844 L) ---------------------------------
  testWidgets('sync_conflict_390x844_light.png', (tester) async {
    SyncStatusHero.debugNowOverride = fixedNow;
    await _setSize(tester, const Size(390, 844));
    final repo = _ScenarioSyncRepository()
      ..connected = true
      ..mappings[kTestDatabasePath] = DatabaseSyncMapping(
        databasePath: kTestDatabasePath,
        providerId: 'google_drive',
        remoteFileId: 'file-123',
        remoteFileName: 'Personal.kdbx',
        lastSyncAt: fixedNow.subtract(const Duration(hours: 6)),
      );
    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repo),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Sync');
    await tester.pumpAndSettle();

    repo.syncNowBehavior = _SyncNowBehavior.conflict;
    await tester.tap(find.byTooltip('Sync now'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('sync_conflict_390x844_light.png'),
    );
  });

  // --- 9. Health — score + 5 categories (390×844 L+D, 1024×768 L) ----------
  const healthCases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'health_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'health_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'health_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
  ];
  for (final testCase in healthCases) {
    testWidgets(testCase.name, (tester) async {
      await _setSize(tester, testCase.size);
      await tester.pumpWidget(
        await pumpableVaultShell(
          themeMode: testCase.themeMode,
          vaultKdbxService: _PopulatedVaultKdbxService(),
        ),
      );
      await tester.pumpAndSettle();

      await _tapDestination(tester, 'Health');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }

  // Regression: at desktop widths a health category opens as a pane pushed
  // over the Health destination body — before the fix the pane surface was
  // created but the non-vault rail body never rendered it, so the tap read
  // as dead.
  testWidgets('health category list opens from Health at 1024', (tester) async {
    await _setSize(tester, const Size(1024, 768));
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: _PopulatedVaultKdbxService()),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Health');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Weak passwords'));
    await tester.pumpAndSettle();

    // The category list screen renders its entries — the health rows never
    // show entry titles, so this only passes when the pane actually shows.
    expect(find.text('Old router admin'), findsOneWidget);
  });

  // --- 10/11. Duplicates — groups + merge preview (390×844 L) --------------
  testWidgets('dup_groups_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: _PopulatedVaultKdbxService()),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Health');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicates'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('dup_groups_390x844_light.png'),
    );
  });

  testWidgets('dup_merge_preview_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: _PopulatedVaultKdbxService()),
    );
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Health');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicates'));
    await tester.pumpAndSettle();
    // Two duplicate groups since credentials grouping landed (reused-1/2
    // share username+password) — tap the first group's merge button.
    await tester.tap(find.text('Merge and move duplicate').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('dup_merge_preview_390x844_light.png'),
    );
  });

  // --- 12. Duplicates — empty (390×844 L) -----------------------------------
  testWidgets('dup_empty_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableVaultShell());
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Health');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicates'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('dup_empty_390x844_light.png'),
    );
  });

  // --- 13. Recycle bin (390×844 L) ------------------------------------------
  testWidgets('bin_list_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: _PopulatedVaultKdbxService()),
    );
    await tester.pumpAndSettle();

    // 2026-08-31: the list header's `⋮` (tooltip 'Settings') is retired —
    // the path is the Settings destination's own 'Recycle bin' row.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Recycle bin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recycle bin'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('bin_list_390x844_light.png'),
    );
  });

  // --- 14. Recycle bin — empty bin confirm sheet (390×844 L) ----------------
  //
  // The mock's screen 14 shows the empty-state background with the confirm
  // sheet overlaid for illustration; the real app disables "Empty bin"
  // once the bin is already empty, so that combination isn't reachable
  // through the UI. This golden instead captures the confirm sheet as the
  // app actually shows it — reached from a non-empty bin.
  testWidgets('bin_empty_confirm_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: _PopulatedVaultKdbxService()),
    );
    await tester.pumpAndSettle();

    // 2026-08-31: the list header's `⋮` (tooltip 'Settings') is retired —
    // the path is the Settings destination's own 'Recycle bin' row.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Recycle bin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recycle bin'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Empty bin ('));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('bin_empty_confirm_390x844_light.png'),
    );
  });

  // --- 15/16. CSV import preview / outcome (390×844 L) ----------------------
  //
  // Pumped directly (public widgets, see csv_import_screens.dart) instead
  // of through `_startCsvImportFlow`: `FilePicker.pickFiles` has no test
  // platform-channel handler in this repo.
  testWidgets('csv_preview_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        // Issue #187: the "overflow marker" in these two goldens was the
        // DEBUG banner of a bare MaterialApp, not a RenderFlex overflow.
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: CsvImportPreviewScreen(
          filePath: '/tmp/chrome-passwords.csv',
          fileSizeBytes: 312 * 1024,
          preview: VaultCsvParseResult(
            items: List.generate(
              208,
              (i) => VaultCsvImportItem(
                rowIndex: i + 1,
                title: 'Item $i',
                username: 'user$i',
                password: 'pw',
                url: 'example$i.com',
                notes: '',
              ),
            ),
            skippedRows: 6,
            skippedRowDetails: const [],
            totalRows: 214,
            format: VaultCsvSourceFormat.chrome,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('csv_preview_390x844_light.png'),
    );
  });

  testWidgets('csv_outcome_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        // Issue #187: the "overflow marker" in these two goldens was the
        // DEBUG banner of a bare MaterialApp, not a RenderFlex overflow.
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: CsvImportOutcomeScreen(
          outcome: const CsvImportOutcome(
            importedCount: 203,
            duplicateSkippedCount: 5,
            skippedRows: [
              SkippedRow(index: 14, reason: 'No password column value'),
              SkippedRow(
                index: 61,
                reason: 'Malformed quoting, row ends early',
              ),
              SkippedRow(
                index: 88,
                reason: 'No title and no URL to name it by',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('csv_outcome_390x844_light.png'),
    );
  });

  // --- 17. Backups (390×844 L) ----------------------------------------------
  testWidgets('backups_390x844_light.png', (tester) async {
    await _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableVaultShell());
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Settings');
    await tester.pumpAndSettle();
    // spec-006 T1: Settings no longer aliases to Backups — it's a row
    // ("Backups & import") one level inside the real Settings screen now.
    await tester.ensureVisible(find.text('Backups & import'));
    await tester.tap(find.text('Backups & import'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('backups_390x844_light.png'),
    );
  });

  // --- Inventory integrity: exactly 22 named files, all present on disk ----
  test('exact golden inventory has exactly 22 files, all generated', () {
    expect(exactGoldenInventory.toSet().length, 22);
    expect(exactGoldenInventory.length, 22);

    final goldensDir = Directory(
      p.join(Directory.current.path, 'test', 'goldens'),
    );
    for (final name in exactGoldenInventory) {
      final file = File(p.join(goldensDir.path, name));
      expect(file.existsSync(), isTrue, reason: '$name must exist on disk');
    }
  });
}
