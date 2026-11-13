import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/repositories/autofill_ports.dart';
import 'package:password_manager/features/password_manager/domain/services/apple_autofill_v2_payload_mapper.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/android_autofill_save_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';

void main() {
  late _FakeClient client;
  late _FakeVaultKdbxService vaultKdbxService;
  late SessionSecretHolder sessionSecretHolder;
  late AndroidAutofillSaveCoordinator coordinator;

  setUp(() {
    client = _FakeClient();
    vaultKdbxService = _FakeVaultKdbxService();
    sessionSecretHolder = SessionSecretHolder()..set('master-password');
    coordinator = AndroidAutofillSaveCoordinator(
      client: client,
      mapper: const AppleAutofillV2PayloadMapper(),
      vaultKdbxService: vaultKdbxService,
      sessionSecretHolder: sessionSecretHolder,
    );
  });

  AndroidAutofillCapture capture({
    String username = 'alice',
    String password = 'submitted-secret',
    String? packageName = 'com.example.app',
    String? webDomain,
  }) {
    return AndroidAutofillCapture(
      token: 'token-1',
      username: username,
      password: password,
      packageName: packageName,
      webDomain: webDomain,
      capturedAtEpochMs: 1,
    );
  }

  VaultEntry entry({
    String id = 'entry-1',
    String username = 'alice',
    String url = '',
    List<VaultCustomField> customFields = const [],
  }) {
    return VaultEntry(
      id: id,
      groupId: 'root',
      title: 'Example',
      username: username,
      password: 'old-password',
      url: url,
      notes: '',
      customFields: customFields,
    );
  }

  group('decide', () {
    test('an empty vault yields a new entry', () {
      final pending = coordinator.decide(capture: capture(), entries: const []);

      expect(pending.kind, AndroidAutofillSaveKind.create);
      expect(pending.existingEntry, isNull);
    });

    test('the same site and username is an update', () {
      final existing = entry(url: 'https://example.com/login');

      final pending = coordinator.decide(
        capture: capture(packageName: null, webDomain: 'example.com'),
        entries: [existing],
      );

      expect(pending.kind, AndroidAutofillSaveKind.update);
      expect(pending.existingEntry, existing);
    });

    test('an app matches through its android package custom field', () {
      final existing = entry(
        customFields: const [
          VaultCustomField(key: 'AndroidPackage', value: 'com.example.app'),
        ],
      );

      final pending = coordinator.decide(
        capture: capture(),
        entries: [existing],
      );

      expect(pending.kind, AndroidAutofillSaveKind.update);
    });

    test('the same site under another username is a new entry', () {
      final pending = coordinator.decide(
        capture: capture(
          username: 'bob',
          packageName: null,
          webDomain: 'example.com',
        ),
        entries: [entry(url: 'https://example.com/login')],
      );

      expect(pending.kind, AndroidAutofillSaveKind.create);
    });

    test('a capture with no association is always a new entry', () {
      final pending = coordinator.decide(
        capture: capture(packageName: null),
        entries: [entry(url: 'https://example.com')],
      );

      expect(pending.kind, AndroidAutofillSaveKind.create);
    });
  });

  group('confirm', () {
    test(
      'a new capture is written as a new entry and resolves saved',
      () async {
        final result = await coordinator.confirm(
          pending: coordinator.decide(capture: capture(), entries: const []),
          databasePath: '/vault.kdbx',
          groupId: 'root',
        );

        expect(result.status, AndroidAutofillSaveStatus.created);
        expect(vaultKdbxService.createdPasswords, ['submitted-secret']);
        expect(vaultKdbxService.updatedEntryIds, isEmpty);
        expect(client.resolved, [
          ('token-1', AndroidAutofillCaptureOutcome.saved),
        ]);
      },
    );

    test('an update writes only the password and resolves updated', () async {
      final existing = entry(url: 'https://example.com');

      final result = await coordinator.confirm(
        pending: coordinator.decide(
          capture: capture(packageName: null, webDomain: 'example.com'),
          entries: [existing],
        ),
        databasePath: '/vault.kdbx',
        groupId: 'root',
      );

      expect(result.status, AndroidAutofillSaveStatus.updated);
      expect(vaultKdbxService.updatedEntryIds, ['entry-1']);
      expect(vaultKdbxService.updatedPasswords, ['submitted-secret']);
      expect(vaultKdbxService.updatedTitles, ['Example']);
      expect(client.resolved, [
        ('token-1', AndroidAutofillCaptureOutcome.updated),
      ]);
    });

    test('a locked vault writes nothing and reports not saved', () async {
      sessionSecretHolder.clear();

      final result = await coordinator.confirm(
        pending: coordinator.decide(capture: capture(), entries: const []),
        databasePath: '/vault.kdbx',
        groupId: 'root',
      );

      expect(result.status, AndroidAutofillSaveStatus.notSaved);
      expect(vaultKdbxService.createdPasswords, isEmpty);
      expect(client.resolved, [
        ('token-1', AndroidAutofillCaptureOutcome.cancelled),
      ]);
    });

    test('a failed write still resolves the token', () async {
      vaultKdbxService.failCreate = true;

      final result = await coordinator.confirm(
        pending: coordinator.decide(capture: capture(), entries: const []),
        databasePath: '/vault.kdbx',
        groupId: 'root',
      );

      expect(result.status, AndroidAutofillSaveStatus.failed);
      expect(client.resolved, [
        ('token-1', AndroidAutofillCaptureOutcome.failed),
      ]);
    });
  });

  group('takePendingSave', () {
    test('no pending token yields nothing', () async {
      expect(await coordinator.takePendingSave(entries: const []), isNull);
    });

    test('a pending token is read and decided', () async {
      client.pendingToken = 'token-1';
      client.capture = capture();

      final pending = await coordinator.takePendingSave(entries: const []);

      expect(pending?.kind, AndroidAutofillSaveKind.create);
      expect(client.resolved, isEmpty);
    });

    test('a capture that is already gone resolves nothing', () async {
      client.pendingToken = 'token-1';
      client.capture = null;

      expect(await coordinator.takePendingSave(entries: const []), isNull);
      expect(client.resolved, isEmpty);
    });

    test('a read failure resolves the token as failed', () async {
      client.pendingToken = 'token-1';
      client.readError = StateError('channel down');

      expect(await coordinator.takePendingSave(entries: const []), isNull);
      expect(client.resolved, [
        ('token-1', AndroidAutofillCaptureOutcome.failed),
      ]);
    });

    test('a held token is used without asking the native side twice', () async {
      client.pendingToken = 'token-1';
      client.capture = capture();

      expect(await coordinator.hasPendingCapture(), isTrue);
      client.pendingToken = null;

      final pending = await coordinator.takePendingSave(entries: const []);

      expect(pending?.kind, AndroidAutofillSaveKind.create);
      expect(client.tokenReads, 1);
    });

    test('abandoning a held capture cancels it right away', () async {
      client.pendingToken = 'token-1';
      expect(await coordinator.hasPendingCapture(), isTrue);

      await coordinator.abandonPendingCapture();

      expect(client.resolved, [
        ('token-1', AndroidAutofillCaptureOutcome.cancelled),
      ]);

      // Nothing is held any more, so a second abandon is a no-op.
      await coordinator.abandonPendingCapture();
      expect(client.resolved, hasLength(1));
    });

    test('nothing pending means nothing to abandon', () async {
      expect(await coordinator.hasPendingCapture(), isFalse);
      await coordinator.abandonPendingCapture();
      expect(client.resolved, isEmpty);
    });

    test('an unsupported platform is inert', () async {
      client.isSupported = false;

      expect(await coordinator.takePendingSave(entries: const []), isNull);
    });
  });

  test('declining is reported as declined so it is remembered', () async {
    final pending = coordinator.decide(capture: capture(), entries: const []);

    final result = await coordinator.decline(pending);

    expect(result.status, AndroidAutofillSaveStatus.notSaved);
    expect(client.resolved, [
      ('token-1', AndroidAutofillCaptureOutcome.declined),
    ]);
  });

  test('dismissing is reported as cancelled so it may prompt again', () async {
    final pending = coordinator.decide(capture: capture(), entries: const []);

    await coordinator.cancel(pending);

    expect(client.resolved, [
      ('token-1', AndroidAutofillCaptureOutcome.cancelled),
    ]);
  });
}

