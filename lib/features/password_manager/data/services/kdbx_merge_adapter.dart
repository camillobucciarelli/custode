// spec-008 T301/T304/T305/T306/T308/T309 — the production KDBX <-> merge-model
// adapter.
//
// **What this file is.** The data-layer bridge that reads two `.kdbx` sides,
// produces the evidence a per-field and per-record diff is computed from, and
// — since slice 2 — applies the resolved decisions and serializes the merge
// candidate. It is the promotion of the Gate 0 spike helpers (`_validateSide`,
// `_crossSideKindMismatch`, `_lineageMatches` in `vault_kdbx_service_test.dart`)
// from test-only code into production code, with the typed refusals the frozen
// domain contract defines.
//
// **What this file is NOT, and why.**
//
//   * It **never touches the filesystem**. The caller hands over bytes and gets
//     bytes back. There is therefore no `withDatabaseLock` and no
//     `SafeVaultFileWriter` call here, and Gate 1's writer-routing guard has
//     nothing to route — building a candidate in memory is not a write, which
//     is a stronger statement than "it takes the mutex". The merge commit that
//     does write the candidate to disk (T403) is a separate, later task and
//     routes through both.
//   * It does **not** call `KdbxFile.merge`. That method is marked unfinished
//     upstream and is forbidden by the spec; a source scan in
//     `vault_kdbx_service_test.dart` enforces it over this file too. The record
//     import below is written against `cloneInto`/`forceSetUuid` instead, which
//     is what the Gate 0 T003 spike proved.
//
// **Secret boundary (T303).** `Credentials`, `KdbxFile`, decrypted string
// values and attachment bytes are legitimate in `data/` and illegitimate
// anywhere else. Nothing in this file is reachable from `domain/` or
// `presentation/` — enforced by `sync_merge_domain_architecture_test.dart`. The
// diff model below deliberately carries an attachment's **digest and length**,
// never its bytes: the diff only needs to classify, and a model that carried
// plaintext would be one refactor away from a log line.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:kdbx/kdbx.dart';
// Gate 0 recorded that the primitives a full-fidelity adapter needs sit outside
// `package:kdbx/kdbx.dart`'s export surface. `cloneInto` copies an entry —
// strings, binaries, custom data, times and history — across files, and
// `forceSetUuid` is what keeps the imported object's identity, which is the
// whole point of a UUID-matched merge.
// ignore: implementation_imports
import 'package:kdbx/src/kdbx_entry.dart' show KdbxEntryInternal;
// ignore: implementation_imports
import 'package:kdbx/src/kdbx_object.dart' show KdbxObjectInternal;

import '../../domain/models/sync_merge_models.dart';
import '../../domain/repositories/sync_merge_repository.dart';
import 'kdbx_semantic_manifest.dart';
import 'passkey_parser.dart';

/// What kind of object a live UUID denotes. FR-2 requires a UUID that appears
/// on both sides to denote the same kind on both.
enum KdbxMergeObjectKind { group, entry }

/// Which namespace a field key lives in. A string key and an attachment name
/// are compared separately even when they spell the same thing: KDBX stores
/// them in two different collections and FR-4's rules apply inside each.
enum KdbxMergeFieldKind { string, attachment }

/// The key KDBX itself matches on: **case-insensitive, case-preserving**.
///
/// `KdbxKey` (kdbx 2.5.0, `kdbx_entry.dart`) defines `==` and `hashCode` over
/// `key.toLowerCase()`, and both `_strings` and `_binaries` are keyed by it. So
/// `Custom_Totp` and `custom_totp` are **one field** to KDBX, and a diff that
/// keys on the verbatim spelling sees two.
///
/// That is not a cosmetic mismatch. It fails twice:
///
///   1. a real value conflict is reported as two automatic one-sided unions, so
///      FR-4's review never shows it to the user;
///   2. the union is not applicable — writing both members into one entry
///      collapses them onto a single key, one value is lost in silence, and
///      which one survives depends on iteration order. Two devices then
///      converge on different bytes, which is exactly the commutativity FR-3
///      exists to guarantee.
///
/// The case that misled the first implementation is `Title` vs `title`: it
/// behaves correctly, because `setString` on an existing entry resolves through
/// `KdbxKey.==` onto the key already stored and KDBX keeps the original
/// spelling. The defect needs the two sides to create the key **independently**
/// — which is the merge scenario and nothing else, and is reachable from any
/// user-typed custom field name or any importer, this repository's own import
/// paths included.
String canonicalFieldKey(String key) => key.toLowerCase();

/// FR-4's presence model, made explicit.
///
/// **Presence is independent of value.** A present empty string and a present
/// zero-byte attachment are [KdbxFieldPresent], never [KdbxFieldMissing] — that
/// distinction is the whole point of the type existing instead of a nullable
/// `String`, which is exactly the representation that collapses the two.
sealed class KdbxFieldPresence {
  const KdbxFieldPresence();

  bool get isPresent;
}

/// The field exists on this side. [semanticValue] is the comparison key, not
/// the plaintext payload:
///
///   * for a string it is the text **verbatim**;
///   * for an attachment it is the SHA-256 digest, so equal-name /
///     different-bytes is detected without the bytes entering this model.
///
/// Protection status is **not** folded into [semanticValue]; it is compared
/// alongside it, in [sameAs], out of [isProtected]. Anyone refactoring `sameAs`
/// must keep both halves: dropping the [isProtected] comparison would make a
/// plain-to-protected change compare `identical` and be silently discarded.
///
/// **No normalisation is applied to a string value, deliberately.** No `trim`,
/// no Unicode normalisation, no case folding. Two values differing only in NFC
/// vs NFD, or only in trailing whitespace, are a [KdbxFieldClassification
/// .fieldConflict] and go to the user. That is the conservative direction: a
/// silent normalisation rewrites a value the user stored — and in a password
/// field a trimmed trailing space is a credential that no longer works. Guarded
/// by tests, so a future "helpful" `trim()` fails instead of shipping.
final class KdbxFieldPresent extends KdbxFieldPresence {
  const KdbxFieldPresent({
    required this.semanticValue,
    required this.isProtected,
    required this.length,
  });

  /// Builds the present state of a KDBX string.
  ///
  /// **Absence of the *key* is the only thing that means missing.** A key
  /// holding an empty value is present.
  ///
  /// The null [StringValue] branch is defensive and, on kdbx 2.5.0, unreachable
  /// through the reader and `setString`: `_strings` is typed
  /// `Map<KdbxKey, StringValue?>`, but the XML reader always constructs a
  /// `PlainValue` (`kdbx_entry.dart:187-197`) and `setString(key, null)`
  /// **removes** the key rather than storing a null (`kdbx_entry.dart:341-352`;
  /// `removeString` is an alias for exactly that). It is not unreachable in
  /// general: `renameKey` with an absent `oldKey` writes `_strings[newKey] =
  /// null` with no guard (`kdbx_entry.dart:355-359`). The adapter never calls
  /// `renameKey`, so that path cannot originate here — but the branch is kept,
  /// and is the reason it is not an assertion.
  /// So the three states the type suggests — absent, null, empty — are two in
  /// any vault, and one fewer again after a save: `<Value/>` reads back as an
  /// empty `PlainValue`. It is mapped to present-empty rather than to missing,
  /// because a key that exists is present; the alternative would make presence
  /// depend on a value, which is the one thing FR-4 forbids.
  factory KdbxFieldPresent.string(StringValue? value) {
    final text = value?.getText() ?? '';
    return KdbxFieldPresent(
      semanticValue: text,
      isProtected: value is ProtectedValue,
      length: text.length,
    );
  }

  /// Builds the present state of a KDBX attachment. Zero bytes is present.
  factory KdbxFieldPresent.attachment(KdbxBinary binary) {
    final bytes = binary.value;
    return KdbxFieldPresent(
      semanticValue: sha256.convert(bytes).toString(),
      isProtected: binary.isProtected,
      length: bytes.length,
    );
  }

  final String semanticValue;
  final bool isProtected;
  final int length;

  @override
  bool get isPresent => true;

  /// Semantic equality for FR-4's "present, equal" row. Protection status is
  /// part of the compared semantics, so a value that only changed from plain
  /// to protected is a genuine conflict rather than a silent overwrite.
  bool sameAs(KdbxFieldPresent other) =>
      semanticValue == other.semanticValue && isProtected == other.isProtected;

  /// Deliberately redacted. This object holds a decrypted value.
  @override
  String toString() => 'KdbxFieldPresent(<redacted>)';
}

/// The field does not exist on this side. **This is not deletion evidence**
/// (FR-4): KDBX has no field-level or attachment-level tombstone, so a missing
/// field is an automatic union member, never a delete.
final class KdbxFieldMissing extends KdbxFieldPresence {
  const KdbxFieldMissing();

  @override
  bool get isPresent => false;

  @override
  String toString() => 'KdbxFieldMissing()';
}

/// FR-4's classification of one field across the two sides.
///
/// `fieldDeletionConflict` has **no member here on purpose.** It requires
/// "explicit field deletion evidence proven by the adapter", and the Gate 0
/// spike proved the installed library exposes deletion evidence only at object
/// level (`DeletedObjects`), never per field or per attachment. Emitting the
/// classification anyway would be the adapter *claiming* evidence it does not
/// have, which FR-4 forbids in the same paragraph. Record-level deletion
/// evidence is FR-5 and lands with T308.
enum KdbxFieldClassification {
  /// Present on both sides with the same semantic value.
  identical,

  /// Present on both sides with different semantic values — a real conflict.
  fieldConflict,

  /// Present locally, missing remotely, no deletion evidence: automatic union.
  fieldLocalOnly,

  /// Missing locally, present remotely, no deletion evidence: automatic union.
  fieldRemoteOnly,
}

/// One field's evidence, for one entry, across both sides.
final class KdbxFieldDiff {
  const KdbxFieldDiff({
    required this.entryUuid,
    required this.fieldKind,
    required this.canonicalKey,
    required this.localKey,
    required this.remoteKey,
    required this.local,
    required this.remote,
    required this.classification,
  });

  /// The KDBX entry UUID both sides agree on. Data-private: FR-2 keeps raw
  /// UUIDs out of logs, state and the domain port.
  final String entryUuid;
  final KdbxMergeFieldKind fieldKind;

  /// The key the two sides are **matched** on — [canonicalFieldKey], i.e. what
  /// KDBX itself matches on. Never written back to a vault.
  final String canonicalKey;

  /// The original key spelling on each side, verbatim, `null` where that side
  /// has no such field. FR-1 keeps original key spelling, so the adapter
  /// preserves both rather than canonicalising one away: the canonical form is
  /// a *match key*, not a value.
  final String? localKey;
  final String? remoteKey;

  final KdbxFieldPresence local;
  final KdbxFieldPresence remote;
  final KdbxFieldClassification classification;

  /// Both sides hold this field but spell its key differently — e.g. local
  /// `Custom_Totp`, remote `custom_totp`.
  ///
  /// **The adapter reports this and does not resolve it.** Neither FR-1 nor
  /// FR-4 says which spelling wins, and the three answers available are all
  /// decisions rather than derivations: "keep local" is perspective-dependent
  /// and FR-3 forbids that class outright (two devices would pick opposite
  /// spellings and never converge); "make it a conflict" would send a row to
  /// the user whose *values* agree, which FR-4's "present, equal → identical"
  /// row denies; and applying FR-3's deterministic UTF-8 order is very probably
  /// right but belongs to T401a, which owns that comparator and has not been
  /// written. Producing the evidence and leaving the choice to the apply step
  /// is the conservative option: nothing is lost, nothing is invented, and the
  /// decision is recorded as open. Raised to the PM with this slice.
  ///
  /// Classification is unaffected: it is driven by the values, so the fixture
  /// `Custom_Totp='AAA'` vs `custom_totp='BBB'` is one
  /// [KdbxFieldClassification.fieldConflict], which is what the user must see.
  bool get keySpellingDiverges =>
      localKey != null && remoteKey != null && localKey != remoteKey;

