// Passkeys-all-platforms T013 — adoption sequencing: fakes for every
// failure-mode row the coordinator owns, plus one run on a real .kdbx.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/pending_passkey_registration.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
import 'package:password_manager/features/password_manager/domain/repositories/autofill_ports.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/pending_passkey_adoption_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';

import '../../../../fixtures/passkeys/vectors.dart';
import 'fake_database_ports.dart';

const _sentinelPem = 'SENTINEL-PEM-DO-NOT-LEAK';

class _FakePort implements PendingPasskeyRegistrationPort {
  PendingPasskeyRegistrations pending = const PendingPasskeyRegistrations();
  Object? readError;
  Object? resolveError;
  final resolved = <String>[];
  void Function()? onResolve;

  /// Worst case for overlapping runs: a resolved record is still listed.
  bool keepResolved = false;

  /// What the native side answers; false = the record was not removed.
  bool resolveResult = true;

  int reads = 0;
  int countError = 0;

  @override
  Future<int> countPendingPasskeyRegistrations() async {
    if (countError > 0) throw PlatformException(code: 'count');
    return pending.records.length + pending.unreadableCount;
  }

  @override
  Future<PendingPasskeyRegistrations> readPendingPasskeyRegistrations() async {
    reads++;
    if (readError != null) throw readError!;
    return PendingPasskeyRegistrations(
      records: pending.records
          .where((r) => keepResolved || !resolved.contains(r.recordId))
          .toList(),
      unreadableCount: pending.unreadableCount,
    );
  }

  @override
  Future<bool> resolvePendingPasskeyRegistration(String recordId) async {
    onResolve?.call();
    if (resolveError != null) throw resolveError!;
    if (!resolveResult) return false;
    resolved.add(recordId);
    return true;
  }
}

/// A vault that remembers: `holders` is `credentialId -> entry id`.
class _FakeVault implements VaultKdbxService {
  final Map<String, String> credentialEntry = {};
  List<String> accountEntryIds = [];
  List<VaultEntry> entries = [];
  Object? writeError;
  bool dropWrites = false;
  void Function()? onWrite;
  Duration? writeDelay;
  final writes = <String>[];
  final replaces = <bool>[];

  String _key(String rp, Uint8List id) => '$rp/${id.join(',')}';

  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async => VaultSnapshot(
    rootGroupId: 'root',
    currentGroupId: 'root',
    groups: const [],
    entries: const [],
    allEntries: entries,
  );

  @override
  Future<({String? credentialEntryId, List<String> accountEntryIds})>
  findPasskeyHolders({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String relyingPartyId,
    required Uint8List credentialId,
    Uint8List? userHandle,
  }) async => (
    credentialEntryId: credentialEntry[_key(relyingPartyId, credentialId)],
    accountEntryIds: accountEntryIds,
  );

  @override
  Future<void> createPasskey({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required VaultPasskey passkey,
    bool replaceExisting = false,
  }) async {
    onWrite?.call();
    if (writeDelay != null) await Future<void>.delayed(writeDelay!);
    if (writeError != null) throw writeError!;
    writes.add('createPasskey:$entryId');
    replaces.add(replaceExisting);
    if (!dropWrites) {
      credentialEntry[_key(passkey.relyingPartyId, passkey.credentialId)] =
          entryId;
    }
  }

