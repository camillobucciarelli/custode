import 'dart:typed_data';

import '../models/vault_passkey.dart';
import '../models/vault_snapshot.dart';

/// The vault operations passkey adoption needs. Implemented by the data layer
/// under the shared path mutex and safe writer; no backup here, that is the
/// caller's.
abstract interface class PasskeyAdoptionVaultPort {
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
  });

  /// New entry and its passkey in one save. Returns the new entry's id.
  Future<String> createEntryWithPasskey({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
    required String title,
    required String username,
    required String url,
    required VaultPasskey passkey,
  });

  Future<void> createPasskey({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required VaultPasskey passkey,
    bool replaceExisting = false,
  });

  /// `credentialEntryId`: entry holding `(relyingPartyId, credentialId)`, or
  /// null. `accountEntryIds`: entries holding a passkey for
  /// `(relyingPartyId, userHandle)`. Read-only.
  Future<({String? credentialEntryId, List<String> accountEntryIds})>
  findPasskeyHolders({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String relyingPartyId,
    required Uint8List credentialId,
    Uint8List? userHandle,
  });
}