  @override
  String toString() => 'KdbxFieldDiff(<redacted>)';
}

/// What one side knows about one object, re-derived from that side's tree and
/// `DeletedObjects` list.
///
/// **Why this has to be re-derived rather than read off the presence sets.**
/// Deleting an entry in this app moves it to the recycle bin. A recycle-binned
/// object is still a *live object in the KDBX tree*: it appears in
/// `getAllGroupsAndEntries`, it is shared with the other side, and its fields
/// keep diffing as though nothing happened. Meanwhile the recycle-bin group
/// itself shows up as an ordinary one-sided group on whichever side created it.
/// Neither fact is deletion evidence, and neither is visible in a UUID set — so
/// bin membership is computed here by walking down from `KdbxFile.recycleBin`,
/// and permanent deletion is read from the `DeletedObjects` tombstone list.
enum KdbxRecordEvidence {
  /// Live in the tree, outside the recycle bin.
  live,

  /// Live in the tree, inside the recycle bin subtree (a move-to-bin).
  recycled,

  /// Absent from the tree with a matching `DeletedObjects` tombstone.
  tombstoned,

  /// Absent from the tree with no tombstone. FR-4: **not** deletion evidence.
  absent,
}

/// One side's evidence about one object.
final class KdbxRecordSide {
  const KdbxRecordSide({
    required this.evidence,
    this.modifiedAtUtc,
    this.deletedAtUtc,
  });

  const KdbxRecordSide.absent()
    : evidence = KdbxRecordEvidence.absent,
      modifiedAtUtc = null,
      deletedAtUtc = null;

  final KdbxRecordEvidence evidence;

  /// KDBX `LastModificationTime` where the object is live on this side.
  final DateTime? modifiedAtUtc;

  /// Tombstone `DeletionTime` where this side holds one.
  final DateTime? deletedAtUtc;

  bool get isLiveSomewhere =>
      evidence == KdbxRecordEvidence.live ||
      evidence == KdbxRecordEvidence.recycled;

  // A constant literal, even though `evidence` is a safe enum: the rule the
  // gate enforces is "no interpolation at all", because an interpolation that
  // is safe today is one field away from carrying a decrypted value, and the
  // reviewer who adds that field will not re-read this method.
  @override
  String toString() => 'KdbxRecordSide(<redacted>)';
}

/// FR-5's record-level classification of one object across the two sides.
enum KdbxRecordClassification {
  /// Live and un-binned on both sides: the ordinary shared record, and the
  /// only classification whose fields are diffed.
  sharedLive,

  /// Live on the local side, no evidence at all on the remote: automatic union.
  recordLocalOnly,

  /// Live on the remote side, no evidence at all on the local: automatic union.
  recordRemoteOnly,

  /// Live one side, deleted (binned or tombstoned) on the other. FR-5 requires
  /// an explicit keep/delete; the default is keep.
  recordDeletionConflict,

  /// Deleted on both sides. Stays deleted; the tombstone/bin evidence of both
  /// sides is preserved.
  recordDeleted,
}

/// One object's record-level evidence across both sides.
final class KdbxRecordDiff {
  const KdbxRecordDiff({
    required this.objectUuid,
    required this.objectKind,
    required this.local,
    required this.remote,
    required this.classification,
  });

  final String objectUuid;
  final KdbxMergeObjectKind objectKind;
  final KdbxRecordSide local;
  final KdbxRecordSide remote;
  final KdbxRecordClassification classification;

  @override
  String toString() => 'KdbxRecordDiff(<redacted>)';
}

/// The read-only evidence a diff is computed from: how every object classifies
/// at record level (FR-5), and how every field of every shared live entry
/// classifies at field level (FR-4).
final class KdbxPresenceDiff {
  KdbxPresenceDiff({
    required List<KdbxRecordDiff> recordDiffs,
    required List<KdbxFieldDiff> fieldDiffs,
  }) : recordDiffs = List.unmodifiable(recordDiffs),
       fieldDiffs = List.unmodifiable(fieldDiffs);

  /// Every object live on at least one side, sorted by UUID so two devices
  /// produce the same evidence in the same order.
  ///
  /// An object tombstoned on both sides and live on neither is deliberately
  /// **not** here: it carries no decision and has no fields. Its tombstones are
  /// still joined when the candidate is built — the newer of the two clocks
  /// wins, which is FR-5's "preserve newest supported deletion data" — see
  /// [KdbxMergeAdapter._unionTombstones].
  final List<KdbxRecordDiff> recordDiffs;

  /// Only fields of entries [KdbxRecordClassification.sharedLive] on both
  /// sides. A one-sided entry's fields are not a field-level decision — the
  /// whole record is an automatic union member — and neither are the fields of
  /// a record whose *existence* is being decided.
  final List<KdbxFieldDiff> fieldDiffs;

  Set<String> _uuidsWhere(
    KdbxRecordClassification classification,
    KdbxMergeObjectKind kind,
  ) => {
    for (final record in recordDiffs)
      if (record.classification == classification && record.objectKind == kind)
        record.objectUuid,
  };

  Set<String> get localOnlyEntryUuids => _uuidsWhere(
    KdbxRecordClassification.recordLocalOnly,
    KdbxMergeObjectKind.entry,
  );

  Set<String> get remoteOnlyEntryUuids => _uuidsWhere(
    KdbxRecordClassification.recordRemoteOnly,
    KdbxMergeObjectKind.entry,
  );

  Set<String> get localOnlyGroupUuids => _uuidsWhere(
    KdbxRecordClassification.recordLocalOnly,
    KdbxMergeObjectKind.group,
  );

  Set<String> get remoteOnlyGroupUuids => _uuidsWhere(
    KdbxRecordClassification.recordRemoteOnly,
    KdbxMergeObjectKind.group,
  );

  /// FR-5 record-level decisions the user must answer.
  List<KdbxRecordDiff> get deletionConflicts => [
    for (final record in recordDiffs)
      if (record.classification ==
          KdbxRecordClassification.recordDeletionConflict)
        record,
  ];

  /// FR-4 one-sided field count for the redacted review summary.
  int get oneSidedFieldCount => fieldDiffs
      .where(
        (d) =>
            d.classification == KdbxFieldClassification.fieldLocalOnly ||
            d.classification == KdbxFieldClassification.fieldRemoteOnly,
      )
      .length;

  @override
  String toString() => 'KdbxPresenceDiff(<redacted>)';
}

/// Addresses one field of one entry, the way the diff matches it.
typedef KdbxFieldRef = ({
  String entryUuid,
  KdbxMergeFieldKind fieldKind,
  String canonicalKey,
});

KdbxFieldRef kdbxFieldRefOf(KdbxFieldDiff diff) => (
  entryUuid: diff.entryUuid,
  fieldKind: diff.fieldKind,
  canonicalKey: diff.canonicalKey,
);

/// The resolved answers the candidate is built from — data-private, and the
/// only thing the domain's redacted decisions are translated into.
final class KdbxMergeResolution {
  KdbxMergeResolution({
    Map<KdbxFieldRef, MergeChoice> fieldChoices = const {},
    Map<String, MergeChoice> recordChoices = const {},
    Map<String, MergeChoice> credentialBlockChoices = const {},
    Map<KdbxPasskeyBlockRef, MergeChoice> passkeyBlockChoices = const {},
  }) : _fieldChoices = Map.unmodifiable(fieldChoices),
       _recordChoices = Map.unmodifiable(recordChoices),
       _credentialBlockChoices = Map.unmodifiable(credentialBlockChoices),
       _passkeyBlockChoices = Map.unmodifiable(passkeyBlockChoices);

  final Map<KdbxFieldRef, MergeChoice> _fieldChoices;
  final Map<String, MergeChoice> _recordChoices;

  /// FR-3a: keyed by entry UUID — the block identity — never by a member's
  /// [KdbxFieldRef]. [engagedCredentialBlockEntryUuids] must have been used to
  /// decide which entries these are; an engaged entry with no entry here is
  /// the same programming error [fieldChoiceFor] guards against.
  final Map<String, MergeChoice> _credentialBlockChoices;

  /// spec 023 T209 / FR-008: keyed by the passkey group, never by a member's
  /// [KdbxFieldRef]. One answer moves the whole credential, so a merge can
  /// never assemble one from two different passkeys.
  final Map<KdbxPasskeyBlockRef, MergeChoice> _passkeyBlockChoices;

  /// A conflict with no recorded answer is a programming error, not a merge
  /// outcome: every conflict carries a computed default from the moment the
  /// review is created, so an absent entry means the resolution was not built
  /// from the session's own decisions.
  MergeChoice fieldChoiceFor(KdbxFieldDiff diff) {
    final choice = _fieldChoices[kdbxFieldRefOf(diff)];
    if (choice == null) {
      throw StateError('no recorded choice for a field conflict');
    }
    return choice;
  }

  /// FR-5's default is **keep**, so an unanswered deletion conflict preserves.
  /// An unattended session can never delete.
  MergeChoice recordChoiceFor(String objectUuid) =>
      _recordChoices[objectUuid] ?? MergeChoice.keep;

  /// FR-3a's one answer per engaged block, always `local` or `remote` — the
  /// same programming-error contract as [fieldChoiceFor].
  MergeChoice credentialBlockChoiceFor(String entryUuid) {
    final choice = _credentialBlockChoices[entryUuid];
    if (choice == null) {
      throw StateError('no recorded choice for a credential-block conflict');
    }
    return choice;
  }

  /// spec 023 T209: one answer per engaged passkey group, with the same
  /// programming-error contract as [fieldChoiceFor].
  MergeChoice passkeyBlockChoiceFor(KdbxPasskeyBlockRef ref) {
    final choice = _passkeyBlockChoices[ref];
    if (choice == null) {
      throw StateError('no recorded choice for a passkey-block conflict');
    }
    return choice;
  }

  @override
  String toString() => 'KdbxMergeResolution(<redacted>)';
}

/// FR-3's Notes separator. **Not** a plain Markdown thematic break: it carries
/// `U+241E SYMBOL FOR RECORD SEPARATOR` between two rules, so ordinary user
/// text — including a `---` the user typed themselves — splits into exactly one
/// segment and can be neither interleaved nor deduplicated against itself.
const mergeNotesSeparator = '\n\n---\u241E---\n\n';

/// FR-3's `bothNotes`: an **ordered, deduplicated union of segments**, not a
/// concatenation.
///
/// A concatenation with a merely fixed operand order is deterministic and still
/// not associative, so three devices merging in different orders hold different
/// Notes, the FR-7 semantic short-circuit stops firing and the next round
/// duplicates text the user wrote. The set union sorted by one fixed comparator
/// is associative, commutative and idempotent.
String notesSegmentUnion(String local, String remote) {
  final segments = {
    ...local.split(mergeNotesSeparator),
    ...remote.split(mergeNotesSeparator),
  }.where((segment) => segment.isNotEmpty).toList()..sort(compareUtf8Bytes);
  return segments.join(mergeNotesSeparator);
}

