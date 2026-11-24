// spec-008 T302 / T302a / T303 / T308 / T309 — the merge repository against a
// real KDBX pair.
//
// Nothing here is mocked at the KDBX level: the fixtures are genuine `.kdbx`
// files, the local side is a real file on disk, the remote side is real bytes,
// and the candidate is really serialized and really reopened. What IS faked is
// the surrounding plumbing — registry, security profile, Drive mapping,
// keystore — because those are other specs' contracts and a fake makes the
// credential-resolution path observable.
//
// Scope, task by task:
//
//   * **T302** the port behaves: a review is produced, decisions update, the
//     session is disposed on cancel/invalidate, and nothing is written.
//   * **T302a** the opaque ids are minted from a CSPRNG, carry 128 bits, are
//     distinct across sessions, and are equal to no digest of any input in
//     scope. This is the requirement the id *type* was wrongly credited with.
//   * **T303** the secret boundary at RUNTIME. The AST judge already proves the
//     static direction (no domain file can reach the data layer); what it
//     cannot prove is that the values actually handed back are clean.
//   * **T308** Prefer local / Prefer remote never select a missing or deleted
//     side, every one-sided record and field survives both shortcuts, and a
//     deletion needs explicit evidence plus an explicit choice.
//   * **T309** the candidate reopens with the original credentials — password
//     only and password + key file — with a matching semantic manifest and
//     unrelated metadata, history, icons and settings intact.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
// Fixtures only: `forceSetUuid` is how two replicas are given a shared lineage.
// ignore: implementation_imports
import 'package:kdbx/src/kdbx_object.dart' show KdbxObjectInternal;
import 'package:password_manager/features/password_manager/data/datasources/secure_data_source.dart';
import 'package:password_manager/features/password_manager/data/datasources/sync_metadata_data_source.dart';
import 'package:password_manager/features/password_manager/data/repositories/sync_merge_repository_impl.dart';
import 'package:password_manager/features/password_manager/data/services/database_path_mutex.dart';
import 'package:password_manager/features/password_manager/data/services/google_drive_api_service.dart';
import 'package:password_manager/features/password_manager/data/services/kdbx_merge_adapter.dart';
import 'package:password_manager/features/password_manager/data/services/kdbx_semantic_manifest.dart';
import 'package:password_manager/features/password_manager/data/services/safe_vault_file_writer.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_security_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/sync_merge_repository.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_merge_models.dart';
import 'package:password_manager/features/password_manager/domain/services/sync_merge_policy.dart';

// Obviously fake, non-secret test material. Each string is distinctive so the
// T303 leak scan can look for it verbatim.
const _password = 'repo-not-a-real-password-9f2b';
const _databaseId = 'db-merge-fixture';
const _remoteFileIdFixture = 'drive-file-fixture';
const _sharedEntryUuid = 'CCCCCCCCCCCCCCCCCCCCAQ==';
const _localOnlyEntryUuid = 'CCCCCCCCCCCCCCCCCCCCAg==';
const _remoteOnlyEntryUuid = 'CCCCCCCCCCCCCCCCCCCCAw==';
const _deletedEntryUuid = 'CCCCCCCCCCCCCCCCCCCCBA==';
const _childGroupUuid = 'CCCCCCCCCCCCCCCCCCCCBQ==';

