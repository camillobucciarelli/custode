import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/database_dedup_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/domain/usecases/resolve_database_duplicate_usecase.dart';

import '../../presentation/coordinators/fake_database_ports.dart';

void main() {
  group('ResolveDatabaseDuplicateUseCase', () {
    late _FakeDatabaseRegistryRepository repository;
    late FakeDatabaseSyncRepository sync;
    late ResolveDatabaseDuplicateUseCase useCase;

    setUp(() {
      repository = _FakeDatabaseRegistryRepository();
      sync = FakeDatabaseSyncRepository();
      useCase = ResolveDatabaseDuplicateUseCase(repository, sync);
    });

    group('a database linked to the remote file from Sync (spec 025 F5)', () {
      // Local `sourceType`, different content and name: only the sync
      // mapping says the incoming remote file is already here.
      setUp(() {
        repository.records = [
          DatabaseRecord(
            databaseId: 'linked',
            canonicalPath: '/tmp/linked.kdbx',
            displayName: 'Work.kdbx',
            sourceType: DatabaseSourceType.local,
            fileHash: 'local-hash',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ];
        sync.mappings['/tmp/linked.kdbx'] = const DatabaseSyncMapping(
          databaseId: 'linked',
          databasePath: '/tmp/linked.kdbx',
          providerId: 'google_drive',
          remoteFileId: 'remote-1',
          remoteFileName: 'Personal.kdbx',
        );
      });

      Future<DatabaseDedupResult> incoming({
        String providerId = 'google_drive',
        String remoteFileId = 'remote-1',
      }) => useCase(
        sourceType: DatabaseSourceType.drive,
        sourceRef: remoteFileId,
        remoteProviderId: providerId,
        fileHash: 'remote-hash',
        displayName: 'Personal.kdbx',
      );

      test('is a source match on the mapped record', () async {
        final result = await incoming();

        expect(result.matchType, DatabaseDuplicateMatchType.source);
        expect(result.resolution, DatabaseDuplicateResolution.useExisting);
        expect(result.existingRecord?.databaseId, 'linked');
      });

      test('the same file id under another provider is not a match', () async {
        expect((await incoming(providerId: 'other')).hasDuplicate, isFalse);
      });

      test('another remote file is not a match', () async {
        expect(
          (await incoming(remoteFileId: 'remote-2')).hasDuplicate,
          isFalse,
        );
      });

      test('unreadable sync metadata degrades to the other checks', () async {
        sync.mappingError = StateError('mapping store unreadable');

        expect((await incoming()).hasDuplicate, isFalse);
      });
    });

    test('returns source duplicate when sourceRef matches', () async {
      final existing = DatabaseRecord(
        databaseId: 'db1',
        canonicalPath: '/tmp/a.kdbx',
        displayName: 'a.kdbx',
        sourceType: DatabaseSourceType.drive,
        sourceRef: 'drive-file-1',
        fileHash: 'hash-a',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repository.records = [existing];

      final result = await useCase(
        sourceType: DatabaseSourceType.drive,
        sourceRef: 'drive-file-1',
        fileHash: 'hash-b',
      );

      expect(result.matchType, DatabaseDuplicateMatchType.source);
      expect(result.resolution, DatabaseDuplicateResolution.useExisting);
      expect(result.existingRecord?.databaseId, 'db1');
    });

    test('returns hash duplicate when hash matches', () async {
      final existing = DatabaseRecord(
        databaseId: 'db2',
        canonicalPath: '/tmp/b.kdbx',
        displayName: 'b.kdbx',
        sourceType: DatabaseSourceType.local,
        fileHash: 'same-hash',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repository.records = [existing];

      final result = await useCase(
        sourceType: DatabaseSourceType.local,
        fileHash: 'same-hash',
      );

      expect(result.matchType, DatabaseDuplicateMatchType.hash);
      expect(result.existingRecord?.databaseId, 'db2');
    });

    test('returns name duplicate when only the display name matches', () async {
      repository.records = [
        DatabaseRecord(
          databaseId: 'db3',
          canonicalPath: '/tmp/c.kdbx',
          displayName: 'Personal.kdbx',
          sourceType: DatabaseSourceType.local,
          fileHash: 'hash-c',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      final result = await useCase(
        sourceType: DatabaseSourceType.drive,
        sourceRef: 'other-remote',
        fileHash: 'other-hash',
        displayName: ' Personal.kdbx ',
      );

      expect(result.matchType, DatabaseDuplicateMatchType.name);
      expect(result.existingRecord?.databaseId, 'db3');
    });

    test('source beats hash beats name', () async {
      DatabaseRecord record(String id, {String? ref, String? hash}) =>
          DatabaseRecord(
            databaseId: id,
            canonicalPath: '/tmp/$id.kdbx',
            displayName: 'Same.kdbx',
            sourceType: DatabaseSourceType.drive,
            sourceRef: ref,
            fileHash: hash,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
      repository.records = [
        record('by-name'),
        record('by-hash', hash: 'h'),
        record('by-source', ref: 'r'),
      ];

      final all = await useCase(
        sourceType: DatabaseSourceType.drive,
        sourceRef: 'r',
        fileHash: 'h',
        displayName: 'Same.kdbx',
      );
      final hashAndName = await useCase(
        sourceType: DatabaseSourceType.drive,
        fileHash: 'h',
        displayName: 'Same.kdbx',
      );

      expect(all.existingRecord?.databaseId, 'by-source');
      expect(all.matchType, DatabaseDuplicateMatchType.source);
      expect(hashAndName.existingRecord?.databaseId, 'by-hash');
      expect(hashAndName.matchType, DatabaseDuplicateMatchType.hash);
    });

    test(
      'a different name is not a duplicate and no name skips the check',
      () async {
        repository.records = [
          DatabaseRecord(
            databaseId: 'db4',
            canonicalPath: '/tmp/d.kdbx',
            displayName: 'Personal.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        ];

        final other = await useCase(
          sourceType: DatabaseSourceType.local,
          displayName: 'Family.kdbx',
        );
        final none = await useCase(sourceType: DatabaseSourceType.local);

        expect(other.hasDuplicate, isFalse);
        expect(none.hasDuplicate, isFalse);
      },
    );

    test('returns no duplicate when there is no match', () async {
      repository.records = [];

      final result = await useCase(
        sourceType: DatabaseSourceType.local,
        sourceRef: 'x',
        fileHash: 'y',
      );

      expect(result.matchType, DatabaseDuplicateMatchType.none);
      expect(result.hasDuplicate, isFalse);
      expect(result.existingRecord, isNull);
    });
  });
}

class _FakeDatabaseRegistryRepository implements DatabaseRegistryRepository {
  List<DatabaseRecord> records = [];

  @override
  Future<List<DatabaseRecord>> list() async => records;

  @override
  Future<DatabaseRecord?> getById(String databaseId) async {
    for (final record in records) {
      if (record.databaseId == databaseId) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<DatabaseRecord?> findBySource({
    required DatabaseSourceType sourceType,
    required String sourceRef,
  }) async {
    for (final record in records) {
      if (record.sourceType == sourceType && record.sourceRef == sourceRef) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<DatabaseRecord?> findByHash(String fileHash) async {
    for (final record in records) {
      if (record.fileHash == fileHash) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<void> upsert(DatabaseRecord record) async {
    records = [
      ...records.where((item) => item.databaseId != record.databaseId),
      record,
    ];
  }

  @override
  Future<void> remove(String databaseId) async {
    records = records.where((item) => item.databaseId != databaseId).toList();
  }

  @override
  Future<void> setActive(String? databaseId) async {}

  @override
  Future<String?> getActive() async => null;
}
