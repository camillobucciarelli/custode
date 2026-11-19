// Google Play store graphics generator. Not part of any suite: the file name
// deliberately lacks the `_test.dart` suffix, so neither `flutter test` nor the
// CI `find test -name '*_test.dart'` picks it up. Run it explicitly from the
// repository root (macOS, for the system monospace font):
//
//   fvm flutter test test/store_screenshots/google_play_assets.dart
//
// Reuses the golden harnesses; writes 24-bit PNGs (no alpha, as Play requires)
// to docs/store_assets/google_play/. flutter_test's default target platform is
// Android, so these render the Android look without an override.
// Entry names are neutral on purpose: no real brands or logos in store images.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/responsive/breakpoints.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_group.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';

import '../features/password_manager/presentation/coordinators/fake_database_ports.dart';

import 'package:password_manager/features/password_manager/presentation/widgets/sync/sync_status_hero.dart';

import '../features/password_manager/presentation/screens/database_selection_unlock_test_utils.dart';
import '../features/password_manager/presentation/screens/vault/vault_shell_test_utils.dart';
import '../goldens/golden_asset_warmup.dart';

const _outDir = 'docs/store_assets/google_play';

/// Minimal 24-bit RGB PNG encoder: `toByteData(png)` always emits an alpha
/// channel, which Google Play rejects for screenshots and the feature graphic.
Uint8List _rgbPng(int width, int height, Uint8List rgba) {
  final raw = Uint8List(height * (1 + width * 3));
  var o = 0;
  for (var y = 0; y < height; y++) {
    raw[o++] = 0; // filter: none
    for (var i = y * width * 4, end = i + width * 4; i < end; i += 4) {
      raw[o++] = rgba[i];
      raw[o++] = rgba[i + 1];
      raw[o++] = rgba[i + 2];
    }
  }
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    var crc = 0xFFFFFFFF;
    for (final b in body) {
      crc ^= b;
      for (var k = 0; k < 8; k++) {
        crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
      }
    }
    crc ^= 0xFFFFFFFF;
    final len = ByteData(4)..setUint32(0, data.length);
    final sum = ByteData(4)..setUint32(0, crc);
    out
      ..add(len.buffer.asUint8List())
      ..add(body)
      ..add(sum.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2); // colour type: RGB
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', zlib.encode(raw));
  chunk('IEND', const []);
  return out.toBytes();
}

const _dbPath = '/tmp/Personal.kdbx';

class _DemoVault implements VaultKdbxService {
  static const rootId = 'root';
  static const _otp =
      'otpauth://totp/Demo:alex@example.com?secret=JBSWY3DPEHPK3PXP&period=30&digits=6';

  static VaultEntry _e(
    String id,
    String group,
    String title,
    String user,
    String url,
    String pw, {
    String? otp,
    DateTime? changed,
  }) => VaultEntry(
    id: id,
    groupId: group,
    title: title,
    username: user,
    password: pw,
    url: url,
    notes: '',
    otpUri: otp,
    lastPasswordChangedAt: changed ?? DateTime(2026, 9, 1),
  );

  static final entries = [
    _e(
      '1',
      rootId,
      'Email',
      'alex.demo@example.com',
      'mail.example.com',
      r'Qx7#mPz9Lk2$Vw8n',
      otp: _otp,
    ),
    _e(
      '2',
      rootId,
      'Cloud Storage',
      'alex.demo@example.com',
      'cloud.example.com',
      r'Zn5!qLp8Rk3@Tx6a',
    ),
    _e(
      '3',
      'work',
      'Code Hosting',
      'alexdemo',
      'code.example.com',
      r'Tr0ub4dor&Zx9!Qp',
      otp: _otp,
    ),
    _e(
      '4',
      'work',
      'Team Chat',
      'alex.demo@example.com',
      'chat.example.com',
      r'Hl1!Nb6$Wq4@Zt9c',
    ),
    _e(
      '5',
      'finance',
      'Demo Bank',
      'alex.demo',
      'bank.example.com',
      r'Mv3#Rk8!Xp2$Ld7f',
      otp: _otp,
    ),
    _e(
      '6',
      'finance',
      'Credit Card',
      'alex.demo',
      'cards.example.com',
      r'Jb9@Ys4#Wn6!Qe1h',
    ),
    _e(
      '7',
      rootId,
      'Video Streaming',
      'family@example.com',
      'video.example.com',
      r'Pc2$Gt7!Hm5@Vz8k',
    ),
    _e(
      '8',
      rootId,
      'Music Streaming',
      'alex.demo@example.com',
      'music.example.com',
      r'Fd6!Lq3#Yr9$Bn2w',
    ),
    _e('9', rootId, 'Home router', 'admin', '192.168.1.1', 'admin'),
    _e(
      '10',
      'work',
      'Online Shop',
      'alexdemo',
      'shop.example.com',
      r'Tr0ub4dor&Zx9!Qp',
    ),
    _e(
      '11',
      rootId,
      'Library',
      'alex.demo',
      'library.example.com',
      r'Kw8#Cs1!Dv4$Nh6j',
      changed: DateTime(2020, 1, 1),
    ),
  ];

  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async => VaultSnapshot(
    rootGroupId: rootId,
    currentGroupId: currentGroupId ?? rootId,
    groups: const [
      VaultGroup(id: rootId, name: 'root', parentId: null),
      VaultGroup(id: 'work', name: 'Work', parentId: rootId),
      VaultGroup(id: 'finance', name: 'Finance', parentId: rootId),
    ],
    entries: entries,
    allEntries: entries,
  );