const _localUserName = 'alice-local-side';
const _remoteUserName = 'alice-remote-side';
const _localOnlyFieldKey = 'Custom_LocalOnlyField';
const _localOnlyFieldValue = 'local-only-field-value';
const _remoteOnlyFieldKey = 'Custom_RemoteOnlyField';
const _remoteOnlyFieldValue = 'remote-only-field-value';
const _sharedAttachmentName = 'shared.bin';
const _databaseDescription = 'unrelated description that must survive';
const _historyUserName = 'alice-history-revision';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sync-merge-repo-');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  // ===========================================================================
  // T302 — the port, end to end, against a real pair.
  // ===========================================================================
  group('T302 the port against a real KDBX pair', () {
    test(
      'startReview returns a redacted review of the real conflicts',
      () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );

        expect(summary.sessionId.token, matches(RegExp(r'^ms-[0-9a-f]{32}$')));
        expect(summary.databaseId, harness.databaseId);
        expect(summary.phase, MergeReviewPhase.reviewing);

        // One value conflict and one record deletion conflict. The value
        // conflict is UserName+Password together (FR-3a): both fields diverge
        // on the shared entry, so they are ONE engaged credential-block row,
        // anchored on `password` — the higher-priority member (T401c) — not
        // two separate rows.
        expect(
          summary.decisions
              .where((d) => d.kind == MergeDecisionKind.fieldConflict)
              .map((d) => d.category),
          contains(MergeFieldCategory.password),
        );
        expect(
          summary.decisions.where(
            (d) => d.kind == MergeDecisionKind.recordDeletionConflict,
          ),
          hasLength(1),
        );

        // One-sided data is counted, never addressable: FR-4 preserves it
        // automatically, so no shortcut can reach it.
        expect(summary.localOnlyRecordCount, 1);
        expect(summary.remoteOnlyRecordCount, 1);
        expect(summary.oneSidedFieldCount, 2);
      },
    );

    test(
      'every conflict arrives with a visible, deterministic default',
      () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );

        for (final decision in summary.decisions) {
          expect(decision.isDefault, isTrue);
          expect(
            SyncMergePolicy.availableChoicesFor(decision),
            contains(decision.choice),
          );
        }
        // FR-5: the automatic default on a deletion conflict is always keep, so
        // an unattended session can never delete.
        expect(
          summary.decisions
              .where((d) => d.kind == MergeDecisionKind.recordDeletionConflict)
              .map((d) => d.choice),
          everyElement(MergeChoice.keep),
        );
      },
    );

    test('the FR-3 default is decided by the data, not by the perspective', () async {
      // Two mirrored harnesses over the same pair with local and remote
      // swapped. The chosen VALUE must be the same on both, or two devices
      // write over each other forever.
      final forward = await _Harness.build(temp, tiedTimestamps: true);
      final mirrored = await _Harness.build(
        temp,
        tiedTimestamps: true,
        mirrored: true,
      );

      final a = await forward.repository.startReview(forward.databaseId);
      final b = await mirrored.repository.startReview(mirrored.databaseId);

      // UserName and Password both diverge on the shared entry, so this is
      // the one engaged credential-block row (T401c), anchored on
      // `password` — its single choice moves both fields together.
      final choiceA = a.decisions
          .firstWhere((d) => d.category == MergeFieldCategory.password)
          .choice;
      final choiceB = b.decisions
          .firstWhere((d) => d.category == MergeFieldCategory.password)
          .choice;

      // The value each perspective's chosen SIDE actually holds.
      String elected(MergeChoice choice, {required bool mirrored}) {
        final onLocal = mirrored ? 'remote-secret' : 'local-secret';
        final onRemote = mirrored ? 'local-secret' : 'remote-secret';
        return choice == MergeChoice.local ? onLocal : onRemote;
      }

      expect(
        choiceA,
        isNot(choiceB),
        reason: 'the sides are swapped, so the SIDE must swap with them',
      );
      expect(
        elected(choiceA, mirrored: false),
        elected(choiceB, mirrored: true),
        reason:
            'both perspectives must elect the SAME value; "prefer local" as a '
            'tie-break makes the merge non-commutative (FR-3)',
      );
    });

    test(
      'updateDecision records the answer and clears the default flag',
      () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );
        // The engaged credential-block row (T401c), anchored on `password`.
        final target = summary.decisions.firstWhere(
          (d) => d.category == MergeFieldCategory.password,
        );

        final updated = await harness.repository.updateDecision(
          sessionId: summary.sessionId,
          decisionId: target.decisionId,
          choice: MergeChoice.remote,
        );

        final after = updated.decisions.firstWhere(
          (d) => d.decisionId == target.decisionId,
        );
        expect(after.choice, MergeChoice.remote);
        expect(after.isDefault, isFalse);
      },
    );

    test(
      'an illegal override is refused before it can reach a vault',
      () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );
        final deletion = summary.decisions.firstWhere(
          (d) => d.kind == MergeDecisionKind.recordDeletionConflict,
        );

        // The record is live on exactly one side; answering it with a value
        // choice is unrepresentable (FR-4/FR-5 constructor invariants).
        await expectLater(
          harness.repository.updateDecision(
            sessionId: summary.sessionId,
            decisionId: deletion.decisionId,
            choice: MergeChoice.local,
          ),
          throwsArgumentError,
        );
      },
    );

    test('cancel and invalidate dispose the session', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);

      await harness.repository.cancel(summary.sessionId);
      await expectLater(
        harness.repository.commit(summary.sessionId),
        _failsWith(MergeFailureCode.sessionInvalidated),
      );

      final second = await harness.repository.startReview(harness.databaseId);
      await harness.repository.invalidate(harness.databaseId);
      await expectLater(
        harness.repository.updateDecision(
          sessionId: second.sessionId,
          decisionId: second.decisions.first.decisionId,
          choice: MergeChoice.remote,
        ),
        _failsWith(MergeFailureCode.sessionInvalidated),
      );
    });

    test('commit with no divergence finalizes: local replaced, upload sent, '
        'mapping updated only after the read-back matches', () async {
      // spec-008 T401. `platformDisabled` is gone: there is no
      // feature-flag mechanism anywhere in this codebase, and T111 passed
      // on all 5 platforms.
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(outcome, isA<MergeApplied>());
      final applied = outcome as MergeApplied;
      expect(applied.uploadState, MergeUploadState.uploaded);
      expect(applied.backupCreated, isTrue);

      // Exactly one upload, and the mapping was written exactly once —
      // AFTER that upload's own read-back matched.
      expect(harness.drive.updateCalls, hasLength(1));
      expect(harness.syncMetadata.upsertCalls, hasLength(1));
      final onDisk = await File(harness.databasePath).readAsBytes();
      expect(onDisk, harness.drive.updateCalls.single);
      expect(harness.remote.content, onDisk);
      expect(
        harness.syncMetadata.upsertCalls.single.lastSyncedLocalChecksum,
        md5.convert(onDisk).toString(),
      );

      // FR-2's session lifecycle: a finalized commit disposes the session.
      await expectLater(
        harness.repository.commit(summary.sessionId),
        _failsWith(MergeFailureCode.sessionInvalidated),
      );
    });

    test('a local edit that lands after review opened refuses the commit '
        'before anything is written or uploaded', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);
      // Simulates an ordinary vault edit racing the open review — written
      // directly, bypassing the merge port entirely, exactly like a VaultBloc
      // CRUD op would.
      await File(harness.databasePath)
          .writeAsBytes(Uint8List.fromList([...harness.localBytes, 0]));

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(
        outcome,
        isA<MergeRejected>()
            .having((r) => r.code, 'code', MergeFailureCode.staleLocal)
            .having((r) => r.localCommitCompleted, 'localCommitted', isFalse),
      );
      expect(harness.drive.updateCalls, isEmpty);
      expect(harness.syncMetadata.upsertCalls, isEmpty);
    });

    test('a wrong-lineage remote is refused before a session exists', () async {
      final harness = await _Harness.build(temp, foreignRemote: true);

      await expectLater(
        harness.repository.startReview(harness.databaseId),
        _failsWith(MergeFailureCode.wrongLineage),
      );
      // FR-2: no session, so no id was ever minted and nothing can be resumed.
      expect(harness.sync.uploads, isEmpty);
      expect(
        await File(harness.databasePath).readAsBytes(),
        harness.localBytes,
      );
    });

    test('D16: an unknown database id is a PRECONDITION failure, not a stale '
        'session', () async {
      // The amendment exists so Phase 6 can derive a user-facing remedy from
      // the code. `sessionInvalidated` here would mean "the session you hold
      // expired", and the remedy for that ("start the review again") is wrong
      // for a database the registry no longer knows.
      final harness = await _Harness.build(temp);

      await expectLater(
        harness.repository.startReview(MergeDatabaseId('db-not-here')),
        _failsWith(MergeFailureCode.mergePreconditionFailed),
      );
    });

    test(
      'D16: a database with no remote mapping is a PRECONDITION failure',
      () async {
        final harness = await _Harness.build(temp, withoutRemoteMapping: true);

        await expectLater(
          harness.repository.startReview(harness.databaseId),
          _failsWith(MergeFailureCode.mergePreconditionFailed),
        );
      },
    );

    test('D16: a MISSING LOCAL FILE stays staleLocal, deliberately', () async {
      // Not `mergePreconditionFailed`: the remedy "the local side is not what
      // the registry recorded, resynchronize instead of writing" is correct
      // for an absent file too, and the amendment says so in as many words.
      final harness = await _Harness.build(temp);
      await File(harness.databasePath).delete();

      await expectLater(
        harness.repository.startReview(harness.databaseId),
        _failsWith(MergeFailureCode.staleLocal),
      );
    });

    test('a revoked credential is a safe code, not a raw exception', () async {
      final harness = await _Harness.build(temp);
      harness.secure.password = null;

      await expectLater(
        harness.repository.startReview(harness.databaseId),
        _failsWith(MergeFailureCode.credentialsRevoked),
      );
    });

    test('buildCandidateBytes CONSUMES the session: a second call is refused, '
        'not silently applied twice', () async {
      // `applyMerge` mutates the local side in place, so a second application
      // re-imports every remote-only record into a tree that already holds it.
      // In debug the library asserts and a raw `AssertionError` crosses the
      // port; in release the assertion is compiled out, `addEntry` proceeds,
      // and the candidate carries two objects with the same UUID — the FR-2
      // violation `validatePair` exists to refuse, introduced by the merge
      // itself.
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);

      await harness.repository.buildCandidateBytes(summary.sessionId);

      await expectLater(
        harness.repository.buildCandidateBytes(summary.sessionId),
        _failsWith(MergeFailureCode.sessionInvalidated),
      );
    });

    test('a consumed session is dead for every other operation too, so no '
        'stale plaintext is served from a mutated local side', () async {
      // After the merge the "local" file IS the candidate, so a field display
      // read from it would report the merged value as the local one — a
      // plausible-looking lie about what the local vault contains.
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);
      // The engaged credential-block row (T401c), anchored on `password`.
      final conflict = summary.decisions.firstWhere(
        (d) => d.category == MergeFieldCategory.password,
      );

      await harness.repository.buildCandidateBytes(summary.sessionId);

      await expectLater(
        harness.repository.loadFieldDisplay(
          sessionId: summary.sessionId,
          decisionId: conflict.decisionId,
        ),
        _failsWith(MergeFailureCode.sessionInvalidated),
      );
      await expectLater(
        harness.repository.updateDecision(
          sessionId: summary.sessionId,
          decisionId: conflict.decisionId,
          choice: MergeChoice.local,
        ),
        _failsWith(MergeFailureCode.sessionInvalidated),
      );
    });

    test('the candidate is re-validated against FR-2 before serialization, so '
        'a UUID collision the merge itself created cannot escape', () async {
      // The consumption guard above closes the known route to a collision.
      // This is the second line of defence, and it is the one that still works
      // when assertions are compiled out: the candidate goes back through
      // `validatePair`, so a collision introduced by ANY apply step is refused
      // with a typed code instead of being handed to T403 as bytes.
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);

      final merged = await KdbxFormat().read(
        await harness.repository.buildCandidateBytes(summary.sessionId),
        await harness.buildCredentials(),
      );

      final uuids = merged.body.rootGroup
          .getAllGroupsAndEntries()
          .map((o) => o.uuid.uuid)
          .toList();
      expect(uuids.toSet(), hasLength(uuids.length));
    });

    test(
      'recoverPending reports nothing, because nothing was dispatched',
      () async {
        final harness = await _Harness.build(temp);
        expect(
          (await harness.repository.recoverPending(harness.databaseId))
              .disposition,
          MergeRecoveryDisposition.none,
        );
      },
    );
  });

  // ===========================================================================
  // T401a — FR-3's LWW is entry-level, not field-level (criterion 15l).
  //
  // KDBX has one `lastModificationTime` per entry, so the timestamp rules 1
  // and 2 consume is the ENTRY's — the newer entry wins ALL of its
  // conflicting fields at once. Two devices editing two DIFFERENT fields of
  // the same entry therefore do NOT get an automatic per-field union: both
  // fields still differ (neither device knows what the other changed), both
  // are independent `fieldConflict` rows, and BOTH default toward whichever
  // entry is newer as a whole — even the field the OLDER device itself
  // edited.
  // ===========================================================================
  group('T401a entry-level LWW (15l)', () {
    late Directory lwwTemp;
    setUp(() async {
      lwwTemp = await Directory.systemTemp.createTemp('sync-merge-lww-');
    });
    tearDown(() async {
      if (lwwTemp.existsSync()) await lwwTemp.delete(recursive: true);
    });

    const entryUuid = 'DDDDDDDDDDDDDDDDDDDDAQ==';

    Future<_FixturePair> lwwFixture({
      required DateTime localAt,
      required DateTime remoteAt,
    }) async {
      final credentials = Credentials(ProtectedValue.fromString(_password));
      final seed = KdbxFormat().create(credentials, 'LWW fixture');
      final entry = KdbxEntry.create(seed, seed.body.rootGroup)
        ..forceSetUuid(KdbxUuid(entryUuid));
      seed.body.rootGroup.addEntry(entry);
      entry
        ..setString(KdbxKeyCommon.TITLE, PlainValue('Shared'))
        ..setString(KdbxKey('Notes'), PlainValue('base-notes'))
        ..setString(KdbxKey('Custom_Other'), PlainValue('base-other'));
      final baseBytes = Uint8List.fromList(await seed.save());

      final localFile = await KdbxFormat().read(baseBytes, credentials);
      final remoteFile = await KdbxFormat().read(baseBytes, credentials);

      // Local edits ONLY Notes; remote edits ONLY the custom field. Neither
      // device knows what the other changed, so BOTH fields still end up
      // differing between the two sides — two INDEPENDENT fieldConflicts,
      // not one shared edit.
      _entry(localFile, entryUuid)!
        ..setString(KdbxKey('Notes'), PlainValue('local-notes'))
        ..times.lastModificationTime.set(localAt);
      _entry(remoteFile, entryUuid)!
        ..setString(KdbxKey('Custom_Other'), PlainValue('remote-other'))
        ..times.lastModificationTime.set(remoteAt);

      return _FixturePair(
        keyFilePath: '${lwwTemp.path}/unused.keyx',
        keyFileBytes: null,
        credentials: credentials,
        localBytes: Uint8List.fromList(await localFile.save()),
        remoteBytes: Uint8List.fromList(await remoteFile.save()),
        rootUuid: localFile.body.rootGroup.uuid,
        deletionTime: DateTime.utc(2020),
      );
    }

    test('both fields default toward the newer ENTRY, including the field '
        'the OLDER device itself edited — asserted so a silent per-field '
        'union reintroduction fails this test', () async {
      final fixture = await lwwFixture(
        localAt: DateTime.utc(2020, 1, 1),
        remoteAt: DateTime.utc(2021, 1, 1),
      );
      final harness = await _Harness.build(lwwTemp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);

      final notes = summary.decisions.singleWhere(
        (d) => d.category == MergeFieldCategory.notes,
      );
      final custom = summary.decisions.singleWhere(
        (d) => d.category == MergeFieldCategory.customField,
      );

      // A per-field union would keep `local-notes` (LOCAL's own edit) and
      // `remote-other` (REMOTE's own edit) — i.e. `notes` defaulting LOCAL.
      // Entry-level LWW instead elects the newer ENTRY (remote) for BOTH,
      // discarding local's Notes edit by default.
      expect(notes.choice, MergeChoice.remote);
      expect(custom.choice, MergeChoice.remote);
    });

    test('swapping which entry is newer swaps BOTH defaults together, never '
        'independently', () async {
      final fixture = await lwwFixture(
        localAt: DateTime.utc(2021, 1, 1),
        remoteAt: DateTime.utc(2020, 1, 1),
      );
      final harness = await _Harness.build(lwwTemp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);

      final notes = summary.decisions.singleWhere(
        (d) => d.category == MergeFieldCategory.notes,
      );
      final custom = summary.decisions.singleWhere(
        (d) => d.category == MergeFieldCategory.customField,
      );

      expect(notes.choice, MergeChoice.local);
      expect(custom.choice, MergeChoice.local);
    });
  });

  // ===========================================================================
  // T401 — the FR-7 write-verify-converge cycle: divergence, the sticky
  // ledger, the retry budget, ambiguous read-backs and the semantic-manifest
  // short-circuit. `harness.remote` is the single mutable "what Drive
  // actually holds" fixture, so a test simulates a concurrent writer either
  // by mutating it directly before `commit` (a write that landed before the
  // cycle started) or via `onUpload` (a write that lands strictly between an
  // upload and its own read-back).
  // ===========================================================================
  group('T401 write-verify-converge cycle', () {
    const entryUuid = 'FFFFFFFFFFFFFFFFFFFFAQ==';
    late Directory t401Temp;
    setUp(() async {
      t401Temp = await Directory.systemTemp.createTemp('sync-merge-t401-');
    });
    tearDown(() async {
      if (t401Temp.existsSync()) await t401Temp.delete(recursive: true);
    });

    test('a benign remote divergence (metadata only) re-merges automatically '
        'via the sticky ledger and still finalizes in one upload', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);

      // A write that landed on the remote before this commit call even
      // started: same field conflict, only the (auto-merged) description
      // differs.
      harness.remote.content = await _withDescription(
        fixture.remoteBytes,
        fixture.credentials,
        'v2-description',
        DateTime.utc(2030),
      );

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(outcome, isA<MergeApplied>());
      // Resolved INLINE within the first round: a pre-write divergence has
      // no candidate yet to short-circuit against, so it always re-merges,
      // but that re-merge does not by itself spend a second upload.
      expect(harness.drive.updateCalls, hasLength(1));

      final merged = await KdbxFormat().read(
        await File(harness.databasePath).readAsBytes(),
        fixture.credentials,
      );
      expect(merged.body.meta.databaseDescription.get(), 'v2-description');
      expect(
        _entry(merged, entryUuid)!.getString(KdbxKey('Notes'))?.getText(),
        'remote-notes-v1',
        reason:
            'the sticky decision for Notes must survive a divergence '
            'that never touched it',
      );
    });

    test('a divergent remote that introduces a field the ledger never saw '
        'returns MergeNeedsReview and writes nothing; answering it and '
        'committing again finalizes', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);
      final before = await File(harness.databasePath).readAsBytes();

      // A concurrent write that ADDS a field local also independently
      // holds (with a different value) — a genuine NEW conflict, never
      // shown at review time (remoteV1 does not have this field at all).
      final remoteV2 = await KdbxFormat().read(
        fixture.remoteBytes,
        fixture.credentials,
      );
      _entry(
        remoteV2,
        entryUuid,
      )!.setString(KdbxKey('Custom_New'), PlainValue('remote-new-value'));
      harness.remote.content = Uint8List.fromList(await remoteV2.save());

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(outcome, isA<MergeNeedsReview>());
      final needsReview = outcome as MergeNeedsReview;
      expect(needsReview.newConflictCount, 1);
      expect(needsReview.reviewReentryCount, 1);
      // Nothing was written: the divergence was caught before step 4 ever
      // built a candidate off a guessed side.
      expect(harness.drive.updateCalls, isEmpty);
      expect(harness.syncMetadata.upsertCalls, isEmpty);
      expect(await File(harness.databasePath).readAsBytes(), before);

      final newConflict = needsReview.summary.decisions.firstWhere(
        (d) => d.category == MergeFieldCategory.customField,
      );
      await harness.repository.updateDecision(
        sessionId: summary.sessionId,
        decisionId: newConflict.decisionId,
        choice: MergeChoice.local,
      );

      final second = await harness.repository.commit(summary.sessionId);

      expect(second, isA<MergeApplied>());
      expect(harness.drive.updateCalls, hasLength(1));
      final merged = await KdbxFormat().read(
        await File(harness.databasePath).readAsBytes(),
        fixture.credentials,
      );
      final mergedEntry = _entry(merged, entryUuid)!;
      expect(
        mergedEntry.getString(KdbxKey('Custom_New'))?.getText(),
        'local-new-value',
      );
      expect(
        mergedEntry.getString(KdbxKey('Notes'))?.getText(),
        'remote-notes-v1',
        reason:
            'the ORIGINAL sticky decision must still hold on the '
            'second commit',
      );
    });

    test('a remote that keeps racing past the retry budget ends '
        'unresolvedConflict, retaining the local file and never marking '
        'synced', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);

      // Every upload is immediately superseded by a fresh, ever-different,
      // never-matching remote write — the description keeps moving with a
      // strictly newer clock each time, so `_mergeMeta` keeps adopting it
      // and no candidate ever catches up within the retry budget. It never
      // creates a genuinely new field conflict, so this exercises the
      // budget, not the review re-entry path.
      var generation = 0;
      harness.remote.onUpload = (uploaded) async {
        generation++;
        return _withDescription(
          uploaded,
          fixture.credentials,
          'race-$generation',
          DateTime.utc(2030).add(Duration(days: generation)),
        );
      };

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(
        outcome,
        isA<MergeRejected>()
            .having((r) => r.code, 'code', MergeFailureCode.unresolvedConflict)
            .having((r) => r.localCommitCompleted, 'localCommitted', isTrue),
      );
      expect(harness.drive.updateCalls, hasLength(3));
      expect(harness.syncMetadata.upsertCalls, isEmpty);
      // The local file and its backup are retained: the last round's
      // candidate is exactly what SafeVaultFileWriter wrote, whether or not
      // the upload it fed ever finalized.
      expect(
        await File(harness.databasePath).readAsBytes(),
        harness.drive.updateCalls.last,
      );
    });

    test('a non-executable read-back (no checksum returned) is ambiguous: '
        'local is written but the mapping is never finalized, and the upload '
        'is not retried blindly', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);
      final before = await File(harness.databasePath).readAsBytes();
      harness.remote.suppressChecksumOnUpdate = true;

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(
        outcome,
        isA<MergeRejected>()
            .having(
              (r) => r.code,
              'code',
              MergeFailureCode.uploadOutcomeAmbiguous,
            )
            .having((r) => r.localCommitCompleted, 'localCommitted', isTrue),
      );
      expect(harness.drive.updateCalls, hasLength(1));
      expect(harness.syncMetadata.upsertCalls, isEmpty);
      expect(await File(harness.databasePath).readAsBytes(), isNot(before));
    });

    test(
      'a transport failure during upload is ambiguous, not a rejection',
      () async {
        final fixture = await _t401Fixture(t401Temp);
        final harness = await _Harness.build(t401Temp, fixture: fixture);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );
        harness.remote.updateFileError = Exception('network boom');

        final outcome = await harness.repository.commit(summary.sessionId);

        expect(
          outcome,
          isA<MergeRejected>()
              .having(
                (r) => r.code,
                'code',
                MergeFailureCode.uploadOutcomeAmbiguous,
              )
              .having((r) => r.localCommitCompleted, 'localCommitted', isTrue),
        );
        expect(harness.syncMetadata.upsertCalls, isEmpty);
      },
    );

    test('T404 the pending record is written before the dispatch, describes '
        'both sides, and carries no credential', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);
      // Fail the upload so the record is observed in its pre-dispatch form:
      // if it were written after the request, this would leave none at all.
      harness.remote.updateFileError = Exception('network boom');

      await harness.repository.commit(summary.sessionId);

      final record = harness.syncMetadata.pendingUploadCalls.first;
      expect(record.databasePath, harness.databasePath);
      expect(record.remoteFileId, isNotEmpty);
      // Separate fields answering separate recovery questions, even though
      // the bytes written are the bytes sent, so they coincide here.
      expect(record.mergedChecksum, isNotEmpty);
      expect(record.localCommittedChecksum, record.mergedChecksum);
      expect(record.backupPath, isNotNull);

      // The security boundary: this file is persisted unencrypted next to the
      // sync mappings, so nothing secret may appear in it.
      final serialized = jsonEncode(record.toMap());
      expect(serialized, isNot(contains(_password)));

      // T406: the transport failure flips the SAME record rather than
      // replacing or clearing it.
      expect(
        harness.syncMetadata.pendingUploadCalls.first.outcomeAmbiguous,
        isFalse,
      );
      expect(
        harness.syncMetadata.pendingUploadCalls.last.outcomeAmbiguous,
        isTrue,
      );
    });

    test('T404 a confirmed read-back drops the pending record', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(outcome, isA<MergeApplied>());
      // The record was written before the dispatch, so it must have existed...
      expect(harness.syncMetadata.pendingUploadCalls, isNotEmpty);
      // ...and must be gone once the read-back confirmed the remote holds the
      // dispatched bytes and the mapping was finalized. Left behind, recovery
      // (T407-T409) would read a completed merge as an un-triaged upload.
      expect(
        await harness.syncMetadata.getPendingUpload(harness.databasePath),
        isNull,
      );
    });

    test('T404 the semantic short-circuit drops the pending record too', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);
      // Same content, different bytes: finalized on the observed checksum via
      // the second success path, which must clear the record just as the first
      // one does.
      harness.remote.onUpload = (uploaded) =>
          _resave(uploaded, fixture.credentials);

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(outcome, isA<MergeApplied>());
      expect(harness.syncMetadata.pendingUploadCalls, isNotEmpty);
      expect(
        await harness.syncMetadata.getPendingUpload(harness.databasePath),
        isNull,
      );
    });

    test('T406 a failed re-download after divergence marks the record '
        'ambiguous', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);
      // Break the network strictly between the upload and the re-download the
      // divergence branch performs — the precheck download has already
      // happened by then, so this reaches the branch under test and no other.
      harness.remote.onUpload = (uploaded) async {
        harness.remote.downloadError = Exception('network boom');
        return _resave(uploaded, fixture.credentials);
      };

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(
        outcome,
        isA<MergeRejected>().having(
          (r) => r.code,
          'code',
          MergeFailureCode.uploadOutcomeAmbiguous,
        ),
      );
      // The write went out and its outcome is unknown, exactly as on the two
      // sibling paths. The record must say so rather than keep its
      // pre-dispatch `false` while the returned code says ambiguous.
      final record = await harness.syncMetadata.getPendingUpload(
        harness.databasePath,
      );
      expect(record, isNotNull);
      expect(record!.outcomeAmbiguous, isTrue);
    });

    test('a metadata-recheck failure before any write is ambiguous and touches '
        'nothing', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);
      final before = await File(harness.databasePath).readAsBytes();
      harness.remote.getMetadataError = Exception('network boom');

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(
        outcome,
        isA<MergeRejected>()
            .having(
              (r) => r.code,
              'code',
              MergeFailureCode.uploadOutcomeAmbiguous,
            )
            .having((r) => r.localCommitCompleted, 'localCommitted', isFalse),
      );
      expect(harness.drive.updateCalls, isEmpty);
      expect(await File(harness.databasePath).readAsBytes(), before);
    });

    test('a post-upload checksum mismatch that is semantically identical '
        'short-circuits: no second upload, and the mapping records what the '
        'remote actually holds', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);
      // The server reports a DIFFERENT raw checksum for the same content —
      // e.g. re-encrypted with fresh salts by some intermediate layer.
      // `serializeCandidate`'s own reopen-and-compare is the model for why
      // this must be a semantic, not a byte, comparison.
      harness.remote.onUpload = (uploaded) =>
          _resave(uploaded, fixture.credentials);

      final outcome = await harness.repository.commit(summary.sessionId);

      expect(outcome, isA<MergeApplied>());
      expect(harness.drive.updateCalls, hasLength(1));
      expect(harness.syncMetadata.upsertCalls, hasLength(1));
      expect(
        harness.syncMetadata.upsertCalls.single.lastSyncedRemoteChecksum,
        md5.convert(harness.remote.content).toString(),
      );
    });

    test('a mid-cycle MergeNeedsReview after an earlier round already wrote '
        'and uploaded does not poison the session: the second commit() call '
        'succeeds off the answered decision instead of refusing staleLocal '
        'forever', () async {
      final fixture = await _t401Fixture(t401Temp);
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);
      final before = await File(harness.databasePath).readAsBytes();

      // A third device's edit that lands strictly between round 0's upload
      // and its own read-back: `onUpload` mutates what the "server" ends up
      // holding, injecting a value the ledger has never seen for a field
      // both sides already carry. Round 0 still completes its write+upload —
      // a real, permanent local commit — but the read-back proves the
      // remote no longer matches what was sent, so it re-anchors and
      // re-merges into round 1, where the genuinely new conflict surfaces
      // and stops the cycle with `MergeNeedsReview`.
      var injected = false;
      harness.remote.onUpload = (uploaded) async {
        if (injected) return uploaded;
        injected = true;
        final remoteFile = await KdbxFormat().read(
          uploaded,
          fixture.credentials,
        );
        _entry(
          remoteFile,
          entryUuid,
        )!.setString(KdbxKey('Custom_New'), PlainValue('third-device-value'));
        return Uint8List.fromList(await remoteFile.save());
      };

      final first = await harness.repository.commit(summary.sessionId);

      expect(first, isA<MergeNeedsReview>());
      final needsReview = first as MergeNeedsReview;
      expect(needsReview.newConflictCount, 1);
      expect(needsReview.reviewReentryCount, 1);
      // Round 0 genuinely wrote and uploaded before round 1 found the new
      // conflict: this is the write the bug used to lose track of.
      expect(harness.drive.updateCalls, hasLength(1));
      expect(await File(harness.databasePath).readAsBytes(), isNot(before));

      final newConflict = needsReview.summary.decisions.singleWhere(
        (d) => d.isDefault,
      );
      await harness.repository.updateDecision(
        sessionId: summary.sessionId,
        decisionId: newConflict.decisionId,
        choice: MergeChoice.local,
      );

      final second = await harness.repository.commit(summary.sessionId);

      // Pre-fix: this returned `MergeRejected(staleLocal, localCommitCompleted:
      // false)` forever, because the step-1/2 precheck compared the
      // already-written on-disk file against `startReview`'s original
      // pristine checksum. Post-fix: the session's expected local checksum
      // was advanced when round 0 wrote, so the precheck sees the truth and
      // this call proceeds into a normal round using the newly-answered
      // decision.
      expect(second, isA<MergeApplied>());
      expect(harness.drive.updateCalls, hasLength(2));
      expect(harness.syncMetadata.upsertCalls, hasLength(1));

      final merged = await KdbxFormat().read(
        await File(harness.databasePath).readAsBytes(),
        fixture.credentials,
      );
      final mergedEntry = _entry(merged, entryUuid)!;
      expect(
        mergedEntry.getString(KdbxKey('Custom_New'))?.getText(),
        'local-new-value',
        reason: 'the newly-answered decision must be applied',
      );
      expect(
        mergedEntry.getString(KdbxKey('Notes'))?.getText(),
        'remote-notes-v1',
        reason:
            'the round-0 sticky decision must still hold on the second call',
      );
    });

    test('a 4th genuinely-new conflict after 3 review reentries ends the '
        'session as unresolvedConflict, per the frozen doc comment on '
        'MergeNeedsReview.reviewReentryCount, instead of a 4th '
        'MergeNeedsReview', () async {
      const localEntryUuid = 'FFFFFFFFFFFFFFFFFFFFAQ==';
      final credentials = Credentials(ProtectedValue.fromString(_password));
      final base = KdbxFormat().create(
        credentials,
        'T401 Reentry Cap Fixture',
        generator: 'spec-008-t401',
      );
      final entry = KdbxEntry.create(base, base.body.rootGroup)
        ..forceSetUuid(KdbxUuid(localEntryUuid));
      base.body.rootGroup.addEntry(entry);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('Shared'));
      // Present, IDENTICAL, on both sides from the start: no conflict exists
      // until a later round mutates the remote copy of one of these — which
      // is exactly what makes each round's conflict genuinely new rather
      // than a repeat of the previous one.
      for (final key in const [
        'Custom_1',
        'Custom_2',
        'Custom_3',
        'Custom_4',
      ]) {
        entry.setString(KdbxKey(key), PlainValue('shared-$key'));
      }
      final baseBytes = Uint8List.fromList(await base.save());
      final localBytes = Uint8List.fromList(
        await (await KdbxFormat().read(baseBytes, credentials)).save(),
      );
      final remoteFile = await KdbxFormat().read(baseBytes, credentials);
      final remoteBytes = Uint8List.fromList(await remoteFile.save());

      final fixture = _FixturePair(
        keyFilePath: '${t401Temp.path}/unused-reentry.keyx',
        keyFileBytes: null,
        credentials: credentials,
        localBytes: localBytes,
        remoteBytes: remoteBytes,
        rootUuid: base.body.rootGroup.uuid,
        deletionTime: DateTime.utc(2020),
      );
      final harness = await _Harness.build(t401Temp, fixture: fixture);
      final summary = await harness.repository.startReview(harness.databaseId);

      Future<void> injectRemoteConflict(String key) async {
        final remote = await KdbxFormat().read(
          harness.remote.content,
          fixture.credentials,
        );
        _entry(
          remote,
          localEntryUuid,
        )!.setString(KdbxKey(key), PlainValue('remote-$key'));
        harness.remote.content = Uint8List.fromList(await remote.save());
      }

      // Three genuinely new conflicts, one per commit() call, each answered
      // before the next drives `reviewReentryCount` from 0 to 1, 2, then 3 —
      // exactly the cap FR-7 N2 and the frozen `reviewReentryCount` doc
      // comment describe.
      var reentry = 0;
      for (final key in const ['Custom_1', 'Custom_2', 'Custom_3']) {
        await injectRemoteConflict(key);
        final outcome = await harness.repository.commit(summary.sessionId);
        reentry++;
        expect(outcome, isA<MergeNeedsReview>());
        final needsReview = outcome as MergeNeedsReview;
        expect(needsReview.newConflictCount, 1);
        expect(needsReview.reviewReentryCount, reentry);
        final newConflict = needsReview.summary.decisions.singleWhere(
          (d) => d.isDefault,
        );
        await harness.repository.updateDecision(
          sessionId: summary.sessionId,
          decisionId: newConflict.decisionId,
          choice: MergeChoice.local,
        );
      }

      // The 4th genuinely new conflict: the cap is already at 3, so this must
      // NOT produce a 4th MergeNeedsReview.
      await injectRemoteConflict('Custom_4');
      final fourth = await harness.repository.commit(summary.sessionId);

      expect(
        fourth,
        isA<MergeRejected>()
            .having((r) => r.code, 'code', MergeFailureCode.unresolvedConflict)
            .having((r) => r.localCommitCompleted, 'localCommitted', isFalse),
      );
      expect(harness.drive.updateCalls, isEmpty);
      expect(harness.syncMetadata.upsertCalls, isEmpty);
      // The cap disposes the session: it is not left around for a 4th review.
      await expectLater(
        harness.repository.commit(summary.sessionId),
        _failsWith(MergeFailureCode.sessionInvalidated),
      );
    });
  });

  // ===========================================================================
  // T302a — opaque id minting.
  //
  // The frozen contract says in as many words that the id TYPE cannot deliver
  // non-derivability, and relocates the guarantee here. So these tests check
  // the minting, and one of them pins the type's actual weakness so it cannot
  // be quietly re-credited later.
  // ===========================================================================
  group('T302a opaque id minting', () {
    final source = File(_implPath).readAsStringSync();

    test('the ONLY source of variability in a token is _secureRandom.nextInt', () {
      // The previous version of this group checked the file for the *strings*
      // `Random.secure()` and `Random(`, which a tester walked straight past:
      // leave `_secureRandom` declared, initialised and referenced in a dead
      // branch, mint from a hand-rolled LCG that never writes the word
      // `Random`, and all three source assertions plus "25 distinct tokens"
      // plus "no token is a digest" stay green — while every session id in the
      // process becomes predictable from one observed token.
      //
      // So the assertion is on the BODY of the minting function, and it is
      // fail-closed: every call it makes must be in this list, which contains
      // exactly one source of entropy.
      const allowedCalls = <String>{
        'nextInt', // the CSPRNG draw
        'write', // StringBuffer
        'toRadixString',
        'padLeft',
        'toString',
      };

      final body = _topLevelFunctionBody(source, '_mintToken');
      final calls = RegExp(r'\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\(')
          .allMatches(body)
          .map((m) => m.group(1)!)
          .toSet();

      expect(
        calls.difference(allowedCalls),
        isEmpty,
        reason:
            '_mintToken calls something outside $allowedCalls. If a new call '
            'is genuinely not a source of entropy, argue it here — this check '
            'refuses what it cannot evaluate.',
      );
      expect(
        RegExp(r'_secureRandom\.nextInt\(').allMatches(body),
        hasLength(1),
        reason: 'exactly one CSPRNG draw per byte, from the one generator',
      );
      // No arithmetic generator smuggled in beside the draw: an LCG needs a
      // multiply or a modulo, and a token has no use for either.
      for (final operator in const ['*', '%', '^', '>>', '<<', '~/']) {
        expect(
          body,
          isNot(contains(operator)),
          reason: 'an arithmetic "$operator" in a token mint is a PRNG',
        );
      }
    });

    test('_secureRandom is declared once and used exactly once', () {
      final code = source.replaceAll(RegExp('^[ ]*//.*', multiLine: true), '');
      final references = RegExp(r'\b_secureRandom\b').allMatches(code).length;
      expect(
        references,
        2,
        reason:
            'exactly the declaration and the single draw in _mintToken. A '
            'second reference means a second minting path exists, and only '
            'one of them is under test.',
      );
      expect(
        _topLevelFunctionBody(source, '_mintToken'),
        contains('_secureRandom'),
        reason: 'the one use must be the mint, not a dead branch elsewhere',
      );
    });

    test('the source of randomness is Random.secure(), and nothing else', () {
      expect(source, contains('Random.secure()'));
      expect(
        RegExp(r'Random\((?!\))').hasMatch(source),
        isFalse,
        reason: 'a seeded Random would make every token predictable',
      );
      // Every executable mention of `Random` must be either the declaration
      // of the single generator or the `.secure()` call that initialises it.
      // Comments are stripped first so prose about randomness cannot make the
      // count pass or fail.
      final code = source.replaceAll(RegExp('^[ ]*//.*', multiLine: true), '');
      final mentions = RegExp(r'\bRandom\b').allMatches(code).length;
      expect(
        mentions,
        2,
        reason:
            'expected exactly two: the `final Random _secureRandom` type '
            'annotation and its `Random.secure()` initialiser, on one line. '
            'Found $mentions.',
      );
    });

    test('a token carries 128 bits of entropy', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);

      // 32 hex characters = 16 bytes = 128 bits, which is the declared floor.
      final body = summary.sessionId.token.substring('ms-'.length);
      expect(body, hasLength(32));
      expect(body, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(body.length * 4, greaterThanOrEqualTo(128));
      for (final decision in summary.decisions) {
        expect(
          decision.decisionId.token,
          matches(RegExp(r'^md-[0-9a-f]{32}$')),
        );
      }
    });

    test('tokens minted for the SAME database and the same decisions are all '
        'distinct across sessions', () async {
      final harness = await _Harness.build(temp);
      final sessionTokens = <String>{};
      final decisionTokens = <String>{};

      const rounds = 25;
      for (var i = 0; i < rounds; i++) {
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );
        sessionTokens.add(summary.sessionId.token);
        decisionTokens.addAll(summary.decisions.map((d) => d.decisionId.token));
        await harness.repository.cancel(summary.sessionId);
      }

      expect(sessionTokens, hasLength(rounds));
      // Same database, same conflicts, same field keys, every round: a derived
      // id would collide on every one of them.
      expect(
        decisionTokens,
        hasLength(rounds * (await _decisionCount(harness))),
      );
    });

    test('no minted token is a digest of any input in scope', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);

      final inputs = <String>[
        harness.databasePath,
        _databaseId,
        _password,
        _remoteFileIdFixture,
        _sharedEntryUuid,
        _localOnlyFieldKey,
        _remoteOnlyFieldKey,
        _sharedAttachmentName,
        _localUserName,
        _remoteUserName,
        'username',
        md5.convert(harness.localBytes).toString(),
      ];
      final digests = <String>{
        for (final input in inputs) ...[
          md5.convert(utf8.encode(input)).toString(),
          sha1.convert(utf8.encode(input)).toString().substring(0, 32),
          sha256.convert(utf8.encode(input)).toString().substring(0, 32),
        ],
      };

      final minted = <String>[
        summary.sessionId.token,
        for (final decision in summary.decisions) decision.decisionId.token,
      ];
      for (final token in minted) {
        expect(
          digests,
          isNot(contains(token.substring(3))),
          reason: 'a minted token equals a digest of an input',
        );
      }
    });

    test('the id TYPE would happily accept a derived token — which is exactly '
        'why the guarantee lives in the minting', () {
      // Pinned as an executable fact so the shape check cannot be re-credited
      // with a guarantee it does not provide (Phase 2 tester finding F5).
      final derived = md5
          .convert(utf8.encode('/Users/me/Vault.kdbx'))
          .toString();
      expect(() => MergeSessionId('ms-$derived'), returnsNormally);
      expect(() => MergeDecisionId('md-$derived'), returnsNormally);
    });
  });

  // ===========================================================================
  // FR-2 — the ordering inside `startReview`.
  //
  // "No session, backup, local write or upload before the guards pass" is
  // guaranteed today by the shape of the call graph, and by nothing else:
  // moving the mint and the registration above `validatePair` (with `pair` and
  // `diff` made `late`) leaves every behavioural test green while a rejected
  // lineage leaves a live session holding the credentials. The CSPRNG is
  // deliberately not injectable, which removes the seam that would let a
  // runtime test count mints — so the ordering is asserted where it is
  // written.
  // ===========================================================================
  group('FR-2 nothing exists before the guards pass', () {
    test('validatePair is invoked before the session id is minted, and the '
        'session is registered after both', () {
      final body = _methodBody(
        File(_implPath).readAsStringSync(),
        'SyncMergeRepositoryImpl',
        'startReview',
      );

      final validate = body.indexOf('validatePair(');
      final mint = body.indexOf('_mintSessionId(');
      final register = body.indexOf('_sessions[');

      expect(validate, isNonNegative, reason: 'startReview must validate');
      expect(mint, isNonNegative, reason: 'startReview must mint');
      expect(register, isNonNegative, reason: 'startReview must register');

      expect(
        validate,
        lessThan(mint),
        reason:
            'FR-2: a lineage or UUID-integrity refusal must happen before an '
            'id exists, or a rejected pair leaves a resumable session',
      );
      expect(
        register,
        greaterThan(mint),
        reason: 'the session cannot be in the store before it is built',
      );
    });

    test('buildCandidateBytes consumes the session BEFORE applying, and '
        're-validates its own output', () {
      // The behavioural tests above prove the consumption guard, because a
      // second call is reachable. The output re-validation is the SECOND layer
      // and, with the first layer in place, nothing can reach it — so deleting
      // it leaves every behavioural test green. It is the layer that still
      // works when assertions are compiled out, so it is pinned where it is
      // written rather than left to a failure mode that no longer exists.
      final body = _methodBody(
        File(_implPath).readAsStringSync(),
        'SyncMergeRepositoryImpl',
        'buildCandidateBytes',
      );

      final consume = body.indexOf('_sessions.remove(');
      final apply = body.indexOf('applyMerge(');
      final revalidate = body.indexOf('validatePair(');
      final serialize = body.indexOf('serializeCandidate(');

      expect(consume, isNonNegative, reason: 'the session must be consumed');
      expect(
        consume,
        lessThan(apply),
        reason:
            'consuming after applying would leave a half-applied session '
            'reachable if the apply threw',
      );
      expect(
        revalidate,
        greaterThan(apply),
        reason:
            'FR-2 on the OUTPUT: the merge is the one step that can create a '
            'UUID collision, and in release the library asserts nothing',
      );
      expect(
        revalidate,
        lessThan(serialize),
        reason: 'a collision must be refused before it becomes bytes',
      );

      // Presence and position are not execution: a re-validation wrapped in a
      // branch that is never taken satisfies every assertion above. So the
      // call must be an unconditional statement directly in the try block —
      // no `if`, no `assert`, no loop, nothing that can skip it.
      final statements = _tryBlockStatements(
        File(_implPath).readAsStringSync(),
        'SyncMergeRepositoryImpl',
        'buildCandidateBytes',
      );
      expect(
        statements.where(
          (statement) =>
              statement is ExpressionStatement &&
              statement.expression.toSource().contains('validatePair('),
        ),
        hasLength(1),
        reason:
            'the candidate re-validation must be a direct, unconditional '
            'statement of the try block — not merely present somewhere in the '
            'method text, which a never-taken branch also satisfies',
      );
    });

    test('a refused pair leaves no session behind, observably', () async {
      // The behavioural half: the id space is unobservable from outside, so
      // what is asserted is that nothing survives the refusal — a subsequent
      // successful review is the FIRST session, and cancelling it empties the
      // store.
      final harness = await _Harness.build(temp, foreignRemote: true);

      await expectLater(
        harness.repository.startReview(harness.databaseId),
        _failsWith(MergeFailureCode.wrongLineage),
      );
      expect(harness.sync.uploads, isEmpty);
      expect(
        await File(harness.databasePath).readAsBytes(),
        harness.localBytes,
      );
    });
  });

  // ===========================================================================
  // FR-3 — commutativity, end to end.
  //
  // T009 proved the MODEL converges. This is the bridge to the implementation:
  // two devices merging the same pair from opposite perspectives must produce
  // the same candidate. If they do not, each rewrites the other's result, the
  // FR-7 semantic short-circuit never fires, and the sync oscillates across
  // sessions where no retry budget can stop it.
  // ===========================================================================
  group('FR-3 the merge is commutative end to end', () {
    test('mirrored perspectives produce the same candidate content — value '
        'conflict, one-sided record per side, and a deletion', () async {
      final fixture = await _Harness.pair(temp, tiedTimestamps: true);
      final forward = await _Harness.build(temp, fixture: fixture);
      final mirrored = await _Harness.build(
        temp,
        fixture: fixture,
        mirrored: true,
      );

      final a = await forward.repository.startReview(forward.databaseId);
      final b = await mirrored.repository.startReview(mirrored.databaseId);
      // No shortcut and no override: the automatic FR-3 defaults are exactly
      // what has to agree.
      final left = await forward.reopenCandidate(a.sessionId);
      // **The two devices merge in different seconds, on purpose.** In the
      // field they always do, and an earlier version of this test was ~27%
      // flaky precisely because sometimes they did not: `addEntry` and
      // `setString` stamp `DateTime.now()`, so the candidate depended on when
      // it was built. Forcing the gap turns that from a flake into a
      // deterministic assertion.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final right = await mirrored.reopenCandidate(b.sessionId);

      final leftManifest = kdbxSemanticManifest(left);
      final rightManifest = kdbxSemanticManifest(right);

      // The substantive claim: same records, same fields, same values, same
      // tombstones, whichever side each device calls "local".
      expect(
        kdbxManifestDigest(_commutativeProjection(leftManifest)),
        kdbxManifestDigest(_commutativeProjection(rightManifest)),
        reason: _manifestDifferences(
          _commutativeProjection(leftManifest),
          _commutativeProjection(rightManifest),
        ).join('\n'),
      );

      // Spelled out, so a future normalisation bug cannot make the digest
      // comparison vacuous.
      expect(
        _entry(
          left,
          _sharedEntryUuid,
        )!.getString(KdbxKeyCommon.USER_NAME)?.getText(),
        _entry(
          right,
          _sharedEntryUuid,
        )!.getString(KdbxKeyCommon.USER_NAME)?.getText(),
      );
      for (final uuid in const [_localOnlyEntryUuid, _remoteOnlyEntryUuid]) {
        expect(_entry(left, uuid), isNotNull);
        expect(_entry(right, uuid), isNotNull);
      }
      expect(_entry(left, _deletedEntryUuid), isNotNull);
      expect(_entry(right, _deletedEntryUuid), isNotNull);
      expect(tombstonesOf(left).keys.toSet(), tombstonesOf(right).keys.toSet());
    });

    test('the two dimensions that are NOT commutative yet — pinned as '
        'findings, not hidden by the projection above', () async {
      // Both are real, both are reported with this slice, and neither is
      // fixable inside an apply step:
      //
      //   * SIBLING ORDER — each device appends what it imports to the end of
      //     the target group. Making it commutative needs a total order over
      //     siblings computed from the data, which is FR-3's own remedy and
      //     T401a's task.
      //   * ENTRY HISTORY — KDBX history is a per-replica edit log. FR-1 says
      //     preserve it; nothing says merge it, and merging two edit logs is a
      //     design question, not an implementation detail.
      //
      // A third divergence used to live here and has been FIXED rather than
      // projected away, because unlike these two it was state the merge wrote
      // itself: `addEntry`/`setString` stamped `DateTime.now()`, so the two
      // candidates differed on every object the merge touched. See
      // `_stampDeterministicTimes`.
      //
      // Both matter beyond cosmetics: FR-7 step 5 arbitrates with the
      // canonical manifest, so two candidates differing on either dimension
      // compare "different", the semantic short-circuit never fires, and the
      // round burns retry budget re-writing a conflict that does not exist.
      final fixture = await _Harness.pair(temp, tiedTimestamps: true);
      final forward = await _Harness.build(temp, fixture: fixture);
      final mirrored = await _Harness.build(
        temp,
        fixture: fixture,
        mirrored: true,
      );

      final left = await forward.reopenCandidate(
        (await forward.repository.startReview(forward.databaseId)).sessionId,
      );
      final right = await mirrored.reopenCandidate(
        (await mirrored.repository.startReview(mirrored.databaseId)).sessionId,
      );

      List<String> rootOrder(KdbxFile file) =>
          file.body.rootGroup.entries.map((e) => e.uuid.uuid).toList();

      expect(
        rootOrder(left).toSet(),
        rootOrder(right).toSet(),
        reason:
            'the SET of records already agrees — only the sequence does not',
      );
      expect(
        rootOrder(left),
        isNot(orderedEquals(rootOrder(right))),
        reason:
            'if this starts passing, sibling order became commutative: delete '
            'this expectation and drop the sort from _commutativeProjection',
      );

      List<Object?> history(KdbxFile file) => _entry(file, _sharedEntryUuid)!
          .history
          .map((h) => h.getString(KdbxKeyCommon.USER_NAME)?.getText())
          .toList();

      expect(
        history(left),
        isNot(orderedEquals(history(right))),
        reason:
            'if this starts passing, history became commutative: delete this '
            'expectation and drop the history drop from _commutativeProjection',
      );
    });
  });

  // ===========================================================================
  // T303 — the secret boundary, at runtime.
  //
  // The AST judge proves the static direction: no `domain/` file can name a
  // data type, transitively. It cannot prove that the VALUES crossing the port
  // are clean, because that is a property of this implementation. These tests
  // are that half.
  // ===========================================================================
  group('T303 secret boundary at runtime', () {
    test(
      'nothing secret is reachable from the review the port returns',
      () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );

        final exposed = _renderDeeply(summary);
        for (final secret in <String>[
          _password,
          harness.databasePath,
          harness.keyFilePath,
          _sharedEntryUuid,
          _localOnlyEntryUuid,
          _childGroupUuid,
          _localUserName,
          _remoteUserName,
          _localOnlyFieldValue,
          _remoteOnlyFieldValue,
          _localOnlyFieldKey,
          _sharedAttachmentName,
          _remoteFileIdFixture,
        ]) {
          expect(
            exposed,
            isNot(contains(secret)),
            reason: '"$secret" is reachable through the port',
          );
        }
      },
    );

    test('no KDBX or data-layer object is reachable through props', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);

      for (final prop in _flatten(summary.props)) {
        final type = prop.runtimeType.toString();
        expect(
          type.startsWith('Kdbx') ||
              type.startsWith('_Merge') ||
              type == 'Credentials' ||
              type == 'ProtectedValue' ||
              type == 'Uint8List' ||
              type == 'File',
          isFalse,
          reason: '$type crossed the port',
        );
      }
    });

    test('a failure carries a code and nothing else', () async {
      final harness = await _Harness.build(temp);
      harness.secure.password = 'wrong-$_password';

      try {
        await harness.repository.startReview(harness.databaseId);
        fail('expected a SyncMergeFailure');
      } on SyncMergeFailure catch (failure) {
        expect(failure.code, MergeFailureCode.credentialsRevoked);
        final rendered = failure.toString();
        expect(rendered, isNot(contains(_password)));
        expect(rendered, isNot(contains(harness.databasePath)));
        expect(rendered, isNot(contains(harness.keyFilePath)));
      }
    });

    test(
      'loadFieldDisplay is the ONE plaintext channel, and it disposes',
      () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );
        // The engaged credential-block row (T401c), anchored on `password`:
        // its display shows the anchor member, per the row's own `category`.
        final conflict = summary.decisions.firstWhere(
          (d) => d.category == MergeFieldCategory.password,
        );

        final display = await harness.repository.loadFieldDisplay(
          sessionId: summary.sessionId,
          decisionId: conflict.decisionId,
        );

        expect(display.local.value, 'local-secret');
        expect(display.remote.value, 'remote-secret');
        // ...and it is not a channel to anywhere durable.
        expect(display.toString(), 'MergeFieldDisplay(<redacted>)');
        expect(display.local.toString(), 'MergeDisplaySide(<redacted>)');

        display.dispose();
        expect(() => display.label, throwsStateError);
        expect(() => display.local.value, throwsStateError);
      },
    );

    // =========================================================================
    // spec 023 T209 — the passkey namespace is ONE row, and its sides carry no
    // member value at all (FR-008).
    // =========================================================================
    test(
      'a conflicting passkey group is one decision, not one per field',
      () async {
        final withoutPasskey = await _Harness.build(temp);
        final baseline = await withoutPasskey.repository.startReview(
          withoutPasskey.databaseId,
        );
        final baselineConflicts = baseline.decisions
            .where((d) => d.kind == MergeDecisionKind.fieldConflict)
            .length;

        final harness = await _Harness.build(temp, withPasskey: true);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );
        final conflicts = summary.decisions
            .where((d) => d.kind == MergeDecisionKind.fieldConflict)
            .length;

        // Two members of the group conflict (credential id and private key), so
        // a per-field treatment would have added two rows.
        expect(conflicts, baselineConflicts + 1);
      },
    );

    test('the passkey row names the credential and shows no member', () async {
      final harness = await _Harness.build(temp, withPasskey: true);
      final summary = await harness.repository.startReview(harness.databaseId);

      // The type of a display is deliberately un-nameable outside the field
      // widget's allowlist, so the row is found and asserted in one pass
      // rather than held in a typed local.
      var found = false;
      for (final decision in summary.decisions) {
        if (decision.kind != MergeDecisionKind.fieldConflict) continue;
        final display = await harness.repository.loadFieldDisplay(
          sessionId: summary.sessionId,
          decisionId: decision.decisionId,
        );
        if (!display.label.startsWith('Passkey')) {
          display.dispose();
          continue;
        }
        found = true;
        expect(display.label, 'Passkey (webauthn.io)');
        expect(display.protected, isTrue);
        // Both sides hold the credential, so both are present — as the label,
        // never as a member value.
        expect(display.local.value, 'Passkey (webauthn.io)');
        expect(display.remote.value, 'Passkey (webauthn.io)');
        expect(
          display.local.value,
          isNot(contains('KEYVAULT-FIXTURE-PASSKEY')),
        );
        expect(display.remote.value, isNot(contains('cred-')));
        // The timestamps are what the choice is actually made on.
        expect(display.local.changedAt, isNotNull);
        expect(display.remote.changedAt, isNotNull);
        display.dispose();
      }

      expect(found, isTrue, reason: 'no passkey row was produced');
    });

    // The two sides wrote different credentials into the same group, so the
    // relying party itself conflicts: each side must name its own site, or
    // choosing remote would drop the local key without the row saying so.
    for (final suffix in const ['', '_1']) {
      test('each side of the passkey row names its own relying party '
          '(group "$suffix")', () async {
        final harness = await _Harness.build(
          temp,
          withPasskey: true,
          passkeySuffix: suffix,
          remotePasskeyRelyingParty: 'other.example',
        );
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );

        var found = false;
        for (final decision in summary.decisions) {
          if (decision.kind != MergeDecisionKind.fieldConflict) continue;
          final display = await harness.repository.loadFieldDisplay(
            sessionId: summary.sessionId,
            decisionId: decision.decisionId,
          );
          if (!display.label.startsWith('Passkey')) {
            display.dispose();
            continue;
          }
          found = true;
          expect(display.label, 'Passkey (webauthn.io)');
          expect(display.local.value, 'Passkey (webauthn.io)');
          expect(display.remote.value, 'Passkey (other.example)');
          display.dispose();
        }

        expect(found, isTrue, reason: 'no passkey row was produced');
      });
    }

    test('a protected value is flagged so the widget can mask it', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);
      final password = summary.decisions.firstWhere(
        (d) => d.category == MergeFieldCategory.password,
      );

      final display = await harness.repository.loadFieldDisplay(
        sessionId: summary.sessionId,
        decisionId: password.decisionId,
      );
      expect(display.protected, isTrue);
      display.dispose();
    });

    test(
      'an attachment display carries size and a fingerprint, never bytes',
      () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );
        final attachment = summary.decisions.firstWhere(
          (d) => d.category == MergeFieldCategory.attachment,
        );

        final display = await harness.repository.loadFieldDisplay(
          sessionId: summary.sessionId,
          decisionId: attachment.decisionId,
        );
        expect(display.local.sizeBytes, isNotNull);
        expect(display.local.fingerprint, hasLength(12));
        // The "value" of an attachment side is its NAME, not its content.
        expect(display.local.value, _sharedAttachmentName);
        display.dispose();
      },
    );

    test('the private session is dropped on cancel: plaintext is no longer '
        'reachable through the port', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);
      final conflict = summary.decisions.first;

      await harness.repository.cancel(summary.sessionId);

      await expectLater(
        harness.repository.loadFieldDisplay(
          sessionId: summary.sessionId,
          decisionId: conflict.decisionId,
        ),
        _failsWith(MergeFailureCode.sessionInvalidated),
      );
    });
  });

  // ===========================================================================
  // T308 — shortcuts and deletion.
  // ===========================================================================
  group('T308 shortcuts never choose a missing or deleted side', () {
    for (final shortcut in MergeShortcut.values) {
      test('$shortcut preserves every one-sided record and field', () async {
        final harness = await _Harness.build(temp);
        var summary = await harness.repository.startReview(harness.databaseId);
        summary = await harness.applyShortcut(summary, shortcut);

        final merged = await harness.reopenCandidate(summary.sessionId);

        // Record-level unions, both directions, under BOTH shortcuts.
        expect(_entry(merged, _localOnlyEntryUuid), isNotNull);
        expect(_entry(merged, _remoteOnlyEntryUuid), isNotNull);

        // Field-level unions inside the SAME entry uuid, both directions.
        final shared = _entry(merged, _sharedEntryUuid)!;
        expect(
          shared.getString(KdbxKey(_localOnlyFieldKey))?.getText(),
          _localOnlyFieldValue,
        );
        expect(
          shared.getString(KdbxKey(_remoteOnlyFieldKey))?.getText(),
          _remoteOnlyFieldValue,
        );
      });

      test('$shortcut chooses a present value for the real conflict, never '
          'null and never the missing side', () async {
        final harness = await _Harness.build(temp);
        var summary = await harness.repository.startReview(harness.databaseId);
        summary = await harness.applyShortcut(summary, shortcut);

        final merged = await harness.reopenCandidate(summary.sessionId);
        final shared = _entry(merged, _sharedEntryUuid)!;

        expect(
          shared.getString(KdbxKeyCommon.USER_NAME)?.getText(),
          shortcut == MergeShortcut.preferLocal
              ? _localUserName
              : _remoteUserName,
        );
      });

      test('$shortcut emits an explicit keep/delete on the deletion conflict, '
          'and never a side choice', () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );

        final commands = SyncMergePolicy.commandsFor(summary, shortcut);
        final deletion = summary.decisions.firstWhere(
          (d) => d.kind == MergeDecisionKind.recordDeletionConflict,
        );
        final answer = commands
            .firstWhere((c) => c.decisionId == deletion.decisionId)
            .choice;

        expect(answer, isIn(const [MergeChoice.keep, MergeChoice.delete]));
        // The record is live locally and tombstoned remotely, so preferring
        // the side that HOLDS it keeps it and preferring the side that deleted
        // it deletes it. Absence is never read as a delete.
        expect(
          answer,
          shortcut == MergeShortcut.preferLocal
              ? MergeChoice.keep
              : MergeChoice.delete,
        );
      });
    }

    test(
      'a shortcut cannot reach one-sided data at all: it iterates decisions, '
      'and one-sided rows are not decisions',
      () async {
        final harness = await _Harness.build(temp);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );

        for (final decision in summary.decisions) {
          if (decision.presence == MergePresence.presentBoth) continue;
          expect(
            decision.kind,
            isIn(const [
              MergeDecisionKind.fieldDeletionConflict,
              MergeDecisionKind.recordDeletionConflict,
            ]),
          );
        }
        expect(
          SyncMergePolicy.commandsFor(summary, MergeShortcut.preferLocal),
          hasLength(summary.decisions.length),
        );
      },
    );

    test('Keep resurrects nothing by ambiguity: the record survives and its '
        'tombstone stops matching on every device', () async {
      final harness = await _Harness.build(temp);
      var summary = await harness.repository.startReview(harness.databaseId);
      summary = await harness.applyShortcut(summary, MergeShortcut.preferLocal);

      final merged = await harness.reopenCandidate(summary.sessionId);
      final kept = _entry(merged, _deletedEntryUuid);

      expect(kept, isNotNull, reason: 'FR-5 Keep emits the live record');
      // T009b gap G2: dropping the tombstone alone lets a peer re-introduce it
      // forever. The live object is re-stamped at the deletion clock, so the
      // tombstone is non-matching everywhere, deterministically.
      expect(
        kept!.times.lastModificationTime.get(),
        harness.remoteDeletionTime,
      );
    });

    test(
      'Delete removes the live record and retains a valid tombstone',
      () async {
        final harness = await _Harness.build(temp);
        var summary = await harness.repository.startReview(harness.databaseId);
        summary = await harness.applyShortcut(
          summary,
          MergeShortcut.preferRemote,
        );

        final merged = await harness.reopenCandidate(summary.sessionId);

        expect(_entry(merged, _deletedEntryUuid), isNull);
        expect(
          // ignore: invalid_use_of_visible_for_testing_member
          merged.body.deletedObjects.map((o) => o.uuid.uuid),
          contains(_deletedEntryUuid),
          reason:
              'FR-5 Delete retains the tombstone, or the peer resurrects it',
        );
      },
    );

    test('a missing side is never a deletion: an ordinary one-sided record '
        'produces NO decision at all', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);

      // The local-only and remote-only entries carry no tombstone, so FR-4
      // makes them automatic unions. If absence were read as evidence they
      // would appear here as deletion conflicts.
      expect(
        summary.decisions.where(
          (d) => d.kind == MergeDecisionKind.recordDeletionConflict,
        ),
        hasLength(1),
      );
      expect(summary.localOnlyRecordCount, 1);
      expect(summary.remoteOnlyRecordCount, 1);
    });
  });

  // ===========================================================================
  // T309 — candidate reopen with password and with password + key file.
  // ===========================================================================
  group('T309 candidate reopen', () {
    for (final withKeyFile in const [false, true]) {
      final label = withKeyFile ? 'password + key file' : 'password only';

      test('the candidate reopens with $label and its manifest matches', () async {
        final harness = await _Harness.build(temp, withKeyFile: withKeyFile);
        var summary = await harness.repository.startReview(harness.databaseId);
        summary = await harness.applyShortcut(
          summary,
          MergeShortcut.preferLocal,
        );

        // `buildCandidateBytes` refuses with `serializationParityFailed`
        // unless the candidate reopens with the ORIGINAL credentials and its
        // canonical semantic manifest survives the round trip. Reaching the
        // next line is that assertion.
        final bytes = await harness.repository.buildCandidateBytes(
          summary.sessionId,
        );

        // Reopened again here with credentials this test composed
        // independently, so the internal check cannot have passed against some
        // other credential object.
        final reopened = await KdbxFormat().read(
          bytes,
          await harness.buildCredentials(),
        );
        final manifest = kdbxSemanticManifest(reopened);

        expect(reopened.body.rootGroup.uuid, harness.rootUuid);
        // Substantive, not an empty structure that would compare equal to
        // anything: the union carries at least the shared entry, both
        // one-sided entries and the kept record.
        expect(manifest['entries'], hasLength(greaterThanOrEqualTo(4)));
        expect(
          kdbxManifestDigest(manifest),
          kdbxManifestDigest(
            kdbxSemanticManifest(
              await KdbxFormat().read(bytes, await harness.buildCredentials()),
            ),
          ),
          reason: 'the manifest must be a function of the content alone',
        );
      });

      test(
        'unrelated metadata, history, icons and settings survive with $label',
        () async {
          final harness = await _Harness.build(temp, withKeyFile: withKeyFile);
          var summary = await harness.repository.startReview(
            harness.databaseId,
          );
          summary = await harness.applyShortcut(
            summary,
            MergeShortcut.preferLocal,
          );

          final merged = await harness.reopenCandidate(summary.sessionId);

          expect(
            merged.body.meta.databaseDescription.get(),
            _databaseDescription,
          );
          expect(merged.body.meta.historyMaxItems.get(), 7);
          expect(merged.body.meta.customIcons, isNotEmpty);
          expect(merged.body.rootGroup.uuid, harness.rootUuid);

          final shared = _entry(merged, _sharedEntryUuid)!;
          expect(
            shared.history.map(
              (h) => h.getString(KdbxKeyCommon.USER_NAME)?.getText(),
            ),
            contains(_historyUserName),
          );
          expect(
            shared.getBinary(KdbxKey(_sharedAttachmentName))?.value,
            isNotEmpty,
          );
          expect(_group(merged, _childGroupUuid), isNotNull);
        },
      );
    }

    test('a candidate whose credentials no longer open it is a parity failure, '
        'never a silent success', () async {
      final harness = await _Harness.build(temp);
      final summary = await harness.repository.startReview(harness.databaseId);
      final bytes = await harness.repository.buildCandidateBytes(
        summary.sessionId,
      );

      await expectLater(
        KdbxFormat().read(
          bytes,
          Credentials(ProtectedValue.fromString('not-$_password')),
        ),
        throwsA(isA<KdbxInvalidKeyException>()),
      );
    });

    // A key-file-only vault has NO password factor. The keystore holds no
    // secret for it (null) or, at most, an empty one; either way the merge
    // must compose the key file alone, never `'' + key file`, which is a
    // different composite that KeePassXC would not open.
    for (final storedSecret in const <String?>[null, '']) {
      test(
        'a key-file-only vault merges, commits and reopens with the key '
        'file alone (stored secret: ${storedSecret == null ? 'none' : 'empty'})',
        () async {
          final harness = await _Harness.build(temp, keyFileOnly: true);
          harness.secure.password = storedSecret;

          var summary = await harness.repository.startReview(
            harness.databaseId,
          );
          summary = await harness.applyShortcut(
            summary,
            MergeShortcut.preferLocal,
          );
          final outcome = await harness.repository.commit(summary.sessionId);

          expect(outcome, isA<MergeApplied>());
          final onDisk = await File(harness.databasePath).readAsBytes();
          final reopened = await KdbxFormat().read(
            onDisk,
            Credentials.composite(null, harness.keyFileBytes),
          );
          expect(reopened.body.rootGroup.uuid, harness.rootUuid);
          await expectLater(
            KdbxFormat().read(
              onDisk,
              Credentials.composite(
                ProtectedValue.fromString(''),
                harness.keyFileBytes,
              ),
            ),
            throwsA(isA<KdbxInvalidKeyException>()),
          );
        },
      );
    }

    test('a password + key file vault with no stored password is still '
        'revoked, not opened with the key file alone', () async {
      final harness = await _Harness.build(temp, withKeyFile: true);
      harness.secure.password = null;

      await expectLater(
        harness.repository.startReview(harness.databaseId),
        _failsWith(MergeFailureCode.credentialsRevoked),
      );
    });
  });

  // =========================================================================
  // Gate 4 — T403 atomic commit composition, T407-T410 restart recovery,
  // T411 upload-failure reopen, T412 capability parity.
  // =========================================================================
  group('Gate 4', () {
    late Directory g4Temp;
    setUp(() async {
      g4Temp = await Directory.systemTemp.createTemp('sync-merge-gate4-');
    });
    tearDown(() async {
      if (g4Temp.existsSync()) await g4Temp.delete(recursive: true);
    });

    group('T403 atomic commit', () {
      test('SC-15d: a backup failure aborts before any remote write and '
          'leaves the local file, the pending record and the mapping '
          'untouched', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _Harness.build(
          g4Temp,
          fixture: fixture,
          safeWriter: _BackupRefusingWriter(),
        );
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );

        final outcome = await harness.repository.commit(summary.sessionId);

        expect(
          outcome,
          isA<MergeRejected>()
              .having((r) => r.code, 'code', MergeFailureCode.backupFailed)
              .having((r) => r.localCommitCompleted, 'local', isFalse),
        );
        expect(harness.drive.updateCalls, isEmpty);
        expect(harness.syncMetadata.pendingUploadCalls, isEmpty);
        expect(harness.syncMetadata.upsertCalls, isEmpty);
        expect(
          await File(harness.databasePath).readAsBytes(),
          fixture.localBytes,
        );
      });

      test('the dated backup holds the pre-merge bytes, the local file holds '
          'the candidate, and the mapping is finalized exactly once, after '
          'the read-back, with the committed checksums', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _Harness.build(g4Temp, fixture: fixture);
        final summary = await harness.repository.startReview(
          harness.databaseId,
        );

        final outcome = await harness.repository.commit(summary.sessionId);

        expect(outcome, isA<MergeApplied>());
        final record = harness.syncMetadata.pendingUploadCalls.first;
        final backup = File(record.backupPath!);
        expect(await backup.exists(), isTrue);
        expect(await backup.readAsBytes(), fixture.localBytes);
        final local = await File(harness.databasePath).readAsBytes();
        expect(md5.convert(local).toString(), record.localCommittedChecksum);
        final mapping = harness.syncMetadata.upsertCalls.single;
        expect(mapping.lastSyncedLocalChecksum, record.localCommittedChecksum);
        expect(mapping.lastSyncedRemoteChecksum, harness.remote.checksum());
      });
    });

    group('T407-T410 restart recovery', () {
      test('no pending record answers none and touches nothing', () async {
        final harness = await _Harness.build(
          g4Temp,
          fixture: await _t401Fixture(g4Temp),
        );
        final restarted = harness.restart();

        final outcome = await restarted.recoverPending(harness.databaseId);

        expect(outcome.disposition, MergeRecoveryDisposition.none);
        expect(harness.drive.getMetadataCalls, 0);
        expect(harness.drive.updateCalls, isEmpty);
      });

      test('T407 a local file that moved after the commit is '
          'staleRecoveryLocal: zero remote calls, no mutation, record and '
          'backup retained', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(g4Temp, fixture);
        // Something else wrote the database between the crash and this
        // restart: the committed bytes are gone.
        await File(harness.databasePath).writeAsBytes(fixture.localBytes);
        final metadataCallsBefore = harness.drive.getMetadataCalls;
        final uploadsBefore = harness.drive.updateCalls.length;
        final recordBefore = await harness.syncMetadata.getPendingUpload(
          harness.databasePath,
        );

        final outcome = await harness.restart().recoverPending(
          harness.databaseId,
        );

        expect(
          outcome.disposition,
          MergeRecoveryDisposition.staleRecoveryLocal,
        );
        expect(harness.drive.getMetadataCalls, metadataCallsBefore);
        expect(harness.drive.updateCalls.length, uploadsBefore);
        expect(harness.syncMetadata.upsertCalls, isEmpty);
        expect(
          await File(harness.databasePath).readAsBytes(),
          fixture.localBytes,
        );
        final recordAfter = await harness.syncMetadata.getPendingUpload(
          harness.databasePath,
        );
        expect(recordAfter, recordBefore);
        expect(await File(recordAfter!.backupPath!).exists(), isTrue);
      });

      test('T408 timeout-applied: the remote already holds the merge, so '
          'recovery finalizes without a second upload', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(
          g4Temp,
          fixture,
          applyRemote: (remote, uploaded) => remote.content = uploaded,
        );
        final uploadsBefore = harness.drive.updateCalls.length;

        final outcome = await harness.restart().recoverPending(
          harness.databaseId,
        );

        expect(outcome.disposition, MergeRecoveryDisposition.finalizedApplied);
        expect(harness.drive.updateCalls.length, uploadsBefore);
        final record = harness.syncMetadata.pendingUploadCalls.first;
        final mapping = harness.syncMetadata.upsertCalls.single;
        expect(mapping.lastSyncedRemoteChecksum, record.mergedChecksum);
        expect(mapping.lastSyncedLocalChecksum, record.localCommittedChecksum);
        expect(
          await harness.syncMetadata.getPendingUpload(harness.databasePath),
          isNull,
        );
        // Recovery is idempotent once finalized: nothing is left to triage.
        final again = await harness.restart().recoverPending(
          harness.databaseId,
        );
        expect(again.disposition, MergeRecoveryDisposition.none);
      });

      test('T408 timeout-not-applied: the remote still holds the expected '
          'old content, so recovery re-puts the committed local bytes and '
          'finalizes on the verified read-back', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(g4Temp, fixture);
        final uploadsBefore = harness.drive.updateCalls.length;
        final localBytes = await File(harness.databasePath).readAsBytes();

        final outcome = await harness.restart().recoverPending(
          harness.databaseId,
        );

        expect(
          outcome.disposition,
          MergeRecoveryDisposition.retriedAndFinalized,
        );
        expect(harness.drive.updateCalls.length, uploadsBefore + 1);
        expect(harness.drive.updateCalls.last, localBytes);
        expect(harness.remote.content, localBytes);
        final mapping = harness.syncMetadata.upsertCalls.single;
        expect(mapping.lastSyncedRemoteChecksum, harness.remote.checksum());
        expect(
          await harness.syncMetadata.getPendingUpload(harness.databasePath),
          isNull,
        );
      });

      test('T408 timeout-third-state: the remote changed independently, so '
          'recovery hands off to a new conflict — no upload, local merge and '
          'backup retained, mapping untouched', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(
          g4Temp,
          fixture,
          // A third device landed something that is neither the old remote
          // nor our merge.
          applyRemote: (remote, _) => remote.content = fixture.localBytes,
        );
        final uploadsBefore = harness.drive.updateCalls.length;
        final mergedLocal = await File(harness.databasePath).readAsBytes();
        final record = (await harness.syncMetadata.getPendingUpload(
          harness.databasePath,
        ))!;

        final outcome = await harness.restart().recoverPending(
          harness.databaseId,
        );

        expect(outcome.disposition, MergeRecoveryDisposition.needsNewConflict);
        expect(harness.drive.updateCalls.length, uploadsBefore);
        expect(harness.syncMetadata.upsertCalls, isEmpty);
        expect(await File(harness.databasePath).readAsBytes(), mergedLocal);
        expect(await File(record.backupPath!).exists(), isTrue);
        // The handoff IS the resolution of this record.
        expect(
          await harness.syncMetadata.getPendingUpload(harness.databasePath),
          isNull,
        );
      });

      test('T410 retry timeout: the recovery re-put itself times out, so the '
          'record stays ambiguous and nothing is finalized', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(g4Temp, fixture);
        harness.remote.updateFileError = Exception('timeout again');

        final outcome = await harness.restart().recoverPending(
          harness.databaseId,
        );

        expect(outcome.disposition, MergeRecoveryDisposition.stillAmbiguous);
        expect(harness.syncMetadata.upsertCalls, isEmpty);
        final record = await harness.syncMetadata.getPendingUpload(
          harness.databasePath,
        );
        expect(record, isNotNull);
        expect(record!.outcomeAmbiguous, isTrue);
      });

      test('T410 a recovery re-put whose read-back returns no checksum is '
          'ambiguous, not finalized', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(g4Temp, fixture);
        harness.remote.suppressChecksumOnUpdate = true;

        final outcome = await harness.restart().recoverPending(
          harness.databaseId,
        );

        expect(outcome.disposition, MergeRecoveryDisposition.stillAmbiguous);
        expect(harness.syncMetadata.upsertCalls, isEmpty);
        expect(
          await harness.syncMetadata.getPendingUpload(harness.databasePath),
          isNotNull,
        );
      });

      test('T410 a recovery re-put that races into a third state hands off '
          'instead of claiming synced', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(g4Temp, fixture);
        harness.remote.onUpload = (_) async => fixture.localBytes;

        final outcome = await harness.restart().recoverPending(
          harness.databaseId,
        );

        expect(outcome.disposition, MergeRecoveryDisposition.needsNewConflict);
        expect(harness.syncMetadata.upsertCalls, isEmpty);
      });

      test('a metadata fetch failure during recovery stays ambiguous and '
          'uploads nothing', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(g4Temp, fixture);
        harness.remote.getMetadataError = Exception('offline');
        final uploadsBefore = harness.drive.updateCalls.length;

        final outcome = await harness.restart().recoverPending(
          harness.databaseId,
        );

        expect(outcome.disposition, MergeRecoveryDisposition.stillAmbiguous);
        expect(harness.drive.updateCalls.length, uploadsBefore);
        expect(harness.syncMetadata.upsertCalls, isEmpty);
      });

      test('the local guard runs under the database mutex: a held lock '
          'blocks recovery until released', () async {
        final fixture = await _t401Fixture(g4Temp);
        final harness = await _ambiguousCommit(g4Temp, fixture);
        final release = Completer<void>();
        final acquired = Completer<void>();
        final held = harness.mutex.withDatabaseLock([harness.databasePath], () {
          acquired.complete();
          return release.future;
        });
        await acquired.future;

        var recovered = false;
        final recovery = harness
            .restart()
            .recoverPending(harness.databaseId)
            .then((o) {
              recovered = true;
              return o;
            });
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(recovered, isFalse);

        release.complete();
        await held;
        final outcome = await recovery;
        expect(
          outcome.disposition,
          MergeRecoveryDisposition.retriedAndFinalized,
        );
      });
    });

    group('T509 serialization', () {
      test('commit, restart recovery and an external writer on the same '
          'database never overlap inside the shared mutex', () async {
        final fixture = await _t401Fixture(g4Temp);
        final mutex = _DepthMutex();
        final harness = await _ambiguousCommit(g4Temp, fixture);
        final restarted = SyncMergeRepositoryImpl(
          registryRepository: harness.registry,
          securityRepository: harness.security,
          syncRepository: harness.sync,
          secureDataSource: harness.secure,
          mutex: mutex,
          driveApiService: harness.drive,
          syncMetadataDataSource: harness.syncMetadata,
        );

        // Three writers race for the same path through the same mutex.
        final review = restarted.startReview(harness.databaseId);
        final external = mutex.withDatabaseLock(
          [harness.databasePath],
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return 'external';
          },
        );
        final recovery = restarted.recoverPending(harness.databaseId);
        await Future.wait([external, recovery]);
        final summary = await review;
        await restarted.commit(summary.sessionId);

        expect(mutex.maxDepth, 1);
        expect(mutex.entries, greaterThanOrEqualTo(3));
        // (The local-check-before-remote-call order is asserted by the T407
        // test above: zero metadata calls on a stale local.)
      });
    });

    group('T411 upload-failure reopen', () {
      for (final withKeyFile in [false, true]) {
        test('after an upload failure the local merged file and the dated '
            'backup remain and reopen with password'
            '${withKeyFile ? ' + key file' : ''}', () async {
          final harness = await _Harness.build(
            g4Temp,
            withKeyFile: withKeyFile,
          );
          final summary = await harness.repository.startReview(
            harness.databaseId,
          );
          await harness.applyShortcut(summary, MergeShortcut.preferLocal);
          harness.remote.updateFileError = Exception('network boom');

          final outcome = await harness.repository.commit(summary.sessionId);

          expect(
            outcome,
            isA<MergeRejected>()
                .having(
                  (r) => r.code,
                  'code',
                  MergeFailureCode.uploadOutcomeAmbiguous,
                )
                .having((r) => r.localCommitCompleted, 'local', isTrue),
          );
          expect(harness.syncMetadata.upsertCalls, isEmpty);
          final credentials = await harness.buildCredentials();
          final merged = await KdbxFormat().read(
            await File(harness.databasePath).readAsBytes(),
            credentials,
          );
          // Prefer local + all one-sided data: the local-only record survives.
          expect(_entry(merged, _localOnlyEntryUuid), isNotNull);
          expect(_entry(merged, _remoteOnlyEntryUuid), isNotNull);
          final record = harness.syncMetadata.pendingUploadCalls.first;
          final backup = await KdbxFormat().read(
            await File(record.backupPath!).readAsBytes(),
            credentials,
          );
          expect(_entry(backup, _remoteOnlyEntryUuid), isNull);
        });
      }
    });

    group('T412 capability parity', () {
      // Three "adapters" that differ only in what they COULD offer. The
      // repository must not notice: same decisions, same outcome, same calls.
      final adapters =
          <String, _FakeGoogleDriveApiService Function(_FakeRemoteDrive)>{
            'bare get/put': _FakeGoogleDriveApiService.new,
            'versionHistory': _VersionHistoryFakeDrive.new,
            'conditionalWrite': _ConditionalWriteFakeDrive.new,
          };

      test('identical decisions and commit outcome across all three '
          'adapter tiers', () async {
        final decisionsByTier = <String, List<Object?>>{};
        final outcomesByTier = <String, MergeCommitOutcome>{};
        for (final entry in adapters.entries) {
          final harness = await _Harness.build(
            g4Temp,
            driveFactory: entry.value,
            // Fixed equal mtimes: otherwise the two sides are stamped with
            // DateTime.now() (second resolution in KDBX), so a tier built
            // across a second boundary gets remoteNewer while the others tie.
            tiedTimestamps: true,
          );
          final summary = await harness.repository.startReview(
            harness.databaseId,
          );
          final ready = await harness.applyShortcut(
            summary,
            MergeShortcut.preferLocal,
          );
          decisionsByTier[entry.key] = ready.decisions
              .map(
                (d) => [
                  d.ordinal,
                  d.kind,
                  d.category,
                  d.presence,
                  d.choice,
                  d.isDefault,
                  d.timestampRelation,
                ],
              )
              .toList();
          outcomesByTier[entry.key] = await harness.repository.commit(
            summary.sessionId,
          );
          expect(harness.drive.updateCalls, hasLength(1), reason: entry.key);
        }
        final reference = decisionsByTier['bare get/put'];
        for (final tier in adapters.keys) {
          expect(decisionsByTier[tier], reference, reason: tier);
          expect(outcomesByTier[tier], isA<MergeApplied>(), reason: tier);
          expect(outcomesByTier[tier], outcomesByTier['bare get/put']);
        }
      });

      test('no domain or presentation source branches on a capability', () {
        final roots = [
          'lib/features/password_manager/domain',
          'lib/features/password_manager/presentation',
        ];
        final offenders = <String>[];
        for (final root in roots) {
          final dir = Directory(root);
          if (!dir.existsSync()) continue;
          for (final file in dir.listSync(recursive: true).whereType<File>()) {
            if (!file.path.endsWith('.dart')) continue;
            final code = file
                .readAsLinesSync()
                .where((l) => !l.trimLeft().startsWith('//'))
                .join('\n');
            if (RegExp(r'\b(conditionalWrite|versionHistory|hasCapability)\b')
                .hasMatch(code)) {
              offenders.add(file.path);
            }
          }
        }
        expect(offenders, isEmpty);
      });
    });
  });
}