/// FR-3's value order: unsigned lexicographic over **UTF-8** bytes, shortest is
/// smaller on a common prefix.
///
/// The encoding is UTF-8 and no other. A Dart `String`'s `codeUnits` are
/// UTF-16, which sorts an astral character's surrogate pair *below* the BMP
/// range `U+E000..FFFF` while its UTF-8 bytes and its code point sort *above*:
/// two devices disagreeing on the encoding elect opposite winners, and the
/// tie-break's whole purpose is that they do not.
///
/// T401a owns the full tie-break (timestamps first, then this). This function
/// is the value half, needed here because [notesSegmentUnion] must sort by the
/// *same* comparator — a segment order that drifted from the tie-break order
/// would make two devices agree on every field and disagree on the notes.
int compareUtf8Bytes(String a, String b) {
  final left = utf8.encode(a);
  final right = utf8.encode(b);
  final shared = left.length < right.length ? left.length : right.length;
  for (var i = 0; i < shared; i++) {
    if (left[i] != right[i]) return left[i] - right[i];
  }
  return left.length - right.length;
}

/// FR-3 rule 3, extended to the **protection dimension** [KdbxFieldPresent
/// .sameAs] also compares (T401a).
///
/// Rule 3 as written orders "the candidate values", and on KDBX a candidate is
/// a value **plus** a protected/plain flag — [KdbxFieldPresent.sameAs] already
/// treats a value that only changed protection as a real conflict, so
/// [KdbxFieldClassification.fieldConflict] is reachable with byte-identical
/// [KdbxFieldPresent.semanticValue]s on both sides. Deciding that case by
/// [compareUtf8Bytes] alone leaves it a bare tie, and a caller that broke the
/// tie by defaulting to "local" reproduced exactly the perspective bug FR-3
/// forbids for values: two mirrored devices, each keeping its OWN protection
/// flag, converge on two different candidates forever. The flag is folded
/// into the same order, after the value bytes: `protected` sorts after
/// `plain` — arbitrary but fixed, exactly as "greater wins" is arbitrary but
/// fixed for the value bytes themselves.
int compareFieldPresent(KdbxFieldPresent a, KdbxFieldPresent b) {
  final byValue = compareUtf8Bytes(a.semanticValue, b.semanticValue);
  if (byValue != 0) return byValue;
  if (a.isProtected == b.isProtected) return 0;
  return a.isProtected ? 1 : -1;
}

/// FR-3a's exact, closed membership set — `UserName`/`Password`/`URL` by
/// [canonicalFieldKey] — and nothing else. Not configurable and does not grow
/// with an entry's contents: this is the only place the three keys are named
/// as a set, so a future field can never join it by accident.
const credentialBlockCanonicalKeys = {'password', 'url', 'username'};

/// FR-3a's fixed block-image member order — ascending UTF-8 over the
/// canonical keys themselves (`password` < `url` < `username`) — which is
/// display priority order too, by coincidence of the alphabet, but is used
/// here purely as the tie-break's fixed join order.
const _credentialBlockImageOrder = ['password', 'url', 'username'];

/// FR-3a's block-image join byte, `0x1E` (`INFORMATION SEPARATOR TWO`).
/// Built with [String.fromCharCode] rather than a `\uXXXX` literal so the
/// control character never has to sit unescaped in this source file.
final String _credentialBlockImageSeparator = String.fromCharCode(0x1E);

/// FR-3a membership: true for exactly `username`, `password` and `url`.
bool isCredentialBlockKey(String canonicalKey) =>
    credentialBlockCanonicalKeys.contains(canonicalKey);

/// FR-3a's one-comparison-per-block tie-break (T401c), reusing
/// [compareUtf8Bytes] directly rather than a second comparator (T401a).
/// [local]/[remote] map canonical member key to that side's present value; an
/// absent member is simply missing from the map and contributes an empty
/// sequence to the image, per spec.
int compareCredentialBlockImage(
  Map<String, KdbxFieldPresent> local,
  Map<String, KdbxFieldPresent> remote,
) {
  String imageOf(Map<String, KdbxFieldPresent> side) => [
    for (final key in _credentialBlockImageOrder)
      side[key]?.semanticValue ?? '',
  ].join(_credentialBlockImageSeparator);
  return compareUtf8Bytes(imageOf(local), imageOf(remote));
}

/// FR-3a's engagement rule: entry UUIDs whose credential block has at least
/// one conflicting shared member (T401c).
///
/// Shared between the apply step below and the repository's decision
/// building — both must agree on exactly this set, or the apply step and the
/// review decisions it is built from disagree about which fields the block
/// owns, and [KdbxMergeResolution.credentialBlockChoiceFor] either throws on
/// a missing entry or is never consulted for one the apply step expected.
Set<String> engagedCredentialBlockEntryUuids(KdbxPresenceDiff diff) {
  final engaged = <String>{};
  for (final field in diff.fieldDiffs) {
    if (field.fieldKind != KdbxMergeFieldKind.string) continue;
    if (!isCredentialBlockKey(field.canonicalKey)) continue;
    if (field.classification != KdbxFieldClassification.fieldConflict) {
      continue;
    }
    engaged.add(field.entryUuid);
  }
  return engaged;
}

/// spec 023 T209 — the identity of one passkey on one entry: the entry plus
/// the `KPEX_PASSKEY_*` group marker (`''`, `_1`, `_2`, …). An entry can hold
/// several passkeys, so unlike FR-3a's credential block the entry UUID alone
/// is not the block identity.
typedef KdbxPasskeyBlockRef = ({String entryUuid, String suffix});

/// [canonicalFieldKey] lowercases, so the namespace is matched in that form.
final String _passkeyCanonicalPrefix = PasskeyParser.keyPrefix.toLowerCase();

/// spec 023 T209 membership: true for every key in the `KPEX_PASSKEY_*`
/// namespace, including keys this app does not interpret
/// (`KPEX_PASSKEY_PRF`) — they belong to the credential and must move with it.
bool isPasskeyBlockKey(String canonicalKey) =>
    canonicalKey.startsWith(_passkeyCanonicalPrefix);

/// The group marker of a passkey field's canonical key. [PasskeyParser.suffixOf]
/// matches on trailing digits only, so the lowercased form is equivalent.
String passkeyBlockSuffixOf(String canonicalKey) =>
    PasskeyParser.suffixOf(canonicalKey);

KdbxPasskeyBlockRef? kdbxPasskeyBlockRefOf(KdbxFieldDiff diff) {
  if (diff.fieldKind != KdbxMergeFieldKind.string) return null;
  if (!isPasskeyBlockKey(diff.canonicalKey)) return null;
  return (
    entryUuid: diff.entryUuid,
    suffix: passkeyBlockSuffixOf(diff.canonicalKey),
  );
}

/// spec 023 T209 engagement: the passkey groups with at least one conflicting
/// shared member. Shared by the apply step and the repository's decision
/// building, exactly as [engagedCredentialBlockEntryUuids] is.
Set<KdbxPasskeyBlockRef> engagedPasskeyBlocks(KdbxPresenceDiff diff) {
  final engaged = <KdbxPasskeyBlockRef>{};
  for (final field in diff.fieldDiffs) {
    if (field.classification != KdbxFieldClassification.fieldConflict) {
      continue;
    }
    final ref = kdbxPasskeyBlockRefOf(field);
    if (ref != null) engaged.add(ref);
  }
  return engaged;
}

/// Every field diff belonging to one passkey group, whichever classification
/// each carries.
List<KdbxFieldDiff> passkeyBlockFieldsOf(
  KdbxPresenceDiff diff,
  KdbxPasskeyBlockRef ref,
) => [
  for (final field in diff.fieldDiffs)
    if (kdbxPasskeyBlockRefOf(field) == ref) field,
];

/// The relying party the group names, for the one row's label — the only
/// member of the namespace that is not a secret and not an opaque identifier.
///
/// The local side is preferred and the remote is the fallback: the label says
/// which credential the row is about, and a conflict on this very field is the
/// one case where the two disagree — for which the row still has to be named
/// something, and naming it after the side being replaced would read as a
/// promise the merge does not make. `null` when neither side carries it, which
/// is a passkey the parser would itself call unusable.
String? passkeyBlockRelyingPartyId(List<KdbxFieldDiff> blockFields) =>
    passkeyBlockRelyingPartyIdOn(blockFields, local: true) ??
    passkeyBlockRelyingPartyIdOn(blockFields, local: false);

/// The relying party one side of the group names, for that side's own
/// display: when the field itself conflicts, each side must show the site its
/// credential is actually for, or the user picks blind. Matched on the group's
/// own suffixed key, so `_1`, `_2` groups resolve as the first group does.
String? passkeyBlockRelyingPartyIdOn(
  List<KdbxFieldDiff> blockFields, {
  required bool local,
}) {
  for (final field in blockFields) {
    final rpKey =
        PasskeyParser.relyingPartyKey.toLowerCase() +
        passkeyBlockSuffixOf(field.canonicalKey);
    if (field.canonicalKey != rpKey) continue;
    final value = local ? field.local : field.remote;
    if (value is KdbxFieldPresent) return value.semanticValue;
  }
  return null;
}

/// spec 023 T209's tie-break: one comparison per group over the whole
/// credential, so the group moves as a unit. Built from the members' canonical
/// keys in ascending UTF-8 order — a fixed join order, as
/// [compareCredentialBlockImage]'s is — and NOT from the private key alone,
/// which would make the outcome depend on one field of several.
int comparePasskeyBlockImage(
  Map<String, KdbxFieldPresent> local,
  Map<String, KdbxFieldPresent> remote,
) {
  final keys = <String>{...local.keys, ...remote.keys}.toList()
    ..sort(compareUtf8Bytes);
  String imageOf(Map<String, KdbxFieldPresent> side) =>
      [for (final key in keys) side[key]?.semanticValue ?? '']
          .join(_credentialBlockImageSeparator);
  return compareUtf8Bytes(imageOf(local), imageOf(remote));
}

/// All of one entry's credential-block field diffs — up to three (password,
/// url, username), whichever classification each carries. Empty if the entry
/// has none of the three fields on either side.
List<KdbxFieldDiff> credentialBlockFieldsOf(
  KdbxPresenceDiff diff,
  String entryUuid,
) => [
  for (final field in diff.fieldDiffs)
    if (field.fieldKind == KdbxMergeFieldKind.string &&
        isCredentialBlockKey(field.canonicalKey) &&
        field.entryUuid == entryUuid)
      field,
];

/// One validated side: the open file plus its live-object UUID index.
///
/// Only constructible through [KdbxMergeAdapter.validatePair], so an index that
/// failed FR-2 validation cannot exist.
///
/// **The guarantee is about the index, not about the file.** [file] is a live
/// mutable `KdbxFile`, and [KdbxMergeAdapter.diffPresence] re-walks it rather
/// than reading [liveObjectKinds] back, so a caller that mutates the file
/// between the two calls gets a diff over unvalidated state. Nothing does that
/// today — the adapter is read-only and the sides are opened from bytes
/// immediately before validation — but "validated by construction" would be
/// overclaiming, so it is stated as what it is: validated at the moment
/// `validatePair` returned.
final class KdbxMergeSide {
  const KdbxMergeSide._(this.file, this.liveObjectKinds);

  final KdbxFile file;

  /// Every live group and entry UUID on this side, mapped to its object kind,
  /// as observed during validation: globally unique and non-nil at that point.
  final Map<String, KdbxMergeObjectKind> liveObjectKinds;

  @override
  String toString() => 'KdbxMergeSide(<redacted>)';
}

