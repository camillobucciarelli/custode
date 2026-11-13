import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:kdbx/kdbx.dart';
import 'package:loggy/loggy.dart';
import 'package:path/path.dart' as p;

import '../../domain/errors/passkey_errors.dart';
import '../../domain/models/vault_attachment.dart';
import '../../domain/models/vault_custom_field.dart';
import '../../domain/models/vault_entry.dart';
import '../../domain/models/vault_entry_revision.dart';
import '../../domain/models/vault_group.dart';
import '../../domain/models/vault_passkey.dart';
import '../../domain/models/vault_snapshot.dart';
import '../../domain/services/url_field_keys.dart';
import 'database_file_hash_recorder.dart';
import 'database_path_mutex.dart';
import 'passkey_parser.dart';
import 'safe_vault_file_writer.dart';

class KdbxCredentialChange {
  const KdbxCredentialChange({
    required this.databasePath,
    required this.backupPath,
  });

  final String databasePath;
  final String backupPath;
}

class VaultKdbxService {
  VaultKdbxService({
    this.credentialTempWriter,
    DatabasePathMutex? mutex,
    SafeVaultFileWriter? safeWriter,
    this._fileHashRecorder,
  }) : _mutex = mutex ?? DatabasePathMutex(),
       _safeWriter = safeWriter ?? SafeVaultFileWriter();

  /// spec 008 T105: every mutation below runs inside this lock so vault
  /// edits, sync replacement, import commits and renames on the same file
  /// serialize. NOT reentrant: no method may call another locked method
  /// from inside its action ([changeCredentials] composes sequentially).
  final DatabasePathMutex _mutex;

  final Future<void> Function(File file, Uint8List bytes)? credentialTempWriter;

  /// spec 008 T109: lock-free safe writer used INSIDE the mutex actions for
  /// every database byte write (temp + fsync + verify + atomic rename).
  final SafeVaultFileWriter _safeWriter;

  /// Invalidate/complete/rollback hash protocol (P1-4) around vault save
  /// and credential-change install/rollback. `null` in callers/tests that
  /// do not need registry hash tracking.
  final DatabaseFileHashRecorder? _fileHashRecorder;

  Future<T> _trackDatabaseWrite<T>({
    required String databasePath,
    required Uint8List bytes,
    required Future<T> Function() write,
  }) {
    final recorder = _fileHashRecorder;
    if (recorder == null) {
      return write();
    }
    return recorder.trackWrite(
      databasePath: databasePath,
      bytes: bytes,
      write: write,
    );
  }

  static const maxAttachmentBytes = 20 * 1024 * 1024;
  static final _notesKey = KdbxKey('Notes');
  static final _standardEntryKeys = {
    KdbxKeyCommon.TITLE.key.toLowerCase(),
    KdbxKeyCommon.USER_NAME.key.toLowerCase(),
    KdbxKeyCommon.PASSWORD.key.toLowerCase(),
    KdbxKeyCommon.URL.key.toLowerCase(),
    _notesKey.key.toLowerCase(),
  };