// ===========================================================================
// Harness
// ===========================================================================

const _implPath =
    'lib/features/password_manager/data/repositories/'
    'sync_merge_repository_impl.dart';

Matcher _failsWith(MergeFailureCode code) =>
    throwsA(isA<SyncMergeFailure>().having((f) => f.code, 'code', code));

/// Source of a top-level function's body, located on the AST rather than by
/// bracket counting.
String _topLevelFunctionBody(String source, String name) {
  final unit = parseString(content: source, path: _implPath).unit;
  final function = unit.declarations
      .whereType<FunctionDeclaration>()
      .singleWhere(
        (declaration) => declaration.name.lexeme == name,
        orElse: () => throw StateError('no top-level function "$name"'),
      );
  return function.functionExpression.body.toSource();
}

/// Statements directly inside the first top-level `try` block of a method.
///
/// "Directly" is the point: a statement nested in an `if`, a loop or an
/// `assert` is not returned, so a guard hidden in a branch cannot pass for an
/// unconditional one.
List<Statement> _tryBlockStatements(
  String source,
  String className,
  String name,
) {
  final unit = parseString(content: source, path: _implPath).unit;
  final type = unit.declarations.whereType<ClassDeclaration>().singleWhere(
    (declaration) => declaration.namePart.typeName.lexeme == className,
  );
  final method = type.body.members.whereType<MethodDeclaration>().singleWhere(
    (member) => member.name.lexeme == name,
  );
  final block = (method.body as BlockFunctionBody).block;
  final tryStatement = block.statements.whereType<TryStatement>().single;
  return tryStatement.body.statements.toList();
}