/// Two sides that have passed every FR-2 gate: per-side UUID integrity, root
/// UUID lineage and cross-side object-kind agreement.
final class KdbxMergePair {
  const KdbxMergePair._(this.local, this.remote);

  final KdbxMergeSide local;
  final KdbxMergeSide remote;

  @override
  String toString() => 'KdbxMergePair(<redacted>)';
}

/// Reads two KDBX sides and produces the evidence for a per-field diff.
///
/// Stateless and read-only. Every refusal is a [SyncMergeFailure] carrying a
/// [MergeFailureCode] and nothing else: no UUID, no object label, no path, no
/// value. FR-2 requires exactly that, because the alternative is a log line
/// that names the entry the user was trying to protect.
class KdbxMergeAdapter {
  const KdbxMergeAdapter({KdbxFormat Function()? format})
    : _format = format ?? KdbxFormat.new;

  /// Tests inject a format that counts key derivations.
  final KdbxFormat Function() _format;

  /// Opens one side from bytes.
  ///
  /// The caller resolves credentials and reads the bytes; the adapter touches
  /// no filesystem, so it can never be the writer that bypasses the mutex.
  ///
  /// **Failure mapping.** A header the library refuses — an out-of-range major
  /// version, an unknown cipher — becomes
  /// [MergeFailureCode.unsupportedKdbxConstruct]. Gate 0 recorded that the
  /// refusal is not one exception type: 5.x and above throw
  /// `KdbxUnsupportedException`, below 3.x the header parser fails earlier with
  /// a `RangeError`. Both are mapped, and so is any other parse failure, so an
  /// unreadable side can never be mistaken for an empty one.
  ///
  /// A wrong-credentials failure is deliberately **not** mapped and propagates
  /// unchanged: it is the calling repository's concern (T302), it is not a
  /// property of the KDBX construct, and swallowing it here would report a
  /// revoked credential as a corrupt database.
  ///
  /// [keySource], a file already opened with [credentials], lets the read
  /// skip the KDF when [bytes] carry the same KDF salt (see
  /// [KdbxFormat.read]); the decrypt and every check still run in full.
  Future<KdbxFile> openSide({
    required Uint8List bytes,
    required Credentials credentials,
    KdbxFile? keySource,
  }) async {
    try {
      return await _format().read(bytes, credentials, keySource: keySource);
    } on KdbxInvalidKeyException {
      rethrow;
    } on Object {
      throw const SyncMergeFailure(MergeFailureCode.unsupportedKdbxConstruct);
    }
  }

  /// Runs every FR-2 gate over the pair and returns the validated sides.
  ///
  /// **Nothing has happened yet when this throws.** The adapter holds no
  /// session, has opened no file handle for writing and has contacted no remote
  /// — and the repository (T302) cannot mint a session id before this method
  /// returns, because the validated [KdbxMergePair] is its only input. "Reject
  /// before session, backup, local write or upload" is therefore a property of
  /// the call graph, not of a check someone remembered to run first.
  ///
  /// Order, and why it is this order:
  ///
  /// 1. **per side** — nil UUID, duplicate entry UUID, duplicate group UUID,
  ///    group/entry collision. Uniqueness is global across groups and entries,
  ///    not per collection and not per parent;
  /// 2. **lineage** — root group UUIDs must match. A shared remote file id is
  ///    not lineage evidence (proven in Gate 0: two independently created
  ///    databases never share a root UUID);
  /// 3. **cross-side kind** — a UUID live on both sides must denote the same
  ///    kind. Only visible with both indexes in hand, which is why it is last.
  ///
  /// **What the order between 1 and 2 actually buys, stated honestly.** It is
  /// not safety: swapping them refuses the same set of pairs, because a nil
  /// root that slipped past the lineage comparison is caught by the per-side
  /// check immediately after, with the same code. An earlier revision of this
  /// comment claimed two nil roots would "pass the gate"; that was false, and a
  /// mutation swapping the blocks survived the whole suite, which is how it was
  /// caught. What the order decides is the **reported code** when a pair
  /// violates both at once: a structurally invalid side is
  /// [MergeFailureCode.unsupportedKdbxData], never
  /// [MergeFailureCode.wrongLineage]. That distinction is worth pinning —
  /// `wrongLineage` tells the user "these are different databases", which is
  /// the wrong remedy for a corrupt one — so it is pinned by a test rather than
  /// left to statement order.
  KdbxMergePair validatePair({
    required KdbxFile local,
    required KdbxFile remote,
  }) {
    final localSide = _validateSide(local);
    final remoteSide = _validateSide(remote);

    if (local.body.rootGroup.uuid != remote.body.rootGroup.uuid) {
      throw const SyncMergeFailure(MergeFailureCode.wrongLineage);
    }

    for (final entry in localSide.liveObjectKinds.entries) {
      final remoteKind = remoteSide.liveObjectKinds[entry.key];
      if (remoteKind != null && remoteKind != entry.value) {
        throw const SyncMergeFailure(MergeFailureCode.unsupportedKdbxData);
      }
    }

    return KdbxMergePair._(localSide, remoteSide);
  }

  /// FR-4/FR-5's presence diff over a validated pair.
  ///
  /// Records are matched by KDBX UUID, never by title or path (FR-3). Record
  /// evidence is re-derived per side from the tree (bin membership) and the
  /// `DeletedObjects` list (tombstones) — see [KdbxRecordEvidence] for why the
  /// UUID sets alone cannot say it. Fields are classified only for records live
  /// and un-binned on both sides; a `missing` side with no deletion evidence is
  /// an automatic union member and never a delete.
  KdbxPresenceDiff diffPresence(KdbxMergePair pair) {
    final local = _sideEvidence(pair.local);
    final remote = _sideEvidence(pair.remote);

    final recordDiffs = <KdbxRecordDiff>[];
    final fieldDiffs = <KdbxFieldDiff>[];

    // Sorted so two devices emit the same evidence in the same order; FR-3's
    // convergence argument depends on it.
    final uuids = {...local.objects.keys, ...remote.objects.keys}.toList()
      ..sort();

    for (final uuid in uuids) {
      final localObject = local.objects[uuid];
      final remoteObject = remote.objects[uuid];
      final localSide = local.sideFor(uuid);
      final remoteSide = remote.sideFor(uuid);
      final classification = _classifyRecord(localSide, remoteSide);

      recordDiffs.add(
        KdbxRecordDiff(
          objectUuid: uuid,
          objectKind: (localObject ?? remoteObject!) is KdbxGroup
              ? KdbxMergeObjectKind.group
              : KdbxMergeObjectKind.entry,
          local: localSide,
          remote: remoteSide,
          classification: classification,
        ),
      );

      if (classification != KdbxRecordClassification.sharedLive) continue;
      if (localObject is! KdbxEntry || remoteObject is! KdbxEntry) continue;
      fieldDiffs.addAll(_diffEntry(uuid, localObject, remoteObject));
    }

    return KdbxPresenceDiff(recordDiffs: recordDiffs, fieldDiffs: fieldDiffs);
  }

  /// Applies [resolution] to the **local** side of [pair] and returns it as the
  /// merge candidate.
  ///
  /// **Why the local file is the base.** FR-1 forbids rebuilding a database
  /// from a lossy projection, and the cheapest way to keep every construct the
  /// library supports — header, KDF, history, custom icons, tombstones — is to
  /// never destroy the object that already holds them. So the candidate *is*
  /// the opened local file, mutated in place.
  ///
  /// **Being the base is not the same as winning.** An earlier version of this
  /// comment claimed metadata and recycle-bin settings were "kept", which was
  /// true of the local side and silently false of the remote one: a database
  /// renamed on one device lost its name on the next merge elsewhere, with no
  /// conflict, no decision and no refusal. Everything the base contributes is
  /// now either merged by an explicit rule ([_mergeMeta]) or listed there as
  /// deliberately not merged, with the reason.
  ///
  /// Two consequences, stated rather than discovered later:
  ///
  ///   * the pair is consumed by this call. `pair.local.file` is no longer the
  ///     local side afterwards, and the caller must not diff it again;
  ///   * nothing is written anywhere. The candidate lives in memory until
  ///     [serializeCandidate] turns it into bytes and T403 writes those bytes
  ///     under the mutex through `SafeVaultFileWriter`.
  ///
  /// What is applied, in this order and for these reasons:
  ///
  ///   0. **metadata**, by the per-field FR-3 join KDBX's own change clocks
  ///      make derivable;
  ///   1. **remote-only groups**, in pre-order so a parent exists before its
  ///      child needs it;
  ///   2. **remote-only entries**, which need their parent group to exist;
  ///   3. **fields of shared live entries** — automatic unions for the
  ///      one-sided rows, the resolved choice for the conflicts;
  ///   4. **record deletion decisions**, which move objects in and out of the
  ///      tree and must therefore run after the imports that may have created
  ///      them;
  ///   5. **tombstone union**, last, so it can see the final tree and skip any
  ///      UUID a Keep decision has just brought back to life.
  KdbxFile applyMerge({
    required KdbxMergePair pair,
    required KdbxPresenceDiff diff,
    required KdbxMergeResolution resolution,
  }) {
    final local = pair.local.file;
    final remote = pair.remote.file;

    // Captured BEFORE anything is mutated: the merge must never write a wall
    // clock into the candidate. See [_stampDeterministicTimes].
    final times = _captureTimes(local, remote);
    final keepStamps = <String, DateTime>{};

    _mergeMeta(local: local, remote: remote);

    for (final record in diff.recordDiffs) {
      if (record.classification != KdbxRecordClassification.recordRemoteOnly) {
        continue;
      }
      if (record.objectKind != KdbxMergeObjectKind.group) continue;
      _importGroup(local: local, remote: remote, groupUuid: record.objectUuid);
    }
    for (final record in diff.recordDiffs) {
      if (record.classification != KdbxRecordClassification.recordRemoteOnly) {
        continue;
      }
      if (record.objectKind != KdbxMergeObjectKind.entry) continue;
      _importEntry(local: local, remote: remote, entryUuid: record.objectUuid);
    }

    // FR-3a: an engaged credential block's SHARED members (`identical` and
    // `fieldConflict`) are handled exclusively by [_applyCredentialBlocks]
    // below, never by the general per-field loop — the whole point of
    // atomicity is that these three fields never consult an independent
    // per-field decision. A one-sided member is untouched by that exclusion
    // and flows through here as an ordinary automatic union, which is exactly
    // FR-4's no-deletion invariant applied to a block member.
    //
    // spec 023 T209 draws the same line around a `KPEX_PASSKEY_*` group, for
    // the same reason with a sharper edge: a per-field decision there could
    // take the private key from one side and the credential id from the other,
    // producing a credential neither device ever held (FR-008).
    final engagedBlocks = engagedCredentialBlockEntryUuids(diff);
    final engagedPasskeys = engagedPasskeyBlocks(diff);
    for (final field in diff.fieldDiffs) {
      if (_isEngagedCredentialBlockMember(field, engagedBlocks)) continue;
      if (_isEngagedPasskeyBlockMember(field, engagedPasskeys)) continue;
      _applyField(
        local: local,
        remote: remote,
        field: field,
        resolution: resolution,
      );
    }
    _applyCredentialBlocks(
      local: local,
      remote: remote,
      diff: diff,
      resolution: resolution,
      engagedEntryUuids: engagedBlocks,
    );
    _applyPasskeyBlocks(
      local: local,
      remote: remote,
      diff: diff,
      resolution: resolution,
      engagedBlocks: engagedPasskeys,
    );

    for (final record in diff.deletionConflicts) {
      _applyRecordDecision(
        local: local,
        remote: remote,
        record: record,
        choice: resolution.recordChoiceFor(record.objectUuid),
        keepStamps: keepStamps,
      );
    }

    _unionTombstones(local: local, remote: remote);
    _stampDeterministicTimes(local, times, keepStamps);
    return local;
  }

