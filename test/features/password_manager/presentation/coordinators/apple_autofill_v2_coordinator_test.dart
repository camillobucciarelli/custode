import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/repositories/autofill_ports.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/domain/services/apple_autofill_v2_payload_mapper.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';

void main() {
  group('AppleAutofillV2Coordinator', () {
    test(
      'publishes mapped vault entries without exposing raw database path',
      () async {
        final client = _FakeAppleAutofillV2Client();
        final coordinator = AppleAutofillV2Coordinator(
          client: client,
          mapper: const AppleAutofillV2PayloadMapper(),
        );

        await coordinator.publishVault(
          databasePath: '/private/vaults/main.kdbx',
          entries: [_entry()],
        );

        expect(client.publishedCredentials.single.id, 'entry-1');
        expect(client.publishedCredentials.single.password, 'pw');
        expect(client.publishedDatabaseId, startsWith('sha256:'));
        expect(
          client.publishedDatabaseId,
          _databaseIdForPath('/private/vaults/main.kdbx'),
        );
        expect(client.publishedDatabaseId, isNot(contains('/private/vaults')));
        expect(
          client.publishedAuthSessionTtlMs,
          AppleAutofillV2Coordinator.authSessionTtl.inMilliseconds,
        );
      },
    );

    // T036: a registered vault is published under its registry id, which
    // does not move with the path. Unregistered paths keep the path hash
    // (the test above, which has no registry).
    test('publishes a registered vault under its registry id', () async {
      final client = _FakeAppleAutofillV2Client();
      final registry = _FakeRegistry('/private/vaults/main.kdbx');
      final coordinator = AppleAutofillV2Coordinator(
        client: client,
        mapper: const AppleAutofillV2PayloadMapper(),
        databaseRegistry: registry,
      );

      await coordinator.publishVault(
        databasePath: '/private/vaults/main.kdbx',
        entries: [_entry()],
      );
      expect(client.publishedDatabaseId, 'reg:vault-1');

      registry.path = '/relocated/main.kdbx';
      await coordinator.publishVault(
        databasePath: '/relocated/main.kdbx',
        entries: [_entry()],
      );
      expect(client.publishedDatabaseId, 'reg:vault-1');

      await coordinator.publishVault(
        databasePath: '/private/vaults/unregistered.kdbx',
        entries: [_entry()],
      );
      expect(
        client.publishedDatabaseId,
        _databaseIdForPath('/private/vaults/unregistered.kdbx'),
      );
    });

    test('readPendingAssociations accepts the registry id and the legacy '
        'path hash of the open vault, nothing else', () async {
      const databasePath = '/private/vaults/main.kdbx';
      final client = _FakeAppleAutofillV2Client()
        ..pendingAssociations = [
          _pendingAssociation(id: 'p-reg', databaseId: 'reg:vault-1'),
          _pendingAssociation(
            id: 'p-legacy',
            databaseId: _databaseIdForPath(databasePath),
          ),
          _pendingAssociation(id: 'p-other', databaseId: 'reg:vault-2'),
          _pendingAssociation(id: 'p-bare', databaseId: 'vault-1'),
        ];
      final coordinator = AppleAutofillV2Coordinator(
        client: client,
        mapper: const AppleAutofillV2PayloadMapper(),
        databaseRegistry: _FakeRegistry(databasePath),
      );

      final pending = await coordinator.readPendingAssociations(
        databasePath: databasePath,
      );

      expect(pending.map((p) => p.id), ['p-reg', 'p-legacy']);
    });

    test('clearCredentials delegates to client on Apple platforms', () async {
      final client = _FakeAppleAutofillV2Client();
      final coordinator = AppleAutofillV2Coordinator(
        client: client,
        mapper: const AppleAutofillV2PayloadMapper(),
      );

      await coordinator.clearCredentials();

      expect(client.clearCallCount, 1);
      expect(client.clearedDatabaseId, isNull);
    });

    test('readPendingAssociations filters by database hash', () async {
      const databasePath = '/private/vaults/main.kdbx';
      final databaseId = _databaseIdForPath(databasePath);
      final client = _FakeAppleAutofillV2Client()
        ..pendingAssociations = [
          _pendingAssociation(id: 'pending-1', databaseId: databaseId),
          _pendingAssociation(id: 'pending-2', databaseId: 'sha256:other'),
        ];
      final coordinator = AppleAutofillV2Coordinator(
        client: client,
        mapper: const AppleAutofillV2PayloadMapper(),
      );

      final pending = await coordinator.readPendingAssociations(
        databasePath: databasePath,
      );

      expect(client.readPendingCallCount, 1);
      expect(pending, [
        _pendingAssociation(id: 'pending-1', databaseId: databaseId),
      ]);
    });

    test('readPendingAssociations skips invalid database paths', () async {
      final client = _FakeAppleAutofillV2Client()
        ..pendingAssociations = [
          _pendingAssociation(id: 'pending-1', databaseId: 'sha256:any'),
        ];
      final coordinator = AppleAutofillV2Coordinator(
        client: client,
        mapper: const AppleAutofillV2PayloadMapper(),
      );

      final missingPath = await coordinator.readPendingAssociations();
      final blankPath = await coordinator.readPendingAssociations(
        databasePath: '   ',
      );

      expect(missingPath, isEmpty);
      expect(blankPath, isEmpty);
      expect(client.readPendingCallCount, 0);
    });

    test('clearPendingAssociations delegates ids to client', () async {
      final client = _FakeAppleAutofillV2Client();
      final coordinator = AppleAutofillV2Coordinator(
        client: client,
        mapper: const AppleAutofillV2PayloadMapper(),
      );

      await coordinator.clearPendingAssociations(ids: ['pending-1']);

      expect(client.clearPendingCallCount, 1);
      expect(client.clearedPendingIds, ['pending-1']);
    });

    test('clearPendingAssociations swallows client failures', () async {
      final client = _FakeAppleAutofillV2Client()
        ..clearPendingError = Exception('boom');
      final coordinator = AppleAutofillV2Coordinator(
        client: client,
        mapper: const AppleAutofillV2PayloadMapper(),
      );

      await coordinator.clearPendingAssociations(ids: ['pending-1']);

      expect(client.clearPendingCallCount, 1);
      expect(client.clearedPendingIds, ['pending-1']);
    });

    test(
      'noop returns empty pending associations and ignores clears',
      () async {
        const coordinator = NoopAppleAutofillV2Coordinator();

        final pending = await coordinator.readPendingAssociations(
          databasePath: '/db.kdbx',
        );
        await coordinator.clearPendingAssociations(ids: ['pending-1']);

        expect(pending, isEmpty);
      },
    );

    test(
      'unsupported platforms skip publish, clear, and pending calls',
      () async {
        final client = _FakeAppleAutofillV2Client(isSupported: false);
        final coordinator = AppleAutofillV2Coordinator(
          client: client,
          mapper: const AppleAutofillV2PayloadMapper(),
        );

        await coordinator.publishVault(
          databasePath: '/db.kdbx',
          entries: [_entry()],
        );
        await coordinator.clearCredentials();
        final pending = await coordinator.readPendingAssociations(
          databasePath: '/db.kdbx',
        );
        await coordinator.clearPendingAssociations(ids: ['pending-1']);

        expect(client.publishCallCount, 0);
        expect(client.clearCallCount, 0);
        expect(client.readPendingCallCount, 0);
        expect(client.clearPendingCallCount, 0);
        expect(pending, isEmpty);
      },
    );
  });
}