/// Source of one method of [className], likewise from the AST.
String _methodBody(String source, String className, String name) {
  final unit = parseString(content: source, path: _implPath).unit;
  final type = unit.declarations.whereType<ClassDeclaration>().singleWhere(
    (declaration) => declaration.namePart.typeName.lexeme == className,
  );
  final method = type.body.members.whereType<MethodDeclaration>().singleWhere(
    (member) => member.name.lexeme == name,
  );
  return method.body.toSource();
}

Future<int> _decisionCount(_Harness harness) async {
  final summary = await harness.repository.startReview(harness.databaseId);
  await harness.repository.cancel(summary.sessionId);
  return summary.decisions.length;
}

/// [manifest] projected onto the dimensions the merge is expected to make
/// commutative today.
///
/// **Exactly two things are removed, and each is pinned by its own assertion**
/// in "the two dimensions that are NOT commutative yet" — so this is a
/// declared scope, not a quiet "ignore what differs". Everything else —
/// parentage, times, strings, binaries, tombstones, metadata, header, KDF — is
/// compared verbatim.
///
/// 1. **sibling order**: each device appends what it imports to the end of the
///    target group, so the two candidates hold the same children in a
///    different sequence;
/// 2. **entry history**: KDBX history is a per-replica edit log and the merge
///    preserves it (FR-1) rather than merging it, so each device keeps the
///    revisions of its own edits and neither has the other's.
Map<String, Object?> _commutativeProjection(Map<String, Object?> manifest) {
  final groups = <String, Object?>{};
  (manifest['groups']! as Map<String, Object?>).forEach((uuid, value) {
    final group = Map<String, Object?>.from(value! as Map<String, Object?>);
    for (final key in const ['groupOrder', 'entryOrder']) {
      group[key] = (group[key]! as List).map((e) => e as String).toList()
        ..sort();
    }
    groups[uuid] = group;
  });

  final entries = <String, Object?>{};
  (manifest['entries']! as Map<String, Object?>).forEach((uuid, value) {
    entries[uuid] = {
      ...value! as Map<String, Object?>,
      'history': const <Object?>[],
    };
  });

  return {...manifest, 'groups': groups, 'entries': entries};
}