  /// FR-1's metadata, merged by the per-field FR-3 join instead of being taken
  /// wholesale from whichever side happened to be the base.
  ///
  /// **Why a merge and not a refusal.** KDBX stores a change clock *next to*
  /// each metadata field — `DatabaseNameChanged`, `DatabaseDescriptionChanged`,
  /// `DefaultUserNameChanged`, `RecycleBinChanged`, `EntryTemplatesGroupChanged`
  /// and `SettingsChanged` for the settings block — for exactly this purpose.
  /// The evidence FR-3's automatic policy needs therefore exists, which puts
  /// metadata in the same class as a value conflict with two known timestamps:
  /// resolved automatically, no decision, no new conflict category. Where the
  /// evidence did not exist this would have to be refused instead, and the
  /// frozen contract has no category for it — that is recorded as a finding,
  /// not worked around.
  ///
  /// The two clocks are compared, not the two values, and a tie falls back to
  /// FR-3's rule 3 (greater UTF-8 byte sequence wins) so the outcome does not
  /// depend on which side is calling itself "local".
  ///
  /// Order matters inside each block: the value is written first and its clock
  /// second, because `KdbxMeta` wires `setOnModifyListener` to stamp the clock
  /// with `DateTime.now()` on every write. Writing the clock afterwards is what
  /// keeps the merge free of the wall clock (see [_stampDeterministicTimes]).
  ///
  /// **Deliberately not merged**, each for a reason:
  ///   * `masterKeyChanged` — the credentials are not the merge's business, and
  ///     the library itself refuses to merge them. Adopting the other side's
  ///     clock would tell KeePass the key rotated when it did not.
  ///   * `generator` and `headerHash` — the writer's own identity and a header
  ///     digest, neither of which is content.
  void _mergeMeta({required KdbxFile local, required KdbxFile remote}) {
    final mine = local.body.meta;
    final theirs = remote.body.meta;

    if (_remoteWins(
      localAt: mine.databaseNameChanged.get(),
      remoteAt: theirs.databaseNameChanged.get(),
      localValue: mine.databaseName.get(),
      remoteValue: theirs.databaseName.get(),
    )) {
      mine.databaseName.set(theirs.databaseName.get());
      mine.databaseNameChanged.set(theirs.databaseNameChanged.get());
    }

    if (_remoteWins(
      localAt: mine.databaseDescriptionChanged.get(),
      remoteAt: theirs.databaseDescriptionChanged.get(),
      localValue: mine.databaseDescription.get(),
      remoteValue: theirs.databaseDescription.get(),
    )) {
      mine.databaseDescription.set(theirs.databaseDescription.get());
      mine.databaseDescriptionChanged.set(
        theirs.databaseDescriptionChanged.get(),
      );
    }

    if (_remoteWins(
      localAt: mine.defaultUserNameChanged.get(),
      remoteAt: theirs.defaultUserNameChanged.get(),
      localValue: mine.defaultUserName.get(),
      remoteValue: theirs.defaultUserName.get(),
    )) {
      mine.defaultUserName.set(theirs.defaultUserName.get());
      mine.defaultUserNameChanged.set(theirs.defaultUserNameChanged.get());
    }

    if (_remoteWins(
      localAt: mine.entryTemplatesGroupChanged.get(),
      remoteAt: theirs.entryTemplatesGroupChanged.get(),
      localValue: mine.entryTemplatesGroup.get()?.uuid,
      remoteValue: theirs.entryTemplatesGroup.get()?.uuid,
    )) {
      mine.entryTemplatesGroup.set(theirs.entryTemplatesGroup.get());
      mine.entryTemplatesGroupChanged.set(
        theirs.entryTemplatesGroupChanged.get(),
      );
    }

    // The recycle-bin block is one unit, because the enabled flag and the UUID
    // share `RecycleBinChanged`. This is also where the FUNCTIONAL half of the
    // bug lived: a device whose local side had no bin imported the other side's
    // bin group as an ordinary one-sided union while `recycleBinUUID` stayed
    // null, so the vault showed an orphan group full of deleted entries in the
    // normal tree and the next delete created a second bin beside it.
    if (_remoteWins(
      localAt: mine.recycleBinChanged.get(),
      remoteAt: theirs.recycleBinChanged.get(),
      localValue:
          '${mine.recycleBinEnabled.get()}|'
          '${mine.recycleBinUUID.get()?.uuid}',
      remoteValue:
          '${theirs.recycleBinEnabled.get()}|'
          '${theirs.recycleBinUUID.get()?.uuid}',
    )) {
      mine.recycleBinEnabled.set(theirs.recycleBinEnabled.get());
      mine.recycleBinUUID.set(theirs.recycleBinUUID.get());
      mine.recycleBinChanged.set(theirs.recycleBinChanged.get());
    }

    // History limits and maintenance days share `SettingsChanged`, which is
    // also the only evidence `customData` has — it is a plain string map with
    // no per-key clock. Both clocks are read BEFORE the block below can
    // overwrite the local one.
    final localSettingsAt = mine.settingsChanged.get();
    final remoteSettingsAt = theirs.settingsChanged.get();
    final settingsToRemote = _remoteWins(
      localAt: mine.settingsChanged.get(),
      remoteAt: theirs.settingsChanged.get(),
      localValue:
          '${mine.historyMaxItems.get()}|'
          '${mine.historyMaxSize.get()}|'
          '${mine.maintenanceHistoryDays.get()}',
      remoteValue:
          '${theirs.historyMaxItems.get()}|'
          '${theirs.historyMaxSize.get()}|'
          '${theirs.maintenanceHistoryDays.get()}',
    );
    if (settingsToRemote) {
      mine.historyMaxItems.set(theirs.historyMaxItems.get());
      mine.historyMaxSize.set(theirs.historyMaxSize.get());
      mine.maintenanceHistoryDays.set(theirs.maintenanceHistoryDays.get());
      mine.settingsChanged.set(theirs.settingsChanged.get());
    }

    // Custom data: a key union, because a key only one side has is a one-sided
    // field and FR-4 preserves those automatically. A key both sides hold with
    // different values falls to `SettingsChanged`, then to the value order.
    for (final entry in theirs.customData.entries) {
      final ours = mine.customData[entry.key];
      if (ours == null) {
        mine.customData[entry.key] = entry.value;
        continue;
      }
      if (ours == entry.value) continue;
      if (_remoteWins(
        localAt: localSettingsAt,
        remoteAt: remoteSettingsAt,
        localValue: ours,
        remoteValue: entry.value,
      )) {
        mine.customData[entry.key] = entry.value;
      }
    }

    // Custom icons: a plain union by UUID, which is idempotent and
    // commutative. `_copyCustomIcon` only carries the icons an imported object
    // references; an icon the remote holds for a record that stayed put would
    // otherwise be dropped.
    for (final icon in theirs.customIcons.values) {
      mine.addCustomIcon(icon);
    }
  }

  /// FR-3's order, applied to one metadata field: newer known clock wins,
  /// a known clock beats an unknown one, and an exact tie falls to the greater
  /// UTF-8 byte sequence so neither perspective is privileged.
  bool _remoteWins({
    required DateTime? localAt,
    required DateTime? remoteAt,
    required String? localValue,
    required String? remoteValue,
  }) {
    if (localAt != null && remoteAt != null) {
      if (remoteAt.isAfter(localAt)) return true;
      if (localAt.isAfter(remoteAt)) return false;
    } else if (remoteAt != null) {
      return true;
    } else if (localAt != null) {
      return false;
    }
    return compareUtf8Bytes(remoteValue ?? '', localValue ?? '') > 0;
  }

  /// Both sides' object times, per UUID, before the merge touches anything.
  Map<String, _ObjectTimes> _captureTimes(KdbxFile local, KdbxFile remote) {
    final captured = <String, _ObjectTimes>{};
    for (final file in [local, remote]) {
      for (final object in file.body.rootGroup.getAllGroupsAndEntries()) {
        final existing = captured[object.uuid.uuid] ?? const _ObjectTimes();
        captured[object.uuid.uuid] = existing.joinedWith(
          modifiedAt: object.times.lastModificationTime.get(),
          locationChangedAt: object.times.locationChanged.get(),
        );
      }
    }
    return captured;
  }

  /// FR-3, applied to timestamps: **every time the merge writes is a function
  /// of the two inputs, never of the local clock.**
  ///
  /// This is not tidiness. `parent.addEntry` / `addGroup` and `setString` all
  /// route through `Changeable.modify`, which stamps the object with
  /// `DateTime.now()`. So importing a one-sided record re-dated the group that
  /// received it, and taking a remote field value re-dated the entry — and two
  /// devices never merge in the same second, so their candidates differed on
  /// exactly those objects, forever. Measured as a ~27% flake in the
  /// commutativity test and reproduced deterministically by separating the two
  /// devices by three seconds.
  ///
  /// It is the same defect class FR-3 identifies for values, in the dimension
  /// nobody looks at: a merge whose output depends on *when* it ran is not
  /// commutative, so the FR-7 semantic short-circuit never fires and each
  /// device rewrites the other's result on every round.
  ///
  /// The rule is FR-3's own join: the merged object's time is the **newer of
  /// the two sides' known times**, which is exactly "the winning side's
  /// timestamp travels with the winning value" at the granularity KDBX
  /// actually stores (there is no per-field time). A one-sided object keeps
  /// the single known time, which is its source's.
  ///
  /// **Known imprecision, and its direction.** Under an explicit user override
  /// the winning VALUE may be the older side's while the stamp is still the max
  /// of the two, so the merged record claims a modification time newer than the
  /// value it carries. KDBX offers nowhere finer to record it — there is one
  /// time per object, not per field — and the damage direction is conservative:
  /// an inflated mtime makes T009b's G1 ("a tombstone matches when it is
  /// strictly newer than the live mtime") fire LESS often, so the bias is
  /// toward preserving the record. The opposite bias would delete.
  ///
  /// Two deliberate exceptions, both already deterministic:
  ///   * [keepStamps] — FR-5 Keep re-dates the record at the tombstone's clock
  ///     (T009b G2), and that must win over the join or the tombstone starts
  ///     matching again on the next peer;
  ///   * a **fresh** deletion emitted by an explicit Delete keeps the wall
  ///     clock. A Delete is a user decision taken at a real moment and is
  ///     per-device by T009b's G4. This is only sound because
  ///     [_unionTombstones] really does take the max of the two clocks — the
  ///     first version of that method did not, and this exception was ratified
  ///     on the strength of a convergence it did not have.
  void _stampDeterministicTimes(
    KdbxFile candidate,
    Map<String, _ObjectTimes> times,
    Map<String, DateTime> keepStamps,
  ) {
    for (final object in candidate.body.rootGroup.getAllGroupsAndEntries()) {
      final captured = times[object.uuid.uuid];
      if (captured == null) continue;
      final modifiedAt = keepStamps[object.uuid.uuid] ?? captured.modifiedAt;
      if (modifiedAt != null) {
        object.times.lastModificationTime.set(modifiedAt);
      }
      if (captured.locationChangedAt != null) {
        object.times.locationChanged.set(captured.locationChangedAt);
      }
    }
  }

