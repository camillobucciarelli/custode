import 'dart:typed_data';

import '../../data/services/passkey_generator.dart';
import '../../data/services/vault_kdbx_service.dart';
import '../../domain/errors/passkey_errors.dart';
import '../../domain/models/vault_passkey.dart';
import '../../domain/repositories/database_file_repository.dart';
import 'dated_backup_path.dart';
import 'session_secret_holder.dart';

/// spec 023 — outcome of a passkey operation. Never carries a secret.
enum PasskeyOutcome { done, vaultLocked, notFound, alreadyExists, failed }

class PasskeyDeleteResult {
  const PasskeyDeleteResult(this.outcome, {this.backupPath});

  final PasskeyOutcome outcome;

  /// Where the pre-delete copy went. Set whenever the backup was written,
  /// including when the delete after it failed — a stray backup is
  /// recoverable, a deleted private key is not.
  final String? backupPath;

  @override
  String toString() => 'PasskeyDeleteResult($outcome, backupPath: $backupPath)';
}

/// spec 023 US3 — a passkey that was created and written, or the reason it
/// was not. Never carries the key: the caller gets the public half and the
/// attestation, which is what a relying party needs.
class PasskeyCreateResult {
  const PasskeyCreateResult(this.outcome, {this.created, this.backupPath});

  final PasskeyOutcome outcome;

  /// Set only on [PasskeyOutcome.done]. The private key inside it has already
  /// been written to the vault; nothing else may persist it.
  final GeneratedPasskey? created;

  final String? backupPath;

  @override
  String toString() => 'PasskeyCreateResult($outcome, backupPath: $backupPath)';
}

/// spec 023 T204 — sequencing for deleting a passkey (FR-010).
///
/// Mirrors `EntryHistoryCoordinator.clearHistory`: refuse on a locked
/// session, write the dated copy first, then the destructive call. The
/// confirmation is the caller's, so this stays callable from a test with no
/// UI (Constitution VIII).
class PasskeyCoordinator {
  PasskeyCoordinator({
    required this.vaultKdbxService,
    required this.sessionSecretHolder,
    required this.databaseFileRepository,
    PasskeyGenerator? generator,
  }) : generator = generator ?? PasskeyGenerator();

  final VaultKdbxService vaultKdbxService;
  final SessionSecretHolder sessionSecretHolder;
  final DatabaseFileRepository databaseFileRepository;
  final PasskeyGenerator generator;

  /// spec 023 US3 — create a passkey for [relyingPartyId] and write it to
  /// [entryId] (FR-018).
  ///
  /// All-or-nothing, and in this order for a reason (FR-020): the backup is
  /// written first, then the vault write completes, and only then does the
  /// caller have a [GeneratedPasskey] to answer the relying party with. A
  /// caller that reported success before this future resolved would leave the
  /// site believing in a credential the vault may not hold.
  ///
  /// [replaceExisting] is false by default, so a clash comes back as
  /// [PasskeyOutcome.alreadyExists] for the caller to warn about rather than
  /// overwriting a key silently (FR-019).
  Future<PasskeyCreateResult> createPasskey({
    required String databasePath,
    String? keyFilePath,
    required String entryId,
    required String relyingPartyId,
    required String username,
    Uint8List? userHandle,
    bool replaceExisting = false,
  }) => _create(
    databasePath: databasePath,
    relyingPartyId: relyingPartyId,
    username: username,
    userHandle: userHandle,
    write: (passkey) => vaultKdbxService.createPasskey(
      databasePath: databasePath,
      password: sessionSecretHolder.read(),
      keyFilePath: keyFilePath,
      entryId: entryId,
      passkey: passkey,
      replaceExisting: replaceExisting,
    ),
  );

  /// spec 023 slice 4 — the same sequence for a platform registration, where
  /// no one can choose the record: the service picks it (D12) and creates one
  /// when the vault has none for the site.
  Future<PasskeyCreateResult> createPasskeyForSite({
    required String databasePath,
    String? keyFilePath,
    required String relyingPartyId,
    required String username,
    Uint8List? userHandle,
    bool replaceExisting = false,
  }) => _create(
    databasePath: databasePath,
    relyingPartyId: relyingPartyId,
    username: username,
    userHandle: userHandle,
    write: (passkey) => vaultKdbxService.createPasskeyForSite(
      databasePath: databasePath,
      password: sessionSecretHolder.read(),
      keyFilePath: keyFilePath,
      passkey: passkey,
      replaceExisting: replaceExisting,
    ),
  );