  @override
  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SyncRepo extends FakeDatabaseSyncRepository {}

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
    // Material icon glyphs (search, strength badge) and the 'monospace' family
    // used for OTP codes are not bundled in flutter_test.
    final icons = File(
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytesSync();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.sublistView(icons)))).load();
    final mono = File('/System/Library/Fonts/Supplemental/Andale Mono.ttf')
        .readAsBytesSync();
    await (FontLoader(
      'monospace',
    )..addFont(Future.value(ByteData.sublistView(mono)))).load();
    await warmUpGoldenAssets();
  });

  tearDown(resetVaultShellTestDi);

  Future<void> snap(
    WidgetTester tester,
    GlobalKey key,
    String platform,
    String name,
    double dpr,
  ) async {
    // SVG icons and images decode on the real event loop.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: dpr);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final file = File('$_outDir/$platform$name.png')
        ..createSync(recursive: true);
      file.writeAsBytesSync(
        _rgbPng(image.width, image.height, data!.buffer.asUint8List()),
      );
    });
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final t = find.text(label);
    await tester.tap(
      t.evaluate().isNotEmpty ? t.first : find.byTooltip(label).first,
    );
    await tester.pumpAndSettle();
  }

  final platforms = <({String name, Size logical, double dpr})>[
    // 1080x1920 px (9:16).
    (name: 'phone/', logical: const Size(432, 768), dpr: 2.5),
    // 1200x1920 px: below the detail-pane threshold, so the phone layout.
    (name: 'tablet-7/', logical: const Size(600, 960), dpr: 2.0),
    // 1600x2560 px: list + detail pane.
    (name: 'tablet-10/', logical: const Size(800, 1280), dpr: 2.0),
  ];

  testWidgets('feature graphic 1024x500', (tester) async {
    tester.view.physicalSize = const Size(1024, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    const ink = Color(0xFF40210F);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ColoredBox(
            color: const Color(0xFFFFE1D0), // adaptive icon background
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/logo/app_icon_family/custode-source-1024.png',
                  width: 380,
                  height: 380,
                ),
                const SizedBox(width: 8),
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Custode',
                      style: TextStyle(
                        fontFamily: 'Caprasimo',
                        fontSize: 104,
                        height: 1.1,
                        color: ink,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Open-source KeePass password manager',
                      style: TextStyle(
                        fontFamily: 'Figtree',
                        fontWeight: FontWeight.w600,
                        fontSize: 27,
                        color: ink,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await snap(tester, key, '', 'feature-graphic', 1);
  });

  for (final p in platforms) {
    // Same width authority the app uses, so each variant gets its real layout.
    final wide = VaultLayoutClass.fromWidth(p.logical.width).hasDetailPane;
    final key = GlobalKey();

    Future<void> setup(WidgetTester tester, Widget w) async {
      tester.view.physicalSize = Size(
        p.logical.width * p.dpr,
        p.logical.height * p.dpr,
      );
      tester.view.devicePixelRatio = p.dpr;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(RepaintBoundary(key: key, child: w));
      await tester.pumpAndSettle();
    }

    Future<Widget> shell({_SyncRepo? sync}) => pumpableVaultShell(
      databasePath: _dbPath,
      themeMode: ThemeMode.light,
      vaultKdbxService: _DemoVault(),
      databaseSyncRepository: sync,
    );

    testWidgets('${p.name} 01 vault', (tester) async {
      await setup(tester, await shell());
      if (wide) {
        await tester.tap(find.text('Cloud Storage').first);
        await tester.pumpAndSettle();
      }
      await snap(tester, key, p.name, '01-vault', p.dpr);
    });

    testWidgets('${p.name} 02 detail', (tester) async {
      await setup(tester, await shell());
      await tester.tap(find.text('Email').first);
      await tester.pumpAndSettle();
      await snap(tester, key, p.name, '02-entry-detail', p.dpr);
    });

    testWidgets('${p.name} 03 generator', (tester) async {
      await setup(tester, await shell());
      await tap(tester, 'Settings');
      await tester.ensureVisible(find.text('Password generator'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Password generator'));
      await tester.pumpAndSettle();
      await snap(tester, key, p.name, '03-generator', p.dpr);
    });

    testWidgets('${p.name} 04 unlock', (tester) async {
      final result = await pumpableUnlockScreen(
        databasePath: _dbPath,
        records: [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: _dbPath,
            displayName: 'Personal.kdbx',
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
      await setup(tester, result.widget);
      await snap(tester, key, p.name, '04-unlock', p.dpr);
      await resetDatabaseTestDi();
    });

    testWidgets('${p.name} 05 health', (tester) async {
      await setup(tester, await shell());
      await tap(tester, 'Health');
      await snap(tester, key, p.name, '05-health', p.dpr);
    });

    testWidgets('${p.name} 06 sync', (tester) async {
      final fixedNow = DateTime(2026, 11, 14, 10, 0);
      SyncStatusHero.debugNowOverride = fixedNow;
      addTearDown(() => SyncStatusHero.debugNowOverride = null);
      final repo = _SyncRepo()
        ..connected = true
        ..mappings[_dbPath] = DatabaseSyncMapping(
          databasePath: _dbPath,
          providerId: 'google_drive',
          remoteFileId: 'file-123',
          remoteFileName: 'Personal.kdbx',
          lastSyncAt: fixedNow.subtract(const Duration(minutes: 12)),
          lastSyncedLocalChecksum: 'a91f00000000000000000000000000007c40',
        );
      await setup(tester, await shell(sync: repo));
      await tap(tester, 'Sync');
      await snap(tester, key, p.name, '06-sync', p.dpr);
    });
  }
}
