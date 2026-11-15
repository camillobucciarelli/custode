// spec 024 T006 (023 T211): the record the passkey goldens photograph and
// the setup the three passkey golden files share.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';
import 'golden_asset_warmup.dart';

/// Stands in for the stored private key. Deliberately not PEM-shaped (same
/// convention as vault_entry_passkeys_test.dart): the goldens assert that no
/// line of it is rendered, and a real PEM block would trip the secret
/// scanners and the redaction grep.
const passkeyFixturePrivateValue =
    'KEYVAULT-FIXTURE-PRIVATE-VALUE-LINE-1\n'
    'KEYVAULT-FIXTURE-PRIVATE-VALUE-LINE-2';

const passkeyRecordTitle = 'Webauthn';

/// The standard fixture plus one record holding a passkey.
VaultSnapshot buildPasskeySnapshot({
  VaultPasskeyUnusableReason? unusableReason,
}) {
  final base = buildFixtureSnapshot();
  final record = VaultEntry(
    id: 'e-passkey',
    groupId: kRootGroupId,
    title: passkeyRecordTitle,
    username: 'ada@example.com',
    password: '',
    url: 'https://webauthn.io',
    notes: '',
    passkeys: [
      VaultPasskey(
        relyingPartyId: 'webauthn.io',
        credentialId: Uint8List.fromList([1, 2, 3, 4]),
        privateKeyPem: passkeyFixturePrivateValue,
        algorithm: VaultPasskeyAlgorithm.es256,
        username: 'ada@example.com',
        createdAt: DateTime(2026, 3, 4, 10, 30),
        unusableReason: unusableReason,
      ),
    ],
    passkeyDigest: 'digest',
    createdAt: DateTime(2024, 1, 4),
    updatedAt: DateTime(2026, 3, 12, 9, 30),
  );
  final entries = [record, ...base.entries];
  return VaultSnapshot(
    rootGroupId: base.rootGroupId,
    currentGroupId: base.currentGroupId,
    groups: base.groups,
    entries: entries,
    allEntries: entries,
  );
}

/// Fonts, asset warm-up, frozen clock and DI reset. Call first in `main()`.
///
/// Order-independence rules (AGENTS.md): `warmUpGoldenAssets()` in
/// `setUpAll`; nothing here resolves `di.sl<T>()` in a `dispose()`.
void setUpPasskeyGoldens() {
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
}

/// Pumps the vault at [size] on the passkey snapshot, list showing.
Future<void> pumpPasskeyVault(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  ThemeMode themeMode = ThemeMode.light,
  VaultPasskeyUnusableReason? unusableReason,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    await pumpableEntryScreen(
      harness: EntryTestHarness(
        snapshot: buildPasskeySnapshot(unusableReason: unusableReason),
      ),
      themeMode: themeMode,
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the passkey record and brings its passkey section into the frame.
Future<void> openPasskeySection(WidgetTester tester) async {
  await tester.tap(find.text(passkeyRecordTitle).first);
  await tester.pumpAndSettle();
  await tester.ensureVisible(
    find.byKey(const ValueKey('entry-detail-passkeys')),
  );
  await tester.pumpAndSettle();
}

/// Asserts no line of the stored private value is on screen, compares with
/// [name], then unmounts: the detail runs a 1 s ticker that must not outlive
/// the test.
Future<void> expectPasskeyGolden(WidgetTester tester, String name) async {
  for (final line in passkeyFixturePrivateValue.split('\n')) {
    expect(find.textContaining(line), findsNothing);
  }
  expect(tester.takeException(), isNull);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile(name));
  await tester.pumpWidget(const SizedBox());
}