/// Every path at which two manifests disagree, so a failure names the field
/// instead of two digests.
List<String> _manifestDifferences(Object? a, Object? b, [String path = '']) {
  if (a is Map && b is Map) {
    return [
      for (final key in {...a.keys, ...b.keys})
        ..._manifestDifferences(a[key], b[key], '$path/$key'),
    ];
  }
  if (a is List && b is List && a.length == b.length) {
    return [
      for (var i = 0; i < a.length; i++)
        ..._manifestDifferences(a[i], b[i], '$path[$i]'),
    ];
  }
  if (jsonEncode(a) == jsonEncode(b)) return const [];
  return ['$path: ${jsonEncode(a)} != ${jsonEncode(b)}'];
}

KdbxEntry? _entry(KdbxFile file, String uuid) {
  for (final entry in file.body.rootGroup.getAllEntries()) {
    if (entry.uuid.uuid == uuid) return entry;
  }
  return null;
}

/// spec-008 T401 — a small, dedicated local/remote pair: one entry, one
/// ordinary (non-credential-block) field conflict on `Notes`, plus a field
/// present ONLY on local (`Custom_New`) so a later remote-side addition of
/// the same key is a genuinely NEW conflict rather than a pre-existing one.
Future<_FixturePair> _t401Fixture(Directory temp) async {
  const entryUuid = 'FFFFFFFFFFFFFFFFFFFFAQ==';
  final credentials = Credentials(ProtectedValue.fromString(_password));
  final base = KdbxFormat().create(
    credentials,
    'T401 Fixture',
    generator: 'spec-008-t401',
  );
  base.body.meta.databaseDescription.set('base-description');
  final entry = KdbxEntry.create(base, base.body.rootGroup)
    ..forceSetUuid(KdbxUuid(entryUuid));
  base.body.rootGroup.addEntry(entry);
  entry
    ..setString(KdbxKeyCommon.TITLE, PlainValue('Shared'))
    ..setString(KdbxKey('Notes'), PlainValue('base-notes'));
  final baseBytes = Uint8List.fromList(await base.save());

  final localFile = await KdbxFormat().read(baseBytes, credentials);
  _entry(localFile, entryUuid)!
    ..setString(KdbxKey('Notes'), PlainValue('local-notes'))
    ..setString(KdbxKey('Custom_New'), PlainValue('local-new-value'))
    ..times.lastModificationTime.set(DateTime.utc(2024, 1, 1));
  final localBytes = Uint8List.fromList(await localFile.save());

  final remoteFile = await KdbxFormat().read(baseBytes, credentials);
  _entry(remoteFile, entryUuid)!
    ..setString(KdbxKey('Notes'), PlainValue('remote-notes-v1'))
    ..times.lastModificationTime.set(DateTime.utc(2024, 6, 1));
  final remoteBytes = Uint8List.fromList(await remoteFile.save());

  return _FixturePair(
    keyFilePath: '${temp.path}/unused.keyx',
    keyFileBytes: null,
    credentials: credentials,
    localBytes: localBytes,
    remoteBytes: remoteBytes,
    rootUuid: localFile.body.rootGroup.uuid,
    deletionTime: DateTime.utc(2020),
  );
}