  /// FR-1's serialization parity gate: serialize the candidate, reopen it with
  /// the **original credentials**, and refuse unless the reopened file carries
  /// the same canonical semantic manifest.
  ///
  /// The comparison is semantic and never on bytes: salts, IVs and the master
  /// seed are redrawn on every save, so two serializations of one file are
  /// never byte-equal and a byte check would refuse every candidate. A
  /// mismatch is [MergeFailureCode.serializationParityFailed] — the candidate
  /// is discarded and no target is touched.
  Future<Uint8List> serializeCandidate({
    required KdbxFile candidate,
    required Credentials credentials,
  }) async {
    final expected = kdbxSemanticManifest(candidate);
    final bytes = Uint8List.fromList(await candidate.save());

    final KdbxFile reopened;
    try {
      // A full decrypt of the bytes with [credentials]. The candidate's
      // derived key is reused only if the candidate was opened with these
      // same credentials, which the library checks; the key is what the KDF
      // would produce again, so the check is unchanged.
      reopened = await _format().read(bytes, credentials, keySource: candidate);
    } on Object {
      throw const SyncMergeFailure(MergeFailureCode.serializationParityFailed);
    }
    if (kdbxManifestDigest(kdbxSemanticManifest(reopened)) !=
        kdbxManifestDigest(expected)) {
      throw const SyncMergeFailure(MergeFailureCode.serializationParityFailed);
    }
    return bytes;
  }

  // ------------------------------------------------------------------ private

  void _importGroup({
    required KdbxFile local,
    required KdbxFile remote,
    required String groupUuid,
  }) {
    final source = _groupByUuid(remote, groupUuid);
    if (source == null) return;
    final parentUuid = source.parent?.uuid.uuid;
    // A remote-only ROOT group is impossible: lineage was verified, so the two
    // roots share a UUID and the root is never one-sided.
    final parent = parentUuid == null
        ? local.body.rootGroup
        : _groupByUuid(local, parentUuid) ?? local.body.rootGroup;

    final imported = KdbxGroup.create(
      ctx: local.ctx,
      parent: parent,
      name: source.name.get(),
    );
    parent.addGroup(imported);
    // Graft the source's own XML rather than copying a hand-written list of
    // fields: `KdbxNode.node` holds every construct the library models AND the
    // ones it does not, so a field nobody remembered is carried anyway. The
    // container elements are excluded because `toXml` regenerates them from
    // the live child lists, and `Times` because it is a separate `KdbxNode`
    // with its own element.
    _graftChildren(
      from: source,
      to: imported,
      skip: const {'Group', 'Entry', 'Times'},
    );
    _graftChildren(from: source.times, to: imported.times);
    imported.forceSetUuid(source.uuid);
    _copyCustomIcon(local: local, remote: remote, object: imported);
  }

  void _importEntry({
    required KdbxFile local,
    required KdbxFile remote,
    required String entryUuid,
  }) {
    final source = _entryByUuid(remote, entryUuid);
    if (source == null) return;
    final parentUuid = source.parent?.uuid.uuid;
    final parent = parentUuid == null
        ? local.body.rootGroup
        : _groupByUuid(local, parentUuid) ?? local.body.rootGroup;

    // `cloneInto` is the Gate 0 T003 primitive: it carries strings, binaries
    // (re-registered in the target file's binary pool), custom data, times,
    // colors, tags, override URL, icons and history.
    final imported = source.cloneInto(parent);
    // ...but not the constructs the library does not model. Gate 0 found
    // exactly one on an entry: `AutoType`. Grafting it keeps the auto-type
    // sequence and window associations of an imported record.
    _graftChildren(from: source, to: imported, only: const {'AutoType'});
    _copyCustomIcon(local: local, remote: remote, object: imported);
  }

  void _copyCustomIcon({
    required KdbxFile local,
    required KdbxFile remote,
    required KdbxObject object,
  }) {
    final iconUuid = object.customIconUuid.get();
    if (iconUuid == null) return;
    if (local.body.meta.customIcons.containsKey(iconUuid)) return;
    final icon = remote.body.meta.customIcons[iconUuid];
    if (icon != null) local.body.meta.addCustomIcon(icon);
  }

  void _applyField({
    required KdbxFile local,
    required KdbxFile remote,
    required KdbxFieldDiff field,
    required KdbxMergeResolution resolution,
  }) {
    final localEntry = _entryByUuid(local, field.entryUuid);
    final remoteEntry = _entryByUuid(remote, field.entryUuid);
    if (localEntry == null || remoteEntry == null) return;

    switch (field.classification) {
      case KdbxFieldClassification.identical:
        // Value already correct; FR-4 preserves it with no decision. A
        // divergent key SPELLING is the one thing still undecided on this
        // row (T401a) — resolved deterministically, never "keep local".
        _reconcileKeySpelling(localEntry, field);
        return;
      case KdbxFieldClassification.fieldLocalOnly:
        // Already in the candidate; FR-4 preserves it with no decision.
        return;
      case KdbxFieldClassification.fieldRemoteOnly:
        _takeRemote(localEntry, remoteEntry, field);
        return;
      case KdbxFieldClassification.fieldConflict:
        final choice = resolution.fieldChoiceFor(field);
        switch (choice) {
          case MergeChoice.local:
            // The VALUE is already the candidate's; only the key spelling is
            // still open, and it is decided by the same deterministic order
            // as every other row — not by which side happened to be local.
            _reconcileKeySpelling(localEntry, field);
            return;
          case MergeChoice.remote:
            _takeRemote(localEntry, remoteEntry, field);
            return;
          case MergeChoice.bothNotes:
            _reconcileKeySpelling(localEntry, field);
            localEntry.setString(
              KdbxKey(_survivingKeySpelling(field)),
              PlainValue(
                notesSegmentUnion(
                  localEntry.getString(KdbxKey(field.localKey!))?.getText() ??
                      '',
                  remoteEntry.getString(KdbxKey(field.remoteKey!))?.getText() ??
                      '',
                ),
              ),
            );
            return;
          case MergeChoice.keep:
          case MergeChoice.delete:
            // Unrepresentable: `RedactedMergeDecision` refuses keep/delete on a
            // value conflict, so reaching here means the resolution was built
            // outside the domain invariants.
            throw StateError('keep/delete is not a value-conflict choice');
        }
    }
  }

  /// Copies the remote side of one field onto the candidate.
  ///
  /// The surviving key spelling is [_survivingKeySpelling]'s, NOT the local
  /// one: "keep local" here was the perspective-dependent default FR-3
  /// forbids. Two mirrored devices resolve the same conflict to the same
  /// VALUE but from opposite sides — one runs this method, the other takes
  /// the `MergeChoice.local` branch — so a local-preferring spelling left
  /// them holding two different verbatim keys forever. Where only the remote
  /// side has the field, its spelling is preserved verbatim (FR-1).
  ///
  /// [_reconcileKeySpelling] runs first because `Map[]=` keeps the EXISTING
  /// key object on an equal key and [KdbxKey] compares case-insensitively:
  /// writing under the winning spelling without renaming first would silently
  /// retain the local one.
  void _takeRemote(
    KdbxEntry localEntry,
    KdbxEntry remoteEntry,
    KdbxFieldDiff field,
  ) {
    _reconcileKeySpelling(localEntry, field);
    final targetKey = KdbxKey(_survivingKeySpelling(field));
    final sourceKey = KdbxKey(field.remoteKey!);

    switch (field.fieldKind) {
      case KdbxMergeFieldKind.string:
        localEntry.setString(targetKey, remoteEntry.getString(sourceKey));
      case KdbxMergeFieldKind.attachment:
        final binary = remoteEntry.getBinary(sourceKey);
        if (binary == null) return;
        if (localEntry.getBinary(targetKey) != null) {
          // `createBinary` uniquifies a colliding name, which would silently
          // produce `doc1.pdf` beside `doc.pdf` instead of replacing it.
          localEntry.removeBinary(targetKey);
        }
        localEntry.createBinary(
          isProtected: binary.isProtected,
          name: targetKey.key,
          bytes: binary.value,
        );
    }
  }

  /// The verbatim key spelling a shared field keeps (T401a).
  ///
  /// One side only: that side's spelling, verbatim (FR-1). Both sides
  /// spelling the same canonical key differently: FR-3's UTF-8 order applied
  /// to the two spellings themselves — greater wins — never "keep local",
  /// which is the exact perspective-dependent default FR-3 forbids for
  /// values, and there is no reason a key spelling should be exempt.
  ///
  /// It is deliberately independent of which side won the VALUE: `bothNotes`
  /// and the `identical` row have no winning side at all, so a
  /// value-following rule is not even expressible there. (FR-3a's credential
  /// block does follow its block winner — see [_applyCredentialBlocks] — but
  /// that block always has one, and its members never reach this method.)
  String _survivingKeySpelling(KdbxFieldDiff field) {
    final localKey = field.localKey;
    final remoteKey = field.remoteKey;
    if (localKey == null) return remoteKey!;
    if (remoteKey == null) return localKey;
    return compareUtf8Bytes(remoteKey, localKey) > 0 ? remoteKey : localKey;
  }

  /// Renames the candidate's key to [_survivingKeySpelling] where the two
  /// sides spell it differently. Nothing here decides values.
  ///
  /// [KdbxEntry.renameKey] stamps a wall clock through `Changeable.modify`
  /// like every other mutator here; [_stampDeterministicTimes] corrects it at
  /// the end of [applyMerge], so no special-casing is needed here.
  void _reconcileKeySpelling(KdbxEntry localEntry, KdbxFieldDiff field) {
    if (!field.keySpellingDiverges) return;
    final localKey = field.localKey!;
    final survivingKey = _survivingKeySpelling(field);
    if (survivingKey == localKey) return; // local's spelling already wins

    switch (field.fieldKind) {
      case KdbxMergeFieldKind.string:
        localEntry.renameKey(KdbxKey(localKey), KdbxKey(survivingKey));
      case KdbxMergeFieldKind.attachment:
        final binary = localEntry.getBinary(KdbxKey(localKey));
        if (binary == null) return;
        localEntry.removeBinary(KdbxKey(localKey));
        localEntry.createBinary(
          isProtected: binary.isProtected,
          name: survivingKey,
          bytes: binary.value,
        );
    }
  }

  /// True for a field the general per-field loop must skip because FR-3a's
  /// atomic block owns it instead — a SHARED member (`identical` or
  /// `fieldConflict`) of an entry whose block is engaged. A one-sided member
  /// is never true here: FR-4's no-deletion invariant is unaffected by
  /// atomicity, and the general loop's own union handling is what preserves
  /// it.
  bool _isEngagedCredentialBlockMember(
    KdbxFieldDiff field,
    Set<String> engagedEntryUuids,
  ) {
    if (field.fieldKind != KdbxMergeFieldKind.string) return false;
    if (!isCredentialBlockKey(field.canonicalKey)) return false;
    if (!engagedEntryUuids.contains(field.entryUuid)) return false;
    return field.classification == KdbxFieldClassification.identical ||
        field.classification == KdbxFieldClassification.fieldConflict;
  }