  @override
  Future<String> createEntryWithPasskey({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
    required String title,
    required String username,
    required String url,
    required VaultPasskey passkey,
  }) async {
    onWrite?.call();
    if (writeDelay != null) await Future<void>.delayed(writeDelay!);
    if (writeError != null) throw writeError!;
    writes.add('new:$groupId:$title:$username:$url');
    if (!dropWrites) {
      credentialEntry[_key(passkey.relyingPartyId, passkey.credentialId)] =
          'new-entry';
    }
    return 'new-entry';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PendingPasskeyRegistration _record(
  String id, {
  String? databaseId,
  String rpId = 'example.com',
  String username = 'alice',
  int cred = 1,
}) => PendingPasskeyRegistration(
  recordId: id,
  databaseId:
      databaseId ?? PendingPasskeyAdoptionCoordinator.databaseIdFor(_path),
  createdAt: DateTime.utc(2026, 11, 1),
  rpId: rpId,
  credentialId: Uint8List.fromList([cred, 2, 3]),
  username: username,
  privateKeyPem: _sentinelPem,
  algorithm: VaultPasskeyAlgorithm.es256,
  be: true,
  bs: false,
  origin: 'https://$rpId',
);

VaultEntry _entry(String id, String url, String username) => VaultEntry(
  id: id,
  groupId: 'root',
  title: id,
  username: username,
  password: '',
  url: url,
  notes: '',
);

late String _path;

void main() {
  late Directory tempDir;
  late _FakePort port;
  late _FakeVault vault;
  late SessionSecretHolder holder;
  late PendingPasskeyAdoptionCoordinator coordinator;

  List<File> backups() => tempDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('.pre-adopt-passkey.kdbx'))
      .toList();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pending_adoption_');
    _path = '${tempDir.path}/vault.kdbx';
    await File(_path).writeAsBytes(const [1, 2, 3], flush: true);
    port = _FakePort();
    vault = _FakeVault();
    holder = SessionSecretHolder()..set('secret');
    coordinator = PendingPasskeyAdoptionCoordinator(
      vault: vault,
      sessionSecretHolder: holder,
      databaseFileRepository: FakeDatabaseFileRepository(),
      pendingPasskeyPort: port,
    );
  });

  tearDown(() => tempDir.delete(recursive: true));

  Future<PendingPasskeyAdoptionResult> adopt() =>
      coordinator.adoptPending(databasePath: _path);

  test('a locked session reads and writes nothing', () async {
    holder.clear();
    port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);

    final result = await adopt();

    expect(result.status, PendingPasskeyAdoptionStatus.vaultLocked);
    expect(vault.writes, isEmpty);
    expect(port.resolved, isEmpty);
    expect(backups(), isEmpty);
  });

  test('a record of another vault is left alone and reported', () async {
    port.pending = PendingPasskeyRegistrations(
      records: [_record('r1', databaseId: 'sha256:other')],
    );

    final result = await adopt();

    expect(result.otherVault.single.databaseId, 'sha256:other');
    expect(result.otherVault.single.recordId, 'r1');
    expect(vault.writes, isEmpty);
    expect(port.resolved, isEmpty);
  });

  test('an other-vault record is named after the known database', () async {
    const otherPath = '/vaults/work.kdbx';
    port.pending = PendingPasskeyRegistrations(
      records: [
        _record(
          'r1',
          databaseId: PendingPasskeyAdoptionCoordinator.databaseIdFor(
            otherPath,
          ),
        ),
        _record('r2', databaseId: 'sha256:unknown'),
      ],
    );
    final named = PendingPasskeyAdoptionCoordinator(
      vault: vault,
      sessionSecretHolder: holder,
      databaseFileRepository: FakeDatabaseFileRepository(),
      pendingPasskeyPort: port,
      databaseRegistry: _FakeRegistry([
        DatabaseRecord(
          databaseId: 'x',
          canonicalPath: otherPath,
          displayName: 'Work',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ]),
    );

    final result = await named.adoptPending(databasePath: _path);

    expect(result.otherVault.map((o) => o.vaultName), ['Work', null]);
  });

  test(
    'moveToOpenVault adopts the other-vault record; discard resolves',
    () async {
      port.pending = PendingPasskeyRegistrations(
        records: [
          _record('r1', databaseId: 'sha256:other'),
          _record('r2', databaseId: 'sha256:other', cred: 2),
        ],
      );

      final moved = await coordinator.moveToOpenVault(
        databasePath: _path,
        recordId: 'r1',
      );
      final discarded = await coordinator.discard('r2');

      expect(moved.adopted.single.recordId, 'r1');
      expect(discarded, isTrue);
      expect(port.resolved, ['r1', 'r2']);
      expect(vault.writes, hasLength(1));
    },
  );

  test(
    'a credential the vault already holds resolves without writing',
    () async {
      final record = _record('r1');
      vault.credentialEntry['example.com/1,2,3'] = 'e9';
      port.pending = PendingPasskeyRegistrations(records: [record]);

      final result = await adopt();

      expect(result.alreadyHeld.single.recordId, 'r1');
      expect(vault.writes, isEmpty);
      expect(backups(), isEmpty);
      expect(port.resolved, ['r1']);
    },
  );

  test('no matching entry creates one, backup first, resolve last', () async {
    port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);
    var backupsAtWrite = -1;
    var resolvedAtResolve = -1;
    vault.onWrite = () => backupsAtWrite = backups().length;
    port.onResolve = () => resolvedAtResolve = vault.writes.length;

    final result = await adopt();

    expect(backupsAtWrite, 1);
    expect(resolvedAtResolve, 1, reason: 'resolve only after the write');
    expect(
      vault.writes.single,
      'new:root:example.com:alice:https://example.com',
    );
    final adopted = result.adopted.single;
    expect(adopted.createdNewEntry, isTrue);
    expect(File(adopted.backupPath).existsSync(), isTrue);
    expect(port.resolved, ['r1']);
  });

  test(
    'the single entry with matching host and username is the target',
    () async {
      vault.entries = [
        _entry('e1', 'https://login.example.com/x', 'alice'),
        _entry('e2', 'https://example.com', 'bob'),
        _entry('e3', 'https://notexample.com', 'alice'),
      ];
      port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);

      final result = await adopt();

      expect(vault.writes.single, 'createPasskey:e1');
      expect(result.adopted.single.createdNewEntry, isFalse);
      expect(vault.replaces.single, isFalse);
    },
  );

  test('two matching entries are ambiguous: a new entry is created', () async {
    vault.entries = [
      _entry('e1', 'https://example.com', 'alice'),
      _entry('e2', 'https://www.example.com', 'alice'),
    ];
    port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);

    await adopt();

    expect(vault.writes.single, startsWith('new:'));
  });

  group('clash', () {
    setUp(() {
      vault.accountEntryIds = ['e1'];
      port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);
    });

    test('is reported as a decision request and writes nothing', () async {
      final result = await adopt();

      expect(result.clashes.single.recordId, 'r1');
      expect(result.clashes.single.candidateEntryIds, ['e1']);
      expect(vault.writes, isEmpty);
      expect(backups(), isEmpty);
      expect(port.resolved, isEmpty);
    });

    test('replace writes with replaceExisting on that entry', () async {
      final result = await coordinator.applyClashDecision(
        databasePath: _path,
        recordId: 'r1',
        decision: PasskeyClashDecision.replace,
        replaceEntryId: 'e1',
      );

      expect(vault.writes.single, 'createPasskey:e1');
      expect(vault.replaces.single, isTrue);
      expect(result.adopted.single.entryId, 'e1');
      expect(port.resolved, ['r1']);
    });

    test('replace on an entry that no longer clashes asks again', () async {
      final result = await coordinator.applyClashDecision(
        databasePath: _path,
        recordId: 'r1',
        decision: PasskeyClashDecision.replace,
        replaceEntryId: 'gone',
      );

      expect(result.clashes, hasLength(1));
      expect(vault.writes, isEmpty);
    });

    test('keepBoth writes a new entry and leaves the old one', () async {
      final result = await coordinator.applyClashDecision(
        databasePath: _path,
        recordId: 'r1',
        decision: PasskeyClashDecision.keepBoth,
      );

      expect(vault.writes.single, startsWith('new:'));
      expect(result.adopted.single.createdNewEntry, isTrue);
      expect(port.resolved, ['r1']);
    });
  });

  test(
    'a failed write keeps the record and the backup, next record runs',
    () async {
      port.pending = PendingPasskeyRegistrations(
        records: [
          _record('r1'),
          _record('r2', cred: 2, rpId: 'other.org'),
        ],
      );
      var calls = 0;
      vault.onWrite = () {
        if (calls++ == 0) vault.writeError = StateError(_sentinelPem);
        if (calls == 2) vault.writeError = null;
      };

      final result = await adopt();

      final failure = result.failures.single;
      expect(failure.recordId, 'r1');
      expect(failure.stage, PendingPasskeyFailureStage.write);
      expect(File(failure.backupPath!).existsSync(), isTrue);
      expect(failure.errorType, 'StateError');
      expect(result.adopted.single.recordId, 'r2');
      expect(port.resolved, ['r2']);
      expect(
        result.toString() + failure.toString(),
        isNot(contains(_sentinelPem)),
      );
    },
  );

  test('a write that is not visible on reopen is not resolved', () async {
    vault.dropWrites = true;
    port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);

    final result = await adopt();

    expect(result.failures.single.stage, PendingPasskeyFailureStage.verify);
    expect(result.adopted, isEmpty);
    expect(port.resolved, isEmpty);
  });

  test('a failed resolve is reported; the replay is case (a)', () async {
    port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);
    port.resolveError = PlatformException(code: 'io', message: _sentinelPem);

    final first = await adopt();

    expect(first.adopted, hasLength(1));
    expect(first.failures.single.stage, PendingPasskeyFailureStage.resolve);
    expect(first.failures.single.errorType, 'PlatformException(io)');

    port.resolveError = null;
    final second = await adopt();

    expect(second.alreadyHeld.single.recordId, 'r1');
    expect(vault.writes, hasLength(1));
    expect(port.resolved, ['r1']);
  });

  test('a resolve that removes nothing is a resolve failure', () async {
    port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);
    port.resolveResult = false;

    final first = await adopt();

    expect(first.failures.single.stage, PendingPasskeyFailureStage.resolve);
    expect(first.failures.single.backupPath, isNotNull);

    // Replay: the credential is held but the record still is not removed.
    final second = await adopt();

    expect(second.alreadyHeld, isEmpty);
    expect(second.failures.single.stage, PendingPasskeyFailureStage.resolve);
    expect(vault.writes, hasLength(1));
  });

  test('overlapping runs write once: the second sees the first', () async {
    port.keepResolved = true;
    port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);
    vault.writeDelay = const Duration(milliseconds: 50);

    final results = await Future.wait([adopt(), adopt()]);

    expect(vault.writes, hasLength(1));
    expect(backups(), hasLength(1));
    expect(results[0].adopted.single.recordId, 'r1');
    expect(results[1].adopted, isEmpty);
    expect(results[1].alreadyHeld.single.recordId, 'r1');
    expect(results[1].failures, isEmpty);
  });

  test('a backup failure writes nothing and keeps the record', () async {
    port.pending = PendingPasskeyRegistrations(records: [_record('r1')]);
    await File(_path).delete();

    final result = await adopt();

    expect(result.failures.single.stage, PendingPasskeyFailureStage.backup);
    expect(vault.writes, isEmpty);
    expect(port.resolved, isEmpty);
  });

  test('unreadable records are counted and never touched', () async {
    port.pending = const PendingPasskeyRegistrations(unreadableCount: 2);

    final result = await adopt();

    expect(result.unreadableCount, 2);
    expect(port.resolved, isEmpty);
    final readsBefore = port.reads;
    expect(await coordinator.waitingCount(), 2);
    expect(port.reads, readsBefore);
  });

  test('a PlatformException on read is reported, not thrown', () async {
    port.readError = PlatformException(code: 'sealed');

    final result = await adopt();

    expect(result.status, PendingPasskeyAdoptionStatus.readFailed);
    expect(result.readErrorCode, 'sealed');
  });

  test('waitingCount needs no session and counts every vault', () async {
    holder.clear();
    port.pending = PendingPasskeyRegistrations(
      records: [
        _record('r1'),
        _record('r2', databaseId: 'sha256:x'),
      ],
      unreadableCount: 1,
    );

    expect(await coordinator.waitingCount(), 3);
    expect(port.reads, 0, reason: 'the count must never read or decrypt');
  });

  test('waitingCount is 0 when the native count fails', () async {
    port.countError = 1;
    expect(await coordinator.waitingCount(), 0);
  });

  test('no result or record prints the PEM', () {
    expect(_record('r1').toString(), isNot(contains(_sentinelPem)));
  });

  group('real kdbx', () {
    const password = 'pw';

    test(
      'backup precedes the write, vault reopens, replay writes nothing',
      () async {
        final kdbx = KdbxFormat().create(
          Credentials(ProtectedValue.fromString(password)),
          'T',
        );
        await File(_path).writeAsBytes(await kdbx.save(), flush: true);
        final before = await File(_path).readAsBytes();

        final record = PendingPasskeyRegistration(
          recordId: 'r1',
          databaseId: PendingPasskeyAdoptionCoordinator.databaseIdFor(_path),
          createdAt: DateTime.utc(2026, 11, 1),
          rpId: webauthnIoRpId,
          credentialId: Uint8List.fromList(List.generate(32, (i) => i + 1)),
          userHandle: Uint8List.fromList([7, 7, 7]),
          username: 'alice',
          privateKeyPem: es256PrivateKeyPem,
          algorithm: VaultPasskeyAlgorithm.es256,
          be: true,
          bs: false,
          origin: 'https://webauthn.io',
        );
        port.pending = PendingPasskeyRegistrations(records: [record]);
        final service = VaultKdbxService();
        var backupAtWrite = false;
        final real = PendingPasskeyAdoptionCoordinator(
          vault: service,
          sessionSecretHolder: SessionSecretHolder()..set(password),
          databaseFileRepository: _RecordingFiles(() => backupAtWrite = true),
          pendingPasskeyPort: port,
        );

        final first = await real.adoptPending(databasePath: _path);

        expect(first.failures, isEmpty);
        final backup = File(first.adopted.single.backupPath);
        expect(backup.existsSync(), isTrue);
        expect(backupAtWrite, isTrue);
        expect(
          await backup.readAsBytes(),
          before,
          reason: 'copy of the old file',
        );
        expect(await File(_path).readAsBytes(), isNot(before));
        final entries = await service.loadAllEntries(
          databasePath: _path,
          password: password,
        );
        final entry = entries.single;
        expect(entry.passkeys.single.relyingPartyId, webauthnIoRpId);
        expect(entry.passkeys.single.credentialId, record.credentialId);
        expect(entry.username, 'alice');
        expect(port.resolved, ['r1']);

        // Replay: the same record comes back (resolve had failed, say).
        port.resolved.clear();
        final bytesAfterFirst = await File(_path).readAsBytes();
        final replay = await real.adoptPending(databasePath: _path);

        expect(replay.alreadyHeld.single.recordId, 'r1');
        expect(replay.adopted, isEmpty);
        expect(await File(_path).readAsBytes(), bytesAfterFirst);
        expect(backups(), hasLength(1));
      },
    );

    test('overlapping runs on a real file create one entry', () async {
      final kdbx = KdbxFormat().create(
        Credentials(ProtectedValue.fromString(password)),
        'T',
      );
      await File(_path).writeAsBytes(await kdbx.save(), flush: true);
      port.keepResolved = true;
      port.pending = PendingPasskeyRegistrations(
        records: [
          PendingPasskeyRegistration(
            recordId: 'r1',
            databaseId: PendingPasskeyAdoptionCoordinator.databaseIdFor(_path),
            createdAt: DateTime.utc(2026, 11, 1),
            rpId: webauthnIoRpId,
            credentialId: Uint8List.fromList(List.generate(32, (i) => i + 1)),
            username: 'alice',
            privateKeyPem: es256PrivateKeyPem,
            algorithm: VaultPasskeyAlgorithm.es256,
            be: true,
            bs: false,
            origin: 'https://webauthn.io',
          ),
        ],
      );
      final service = VaultKdbxService();
      final real = PendingPasskeyAdoptionCoordinator(
        vault: service,
        sessionSecretHolder: SessionSecretHolder()..set(password),
        databaseFileRepository: FakeDatabaseFileRepository(),
        pendingPasskeyPort: port,
      );

      final results = await Future.wait([
        real.adoptPending(databasePath: _path),
        real.adoptPending(databasePath: _path),
      ]);

      expect(results.expand((r) => r.failures), isEmpty);
      expect(results[0].adopted, hasLength(1));
      expect(results[1].alreadyHeld.single.recordId, 'r1');
      final entries = await service.loadAllEntries(
        databasePath: _path,
        password: password,
      );
      expect(entries, hasLength(1));
      expect(backups(), hasLength(1));
    });
  });
}

class _RecordingFiles extends FakeDatabaseFileRepository {
  _RecordingFiles(this.onCopy);
  final void Function() onCopy;

  @override
  Future<void> copyFile({
    required String sourcePath,
    required String targetPath,
  }) async {
    onCopy();
    await super.copyFile(sourcePath: sourcePath, targetPath: targetPath);
  }
}

class _FakeRegistry implements DatabaseRegistryRepository {
  _FakeRegistry(this.records);

  final List<DatabaseRecord> records;

  @override
  Future<List<DatabaseRecord>> list() async => records;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
