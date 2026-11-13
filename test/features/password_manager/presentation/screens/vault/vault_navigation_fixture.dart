// spec-018: shared vault fixture for the navigation / record-action tests.
//
// `vault_shell_test_utils.dart`'s default fake serves an EMPTY vault, which
// is right for geometry goldens and useless for navigation: there is no row
// to activate. This fixture serves a small, stable vault AND records the
// mutating calls the BLoC makes, so a test can assert "the action actually
// reached the vault" rather than only "a dialog closed".
//
// Recording the calls is the point: spec-018's D5 is an action that is
// confirmed by the user and then silently dropped. A test that only checks
// the UI settled would pass against that bug.
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_attachment.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry_revision.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_group.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';

/// The passwords below are fixture data and are written to look like it.
///
/// They were high-entropy invented strings until GitGuardian's
/// "Username Password" detector flagged the `CB77219` pair on PR #175 — a
/// correct detection of a fake credential. They keep the length (16) and the
/// four character classes the strength strip needs to read `Strong`, so no
/// golden moves; what changed is that they no longer read as a credential in a
/// repository where a real one would matter.

/// One recorded mutating call against the vault.
class RecordedVaultCall {
  const RecordedVaultCall(
    this.kind,
    this.entryId, [
    this.fields = const {},
    this.customFields = const [],
  ]);

  final String kind;
  final String entryId;
  final Map<String, String> fields;

  /// spec 023 US1b: what the editor asked to persist, protection flag and
  /// all.
  final List<VaultCustomField> customFields;

  @override
  String toString() => 'RecordedVaultCall($kind, $entryId, $fields)';
}

class NavigationFixtureVaultKdbxService implements VaultKdbxService {
  NavigationFixtureVaultKdbxService();

  static const rootId = 'root';
  static const folderId = 'folder-devs';

  /// Every mutating call the BLoC made, in order.
  final List<RecordedVaultCall> calls = <RecordedVaultCall>[];

  /// When set, the next `updateEntry` throws it after recording the call, the
  /// way the real service does for an unreadable attachment source.
  Object? updateFailure;

  /// Ids removed by a recorded delete — the next `loadVault` omits them, so
  /// the "entry disappeared" path is exercised for real.
  final Set<String> _deleted = <String>{};

  /// Edits applied by a recorded update, so two consecutive edits can be
  /// asserted to compose rather than the second reverting the first (D4).
  final Map<String, VaultEntry> _updated = <String, VaultEntry>{};

  /// Records created by `duplicateEntry`, appended to the vault by [entries].
  final List<VaultEntry> _duplicates = <VaultEntry>[];

  /// Extra entries seeded on top of the three fixed ones, so a scenario can
  /// bring the shape it needs (spec 023 US1b: a protected custom field)
  /// without every other test seeing it.
  final List<VaultEntry> extraEntries = <VaultEntry>[];

  static const gmail = VaultEntry(
    id: 'entry-gmail',
    groupId: rootId,
    title: 'Gmail',
    username: 'me@example.com',
    password: 'Fixture-Pass-1a!',
    url: 'mail.google.com',
    notes: '',
  );
  static const github = VaultEntry(
    id: 'entry-github',
    groupId: folderId,
    title: 'GitHub',
    // spec-020: one record with attachments, so the count is exercised.
    attachments: [
      VaultAttachment(key: 'ssh', name: 'id_ed25519.pub', size: 98),
      VaultAttachment(key: 'recovery', name: 'recovery-codes.txt', size: 512),
    ],
    username: 'dev',
    password: 'Sample-Pass-2b!x',
    url: 'github.com',
    notes: '',
  );
  static const bank = VaultEntry(
    id: 'entry-bank',
    groupId: rootId,
    title: 'Banca Sella',
    username: 'CB77219',
    password: 'Dummy-Pass-3c!yz',
    url: 'sella.it',
    notes: '',
  );

  List<VaultEntry> get entries => <VaultEntry>[
    for (final entry in [gmail, github, bank, ...extraEntries])
      if (!_deleted.contains(entry.id)) _updated[entry.id] ?? entry,
    for (final entry in _duplicates)
      if (!_deleted.contains(entry.id)) _updated[entry.id] ?? entry,
  ];

  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async {
    final all = entries;
    return VaultSnapshot(
      rootGroupId: rootId,
      currentGroupId: currentGroupId ?? rootId,
      groups: const [
        VaultGroup(id: rootId, name: 'root', parentId: null),
        VaultGroup(id: folderId, name: 'Devs', parentId: rootId),
      ],
      entries: all,
      allEntries: all,
    );
  }

