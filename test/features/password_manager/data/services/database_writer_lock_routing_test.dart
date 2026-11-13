import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:password_manager/features/password_manager/data/datasources/sync_metadata_data_source.dart';
import 'package:password_manager/features/password_manager/data/services/database_file_hash_recorder.dart';
import 'package:password_manager/features/password_manager/data/services/database_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/database_path_mutex.dart';
import 'package:password_manager/features/password_manager/data/services/database_sync_orchestrator.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_transaction.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/repositories/cloud_storage_provider.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/usecases/validate_database_usecase.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'lock_routing_test_mutexes.dart';

// =============================================================================
// spec 008 Gate 1 T105 — executable no-bypass guard.
//
// For every frozen writer entry point (T101 inventory) two things are proven:
//
//   1. KILL-CHECK: driven through a mutex that refuses the lock, the writer
//      throws and the filesystem is untouched. Unwrapping any entry point
//      (writing before/outside `withDatabaseLock`) makes the write land
//      despite the refused lock and fails the untouched assertion.
//   2. ANTI-NESTING: driven through a recording pass-through mutex, the
//      writer succeeds, every acquisition names the database path(s) it
//      mutates, and the nesting depth never exceeds 1 — the real mutex is
//      not reentrant, so depth 2 in production is a deadlock.
//
// The static half of the guard (the exact set of files allowed to reference
// the mutex, and the frozen mutation-site counts that catch a NEW write site)
// lives in `database_writer_inventory_test.dart`.
// =============================================================================

const _password = 'test-password';

/// Minimal bytes `ValidateDatabaseUseCase` accepts: KDBX magic + padding.
final Uint8List _kdbxMagic = Uint8List.fromList([
  0x03, 0xD9, 0xA2, 0x9A, // signature 1: 0x9AA2D903 little-endian
  0x67, 0xFB, 0x4B, 0xB5, // signature 2: 0xB54BFB67 little-endian
  0, 0, 0, 0,
]);

