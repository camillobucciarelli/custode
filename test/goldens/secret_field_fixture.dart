// spec 023 T104: the record the secret-field goldens photograph, and the
// WCAG contrast helper they assert with.
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';

/// Fixed fake secret (Constitution IV): masked in every golden, never shown.
const secretFieldValue = 'abandon ability able about above absent';

/// The standard fixture plus one record carrying a secret custom field
/// beside a plain one.
VaultSnapshot buildSecretFieldSnapshot() {
  final base = buildFixtureSnapshot();
  final wallet = VaultEntry(
    id: 'e-wallet',
    groupId: kRootGroupId,
    title: 'Wallet',
    username: 'camillo',
    password: 'Fixture-Pass-9d!z',
    url: 'https://wallet.example',
    notes: '',
    customFields: const [
      VaultCustomField(
        key: 'Seed phrase',
        value: secretFieldValue,
        isProtected: true,
      ),
      VaultCustomField(key: 'Network', value: 'mainnet'),
    ],
    createdAt: DateTime(2024, 1, 4),
    updatedAt: DateTime(2026, 3, 12, 9, 30),
    lastPasswordChangedAt: DateTime(2026, 1, 12),
  );
  final entries = [wallet, ...base.entries];
  return VaultSnapshot(
    rootGroupId: base.rootGroupId,
    currentGroupId: base.currentGroupId,
    groups: base.groups,
    entries: entries,
    allEntries: entries,
  );
}

/// WCAG 2.x contrast ratio, alpha-blending the foreground first.
double contrastRatio(Color foreground, Color background) {
  final opaque = Color.alphaBlend(foreground, background);
  final a = opaque.computeLuminance();
  final b = background.computeLuminance();
  final high = a > b ? a : b;
  final low = a > b ? b : a;
  return (high + 0.05) / (low + 0.05);
}
