// spec-008 T302/T302a/T303 — the data-owned implementation of the frozen merge
// port.
//
// **The whole point of this file is that it is the only thing that knows.** The
// domain port speaks in opaque ids, redacted decisions and safe codes; every
// fact those stand for — the canonical path, the master password, the key-file
// bytes, the two `KdbxFile`s, the object UUIDs, the field keys, the decrypted
// values and the attachment bytes — lives here, in `_MergeSession`, and is
// dropped when the session is cancelled, invalidated or completed.
//
// **T401 — FR-7's write-verify-converge cycle.** `commit` now writes: it
// revalidates under the shared `DatabasePathMutex`, replaces the local file
// through `SafeVaultFileWriter` (T108/T109's collision-safe backup + atomic
// replace, reused as-is), uploads through `GoogleDriveApiService` and treats
// the upload's own follow-up `getFileMetadata` fetch as the mandatory step-5
// read-back — a real second round trip the server answers strictly after the
// write completes, not a cached echo of what we sent. On divergence it
// re-anchors to the observed remote content, short-circuits on canonical
// semantic-manifest equality, and otherwise re-merges with the T401b sticky
// decision ledger, up to a budget of 3 rounds per `commit` call.
//
// **T403/T404 — the atomic commit.** Every round of the cycle composes, in
// this order and nowhere else: candidate semantic revalidation, verified
// collision-safe backup, same-directory temp + atomic replace, the
// pre-dispatch `PendingMergeUpload` record, the upload, the step-5 read-back
// and only then the mapping finalization. A backup failure aborts before any
// remote write; a mapping is never finalized on an unverified response.
//
// **T407/T408 — restart recovery.** `recoverPending` reads the persisted
// record under the same mutex, guards on the local checksum BEFORE any remote
// call, then triages the remote checksum: applied → finalize; unchanged
// expected-old → re-put the committed local bytes and verify; anything else →
// hand off to a new conflict, retaining the local merge and its backup.
// No concurrency token is selected or sent: Drive declares no `conditionalWrite`
// capability, so FR-7's optional token never applies to this adapter.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:kdbx/kdbx.dart';

import '../../domain/entities/database_record.dart';
import '../../domain/models/database_sync_mapping.dart';
import '../../domain/models/remote_file.dart';
import '../../domain/models/merge_field_display.dart';
import '../../domain/models/sync_merge_models.dart';
import '../../domain/repositories/database_registry_repository.dart';
import '../../domain/repositories/database_security_repository.dart';
import '../../domain/repositories/database_sync_repository.dart';
import '../../domain/repositories/sync_merge_repository.dart';
import '../../domain/usecases/vault_credentials.dart';
import '../datasources/secure_data_source.dart';
import '../datasources/sync_metadata_data_source.dart';
import '../services/database_path_mutex.dart';
import '../services/google_drive_api_service.dart';
import '../services/kdbx_merge_adapter.dart';
import '../services/kdbx_semantic_manifest.dart';
import '../services/merge_decision_ledger.dart';
import '../services/safe_vault_file_writer.dart';

/// spec-008 **T302a** — opaque id minting.
///
/// **This is where T202's "not derivable into sensitive values" actually
/// lives.** The frozen contract says so in as many words, because the id
/// *type* cannot deliver it: `ms-` + 32 lowercase hex is exactly the shape of
/// `'ms-' + md5(anything)`, so the shape check accepts a token that decodes
/// straight back to the thing it is supposed to hide. The type is a typo guard.
/// The guarantee is a property of this function and of nothing else.
///
/// Three commitments, each verified in
/// `test/.../data/repositories/sync_merge_repository_impl_test.dart`:
///
///   1. the source is [Random.secure] — a CSPRNG — and no other `Random`
///      instance exists in this library;
///   2. every token carries [_tokenEntropyBytes] × 8 = 128 bits;
///   3. no input reaches the token. Not the canonical path, not the registry
///      id, not an object UUID, not a field key, not an attachment name, not a
///      checksum, not a credential. The function takes **no argument** other
///      than its prefix, which is the strongest form that statement can take:
///      there is nothing to derive from.
const _tokenEntropyBytes = 16;

/// The one CSPRNG. Not injectable on purpose: a seam here would let a test —
/// or a future caller — substitute a predictable generator, and the whole
/// obligation of T302a is that the production path cannot be anything but
/// [Random.secure].
final Random _secureRandom = Random.secure();