  @override
  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async => const [];

  @override
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
  }) async {
    calls.add(
      RecordedVaultCall('update', entryId, {
        'title': title,
        'username': username,
        'url': url,
        'notes': notes,
        if (addedAttachmentPaths.isNotEmpty)
          'added': addedAttachmentPaths.join(','),
        if (removedAttachmentKeys.isNotEmpty)
          'removed': removedAttachmentKeys.join(','),
      }, customFields),
    );
    final failure = updateFailure;
    if (failure != null) {
      throw failure;
    }
    final base =
        _updated[entryId] ??
        entries.firstWhere((entry) => entry.id == entryId, orElse: () => gmail);
    _updated[entryId] = VaultEntry(
      id: base.id,
      groupId: base.groupId,
      title: title,
      username: username,
      password: entryPassword,
      url: url,
      notes: notes,
      customFields: customFields,
      // The next `loadVault` omits a removed attachment, so the detail the
      // user lands on after a save shows what the file now holds.
      attachments: [
        for (final attachment in base.attachments)
          if (!removedAttachmentKeys.contains(attachment.key)) attachment,
      ],
    );
  }

  @override
  Future<void> addAttachment({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String filePath,
  }) async {
    calls.add(RecordedVaultCall('addAttachment', entryId, {'path': filePath}));
  }

  @override
  Future<void> deleteEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    bool permanently = false,
  }) async {
    calls.add(RecordedVaultCall('delete', entryId));
    _deleted.add(entryId);
  }

  /// spec-019 C-04-05: the copy the real service makes inside the database,
  /// modelled here as a sibling record so the list has something to show.
  @override
  Future<String> duplicateEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String titleSuffix,
  }) async {
    calls.add(RecordedVaultCall('duplicate', entryId));
    final source = entries.firstWhere((entry) => entry.id == entryId);
    final copy = VaultEntry(
      id: '$entryId-copy',
      groupId: source.groupId,
      title: '${source.title}$titleSuffix',
      username: source.username,
      password: source.password,
      url: source.url,
      notes: source.notes,
      customFields: source.customFields,
    );
    _duplicates.add(copy);
    return copy.id;
  }

  /// spec 017: this record's previous versions, by entry id. A record with
  /// no entry here has an empty history — the same answer the real service
  /// gives for one that was never edited.
  final Map<String, VaultEntryHistory> histories =
      <String, VaultEntryHistory>{};

  /// Every entry whose history was read, in order.
  final List<String> historyReads = <String>[];

  @override
  Future<VaultEntryHistory> loadEntryHistory({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
  }) async {
    historyReads.add(entryId);
    return histories[entryId] ??
        const VaultEntryHistory(
          revisions: [],
          retention: VaultHistoryRetention(maxItems: 10),
        );
  }

  /// spec 017 T403: recorded like every other mutating call; the next read
  /// of that entry's history omits the revision, so the list updates.
  @override
  Future<void> deleteEntryRevision({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required DateTime replacedAt,
    int ordinal = 0,
  }) async {
    calls.add(
      RecordedVaultCall('deleteRevision', entryId, {
        'replacedAt': replacedAt.toIso8601String(),
      }),
    );
    final history = histories[entryId];
    if (history == null) return;
    histories[entryId] = VaultEntryHistory(
      revisions: [
        for (final revision in history.revisions)
          if (revision.replacedAt != replacedAt) revision,
      ],
      retention: history.retention,
    );
  }

  @override
  Future<void> moveEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String targetGroupId,
  }) async {
    calls.add(
      RecordedVaultCall('move', entryId, {'targetGroupId': targetGroupId}),
    );
  }

  @override
  Future<String> exportAttachment({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String attachmentKey,
    required String destinationDirectory,
  }) async {
    calls.add(
      RecordedVaultCall('exportAttachment', entryId, {
        'key': attachmentKey,
        'directory': destinationDirectory,
      }),
    );
    return '$destinationDirectory/$attachmentKey';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
