import 'vault_encryption.dart';
import 'vault_entry.dart';
import 'vault_group.dart';

class VaultSnapshot {
  const VaultSnapshot({
    required this.rootGroupId,
    required this.currentGroupId,
    required this.groups,
    required this.entries,
    required this.allEntries,
    this.encryption,
  });

  final String rootGroupId;
  final String currentGroupId;
  final List<VaultGroup> groups;
  final List<VaultEntry> entries;
  final List<VaultEntry> allEntries;

  /// Cipher, KDF and KDF cost of the open file's header.
  final VaultEncryption? encryption;
}