void main() {
  group('VaultKdbxService lock routing', () {
    late Directory tempDir;
    late String databasePath;
    late VaultKdbxService setup;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('kdbx_lock_routing_');
      databasePath = p.join(tempDir.path, 'vault.kdbx');
      setup = VaultKdbxService(mutex: RecordingDatabasePathMutex());
      final credentials = Credentials(ProtectedValue.fromString(_password));
      final kdbx = KdbxFormat().create(credentials, 'Routing');
      await File(databasePath).writeAsBytes(await kdbx.save(), flush: true);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<String> rootGroupId() async {
      final snapshot = await setup.loadVault(
        databasePath: databasePath,
        password: _password,
      );
      return snapshot.rootGroupId;
    }

    Future<String> newEntry({String title = 'entry'}) async {
      return setup.createEntry(
        databasePath: databasePath,
        password: _password,
        groupId: await rootGroupId(),
        title: title,
        username: 'user',
        entryPassword: 'secret',
        url: '',
        notes: '',
      );
    }

    Future<String> newGroup(String name) async {
      await setup.createGroup(
        databasePath: databasePath,
        password: _password,
        parentGroupId: await rootGroupId(),
        name: name,
      );
      final snapshot = await setup.loadVault(
        databasePath: databasePath,
        password: _password,
      );
      return snapshot.groups.firstWhere((group) => group.name == name).id;
    }

    Future<String> attachmentSource() async {
      final source = File(p.join(tempDir.path, 'attachment.bin'));
      await source.writeAsBytes(const [1, 2, 3], flush: true);
      return source.path;
    }

    /// Runs the shared kill-check + anti-nesting assertions for one entry
    /// point. [run] is invoked twice on the same on-disk state: once with a
    /// refusing mutex (must throw, must not write) and once with a recording
    /// mutex (must succeed, single-depth, locking [expectedPath]).
    Future<void> check(
      Future<void> Function(VaultKdbxService service) run, {
      String? expectedPath,
    }) async {
      final before = await File(databasePath).readAsBytes();
      await expectLater(
        () => run(VaultKdbxService(mutex: RefusingDatabasePathMutex())),
        throwsA(isA<LockRefused>()),
      );
      expect(
        await File(databasePath).readAsBytes(),
        before,
        reason: 'the entry point mutated the database without holding a lock',
      );

      final recording = RecordingDatabasePathMutex();
      await run(VaultKdbxService(mutex: recording));
      expect(recording.acquisitions, isNotEmpty);
      for (final acquisition in recording.acquisitions) {
        expect(acquisition, contains(expectedPath ?? databasePath));
      }
      expect(
        recording.maxDepth,
        1,
        reason:
            'a routed writer called another routed writer inside its action '
            '— the mutex is not reentrant, this deadlocks in production',
      );
    }

    test('createEntry', () async {
      final groupId = await rootGroupId();
      await check(
        (service) async => service.createEntry(
          databasePath: databasePath,
          password: _password,
          groupId: groupId,
          title: 't',
          username: 'u',
          entryPassword: 'p',
          url: '',
          notes: '',
        ),
      );
    });

    test('updateEntry', () async {
      final entryId = await newEntry();
      await check(
        (service) => service.updateEntry(
          databasePath: databasePath,
          password: _password,
          entryId: entryId,
          title: 't2',
          username: 'u',
          entryPassword: 'p',
          url: '',
          notes: '',
        ),
      );
    });

    test('mergeEntries', () async {
      final primary = await newEntry(title: 'a');
      final secondary = await newEntry(title: 'b');
      await check(
        (service) => service.mergeEntries(
          databasePath: databasePath,
          password: _password,
          primaryId: primary,
          secondaryIds: [secondary],
        ),
      );
    });

    test('addAttachment', () async {
      final entryId = await newEntry();
      final sourcePath = await attachmentSource();
      await check(
        (service) => service.addAttachment(
          databasePath: databasePath,
          password: _password,
          entryId: entryId,
          filePath: sourcePath,
        ),
      );
    });

    test('exportAttachment locks database and destination', () async {
      final entryId = await newEntry();
      final sourcePath = await attachmentSource();
      await setup.addAttachment(
        databasePath: databasePath,
        password: _password,
        entryId: entryId,
        filePath: sourcePath,
      );
      final destinationDir = Directory(p.join(tempDir.path, 'export'));
      await destinationDir.create();
      final destination = p.join(destinationDir.path, 'attachment.bin');

      await expectLater(
        () =>
            VaultKdbxService(mutex: RefusingDatabasePathMutex())
                .exportAttachment(
                  databasePath: databasePath,
                  password: _password,
                  entryId: entryId,
                  attachmentKey: 'attachment.bin',
                  destinationDirectory: destinationDir.path,
                ),
        throwsA(isA<LockRefused>()),
      );
      expect(File(destination).existsSync(), isFalse);

      final recording = RecordingDatabasePathMutex();
      await VaultKdbxService(mutex: recording).exportAttachment(
        databasePath: databasePath,
        password: _password,
        entryId: entryId,
        attachmentKey: 'attachment.bin',
        destinationDirectory: destinationDir.path,
      );
      expect(File(destination).existsSync(), isTrue);
      expect(recording.acquisitions, [
        [databasePath, destination],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('deleteEntry', () async {
      final entryId = await newEntry();
      await check(
        (service) => service.deleteEntry(
          databasePath: databasePath,
          password: _password,
          entryId: entryId,
        ),
      );
    });

    test('moveEntry', () async {
      final entryId = await newEntry();
      final groupId = await newGroup('target');
      await check(
        (service) => service.moveEntry(
          databasePath: databasePath,
          password: _password,
          entryId: entryId,
          targetGroupId: groupId,
        ),
      );
    });

    test('createGroup', () async {
      final parentId = await rootGroupId();
      await check(
        (service) => service.createGroup(
          databasePath: databasePath,
          password: _password,
          parentGroupId: parentId,
          name: 'new-group',
        ),
      );
    });

    test('renameGroup', () async {
      final groupId = await newGroup('old-name');
      await check(
        (service) => service.renameGroup(
          databasePath: databasePath,
          password: _password,
          groupId: groupId,
          newName: 'new-name',
        ),
      );
    });

    test('deleteGroup', () async {
      final groupId = await newGroup('doomed');
      await check(
        (service) => service.deleteGroup(
          databasePath: databasePath,
          password: _password,
          groupId: groupId,
        ),
      );
    });

    test('moveGroup', () async {
      final groupId = await newGroup('mover');
      final targetId = await newGroup('destination');
      await check(
        (service) => service.moveGroup(
          databasePath: databasePath,
          password: _password,
          groupId: groupId,
          targetGroupId: targetId,
        ),
      );
    });

    test('restoreEntryFromRecycleBin', () async {
      final entryId = await newEntry();
      await setup.deleteEntry(
        databasePath: databasePath,
        password: _password,
        entryId: entryId,
      );
      await check(
        (service) => service.restoreEntryFromRecycleBin(
          databasePath: databasePath,
          password: _password,
          entryId: entryId,
        ),
      );
    });

    test('restoreGroupFromRecycleBin', () async {
      final groupId = await newGroup('binned');
      await setup.deleteGroup(
        databasePath: databasePath,
        password: _password,
        groupId: groupId,
      );
      await check(
        (service) => service.restoreGroupFromRecycleBin(
          databasePath: databasePath,
          password: _password,
          groupId: groupId,
        ),
      );
    });

    test('deleteEntryPermanently', () async {
      final entryId = await newEntry();
      await setup.deleteEntry(
        databasePath: databasePath,
        password: _password,
        entryId: entryId,
      );
      await check(
        (service) => service.deleteEntryPermanently(
          databasePath: databasePath,
          password: _password,
          entryId: entryId,
        ),
      );
    });

    test('deleteGroupPermanently', () async {
      final groupId = await newGroup('binned-group');
      await setup.deleteGroup(
        databasePath: databasePath,
        password: _password,
        groupId: groupId,
      );
      await check(
        (service) => service.deleteGroupPermanently(
          databasePath: databasePath,
          password: _password,
          groupId: groupId,
        ),
      );
    });

    test('emptyRecycleBin', () async {
      final entryId = await newEntry();
      await setup.deleteEntry(
        databasePath: databasePath,
        password: _password,
        entryId: entryId,
      );
      await check(
        (service) => service.emptyRecycleBin(
          databasePath: databasePath,
          password: _password,
        ),
      );
    });

    test('beginCredentialChange', () async {
      await check(
        (service) => service.beginCredentialChange(
          databasePath: databasePath,
          currentPassword: _password,
          newPassword: 'next-password',
        ),
      );
    });

    test('finalizeCredentialChange', () async {
      final change = await setup.beginCredentialChange(
        databasePath: databasePath,
        currentPassword: _password,
        newPassword: 'next-password',
      );
      await check((service) => service.finalizeCredentialChange(change));
      expect(File(change.backupPath).existsSync(), isFalse);
    });

    test('rollbackCredentialChange', () async {
      final change = await setup.beginCredentialChange(
        databasePath: databasePath,
        currentPassword: _password,
        newPassword: 'next-password',
      );
      await check((service) => service.rollbackCredentialChange(change));
      // Rolled back: the original password opens the file again.
      await expectLater(
        setup.loadVault(databasePath: databasePath, password: _password),
        completes,
      );
    });
  });

  group('DatabaseImportService lock routing', () {
    late Directory tempDir;
    late Directory docsDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('import_lock_routing_');
      docsDir = Directory(p.join(tempDir.path, 'docs'));
      await docsDir.create();
      PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    DatabaseImportService service(
      DatabasePathMutex mutex, {
      Future<void> Function()? afterCommitInstall,
      DatabaseFileHashRecorder? fileHashRecorder,
    }) {
      return DatabaseImportService(
        validateDatabaseUseCase: ValidateDatabaseUseCase(),
        mutex: mutex,
        afterCommitInstall: afterCommitInstall,
        fileHashRecorder: fileHashRecorder,
      );
    }

    Future<File> tempFile(String name, List<int> bytes) async {
      final file = File(p.join(tempDir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      return file;
    }

    Future<File> stagedFile(String name, List<int> bytes) async {
      final dir = Directory(p.join(docsDir.path, 'database_imports'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      return file;
    }

    StagedDatabaseImport stagedImport(File file) {
      return StagedDatabaseImport(
        imported: DatabaseImportResult(
          path: file.path,
          fileName: p.basename(file.path),
          fileHash: md5.convert(file.readAsBytesSync()).toString(),
          sourceType: DatabaseSourceType.local,
        ),
        preferredFileName: p.basename(file.path),
      );
    }

    test('copyFile', () async {
      final source = await tempFile('source.kdbx', const [1, 2, 3]);
      final target = p.join(tempDir.path, 'copy.kdbx');

      await expectLater(
        () =>
            service(RefusingDatabasePathMutex())
                .copyFile(sourcePath: source.path, targetPath: target),
        throwsA(isA<LockRefused>()),
      );
      expect(File(target).existsSync(), isFalse);

      final recording = RecordingDatabasePathMutex();
      await service(recording)
          .copyFile(sourcePath: source.path, targetPath: target);
      expect(File(target).existsSync(), isTrue);
      expect(recording.acquisitions, [
        [source.path, target],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('renameFile', () async {
      final source = await tempFile('source.kdbx', const [1, 2, 3]);
      final target = p.join(tempDir.path, 'renamed.kdbx');

      await expectLater(
        () =>
            service(RefusingDatabasePathMutex())
                .renameFile(sourcePath: source.path, targetPath: target),
        throwsA(isA<LockRefused>()),
      );
      expect(source.existsSync(), isTrue);
      expect(File(target).existsSync(), isFalse);

      final recording = RecordingDatabasePathMutex();
      await service(recording)
          .renameFile(sourcePath: source.path, targetPath: target);
      expect(source.existsSync(), isFalse);
      expect(File(target).existsSync(), isTrue);
      expect(recording.acquisitions, [
        [source.path, target],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('deleteFile', () async {
      final target = await tempFile('doomed.kdbx', const [1]);

      await expectLater(
        () => service(RefusingDatabasePathMutex()).deleteFile(target.path),
        throwsA(isA<LockRefused>()),
      );
      expect(target.existsSync(), isTrue);

      final recording = RecordingDatabasePathMutex();
      await service(recording).deleteFile(target.path);
      expect(target.existsSync(), isFalse);
      expect(recording.acquisitions, [
        [target.path],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('commitStagedDatabase onto an explicit target', () async {
      final staged = await tempFile('staged.kdbx', _kdbxMagic);
      final target = await tempFile('target.kdbx', const [9, 9, 9]);
      final import = stagedImport(staged);

      await expectLater(
        () =>
            service(RefusingDatabasePathMutex())
                .commitStagedDatabase(import, targetPath: target.path),
        throwsA(isA<LockRefused>()),
      );
      expect(await target.readAsBytes(), [9, 9, 9]);
      expect(staged.existsSync(), isTrue);

      final recording = RecordingDatabasePathMutex();
      final commit = await service(recording)
          .commitStagedDatabase(import, targetPath: target.path);
      expect(await target.readAsBytes(), _kdbxMagic);
      expect(commit.backupPath, isNotNull);
      expect(recording.acquisitions, [
        [staged.path, target.path],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('commitStagedDatabase into managed storage', () async {
      final staged = await stagedFile('managed.kdbx', _kdbxMagic);
      final import = stagedImport(staged);
      final committedPath = p.join(docsDir.path, 'databases', 'managed.kdbx');

      await expectLater(
        () => service(RefusingDatabasePathMutex()).commitStagedDatabase(import),
        throwsA(isA<LockRefused>()),
      );
      expect(File(committedPath).existsSync(), isFalse);
      expect(staged.existsSync(), isTrue);

      final recording = RecordingDatabasePathMutex();
      final commit = await service(recording).commitStagedDatabase(import);
      expect(File(commit.databasePath).existsSync(), isTrue);
      // Staged file discarded INSIDE the same single acquisition — a second
      // acquisition here would be the nested-deadlock pattern.
      expect(staged.existsSync(), isFalse);
      expect(recording.acquisitions, [
        [staged.path, committedPath],
      ]);
      expect(recording.maxDepth, 1);
    });

    // P2: a failure that lands after a commit has installed its bytes but
    // before the method returns its rollback handle must be compensated
    // internally — the caller never gets an exception with no handle and
    // an orphan file on disk.
    test('commitStagedDatabase into managed storage compensates a failure '
        'after install without orphaning the target', () async {
      final staged = await stagedFile('managed-fault.kdbx', _kdbxMagic);
      final import = stagedImport(staged);
      final committedPath = p.join(
        docsDir.path,
        'databases',
        'managed-fault.kdbx',
      );

      await expectLater(
        () => service(
          RecordingDatabasePathMutex(),
          afterCommitInstall: () async {
            throw Exception('fault after install');
          },
        ).commitStagedDatabase(import),
        throwsException,
      );

      expect(File(committedPath).existsSync(), isFalse);
      expect(staged.existsSync(), isTrue);
      expect(await staged.readAsBytes(), _kdbxMagic);
    });

    test('commitStagedDatabase onto an explicit target compensates a failure '
        'after install, restoring the staged file and prior target', () async {
      final staged = await tempFile('staged-fault.kdbx', _kdbxMagic);
      final target = await tempFile('target-fault.kdbx', const [9]);

      await expectLater(
        () => service(
          RecordingDatabasePathMutex(),
          afterCommitInstall: () async {
            throw Exception('fault after install');
          },
        ).commitStagedDatabase(stagedImport(staged), targetPath: target.path),
        throwsException,
      );

      expect(await target.readAsBytes(), [9]);
      expect(staged.existsSync(), isTrue);
      expect(await staged.readAsBytes(), _kdbxMagic);
    });

    test(
      'commit invalidation failure blocks the replace-in-place write',
      () async {
        final staged = await tempFile('staged-hash-block.kdbx', _kdbxMagic);
        final target = await tempFile('target-hash-block.kdbx', const [9]);
        final registry = _ImportHashRegistry(target.path, 'old-hash')
          ..failUpsertOnCall = 1;

        await expectLater(
          () => service(
            RecordingDatabasePathMutex(),
            fileHashRecorder: DatabaseFileHashRecorder(
              registryRepository: registry,
            ),
          ).commitStagedDatabase(stagedImport(staged), targetPath: target.path),
          throwsStateError,
        );

        expect(await target.readAsBytes(), [9]);
        expect(staged.existsSync(), isTrue);
        expect(registry.record.fileHash, 'old-hash');
      },
    );

    test(
      'commit hash-refresh failure leaves the hash absent, not stale',
      () async {
        final staged = await tempFile('staged-hash-refresh.kdbx', _kdbxMagic);
        final target = await tempFile('target-hash-refresh.kdbx', const [9]);
        final registry = _ImportHashRegistry(target.path, 'old-hash')
          ..failUpsertOnCall = 2;

        await service(
          RecordingDatabasePathMutex(),
          fileHashRecorder: DatabaseFileHashRecorder(
            registryRepository: registry,
          ),
        ).commitStagedDatabase(stagedImport(staged), targetPath: target.path);

        expect(await target.readAsBytes(), _kdbxMagic);
        expect(registry.record.fileHash, isNull);
      },
    );

    test('rollbackDatabaseCommit refreshes the hash to match the restored '
        'bytes, not the pre-commit placeholder', () async {
      final staged = await tempFile('staged-rollback.kdbx', _kdbxMagic);
      final originalBytes = const [9];
      final target = await tempFile('target-rollback.kdbx', originalBytes);
      final registry = _ImportHashRegistry(target.path, 'old-hash');
      final commit = await service(
        RecordingDatabasePathMutex(),
        fileHashRecorder: DatabaseFileHashRecorder(
          registryRepository: registry,
        ),
      ).commitStagedDatabase(stagedImport(staged), targetPath: target.path);
      expect(registry.record.fileHash, md5.convert(_kdbxMagic).toString());

      await service(
        RecordingDatabasePathMutex(),
        fileHashRecorder: DatabaseFileHashRecorder(
          registryRepository: registry,
        ),
      ).rollbackDatabaseCommit(commit);

      expect(await target.readAsBytes(), originalBytes);
      expect(registry.record.fileHash, md5.convert(originalBytes).toString());
    });

    test('finalizeDatabaseCommit', () async {
      final database = await tempFile('database.kdbx', _kdbxMagic);
      final backup = await tempFile('database.kdbx.import-backup-1', const [1]);
      final commit = DatabaseFileCommit(
        databasePath: database.path,
        backupPath: backup.path,
      );

      await expectLater(
        () =>
            service(RefusingDatabasePathMutex()).finalizeDatabaseCommit(commit),
        throwsA(isA<LockRefused>()),
      );
      expect(backup.existsSync(), isTrue);

      final recording = RecordingDatabasePathMutex();
      await service(recording).finalizeDatabaseCommit(commit);
      expect(backup.existsSync(), isFalse);
      expect(recording.acquisitions, [
        [database.path],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('rollbackDatabaseCommit', () async {
      final database = await tempFile('database.kdbx', _kdbxMagic);
      final backup = await tempFile('database.kdbx.import-backup-1', const [
        5,
        5,
      ]);
      final commit = DatabaseFileCommit(
        databasePath: database.path,
        backupPath: backup.path,
      );

      await expectLater(
        () =>
            service(RefusingDatabasePathMutex()).rollbackDatabaseCommit(commit),
        throwsA(isA<LockRefused>()),
      );
      expect(await database.readAsBytes(), _kdbxMagic);

      final recording = RecordingDatabasePathMutex();
      await service(recording).rollbackDatabaseCommit(commit);
      expect(await database.readAsBytes(), [5, 5]);
      expect(recording.acquisitions, [
        [database.path],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('discardStagedDatabase', () async {
      final staged = await stagedFile('discard-me.kdbx', _kdbxMagic);
      final import = stagedImport(staged);

      await expectLater(
        () =>
            service(RefusingDatabasePathMutex()).discardStagedDatabase(import),
        throwsA(isA<LockRefused>()),
      );
      expect(staged.existsSync(), isTrue);

      final recording = RecordingDatabasePathMutex();
      await service(recording).discardStagedDatabase(import);
      expect(staged.existsSync(), isFalse);
      expect(recording.acquisitions, [
        [staged.path],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('createDatabase', () async {
      final createdPath = p.join(docsDir.path, 'databases', 'created.kdbx');

      await expectLater(
        () => service(
          RefusingDatabasePathMutex(),
        ).createDatabase(outputFile: 'created.kdbx', databaseBytes: _kdbxMagic),
        throwsA(isA<LockRefused>()),
      );
      expect(File(createdPath).existsSync(), isFalse);

      final recording = RecordingDatabasePathMutex();
      final resultPath = await service(
        recording,
      ).createDatabase(outputFile: 'created.kdbx', databaseBytes: _kdbxMagic);
      expect(File(resultPath).existsSync(), isTrue);
      expect(recording.acquisitions, [
        [createdPath],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('stageLocalSelection', () async {
      final stagingDir = Directory(p.join(docsDir.path, 'database_imports'));

      await expectLater(
        () => service(RefusingDatabasePathMutex()).stageLocalSelection(
          fileName: 'incoming.kdbx',
          selectedBytes: _kdbxMagic,
        ),
        throwsA(isA<LockRefused>()),
      );
      expect(
        stagingDir.existsSync()
            ? stagingDir.listSync().whereType<File>().toList()
            : const <File>[],
        isEmpty,
      );

      final recording = RecordingDatabasePathMutex();
      final staged = await service(recording).stageLocalSelection(
        fileName: 'incoming.kdbx',
        selectedBytes: _kdbxMagic,
      );
      expect(File(staged.imported.path).existsSync(), isTrue);
      expect(recording.acquisitions, [
        [p.join(stagingDir.path, 'incoming.kdbx')],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('stageDriveDownload', () async {
      final stagingDir = Directory(p.join(docsDir.path, 'database_imports'));

      await expectLater(
        () => service(RefusingDatabasePathMutex()).stageDriveDownload(
          fileName: 'remote.kdbx',
          bytes: _kdbxMagic,
          remoteFileId: 'remote-1',
        ),
        throwsA(isA<LockRefused>()),
      );
      expect(
        stagingDir.existsSync()
            ? stagingDir.listSync().whereType<File>().toList()
            : const <File>[],
        isEmpty,
      );

      final recording = RecordingDatabasePathMutex();
      final staged = await service(recording).stageDriveDownload(
        fileName: 'remote.kdbx',
        bytes: _kdbxMagic,
        remoteFileId: 'remote-1',
      );
      expect(File(staged.imported.path).existsSync(), isTrue);
      expect(recording.acquisitions, [
        [p.join(stagingDir.path, 'remote.kdbx')],
      ]);
      expect(recording.maxDepth, 1);
    });

    test('importFromSelection stages under the lock', () async {
      final databasesDir = Directory(p.join(docsDir.path, 'databases'));

      await expectLater(
        () => service(RefusingDatabasePathMutex()).importFromSelection(
          fileName: 'picked.kdbx',
          selectedBytes: _kdbxMagic,
        ),
        throwsA(isA<LockRefused>()),
      );
      expect(
        databasesDir.existsSync()
            ? databasesDir.listSync().whereType<File>().toList()
            : const <File>[],
        isEmpty,
      );

      final recording = RecordingDatabasePathMutex();
      final result = await service(
        recording,
      ).importFromSelection(fileName: 'picked.kdbx', selectedBytes: _kdbxMagic);
      expect(File(result.path).existsSync(), isTrue);
      expect(recording.acquisitions, isNotEmpty);
      expect(recording.maxDepth, 1);
    });

    test(
      'importFromSelection with overwrite replaces under the lock',
      () async {
        final target = File(p.join(docsDir.path, 'databases', 'vault.kdbx'));
        await target.parent.create(recursive: true);
        final oldBytes = Uint8List.fromList([..._kdbxMagic, 1]);
        await target.writeAsBytes(oldBytes, flush: true);
        final newBytes = Uint8List.fromList([..._kdbxMagic, 2]);

        await expectLater(
          () => service(RefusingDatabasePathMutex()).importFromSelection(
            fileName: 'vault.kdbx',
            selectedBytes: newBytes,
            overwriteExisting: true,
          ),
          throwsA(isA<LockRefused>()),
        );
        expect(await target.readAsBytes(), oldBytes);

        final recording = RecordingDatabasePathMutex();
        final result = await service(recording).importFromSelection(
          fileName: 'vault.kdbx',
          selectedBytes: newBytes,
          overwriteExisting: true,
        );
        expect(result.path, target.path);
        expect(await target.readAsBytes(), newBytes);
        // The replace acquisition names both the imported copy and the target.
        expect(recording.acquisitions.last, containsAll(<String>[target.path]));
        expect(recording.acquisitions.last, hasLength(2));
        expect(recording.maxDepth, 1);
      },
    );
  });

  group('DatabaseSyncOrchestrator lock routing', () {
    late Directory tempDir;
    late _InMemoryMetadata metadata;
    late _FakeProvider drive;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sync_lock_routing_');
      metadata = _InMemoryMetadata();
      drive = _FakeProvider();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('syncNow replaces the local file only inside the lock', () async {
      final localBytes = Uint8List.fromList([1, 2, 3]);
      final remoteBytes = Uint8List.fromList([4, 5, 6]);
      final localFile = File(p.join(tempDir.path, 'vault.kdbx'));
      await localFile.writeAsBytes(localBytes, flush: true);
      final localChecksum = md5.convert(localBytes).toString();
      final remoteChecksum = md5.convert(remoteBytes).toString();

      await metadata.upsertMapping(
        localFile.path,
        DatabaseSyncMapping(
          databasePath: localFile.path,
          providerId: 'google_drive',
          remoteFileId: 'remote-1',
          remoteFileName: 'vault.kdbx',
          // Remote changed, local unchanged -> download+replace branch.
          lastSyncedLocalChecksum: localChecksum,
          lastSyncedRemoteChecksum: 'stale-remote-checksum',
          lastSyncedRemoteModifiedTime: null,
          lastSyncAt: DateTime(2026),
        ),
      );
      drive.metadataResult = RemoteFile(
        providerId: 'google_drive',
        id: 'remote-1',
        name: 'vault.kdbx',
        contentChecksum: remoteChecksum,
      );
      drive.downloadResult = remoteBytes;

      await expectLater(
        () => DatabaseSyncOrchestrator(
          resolveDatabaseId: (databasePath) async => databasePath,
          syncMetadataDataSource: metadata,
          cloudStorageProvider: drive,
          mutex: RefusingDatabasePathMutex(),
        ).syncNow(localFile.path),
        throwsA(isA<LockRefused>()),
      );
      expect(
        await localFile.readAsBytes(),
        localBytes,
        reason: 'syncNow mutated the database without holding the lock',
      );

      final recording = RecordingDatabasePathMutex();
      final result = await DatabaseSyncOrchestrator(
        resolveDatabaseId: (databasePath) async => databasePath,
        syncMetadataDataSource: metadata,
        cloudStorageProvider: drive,
        mutex: recording,
      ).syncNow(localFile.path);
      expect(result, isA<SyncNowSuccess>());
      expect(await localFile.readAsBytes(), remoteBytes);
      // The `_backupFile` copy ran inside the SAME acquisition (depth 1),
      // and a dated .bak sibling exists.
      expect(recording.acquisitions, [
        [localFile.path],
      ]);
      expect(recording.maxDepth, 1);
      final backups = tempDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.bak'))
          .toList();
      expect(backups, hasLength(1));
    });

    test('a hung Drive call cannot hold the database lock forever: syncNow '
        'times out through the error path and the lock is released', () async {
      // Tester finding (HIGH): the mutex is in-process and only released
      // by the action completing — a Drive request that never responds
      // would queue every writer on this database until app restart.
      final localFile = File(p.join(tempDir.path, 'vault.kdbx'));
      await localFile.writeAsBytes(const [1, 2, 3], flush: true);
      await metadata.upsertMapping(
        localFile.path,
        DatabaseSyncMapping(
          databasePath: localFile.path,
          providerId: 'google_drive',
          remoteFileId: 'remote-1',
          remoteFileName: 'vault.kdbx',
          lastSyncedLocalChecksum: null,
          lastSyncedRemoteChecksum: null,
          lastSyncedRemoteModifiedTime: null,
          lastSyncAt: null,
        ),
      );
      final mutex = DatabasePathMutex();
      final orchestrator = DatabaseSyncOrchestrator(
        resolveDatabaseId: (databasePath) async => databasePath,
        syncMetadataDataSource: metadata,
        cloudStorageProvider: _HangingProvider(),
        mutex: mutex,
        remoteCallTimeout: const Duration(milliseconds: 200),
      );

      await expectLater(
        orchestrator
            .syncNow(localFile.path)
            // Outer bound proves syncNow itself terminates promptly.
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()),
      );

      // The lock must be free again: an unrelated acquisition on the same
      // path is granted immediately.
      var acquired = false;
      await mutex
          .withDatabaseLock([localFile.path], () async {
            acquired = true;
          })
          .timeout(const Duration(seconds: 5));
      expect(acquired, isTrue);
      expect(await localFile.readAsBytes(), [1, 2, 3]);
    });
  });
}

// =============================================================================
// Fakes.
// =============================================================================

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.basePath);

  final String basePath;

  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;

  @override
  Future<String?> getApplicationSupportPath() async => basePath;
}

class _InMemoryMetadata implements SyncMetadataDataSource {
  final Map<String, DatabaseSyncMapping> _mappings = {};

  @override
  Future<DatabaseSyncMapping?> getMapping(String databasePath) async =>
      _mappings[databasePath];

  @override
  Future<void> upsertMapping(
    String databaseId,
    DatabaseSyncMapping mapping,
  ) async {
    _mappings[databaseId] = mapping.copyWith(databaseId: databaseId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

/// Provider fake whose first metadata call never completes — models a hung
/// network request for the lock-liveness test.
class _HangingProvider implements CloudStorageProvider {
  @override
  String get providerId => 'google_drive';

  @override
  Future<RemoteFile> getFileMetadata(String remoteFileId) {
    return Completer<RemoteFile>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

class _FakeProvider implements CloudStorageProvider {
  RemoteFile? metadataResult;
  Uint8List? downloadResult;

  @override
  String get providerId => 'google_drive';

  @override
  Future<RemoteFile> getFileMetadata(String remoteFileId) async =>
      metadataResult!;

  @override
  Future<Uint8List> downloadFile(String remoteFileId) async => downloadResult!;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

class _ImportHashRegistry implements DatabaseRegistryRepository {
  _ImportHashRegistry(String path, String hash)
    : record = DatabaseRecord(
        databaseId: 'db-1',
        canonicalPath: path,
        displayName: p.basename(path),
        sourceType: DatabaseSourceType.local,
        fileHash: hash,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

  DatabaseRecord record;
  int? failUpsertOnCall;
  int upsertCalls = 0;

  @override
  Future<DatabaseRecord?> getById(String databaseId) async => record;

  @override
  Future<List<DatabaseRecord>> list() async => [record];

  @override
  Future<void> upsert(DatabaseRecord value) async {
    upsertCalls += 1;
    if (failUpsertOnCall == upsertCalls) {
      throw StateError('registry write failed');
    }
    record = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}
