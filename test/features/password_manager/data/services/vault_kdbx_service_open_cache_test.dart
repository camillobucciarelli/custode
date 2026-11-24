import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:password_manager/features/password_manager/data/services/database_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/safe_vault_file_writer.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_transaction.dart';
import 'package:password_manager/features/password_manager/domain/usecases/unlock_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/validate_database_usecase.dart';

/// The KDF is what makes opening a vault slow, so it is what is counted.
class _CountingArgon2 extends PointyCastleArgon2 {
  int calls = 0;

  @override
  Future<Uint8List> argon2Async(args) {
    calls++;
    return super.argon2Async(args);
  }
}

class _FailingWriter extends SafeVaultFileWriter {
  bool fail = false;

  /// Runs while an edit's file is checked out and before its bytes land.
  Future<void> Function()? beforeWrite;

  @override
  Future<SafeVaultFileWriteResult> write({
    required String targetPath,
    required Uint8List bytes,
    bool backupExistingTarget = false,
    String? operation,
  }) async {
    final hook = beforeWrite;
    beforeWrite = null;
    await hook?.call();
    if (fail) {
      throw const FileSystemException('disk full');
    }
    return super.write(
      targetPath: targetPath,
      bytes: bytes,
      backupExistingTarget: backupExistingTarget,
      operation: operation,
    );
  }
}