  /// Whether the open vault holds a passkey for this site and account. False
  /// on a locked session: the caller reports the lock from its own check.
  Future<bool> hasPasskeyFor({
    required String databasePath,
    String? keyFilePath,
    required String relyingPartyId,
    required Uint8List? userHandle,
  }) async {
    if (!sessionSecretHolder.hasSecret) return false;
    return vaultKdbxService.hasPasskeyFor(
      databasePath: databasePath,
      password: sessionSecretHolder.read(),
      keyFilePath: keyFilePath,
      relyingPartyId: relyingPartyId,
      userHandle: userHandle,
    );
  }

  /// Whether the open vault holds one of [credentialIds] for the site. False
  /// on a locked session.
  Future<bool> holdsAnyPasskeyCredential({
    required String databasePath,
    String? keyFilePath,
    required String relyingPartyId,
    required List<Uint8List> credentialIds,
  }) async {
    if (!sessionSecretHolder.hasSecret) return false;
    return vaultKdbxService.holdsAnyPasskeyCredential(
      databasePath: databasePath,
      password: sessionSecretHolder.read(),
      keyFilePath: keyFilePath,
      relyingPartyId: relyingPartyId,
      credentialIds: credentialIds,
    );
  }

  Future<PasskeyCreateResult> _create({
    required String databasePath,
    required String relyingPartyId,
    required String username,
    required Uint8List? userHandle,
    required Future<Object?> Function(VaultPasskey passkey) write,
  }) async {
    if (!sessionSecretHolder.hasSecret) {
      return const PasskeyCreateResult(PasskeyOutcome.vaultLocked);
    }
    final backupPath = datedBackupPath(
      databasePath,
      suffix: 'pre-create-passkey',
    );
    try {
      await databaseFileRepository.copyFile(
        sourcePath: databasePath,
        targetPath: backupPath,
      );
    } catch (_) {
      return const PasskeyCreateResult(PasskeyOutcome.failed);
    }

    final created = generator.generate(
      relyingPartyId: relyingPartyId,
      username: username,
      userHandle: userHandle,
      createdAt: DateTime.now(),
    );
    try {
      await write(created.passkey);
      return PasskeyCreateResult(
        PasskeyOutcome.done,
        created: created,
        backupPath: backupPath,
      );
    } on PasskeyAlreadyExists {
      return PasskeyCreateResult(
        PasskeyOutcome.alreadyExists,
        backupPath: backupPath,
      );
    } catch (_) {
      // The key exists only in this frame and is dropped with it: a failed
      // write must not leave a credential the site could be told about.
      return PasskeyCreateResult(PasskeyOutcome.failed, backupPath: backupPath);
    }
  }

  /// Named `deletePasskey`, not `delete`: spec 008 T102's architecture guard
  /// greps the presentation layer for a bare delete call on a receiver, to
  /// catch a `dart:io` mutation escaping the `DatabaseFileRepository` port.
  /// A one-word name here would read as exactly that — to the guard and to a
  /// reviewer.
  ///
  /// A backup that cannot be written stops the delete: a passkey has exactly
  /// one copy of its private key, and without the copy the destruction is
  /// unrecoverable — which is the whole point of Constitution VII here.
  Future<PasskeyDeleteResult> deletePasskey({
    required String databasePath,
    String? keyFilePath,
    required String entryId,
    required String relyingPartyId,
    required Uint8List credentialId,
  }) async {
    if (!sessionSecretHolder.hasSecret) {
      return const PasskeyDeleteResult(PasskeyOutcome.vaultLocked);
    }
    final backupPath = datedBackupPath(
      databasePath,
      suffix: 'pre-delete-passkey',
    );
    try {
      await databaseFileRepository.copyFile(
        sourcePath: databasePath,
        targetPath: backupPath,
      );
    } catch (_) {
      return const PasskeyDeleteResult(PasskeyOutcome.failed);
    }
    try {
      await vaultKdbxService.deletePasskey(
        databasePath: databasePath,
        password: sessionSecretHolder.read(),
        keyFilePath: keyFilePath,
        entryId: entryId,
        relyingPartyId: relyingPartyId,
        credentialId: credentialId,
      );
      return PasskeyDeleteResult(PasskeyOutcome.done, backupPath: backupPath);
    } on PasskeyNotFound {
      // The vault changed under the open record — synced, merged or edited
      // elsewhere. Nothing was written, but the backup stays: it is the only
      // copy of the file as the user last saw it.
      return PasskeyDeleteResult(
        PasskeyOutcome.notFound,
        backupPath: backupPath,
      );
    } catch (_) {
      return PasskeyDeleteResult(PasskeyOutcome.failed, backupPath: backupPath);
    }
  }
}