class _FakeVaultKdbxService implements VaultKdbxService {
  final List<String> createdPasswords = [];
  final List<String> updatedEntryIds = [];
  final List<String> updatedPasswords = [];
  final List<String> updatedTitles = [];
  bool failCreate = false;

  @override
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
  }) async {
    if (failCreate) {
      throw StateError('write failed');
    }
    createdPasswords.add(entryPassword);
    return 'new-entry';
  }

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
    updatedEntryIds.add(entryId);
    updatedPasswords.add(entryPassword);
    updatedTitles.add(title);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements AppleAutofillV2Client {
  @override
  bool isSupported = true;

  String? pendingToken;
  AndroidAutofillCapture? capture;
  Object? readError;
  final List<(String, AndroidAutofillCaptureOutcome)> resolved = [];

  int tokenReads = 0;

  @override
  Future<String?> takePendingCaptureToken() async {
    tokenReads += 1;
    return pendingToken;
  }

  @override
  Future<AndroidAutofillCapture?> readPendingCapture(String token) async {
    final error = readError;
    if (error != null) {
      throw error;
    }
    return capture;
  }

  @override
  Future<AppleAutofillV2ClearPendingAssociationsResult> resolvePendingCapture({
    required String token,
    required AndroidAutofillCaptureOutcome outcome,
  }) async {
    resolved.add((token, outcome));
    return const AppleAutofillV2ClearPendingAssociationsResult(clearedCount: 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
