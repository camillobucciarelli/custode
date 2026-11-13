// spec 017 T501: the history view's golden inventory (plan.md) — the list
// at both widths in light and dark, the empty state, and a revealed
// revision. Same deterministic-render pattern as
// entry_editor_generator_test.dart.
//
// Order-independence rules (AGENTS.md): `warmUpGoldenAssets()` in
// `setUpAll`; nothing here resolves `di.sl<T>()` in a `dispose()`.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry_revision.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';
import 'golden_asset_warmup.dart';

/// Fixed fake secrets (Constitution IV): the revealed golden photographs
/// [_revealedSecret], and nothing else ever should.
const _revealedSecret = 'Fixture-Old-Pass-9z';
const _olderSecret = 'fixture-older-password';

/// Three revisions of the GitHub fixture: a password change, a
/// notes-and-custom-field change, and one with a different attachment set.
VaultEntryHistory _githubHistory() => VaultEntryHistory(
  revisions: [
    VaultEntryRevision(
      entryId: 'e-github',
      replacedAt: DateTime.utc(2026, 3, 2, 10, 30),
      title: 'GitHub',
      username: 'camillo@bucciarelli.dev',
      password: _revealedSecret,
      url: 'https://github.com',
      notes:
          'Recovery codes in the attachment. SSO via Google disabled on '
          'purpose.',
      customFields: const [
        VaultCustomField(key: 'Codice cliente', value: '88-4412-C'),
      ],
      attachmentNames: const ['mfa-recovery-codes.txt'],
    ),
    VaultEntryRevision(
      entryId: 'e-github',
      replacedAt: DateTime.utc(2026, 2, 14, 18, 5),
      title: 'GitHub',
      username: 'camillo@bucciarelli.dev',
      password: _revealedSecret,
      url: 'https://github.com',
      notes: 'Recovery codes in the attachment.',
      attachmentNames: const ['mfa-recovery-codes.txt'],
    ),
    VaultEntryRevision(
      entryId: 'e-github',
      replacedAt: DateTime.utc(2026, 1, 4, 8, 0),
      title: 'GitHub',
      username: 'camillo@bucciarelli.dev',
      password: _olderSecret,
      url: 'https://github.com',
      notes: 'Recovery codes in the attachment.',
    ),
  ],
  retention: const VaultHistoryRetention(maxItems: 10),
);

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

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Both the detail and the history dialog run a 1 s ticker; unmount so
  /// no timer is left pending when the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> openHistory(
    WidgetTester tester, {
    required Size size,
    required ThemeMode themeMode,
    required EntryTestHarness harness,
  }) async {
    await setSize(tester, size);
    await tester.pumpWidget(
      await pumpableEntryScreen(harness: harness, themeMode: themeMode),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub').first);
    await tester.pumpAndSettle();
    final chip = find.text('View history');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  const listCases = <({String name, Size size, ThemeMode themeMode})>[
    (
      name: 'vault_entry_history_list_390x844_light.png',
      size: Size(390, 844),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'vault_entry_history_list_390x844_dark.png',
      size: Size(390, 844),
      themeMode: ThemeMode.dark,
    ),
    (
      name: 'vault_entry_history_list_wide_1024x768_light.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.light,
    ),
    (
      name: 'vault_entry_history_list_wide_1024x768_dark.png',
      size: Size(1024, 768),
      themeMode: ThemeMode.dark,
    ),
  ];

  for (final testCase in listCases) {
    testWidgets(testCase.name, (tester) async {
      final harness = EntryTestHarness()
        ..histories['e-github'] = _githubHistory();
      await openHistory(
        tester,
        size: testCase.size,
        themeMode: testCase.themeMode,
        harness: harness,
      );

      expect(tester.takeException(), isNull);
      // Masked: no fixture secret is on screen.
      expect(find.text(_revealedSecret), findsNothing);
      expect(find.text(_olderSecret), findsNothing);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
      await unmount(tester);
    });
  }

  testWidgets('vault_entry_history_empty_390x844_light.png', (tester) async {
    await openHistory(
      tester,
      size: const Size(390, 844),
      themeMode: ThemeMode.light,
      harness: EntryTestHarness(),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No previous versions'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('vault_entry_history_empty_390x844_light.png'),
    );
    await unmount(tester);
  });

  testWidgets('vault_entry_history_revealed_390x844_dark.png', (tester) async {
    final harness = EntryTestHarness()
      ..histories['e-github'] = _githubHistory();
    await openHistory(
      tester,
      size: const Size(390, 844),
      themeMode: ThemeMode.dark,
      harness: harness,
    );
    await tester.tap(find.byTooltip('Show this version’s password').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(_revealedSecret), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('vault_entry_history_revealed_390x844_dark.png'),
    );
    await unmount(tester);
  });
}
