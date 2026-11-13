// spec-004 T24: exact golden inventory — 18 files across the 13 named
// screens in spec.md's "Screens" table (several screens have a
// light/dark and/or 390×844/1024×768 pair). Same deterministic-render
// pattern as database_and_unlock_test.dart / vault_shell_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/utils/clipboard_guard.dart';
import 'package:password_manager/core/widgets/kv_pill_button.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';
import 'package:password_manager/injection_container.dart' as di;
import 'package:path/path.dart' as p;

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';

/// Exact 18-file inventory (spec-004 spec.md "Screens" table, expanded per
/// listed size/theme variant). Order matches the spec table.
const exactGoldenInventory = <String>[
  'entry_detail_hidden_390x844_light.png',
  'entry_detail_hidden_390x844_dark.png',
  'entry_detail_hidden_1024x768_light.png',
  'entry_detail_revealed_totp_390x844_light.png',
  'entry_detail_revealed_totp_390x844_dark.png',
  'entry_biometric_gate_390x844_light.png',
  'entry_copy_confirmation_390x844_light.png',
  'entry_weak_reused_390x844_light.png',
  'editor_new_item_390x844_light.png',
  'editor_new_item_1024x768_light.png',
  'editor_generator_sheet_390x844_light.png',
  'editor_generator_column_1024x768_light.png',
  'editor_errors_390x844_light.png',
  'editor_qr_scanner_390x844.png',
  'editor_camera_denied_390x844_light.png',
  'editor_discard_390x844_light.png',
  'editor_saving_390x844_light.png',
  'generator_standalone_390x844_light.png',
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
    // TOTP codes/countdowns are wall-clock-real by design — freeze "now"
    // for the whole file so the revealed+TOTP goldens (and every entry's
    // "changed N months ago" caption) are deterministic regardless of when
    // or how long the suite takes to run. Matches the fixture's own
    // reference `now` (entry_editor_generator_test_utils.dart).
    debugEntryDetailNowOverride = () => DateTime.utc(2026, 3, 12, 9, 30);
  });

  tearDownAll(() {
    debugEntryDetailNowOverride = DateTime.now;
  });

  tearDown(resetEntryTestDi);

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // The entry-detail screen runs a 1s `Timer.periodic` ticker (TOTP +
  // reveal countdown, spec-004's shared-ticker non-negotiable) for as long
  // as it's mounted. flutter_test asserts no timer is left pending when a
  // test ends, so every test that opens entry detail must unmount it
  // (cancelling the ticker via dispose()) before finishing.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  // --- Entry detail: hidden (mobile L/D, tablet L) -------------------------
  const hiddenCases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'entry_detail_hidden_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'entry_detail_hidden_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'entry_detail_hidden_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
  ];

  for (final testCase in hiddenCases) {
    testWidgets(testCase.name, (tester) async {
      await setSize(tester, testCase.size);
      await tester.pumpWidget(
        await pumpableEntryScreen(themeMode: testCase.themeMode),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('GitHub').first);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
      await unmount(tester);
    });
  }

  // --- Entry detail: revealed + TOTP (mobile L/D) ---------------------------
  const revealedCases = <({String name, ThemeMode themeMode})>[
    (
      name: 'entry_detail_revealed_totp_390x844_light.png',
      themeMode: ThemeMode.light,
    ),
    (
      name: 'entry_detail_revealed_totp_390x844_dark.png',
      themeMode: ThemeMode.dark,
    ),
  ];

  for (final testCase in revealedCases) {
    testWidgets(testCase.name, (tester) async {
      await setSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        await pumpableEntryScreen(themeMode: testCase.themeMode),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Banca Sella'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
      await unmount(tester);
    });
  }

  // --- Biometric gate before reveal ------------------------------------------
  testWidgets('entry_biometric_gate_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    final harness = EntryTestHarness()..biometricEnabledForDatabase = true;
    await tester.pumpWidget(await pumpableEntryScreen(harness: harness));
    await tester.pumpAndSettle();

    await tester.tap(find.text('GitHub').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('entry_biometric_gate_390x844_light.png'),
    );
    await unmount(tester);
  });

  // --- Copy confirmation (toast) ----------------------------------------------
  testWidgets('entry_copy_confirmation_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();

    await tester.tap(find.text('GitHub').first);
    await tester.pumpAndSettle();
    // 2026-08-31: the Copy password pill is gone — copy via the password
    // row's own button.
    await tester.tap(find.byTooltip('Copy').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('entry_copy_confirmation_390x844_light.png'),
    );
    // Let the toast's own 1600ms auto-hide timer fire before tearing down
    // (it's a top-level global timer, not cancelled by disposing the tree).
    await tester.pump(const Duration(milliseconds: 1700));
    // ClipboardGuard is a DI app-lifetime singleton (see spec-004 fix):
    // its 30s clear timer outlives this screen's dispose(), so it must be
    // cancelled explicitly or flutter_test's pending-timer check fails.
    di.sl<ClipboardGuard>().dispose();
    await unmount(tester);
  });

  // --- Weak / reused warning ----------------------------------------------------
  testWidgets('entry_weak_reused_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Netflix').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('entry_weak_reused_390x844_light.png'),
    );
    await unmount(tester);
  });

  Future<void> openNewItemEditor(WidgetTester tester) async {
    // spec-019 T045: one affordance, in the header, filing into the selected
    // folder — not an action on a folder row inside the records list.
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add record'));
    await tester.pumpAndSettle();
  }

  // --- Editor: new item (mobile/tablet) ----------------------------------------
  testWidgets('editor_new_item_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();
    await openNewItemEditor(tester);

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('editor_new_item_390x844_light.png'),
    );
  });

  testWidgets('editor_new_item_1024x768_light.png', (tester) async {
    await setSize(tester, const Size(1024, 768));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();
    await openNewItemEditor(tester);

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('editor_new_item_1024x768_light.png'),
    );
  });

  // --- Editor: generator sheet (mobile sheet / tablet 3rd column) --------------
  testWidgets('editor_generator_sheet_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();
    await openNewItemEditor(tester);

    await tester.tap(find.byTooltip('Generate secure password'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('editor_generator_sheet_390x844_light.png'),
    );
    await unmount(tester);
  });

  testWidgets('editor_generator_column_1024x768_light.png', (tester) async {
    await setSize(tester, const Size(1024, 768));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();
    await openNewItemEditor(tester);

    await tester.tap(find.byTooltip('Generate secure password'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('editor_generator_column_1024x768_light.png'),
    );
    await unmount(tester);
  });

  // --- Editor: constraint errors ------------------------------------------------
  // spec-022 F-001: dark added — the error text was a hard-coded light-ramp
  // colour and vanished on the dark ground.
  for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
    final name =
        'editor_errors_390x844_${themeMode == ThemeMode.dark ? 'dark' : 'light'}.png';
    testWidgets(name, (tester) async {
      await setSize(tester, const Size(390, 844));
      await tester.pumpWidget(await pumpableEntryScreen(themeMode: themeMode));
      await tester.pumpAndSettle();
      await openNewItemEditor(tester);

      await tester.tap(find.text('One-time code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, 'not-a-uri');
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(name));
    });
  }

  // --- QR scanner / camera denied (forced to a mobile platform: the QR ------
  // scan affordance and mobile_scanner are Android/iOS-only per
  // _supportsOtpQrScan()) ------------------------------------------------------
  group('QR / camera-denied (Android platform override)', () {
    // The QR scan affordance and mobile_scanner are Android/iOS-only per
    // _supportsOtpQrScan(); the override is set/reset inside each test body
    // (not group setUp/tearDown) so it never outlives that specific test —
    // flutter_test's foundation-debug-var invariant check runs before
    // group-level tearDown callbacks would otherwise restore it.
    //
    // mobile_scanner has no platform implementation under `flutter test`.
    // `_controller.start()`'s MissingPluginException is caught by the
    // screen itself (-> camera-denied UI, exactly what we want to golden).
    // But the plugin *also* opens two EventChannels (barcode + device
    // orientation) on mount, independent of that catch, and an unhandled
    // EventChannel error fails the whole test — those two are muted here
    // at the binary-messenger level (the 'stop' method call fired on
    // dispose is muted for the same reason).
    const methodChannel = MethodChannel(
      'dev.steenbakker.mobile_scanner/scanner/method',
    );
    const eventChannel = MethodChannel(
      'dev.steenbakker.mobile_scanner/scanner/event',
    );
    const orientationChannel = MethodChannel(
      'dev.steenbakker.mobile_scanner/scanner/deviceOrientation',
    );

    void muteScannerEventChannels({required bool hangStart}) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(eventChannel, (_) async => null);
      messenger.setMockMethodCallHandler(orientationChannel, (_) async => null);
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        if (call.method == 'stop') return null;
        // `hangStart`: never resolve, so the controller stays in its
        // "about to start" state forever — used for the QR-scanner-chrome
        // golden, so it can safely `pumpAndSettle` (finishing the route
        // transition) without also racing the plugin's inevitable "no
        // native implementation" failure into view.
        // Otherwise: fail immediately — the camera-denied trigger this
        // test group exists to exercise.
        if (hangStart) return Completer<Object?>().future;
        throw MissingPluginException();
      });
    }

    void unmuteScannerEventChannels() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(eventChannel, null);
      messenger.setMockMethodCallHandler(orientationChannel, null);
      messenger.setMockMethodCallHandler(methodChannel, null);
      // From mobile_scanner 7.5.0 every start waits on one static session
      // lock. The scanner-chrome golden never resolves its start, so without
      // this reset it holds that lock for the rest of the file: later starts
      // wait instead of failing, and the camera-denied screen never shows.
      MobileScannerController.resetPlatformSessionOwner();
    }

    Future<void> openScanner(WidgetTester tester) async {
      await tester.tap(find.text('One-time code'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Scan QR'));
      await tester.pumpAndSettle();
    }

    testWidgets('editor_qr_scanner_390x844.png', (tester) async {
      final originalPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      muteScannerEventChannels(hangStart: true);
      // `finally` (not end-of-body cleanup, not addTearDown): guarantees the
      // debug-var + mock-channel reset runs even if the golden assertion
      // below throws, so a failure here can't leak dirty global state into
      // later tests in this file. addTearDown doesn't work for
      // debugDefaultTargetPlatformOverride specifically — flutter_test's
      // foundation-debug-var invariant check runs synchronously right after
      // the test body returns, before any addTearDown callback fires.
      try {
        await setSize(tester, const Size(390, 844));
        await tester.pumpWidget(await pumpableEntryScreen());
        await tester.pumpAndSettle();
        await openNewItemEditor(tester);
        await openScanner(tester);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('editor_qr_scanner_390x844.png'),
        );

        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = originalPlatform;
        unmuteScannerEventChannels();
        await unmount(tester);
      }
    });

    testWidgets('editor_camera_denied_390x844_light.png', (tester) async {
      final originalPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      muteScannerEventChannels(hangStart: false);
      try {
        await setSize(tester, const Size(390, 844));
        await tester.pumpWidget(await pumpableEntryScreen());
        await tester.pumpAndSettle();
        await openNewItemEditor(tester);
        await tester.tap(find.text('One-time code'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Scan QR'));
        // Let the (inevitable, no-camera-in-tests) controller error resolve.
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('editor_camera_denied_390x844_light.png'),
        );
      } finally {
        debugDefaultTargetPlatformOverride = originalPlatform;
        unmuteScannerEventChannels();
        await unmount(tester);
      }
    });

    // Regression for T16: `_CameraDeniedScreen` was a StatelessWidget that
    // computed the "Save the URI" button's enabled state once at build time
    // from `manualUriController.text`, with no listener on the controller —
    // typing in the field never rebuilt the button, so it stayed disabled
    // forever. Fails pre-fix (button stays disabled after enterText),
    // passes post-fix (ValueListenableBuilder rebuilds on every keystroke).
    testWidgets(
      'camera denied: "Save the URI" button enables reactively as the user '
      'types a valid otpauth:// URI, single standard pump after enterText '
      'is enough — no pumpAndSettle needed',
      (tester) async {
        final originalPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        muteScannerEventChannels(hangStart: false);
        try {
          await setSize(tester, const Size(390, 844));
          await tester.pumpWidget(await pumpableEntryScreen());
          await tester.pumpAndSettle();
          await openNewItemEditor(tester);
          await tester.tap(find.text('One-time code'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Scan QR'));
          await tester.pumpAndSettle();

          KvSecondaryPillButton saveUriButton() =>
              tester.widget<KvSecondaryPillButton>(
                find.widgetWithText(KvSecondaryPillButton, 'Save the URI'),
              );

          expect(saveUriButton().onPressed, isNull);

          await tester.enterText(
            find.byType(TextFormField),
            'otpauth://totp/Sella:CB77219?secret=ABC',
          );
          await tester.pump();

          expect(saveUriButton().onPressed, isNotNull);
        } finally {
          debugDefaultTargetPlatformOverride = originalPlatform;
          unmuteScannerEventChannels();
          await unmount(tester);
        }
      },
    );
  });

  // --- Discard changes ------------------------------------------------------------
  testWidgets('editor_discard_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();
    await openNewItemEditor(tester);

    await tester.enterText(find.byType(TextFormField).first, 'Netflix');
    await tester.pump();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('editor_discard_390x844_light.png'),
    );
  });

  // --- Saving overlay ---------------------------------------------------------------
  testWidgets('editor_saving_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();
    await openNewItemEditor(tester);

    await tester.enterText(find.byType(TextFormField).first, 'Netflix');
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('editor_saving_390x844_light.png'),
    );
    // Let the (deliberately not-yet-settled) 250ms save delay resolve
    // before the test ends, so its Timer doesn't outlive the widget tree.
    await tester.pumpAndSettle();
  });

  // --- Generator standalone (Vault destination entry point) -----------------------
  testWidgets('generator_standalone_390x844_light.png', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(await pumpableEntryScreen());
    await tester.pumpAndSettle();

    // 2026-08-31: the `⋮` sheet is retired; the standalone generator lives
    // in the Settings destination.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Password generator'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Password generator'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('generator_standalone_390x844_light.png'),
    );
  });

  // --- Inventory integrity: exactly 18 named files, all present on disk -----------
  test('exact golden inventory has exactly 18 files, all generated', () {
    expect(exactGoldenInventory.toSet().length, 18);
    expect(exactGoldenInventory.length, 18);

    final goldensDir = Directory(
      p.join(Directory.current.path, 'test', 'goldens'),
    );
    for (final name in exactGoldenInventory) {
      final file = File(p.join(goldensDir.path, name));
      expect(file.existsSync(), isTrue, reason: '$name must exist on disk');
    }
  });
}