VaultEntry _entry() {
  return const VaultEntry(
    id: 'entry-1',
    groupId: 'root',
    title: 'Example',
    username: 'alice',
    password: 'pw',
    url: 'example.com',
    notes: '',
  );
}

AppleAutofillV2PendingAssociation _pendingAssociation({
  required String id,
  required String databaseId,
}) {
  return AppleAutofillV2PendingAssociation(
    id: id,
    databaseId: databaseId,
    entryId: 'entry-1',
    serviceIdentifierType: 'domain',
    serviceIdentifierValue: 'example.com',
    displayService: 'example.com',
    createdAtEpochMs: 1,
  );
}

String _databaseIdForPath(String databasePath) {
  return 'sha256:${sha256.convert(utf8.encode(databasePath.trim()))}';
}

class _FakeAppleAutofillV2Client implements AppleAutofillV2Client {
  _FakeAppleAutofillV2Client({this.isSupported = true});

  @override
  final bool isSupported;

  @override
  Future<bool?> getExtensionEnabled() async => null;

  @override
  Future<AndroidPasskeyProviderAvailability>
  getPasskeyProviderAvailability() async =>
      const AndroidPasskeyProviderAvailability.unsupported();

  int publishCallCount = 0;
  int clearCallCount = 0;
  int readPendingCallCount = 0;
  int clearPendingCallCount = 0;
  String? publishedDatabaseId;
  String? clearedDatabaseId;
  List<String>? clearedPendingIds;
  Object? clearPendingError;
  List<AppleAutofillV2Credential> publishedCredentials = const [];
  int? publishedAuthSessionTtlMs;
  List<AppleAutofillV2PendingAssociation> pendingAssociations = const [];