/// Re-opens [bytes], sets the database description (and its change clock,
/// so `_mergeMeta`'s FR-3 comparator actually adopts it) and re-saves —
/// content-different bytes with a controlled, single-field delta.
Future<Uint8List> _withDescription(
  Uint8List bytes,
  Credentials credentials,
  String description,
  DateTime changedAt,
) async {
  final file = await KdbxFormat().read(bytes, credentials);
  file.body.meta
    ..databaseDescription.set(description)
    ..databaseDescriptionChanged.set(changedAt);
  return Uint8List.fromList(await file.save());
}

/// Re-opens and re-saves [bytes] unchanged: same semantic content, different
/// raw bytes (fresh salts/IVs/master seed on every KDBX save).
Future<Uint8List> _resave(Uint8List bytes, Credentials credentials) async {
  final file = await KdbxFormat().read(bytes, credentials);
  return Uint8List.fromList(await file.save());
}

KdbxGroup? _group(KdbxFile file, String uuid) {
  for (final group in file.body.rootGroup.getAllGroups()) {
    if (group.uuid.uuid == uuid) return group;
  }
  return null;
}

/// Everything a value exposes to a log line, an error report or a serializer:
/// `toString`, and every `props` element, recursively.
String _renderDeeply(Object? value) {
  final buffer = StringBuffer(value.toString());
  for (final child in _flatten(
    value is MergeReviewSummary ? value.props : [],
  )) {
    buffer.write('|${child.toString()}');
  }
  return buffer.toString();
}

