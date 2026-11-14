import 'package:flutter/services.dart';

import '../../data/services/desktop_browser_autofill_cache.dart';
import '../../data/services/vault_kdbx_service.dart';
import '../../domain/models/pending_passkey_registration.dart';
import '../../domain/models/vault_entry.dart';
import '../../domain/models/vault_passkey.dart';
import '../../domain/repositories/autofill_ports.dart';
import '../../domain/repositories/database_file_repository.dart';
import '../../domain/repositories/database_registry_repository.dart';
import 'dated_backup_path.dart';
import 'session_secret_holder.dart';

// Passkeys-all-platforms spec, T013 (FR-8, FR-9). Every type below is plain
// and immutable and carries identifiers only: no PEM, no key bytes (SR-1).

enum PendingPasskeyAdoptionStatus {
  /// The records were processed; see the lists for the per-record outcome.
  done,

  /// No session secret: nothing was read or written.
  vaultLocked,

  /// The native queue could not be read ([PendingPasskeyAdoptionResult
  /// .readErrorCode] holds the platform error code).
  readFailed,
}

/// Where in the sequence a record failed. The record always stays in the queue
/// (FR-9); only [resolve] means the vault write itself succeeded.
enum PendingPasskeyFailureStage { backup, write, verify, resolve }

enum PasskeyClashDecision { replace, keepBoth }

class PendingPasskeyRef {
  const PendingPasskeyRef({
    required this.recordId,
    required this.rpId,
    required this.username,
  });

  final String recordId;
  final String rpId;
  final String username;

  @override
  String toString() => 'PendingPasskeyRef($recordId, $rpId)';
}

class AdoptedPasskey extends PendingPasskeyRef {
  const AdoptedPasskey({
    required super.recordId,
    required super.rpId,
    required super.username,
    required this.entryId,
    required this.createdNewEntry,
    required this.backupPath,
  });

  final String entryId;
  final bool createdNewEntry;
  final String backupPath;
}

/// A record whose account already has a passkey in the vault: nothing was
/// written. The UI asks the user, then calls
/// [PendingPasskeyAdoptionCoordinator.applyClashDecision].
class PasskeyClashRequest extends PendingPasskeyRef {
  const PasskeyClashRequest({
    required super.recordId,
    required super.rpId,
    required super.username,
    required this.candidateEntryIds,
  });

  final List<String> candidateEntryIds;
}

/// A record bound to a vault other than the open one; left untouched.
class PendingPasskeyOtherVault extends PendingPasskeyRef {
  const PendingPasskeyOtherVault({
    required super.recordId,
    required super.rpId,
    required super.username,
    required this.databaseId,
    this.vaultName,
  });

  final String databaseId;

  /// Display name of the known database this record is bound to; null when no
  /// registered database hashes to [databaseId].
  final String? vaultName;
}

class PendingPasskeyFailure extends PendingPasskeyRef {
  const PendingPasskeyFailure({
    required super.recordId,
    required super.rpId,
    required super.username,
    required this.stage,
    required this.errorType,
    this.backupPath,
  });

  final PendingPasskeyFailureStage stage;

  /// Exception type (and platform code), never its message: a message could
  /// quote key material.
  final String errorType;

  /// Set whenever the dated copy was written, including after a failed write.
  final String? backupPath;
}

class PendingPasskeyAdoptionResult {
  const PendingPasskeyAdoptionResult({
    this.status = PendingPasskeyAdoptionStatus.done,
    this.adopted = const [],
    this.alreadyHeld = const [],
    this.clashes = const [],
    this.otherVault = const [],
    this.unreadableCount = 0,
    this.failures = const [],
    this.readErrorCode,
  });

  final PendingPasskeyAdoptionStatus status;
  final List<AdoptedPasskey> adopted;

  /// Vault already held the credential; record resolved, nothing written.
  final List<PendingPasskeyRef> alreadyHeld;
  final List<PasskeyClashRequest> clashes;
  final List<PendingPasskeyOtherVault> otherVault;
  final int unreadableCount;
  final List<PendingPasskeyFailure> failures;
  final String? readErrorCode;

