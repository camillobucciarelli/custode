// spec-005 T20/AC5: merge preview sheet shows exactly the five
// `MergePreview` flags — no more, no fewer.
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/widgets/kv_pill_button.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_group.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';

import 'vault_shell_test_utils.dart';

/// spec 023 T207 — a passkey-only entry and a password entry for one account.
///
/// With [conflict] the two entries instead share a username and a password
/// across two sites and each holds a passkey for the same account. That is a
/// *credentials* group (pass 1), which is the only way the two can end up in
/// one group while both hold a credential: the site pass drops two passkey
/// holders rather than offering a merge that would have to pick one.
class _PasskeyPairingVaultKdbxService implements VaultKdbxService {
  _PasskeyPairingVaultKdbxService({this.conflict = false});

  final bool conflict;

  static VaultPasskey _passkey(String handle) => VaultPasskey(
    relyingPartyId: 'webauthn.io',
    credentialId: Uint8List.fromList(utf8.encode('cred-$handle')),
    userHandle: Uint8List.fromList(utf8.encode(handle)),
    privateKeyPem: 'FIXTURE-KEY-$handle',
    algorithm: VaultPasskeyAlgorithm.es256,
    username: 'alice',
  );

  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async {
    const rootId = 'root';
    final withPassword = VaultEntry(
      id: 'with-password',
      groupId: rootId,
      title: 'webauthn.io',
      username: 'alice',
      password: conflict ? 'shared-pw' : 'secret-pw',
      url: 'https://webauthn.io',
      notes: 'notes',
      passkeys: conflict ? [_passkey('handle-1')] : const [],
      updatedAt: DateTime(2024),
    );
    final withPasskey = VaultEntry(
      id: 'with-passkey',
      groupId: rootId,
      title: 'webauthn.io passkey',
      username: 'alice',
      password: conflict ? 'shared-pw' : '',
      url: conflict ? 'https://webauthn.dev' : 'https://webauthn.io',
      notes: '',
      passkeys: [_passkey('handle-1')],
      updatedAt: DateTime(2026),
    );

    return VaultSnapshot(
      rootGroupId: rootId,
      currentGroupId: currentGroupId ?? rootId,
      groups: const [VaultGroup(id: rootId, name: 'root', parentId: null)],
      entries: [withPassword, withPasskey],
      allEntries: [withPassword, withPasskey],
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

class _DuplicatesVaultKdbxService implements VaultKdbxService {
  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async {
    const rootId = 'root';
    final primary = VaultEntry(
      id: 'primary',
      groupId: rootId,
      title: 'Netflix',
      username: 'user@example.com',
      password: 'primary-pw',
      url: 'netflix.com',
      notes: '', // empty -> willCopyNotes should be true
      updatedAt: DateTime(2026, 1, 2),
    );
    final secondary = VaultEntry(
      id: 'secondary',
      groupId: rootId,
      title: 'Netflix family',
      username: 'user@example.com',
      password: 'secondary-pw',
      url: 'netflix.com',
      notes: 'Family plan notes',
      customFields: const [VaultCustomField(key: 'Plan', value: 'Family')],
      updatedAt: DateTime(2024, 1, 4),
    );

    return VaultSnapshot(
      rootGroupId: rootId,
      currentGroupId: currentGroupId ?? rootId,
      groups: const [VaultGroup(id: rootId, name: 'root', parentId: null)],
      entries: [primary, secondary],
      allEntries: [primary, secondary],
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

  tearDown(resetVaultShellTestDi);

  testWidgets('merge preview sheet renders exactly 5 MergePreview flag rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: _DuplicatesVaultKdbxService()),
    );
    await tester.pumpAndSettle();

    // Vault -> Health -> Duplicates category -> group card -> Merge.
    await tester.tap(find.text('Health'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge and move duplicate'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final flagRowKeys = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('merge-flag-row-');
    });
    expect(
      flagRowKeys,
      findsNWidgets(5),
      reason: 'exactly the five MergePreview flags — no more, no fewer',
    );

    // Sanity: the five concepts are exactly
    // notes/attachments/customFields/urls/otp.
    expect(find.byKey(const ValueKey('merge-flag-row-notes')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('merge-flag-row-attachments')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('merge-flag-row-customFields')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('merge-flag-row-urls')), findsOneWidget);
    expect(find.byKey(const ValueKey('merge-flag-row-otp')), findsOneWidget);
  });

  group('spec 023 T207 — the passkey pairing in Vault health', () {
    Future<void> openMergePreview(
      WidgetTester tester,
      VaultKdbxService service,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        await pumpableVaultShell(vaultKdbxService: service),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Health'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicates'));
      await tester.pumpAndSettle();
    }

    testWidgets('the group says what makes it one account', (tester) async {
      await openMergePreview(tester, _PasskeyPairingVaultKdbxService());

      expect(
        find.textContaining('same account, one holds the passkey'),
        findsOneWidget,
      );
    });

    testWidgets('the preview names the credential and the backup', (
      tester,
    ) async {
      await openMergePreview(tester, _PasskeyPairingVaultKdbxService());
      await tester.tap(find.text('Merge and move duplicate'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('merge-flag-row-passkey')),
        findsOneWidget,
      );
      expect(
        find.textContaining('webauthn.io will move to the kept record'),
        findsOneWidget,
      );
      expect(
        find.textContaining('A dated copy of the vault is saved first'),
        findsOneWidget,
      );
      // FR-008: the credential is one named row, never its fields.
      expect(find.textContaining('FIXTURE-KEY'), findsNothing);
      expect(find.textContaining('PRIVATE_KEY'), findsNothing);
    });

    testWidgets('two passkeys for one account refuse the merge', (
      tester,
    ) async {
      await openMergePreview(
        tester,
        // Same rpId and the same handle on both sides.
        _PasskeyPairingVaultKdbxService(conflict: true),
      );
      await tester.tap(find.text('Merge and move duplicate'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot be merged'), findsOneWidget);
      expect(
        find.textContaining('which of the two passkeys it still accepts'),
        findsOneWidget,
      );
      final button = tester.widget<KvPillButton>(
        find.widgetWithText(KvPillButton, 'Merge and move duplicate'),
      );
      expect(button.onPressed, isNull);
    });
  });
}