Iterable<Object?> _flatten(Iterable<Object?> values) sync* {
  for (final value in values) {
    yield value;
    if (value is Iterable) yield* _flatten(value);
    if (value is RedactedMergeDecision) yield* _flatten(value.props);
  }
}

int _fixtureSequence = 0;

/// The two diverged sides plus everything needed to open them.
class _FixturePair {
  _FixturePair({
    required this.keyFilePath,
    required this.keyFileBytes,
    required this.credentials,
    required this.localBytes,
    required this.remoteBytes,
    required this.rootUuid,
    required this.deletionTime,
  });

  final String keyFilePath;
  final Uint8List? keyFileBytes;
  final Credentials credentials;
  final Uint8List localBytes;
  final Uint8List remoteBytes;
  final KdbxUuid rootUuid;
  final DateTime deletionTime;
}

class _Harness {
  _Harness({
    required this.repository,
    required this.databaseId,
    required this.databasePath,
    required this.keyFilePath,
    required this.keyFileBytes,
    required this.localBytes,
    required this.rootUuid,
    required this.remoteDeletionTime,
    required this.sync,
    required this.secure,
    required this.remote,
    required this.drive,
    required this.syncMetadata,
    required this.mutex,
    required this.registry,
    required this.security,
    this.keyFileOnly = false,
  });

  final SyncMergeRepositoryImpl repository;
  final DatabasePathMutex mutex;
  final _FakeRegistryRepository registry;
  final _FakeSecurityRepository security;

  /// A process restart: a brand-new repository with no in-memory session,
  /// over the same persisted state (files, mapping, pending record).
  SyncMergeRepositoryImpl restart() => SyncMergeRepositoryImpl(
    registryRepository: registry,
    securityRepository: security,
    syncRepository: sync,
    secureDataSource: secure,
    mutex: mutex,
    driveApiService: drive,
    syncMetadataDataSource: syncMetadata,
  );
  final MergeDatabaseId databaseId;
  final String databasePath;
  final String keyFilePath;
  final Uint8List? keyFileBytes;
  final Uint8List localBytes;
  final KdbxUuid rootUuid;
  final DateTime remoteDeletionTime;
  final _FakeSyncRepository sync;
  final _FakeSecureDataSource secure;

  /// spec-008 T401 — the write-verify-converge cycle's dependencies.
  final _FakeRemoteDrive remote;
  final _FakeGoogleDriveApiService drive;
  final _FakeSyncMetadataDataSource syncMetadata;

  /// A key-file-only vault: no password factor at all, exactly what KeePassXC
  /// writes when the password box is left empty.
  final bool keyFileOnly;

  Future<Credentials> buildCredentials() async => Credentials.composite(
    keyFileOnly ? null : ProtectedValue.fromString(_password),
    keyFileBytes,
  );

  Future<MergeReviewSummary> applyShortcut(
    MergeReviewSummary summary,
    MergeShortcut shortcut,
  ) async {
    var current = summary;
    for (final command in SyncMergePolicy.commandsFor(summary, shortcut)) {
      current = await repository.updateDecision(
        sessionId: summary.sessionId,
        decisionId: command.decisionId,
        choice: command.choice,
      );
    }
    return current;
  }

  Future<KdbxFile> reopenCandidate(MergeSessionId sessionId) async {
    final bytes = await repository.buildCandidateBytes(sessionId);
    return KdbxFormat().read(bytes, await buildCredentials());
  }

  /// One diverged pair, built once.
  ///
  /// Extracted so the commutativity test can hand the SAME two sides to two
  /// harnesses with `mirrored` flipped. Building the pair twice would compare
  /// two different databases — different root UUIDs, different custom-icon
  /// UUIDs, different creation times — and the test would fail for reasons
  /// that have nothing to do with the merge.
  static Future<_FixturePair> pair(
    Directory temp, {
    bool withKeyFile = false,
    bool keyFileOnly = false,
    bool foreignRemote = false,
    bool tiedTimestamps = false,
    bool withPasskey = false,
    String passkeySuffix = '',
    String remotePasskeyRelyingParty = 'webauthn.io',
  }) async {
    Uint8List? keyFileBytes;
    final keyFilePath = '${temp.path}/fixture-key-file.keyx';
    if (withKeyFile || keyFileOnly) {
      keyFileBytes = Uint8List.fromList(
        utf8.encode('fixture-key-file-material-not-a-real-key'),
      );
      await File(keyFilePath).writeAsBytes(keyFileBytes);
    }
    final credentials = Credentials.composite(
      keyFileOnly ? null : ProtectedValue.fromString(_password),
      keyFileBytes,
    );

    // A history revision only appears on the first modification after a CLEAN
    // read: `Changeable.modify` snapshots into `history` when the object is
    // not already dirty, and an object is dirty from the moment it is created.
    // So the seed is saved, reopened, and only then edited — which is also how
    // a real vault accumulates history.
    final seeded = await KdbxFormat().read(
      Uint8List.fromList(await _buildBase(credentials).save()),
      credentials,
    );
    _entry(
      seeded,
      _sharedEntryUuid,
    )!.setString(KdbxKeyCommon.USER_NAME, PlainValue('alice-base'));
    final baseBytes = Uint8List.fromList(await seeded.save());

    final localFile = await KdbxFormat().read(baseBytes, credentials);
    final remoteFile = foreignRemote
        ? _buildBase(credentials)
        : await KdbxFormat().read(baseBytes, credentials);

    var deletionTime = DateTime.utc(2020);
    if (!foreignRemote) {
      _divergeLocal(localFile, tiedTimestamps: tiedTimestamps);
      deletionTime = _divergeRemote(remoteFile, tiedTimestamps: tiedTimestamps);
      if (withPasskey) {
        _writePasskeyGroup(localFile, side: 'local', suffix: passkeySuffix);
        _writePasskeyGroup(
          remoteFile,
          side: 'remote',
          suffix: passkeySuffix,
          relyingParty: remotePasskeyRelyingParty,
        );
      }
    }

    return _FixturePair(
      keyFilePath: keyFilePath,
      keyFileBytes: keyFileBytes,
      credentials: credentials,
      localBytes: Uint8List.fromList(await localFile.save()),
      remoteBytes: Uint8List.fromList(await remoteFile.save()),
      rootUuid: localFile.body.rootGroup.uuid,
      deletionTime: deletionTime,
    );
  }