  @override
  String toString() =>
      'PendingPasskeyAdoptionResult($status, adopted: ${adopted.length}, '
      'alreadyHeld: ${alreadyHeld.length}, clashes: ${clashes.length}, '
      'otherVault: ${otherVault.length}, unreadable: $unreadableCount, '
      'failures: ${failures.length})';
}

/// Writes passkeys created by an autofill surface (see
/// [PendingPasskeyRegistrationPort]) into the open vault.
///
/// Sequence per record, as [PasskeyCoordinator]: dated backup, write, verify
/// by reopening, and only then delete the queue record. Records are re-read
/// from the port whenever a user decision arrives, so no key material is held
/// between calls (SR-8).
class PendingPasskeyAdoptionCoordinator {
  PendingPasskeyAdoptionCoordinator({
    required this.vaultKdbxService,
    required this.sessionSecretHolder,
    required this.databaseFileRepository,
    required this.pendingPasskeyPort,
    this.databaseRegistry,
  });

  final VaultKdbxService vaultKdbxService;
  final SessionSecretHolder sessionSecretHolder;
  final DatabaseFileRepository databaseFileRepository;
  final PendingPasskeyRegistrationPort pendingPasskeyPort;

  /// Only used to name the vault an other-vault record belongs to.
  final DatabaseRegistryRepository? databaseRegistry;

  /// The id the autofill cache is published under for [databasePath]
  /// (`sha256:` of the trimmed path), which pending records are bound to.
  static String databaseIdFor(String databasePath) =>
      DesktopBrowserAutofillMetadataMapper.databaseIdForPath(databasePath);

  /// Tail of the queue every queue-mutating call runs behind. The vault mutex
  /// is taken per read/write, not across check-then-write, so two overlapping
  /// runs (init + resume) could both see "not held" and both write.
  // ponytail: one lock for every vault; per-path locks if adoption of several
  // vaults ever has to overlap.
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Records waiting in the queue (every vault) plus unreadable ones, for the
  /// pre-unlock banner. Needs no session. A queue that cannot be read counts
  /// as 0: a banner must not break the unlock screen, and [adoptPending]
  /// reports the read error itself.
  Future<int> waitingCount() async {
    try {
      // Metadata-only count: reading would decrypt every record before unlock.
      return await pendingPasskeyPort.countPendingPasskeyRegistrations();
    } on PlatformException {
      return 0;
    }
  }

  /// FR-8: adopts every record bound to the vault at [databasePath].
  /// Other-vault records are only reported. Clashes are reported, not written.
  Future<PendingPasskeyAdoptionResult> adoptPending({
    required String databasePath,
    String? keyFilePath,
  }) => _serial(() => _adoptPending(databasePath, keyFilePath));

  Future<PendingPasskeyAdoptionResult> _adoptPending(
    String databasePath,
    String? keyFilePath,
  ) async {
    if (!sessionSecretHolder.hasSecret) {
      return const PendingPasskeyAdoptionResult(
        status: PendingPasskeyAdoptionStatus.vaultLocked,
      );
    }
    final PendingPasskeyRegistrations pending;
    try {
      pending = await pendingPasskeyPort.readPendingPasskeyRegistrations();
    } on PlatformException catch (e) {
      return PendingPasskeyAdoptionResult(
        status: PendingPasskeyAdoptionStatus.readFailed,
        readErrorCode: e.code,
      );
    }
    final openId = databaseIdFor(databasePath);
    final out = _Builder()..unreadableCount = pending.unreadableCount;
    Map<String, String>? names;
    for (final record in pending.records) {
      if (record.databaseId != openId) {
        names ??= await _knownVaultNames();
        out.otherVault.add(
          PendingPasskeyOtherVault(
            recordId: record.recordId,
            rpId: record.rpId,
            username: record.username,
            databaseId: record.databaseId,
            vaultName: names[record.databaseId],
          ),
        );
        continue;
      }
      if (!sessionSecretHolder.hasSecret) {
        out.status = PendingPasskeyAdoptionStatus.vaultLocked;
        break;
      }
      await _process(record, databasePath, keyFilePath, out);
    }
    return out.build();
  }