  @override
  Future<AppleAutofillV2PublishResult> publishCredentials({
    required String databaseId,
    required List<AppleAutofillV2Credential> credentials,
    int authSessionTtlMs = 0,
  }) async {
    publishCallCount += 1;
    publishedDatabaseId = databaseId;
    publishedCredentials = credentials;
    publishedAuthSessionTtlMs = authSessionTtlMs;
    return AppleAutofillV2PublishResult(
      publishedCount: credentials.length,
      skippedCount: 0,
      identityCount: credentials.length,
      identityStoreSynced: true,
    );
  }

  @override
  Future<AppleAutofillV2ClearResult> clearCredentials({
    String? databaseId,
  }) async {
    clearCallCount += 1;
    clearedDatabaseId = databaseId;
    return const AppleAutofillV2ClearResult(
      cleared: true,
      identityStoreCleared: true,
      keychainKeyCleared: true,
    );
  }

  @override
  Future<List<AppleAutofillV2PendingAssociation>>
  readPendingAssociations() async {
    readPendingCallCount += 1;
    return pendingAssociations;
  }

  @override
  Future<AppleAutofillV2ClearPendingAssociationsResult>
  clearPendingAssociations({List<String>? ids}) async {
    clearPendingCallCount += 1;
    clearedPendingIds = ids;
    final error = clearPendingError;
    if (error != null) {
      throw error;
    }
    return AppleAutofillV2ClearPendingAssociationsResult(
      clearedCount: ids?.length ?? pendingAssociations.length,
    );
  }

  @override
  Future<String?> takePendingCaptureToken() async => null;

  @override
  Future<AndroidAutofillCapture?> readPendingCapture(String token) async =>
      null;

  @override
  Future<AppleAutofillV2ClearPendingAssociationsResult> resolvePendingCapture({
    required String token,
    required AndroidAutofillCaptureOutcome outcome,
  }) async {
    return const AppleAutofillV2ClearPendingAssociationsResult(clearedCount: 0);
  }

  @override
  Future<AppleAutofillV2Status> getStatus() async {
    return const AppleAutofillV2Status(
      supported: true,
      version: 2,
      appGroupAvailable: true,
      keychainAccessGroupAvailable: true,
      metadataCount: 0,
      encryptedCacheAvailable: false,
      cacheAvailable: false,
    );
  }
}

class _FakeRegistry implements DatabaseRegistryRepository {
  _FakeRegistry(this.path);

  String path;

  @override
  Future<List<DatabaseRecord>> list() async => [
    DatabaseRecord(
      databaseId: 'vault-1',
      canonicalPath: path,
      displayName: 'Main',
      sourceType: DatabaseSourceType.local,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