  /// FR-3a: for every engaged block, every SHARED member (value, protection
  /// flag and verbatim key spelling all travel together, by copying the
  /// winning side's `StringValue` object wholesale — the same trick
  /// [_takeRemote] uses) is taken from [resolution]'s single answer for the
  /// whole entry. A one-sided member is left alone: it was never a candidate
  /// for this method, having been excluded from the very diff this iterates
  /// (see [_isEngagedCredentialBlockMember]'s converse in [applyMerge]).
  void _applyCredentialBlocks({
    required KdbxFile local,
    required KdbxFile remote,
    required KdbxPresenceDiff diff,
    required KdbxMergeResolution resolution,
    required Set<String> engagedEntryUuids,
  }) {
    for (final entryUuid in engagedEntryUuids) {
      final localEntry = _entryByUuid(local, entryUuid);
      final remoteEntry = _entryByUuid(remote, entryUuid);
      if (localEntry == null || remoteEntry == null) continue;

      final winnerIsLocal =
          resolution.credentialBlockChoiceFor(entryUuid) == MergeChoice.local;

      for (final field in credentialBlockFieldsOf(diff, entryUuid)) {
        if (field.local is! KdbxFieldPresent ||
            field.remote is! KdbxFieldPresent) {
          continue; // one-sided: preserved by the general loop already.
        }
        final targetKey = winnerIsLocal ? field.localKey! : field.remoteKey!;
        final sourceEntry = winnerIsLocal ? localEntry : remoteEntry;
        final winningValue = sourceEntry.getString(KdbxKey(targetKey));
        if (field.localKey != null && field.localKey != targetKey) {
          localEntry.removeString(KdbxKey(field.localKey!));
        }
        localEntry.setString(KdbxKey(targetKey), winningValue);
      }
    }
  }

  /// spec 023 T209's counterpart to [_isEngagedCredentialBlockMember]: EVERY
  /// member of an engaged passkey group, which [_applyPasskeyBlocks] owns
  /// outright.
  ///
  /// **Unlike the credential block, one-sided members are claimed too**, and
  /// that asymmetry is the whole point. FR-3a's block is a closed set of the
  /// entry's own fields (`username`/`password`/`url`): a member present on one
  /// side only is simply a field the other side lacks, and FR-4's no-deletion
  /// invariant says preserve it. A `KPEX_PASSKEY_*` member is not the entry's
  /// field, it is *part of one credential*. Leaving a one-sided member to the
  /// general loop's union attaches it to whichever credential won — so a
  /// `KPEX_PASSKEY_USER_HANDLE` or `KPEX_PASSKEY_PRF` written only on the
  /// losing side would end up beside the winner's key and id. That is exactly
  /// the mixed credential FR-008 forbids, and it fails in the worst way: the
  /// group still parses, so sign-in is attempted and the relying party rejects
  /// a handle it never issued.
  ///
  /// A group that is NOT engaged is untouched by this and flows through the
  /// general loop, so a passkey present on one side only is still preserved
  /// whole.
  bool _isEngagedPasskeyBlockMember(
    KdbxFieldDiff field,
    Set<KdbxPasskeyBlockRef> engagedBlocks,
  ) {
    final ref = kdbxPasskeyBlockRefOf(field);
    return ref != null && engagedBlocks.contains(ref);
  }

  /// spec 023 T209: an engaged passkey group ends up holding **exactly the
  /// winning side's members** — nothing of the loser's survives beside them.
  ///
  /// The winner's members are copied by taking its `StringValue` object
  /// wholesale, so the protection flag travels with the value and the secret is
  /// never read into a Dart string here, exactly as in
  /// [_applyCredentialBlocks]. A member the winner does not have is REMOVED
  /// from local when local is the side carrying it, and simply not copied when
  /// the loser is remote.
  ///
  /// That removal is a deliberate exception to FR-4's no-deletion invariant,
  /// and the narrowest one that works: what is dropped is one member of a
  /// credential the user chose to replace, not a field of the entry and not the
  /// credential the user kept. Preserving it instead would leave one
  /// credential's user handle or PRF secret attached to another credential's
  /// key — a group that parses, attempts a sign-in, and is refused by the
  /// relying party (FR-008).
  void _applyPasskeyBlocks({
    required KdbxFile local,
    required KdbxFile remote,
    required KdbxPresenceDiff diff,
    required KdbxMergeResolution resolution,
    required Set<KdbxPasskeyBlockRef> engagedBlocks,
  }) {
    for (final ref in engagedBlocks) {
      final localEntry = _entryByUuid(local, ref.entryUuid);
      final remoteEntry = _entryByUuid(remote, ref.entryUuid);
      if (localEntry == null || remoteEntry == null) continue;

      final winnerIsLocal =
          resolution.passkeyBlockChoiceFor(ref) == MergeChoice.local;

      for (final field in passkeyBlockFieldsOf(diff, ref)) {
        final winnerPresence = winnerIsLocal ? field.local : field.remote;
        final winnerKey = winnerIsLocal ? field.localKey : field.remoteKey;
        final localKey = field.localKey;

        if (winnerPresence is! KdbxFieldPresent || winnerKey == null) {
          // The winning credential has no such member. Drop local's copy if it
          // has one; a remote-only member is never added, because this method
          // owns every member of an engaged group and the general loop skips
          // them all.
          if (localKey != null) localEntry.removeString(KdbxKey(localKey));
          continue;
        }

        final sourceEntry = winnerIsLocal ? localEntry : remoteEntry;
        final winningValue = sourceEntry.getString(KdbxKey(winnerKey));
        if (localKey != null && localKey != winnerKey) {
          localEntry.removeString(KdbxKey(localKey));
        }
        localEntry.setString(KdbxKey(winnerKey), winningValue);
      }
    }
  }

  /// FR-5 Keep/Delete on one record.
  void _applyRecordDecision({
    required KdbxFile local,
    required KdbxFile remote,
    required KdbxRecordDiff record,
    required MergeChoice choice,
    required Map<String, DateTime> keepStamps,
  }) {
    switch (choice) {
      case MergeChoice.keep:
        _applyKeep(
          local: local,
          remote: remote,
          record: record,
          keepStamps: keepStamps,
        );
      case MergeChoice.delete:
        _applyDelete(local: local, record: record);
      case MergeChoice.local:
      case MergeChoice.remote:
      case MergeChoice.bothNotes:
        throw StateError('a deletion conflict is answered keep/delete only');
    }
  }

  void _applyKeep({
    required KdbxFile local,
    required KdbxFile remote,
    required KdbxRecordDiff record,
    required Map<String, DateTime> keepStamps,
  }) {
    final uuid = record.objectUuid;
    var object = _objectByUuid(local, uuid);

    if (object == null) {
      // Tombstoned locally, live remotely: import it back.
      if (record.objectKind == KdbxMergeObjectKind.group) {
        _importGroup(local: local, remote: remote, groupUuid: uuid);
      } else {
        _importEntry(local: local, remote: remote, entryUuid: uuid);
      }
      object = _objectByUuid(local, uuid);
    } else if (record.local.evidence == KdbxRecordEvidence.recycled) {
      // Binned locally, live remotely: put it back where the live side has it.
      final remoteParentUuid = _objectByUuid(remote, uuid)?.parent?.uuid.uuid;
      final target = remoteParentUuid == null
          ? local.body.rootGroup
          : _groupByUuid(local, remoteParentUuid) ?? local.body.rootGroup;
      KdbxDao(local).move(object, target);
    }
    if (object == null) return;

    // FR-5: Keep "removes/neutralizes matching tombstone". T009b gap G2: simply
    // dropping the tombstone locally lets a peer that still holds it
    // re-introduce the conflict on the next sync, forever. So the live object
    // is also re-stamped at the tombstone's own clock, which under G1/G3 makes
    // the tombstone non-matching on *every* device, deterministically — while
    // the tombstone evidence stays retained wherever it exists, so the join
    // remains monotone.
    final deletedAt = record.local.deletedAtUtc ?? record.remote.deletedAtUtc;
    if (deletedAt != null) {
      keepStamps[uuid] = deletedAt;
    }
    _removeTombstone(local, uuid);
  }

  void _applyDelete({required KdbxFile local, required KdbxRecordDiff record}) {
    final object = _objectByUuid(local, record.objectUuid);
    if (object != null && object.parent != null) {
      // `deletePermanently` removes the object and emits the tombstone in one
      // step, for the object and — on a group — for everything under it.
      KdbxDao(local).deletePermanently(object);
      return;
    }
    if (!tombstonesOf(local).containsKey(record.objectUuid)) {
      _addTombstone(
        local,
        record.objectUuid,
        record.remote.deletedAtUtc ?? record.local.deletedAtUtc,
      );
    }
  }

  /// Emits a tombstone carrying [deletedAt].
  ///
  /// `KdbxReadWriteContext.addDeletedObject` declares a `now` parameter and
  /// then **drops it** (kdbx 2.5.0, `kdbx_format.dart:119`: it calls
  /// `KdbxDeletedObject.create(this, uuid)` without forwarding it), so every
  /// tombstone it emits is stamped with the current clock. That silently
  /// rewrites the deletion time of a tombstone copied from the other side,
  /// which is the one piece of data FR-5's "preserve newest supported deletion
  /// data" is about, and which T009b's G1 uses to decide whether a tombstone
  /// still matches. The clock is therefore re-applied on the object the call
  /// just appended.
  void _addTombstone(KdbxFile file, String uuid, DateTime? deletedAt) {
    file.ctx.addDeletedObject(KdbxUuid(uuid));
    if (deletedAt == null) return;
    // ignore: invalid_use_of_visible_for_testing_member
    final emitted = file.body.deletedObjects.lastWhere(
      (o) => o.uuid.uuid == uuid,
    );
    emitted.deletionTime.set(deletedAt);
  }

  /// FR-5 "preserve newest supported deletion data" — the **max** of the two
  /// deletion clocks, not "keep whichever one we already had".
  ///
  /// The earlier version returned early whenever the UUID was already
  /// tombstoned locally, so a tombstone the remote held with a NEWER clock was
  /// discarded. Two devices deleting the same record seconds apart therefore
  /// each froze their own clock and never converged — measured across three
  /// rounds — while this method's own doc comment claimed the opposite. The
  /// vault CONTENT still converged, because both clocks sit above the live
  /// mtime and T009b's G1 classifies identically on both devices; what
  /// diverged was `DeletedObjects` and therefore the canonical manifest, which
  /// is what FR-7 step 5 arbitrates on.
  ///
  /// A UUID that is live in the candidate is skipped: a Keep decision or a
  /// one-sided union just established that the record exists.
  void _unionTombstones({required KdbxFile local, required KdbxFile remote}) {
    final existing = tombstonesOf(local);
    final live = {
      for (final object in local.body.rootGroup.getAllGroupsAndEntries())
        object.uuid.uuid,
    };
    tombstonesOf(remote).forEach((uuid, deletedAt) {
      if (live.contains(uuid)) return;
      if (!existing.containsKey(uuid)) {
        _addTombstone(local, uuid, deletedAt);
        return;
      }
      if (deletedAt == null) return;
      final mine = existing[uuid];
      if (mine != null && !deletedAt.isAfter(mine)) return;
      // ignore: invalid_use_of_visible_for_testing_member
      local.body.deletedObjects
          .firstWhere((o) => o.uuid.uuid == uuid)
          .deletionTime
          .set(deletedAt);
    });
  }

  void _removeTombstone(KdbxFile file, String uuid) {
    // ignore: invalid_use_of_visible_for_testing_member
    file.body.deletedObjects.removeWhere((o) => o.uuid.uuid == uuid);
  }