  Future<String?> getRecycleBinGroupId({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async {
    final file = await _openFile(
      databasePath: databasePath,
      password: password,
      keyFilePath: keyFilePath,
    );
    return file.recycleBin?.uuid.uuid;
  }

  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async {
    final file = await _openFile(
      databasePath: databasePath,
      password: password,
      keyFilePath: keyFilePath,
    );

    final rootGroup = file.body.rootGroup;
    final groups = rootGroup.getAllGroups();

    final resolvedCurrentGroup = currentGroupId == null
        ? rootGroup
        : _findGroupByIdOrNull(groups, currentGroupId) ?? rootGroup;

    final groupModels = groups
        .map(
          (group) => VaultGroup(
            id: group.uuid.uuid,
            name: group.name.get() ?? 'Untitled Group',
            parentId: group.parent?.uuid.uuid,
            isRecycleBin: file.recycleBin?.uuid == group.uuid,
          ),
        )
        .toList(growable: false);

    final entryModels = resolvedCurrentGroup.entries
        .map((entry) => _mapEntry(resolvedCurrentGroup.uuid.uuid, entry))
        .toList(growable: false);

    final recycleBinUuid = file.recycleBin?.uuid.uuid;
    final allEntryModels = rootGroup
        .getAllEntries()
        .where((entry) => !_isInsideRecycleBin(entry, recycleBinUuid))
        .map(
          (entry) =>
              _mapEntry(entry.parent?.uuid.uuid ?? rootGroup.uuid.uuid, entry),
        )
        .toList(growable: false);

    return VaultSnapshot(
      rootGroupId: rootGroup.uuid.uuid,
      currentGroupId: resolvedCurrentGroup.uuid.uuid,
      groups: groupModels,
      entries: entryModels,
      allEntries: allEntryModels,
    );
  }

  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async {
    final file = await _openFile(
      databasePath: databasePath,
      password: password,
      keyFilePath: keyFilePath,
    );

    final recycleBin = file.recycleBin;
    if (recycleBin == null) {
      return const [];
    }

    final entries = recycleBin.getAllEntries()
      ..sort((a, b) {
        final left = a.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
        final right = b.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
        return left.toLowerCase().compareTo(right.toLowerCase());
      });

    return entries
        .map(
          (entry) =>
              _mapEntry(entry.parent?.uuid.uuid ?? recycleBin.uuid.uuid, entry),
        )
        .toList(growable: false);
  }

  Future<List<VaultEntry>> loadAllEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async {
    final file = await _openFile(
      databasePath: databasePath,
      password: password,
      keyFilePath: keyFilePath,
    );

    final recycleBinUuid = file.recycleBin?.uuid.uuid;
    final entries =
        file.body.rootGroup
            .getAllEntries()
            .where((entry) => !_isInsideRecycleBin(entry, recycleBinUuid))
            .toList()
          ..sort((a, b) {
            final left = a.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
            final right = b.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
            return left.toLowerCase().compareTo(right.toLowerCase());
          });

    return entries
        .map(
          (entry) => _mapEntry(
            entry.parent?.uuid.uuid ?? file.body.rootGroup.uuid.uuid,
            entry,
          ),
        )
        .toList(growable: false);
  }

  Future<String> createEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
    required String title,
    required String username,
    required String entryPassword,
    required String url,
    required String notes,
    List<VaultCustomField> customFields = const [],
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );
      final rootGroup = file.body.rootGroup;
      final group = _findGroupById(rootGroup.getAllGroups(), groupId);

      final entry = KdbxEntry.create(file, group);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(username));
      entry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString(entryPassword),
      );
      entry.setString(KdbxKeyCommon.URL, PlainValue(url));
      entry.setString(_notesKey, PlainValue(notes));
      _setCustomFields(entry, customFields);
      group.addEntry(entry);

      await _save(databasePath, file);
      return entry.uuid.uuid;
    });
  }

  /// spec-019 C-04-05 — copy a record, whole, beside itself.
  ///
  /// Deliberately not built on [createEntry]: that path takes the fields the
  /// editor knows about, and a record is more than those. It carries protected
  /// strings whose plaintext the caller has no reason to hold, custom fields
  /// (which is where the TOTP secret lives), and file attachments that exist
  /// only as bytes inside the database — nothing a caller could pass back in
  /// through a list of file paths.
  ///
  /// So the copy is made here, where the source entry is already open: every
  /// string with its protection flag intact, every binary, into the source's
  /// own group. The plaintext of the password is never read, only re-set from
  /// the value object.
  ///
  /// Returns the new entry's id.
  Future<String> duplicateEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String titleSuffix,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final source = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      final group = source.parent;
      if (group == null) {
        throw Exception('Record has no group to be duplicated into.');
      }

      final copy = KdbxEntry.create(file, group);
      for (final key in source.stringEntries) {
        final value = key.value;
        if (value == null) {
          continue;
        }
        copy.setString(key.key, value);
      }
      final sourceTitle =
          source.getString(KdbxKeyCommon.TITLE)?.getText() ?? '';
      copy.setString(
        KdbxKeyCommon.TITLE,
        PlainValue('$sourceTitle$titleSuffix'),
      );

      for (final binary in source.binaryEntries) {
        copy.createBinary(
          isProtected: binary.value.isProtected,
          name: binary.key.key,
          bytes: binary.value.value,
        );
      }

      group.addEntry(copy);
      await _save(databasePath, file);
      return copy.uuid.uuid;
    });
  }

  Future<void> updateEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String title,
    required String username,
    required String entryPassword,
    required String url,
    required String notes,
    List<VaultCustomField> customFields = const [],
    List<String> addedAttachmentPaths = const [],
    List<String> removedAttachmentKeys = const [],
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      // Read every new attachment before the entry is touched: an unreadable
      // or oversized file fails the whole update, so the fields and the files
      // land together or not at all, in one save and one history revision.
      final addedAttachments = <(String, Uint8List)>[
        for (final filePath in addedAttachmentPaths)
          (p.basename(filePath), await _readAttachmentSource(filePath)),
      ];
      entry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(username));
      entry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString(entryPassword),
      );
      entry.setString(KdbxKeyCommon.URL, PlainValue(url));
      entry.setString(_notesKey, PlainValue(notes));
      _setCustomFields(entry, customFields);
      // Removals first, so a replaced file never collides with its old copy.
      // A key that is already gone (a sync merge removed it while the editor
      // was open) is the outcome the user asked for, not a failure.
      final existingKeys = entry.binaryEntries
          .map((binary) => binary.key.key)
          .toSet();
      for (final attachmentKey in removedAttachmentKeys) {
        if (existingKeys.contains(attachmentKey)) {
          entry.removeBinary(KdbxKey(attachmentKey));
        }
      }
      for (final (name, bytes) in addedAttachments) {
        entry.createBinary(isProtected: false, name: name, bytes: bytes);
      }

      await _save(databasePath, file);
    });
  }

  Future<Uint8List> _readAttachmentSource(String filePath) async {
    final source = File(filePath);
    if (!await source.exists()) {
      throw Exception('Attachment source file not found.');
    }
    final bytes = await source.readAsBytes();
    if (bytes.length > maxAttachmentBytes) {
      throw Exception('Attachment exceeds 20 MB limit.');
    }
    return bytes;
  }

  /// spec 017 T103 — the revisions the KDBX writer already recorded for an
  /// entry, newest first (FR-001), together with the vault's retention limits
  /// (FR-012), from one open of the file under one lock: two separate reads
  /// could observe two different states of it.
  ///
  /// Read-only. An entry with no history yields an empty list, not an error
  /// (FR-013); an unknown entry throws, like every other lookup here.
  Future<VaultEntryHistory> loadEntryHistory({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );

      final revisions = [
        for (final (_, revision) in _orderedHistory(entryId, entry)) revision,
      ].toList(growable: false);

      final meta = file.body.meta;
      return VaultEntryHistory(
        revisions: revisions,
        retention: VaultHistoryRetention(
          maxItems: meta.historyMaxItems.get(),
          maxSizeBytes: meta.historyMaxSize.get(),
        ),
      );
    });
  }

  /// spec 017 T301 — put a revision's fields back on the entry, with the same
  /// setters [updateEntry] uses so the KDBX writer appends the pre-restore
  /// state to history (D5, FR-007). The OTP secret rides along in the custom
  /// fields, where it lives. Attachments are not touched (FR-006a).
  ///
  /// Throws when no revision of [entryId] carries [replacedAt] (and
  /// [ordinal], for same-second revisions — see [VaultEntryRevision.ordinal]).
  Future<void> restoreEntryRevision({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required DateTime replacedAt,
    int ordinal = 0,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      final (_, revision) = _findRevision(entryId, entry, replacedAt, ordinal);

      entry.setString(KdbxKeyCommon.TITLE, PlainValue(revision.title));
      entry.setString(KdbxKeyCommon.USER_NAME, PlainValue(revision.username));
      entry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString(revision.password),
      );
      entry.setString(KdbxKeyCommon.URL, PlainValue(revision.url));
      entry.setString(_notesKey, PlainValue(revision.notes));
      _setCustomFields(entry, revision.customFields);

      await _save(databasePath, file);
    });
  }

  /// spec 017 T401 — remove exactly the revision saved at [replacedAt]
  /// (FR-009). The others keep their order. No backup here: that is the
  /// coordinator's, so the backup and the warning stay together.
  ///
  /// The list is edited directly, never through `modify`: `modify` is what
  /// appends a history entry, and removing one must not add one (FR-014).
  /// Throws when no revision carries that timestamp (and [ordinal]).
  Future<void> deleteEntryRevision({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required DateTime replacedAt,
    int ordinal = 0,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );
      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      final (fileIndex, _) = _findRevision(entryId, entry, replacedAt, ordinal);
      entry.history.removeAt(fileIndex);
      await _save(databasePath, file);
    });
  }

  /// spec 023 T203 — remove exactly the `KPEX_PASSKEY_*` group whose
  /// `(relyingPartyId, credentialId)` matches, and nothing else (FR-010).
  ///
  /// Matched on the credential, not on the field suffix: the suffix is the
  /// group's *position* in the namespace, and a sync or a KeePassXC edit can
  /// renumber it between the read that built the UI and this write. Removing
  /// by position would then delete a different passkey.
  ///
  /// Every string of the group goes, including keys this app does not
  /// understand (`KPEX_PASSKEY_PRF`): they belong to the credential being
  /// deleted, and leaving them would strand fields pointing at a key that no
  /// longer exists. The entry's own fields, its binaries, tags and history
  /// are untouched, and `setString`/`removeString` record one ordinary
  /// revision, exactly as an edit does.
  ///
  /// Throws [PasskeyNotFound] when no group matches. No backup here: that is
  /// the coordinator's, so the backup and the confirmation stay together.
  Future<void> deletePasskey({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String relyingPartyId,
    required Uint8List credentialId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );
      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );

      final match = _mapPasskeys(entry).where((passkey) {
        return passkey.relyingPartyId == relyingPartyId &&
            _sameBytes(passkey.credentialId, credentialId);
      }).firstOrNull;
      if (match == null) {
        throw PasskeyNotFound(entryId: entryId, relyingPartyId: relyingPartyId);
      }

      // The empty suffix is a prefix of `_1`, so a plain `startsWith` on the
      // group key would let deleting the first passkey take the others with
      // it. Compare the suffix the parser derived instead.
      final keysToRemove = entry.stringEntries
          .map((stringEntry) => stringEntry.key)
          .where(
            (key) =>
                PasskeyParser.isPasskeyKey(key.key) &&
                PasskeyParser.suffixOf(key.key) == match.fieldSuffix,
          )
          .toList(growable: false);
      for (final key in keysToRemove) {
        entry.removeString(key);
      }

      await _save(databasePath, file);
    });
  }

  /// spec 023 US3 — write a newly created passkey onto an entry (FR-018).
  ///
  /// [replaceExisting] decides what happens when the entry already holds a
  /// passkey for the same `(relyingPartyId, userHandle)`: false throws
  /// [PasskeyAlreadyExists] so the caller can warn before anything is
  /// overwritten (FR-019), true removes that group first. Nothing is ever
  /// overwritten by default — silently replacing a credential is how a user
  /// loses the only copy of a key.
  ///
  /// All-or-nothing (FR-020): the fields are written and saved inside one
  /// locked action, so the file on disk holds either the whole credential or
  /// none of it. The caller must not report success to a relying party before
  /// this future completes.
  ///
  /// Written into the first free suffix group, so an entry that already holds
  /// a passkey gains a second rather than losing the first.
  Future<void> createPasskey({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required VaultPasskey passkey,
    bool replaceExisting = false,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );
      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );

      final existing = _mapPasskeys(entry);
      final clash = existing.where((candidate) {
        return candidate.relyingPartyId == passkey.relyingPartyId &&
            _sameHandle(candidate.userHandle, passkey.userHandle);
      }).firstOrNull;
      if (clash != null) {
        if (!replaceExisting) {
          throw PasskeyAlreadyExists(
            entryId: entryId,
            relyingPartyId: passkey.relyingPartyId,
          );
        }
        _removePasskeyGroup(entry, clash.fieldSuffix);
      }

      final suffix = _nextPasskeySuffix(entry);
      for (final field in passkeyFieldsFor(passkey, suffix: suffix).entries) {
        entry.setString(
          KdbxKey(field.key),
          field.value.isProtected
              ? ProtectedValue.fromString(field.value.value)
              : PlainValue(field.value.value),
        );
      }

      await _save(databasePath, file);
    });
  }

  /// The `KPEX_PASSKEY_*` fields for [passkey], in the KeePassXC layout, with
  /// the protection flags KeePassXC itself uses.
  ///
  /// The private key, the credential id and the user handle are protected; the
  /// relying party, the username and the backup flags are not. Matching
  /// KeePassXC here is what keeps a vault written by this app usable in it.
  @visibleForTesting
  static Map<String, VaultCustomField> passkeyFieldsFor(
    VaultPasskey passkey, {
    String suffix = '',
  }) {
    String key(String base) => '$base$suffix';
    return {
      key(PasskeyParser.relyingPartyKey): VaultCustomField(
        key: key(PasskeyParser.relyingPartyKey),
        value: passkey.relyingPartyId,
      ),
      key(PasskeyParser.credentialIdKey): VaultCustomField(
        key: key(PasskeyParser.credentialIdKey),
        value: _base64UrlUnpadded(passkey.credentialId),
        isProtected: true,
      ),
      if (passkey.userHandle != null)
        key(PasskeyParser.userHandleKey): VaultCustomField(
          key: key(PasskeyParser.userHandleKey),
          value: _base64UrlUnpadded(passkey.userHandle!),
          isProtected: true,
        ),
      key(PasskeyParser.usernameKey): VaultCustomField(
        key: key(PasskeyParser.usernameKey),
        value: passkey.username,
      ),
      key(PasskeyParser.privateKeyPemKey): VaultCustomField(
        key: key(PasskeyParser.privateKeyPemKey),
        value: passkey.privateKeyPem,
        isProtected: true,
      ),
      key(PasskeyParser.flagBeKey): VaultCustomField(
        key: key(PasskeyParser.flagBeKey),
        value: passkey.backupEligible ? '1' : '0',
      ),
      key(PasskeyParser.flagBsKey): VaultCustomField(
        key: key(PasskeyParser.flagBsKey),
        value: passkey.backupState ? '1' : '0',
      ),
    };
  }

  /// `''` when the namespace is free, then `_1`, `_2`, … — the KeePassDX
  /// convention the parser already groups by.
  String _nextPasskeySuffix(KdbxEntry entry) {
    final used = {
      for (final stringEntry in entry.stringEntries)
        if (PasskeyParser.isPasskeyKey(stringEntry.key.key))
          PasskeyParser.suffixOf(stringEntry.key.key),
    };
    if (!used.contains('')) return '';
    for (var index = 1; index < 1000; index++) {
      if (!used.contains('_$index')) return '_$index';
    }
    throw StateError('entry ${entry.uuid.uuid} holds too many passkeys');
  }

  void _removePasskeyGroup(KdbxEntry entry, String suffix) {
    final keys = entry.stringEntries
        .map((stringEntry) => stringEntry.key)
        .where(
          (key) =>
              PasskeyParser.isPasskeyKey(key.key) &&
              PasskeyParser.suffixOf(key.key) == suffix,
        )
        .toList(growable: false);
    for (final key in keys) {
      entry.removeString(key);
    }
  }

  /// Two credentials collide only when both name the same account at the same
  /// relying party. A passkey with no handle collides only with another that
  /// also has none.
  static bool _sameHandle(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == null && b == null;
    return _sameBytes(a, b);
  }

  static String _base64UrlUnpadded(Uint8List bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The one ordering every history read and write shares, so what the list
  /// shows is what a restore or delete acts on.
  ///
  /// The KDBX list is oldest first *when this app wrote it*, but
  /// `KdbxEntry.merge` appends the other side's revisions without
  /// reordering, so after a two-device sync file order is not chronological.
  /// FR-001 promises newest first, so order by the timestamp rather than by
  /// position. KDBX times are second-precision: ties keep reversed file
  /// order (deterministic even though `List.sort` is not stable), and each
  /// revision's [VaultEntryRevision.ordinal] is its place within that tie.
  ///
  /// Returns `(file index, revision)` pairs.
  List<(int, VaultEntryRevision)> _orderedHistory(
    String entryId,
    KdbxEntry entry,
  ) {
    final ordered =
        [
          for (final (index, revision) in entry.history.indexed)
            (index, _revisionTime(revision)),
        ]..sort((a, b) {
          final byTime = b.$2.compareTo(a.$2);
          return byTime != 0 ? byTime : b.$1.compareTo(a.$1);
        });
    final result = <(int, VaultEntryRevision)>[];
    var ordinal = 0;
    for (var i = 0; i < ordered.length; i++) {
      ordinal = i > 0 && ordered[i].$2 == ordered[i - 1].$2 ? ordinal + 1 : 0;
      final fileIndex = ordered[i].$1;
      result.add((
        fileIndex,
        _mapRevision(entryId, entry.history[fileIndex], ordinal: ordinal),
      ));
    }
    return result;
  }

  (int, VaultEntryRevision) _findRevision(
    String entryId,
    KdbxEntry entry,
    DateTime replacedAt,
    int ordinal,
  ) {
    final wanted = replacedAt.toUtc();
    for (final candidate in _orderedHistory(entryId, entry)) {
      if (candidate.$2.replacedAt == wanted &&
          candidate.$2.ordinal == ordinal) {
        return candidate;
      }
    }
    throw StateError('No revision of entry $entryId at $replacedAt#$ordinal');
  }

  /// spec 017 T401 — empty an entry's history (FR-010). The dated backup
  /// is the coordinator's, written before this is called.
  Future<void> clearEntryHistory({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );
      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      entry.history.clear();
      await _save(databasePath, file);
    });
  }

  /// Throws [PasskeyMergeConflict] when the primary and one of the
  /// secondaries hold different passkeys for the same relying party and
  /// account (spec 023 FR-011a). Checked for every secondary before anything
  /// is written, so a refused merge leaves the file exactly as it was rather
  /// than folding in the first two entries and then giving up.
  Future<void> mergeEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String primaryId,
    required List<String> secondaryIds,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final allEntries = file.body.rootGroup.getAllEntries();
      final primary = _findEntryById(allEntries, primaryId);
      final secondaries = [
        for (final secondaryId in secondaryIds)
          _findEntryById(allEntries, secondaryId),
      ];

      // The primary's own passkeys plus the ones earlier secondaries would
      // add: two secondaries carrying the same identity collide with each
      // other just as surely as with the primary.
      final claimedIdentities = _mapPasskeys(primary)
          .map(_passkeyIdentityKey)
          .toSet();
      for (final secondary in secondaries) {
        for (final passkey in _mapPasskeys(secondary)) {
          if (!claimedIdentities.add(_passkeyIdentityKey(passkey))) {
            throw PasskeyMergeConflict(
              primaryId: primaryId,
              secondaryId: secondary.uuid.uuid,
              relyingPartyId: passkey.relyingPartyId,
            );
          }
        }
      }

      for (final secondary in secondaries) {
        _mergeInto(file, primary, secondary);
      }

      await _save(databasePath, file);
    });
  }

  /// The relying party plus the account the passkey names — what makes two
  /// credentials the same slot. Built from the parsed passkey so it matches
  /// [_sameHandle]'s rule: no handle collides only with no handle.
  static String _passkeyIdentityKey(VaultPasskey passkey) {
    final handle = passkey.userHandle;
    return '${passkey.relyingPartyId}\x00'
        '${handle == null ? '<none>' : _base64UrlUnpadded(handle)}';
  }

  /// Folds [secondary] into [primary] (notes, custom fields, URLs,
  /// attachments) and moves it to the recycle bin.
  void _mergeInto(KdbxFile file, KdbxEntry primary, KdbxEntry secondary) {
    {
      // Copy notes if primary notes is empty.
      final primaryNotes = primary.getString(_notesKey)?.getText() ?? '';
      final secondaryNotes = secondary.getString(_notesKey)?.getText() ?? '';
      if (primaryNotes.trim().isEmpty && secondaryNotes.trim().isNotEmpty) {
        primary.setString(_notesKey, PlainValue(secondaryNotes));
      }

      // Copy custom fields present in secondary but absent in primary.
      // URL-keyed fields are handled separately below, so they dedup by
      // value instead of clashing by key.
      final primaryStringKeys = primary.stringEntries
          .map((e) => e.key.key.toLowerCase())
          .toSet();
      for (final stringEntry in secondary.stringEntries) {
        final key = stringEntry.key.key;
        if (_standardEntryKeys.contains(key.toLowerCase())) continue;
        if (isUrlFieldKey(key)) continue;
        // spec 023 T207 — the passkey namespace never travels key by key.
        // Copying it that way would let a private key from one credential
        // land beside the credential id of another, since the keys collide by
        // suffix and not by credential (FR-008). The whole group is copied
        // below instead.
        if (PasskeyParser.isPasskeyKey(key)) continue;
        if (!primaryStringKeys.contains(key.toLowerCase())) {
          primary.setString(KdbxKey(key), stringEntry.value ?? PlainValue(''));
        }
      }

      // Copy each of the secondary's passkeys as one credential, renumbered
      // into a free suffix on the primary (spec 023 T207 / FR-011a).
      //
      // The values are copied as their own `KdbxValue`, not re-serialized
      // from the parsed model: a protected field stays protected, an unusable
      // passkey travels as it is rather than being silently normalized, and
      // keys this app does not understand (`KPEX_PASSKEY_PRF`) stay with the
      // credential they belong to. The secret is never read into a Dart
      // string on this path.
      //
      // An identity the primary already holds is skipped, not overwritten.
      // [mergeEntries] has already refused that case; this guard is what keeps
      // any other caller of [_mergeInto] from assembling a mixed credential.
      for (final passkey in _mapPasskeys(secondary)) {
        final claimed = _mapPasskeys(primary).map(_passkeyIdentityKey).toSet();
        if (claimed.contains(_passkeyIdentityKey(passkey))) continue;
        final targetSuffix = _nextPasskeySuffix(primary);
        final sourceSuffix = passkey.fieldSuffix;
        for (final stringEntry in secondary.stringEntries) {
          final key = stringEntry.key.key;
          if (!PasskeyParser.isPasskeyKey(key)) continue;
          if (PasskeyParser.suffixOf(key) != sourceSuffix) continue;
          final base = key.substring(0, key.length - sourceSuffix.length);
          primary.setString(
            KdbxKey('$base$targetSuffix'),
            stringEntry.value ?? PlainValue(''),
          );
        }
      }

      // Collect every URL the secondary carries (primary URL field + URL
      // custom fields) and append the ones the primary is missing as
      // KP2A_URL_n extra-URL fields.
      List<String> urlsOf(KdbxEntry entry) => [
        entry.getString(KdbxKeyCommon.URL)?.getText() ?? '',
        for (final stringEntry in entry.stringEntries)
          if (!_standardEntryKeys.contains(stringEntry.key.key.toLowerCase()) &&
              isUrlFieldKey(stringEntry.key.key))
            stringEntry.value?.getText() ?? '',
      ].map((u) => u.trim()).where((u) => u.isNotEmpty).toList();

      final primaryUrls = urlsOf(primary).map(normalizeUrlForCompare).toSet();
      var nextUrlIndex = 1;
      for (final url in urlsOf(secondary)) {
        if (!primaryUrls.add(normalizeUrlForCompare(url))) continue;
        while (primary.getString(KdbxKey('$kp2aUrlKeyPrefix$nextUrlIndex')) !=
            null) {
          nextUrlIndex++;
        }
        primary.setString(
          KdbxKey('$kp2aUrlKeyPrefix$nextUrlIndex'),
          PlainValue(url),
        );
        nextUrlIndex++;
      }

      // Copy attachments present in secondary but absent in primary.
      final primaryAttachmentKeys = primary.binaryEntries
          .map((e) => e.key.key)
          .toSet();
      for (final binaryEntry in secondary.binaryEntries) {
        final key = binaryEntry.key.key;
        if (!primaryAttachmentKeys.contains(key)) {
          primary.createBinary(
            isProtected: false,
            name: key,
            bytes: binaryEntry.value.value,
          );
        }
      }

      // Move secondary to recycle bin.
      file.deleteEntry(secondary);
    }
  }

  Future<void> changeCredentials({
    required String databasePath,
    required String currentPassword,
    String? currentKeyFilePath,
    required String newPassword,
    String? newKeyFilePath,
  }) async {
    final change = await beginCredentialChange(
      databasePath: databasePath,
      currentPassword: currentPassword,
      currentKeyFilePath: currentKeyFilePath,
      newPassword: newPassword,
      newKeyFilePath: newKeyFilePath,
    );
    await finalizeCredentialChange(change);
  }

  Future<KdbxCredentialChange> beginCredentialChange({
    required String databasePath,
    required String currentPassword,
    String? currentKeyFilePath,
    required String newPassword,
    String? newKeyFilePath,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: currentPassword,
        keyFilePath: currentKeyFilePath,
      );

      Uint8List? keyFileBytes;
      if (newKeyFilePath != null && newKeyFilePath.trim().isNotEmpty) {
        final keyFile = File(newKeyFilePath);
        if (!await keyFile.exists()) {
          throw Exception('Key file not found.');
        }
        keyFileBytes = await keyFile.readAsBytes();
      }

      file.credentials = Credentials.composite(
        ProtectedValue.fromString(newPassword),
        keyFileBytes,
      );
      final bytes = await file.save();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final directory = p.dirname(databasePath);
      final name = p.basename(databasePath);
      final tempFile = File(
        p.join(directory, '.$name.credentials-$suffix.tmp'),
      );
      final backupFile = File(
        p.join(directory, '.$name.credentials-$suffix.bak'),
      );
      final databaseFile = File(databasePath);

      try {
        final writer = credentialTempWriter;
        if (writer == null) {
          // T109: fsync the temp before it is verified and renamed over the
          // database — a rename of an un-fsynced temp is the classic
          // post-crash corruption.
          await _safeWriter.write(
            targetPath: tempFile.path,
            bytes: bytes,
            operation: 'credential change temp',
          );
        } else {
          await writer(tempFile, bytes);
        }
        await _openFile(
          databasePath: tempFile.path,
          password: newPassword,
          keyFilePath: newKeyFilePath,
        );

        await _trackDatabaseWrite(
          databasePath: databasePath,
          bytes: bytes,
          write: () async {
            await databaseFile.rename(backupFile.path);
            try {
              await tempFile.rename(databasePath);
            } catch (_) {
              await backupFile.rename(databasePath);
              rethrow;
            }
          },
        );

        return KdbxCredentialChange(
          databasePath: databasePath,
          backupPath: backupFile.path,
        );
      } catch (_) {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        rethrow;
      }
    });
  }

  Future<void> finalizeCredentialChange(KdbxCredentialChange change) {
    return _mutex.withDatabaseLock([change.databasePath], () async {
      final backupFile = File(change.backupPath);
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
    });
  }

  Future<void> rollbackCredentialChange(KdbxCredentialChange change) {
    return _mutex.withDatabaseLock([change.databasePath], () async {
      final backupFile = File(change.backupPath);
      if (!await backupFile.exists()) {
        throw StateError('Credential backup is unavailable.');
      }

      final databaseFile = File(change.databasePath);
      final failedFile = File(
        '${change.databasePath}.credentials-rollback-${DateTime.now().microsecondsSinceEpoch}',
      );
      final restoredBytes = await backupFile.readAsBytes();
      await _trackDatabaseWrite(
        databasePath: change.databasePath,
        bytes: restoredBytes,
        write: () async {
          if (await databaseFile.exists()) {
            await databaseFile.rename(failedFile.path);
          }
          try {
            await backupFile.rename(change.databasePath);
          } catch (_) {
            if (await failedFile.exists() && !await databaseFile.exists()) {
              await failedFile.rename(change.databasePath);
            }
            rethrow;
          }
        },
      );
      try {
        if (await failedFile.exists()) {
          await failedFile.delete();
        }
      } catch (error, stackTrace) {
        logWarning(
          'Unable to remove a credential rollback artifact.',
          error,
          stackTrace,
        );
      }
    });
  }

  Future<void> addAttachment({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String filePath,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final bytes = await _readAttachmentSource(filePath);

      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      entry.createBinary(
        isProtected: false,
        name: p.basename(filePath),
        bytes: bytes,
      );
      await _save(databasePath, file);
    });
  }

  Future<String> exportAttachment({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String attachmentKey,
    required String destinationDirectory,
  }) {
    return _mutex.withDatabaseLock(
      [databasePath, p.join(destinationDirectory, attachmentKey)],
      () async {
        final file = await _openFile(
          databasePath: databasePath,
          password: password,
          keyFilePath: keyFilePath,
        );

        final entry = _findEntryById(
          file.body.rootGroup.getAllEntries(),
          entryId,
        );
        final binary = entry.getBinary(KdbxKey(attachmentKey));
        if (binary == null) {
          throw Exception('Attachment not found.');
        }

        final destination = File(p.join(destinationDirectory, attachmentKey));
        await destination.writeAsBytes(binary.value, flush: true);
        return destination.path;
      },
    );
  }

  Future<void> deleteEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    bool permanently = false,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );

      if (permanently) {
        file.deletePermanently(entry);
      } else {
        file.deleteEntry(entry);
      }

      await _save(databasePath, file);
    });
  }

  Future<void> moveEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String targetGroupId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final groups = file.body.rootGroup.getAllGroups();
      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      final targetGroup = _findGroupById(groups, targetGroupId);
      file.move(entry, targetGroup);

      await _save(databasePath, file);
    });
  }

  Future<void> createGroup({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String parentGroupId,
    required String name,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final parentGroup = _findGroupById(
        file.body.rootGroup.getAllGroups(),
        parentGroupId,
      );
      file.createGroup(parent: parentGroup, name: name);

      await _save(databasePath, file);
    });
  }

  Future<void> renameGroup({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
    required String newName,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final group = _findGroupById(file.body.rootGroup.getAllGroups(), groupId);
      group.name.set(newName);

      await _save(databasePath, file);
    });
  }

  Future<void> deleteGroup({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
    bool permanently = false,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final group = _findGroupById(file.body.rootGroup.getAllGroups(), groupId);
      if (group.parent == null) {
        throw Exception('Root group cannot be deleted.');
      }

      if (permanently) {
        file.deletePermanently(group);
      } else {
        file.deleteGroup(group);
      }

      await _save(databasePath, file);
    });
  }

  Future<bool> isGroupEmpty({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
  }) async {
    final file = await _openFile(
      databasePath: databasePath,
      password: password,
      keyFilePath: keyFilePath,
    );

    final group = _findGroupById(file.body.rootGroup.getAllGroups(), groupId);
    if (group.parent == null) {
      throw Exception('Root group cannot be deleted.');
    }

    return group.entries.isEmpty && group.groups.isEmpty;
  }

  Future<void> moveGroup({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
    required String targetGroupId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final groups = file.body.rootGroup.getAllGroups();
      final group = _findGroupById(groups, groupId);
      final targetGroup = _findGroupById(groups, targetGroupId);

      if (group.parent == null) {
        throw Exception('Root group cannot be moved.');
      }
      if (group.uuid == targetGroup.uuid) {
        throw Exception('Group cannot be moved into itself.');
      }
      if (targetGroup.isInGroup(group)) {
        throw Exception('Group cannot be moved into a descendant.');
      }

      file.move(group, targetGroup);
      await _save(databasePath, file);
    });
  }

  Future<void> restoreEntryFromRecycleBin({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      if (!entry.isInRecycleBin()) {
        throw Exception('Entry is not in recycle bin.');
      }

      final targetGroup = _resolveRestoreTargetGroup(file, entry);
      file.move(entry, targetGroup);
      await _save(databasePath, file);
    });
  }

  Future<void> restoreGroupFromRecycleBin({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final groups = file.body.rootGroup.getAllGroups();
      final group = _findGroupById(groups, groupId);
      if (!group.isInRecycleBin()) {
        throw Exception('Group is not in recycle bin.');
      }

      final targetGroup = _resolveRestoreTargetGroup(file, group);
      if (targetGroup == group || targetGroup.isInGroup(group)) {
        throw Exception('Invalid restore target group.');
      }

      file.move(group, targetGroup);
      await _save(databasePath, file);
    });
  }

  Future<void> deleteEntryPermanently({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final entry = _findEntryById(
        file.body.rootGroup.getAllEntries(),
        entryId,
      );
      if (!entry.isInRecycleBin()) {
        throw Exception('Only recycle bin entries can be permanently deleted.');
      }

      file.deletePermanently(entry);
      await _save(databasePath, file);
    });
  }

  Future<void> deleteGroupPermanently({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final group = _findGroupById(file.body.rootGroup.getAllGroups(), groupId);
      if (!group.isInRecycleBin()) {
        throw Exception('Only recycle bin groups can be permanently deleted.');
      }
      if (group == file.recycleBin) {
        throw Exception('Recycle bin group cannot be permanently deleted.');
      }

      file.deletePermanently(group);
      await _save(databasePath, file);
    });
  }

  Future<void> emptyRecycleBin({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) {
    return _mutex.withDatabaseLock([databasePath], () async {
      final file = await _openFile(
        databasePath: databasePath,
        password: password,
        keyFilePath: keyFilePath,
      );

      final recycleBin = file.recycleBin;
      if (recycleBin == null) {
        return;
      }

      final entries = recycleBin.getAllEntries();
      for (final entry in entries) {
        if (entry.parent != null) {
          file.deletePermanently(entry);
        }
      }

      final groups =
          recycleBin
              .getAllGroups()
              .where((group) => group != recycleBin)
              .toList()
            ..sort(
              (a, b) => b.breadcrumbs.length.compareTo(a.breadcrumbs.length),
            );

      for (final group in groups) {
        if (group.parent != null) {
          file.deletePermanently(group);
        }
      }

      await _save(databasePath, file);
    });
  }

  Future<KdbxFile> _openFile({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async {
    final dbFile = File(databasePath);
    if (!await dbFile.exists()) {
      throw Exception('Database file not found.');
    }

    Uint8List? keyFileBytes;
    if (keyFilePath != null && keyFilePath.trim().isNotEmpty) {
      final keyFile = File(keyFilePath);
      if (!await keyFile.exists()) {
        throw Exception('Key file not found.');
      }
      keyFileBytes = await keyFile.readAsBytes();
    }

    final credentials = Credentials.composite(
      ProtectedValue.fromString(password),
      keyFileBytes,
    );
    final dbBytes = await dbFile.readAsBytes();
    return KdbxFormat().read(dbBytes, credentials);
  }

  Future<void> _save(String databasePath, KdbxFile file) async {
    final bytes = await file.save();
    // T109: same-directory temp + fsync + verify + atomic rename. No backup
    // here: routine saves never produced one (user behaviour unchanged); the
    // old bytes stay intact until the atomic replace.
    await _trackDatabaseWrite(
      databasePath: databasePath,
      bytes: bytes,
      write: () => _safeWriter.write(
        targetPath: databasePath,
        bytes: bytes,
        operation: 'vault save',
      ),
    );
  }

  KdbxGroup _findGroupById(List<KdbxGroup> groups, String id) {
    return groups.firstWhere(
      (group) => group.uuid.uuid == id,
      orElse: () => throw Exception('Group not found.'),
    );
  }

  KdbxGroup? _findGroupByIdOrNull(List<KdbxGroup> groups, String id) {
    for (final group in groups) {
      if (group.uuid.uuid == id) {
        return group;
      }
    }
    return null;
  }

  KdbxEntry _findEntryById(List<KdbxEntry> entries, String id) {
    return entries.firstWhere(
      (entry) => entry.uuid.uuid == id,
      orElse: () => throw Exception('Entry not found.'),
    );
  }

  bool _isInsideRecycleBin(KdbxEntry entry, String? recycleBinUuid) {
    if (recycleBinUuid == null) return false;

    KdbxGroup? group = entry.parent;
    while (group != null) {
      if (group.uuid.uuid == recycleBinUuid) return true;
      group = group.parent;
    }
    return false;
  }

  /// Every non-standard string except the `KPEX_PASSKEY_*` namespace, which
  /// [_mapPasskeys] reads and no writer here touches (spec 023 T013).
  List<VaultCustomField> _mapCustomFields(KdbxEntry entry) {
    final customFields = <VaultCustomField>[];
    for (final stringEntry in entry.stringEntries) {
      final key = stringEntry.key.key;
      if (_standardEntryKeys.contains(key.toLowerCase()) ||
          PasskeyParser.isPasskeyKey(key)) {
        continue;
      }
      customFields.add(
        VaultCustomField(
          key: key,
          value: stringEntry.value?.getText() ?? '',
          isProtected: stringEntry.value is ProtectedValue,
        ),
      );
    }
    return customFields;
  }

  List<VaultCustomField> _passkeyRawFields(KdbxEntry entry) => [
    for (final stringEntry in entry.stringEntries)
      if (PasskeyParser.isPasskeyKey(stringEntry.key.key))
        VaultCustomField(
          key: stringEntry.key.key,
          value: stringEntry.value?.getText() ?? '',
          isProtected: stringEntry.value is ProtectedValue,
        ),
  ];

  List<VaultPasskey> _mapPasskeys(KdbxEntry entry) =>
      const PasskeyParser().parse(
        _passkeyRawFields(entry),
        createdAt: entry.times.creationTime.get()?.toLocal(),
      );

  /// Order-independent fingerprint of the raw passkey fields (values and
  /// protection flag included), so two revisions can be told apart without
  /// carrying the material. `null` when the entry holds none.
  String? _passkeyDigest(KdbxEntry entry) {
    final raw = _passkeyRawFields(entry);
    if (raw.isEmpty) return null;
    final pairs =
        raw
            .map((f) => '${f.key}\u0000${f.isProtected}\u0000${f.value}')
            .toList()
          ..sort();
    return sha256.convert(utf8.encode(pairs.join('\u0001'))).toString();
  }

  /// spec 017 T103 — a KDBX history record projected onto the domain model.
  /// Attachment *names* only: a revision's bytes are never read (FR-006a).
  DateTime _revisionTime(KdbxEntry revision) =>
      (revision.times.lastModificationTime.get() ??
              revision.times.creationTime.get() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
          .toUtc();

  VaultEntryRevision _mapRevision(
    String entryId,
    KdbxEntry revision, {
    int ordinal = 0,
  }) {
    final customFields = _mapCustomFields(revision);

    return VaultEntryRevision(
      entryId: entryId,
      replacedAt: _revisionTime(revision),
      ordinal: ordinal,
      title: revision.getString(KdbxKeyCommon.TITLE)?.getText() ?? '',
      username: revision.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '',
      password: revision.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '',
      url: revision.getString(KdbxKeyCommon.URL)?.getText() ?? '',
      notes: revision.getString(_notesKey)?.getText() ?? '',
      customFields: customFields,
      attachmentNames: revision.binaryEntries
          .map((binaryEntry) => binaryEntry.key.key)
          .toList(growable: false),
      passkeyDigest: _passkeyDigest(revision),
      otpUri: _resolveOtpUri(customFields),
    );
  }

  VaultEntry _mapEntry(String groupId, KdbxEntry entry) {
    final customFields = _mapCustomFields(entry);

    final attachments = entry.binaryEntries
        .map(
          (binaryEntry) => VaultAttachment(
            key: binaryEntry.key.key,
            name: binaryEntry.key.key,
            size: binaryEntry.value.value.length,
          ),
        )
        .toList(growable: false);

    final otpUri = _resolveOtpUri(customFields);
    final createdAt = entry.times.creationTime.get()?.toLocal();
    final updatedAt = entry.times.lastModificationTime.get()?.toLocal();

    return VaultEntry(
      id: entry.uuid.uuid,
      groupId: groupId,
      title: entry.getString(KdbxKeyCommon.TITLE)?.getText() ?? '',
      username: entry.getString(KdbxKeyCommon.USER_NAME)?.getText() ?? '',
      password: entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '',
      url: entry.getString(KdbxKeyCommon.URL)?.getText() ?? '',
      notes: entry.getString(_notesKey)?.getText() ?? '',
      customFields: customFields,
      attachments: attachments,
      passkeys: _mapPasskeys(entry),
      passkeyDigest: _passkeyDigest(entry),
      otpUri: otpUri,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastPasswordChangedAt: _resolveLastPasswordChangedAt(
        entry,
        fallbackCreatedAt: createdAt,
      ),
    );
  }

  DateTime? _resolveLastPasswordChangedAt(
    KdbxEntry entry, {
    DateTime? fallbackCreatedAt,
  }) {
    final revisions = <KdbxEntry>[...entry.history, entry]
      ..sort((left, right) {
        final leftTime =
            left.times.lastModificationTime.get() ??
            left.times.creationTime.get() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        final rightTime =
            right.times.lastModificationTime.get() ??
            right.times.creationTime.get() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        return leftTime.compareTo(rightTime);
      });

    if (revisions.isEmpty) {
      return fallbackCreatedAt;
    }

    var previousPassword = _passwordOf(revisions.first);
    DateTime? lastChangedUtc;

    for (var i = 1; i < revisions.length; i++) {
      final current = revisions[i];
      final currentPassword = _passwordOf(current);
      if (currentPassword != previousPassword) {
        lastChangedUtc =
            current.times.lastModificationTime.get() ??
            current.times.creationTime.get();
      }
      previousPassword = currentPassword;
    }

    if (lastChangedUtc != null) {
      return lastChangedUtc.toLocal();
    }

    return fallbackCreatedAt ??
        revisions.first.times.creationTime.get()?.toLocal();
  }

  String _passwordOf(KdbxEntry entry) {
    return entry.getString(KdbxKeyCommon.PASSWORD)?.getText() ?? '';
  }

  String? _resolveOtpUri(List<VaultCustomField> customFields) {
    for (final field in customFields) {
      final key = field.key.toLowerCase().trim();
      final value = field.value.trim();
      final looksLikeOtpField =
          key == 'otp' ||
          key == 'totp' ||
          key == 'otpauth' ||
          key.contains('otp');
      if (looksLikeOtpField && value.startsWith('otpauth://')) {
        return value;
      }
    }
    return null;
  }

  /// Replaces the editable custom fields. The `KPEX_PASSKEY_*` namespace is
  /// never removed or written here, so an ordinary edit leaves a passkey
  /// byte-identical (spec 023 FR-003); only `deletePasskey` touches it.
  void _setCustomFields(KdbxEntry entry, List<VaultCustomField> customFields) {
    final keysToRemove = entry.stringEntries
        .map((entry) => entry.key)
        .where(
          (key) =>
              !_standardEntryKeys.contains(key.key.toLowerCase()) &&
              !PasskeyParser.isPasskeyKey(key.key),
        )
        .toList(growable: false);

    for (final key in keysToRemove) {
      entry.removeString(key);
    }

    for (final field in customFields) {
      final normalizedKey = field.key.trim();
      if (normalizedKey.isEmpty || PasskeyParser.isPasskeyKey(normalizedKey)) {
        continue;
      }
      entry.setString(
        KdbxKey(normalizedKey),
        field.isProtected
            ? ProtectedValue.fromString(field.value)
            : PlainValue(field.value),
      );
    }
  }

  KdbxGroup _resolveRestoreTargetGroup(KdbxFile file, KdbxObject object) {
    final previousParentUuid = object.previousParentGroup.get();
    if (previousParentUuid != null) {
      try {
        final previousParent = file.findGroupByUuid(previousParentUuid);
        if (!previousParent.isInRecycleBin()) {
          return previousParent;
        }
      } catch (_) {
        // Ignore and fallback to root group.
      }
    }
    return file.body.rootGroup;
  }
}