  /// `databaseIdFor(path)` -> display name, for every registered database. A
  /// registry that cannot be read only costs the name, never the adoption.
  Future<Map<String, String>> _knownVaultNames() async {
    try {
      final records = await databaseRegistry?.list() ?? const [];
      return {
        for (final r in records) databaseIdFor(r.canonicalPath): r.displayName,
      };
    } on Object {
      return const {};
    }
  }

  /// FR-8 case (b): applies the user's choice for a clash reported by
  /// [adoptPending]. [replaceEntryId] is required for
  /// [PasskeyClashDecision.replace] and must still hold a passkey for the
  /// account.
  ///
  /// keepBoth writes a NEW entry: [VaultKdbxService.createPasskey] on an entry
  /// that already holds a passkey for the same `(rpId, userHandle)` throws
  /// `PasskeyAlreadyExists`, and the clash is by definition that case.
  Future<PendingPasskeyAdoptionResult> applyClashDecision({
    required String databasePath,
    String? keyFilePath,
    required String recordId,
    required PasskeyClashDecision decision,
    String? replaceEntryId,
  }) => _serial(() async {
    final (:record, :early) = await _readOne(recordId);
    if (record == null) return early!;
    return _single(record, (out) async {
      final r = record;
      final holders = await _holders(databasePath, keyFilePath, r);
      if (holders.credentialEntryId != null) {
        // Replayed after a crash between write and resolve.
        await _resolve(r, out, alreadyHeld: true);
        return;
      }
      if (decision == PasskeyClashDecision.replace) {
        if (replaceEntryId == null ||
            !holders.accountEntryIds.contains(replaceEntryId)) {
          // The vault changed since the question was asked: ask again.
          out.clashes.add(_clash(r, holders.accountEntryIds));
          return;
        }
        await _write(
          r,
          databasePath,
          keyFilePath,
          out,
          entryId: replaceEntryId,
          replace: true,
        );
      } else {
        await _write(r, databasePath, keyFilePath, out, newEntry: true);
      }
    });
  });

  /// Adopts [recordId] into the open vault although it is bound to another
  /// `databaseId`. Call only after the user confirmed.
  Future<PendingPasskeyAdoptionResult> moveToOpenVault({
    required String databasePath,
    String? keyFilePath,
    required String recordId,
  }) => _serial(() async {
    final (:record, :early) = await _readOne(recordId);
    if (record == null) return early!;
    return _single(
      record,
      (out) => _process(record, databasePath, keyFilePath, out),
    );
  });

  /// Deletes [recordId] from the queue without writing. Call only after the
  /// user confirmed (FR-9). Needs no session. `PlatformException` propagates.
  ///
  /// Unreadable records cannot be discarded: the port has no way to name
  /// them (open point for the native side).
  Future<bool> discard(String recordId) => _serial(
    () => pendingPasskeyPort.resolvePendingPasskeyRegistration(recordId),
  );

  // -- internals -------------------------------------------------------------

  /// The record, or a ready [early] result when it cannot be used.
  Future<
    ({PendingPasskeyRegistration? record, PendingPasskeyAdoptionResult? early})
  >
  _readOne(String recordId) async {
    if (!sessionSecretHolder.hasSecret) {
      return (
        record: null,
        early: const PendingPasskeyAdoptionResult(
          status: PendingPasskeyAdoptionStatus.vaultLocked,
        ),
      );
    }
    try {
      final pending = await pendingPasskeyPort
          .readPendingPasskeyRegistrations();
      for (final record in pending.records) {
        if (record.recordId == recordId) return (record: record, early: null);
      }
      // Gone (resolved elsewhere): nothing to do.
      return (
        record: null,
        early: PendingPasskeyAdoptionResult(
          unreadableCount: pending.unreadableCount,
        ),
      );
    } on PlatformException catch (e) {
      return (
        record: null,
        early: PendingPasskeyAdoptionResult(
          status: PendingPasskeyAdoptionStatus.readFailed,
          readErrorCode: e.code,
        ),
      );
    }
  }