  static Future<_Harness> build(
    Directory temp, {
    bool withKeyFile = false,
    bool keyFileOnly = false,
    bool foreignRemote = false,
    bool tiedTimestamps = false,
    bool withPasskey = false,
    String passkeySuffix = '',
    String remotePasskeyRelyingParty = 'webauthn.io',
    bool mirrored = false,
    bool withoutRemoteMapping = false,
    _FixturePair? fixture,
    SafeVaultFileWriter? safeWriter,
    _FakeGoogleDriveApiService Function(_FakeRemoteDrive)? driveFactory,
  }) async {
    final built =
        fixture ??
        await pair(
          temp,
          withKeyFile: withKeyFile,
          keyFileOnly: keyFileOnly,
          foreignRemote: foreignRemote,
          tiedTimestamps: tiedTimestamps,
          withPasskey: withPasskey,
          passkeySuffix: passkeySuffix,
          remotePasskeyRelyingParty: remotePasskeyRelyingParty,
        );
    final keyFilePath = built.keyFilePath;
    final keyFileBytes = built.keyFileBytes;
    final deletionTime = built.deletionTime;

    final localBytes = mirrored ? built.remoteBytes : built.localBytes;
    final remoteBytes = mirrored ? built.localBytes : built.remoteBytes;

    final databasePath = '${temp.path}/fixture-${_fixtureSequence++}.kdbx';
    await File(databasePath).writeAsBytes(localBytes);

    final remote = _FakeRemoteDrive(remoteBytes);
    final sync = _FakeSyncRepository(
      mapping: withoutRemoteMapping
          ? null
          : DatabaseSyncMapping(
              databasePath: databasePath,
              providerId: 'google_drive',
              remoteFileId: _remoteFileIdFixture,
              remoteFileName: 'fixture.kdbx',
            ),
      remote: remote,
    );
    // A key-file-only vault has no secret to store: biometric enrolment skips
    // an empty session secret, so the keystore really holds nothing.
    final secure = _FakeSecureDataSource(keyFileOnly ? null : _password);
    final drive = (driveFactory ?? _FakeGoogleDriveApiService.new)(remote);
    final syncMetadata = _FakeSyncMetadataDataSource();
    final mutex = DatabasePathMutex();
    final registry = _FakeRegistryRepository(
      DatabaseRecord(
        databaseId: _databaseId,
        canonicalPath: databasePath,
        displayName: 'Fixture',
        sourceType: DatabaseSourceType.drive,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
    final security = _FakeSecurityRepository(
      withKeyFile || keyFileOnly
          ? DatabaseSecurityProfile(
              databaseId: _databaseId,
              keyFilePath: keyFilePath,
            )
          : null,
    );

    return _Harness(
      repository: SyncMergeRepositoryImpl(
        registryRepository: registry,
        securityRepository: security,
        syncRepository: sync,
        secureDataSource: secure,
        mutex: mutex,
        driveApiService: drive,
        syncMetadataDataSource: syncMetadata,
        safeWriter: safeWriter,
      ),
      databaseId: MergeDatabaseId(_databaseId),
      databasePath: databasePath,
      keyFilePath: keyFilePath,
      keyFileBytes: keyFileBytes,
      localBytes: localBytes,
      rootUuid: built.rootUuid,
      remoteDeletionTime: deletionTime,
      sync: sync,
      secure: secure,
      remote: remote,
      drive: drive,
      syncMetadata: syncMetadata,
      mutex: mutex,
      registry: registry,
      security: security,
      keyFileOnly: keyFileOnly,
    );
  }
}

/// The common ancestor both replicas are made from, so lineage matches without
/// any UUID surgery on the root.
KdbxFile _buildBase(Credentials credentials) {
  final file = KdbxFormat().create(
    credentials,
    'Merge Fixture',
    generator: 'spec-008-t302',
  );
  file.body.meta
    ..databaseDescription.set(_databaseDescription)
    ..historyMaxItems.set(7)
    ..addCustomIcon(
      KdbxCustomIcon(
        uuid: KdbxUuid.random(),
        data: Uint8List.fromList(const [1, 2, 3, 4]),
      ),
    );

  final child = file.createGroup(parent: file.body.rootGroup, name: 'Child')
    ..forceSetUuid(KdbxUuid(_childGroupUuid));

  final shared = KdbxEntry.create(file, child)
    ..forceSetUuid(KdbxUuid(_sharedEntryUuid));
  child.addEntry(shared);
  shared
    ..setString(KdbxKeyCommon.TITLE, PlainValue('Shared'))
    ..setString(KdbxKeyCommon.USER_NAME, PlainValue(_historyUserName))
    ..setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString('base-secret'),
    );
  shared.createBinary(
    isProtected: false,
    name: _sharedAttachmentName,
    bytes: Uint8List.fromList(const [9, 9, 9]),
  );

  // The record both sides start from and the remote later deletes.
  final doomed = KdbxEntry.create(file, child)
    ..forceSetUuid(KdbxUuid(_deletedEntryUuid));
  child.addEntry(doomed);
  doomed.setString(KdbxKeyCommon.TITLE, PlainValue('Doomed'));
  // Pinned in the past, and set LAST because every `setString` re-stamps the
  // modification time. A tombstone only "matches" when it is strictly newer
  // than this (T009b G1), so an mtime of "now" would make the fixture's
  // deletion evidence non-matching and the whole deletion group vacuous.
  doomed.times.lastModificationTime.set(DateTime.utc(2020));

  return file;
}

void _divergeLocal(KdbxFile file, {required bool tiedTimestamps}) {
  final shared = _entry(file, _sharedEntryUuid)!;
  shared
    ..setString(KdbxKeyCommon.USER_NAME, PlainValue(_localUserName))
    ..setString(KdbxKey(_localOnlyFieldKey), PlainValue(_localOnlyFieldValue))
    ..setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString('local-secret'),
    )
    // Same attachment name, different bytes: FR-4's equal-name/different-bytes
    // row, and the only way a conflicting ATTACHMENT decision exists to test
    // the display's size/fingerprint against.
    ..removeBinary(KdbxKey(_sharedAttachmentName));
  shared.createBinary(
    isProtected: false,
    name: _sharedAttachmentName,
    bytes: Uint8List.fromList(const [1, 1, 1, 1]),
  );
  if (tiedTimestamps) {
    shared.times.lastModificationTime.set(DateTime.utc(2026, 8, 22, 10));
  }

  final localOnly = KdbxEntry.create(file, file.body.rootGroup)
    ..forceSetUuid(KdbxUuid(_localOnlyEntryUuid));
  file.body.rootGroup.addEntry(localOnly);
  localOnly.setString(KdbxKeyCommon.TITLE, PlainValue('Local Only'));
}

/// spec 023 T209 — one `KPEX_PASSKEY_*` group on the shared entry, written
/// with a different credential id and private key per [side] so every member
/// of the group conflicts.
void _writePasskeyGroup(
  KdbxFile file, {
  required String side,
  String suffix = '',
  String relyingParty = 'webauthn.io',
}) {
  final shared = _entry(file, _sharedEntryUuid)!;
  shared
    ..setString(
      KdbxKey('KPEX_PASSKEY_RELYING_PARTY$suffix'),
      PlainValue(relyingParty),
    )
    ..setString(
      KdbxKey('KPEX_PASSKEY_CREDENTIAL_ID$suffix'),
      ProtectedValue.fromString('cred-$side'),
    )
    ..setString(
      KdbxKey('KPEX_PASSKEY_PRIVATE_KEY_PEM$suffix'),
      ProtectedValue.fromString('$_passkeyFixtureKeyMarker-$side'),
    );
}

/// Deliberately not PEM-shaped: nothing in this layer parses it, and a real
/// key header in a test fixture is what the secret scanners flag.
const _passkeyFixtureKeyMarker = 'KEYVAULT-FIXTURE-PASSKEY-VALUE';

DateTime _divergeRemote(KdbxFile file, {required bool tiedTimestamps}) {
  final shared = _entry(file, _sharedEntryUuid)!;
  shared
    ..setString(KdbxKeyCommon.USER_NAME, PlainValue(_remoteUserName))
    ..setString(KdbxKey(_remoteOnlyFieldKey), PlainValue(_remoteOnlyFieldValue))
    ..setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString('remote-secret'),
    )
    ..removeBinary(KdbxKey(_sharedAttachmentName));
  shared.createBinary(
    isProtected: false,
    name: _sharedAttachmentName,
    bytes: Uint8List.fromList(const [2, 2]),
  );
  if (tiedTimestamps) {
    shared.times.lastModificationTime.set(DateTime.utc(2026, 8, 22, 10));
  }

  final remoteOnly = KdbxEntry.create(file, file.body.rootGroup)
    ..forceSetUuid(KdbxUuid(_remoteOnlyEntryUuid));
  file.body.rootGroup.addEntry(remoteOnly);
  remoteOnly.setString(KdbxKeyCommon.TITLE, PlainValue('Remote Only'));

  // Explicit deletion EVIDENCE, which is the only thing that turns an absence
  // into a decision. `addDeletedObject` stamps the tombstone with the current
  // clock (its `now` parameter is dropped upstream), and the base pinned the
  // doomed entry's modification time to 2020, so the tombstone is strictly
  // newer and therefore MATCHES under T009b's G1/G3.
  KdbxDao(file).deletePermanently(_entry(file, _deletedEntryUuid)!);
  // ignore: invalid_use_of_visible_for_testing_member
  return file.body.deletedObjects
      .firstWhere((o) => o.uuid.uuid == _deletedEntryUuid)
      .deletionTime
      .get()!;
}

// ---------------------------------------------------------------------------
// Fakes for the surrounding contracts. `noSuchMethod` covers the members this
// repository never calls: if it starts calling one, the test fails loudly
// instead of silently receiving a default.
// ---------------------------------------------------------------------------

class _FakeRegistryRepository implements DatabaseRegistryRepository {
  _FakeRegistryRepository(this.record);

  final DatabaseRecord record;

  @override
  Future<DatabaseRecord?> getById(String databaseId) async =>
      databaseId == record.databaseId ? record : null;

  @override
  Future<String?> getActive() async => record.databaseId;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of T302');
}

class _FakeSecurityRepository implements DatabaseSecurityRepository {
  _FakeSecurityRepository(this.profile);

  final DatabaseSecurityProfile? profile;

  @override
  Future<DatabaseSecurityProfile?> getProfile(String databaseId) async =>
      profile;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of T302');
}

class _FakeSyncRepository implements DatabaseSyncRepository {
  _FakeSyncRepository({required this.mapping, required this.remote});

  final DatabaseSyncMapping? mapping;
  final _FakeRemoteDrive remote;

  /// Deliberately never written to: `DatabaseSyncRepository` exposes no raw
  /// upload, so T401's `commit` never calls anything on this fake that would
  /// populate it. A test asserting it is empty is what makes that a fact
  /// rather than an intention.
  final List<Uint8List> uploads = <Uint8List>[];

  @override
  Future<DatabaseSyncMapping?> getMapping(String databasePath) async =>
      databasePath == mapping?.databasePath ? mapping : null;

  @override
  Future<Uint8List> downloadRemoteFile(
    String fileId, {
    required String providerId,
  }) async {
    if (fileId != mapping?.remoteFileId) {
      throw StateError('unexpected remote file id');
    }
    if (remote.downloadError != null) throw remote.downloadError!;
    return remote.content;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of T302');
}

/// spec-008 T401 — the single mutable "what Drive actually holds" fixture
/// shared by [_FakeSyncRepository] (downloads) and [_FakeGoogleDriveApiService]
/// (metadata + uploads), so a test can simulate a concurrent writer by
/// mutating [content] directly, or by racing it mid-upload via [onUpload].
class _FakeRemoteDrive {
  _FakeRemoteDrive(this.content);

  Uint8List content;
  Object? downloadError;
  Object? getMetadataError;
  Object? updateFileError;

  /// When set, `updateFile` stores `await onUpload(uploadedBytes)` instead of
  /// the bytes it was actually called with — simulating a write that lands on
  /// the remote strictly between this upload and its own read-back.
  Future<Uint8List> Function(Uint8List uploaded)? onUpload;

  /// When true, `updateFile`'s response carries no checksum — the
  /// non-executable read-back FR-7 calls `ambiguous`.
  bool suppressChecksumOnUpdate = false;

  String checksum() => md5.convert(content).toString();
}

class _FakeGoogleDriveApiService implements GoogleDriveApiService {
  _FakeGoogleDriveApiService(this.remote);

  final _FakeRemoteDrive remote;
  final List<Uint8List> updateCalls = <Uint8List>[];
  int getMetadataCalls = 0;

  @override
  Future<RemoteFile> getFileMetadata(String fileId) async {
    getMetadataCalls++;
    if (remote.getMetadataError != null) throw remote.getMetadataError!;
    return RemoteFile(
      providerId: 'google_drive',
      id: fileId,
      name: 'fixture.kdbx',
      contentChecksum: remote.checksum(),
      modifiedTime: DateTime.now(),
    );
  }

  @override
  Future<RemoteFile> updateFile({
    required String fileId,
    required Uint8List bytes,
  }) async {
    updateCalls.add(bytes);
    if (remote.updateFileError != null) throw remote.updateFileError!;
    final race = remote.onUpload;
    remote.content = race == null ? bytes : await race(bytes);
    return RemoteFile(
      providerId: 'google_drive',
      id: fileId,
      name: 'fixture.kdbx',
      contentChecksum: remote.suppressChecksumOnUpdate
          ? null
          : remote.checksum(),
      modifiedTime: DateTime.now(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of T401');
}

class _FakeSyncMetadataDataSource implements SyncMetadataDataSource {
  final List<DatabaseSyncMapping> upsertCalls = <DatabaseSyncMapping>[];

  /// Every T404 record this store was handed, in order, including the
  /// ambiguous flips. Kept as a list rather than a map so a test can assert
  /// the transition happened, not merely the state it ended in.
  final List<PendingMergeUpload> pendingUploadCalls = <PendingMergeUpload>[];
  final Map<String, PendingMergeUpload> _pendingUploads = {};

  @override
  Future<void> upsertMapping(
    String databaseId,
    DatabaseSyncMapping mapping,
  ) async {
    upsertCalls.add(mapping.copyWith(databaseId: databaseId));
  }

  @override
  Future<PendingMergeUpload?> getPendingUpload(String databasePath) async {
    return _pendingUploads[databasePath];
  }

  @override
  Future<void> upsertPendingUpload(PendingMergeUpload record) async {
    pendingUploadCalls.add(record);
    _pendingUploads[record.databasePath] = record;
  }

  @override
  Future<void> clearPendingUpload(String databasePath) async {
    _pendingUploads.remove(databasePath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of T401');
}

class _FakeSecureDataSource implements SecureDataSource {
  _FakeSecureDataSource(this.password);

  String? password;

  @override
  Future<String?> getMasterPassword(String databaseId) async => password;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of T302');
}

/// Gate 4: a commit whose upload is interrupted after (or at) dispatch, so a
/// pending record is left behind for restart recovery. [applyRemote], when
/// given, runs on the remote before the transport failure — it decides what the
/// server actually ended up holding.
Future<_Harness> _ambiguousCommit(
  Directory temp,
  _FixturePair fixture, {
  void Function(_FakeRemoteDrive remote, Uint8List uploaded)? applyRemote,
}) async {
  final harness = await _Harness.build(temp, fixture: fixture);
  final summary = await harness.repository.startReview(harness.databaseId);
  if (applyRemote == null) {
    harness.remote.updateFileError = Exception('timeout');
  } else {
    harness.remote.onUpload = (uploaded) async {
      applyRemote(harness.remote, uploaded);
      throw Exception('timeout after dispatch');
    };
  }
  final outcome = await harness.repository.commit(summary.sessionId);
  expect(
    outcome,
    isA<MergeRejected>().having(
      (r) => r.code,
      'code',
      MergeFailureCode.uploadOutcomeAmbiguous,
    ),
  );
  expect(
    await harness.syncMetadata.getPendingUpload(harness.databasePath),
    isNotNull,
  );
  harness.remote.updateFileError = null;
  harness.remote.onUpload = null;
  return harness;
}

/// T403 / SC-15d: a writer whose backup step fails before anything is written.
class _BackupRefusingWriter extends SafeVaultFileWriter {
  @override
  Future<SafeVaultFileWriteResult> write({
    required String targetPath,
    required Uint8List bytes,
    bool backupExistingTarget = false,
    String? operation,
  }) async {
    throw const SafeVaultBackupUnavailableException(
      operation: 'merge commit',
      osReason: 'fixture refuses backups',
    );
  }
}

/// T412: an adapter that COULD serve revisions. Nothing asks it to.
class _VersionHistoryFakeDrive extends _FakeGoogleDriveApiService {
  _VersionHistoryFakeDrive(super.remote);

  int revisionCalls = 0;

  Future<List<Uint8List>> listRevisions(String fileId) async {
    revisionCalls++;
    return [remote.content];
  }
}

/// T412: an adapter that COULD enforce a precondition. Nothing sends one.
class _ConditionalWriteFakeDrive extends _FakeGoogleDriveApiService {
  _ConditionalWriteFakeDrive(super.remote);

  int conditionalCalls = 0;

  Future<RemoteFile> updateFileIfMatch({
    required String fileId,
    required Uint8List bytes,
    required String expectedToken,
  }) async {
    conditionalCalls++;
    if (expectedToken != remote.checksum()) {
      throw StateError('precondition failed');
    }
    return updateFile(fileId: fileId, bytes: bytes);
  }
}

/// T509: records how deeply the lock is nested and how often it is entered.
class _DepthMutex extends DatabasePathMutex {
  int _depth = 0;
  int maxDepth = 0;
  int entries = 0;

  @override
  Future<T> withDatabaseLock<T>(
    Iterable<String> paths,
    Future<T> Function() action,
  ) {
    return super.withDatabaseLock(paths, () async {
      entries++;
      _depth++;
      if (_depth > maxDepth) maxDepth = _depth;
      try {
        return await action();
      } finally {
        _depth--;
      }
    });
  }
}