  /// Copies element children of [from]'s XML into [to]'s, replacing same-named
  /// ones.
  ///
  /// Takes the `KdbxNode`s rather than the `XmlElement`s so that `xml` does not
  /// become a direct dependency of this package: it is kdbx's own transitive
  /// dependency, and `KdbxNode.node` is a public, exported member, so the
  /// elements are reachable through inference without naming the type.
  void _graftChildren({
    required KdbxNode from,
    required KdbxNode to,
    Set<String> skip = const {},
    Set<String>? only,
  }) {
    for (final child in from.node.childElements.toList()) {
      final name = child.name.local;
      if (skip.contains(name)) continue;
      if (only != null && !only.contains(name)) continue;
      for (final existing in to.node.childElements.toList()) {
        if (existing.name.local == name) to.node.children.remove(existing);
      }
      to.node.children.add(child.copy());
    }
  }

  KdbxObject? _objectByUuid(KdbxFile file, String uuid) {
    for (final object in file.body.rootGroup.getAllGroupsAndEntries()) {
      if (object.uuid.uuid == uuid) return object;
    }
    return null;
  }

  KdbxGroup? _groupByUuid(KdbxFile file, String uuid) {
    final object = _objectByUuid(file, uuid);
    return object is KdbxGroup ? object : null;
  }

  KdbxEntry? _entryByUuid(KdbxFile file, String uuid) {
    final object = _objectByUuid(file, uuid);
    return object is KdbxEntry ? object : null;
  }

  /// FR-5's record table, with T009b's temporal reading of "matching".
  ///
  /// The one row that is not a direct transcription of the spec table is
  /// `live` against `tombstoned`: T009b's gaps G1/G3 resolved "matching" as
  /// **strictly newer than the live side's modification time**, so an edit at
  /// or after the deletion clock is proof of life and supersedes the tombstone,
  /// and an equal clock breaks toward preservation. An *unknown* modification
  /// time carries no such proof, so a tombstone always matches it — FR-3's
  /// "unknown never outranks evidence", applied to deletion. That model is the
  /// gate this implementation has to be coherent with, not an invention here.
  KdbxRecordClassification _classifyRecord(
    KdbxRecordSide local,
    KdbxRecordSide remote,
  ) {
    if (local.evidence == KdbxRecordEvidence.live &&
        remote.evidence == KdbxRecordEvidence.live) {
      return KdbxRecordClassification.sharedLive;
    }
    if (!local.isLiveSomewhere && !remote.isLiveSomewhere) {
      return KdbxRecordClassification.recordDeleted;
    }
    if (local.isLiveSomewhere && remote.isLiveSomewhere) {
      // At least one side has it binned (the other is live or binned too):
      // bin-vs-live is FR-5's explicit move-to-bin conflict, bin-vs-bin is
      // deleted on both.
      return local.evidence == remote.evidence
          ? KdbxRecordClassification.recordDeleted
          : KdbxRecordClassification.recordDeletionConflict;
    }

    final liveSide = local.isLiveSomewhere ? local : remote;
    final otherSide = local.isLiveSomewhere ? remote : local;
    final liveOnLocal = local.isLiveSomewhere;

    if (otherSide.evidence == KdbxRecordEvidence.tombstoned &&
        _tombstoneMatches(liveSide, otherSide)) {
      return KdbxRecordClassification.recordDeletionConflict;
    }
    // Either plain absence (FR-4: never deletion evidence) or a tombstone the
    // live side's later edit superseded. Both preserve the record.
    return liveOnLocal
        ? KdbxRecordClassification.recordLocalOnly
        : KdbxRecordClassification.recordRemoteOnly;
  }

  bool _tombstoneMatches(KdbxRecordSide live, KdbxRecordSide tomb) {
    final deletedAt = tomb.deletedAtUtc;
    if (deletedAt == null) return true;
    final modifiedAt = live.modifiedAtUtc;
    if (modifiedAt == null) return true;
    return deletedAt.isAfter(modifiedAt);
  }

  _SideEvidence _sideEvidence(KdbxMergeSide side) {
    final file = side.file;
    final binned = _recycleBinMemberUuids(file);
    final objects = <String, KdbxObject>{
      for (final object in file.body.rootGroup.getAllGroupsAndEntries())
        object.uuid.uuid: object,
    };
    return _SideEvidence(
      objects: objects,
      binnedUuids: binned,
      tombstones: tombstonesOf(file),
    );
  }

  /// Every object inside the recycle-bin subtree, the bin group itself
  /// excluded.
  ///
  /// The bin group is a container, not a deleted record: it is preserved like
  /// any other group, and only what the user put *into* it counts as a
  /// move-to-bin.
  Set<String> _recycleBinMemberUuids(KdbxFile file) {
    // Resolved here rather than through `KdbxFile.recycleBin`, which MEMOIZES
    // its answer on first call. Reading it during the diff would cache "this
    // file has no bin" and that stale null would survive `_mergeMeta` adopting
    // the other side's bin, so the candidate would carry a correct
    // `RecycleBinUUID` while the in-memory object still denied having one.
    final binUuid = file.body.meta.recycleBinUUID.get();
    if (binUuid == null || binUuid.isNil) return const <String>{};
    final bin = _groupByUuid(file, binUuid.uuid);
    if (bin == null) return const <String>{};
    return {
      for (final object in bin.getAllGroupsAndEntries())
        if (object.uuid != bin.uuid) object.uuid.uuid,
    };
  }

  KdbxMergeSide _validateSide(KdbxFile file) {
    final kinds = <String, KdbxMergeObjectKind>{};

    for (final object in file.body.rootGroup.getAllGroupsAndEntries()) {
      final uuid = object.uuid;
      if (uuid.isNil) {
        throw const SyncMergeFailure(MergeFailureCode.unsupportedKdbxData);
      }
      final kind = object is KdbxGroup
          ? KdbxMergeObjectKind.group
          : KdbxMergeObjectKind.entry;
      // One map for both collections, so a duplicate group UUID, a duplicate
      // entry UUID and a group/entry collision are the same single check.
      // FR-2 requires global uniqueness; three separate per-collection checks
      // is how the collision case gets forgotten.
      if (kinds.containsKey(uuid.uuid)) {
        throw const SyncMergeFailure(MergeFailureCode.unsupportedKdbxData);
      }
      kinds[uuid.uuid] = kind;
    }

    return KdbxMergeSide._(file, Map.unmodifiable(kinds));
  }

  Iterable<KdbxFieldDiff> _diffEntry(
    String entryUuid,
    KdbxEntry local,
    KdbxEntry remote,
  ) sync* {
    // Keyed by the CANONICAL key, because that is what KDBX matches on. The
    // verbatim spelling travels as payload so FR-1's "original key spelling"
    // is preserved for both sides.
    yield* _classifyAll(
      entryUuid,
      KdbxMergeFieldKind.string,
      {
        for (final e in local.stringEntries)
          canonicalFieldKey(e.key.key): (
            spelling: e.key.key,
            present: KdbxFieldPresent.string(e.value),
          ),
      },
      {
        for (final e in remote.stringEntries)
          canonicalFieldKey(e.key.key): (
            spelling: e.key.key,
            present: KdbxFieldPresent.string(e.value),
          ),
      },
    );
    yield* _classifyAll(
      entryUuid,
      KdbxMergeFieldKind.attachment,
      {
        for (final e in local.binaryEntries)
          canonicalFieldKey(e.key.key): (
            spelling: e.key.key,
            present: KdbxFieldPresent.attachment(e.value),
          ),
      },
      {
        for (final e in remote.binaryEntries)
          canonicalFieldKey(e.key.key): (
            spelling: e.key.key,
            present: KdbxFieldPresent.attachment(e.value),
          ),
      },
    );
  }

  Iterable<KdbxFieldDiff> _classifyAll(
    String entryUuid,
    KdbxMergeFieldKind fieldKind,
    Map<String, ({String spelling, KdbxFieldPresent present})> local,
    Map<String, ({String spelling, KdbxFieldPresent present})> remote,
  ) sync* {
    // Sorted by canonical key so the diff is deterministic AND identical on
    // both devices; FR-3's convergence argument needs two devices to produce
    // the same evidence in the same order, and sorting by a per-side verbatim
    // spelling would not be the same order on both.
    final keys = {...local.keys, ...remote.keys}.toList()..sort();
    for (final key in keys) {
      final l = local[key]?.present;
      final r = remote[key]?.present;

      // "missing on both" cannot occur — the key set is the union — which is
      // FR-4's "emit no field" row expressed as an absence from the output.
      final KdbxFieldClassification classification;
      if (l != null && r != null) {
        classification = l.sameAs(r)
            ? KdbxFieldClassification.identical
            : KdbxFieldClassification.fieldConflict;
      } else if (l != null) {
        classification = KdbxFieldClassification.fieldLocalOnly;
      } else {
        classification = KdbxFieldClassification.fieldRemoteOnly;
      }

      yield KdbxFieldDiff(
        entryUuid: entryUuid,
        fieldKind: fieldKind,
        canonicalKey: key,
        localKey: local[key]?.spelling,
        remoteKey: remote[key]?.spelling,
        local: l ?? const KdbxFieldMissing(),
        remote: r ?? const KdbxFieldMissing(),
        classification: classification,
      );
    }
  }
}

/// The join of one object's times across the two sides.
final class _ObjectTimes {
  const _ObjectTimes({this.modifiedAt, this.locationChangedAt});

  final DateTime? modifiedAt;
  final DateTime? locationChangedAt;

  /// FR-3's order over known times: a known time beats an unknown one, and the
  /// newer known time wins. Commutative, so the two sides can be visited in
  /// either order — which is the whole point.
  _ObjectTimes joinedWith({
    DateTime? modifiedAt,
    DateTime? locationChangedAt,
  }) => _ObjectTimes(
    modifiedAt: _newer(this.modifiedAt, modifiedAt),
    locationChangedAt: _newer(this.locationChangedAt, locationChangedAt),
  );

  static DateTime? _newer(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}

/// One side's raw evidence, indexed by UUID.
final class _SideEvidence {
  const _SideEvidence({
    required this.objects,
    required this.binnedUuids,
    required this.tombstones,
  });

  final Map<String, KdbxObject> objects;
  final Set<String> binnedUuids;
  final Map<String, DateTime?> tombstones;

  KdbxRecordSide sideFor(String uuid) {
    final object = objects[uuid];
    if (object != null) {
      return KdbxRecordSide(
        evidence: binnedUuids.contains(uuid)
            ? KdbxRecordEvidence.recycled
            : KdbxRecordEvidence.live,
        modifiedAtUtc: object.times.lastModificationTime.get(),
        // A tombstone can coexist with a live object of the same UUID after a
        // delete-then-restore on this side; carrying it keeps the join
        // monotone (T009b) instead of silently dropping evidence.
        deletedAtUtc: tombstones[uuid],
      );
    }
    if (tombstones.containsKey(uuid)) {
      return KdbxRecordSide(
        evidence: KdbxRecordEvidence.tombstoned,
        deletedAtUtc: tombstones[uuid],
      );
    }
    return const KdbxRecordSide.absent();
  }
}

/// The `DeletedObjects` tombstone list of [file], keyed by UUID.
///
/// `KdbxBody.deletedObjects` is the only accessor the library offers and it is
/// annotated `@visibleForTesting` — recorded in the Gate 0 report as one of the
/// primitives that sits outside the supported surface. It is exported and
/// stable; the annotation is what forces the ignore, not the API.
Map<String, DateTime?> tombstonesOf(KdbxFile file) => {
  // ignore: invalid_use_of_visible_for_testing_member
  for (final deleted in file.body.deletedObjects)
    deleted.uuid.uuid: deleted.deletionTime.get(),
};