  Future<PendingPasskeyAdoptionResult> _single(
    PendingPasskeyRegistration record,
    Future<void> Function(_Builder out) body,
  ) async {
    final out = _Builder();
    try {
      await body(out);
    } catch (e) {
      out.failures.add(_failure(record, PendingPasskeyFailureStage.verify, e));
    }
    return out.build();
  }

  /// FR-8 (a) to (c) for one record.
  Future<void> _process(
    PendingPasskeyRegistration record,
    String databasePath,
    String? keyFilePath,
    _Builder out,
  ) async {
    final ({String? credentialEntryId, List<String> accountEntryIds}) holders;
    try {
      holders = await _holders(databasePath, keyFilePath, record);
    } catch (e) {
      out.failures.add(_failure(record, PendingPasskeyFailureStage.verify, e));
      return;
    }
    if (holders.credentialEntryId != null) {
      await _resolve(record, out, alreadyHeld: true);
      return;
    }
    if (holders.accountEntryIds.isNotEmpty) {
      out.clashes.add(_clash(record, holders.accountEntryIds));
      return;
    }
    // Case (c): the one entry for this site and username, else a new one.
    final String? target;
    try {
      target = await _soleMatchingEntry(record, databasePath, keyFilePath);
    } catch (e) {
      out.failures.add(_failure(record, PendingPasskeyFailureStage.verify, e));
      return;
    }
    await _write(
      record,
      databasePath,
      keyFilePath,
      out,
      entryId: target,
      newEntry: target == null,
    );
  }

  Future<({String? credentialEntryId, List<String> accountEntryIds})> _holders(
    String databasePath,
    String? keyFilePath,
    PendingPasskeyRegistration record,
  ) => vaultKdbxService.findPasskeyHolders(
    databasePath: databasePath,
    password: sessionSecretHolder.read(),
    keyFilePath: keyFilePath,
    relyingPartyId: record.rpId,
    credentialId: record.credentialId,
    userHandle: record.userHandle,
  );

  Future<String?> _soleMatchingEntry(
    PendingPasskeyRegistration record,
    String databasePath,
    String? keyFilePath,
  ) async {
    final snapshot = await vaultKdbxService.loadVault(
      databasePath: databasePath,
      password: sessionSecretHolder.read(),
      keyFilePath: keyFilePath,
    );
    final rpId = record.rpId.toLowerCase();
    bool matches(VaultEntry entry) {
      final host = DesktopBrowserAutofillMetadataMapper.normalizedHost(
        entry.url,
      );
      return host != null &&
          (host == rpId || host.endsWith('.$rpId')) &&
          entry.username == record.username;
    }

    final found = snapshot.allEntries.where(matches).toList();
    return found.length == 1 ? found.single.id : null;
  }