String _mintToken(String prefix) {
  final buffer = StringBuffer(prefix)..write('-');
  for (var i = 0; i < _tokenEntropyBytes; i++) {
    buffer.write(_secureRandom.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

MergeSessionId _mintSessionId() => MergeSessionId(_mintToken('ms'));

MergeDecisionId _mintDecisionId() => MergeDecisionId(_mintToken('md'));

/// FR-7 step 1/2/3's comparator: `contentChecksum` is what Drive reports and
/// what every other writer in this codebase already checksums local bytes with
/// (`DatabaseSyncOrchestrator`), so a local/remote pair is comparable without
/// a second hash family entering the picture.
String _checksumOf(Uint8List bytes) => md5.convert(bytes).toString();

class SyncMergeRepositoryImpl implements SyncMergeRepository {
  SyncMergeRepositoryImpl({
    required DatabaseRegistryRepository registryRepository,
    required DatabaseSecurityRepository securityRepository,
    required DatabaseSyncRepository syncRepository,
    required SecureDataSource secureDataSource,
    required this._mutex,
    required GoogleDriveApiService driveApiService,
    required SyncMetadataDataSource syncMetadataDataSource,
    this._adapter = const KdbxMergeAdapter(),
    SafeVaultFileWriter? safeWriter,
  }) : _registry = registryRepository,
       _security = securityRepository,
       _sync = syncRepository,
       _secure = secureDataSource,
       _drive = driveApiService,
       _syncMetadata = syncMetadataDataSource,
       _safeWriter = safeWriter ?? SafeVaultFileWriter();

  final DatabaseRegistryRepository _registry;
  final DatabaseSecurityRepository _security;
  final DatabaseSyncRepository _sync;
  final SecureDataSource _secure;
  final KdbxMergeAdapter _adapter;

  /// T401: the whole write-verify-converge cycle runs under this — the shared
  /// per-database writer lock every other database writer in this codebase
  /// routes through (see `database_writer_inventory_test.dart`).
  final DatabasePathMutex _mutex;

  /// T401 step 3/11/13: metadata recheck, upload and the read-back the upload
  /// itself performs. No raw upload is exposed on `DatabaseSyncRepository`
  /// (it only carries `downloadRemoteFile`/`getMapping`), so this is injected
  /// directly rather than routed through that port.
  final GoogleDriveApiService _drive;

  /// T401 step 14: the mapping is updated ONLY once the read-back proves the
  /// remote holds the merged state.
  final SyncMetadataDataSource _syncMetadata;

  /// T401 steps 5-9, reused as-is: collision-safe backup + atomic replace.
  /// Lock-free by design — called only inside the `_mutex` acquisition below.
  final SafeVaultFileWriter _safeWriter;

  /// FR-7: at most 3 automatic re-merge rounds per `commit` call before the
  /// session settles on [MergeFailureCode.unresolvedConflict].
  static const _mergeRetryBudget = 3;

  /// FR-7 N2, and the frozen doc comment on [MergeNeedsReview.reviewReentryCount]:
  /// at most 3 returns to review over a session's lifetime (across as many
  /// `commit` calls as it takes). The 4th attempt that would otherwise produce
  /// another [MergeNeedsReview] ends the session as
  /// [MergeFailureCode.unresolvedConflict] instead.
  static const _reviewReentryCap = 3;

  /// The private session store. Keyed by the minted token, so a caller can only
  /// reach a session by presenting an id this repository handed out.
  final Map<String, _MergeSession> _sessions = <String, _MergeSession>{};

  @override
  Future<MergeReviewSummary> startReview(MergeDatabaseId databaseId) async {
    final record = await _registry.getById(databaseId.value);
    if (record == null) {
      // D16: the id names nothing in the registry, so the state that made a
      // review possible is gone. Distinct from `sessionInvalidated`, which
      // means "the session you are holding is no longer valid".
      throw const SyncMergeFailure(MergeFailureCode.mergePreconditionFailed);
    }

    final credentials = await _resolveCredentials(record);
    final localBytes = await _readLocalBytes(record);
    final remoteBytes = await _downloadRemoteBytes(record);

    // FR-2: everything below happens BEFORE a session id exists, so a refusal
    // cannot leave a session, a backup, a local write or an upload behind.
    final localFile = await _open(localBytes, credentials);
    final remoteFile = await _open(remoteBytes, credentials);
    final pair = _adapter.validatePair(local: localFile, remote: remoteFile);
    final diff = _adapter.diffPresence(pair);

    final session = _MergeSession(
      sessionId: _mintSessionId(),
      databaseId: databaseId,
      canonicalPath: record.canonicalPath,
      credentials: credentials,
      pair: pair,
      diff: diff,
      localBytes: localBytes,
      remoteBytes: remoteBytes,
      localChecksum: _checksumOf(localBytes),
      remoteChecksum: _checksumOf(remoteBytes),
    );
    // The ledger is empty at this point, so every conflict below replays as
    // `MergeLedgerNeverShown` and takes the computed-default branch — the
    // exact behaviour this method always had, before T401 gave it a second
    // caller (the re-merge rounds in `commit`, where the ledger is not empty).
    _buildDecisions(session);
    _sessions[session.sessionId.token] = session;
    return session.summary();
  }

  @override
  Future<MergeReviewSummary> updateDecision({
    required MergeSessionId sessionId,
    required MergeDecisionId decisionId,
    required MergeChoice choice,
  }) async {
    final session = _requireSession(sessionId);
    final entry = session.decisions[decisionId.token];
    if (entry == null) {
      throw const SyncMergeFailure(MergeFailureCode.sessionInvalidated);
    }
    // `withChoice` re-runs every FR-4/FR-5/FR-6 invariant, so a missing side or
    // a delete without evidence throws before it can reach the candidate.
    entry.redacted = entry.redacted.withChoice(choice);
    return session.summary();
  }

  @override
  Future<MergeCommitOutcome> commit(MergeSessionId sessionId) async {
    // T111 passed on all 5 platforms as of 2026-08-25 (tasks.md); there is no
    // feature-flag mechanism anywhere in this codebase and none is added
    // here — the platform gate this comment used to describe is gone.
    final session = _requireSession(sessionId);
    return _mutex.withDatabaseLock([
      session.canonicalPath,
    ], () => _commitLocked(session));
  }

  /// The FR-7 cycle, steps 1-4/11/13-14 (T401's scope). Steps 5-9 are
  /// [SafeVaultFileWriter.write], reused unmodified. Step 10 (persist a
  /// pendingUpload record before dispatch) is not built: T404 owns that type
  /// and its persistence, so a process crash between this method's local
  /// atomic replace and its mapping-finalize update is NOT recoverable today
  /// — `recoverPending` still always answers `.none`. Do not read a
  /// successful return from this method as proof that FR-10 restart recovery
  /// works; it does not yet.
  Future<MergeCommitOutcome> _commitLocked(_MergeSession session) async {
    // Steps 1/2: the session is still valid ([_requireSession] above) and the
    // local side is exactly what the review was computed from. Checked once,
    // not per round: the mutex above excludes every other routed local writer
    // for the rest of this method, so nothing else can touch this path while
    // it runs.
    final Uint8List currentLocalBytes;
    try {
      currentLocalBytes = await File(session.canonicalPath).readAsBytes();
    } on Object {
      return const MergeRejected(
        MergeFailureCode.staleLocal,
        localCommitCompleted: false,
      );
    }
    if (_checksumOf(currentLocalBytes) != session.localChecksum) {
      // D16's reasoning again: the local side moved under a live review, and
      // the decisions on file were computed against bytes that no longer
      // exist. The session is left intact rather than disposed — nothing was
      // written, so the caller loses no review work by trying again later,
      // but a retry against the SAME session would fail the same way until a
      // fresh `startReview` re-diffs the current file.
      return const MergeRejected(
        MergeFailureCode.staleLocal,
        localCommitCompleted: false,
      );
    }

    final mapping = await _sync.getMapping(session.canonicalPath);
    if (mapping == null) {
      return const MergeRejected(
        MergeFailureCode.mergePreconditionFailed,
        localCommitCompleted: false,
      );
    }

    // FR-7 "explicit decisions are sticky across a re-merge": everything the
    // user is confirming in THIS review pass is recorded before the cycle can
    // touch anything, so a divergence discovered below replays it instead of
    // asking again or silently picking a side.
    _seedLedger(session);

    var remoteBytes = session.remoteBytes;
    var expectedRemoteChecksum = session.remoteChecksum;
    // Seeded from the session rather than `false`: an earlier round of THIS
    // call, or an earlier `commit` call entirely (the session survives a
    // `MergeNeedsReview` return), may already have written locally. Any
    // outcome this call produces must say so truthfully.
    var localWritten = session.everWrittenLocally;

    for (var round = 0; round < _mergeRetryBudget; round++) {
      // Step 3: remote metadata recheck. No concurrency token is read or
      // sent — Drive declares no `conditionalWrite` capability, so FR-7's
      // optional token never applies here; `contentChecksum` alone is the
      // comparator.
      final RemoteFile remoteMeta;
      try {
        remoteMeta = await _drive.getFileMetadata(mapping.remoteFileId);
      } on Object {
        return MergeRejected(
          MergeFailureCode.uploadOutcomeAmbiguous,
          localCommitCompleted: localWritten,
        );
      }
      final observedBeforeWrite = remoteMeta.contentChecksum;
      if (observedBeforeWrite != null &&
          observedBeforeWrite != expectedRemoteChecksum) {
        // Divergence found BEFORE anything is written this round: there is no
        // candidate yet to short-circuit against, so the only sound move is
        // to re-merge against what the remote actually holds now.
        try {
          remoteBytes = await _sync.downloadRemoteFile(
            mapping.remoteFileId,
            providerId: mapping.providerId,
          );
        } on Object {
          return MergeRejected(
            MergeFailureCode.uploadOutcomeAmbiguous,
            localCommitCompleted: localWritten,
          );
        }
        expectedRemoteChecksum = observedBeforeWrite;
      }

      // Step 4 (re-)diff: local is always re-opened from the EXACT bytes the
      // review was computed from, never from a previous round's own
      // candidate — `applyMerge` mutates its input in place, so re-diffing a
      // mutated tree would compare the merge against itself.
      final newConflictCount = await _rebuildDiffAndDecisions(
        session,
        remoteBytes,
      );
      if (newConflictCount > 0) {
        // The doc comment on `MergeNeedsReview.reviewReentryCount` (frozen
        // contract) is the source of truth: the 4th return-to-review ends the
        // session instead. `localWritten` here already reflects any write an
        // earlier round of THIS call made, via the seed above.
        if (session.reviewReentryCount >= _reviewReentryCap) {
          _disposeSession(session);
          return MergeRejected(
            MergeFailureCode.unresolvedConflict,
            localCommitCompleted: localWritten,
          );
        }
        session.reviewReentryCount++;
        return MergeNeedsReview(
          summary: session.summary(),
          newConflictCount: newConflictCount,
          reviewReentryCount: session.reviewReentryCount,
        );
      }

      final candidate = _adapter.applyMerge(
        pair: session.pair,
        diff: session.diff,
        resolution: session.resolution(),
      );
      // Same FR-2 output gate `buildCandidateBytes` runs: the merge is the one
      // operation that can create a UUID collision.
      _adapter.validatePair(local: candidate, remote: candidate);
      final candidateManifestDigest = kdbxManifestDigest(
        kdbxSemanticManifest(candidate),
      );
      final entryCount = candidate.body.rootGroup.getAllEntries().length;
      final candidateBytes = await _adapter.serializeCandidate(
        candidate: candidate,
        credentials: session.credentials,
      );

      // Steps 5-9, reused as-is: verified collision-safe backup first, then the
      // same-directory temp and the atomic replace.
      //
      // T403: mapped to a typed refusal like every other fallible step in this
      // method. An uncaught `FileSystemException` here would cross the frozen
      // port carrying a verbatim vault path, and a caller built on that port
      // would crash instead of being refused. The classification is by
      // exception type, which is as precise as the writer's surface allows: a
      // name-collision exhaustion is reported as `atomicReplaceFailed` even
      // when it happened while claiming the backup name, because the writer
      // does not say which phase raised it. In both cases nothing was written
      // and the target is untouched, which is what the codes' shared remedy
      // rests on.
      final SafeVaultFileWriteResult written;
      try {
        written = await _safeWriter.write(
          targetPath: session.canonicalPath,
          bytes: candidateBytes,
          backupExistingTarget: true,
          operation: 'merge commit',
        );
      } on SafeVaultBackupUnavailableException {
        // FR-9's hard stop: the target could not be backed up, so it was never
        // touched. The session is left intact — nothing was written, so a
        // retry after the user fixes the folder permission costs no review
        // work.
        return MergeRejected(
          MergeFailureCode.backupFailed,
          localCommitCompleted: localWritten,
        );
      } on Object {
        return MergeRejected(
          MergeFailureCode.atomicReplaceFailed,
          localCommitCompleted: localWritten,
        );
      }
      localWritten = true;
      session.everWrittenLocally = true;
      // The step-1/2 staleness precheck at the top of this method must judge
      // a LATER `commit` call against what is actually on disk now, not
      // against `startReview`'s original snapshot: this round may go on to
      // find a genuinely new conflict below and return `MergeNeedsReview`
      // without finalizing, and the write already happened.
      final localCandidateChecksum = _checksumOf(candidateBytes);
      session.localChecksum = localCandidateChecksum;

      // Step 10 — T404. Persisted BEFORE the request goes out, because the
      // whole point is to survive a process that dies while the request is in
      // flight. `mergedChecksum` and `localCommittedChecksum` are the same
      // value here by construction (the bytes written are the bytes sent);
      // they are separate fields because restart recovery asks two different
      // questions of them.
      final pending = PendingMergeUpload(
        databasePath: session.canonicalPath,
        remoteFileId: mapping.remoteFileId,
        mergedChecksum: localCandidateChecksum,
        localCommittedChecksum: localCandidateChecksum,
        expectedOldRemoteChecksum: expectedRemoteChecksum,
        backupPath: written.backupPath,
      );
      try {
        await _syncMetadata.upsertPendingUpload(pending);
      } on Object {
        // No record, no dispatch: uploading with no way to triage the outcome
        // is the exact hole this step exists to close, so the cycle stops here
        // instead. The merged local file and its backup are retained and the
        // mapping is never marked synced — the same disposition as a spent
        // retry budget, which is why it reports the same code.
        _disposeSession(session);
        return const MergeRejected(
          MergeFailureCode.unresolvedConflict,
          localCommitCompleted: true,
        );
      }

      // Step 11.
      final RemoteFile updated;
      try {
        updated = await _drive.updateFile(
          fileId: mapping.remoteFileId,
          bytes: candidateBytes,
        );
      } on Object {
        // T405/T406: Drive declares no `conditionalWrite`, so a CERTAIN
        // rejection — the one outcome that would prove nothing was
        // overwritten — cannot exist on this backend. Every failure after the
        // request went out is transport-ambiguous: the write may well have
        // landed. Recorded as such and left for recovery triage; never
        // retried blindly, never marked synced, never marked failed.
        await _markPendingAmbiguous(pending);
        _disposeSession(session);
        return const MergeRejected(
          MergeFailureCode.uploadOutcomeAmbiguous,
          localCommitCompleted: true,
        );
      }

      // Steps 12/13. T405: what `updateFile` returned is an APPARENT success
      // and nothing more — on a backend with no conditional write, the absence
      // of a rejection is not evidence that nothing was overwritten. Only the
      // read-back promotes it to confirmed, and the mapping is finalized
      // nowhere else. `updateFile` already issues its own `getFileMetadata`
      // strictly after the write completes (a real second round trip, not a
      // cached echo of what was sent), so that response IS the mandatory
      // read-back.
      final observedChecksum = updated.contentChecksum;
      if (observedChecksum == null) {
        // A non-executable read-back: nothing to verify against. Ambiguous,
        // never finalized, never retried blindly.
        await _markPendingAmbiguous(pending);
        _disposeSession(session);
        return const MergeRejected(
          MergeFailureCode.uploadOutcomeAmbiguous,
          localCommitCompleted: true,
        );
      }
      if (observedChecksum == localCandidateChecksum) {
        await _finalizeMapping(
          databaseId: session.databaseId.value,
          mapping: mapping,
          localChecksum: localCandidateChecksum,
          remoteChecksum: observedChecksum,
          modifiedTime: updated.modifiedTime,
        );
        await _clearPending(pending);
        _disposeSession(session);
        return MergeApplied(
          entryCount: entryCount,
          backupCreated: true,
          uploadState: MergeUploadState.uploaded,
        );
      }

      // Divergence AFTER the write: re-anchor to what the server actually
      // holds and try the canonical semantic-manifest short-circuit before
      // spending a re-merge round on it.
      final Uint8List redownloaded;
      try {
        redownloaded = await _sync.downloadRemoteFile(
          mapping.remoteFileId,
          providerId: mapping.providerId,
        );
      } on Object {
        // The write went out and the read-back showed divergence, so the
        // outcome is exactly as unknown as the two paths above — mark it the
        // same way. Without this the record keeps `outcomeAmbiguous: false`
        // while the returned code says ambiguous, and the two disagree.
        await _markPendingAmbiguous(pending);
        _disposeSession(session);
        return const MergeRejected(
          MergeFailureCode.uploadOutcomeAmbiguous,
          localCommitCompleted: true,
        );
      }
      final redownloadedFile = await _open(redownloaded, session.credentials);
      final redownloadedManifestDigest = kdbxManifestDigest(
        kdbxSemanticManifest(redownloadedFile),
      );
      if (redownloadedManifestDigest == candidateManifestDigest) {
        // Short-circuit: what the remote holds is semantically what we just
        // wrote (e.g. content-equivalent, byte-different). Finalize on the
        // OBSERVED content, not on our own recomputed checksum — the rule is
        // "the read-back proved the remote holds the merged state".
        await _finalizeMapping(
          databaseId: session.databaseId.value,
          mapping: mapping,
          localChecksum: localCandidateChecksum,
          remoteChecksum: _checksumOf(redownloaded),
          modifiedTime: updated.modifiedTime,
        );
        await _clearPending(pending);
        _disposeSession(session);
        return MergeApplied(
          entryCount: entryCount,
          backupCreated: true,
          uploadState: MergeUploadState.uploaded,
        );
      }

      // Re-merge and repeat from step 3, up to the budget.
      remoteBytes = redownloaded;
      expectedRemoteChecksum = observedChecksum;
    }

    // Budget exhausted: the merged local file and its backup are retained
    // (SafeVaultFileWriter never deletes what it just wrote), the mapping is
    // never marked synced.
    _disposeSession(session);
    return const MergeRejected(
      MergeFailureCode.unresolvedConflict,
      localCommitCompleted: true,
    );
  }

  /// Flips the pending record to ambiguous (T406) on the paths where the
  /// upload's outcome cannot be known.
  ///
  /// A failure to persist the flip is swallowed on purpose: every caller is
  /// already returning `uploadOutcomeAmbiguous`, and throwing here would
  /// replace that answer with an unclassified error. The record then survives
  /// in its pre-dispatch form, which recovery already treats as un-triaged
  /// rather than as applied or failed -- strictly less information, never
  /// wrong information.
  Future<void> _markPendingAmbiguous(PendingMergeUpload pending) async {
    try {
      await _syncMetadata.upsertPendingUpload(pending.asAmbiguous());
    } on Object {
      // Deliberately ignored -- see above.
    }
  }

  /// Drops the pending record (T404) once the read-back has proved the remote
  /// holds the dispatched bytes and [_finalizeMapping] has run — the only
  /// condition the data source's contract allows it under.
  ///
  /// A failure to persist the drop is swallowed for the same reason as in
  /// [_markPendingAmbiguous]: the merge genuinely succeeded, and throwing here
  /// would turn it into an unclassified error after the fact. The stale record
  /// is self-correcting rather than wrong — recovery re-hashes the local file,
  /// refetches, finds the remote already holds `mergedChecksum`, and converges
  /// on the outcome that in fact occurred.
  Future<void> _clearPending(PendingMergeUpload pending) async {
    try {
      await _syncMetadata.clearPendingUpload(pending.databasePath);
    } on Object {
      // Deliberately ignored -- see above.
    }
  }

  Future<void> _finalizeMapping({
    required String databaseId,
    required DatabaseSyncMapping mapping,
    required String localChecksum,
    required String remoteChecksum,
    DateTime? modifiedTime,
  }) {
    // spec 014 FR-6: mappings are keyed by database identifier; the session's
    // registry id is the authority.
    return _syncMetadata.upsertMapping(
      databaseId,
      mapping.copyWith(
        lastSyncedLocalChecksum: localChecksum,
        lastSyncedRemoteChecksum: remoteChecksum,
        lastSyncedRemoteModifiedTime: modifiedTime,
        lastSyncAt: DateTime.now(),
        clearError: true,
      ),
    );
  }

  void _disposeSession(_MergeSession session) {
    _sessions.remove(session.sessionId.token);
    session.dispose();
  }

  /// Re-opens both sides fresh — local from the exact bytes [startReview] saw,
  /// remote from [remoteBytes] — diffs them, and rebuilds [session.decisions]
  /// by replaying every conflict against [session.ledger]. Returns how many of
  /// the rebuilt decisions were never shown to the user (or are stale): a
  /// non-zero count means this round must stop and return to review rather
  /// than build a candidate from a guessed side.
  Future<int> _rebuildDiffAndDecisions(
    _MergeSession session,
    Uint8List remoteBytes,
  ) async {
    final localFile = await _open(session.localBytes, session.credentials);
    final remoteFile = await _open(remoteBytes, session.credentials);
    final pair = _adapter.validatePair(local: localFile, remote: remoteFile);
    final diff = _adapter.diffPresence(pair);
    session.pair = pair;
    session.diff = diff;
    session.decisions.clear();
    return _buildDecisions(session);
  }

  /// FR-7's ledger-seeding contract: every decision presented in the pass
  /// being confirmed right now, including ones left at their default.
  void _seedLedger(_MergeSession session) {
    for (final entry in session.decisions.values) {
      final choice = entry.redacted.choice;
      final field = entry.field;
      final blockEntryUuid = entry.credentialBlockEntryUuid;
      final passkeyRef = entry.passkeyBlockRef;
      if (field != null) {
        session.ledger.recordField(
          kdbxFieldRefOf(field),
          choice,
          decidedValue: _fieldSideValue(field, choice),
        );
      } else if (passkeyRef != null) {
        final blockFields = passkeyBlockFieldsOf(session.diff, passkeyRef);
        session.ledger.recordPasskeyBlock(
          passkeyRef,
          choice,
          decidedValue: choice == MergeChoice.local
              ? _blockImage(blockFields, local: true)
              : choice == MergeChoice.remote
              ? _blockImage(blockFields, local: false)
              : null,
        );
      } else if (blockEntryUuid != null) {
        final blockFields = credentialBlockFieldsOf(
          session.diff,
          blockEntryUuid,
        );
        session.ledger.recordCredentialBlock(
          blockEntryUuid,
          choice,
          decidedValue: choice == MergeChoice.local
              ? _blockImage(blockFields, local: true)
              : choice == MergeChoice.remote
              ? _blockImage(blockFields, local: false)
              : null,
        );
      } else {
        session.ledger.recordRecord(entry.record!.objectUuid, choice);
      }
    }
  }

  KdbxFieldPresent? _fieldSideValue(KdbxFieldDiff field, MergeChoice choice) {
    final side = switch (choice) {
      MergeChoice.local => field.local,
      MergeChoice.remote => field.remote,
      _ => null,
    };
    return side is KdbxFieldPresent ? side : null;
  }

  Map<String, KdbxFieldPresent> _blockImage(
    List<KdbxFieldDiff> blockFields, {
    required bool local,
  }) => {
    for (final f in blockFields)
      if ((local ? f.local : f.remote) is KdbxFieldPresent)
        f.canonicalKey: (local ? f.local : f.remote) as KdbxFieldPresent,
  };

  /// spec-008 T301 (apply half) / T309 — the merge candidate, in memory.
  ///
  /// Applies the session's decisions to the local side, serializes it, reopens
  /// the result with the **original credentials** and validates the canonical
  /// semantic manifest before returning the bytes. Nothing is written: the
  /// caller that eventually does write them is T403, under the path mutex and
  /// through `SafeVaultFileWriter`.
  ///
  /// **The session is consumed here, before anything is applied**, and a second
  /// call returns [MergeFailureCode.sessionInvalidated].
  ///
  /// That is a constraint, not a convention, and the difference is not
  /// academic. [KdbxMergeAdapter.applyMerge] mutates the local side in place,
  /// so a second application re-imports every remote-only record into a tree
  /// that already contains it. In debug the library's own assertion fires and
  /// a raw `AssertionError` crosses the port, breaking the typed-refusal
  /// contract. **In release assertions are disabled**, `addEntry` proceeds, and
  /// the candidate carries two objects with the same UUID — precisely the FR-2
  /// violation `validatePair` exists to refuse, introduced by the merge itself.
  /// A comment saying "call this once" prevents neither.
  ///
  /// The session is removed first rather than last so that a failure anywhere
  /// below cannot leave a half-applied session reachable: the local `KdbxFile`
  /// has already been mutated by then, so it is no longer the local side of
  /// anything and must not be diffed, displayed or re-applied.
  Future<Uint8List> buildCandidateBytes(MergeSessionId sessionId) async {
    final session = _requireSession(sessionId);
    _sessions.remove(sessionId.token);

    try {
      final candidate = _adapter.applyMerge(
        pair: session.pair,
        diff: session.diff,
        resolution: session.resolution(),
      );
      // The merge is the one operation that can *create* a UUID collision, by
      // importing an object the tree already holds. `validatePair` is FR-2's
      // gate on the inputs; running it against the candidate makes it a gate on
      // the output too, which is the check that is missing in release where the
      // library's assertion is compiled out. Cost is one tree walk over a file
      // already in memory — cheaper than the serialization on the next line.
      _adapter.validatePair(local: candidate, remote: candidate);
      return await _adapter.serializeCandidate(
        candidate: candidate,
        credentials: session.credentials,
      );
    } finally {
      session.dispose();
    }
  }

  @override
  Future<void> cancel(MergeSessionId sessionId) async {
    _sessions.remove(sessionId.token)?.dispose();
  }

  @override
  Future<void> invalidate(MergeDatabaseId databaseId) async {
    final doomed = [
      for (final entry in _sessions.entries)
        if (entry.value.databaseId == databaseId) entry.key,
    ];
    for (final token in doomed) {
      _sessions.remove(token)?.dispose();
    }
  }

  @override
  Future<MergeRecoveryOutcome> recoverPending(
    MergeDatabaseId databaseId,
  ) async {
    // T407/T408 — FR-10 restart recovery. Everything below runs under the same
    // per-database mutex every writer takes, so the local checksum it reads
    // is the one it acts on.
    final record = await _registry.getById(databaseId.value);
    if (record == null) {
      return const MergeRecoveryOutcome(MergeRecoveryDisposition.none);
    }
    return _mutex.withDatabaseLock([
      record.canonicalPath,
    ], () => _recoverLocked(record));
  }

  Future<MergeRecoveryOutcome> _recoverLocked(DatabaseRecord record) async {
    final pending = await _syncMetadata.getPendingUpload(record.canonicalPath);
    if (pending == null) {
      return const MergeRecoveryOutcome(MergeRecoveryDisposition.none);
    }

    // T407 — the local guard comes BEFORE any remote call or vault mutation.
    // A local file that no longer holds the committed bytes means the review
    // this record describes is stale: nothing about it may be uploaded,
    // retried or finalized. The record and the dated backup are retained as
    // evidence; a fresh conflict must be opened from the current state.
    final Uint8List localBytes;
    try {
      localBytes = await File(record.canonicalPath).readAsBytes();
    } on Object {
      return const MergeRecoveryOutcome(
        MergeRecoveryDisposition.staleRecoveryLocal,
      );
    }
    if (_checksumOf(localBytes) != pending.localCommittedChecksum) {
      return const MergeRecoveryOutcome(
        MergeRecoveryDisposition.staleRecoveryLocal,
      );
    }

    // T408 — matching local: refetch remote metadata and triage on checksum.
    // Drive is a bare `get`/`put` adapter: no `conditionalWrite` token to
    // re-send and no `versionHistory` revision to fetch, so the step-3
    // re-read plus the step-5 verification carry the whole safety here.
    final mapping = await _sync.getMapping(record.canonicalPath);
    if (mapping == null || mapping.remoteFileId != pending.remoteFileId) {
      // The mapping moved under the record; nothing can be verified against
      // it. Keep the evidence and stay ambiguous rather than guess.
      await _markPendingAmbiguous(pending);
      return const MergeRecoveryOutcome(
        MergeRecoveryDisposition.stillAmbiguous,
      );
    }
    final RemoteFile remoteMeta;
    try {
      remoteMeta = await _drive.getFileMetadata(pending.remoteFileId);
    } on Object {
      await _markPendingAmbiguous(pending);
      return const MergeRecoveryOutcome(
        MergeRecoveryDisposition.stillAmbiguous,
      );
    }
    final observed = remoteMeta.contentChecksum;
    if (observed == null) {
      await _markPendingAmbiguous(pending);
      return const MergeRecoveryOutcome(
        MergeRecoveryDisposition.stillAmbiguous,
      );
    }

    // Step 5: the upload applied after all — finalize what the remote holds.
    if (observed == pending.mergedChecksum) {
      await _finalizeMapping(
        databaseId: record.databaseId,
        mapping: mapping,
        localChecksum: pending.localCommittedChecksum,
        remoteChecksum: observed,
        modifiedTime: remoteMeta.modifiedTime,
      );
      await _clearPending(pending);
      return const MergeRecoveryOutcome(
        MergeRecoveryDisposition.finalizedApplied,
      );
    }

    // Step 6: the remote still holds the expected old content, so the write
    // never applied. Re-enter FR-7 from step 3 with the committed local bytes
    // (the candidate the review produced is exactly what is on disk) and
    // verify with the same step-5 read-back `commit` uses.
    if (observed == pending.expectedOldRemoteChecksum) {
      final RemoteFile updated;
      try {
        updated = await _drive.updateFile(
          fileId: pending.remoteFileId,
          bytes: localBytes,
        );
      } on Object {
        await _markPendingAmbiguous(pending);
        return const MergeRecoveryOutcome(
          MergeRecoveryDisposition.stillAmbiguous,
        );
      }
      final afterWrite = updated.contentChecksum;
      if (afterWrite == null) {
        await _markPendingAmbiguous(pending);
        return const MergeRecoveryOutcome(
          MergeRecoveryDisposition.stillAmbiguous,
        );
      }
      if (afterWrite == pending.mergedChecksum) {
        await _finalizeMapping(
          databaseId: record.databaseId,
          mapping: mapping,
          localChecksum: pending.localCommittedChecksum,
          remoteChecksum: afterWrite,
          modifiedTime: updated.modifiedTime,
        );
        await _clearPending(pending);
        return const MergeRecoveryOutcome(
          MergeRecoveryDisposition.retriedAndFinalized,
        );
      }
      // The retry raced another writer: a third state, handled below.
    }

    // Step 7: the remote changed independently. Hand off to a new conflict —
    // the local merged file and its dated backup stay exactly as they are,
    // and the record clears only because the handoff is the resolution.
    await _clearPending(pending);
    return const MergeRecoveryOutcome(
      MergeRecoveryDisposition.needsNewConflict,
    );
  }

  @override
  Future<MergeFieldDisplay> loadFieldDisplay({
    required MergeSessionId sessionId,
    required MergeDecisionId decisionId,
  }) async {
    final session = _requireSession(sessionId);
    final entry = session.decisions[decisionId.token];
    if (entry == null) {
      throw const SyncMergeFailure(MergeFailureCode.sessionInvalidated);
    }
    return entry.display(session);
  }

  // =========================================================================
  // Credentials and bytes. Everything below is data-private by construction.
  // =========================================================================

  Future<Credentials> _resolveCredentials(DatabaseRecord record) async {
    final password = await _secure.getMasterPassword(record.databaseId);

    final profile = await _security.getProfile(record.databaseId);
    // spec 014 FR-8 (T014c): the per-database security profile is the ONLY
    // key-file source; the process-wide cached path is gone. A database
    // whose profile names no key file merges with password-only
    // credentials, exactly as it unlocks.
    final keyFilePath = profile?.keyFilePath;

    Uint8List? keyFileBytes;
    if (keyFilePath != null && keyFilePath.trim().isNotEmpty) {
      final keyFile = File(keyFilePath);
      if (!await keyFile.exists()) {
        throw const SyncMergeFailure(MergeFailureCode.credentialsRevoked);
      }
      keyFileBytes = await keyFile.readAsBytes();
    }

    // spec-011 FR-2, as at unlock: a missing or empty password is a
    // credential only for a key-file-only vault. Anything else whose password
    // is not stored is revoked; a key-only guess on a password + key file
    // vault fails to open and is reported as revoked by [_open].
    if ((password == null || password.isEmpty) && keyFileBytes == null) {
      throw const SyncMergeFailure(MergeFailureCode.credentialsRevoked);
    }
    return composeVaultCredentials(
      password: password ?? '',
      keyFileBytes: keyFileBytes,
    );
  }

  Future<Uint8List> _readLocalBytes(DatabaseRecord record) async {
    final file = File(record.canonicalPath);
    if (!await file.exists()) {
      // Deliberately NOT `mergePreconditionFailed` (D16): `staleLocal` is the
      // least-wrong code that exists here, because its user-facing remedy —
      // "the local side is not what the registry recorded, resynchronize
      // instead of writing" — is correct for an absent file too.
      throw const SyncMergeFailure(MergeFailureCode.staleLocal);
    }
    return file.readAsBytes();
  }

  Future<Uint8List> _downloadRemoteBytes(DatabaseRecord record) async {
    final mapping = await _sync.getMapping(record.canonicalPath);
    if (mapping == null) {
      // D16: no remote to merge against. A merge review is only reachable from
      // a linked database, so reaching here means the mapping vanished under
      // the caller — a precondition, not a stale session.
      throw const SyncMergeFailure(MergeFailureCode.mergePreconditionFailed);
    }
    try {
      return await _sync.downloadRemoteFile(
        mapping.remoteFileId,
        providerId: mapping.providerId,
      );
    } on SyncMergeFailure {
      rethrow;
    } on Object {
      // The raw transport error never crosses the port: it can carry a file
      // id, a URL and an account label.
      throw const SyncMergeFailure(MergeFailureCode.uploadOutcomeAmbiguous);
    }
  }

  Future<KdbxFile> _open(Uint8List bytes, Credentials credentials) async {
    try {
      return await _adapter.openSide(bytes: bytes, credentials: credentials);
    } on KdbxInvalidKeyException {
      // The adapter deliberately lets this through unmapped: whether a
      // credential still opens the file is the repository's concern, not a
      // property of the KDBX construct.
      throw const SyncMergeFailure(MergeFailureCode.credentialsRevoked);
    }
  }

  _MergeSession _requireSession(MergeSessionId sessionId) {
    final session = _sessions[sessionId.token];
    // The disposed check is redundant with the removal at every call site, and
    // deliberately kept: it makes "disposed" the authority rather than "still
    // in the map", so a future edit that forgets one removal cannot serve a
    // session whose KdbxFile has already been consumed.
    if (session == null || session.isDisposed) {
      throw const SyncMergeFailure(MergeFailureCode.sessionInvalidated);
    }
    return session;
  }

  // =========================================================================
  // Redaction: private evidence -> domain decisions.
  // =========================================================================

  /// Builds [session.decisions] from [session.diff], replaying every
  /// conflict against [session.ledger] first (T401). At `startReview` time the
  /// ledger is empty, so every replay is [MergeLedgerNeverShown] and every
  /// decision takes the computed-default branch — the exact behaviour this
  /// method always had. `commit`'s re-merge rounds are the second caller,
  /// where the ledger is not empty: a replayed decision keeps the recorded
  /// choice (`isDefault: false`, sticky per FR-7) and is not counted; a
  /// [MergeLedgerNeverShown] or [MergeLedgerStale] one takes the computed
  /// default and IS counted, because the user has not seen it (or the
  /// candidates it was decided over no longer exist).
  ///
  /// Returns how many decisions were counted that way.
  int _buildDecisions(_MergeSession session) {
    var ordinal = 0;
    var newConflictCount = 0;

    // FR-3a: an engaged block's shared username/password/url conflicts are
    // ONE decision, never three (15n). `engagedCredentialBlockEntryUuids` is
    // the SAME function `applyMerge` filters its per-field loop with, so the
    // two halves can never disagree about which entries these are.
    final engagedBlocks = engagedCredentialBlockEntryUuids(session.diff);
    // spec 023 T209 / FR-008: a `KPEX_PASSKEY_*` group is ONE decision too,
    // and for a stronger reason than FR-3a's — a per-field answer there could
    // take the private key from one side and the credential id from the other.
    final engagedPasskeys = engagedPasskeyBlocks(session.diff);

    for (final field in session.diff.fieldDiffs) {
      if (field.classification != KdbxFieldClassification.fieldConflict) {
        continue;
      }
      if (isCredentialBlockKey(field.canonicalKey) &&
          field.fieldKind == KdbxMergeFieldKind.string &&
          engagedBlocks.contains(field.entryUuid)) {
        continue; // folded into the one block decision built below instead.
      }
      final passkeyRef = kdbxPasskeyBlockRefOf(field);
      if (passkeyRef != null && engagedPasskeys.contains(passkeyRef)) {
        continue; // folded into the one passkey decision built below instead.
      }
      final local = field.local as KdbxFieldPresent;
      final remote = field.remote as KdbxFieldPresent;
      final relation = session.timestampRelationFor(field.entryUuid);
      final replay = session.ledger.replayField(
        kdbxFieldRefOf(field),
        currentLocal: local,
        currentRemote: remote,
      );
      final MergeChoice choice;
      final bool isDefault;
      if (replay is MergeLedgerReplayed) {
        choice = replay.choice;
        isDefault = false;
      } else {
        choice = _defaultFieldChoice(relation, local, remote);
        isDefault = true;
        newConflictCount++;
      }
      final decisionId = _mintDecisionId();
      session.decisions[decisionId.token] = _DecisionRecord.forField(
        fieldDiff: field,
        redacted: RedactedMergeDecision(
          decisionId: decisionId,
          ordinal: ordinal++,
          kind: MergeDecisionKind.fieldConflict,
          category: _categoryOf(field),
          presence: MergePresence.presentBoth,
          choice: choice,
          isDefault: isDefault,
          timestampRelation: relation,
        ),
      );
    }

    for (final entryUuid in engagedBlocks.toList()..sort()) {
      final blockFields = credentialBlockFieldsOf(session.diff, entryUuid);
      final conflicting =
          blockFields
              .where(
                (f) =>
                    f.classification == KdbxFieldClassification.fieldConflict,
              )
              .toList()
            ..sort(
              (a, b) => _anchorPriority[a.canonicalKey]!.compareTo(
                _anchorPriority[b.canonicalKey]!,
              ),
            );
      // `engagedBlocks` guarantees at least one conflicting member exists.
      final anchor = conflicting.first;
      final relation = session.timestampRelationFor(entryUuid);
      final replay = session.ledger.replayCredentialBlock(
        entryUuid,
        currentLocal: _blockImage(blockFields, local: true),
        currentRemote: _blockImage(blockFields, local: false),
      );
      final MergeChoice choice;
      final bool isDefault;
      if (replay is MergeLedgerReplayed) {
        choice = replay.choice;
        isDefault = false;
      } else {
        choice = _defaultCredentialBlockChoice(relation, blockFields);
        isDefault = true;
        newConflictCount++;
      }
      final decisionId = _mintDecisionId();
      session.decisions[decisionId.token] = _DecisionRecord.forCredentialBlock(
        entryUuid: entryUuid,
        anchorField: anchor,
        redacted: RedactedMergeDecision(
          decisionId: decisionId,
          ordinal: ordinal++,
          kind: MergeDecisionKind.fieldConflict,
          category: _categoryOf(anchor),
          presence: MergePresence.presentBoth,
          choice: choice,
          isDefault: isDefault,
          timestampRelation: relation,
        ),
      );
    }

    // spec 023 T209 — one row per passkey group, ordered deterministically so
    // two devices reviewing the same pair see the same ordinals.
    final orderedPasskeys = engagedPasskeys.toList()
      ..sort((a, b) {
        final byEntry = a.entryUuid.compareTo(b.entryUuid);
        return byEntry != 0 ? byEntry : a.suffix.compareTo(b.suffix);
      });
    for (final ref in orderedPasskeys) {
      final blockFields = passkeyBlockFieldsOf(session.diff, ref);
      final relation = session.timestampRelationFor(ref.entryUuid);
      final replay = session.ledger.replayPasskeyBlock(
        ref,
        currentLocal: _blockImage(blockFields, local: true),
        currentRemote: _blockImage(blockFields, local: false),
      );
      final MergeChoice choice;
      final bool isDefault;
      if (replay is MergeLedgerReplayed) {
        choice = replay.choice;
        isDefault = false;
      } else {
        choice = _defaultPasskeyBlockChoice(relation, blockFields);
        isDefault = true;
        newConflictCount++;
      }
      final decisionId = _mintDecisionId();
      session.decisions[decisionId.token] = _DecisionRecord.forPasskeyBlock(
        ref: ref,
        relyingPartyId: passkeyBlockRelyingPartyId(blockFields),
        redacted: RedactedMergeDecision(
          decisionId: decisionId,
          ordinal: ordinal++,
          kind: MergeDecisionKind.fieldConflict,
          // The frozen contract has no passkey category, and inventing one
          // would change the port. A passkey is a custom-field namespace in
          // KDBX terms, which is what this says.
          category: MergeFieldCategory.customField,
          presence: MergePresence.presentBoth,
          choice: choice,
          isDefault: isDefault,
          timestampRelation: relation,
        ),
      );
    }

    for (final record in session.diff.deletionConflicts) {
      final replay = session.ledger.replayRecord(record.objectUuid);
      final MergeChoice choice;
      final bool isDefault;
      if (replay is MergeLedgerReplayed) {
        choice = replay.choice;
        isDefault = false;
      } else {
        // FR-5: the automatic default is always Keep, so an unattended
        // session can never delete. The constructor enforces it too.
        choice = MergeChoice.keep;
        isDefault = true;
        newConflictCount++;
      }
      final decisionId = _mintDecisionId();
      session.decisions[decisionId.token] = _DecisionRecord.forRecord(
        recordDiff: record,
        redacted: RedactedMergeDecision(
          decisionId: decisionId,
          ordinal: ordinal++,
          kind: MergeDecisionKind.recordDeletionConflict,
          category: record.objectKind == KdbxMergeObjectKind.group
              ? MergeFieldCategory.groupMetadata
              : MergeFieldCategory.other,
          presence: record.local.evidence == KdbxRecordEvidence.live
              ? MergePresence.localOnly
              : MergePresence.remoteOnly,
          choice: choice,
          isDefault: isDefault,
          timestampRelation: _relationOf(
            record.local.modifiedAtUtc,
            record.remote.modifiedAtUtc,
          ),
        ),
      );
    }
    return newConflictCount;
  }

  MergeFieldCategory _categoryOf(KdbxFieldDiff field) {
    if (field.fieldKind == KdbxMergeFieldKind.attachment) {
      return MergeFieldCategory.attachment;
    }
    switch (field.canonicalKey) {
      case 'title':
        return MergeFieldCategory.title;
      case 'username':
        return MergeFieldCategory.username;
      case 'password':
        return MergeFieldCategory.password;
      case 'url':
        return MergeFieldCategory.url;
      case 'notes':
        return MergeFieldCategory.notes;
      case 'otp':
      case 'totp':
      case 'otpauth':
        return MergeFieldCategory.otp;
      default:
        return MergeFieldCategory.customField;
    }
  }

  /// FR-3's default, computed from the data alone.
  ///
  /// Known modification time beats unknown; then newer wins; then the greater
  /// UTF-8 byte sequence wins. **Never "prefer local"** — that is
  /// perspective-dependent, so two devices holding the same pair would pick
  /// opposite winners, write over each other and oscillate across sessions,
  /// which no retry budget can stop.
  ///
  /// For an attachment the compared value is the SHA-256 digest rather than the
  /// bytes. It is still a function of the content alone and still identical on
  /// both devices, which is everything the tie-break requires; carrying the
  /// bytes into a comparator would put them one refactor away from a log line.
  ///
  /// T401a owns the full tie-break and promotes the T009 model properties to
  /// adapter-level tests. This is the same order, applied where the frozen
  /// contract forces a visible default to exist from the first review.
  MergeChoice _defaultFieldChoice(
    TimestampRelation relation,
    KdbxFieldPresent local,
    KdbxFieldPresent remote,
  ) {
    switch (relation) {
      case TimestampRelation.localNewer:
      case TimestampRelation.localKnownRemoteUnknown:
        return MergeChoice.local;
      case TimestampRelation.remoteNewer:
      case TimestampRelation.remoteKnownLocalUnknown:
        return MergeChoice.remote;
      case TimestampRelation.tie:
      case TimestampRelation.bothUnknown:
        // T401a: `compareFieldPresent`, not `compareUtf8Bytes` on the value
        // alone — a field-conflict pair can be byte-identical and differ only
        // in the protection flag `KdbxFieldPresent.sameAs` also compares, and
        // resolving THAT case on the value alone is a bare tie that always
        // fell to "local" — perspective-dependent, and forbidden by FR-3.
        return compareFieldPresent(local, remote) >= 0
            ? MergeChoice.local
            : MergeChoice.remote;
    }
  }

  /// spec-008 **T401c** — FR-3a's one comparison per credential block,
  /// mirroring [_defaultFieldChoice]'s shape exactly but over the block image
  /// (T401a's [compareCredentialBlockImage]) rather than one field.
  MergeChoice _defaultCredentialBlockChoice(
    TimestampRelation relation,
    List<KdbxFieldDiff> blockFields,
  ) {
    switch (relation) {
      case TimestampRelation.localNewer:
      case TimestampRelation.localKnownRemoteUnknown:
        return MergeChoice.local;
      case TimestampRelation.remoteNewer:
      case TimestampRelation.remoteKnownLocalUnknown:
        return MergeChoice.remote;
      case TimestampRelation.tie:
      case TimestampRelation.bothUnknown:
        final localImage = <String, KdbxFieldPresent>{
          for (final f in blockFields)
            if (f.local is KdbxFieldPresent)
              f.canonicalKey: f.local as KdbxFieldPresent,
        };
        final remoteImage = <String, KdbxFieldPresent>{
          for (final f in blockFields)
            if (f.remote is KdbxFieldPresent)
              f.canonicalKey: f.remote as KdbxFieldPresent,
        };
        return compareCredentialBlockImage(localImage, remoteImage) >= 0
            ? MergeChoice.local
            : MergeChoice.remote;
    }
  }

  /// spec 023 T209 — the same shape as [_defaultCredentialBlockChoice], over
  /// the whole passkey group rather than one field, so the credential moves as
  /// a unit whichever way the tie falls.
  MergeChoice _defaultPasskeyBlockChoice(
    TimestampRelation relation,
    List<KdbxFieldDiff> blockFields,
  ) {
    switch (relation) {
      case TimestampRelation.localNewer:
      case TimestampRelation.localKnownRemoteUnknown:
        return MergeChoice.local;
      case TimestampRelation.remoteNewer:
      case TimestampRelation.remoteKnownLocalUnknown:
        return MergeChoice.remote;
      case TimestampRelation.tie:
      case TimestampRelation.bothUnknown:
        return comparePasskeyBlockImage(
                  _blockImage(blockFields, local: true),
                  _blockImage(blockFields, local: false),
                ) >=
                0
            ? MergeChoice.local
            : MergeChoice.remote;
    }
  }

  /// FR-3a's fixed display priority for the anchor member of an engaged
  /// block — `password` > `username` > `url` — distinct from
  /// [compareCredentialBlockImage]'s ascending-UTF-8 join order, which exists
  /// only to fix the tie-break's byte sequence.
  static const _anchorPriority = {'password': 0, 'username': 1, 'url': 2};
}

TimestampRelation _relationOf(DateTime? local, DateTime? remote) {
  if (local == null && remote == null) return TimestampRelation.bothUnknown;
  if (remote == null) return TimestampRelation.localKnownRemoteUnknown;
  if (local == null) return TimestampRelation.remoteKnownLocalUnknown;
  if (local.isAfter(remote)) return TimestampRelation.localNewer;
  if (remote.isAfter(local)) return TimestampRelation.remoteNewer;
  return TimestampRelation.tie;
}

/// One review session's private state.
///
/// Not `Equatable`, not serializable, `toString` redacted. Everything the port
/// must never expose is reachable from here and from nowhere else.
final class _MergeSession {
  _MergeSession({
    required this.sessionId,
    required this.databaseId,
    required this.canonicalPath,
    required this.credentials,
    required this.pair,
    required this.diff,
    required this.localBytes,
    required this.remoteBytes,
    required this.localChecksum,
    required this.remoteChecksum,
  });

  final MergeSessionId sessionId;
  final MergeDatabaseId databaseId;
  final String canonicalPath;
  final Credentials credentials;

  /// T401: mutable across `commit`'s re-merge rounds — each round re-diffs
  /// fresh sides and replaces both, rather than reusing (and re-mutating) a
  /// pair from a previous round.
  KdbxMergePair pair;
  KdbxPresenceDiff diff;

  /// spec-008 T401: the exact bytes [startReview] read. Every commit-cycle
  /// round re-diffs the local side from THESE bytes, never from a previous
  /// round's own candidate output — `applyMerge` mutates its input in place,
  /// so re-diffing a mutated tree would compare the merge against itself.
  final Uint8List localBytes;
  final Uint8List remoteBytes;

  /// FR-7 step 1/2's "expected base": the checksum `commit`'s staleness
  /// precheck compares the on-disk file against. Starts as the checksum
  /// [startReview] actually diffed from, so `commit` can detect a local edit
  /// that landed after review opened ([MergeFailureCode.staleLocal]). NOT
  /// final: once a round of `commit` writes locally, this is advanced to the
  /// checksum of what was actually written, so a later `commit` call on the
  /// same session — including one made after this round itself returned
  /// [MergeNeedsReview] instead of finalizing — judges the precheck against
  /// reality rather than against a snapshot a real write has already
  /// superseded.
  String localChecksum;
  final String remoteChecksum;

  /// True once ANY round of ANY `commit` call on this session has written
  /// locally. Distinct from `commit`'s own per-call `localWritten` local,
  /// which starts from this flag: an outcome produced by a later call, or by
  /// a later round of the same call, must still report a prior write
  /// truthfully rather than answering only for bytes it wrote itself.
  bool everWrittenLocally = false;

  /// spec-008 T401b: sticky across every re-merge round of every `commit`
  /// call this session ever makes.
  final MergeDecisionLedger ledger = MergeDecisionLedger();

  /// How many times `commit` has returned this session to review. FR-7 N2
  /// caps this at 3; `_commitLocked` enforces the cap against this count
  /// before incrementing it a 4th time.
  int reviewReentryCount = 0;

  /// Keyed by the minted decision token.
  final Map<String, _DecisionRecord> decisions = <String, _DecisionRecord>{};

  bool _disposed = false;

  TimestampRelation timestampRelationFor(String entryUuid) {
    final record = diff.recordDiffs.firstWhere(
      (r) => r.objectUuid == entryUuid,
    );
    return _relationOf(record.local.modifiedAtUtc, record.remote.modifiedAtUtc);
  }

  KdbxEntry? entryOn(KdbxFile file, String uuid) {
    for (final entry in file.body.rootGroup.getAllEntries()) {
      if (entry.uuid.uuid == uuid) return entry;
    }
    return null;
  }

  KdbxObject? objectOn(KdbxFile file, String uuid) {
    for (final object in file.body.rootGroup.getAllGroupsAndEntries()) {
      if (object.uuid.uuid == uuid) return object;
    }
    return null;
  }

  MergeReviewSummary summary() {
    final ordered = decisions.values.toList()
      ..sort((a, b) => a.redacted.ordinal.compareTo(b.redacted.ordinal));
    return MergeReviewSummary(
      sessionId: sessionId,
      databaseId: databaseId,
      phase: MergeReviewPhase.reviewing,
      decisions: [for (final entry in ordered) entry.redacted],
      localOnlyRecordCount:
          diff.localOnlyEntryUuids.length + diff.localOnlyGroupUuids.length,
      remoteOnlyRecordCount:
          diff.remoteOnlyEntryUuids.length + diff.remoteOnlyGroupUuids.length,
      oneSidedFieldCount: diff.oneSidedFieldCount,
    );
  }

  /// The private evidence the resolved candidate is built from (T403 consumes
  /// it). Kept here so the translation from redacted decisions to KDBX
  /// operations happens exactly once, on this side of the port.
  KdbxMergeResolution resolution() {
    final fieldChoices = <KdbxFieldRef, MergeChoice>{};
    final recordChoices = <String, MergeChoice>{};
    final credentialBlockChoices = <String, MergeChoice>{};
    final passkeyBlockChoices = <KdbxPasskeyBlockRef, MergeChoice>{};
    for (final entry in decisions.values) {
      final field = entry.field;
      if (field != null) {
        fieldChoices[kdbxFieldRefOf(field)] = entry.redacted.choice;
        continue;
      }
      final passkeyRef = entry.passkeyBlockRef;
      if (passkeyRef != null) {
        passkeyBlockChoices[passkeyRef] = entry.redacted.choice;
        continue;
      }
      final blockEntryUuid = entry.credentialBlockEntryUuid;
      if (blockEntryUuid != null) {
        credentialBlockChoices[blockEntryUuid] = entry.redacted.choice;
        continue;
      }
      recordChoices[entry.record!.objectUuid] = entry.redacted.choice;
    }
    return KdbxMergeResolution(
      fieldChoices: fieldChoices,
      recordChoices: recordChoices,
      credentialBlockChoices: credentialBlockChoices,
      passkeyBlockChoices: passkeyBlockChoices,
    );
  }

  bool get isDisposed => _disposed;

  void dispose() {
    decisions.clear();
    _disposed = true;
  }

  @override
  String toString() => '_MergeSession(<redacted>)';
}

/// One decision: the redacted row that crosses the port, plus the private
/// evidence it stands for. The two are never merged into one object — that is
/// the whole boundary.
final class _DecisionRecord {
  _DecisionRecord.forField({
    required KdbxFieldDiff fieldDiff,
    required this.redacted,
  }) : field = fieldDiff,
       record = null,
       credentialBlockEntryUuid = null,
       credentialBlockAnchor = null,
       passkeyBlockRef = null,
       passkeyRelyingPartyId = null;

  _DecisionRecord.forRecord({
    required KdbxRecordDiff recordDiff,
    required this.redacted,
  }) : record = recordDiff,
       field = null,
       credentialBlockEntryUuid = null,
       credentialBlockAnchor = null,
       passkeyBlockRef = null,
       passkeyRelyingPartyId = null;

  /// spec 023 T209 — one row for a whole `KPEX_PASSKEY_*` group, keyed by the
  /// group rather than by any member's field ref.
  ///
  /// It carries no anchor field, unlike [_DecisionRecord.forCredentialBlock]:
  /// an anchor exists to show one member's values, and here there is no member
  /// whose values may be shown at all (FR-008). [relyingPartyId] names the
  /// credential instead, and is the only thing about it the row ever displays.
  _DecisionRecord.forPasskeyBlock({
    required KdbxPasskeyBlockRef ref,
    required String? relyingPartyId,
    required this.redacted,
  }) : field = null,
       record = null,
       credentialBlockEntryUuid = null,
       credentialBlockAnchor = null,
       passkeyBlockRef = ref,
       passkeyRelyingPartyId = relyingPartyId;

  /// spec-008 T401c — one row for a whole FR-3a credential block, keyed for
  /// [_MergeSession.resolution] by entry UUID rather than by any member's
  /// field ref. [anchorField] exists only for [display]: the highest-priority
  /// conflicting member, so the preview shown matches the row's `category`.
  _DecisionRecord.forCredentialBlock({
    required String entryUuid,
    required KdbxFieldDiff anchorField,
    required this.redacted,
  }) : field = null,
       record = null,
       credentialBlockEntryUuid = entryUuid,
       credentialBlockAnchor = anchorField,
       passkeyBlockRef = null,
       passkeyRelyingPartyId = null;

  final KdbxFieldDiff? field;
  final KdbxRecordDiff? record;
  final String? credentialBlockEntryUuid;
  final KdbxFieldDiff? credentialBlockAnchor;
  final KdbxPasskeyBlockRef? passkeyBlockRef;
  final String? passkeyRelyingPartyId;

  RedactedMergeDecision redacted;

  /// The single transient plaintext read (T203). This is the ONLY method in
  /// the whole data implementation that produces a value the presentation layer
  /// can read, and its result is non-`Equatable`, non-serializable, redacted in
  /// `toString` and disposable.
  ///
  /// A credential-block row shows its ANCHOR member only. Showing all three
  /// members is the UI-wording gap spec.md records as out of scope here
  /// (T602/T603) — this is the minimum that keeps the row from crashing on
  /// display, not the final word on what it should show.
  MergeFieldDisplay display(_MergeSession session) {
    final passkeyRef = passkeyBlockRef;
    if (passkeyRef != null) return _passkeyBlockDisplay(session, passkeyRef);
    final field = this.field ?? credentialBlockAnchor;
    if (field != null) return _fieldDisplay(session, field);
    return _recordDisplay(session, record!);
  }

  /// spec 023 T209 / FR-008 — one named credential, with redacted sides.
  ///
  /// Neither side carries a member value: not the private key, not the
  /// credential id, not the user handle. What the row shows is the relying
  /// party, which side holds a passkey at all, and when that side's entry last
  /// changed — which is what the choice is actually made on, and is the same
  /// evidence `timestampRelation` already puts on the redacted row.
  MergeFieldDisplay _passkeyBlockDisplay(
    _MergeSession session,
    KdbxPasskeyBlockRef ref,
  ) {
    final blockFields = passkeyBlockFieldsOf(session.diff, ref);
    final rpId = passkeyRelyingPartyId;
    final label = rpId == null || rpId.isEmpty ? 'Passkey' : 'Passkey ($rpId)';

    MergeDisplaySide sideOf(KdbxFile file, {required bool local}) {
      final present = blockFields.any(
        (field) => (local ? field.local : field.remote) is KdbxFieldPresent,
      );
      if (!present) return MergeDisplaySide.missing();
      final entry = session.entryOn(file, ref.entryUuid);
      if (entry == null) return MergeDisplaySide.missing();
      // Each side names its own site: on a conflicting relying party the
      // shared row label is the local one, and showing it on the remote side
      // too would hide which credential choosing remote keeps.
      final sideRp = passkeyBlockRelyingPartyIdOn(blockFields, local: local);
      return MergeDisplaySide.present(
        sideRp == null || sideRp.isEmpty ? 'Passkey' : 'Passkey ($sideRp)',
        changedAt: entry.times.lastModificationTime.get(),
      );
    }

    return MergeFieldDisplay(
      label: label,
      local: sideOf(session.pair.local.file, local: true),
      remote: sideOf(session.pair.remote.file, local: false),
      // The group holds protected members, so the row is a protected row even
      // though what it displays is not a secret.
      protected: true,
    );
  }

  MergeFieldDisplay _fieldDisplay(_MergeSession session, KdbxFieldDiff field) {
    final localEntry = session.entryOn(
      session.pair.local.file,
      field.entryUuid,
    );
    final remoteEntry = session.entryOn(
      session.pair.remote.file,
      field.entryUuid,
    );
    final protected =
        (field.local is KdbxFieldPresent &&
            (field.local as KdbxFieldPresent).isProtected) ||
        (field.remote is KdbxFieldPresent &&
            (field.remote as KdbxFieldPresent).isProtected);

    return MergeFieldDisplay(
      // FR-4 keeps a custom field / attachment name data-private until exactly
      // this transient response is requested.
      label: field.localKey ?? field.remoteKey ?? field.canonicalKey,
      local: _side(field, field.local, field.localKey, localEntry),
      remote: _side(field, field.remote, field.remoteKey, remoteEntry),
      protected: protected,
    );
  }

  MergeDisplaySide _side(
    KdbxFieldDiff field,
    KdbxFieldPresence presence,
    String? spelling,
    KdbxEntry? entry,
  ) {
    if (presence is! KdbxFieldPresent || spelling == null || entry == null) {
      return MergeDisplaySide.missing();
    }
    final changedAt = entry.times.lastModificationTime.get();
    if (field.fieldKind == KdbxMergeFieldKind.attachment) {
      return MergeDisplaySide.present(
        spelling,
        changedAt: changedAt,
        sizeBytes: presence.length,
        // A short prefix of the digest, never the bytes and never the whole
        // checksum: enough to tell "same name, different content" apart.
        fingerprint: presence.semanticValue.substring(0, 12),
      );
    }
    return MergeDisplaySide.present(
      entry.getString(KdbxKey(spelling))?.getText() ?? '',
      changedAt: changedAt,
    );
  }

  MergeFieldDisplay _recordDisplay(
    _MergeSession session,
    KdbxRecordDiff record,
  ) {
    MergeDisplaySide sideOf(KdbxFile file, KdbxRecordSide side) {
      if (!side.isLiveSomewhere) return MergeDisplaySide.missing();
      final object = session.objectOn(file, record.objectUuid);
      if (object == null) return MergeDisplaySide.missing();
      final label = object is KdbxEntry
          ? object.getString(KdbxKeyCommon.TITLE)?.getText() ?? ''
          : (object as KdbxGroup).name.get() ?? '';
      return MergeDisplaySide.present(label, changedAt: side.modifiedAtUtc);
    }

    return MergeFieldDisplay(
      label: record.objectKind == KdbxMergeObjectKind.group ? 'group' : 'entry',
      local: sideOf(session.pair.local.file, record.local),
      remote: sideOf(session.pair.remote.file, record.remote),
      protected: false,
    );
  }
}
