// spec 023 T202 — the entry detail's passkey section. Metadata only: the
// section must never put the private key in the widget tree, must never
// offer copy or reveal on a passkey value, and must say in words when a
// passkey cannot be used to sign in (FR-009, FR-011, FR-012).
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_group.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';

import 'entry_editor_generator_test_utils.dart';

/// Stands in for the stored private key. Deliberately NOT PEM-shaped: nothing
/// in this layer parses the value — the property under test is that no part of
/// it is rendered — and a real PEM block here is reported as a leaked key by
/// both secret scanners on every commit that touches the file.
///
/// Multi-line and distinctive for the same reason a real key would be: each
/// line is searched for on screen individually, so a partial render is caught
/// too.
const _pem =
    'KEYVAULT-FIXTURE-PRIVATE-VALUE-LINE-1\n'
    'KEYVAULT-FIXTURE-PRIVATE-VALUE-LINE-2\n'
    'KEYVAULT-FIXTURE-PRIVATE-VALUE-LINE-3';

VaultPasskey _passkey({
  String relyingPartyId = 'webauthn.io',
  String username = 'ada@example.com',
  VaultPasskeyAlgorithm algorithm = VaultPasskeyAlgorithm.es256,
  bool backupEligible = true,
  bool backupState = true,
  VaultPasskeyUnusableReason? unusableReason,
  String fieldSuffix = '',
}) => VaultPasskey(
  relyingPartyId: relyingPartyId,
  credentialId: Uint8List.fromList([1, 2, 3, 4]),
  privateKeyPem: _pem,
  algorithm: algorithm,
  username: username,
  backupEligible: backupEligible,
  backupState: backupState,
  createdAt: DateTime(2026, 3, 4, 10, 30),
  fieldSuffix: fieldSuffix,
  unusableReason: unusableReason,
);

VaultSnapshot _snapshot({required List<VaultPasskey> passkeys}) {
  final withPasskey = VaultEntry(
    id: 'e-passkey',
    groupId: kRootGroupId,
    title: 'Webauthn',
    username: 'ada@example.com',
    password: '',
    url: 'https://webauthn.io',
    notes: '',
    passkeys: passkeys,
    passkeyDigest: 'digest',
  );
  const plain = VaultEntry(
    id: 'e-plain',
    groupId: kRootGroupId,
    title: 'Plain',
    username: 'ada@example.com',
    password: 'Fixture-Pass-9d!z',
    url: '',
    notes: '',
  );
  return VaultSnapshot(
    rootGroupId: kRootGroupId,
    currentGroupId: kRootGroupId,
    groups: const [VaultGroup(id: kRootGroupId, name: 'Vault', parentId: null)],
    entries: [withPasskey, plain],
    allEntries: [withPasskey, plain],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetEntryTestDi);

  Future<void> pumpDetail(
    WidgetTester tester, {
    required List<VaultPasskey> passkeys,
    String open = 'Webauthn',
  }) async {
    final harness = EntryTestHarness(snapshot: _snapshot(passkeys: passkeys));
    await tester.pumpWidget(await pumpableEntryScreen(harness: harness));
    await tester.pumpAndSettle();
    await tester.tap(find.text(open).first);
    await tester.pumpAndSettle();
  }

  // T201 / FR-011: the list says which records hold a passkey, in words as
  // well as in a glyph.
  testWidgets('the records list badges only the record with a passkey', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    final harness = EntryTestHarness(
      snapshot: _snapshot(passkeys: [_passkey()]),
    );
    await tester.pumpWidget(await pumpableEntryScreen(harness: harness));
    await tester.pumpAndSettle();

    // One record holds a passkey, so exactly one row announces it — and the
    // signal is a word, not the glyph's colour (Constitution V). Matched as
    // a pattern because the badge merges into the row's own announcement
    // ("Webauthn, ada@example.com, Passkey, Password healthy") rather than
    // interrupting it with a node of its own.
    expect(find.bySemanticsLabel(RegExp('Passkey')), findsOneWidget);
    semanticsHandle.dispose();
  });

  testWidgets('shows the passkey metadata and the fixed security note', (
    tester,
  ) async {
    await pumpDetail(tester, passkeys: [_passkey()]);

    expect(find.byKey(const ValueKey('entry-detail-passkeys')), findsOneWidget);
    expect(find.text('webauthn.io'), findsOneWidget);
    expect(find.text('ada@example.com'), findsWidgets);
    expect(find.text('ES256 (ECDSA P-256)'), findsOneWidget);
    expect(find.text('Backed up across devices'), findsOneWidget);
    // FR-009: the vault's security model, said plainly.
    expect(
      find.textContaining('not held in hardware key isolation'),
      findsOneWidget,
    );
  });

  testWidgets('never renders the private key, and offers no copy or reveal', (
    tester,
  ) async {
    await pumpDetail(tester, passkeys: [_passkey()]);

    for (final line in _pem.split('\n')) {
      expect(find.textContaining(line), findsNothing);
    }
    // Scoped to the section: the record's own Username row keeps its copy
    // button, and this is about the passkey's values, not the record's.
    final section = find.byKey(const ValueKey('entry-detail-passkeys'));
    expect(
      find.descendant(of: section, matching: find.byTooltip('Copy')),
      findsNothing,
    );
    expect(
      find.descendant(of: section, matching: find.byType(IconButton)),
      findsNothing,
    );
    // The record has no password, so an eye anywhere on this screen could
    // only belong to the passkey.
    expect(find.byTooltip('Show password'), findsNothing);
    expect(find.byTooltip('Show value'), findsNothing);
  });

  testWidgets('an unusable passkey says it cannot sign in, and why', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      passkeys: [_passkey(unusableReason: VaultPasskeyUnusableReason.badKey)],
    );

    expect(find.text('Unusable'), findsOneWidget);
    expect(
      find.textContaining('cannot be used to sign in: its stored key cannot'),
      findsOneWidget,
    );
  });

  testWidgets('a record with no passkey has no section', (tester) async {
    await pumpDetail(tester, passkeys: const [], open: 'Plain');

    expect(find.byKey(const ValueKey('entry-detail-passkeys')), findsNothing);
  });

  testWidgets('two passkeys on one record are two cards', (tester) async {
    await pumpDetail(
      tester,
      passkeys: [
        _passkey(),
        _passkey(relyingPartyId: 'example.org', fieldSuffix: '_1'),
      ],
    );

    expect(find.text('webauthn.io'), findsOneWidget);
    expect(find.text('example.org'), findsOneWidget);
    expect(find.text('Delete passkey'), findsNWidgets(2));
  });

  testWidgets('delete asks first, names the site and account, and cancels', (
    tester,
  ) async {
    await pumpDetail(tester, passkeys: [_passkey()]);

    await tester.ensureVisible(find.text('Delete passkey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete passkey'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this passkey?'), findsOneWidget);
    expect(find.textContaining('webauthn.io'), findsWidgets);
    expect(find.textContaining('cannot be recovered'), findsOneWidget);
    expect(find.textContaining('dated copy of the vault'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Cancel changes nothing: the card is still there.
    expect(find.text('webauthn.io'), findsOneWidget);
  });
}