  Future<void> _write(
    PendingPasskeyRegistration record,
    String databasePath,
    String? keyFilePath,
    _Builder out, {
    String? entryId,
    bool newEntry = false,
    bool replace = false,
  }) async {
    final backupPath = datedBackupPath(
      databasePath,
      suffix: 'pre-adopt-passkey',
    );
    try {
      await databaseFileRepository.copyFile(
        sourcePath: databasePath,
        targetPath: backupPath,
      );
    } catch (e) {
      out.failures.add(_failure(record, PendingPasskeyFailureStage.backup, e));
      return;
    }
    final password = sessionSecretHolder.read();
    final passkey = VaultPasskey(
      relyingPartyId: record.rpId,
      credentialId: record.credentialId,
      userHandle: record.userHandle,
      username: record.username,
      privateKeyPem: record.privateKeyPem,
      algorithm: record.algorithm,
      backupEligible: record.be,
      backupState: record.bs,
      createdAt: record.createdAt,
    );
    String writtenEntryId;
    try {
      if (newEntry) {
        final snapshot = await vaultKdbxService.loadVault(
          databasePath: databasePath,
          password: password,
          keyFilePath: keyFilePath,
        );
        writtenEntryId = await vaultKdbxService.createEntryWithPasskey(
          databasePath: databasePath,
          password: password,
          keyFilePath: keyFilePath,
          groupId: snapshot.rootGroupId,
          title: record.rpId,
          username: record.username,
          url: 'https://${record.rpId}',
          passkey: passkey,
        );
      } else {
        writtenEntryId = entryId!;
        await vaultKdbxService.createPasskey(
          databasePath: databasePath,
          password: password,
          keyFilePath: keyFilePath,
          entryId: writtenEntryId,
          passkey: passkey,
          replaceExisting: replace,
        );
      }
    } catch (e) {
      out.failures.add(
        _failure(
          record,
          PendingPasskeyFailureStage.write,
          e,
          backupPath: backupPath,
        ),
      );
      return;
    }
    try {
      final holders = await _holders(databasePath, keyFilePath, record);
      if (holders.credentialEntryId == null) {
        throw StateError('credential not found after write');
      }
    } catch (e) {
      out.failures.add(
        _failure(
          record,
          PendingPasskeyFailureStage.verify,
          e,
          backupPath: backupPath,
        ),
      );
      return;
    }
    out.adopted.add(
      AdoptedPasskey(
        recordId: record.recordId,
        rpId: record.rpId,
        username: record.username,
        entryId: writtenEntryId,
        createdNewEntry: newEntry,
        backupPath: backupPath,
      ),
    );
    await _resolve(record, out, backupPath: backupPath);
  }

  /// Deletes the queue record. A failure here is reported but safe: the vault
  /// holds the credential, so the next run lands in case (a).
  Future<void> _resolve(
    PendingPasskeyRegistration record,
    _Builder out, {
    bool alreadyHeld = false,
    String? backupPath,
  }) async {
    try {
      final removed = await pendingPasskeyPort
          .resolvePendingPasskeyRegistration(record.recordId);
      // Still queued: not clean, the next run must see it again.
      if (!removed) throw StateError('pending record not removed');
      if (alreadyHeld) {
        out.alreadyHeld.add(
          PendingPasskeyRef(
            recordId: record.recordId,
            rpId: record.rpId,
            username: record.username,
          ),
        );
      }
    } catch (e) {
      out.failures.add(
        _failure(
          record,
          PendingPasskeyFailureStage.resolve,
          e,
          backupPath: backupPath,
        ),
      );
    }
  }

  PasskeyClashRequest _clash(
    PendingPasskeyRegistration record,
    List<String> candidates,
  ) => PasskeyClashRequest(
    recordId: record.recordId,
    rpId: record.rpId,
    username: record.username,
    candidateEntryIds: List.unmodifiable(candidates),
  );

  PendingPasskeyFailure _failure(
    PendingPasskeyRegistration record,
    PendingPasskeyFailureStage stage,
    Object error, {
    String? backupPath,
  }) => PendingPasskeyFailure(
    recordId: record.recordId,
    rpId: record.rpId,
    username: record.username,
    stage: stage,
    errorType: error is PlatformException
        ? 'PlatformException(${error.code})'
        : error.runtimeType.toString(),
    backupPath: backupPath,
  );
}

class _Builder {
  PendingPasskeyAdoptionStatus status = PendingPasskeyAdoptionStatus.done;
  int unreadableCount = 0;
  final adopted = <AdoptedPasskey>[];
  final alreadyHeld = <PendingPasskeyRef>[];
  final clashes = <PasskeyClashRequest>[];
  final otherVault = <PendingPasskeyOtherVault>[];
  final failures = <PendingPasskeyFailure>[];

  PendingPasskeyAdoptionResult build() => PendingPasskeyAdoptionResult(
    status: status,
    adopted: List.unmodifiable(adopted),
    alreadyHeld: List.unmodifiable(alreadyHeld),
    clashes: List.unmodifiable(clashes),
    otherVault: List.unmodifiable(otherVault),
    unreadableCount: unreadableCount,
    failures: List.unmodifiable(failures),
  );
}