void main() {
  const password = 'test-password';

  late Directory tempDir;
  late String databasePath;
  late _CountingArgon2 argon2;
  late _FailingWriter writer;
  late bool sessionOpen;
  late VaultKdbxService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vault_open_cache_test_');
    databasePath = '${tempDir.path}/vault.kdbx';
    await File(
      databasePath,
    ).writeAsBytes(await _vaultBytes(password, titles: ['Seed']), flush: true);
    argon2 = _CountingArgon2();
    writer = _FailingWriter();
    sessionOpen = true;
    service = VaultKdbxService(
      safeWriter: writer,
      kdbxFormat: KdbxFormat(argon2),
      keepOpenWhile: () => sessionOpen,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<List<String>> titles({String pw = password}) async {
    final entries = await service.loadAllEntries(
      databasePath: databasePath,
      password: pw,
    );
    return entries.map((entry) => entry.title).toList();
  }

  Future<String> rootGroupId() async => (await service.loadVault(
    databasePath: databasePath,
    password: password,
  )).rootGroupId;

  Future<String> create(String title, String groupId) => service.createEntry(
    databasePath: databasePath,
    password: password,
    groupId: groupId,
    title: title,
    username: 'user',
    entryPassword: 'secret',
    url: '',
    notes: '',
  );

  test('N reads plus M edits after the first open cost no KDF, '
      'and every edit still reaches the disk', () async {
    final groupId = await rootGroupId();
    expect(argon2.calls, 1, reason: 'first open decrypts');
    argon2.calls = 0;

    const reads = 6;
    for (var i = 0; i < reads; i++) {
      await service.loadVault(databasePath: databasePath, password: password);
      await service.loadRecycleBinEntries(
        databasePath: databasePath,
        password: password,
      );
    }
    final id = await create('One', groupId);
    await service.updateEntry(
      databasePath: databasePath,
      password: password,
      entryId: id,
      title: 'One edited',
      username: 'user',
      entryPassword: 'secret',
      url: '',
      notes: '',
    );
    await create('Two', groupId);
    expect(await titles(), containsAll(['Seed', 'One edited', 'Two']));

    expect(
      argon2.calls,
      0,
      reason: 'saves reuse the derived key, reads the cache',
    );

    // Disk, not memory: a cold reader sees the same state.
    final onDisk = await KdbxFormat().read(
      await File(databasePath).readAsBytes(),
      Credentials(ProtectedValue.fromString(password)),
    );
    expect(
      onDisk.body.rootGroup.getAllEntries().map(
        (e) => e.getString(KdbxKeyCommon.TITLE)?.getText(),
      ),
      containsAll(['Seed', 'One edited', 'Two']),
    );
  });

  // The coordinator's hand-off, through the real port implementation.
  Future<void> unlockAndAdopt(String pw) async {
    final unlocked = await UnlockDatabaseUseCase()(
      databasePath: databasePath,
      password: pw,
    );
    DatabaseImportService(
      validateDatabaseUseCase: ValidateDatabaseUseCase(),
      adoptOpenedFile: service.adoptOpenedFile,
    ).adoptUnlockedDatabase(unlocked);
  }

  test('a successful unlock hands its file over: unlock plus loadVault costs '
      'one KDF', () async {
    await unlockAndAdopt(password);

    // The use case runs its own KdbxFormat, so its single KDF is not counted
    // here; the service's first read must add none.
    await service.loadVault(databasePath: databasePath, password: password);
    expect(argon2.calls, 0);
  });

  test('a failed unlock hands nothing over', () async {
    await expectLater(unlockAndAdopt('wrong'), throwsA(anything));
    await service.loadVault(databasePath: databasePath, password: password);
    expect(argon2.calls, 1);
  });

  test('an unlock while locked hands nothing over', () async {
    sessionOpen = false;
    await unlockAndAdopt(password);

    sessionOpen = true;
    await service.loadVault(databasePath: databasePath, password: password);
    expect(argon2.calls, 1, reason: 'nothing was adopted while locked');
  });

  test('deleting the recycle bin permanently, then an entry, on a warm '
      'cache keeps the entry in a new bin', () async {
    final rootId = await rootGroupId();
    final doomedId = await create('Doomed', rootId);
    await service.deleteEntry(
      databasePath: databasePath,
      password: password,
      entryId: doomedId,
    );
    final oldBinId = (await service.getRecycleBinGroupId(
      databasePath: databasePath,
      password: password,
    ))!;
    await service.deleteGroup(
      databasePath: databasePath,
      password: password,
      groupId: oldBinId,
      permanently: true,
    );
    final keptId = await create('Kept', rootId);
    await service.deleteEntry(
      databasePath: databasePath,
      password: password,
      entryId: keptId,
    );

    final onDisk = await KdbxFormat().read(
      await File(databasePath).readAsBytes(),
      Credentials(ProtectedValue.fromString(password)),
    );
    final bin = onDisk.recycleBin!;
    expect(bin.uuid.uuid, isNot(oldBinId));
    expect(bin.parent, same(onDisk.body.rootGroup));
    expect(bin.entries.map((e) => e.uuid.uuid), [keptId]);
  });

  test('a warm cache never accepts the wrong password', () async {
    await titles();
    await expectLater(titles(pw: 'wrong'), throwsA(anything));
  });

  group('the cache is re-read, never served stale, after', () {
    setUp(() async {
      await titles();
      argon2.calls = 0;
    });

    test('an external write of different bytes', () async {
      await File(databasePath).writeAsBytes(
        await _vaultBytes(password, titles: ['External']),
        flush: true,
      );

      expect(await titles(), ['External']);
      expect(argon2.calls, 1);
    });

    test('a sync merge written through the safe writer', () async {
      final format = KdbxFormat();
      final credentials = Credentials(ProtectedValue.fromString(password));
      final local = await format.read(
        await File(databasePath).readAsBytes(),
        credentials,
      );
      final remote = await format.read(
        await File(databasePath).readAsBytes(),
        credentials,
      );
      final entry = KdbxEntry.create(remote, remote.body.rootGroup);
      entry.setString(KdbxKeyCommon.TITLE, PlainValue('From remote'));
      remote.body.rootGroup.addEntry(entry);
      local.merge(remote);
      await SafeVaultFileWriter().write(
        targetPath: databasePath,
        bytes: await local.save(),
        operation: 'sync merge commit',
      );

      expect(await titles(), containsAll(['Seed', 'From remote']));
      expect(
        argon2.calls,
        0,
        reason:
            'decrypted again from disk; the merge kept the KDF salt, so '
            'the derived key still fits',
      );
    });

    test('an import that replaces the file', () async {
      final stagedPath = '${tempDir.path}/staged.kdbx';
      await File(stagedPath)
          .writeAsBytes(await _vaultBytes(password, titles: ['Imported']));
      final import = DatabaseImportService(
        validateDatabaseUseCase: ValidateDatabaseUseCase(),
      );
      final commit = await import.commitStagedDatabase(
        StagedDatabaseImport(
          imported: DatabaseImportResult(
            path: stagedPath,
            fileName: 'staged.kdbx',
            fileHash: '',
            sourceType: DatabaseSourceType.local,
          ),
          preferredFileName: 'staged.kdbx',
        ),
        targetPath: databasePath,
      );
      await import.finalizeDatabaseCommit(commit);

      expect(await titles(), ['Imported']);
      expect(argon2.calls, 1);
    });

    test('a credentials change', () async {
      await service.changeCredentials(
        databasePath: databasePath,
        currentPassword: password,
        newPassword: 'new-password',
      );

      await expectLater(titles(), throwsA(anything));
      expect(await titles(pw: 'new-password'), ['Seed']);
    });

    test('lock (session end), and nothing is kept while locked', () async {
      service.closeOpenVaults();
      await titles();
      expect(argon2.calls, 1);

      sessionOpen = false;
      await titles();
      await titles();
      expect(argon2.calls, 3, reason: 'no reuse while the session is locked');
    });

    test('a failed save: the half-applied edit is dropped', () async {
      final groupId = await rootGroupId();
      writer.fail = true;
      await expectLater(create('Ghost', groupId), throwsA(anything));
      writer.fail = false;
      argon2.calls = 0;

      expect(await titles(), ['Seed']);
      expect(
        argon2.calls,
        0,
        reason: 're-decrypted from disk with the known derived key',
      );
    });

    test('a failed edit before the save is dropped too', () async {
      await expectLater(
        service.deleteGroup(
          databasePath: databasePath,
          password: password,
          groupId: await rootGroupId(),
        ),
        throwsA(anything),
      );

      expect(await titles(), ['Seed']);
      expect(argon2.calls, 0, reason: 're-decrypted from disk, no KDF');
    });
  });

  test(
    'a read during an edit sees the last saved state and runs no KDF',
    () async {
      final groupId = await rootGroupId();
      argon2.calls = 0;
      List<String>? duringEdit;
      writer.beforeWrite = () async => duringEdit = await titles();

      await create('New', groupId);

      expect(duringEdit, ['Seed'], reason: 'never the half-applied edit');
      expect(await titles(), containsAll(['Seed', 'New']));
      expect(argon2.calls, 0);
    },
  );

  test('a credential change costs two KDFs (save, verify) and the next '
      'read none', () async {
    await titles();
    argon2.calls = 0;

    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: password,
      newPassword: 'new-password',
    );
    expect(argon2.calls, 2);

    expect(await titles(pw: 'new-password'), ['Seed']);
    expect(argon2.calls, 2);
    await expectLater(titles(), throwsA(anything));
  });

  test('a credential change while locked adopts nothing', () async {
    sessionOpen = false;
    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: password,
      newPassword: 'new-password',
    );
    sessionOpen = true;
    argon2.calls = 0;

    expect(await titles(pw: 'new-password'), ['Seed']);
    expect(argon2.calls, 1);
  });
}

Future<Uint8List> _vaultBytes(
  String password, {
  required List<String> titles,
}) async {
  final file = KdbxFormat().create(
    Credentials(ProtectedValue.fromString(password)),
    'Test DB',
  );
  for (final title in titles) {
    final entry = KdbxEntry.create(file, file.body.rootGroup);
    entry.setString(KdbxKeyCommon.TITLE, PlainValue(title));
    file.body.rootGroup.addEntry(entry);
  }
  return file.save();
}
