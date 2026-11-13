import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdbx/kdbx.dart';
// spec 008 Gate 0 finding: every primitive a full-fidelity merge adapter needs
// sits OUTSIDE the `package:kdbx/kdbx.dart` public export surface:
//   * `forceSetUuid`   — import an object into another file keeping its UUID;
//   * `cloneInto`      — copy an entry (with history) across files;
//   * `KdbxHeader`     — choose the KDBX 3 vs 4 header/KDF;
//   * `KdbxColor`      — set entry colors.
// `KdbxBody.deletedObjects` is exported but annotated `@visibleForTesting`.
// The adapter therefore cannot be built on the public API alone. Recorded in
// `specs/008-per-field-conflict-resolution/feasibility-report.md`.
// ignore: implementation_imports
import 'package:kdbx/src/kdbx_entry.dart' show KdbxEntryInternal;
// ignore: implementation_imports
import 'package:kdbx/src/kdbx_header.dart' show KdbxHeader;
// ignore: implementation_imports
import 'package:kdbx/src/kdbx_object.dart' show KdbxObjectInternal;
// ignore: implementation_imports
import 'package:kdbx/src/kdbx_xml.dart' show KdbxColor;
import 'package:password_manager/features/password_manager/data/services/database_file_hash_recorder.dart';
import 'package:password_manager/features/password_manager/data/services/safe_vault_file_writer.dart';
import 'package:password_manager/features/password_manager/data/services/passkey_parser.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/errors/passkey_errors.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry_revision.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_registry_repository.dart';
// `KdbxNode.node` is a public, exported `XmlElement`: constructs the library
// does not model (entry colors' RGB value, entry AutoType) are read and
// written straight through it, with no implementation import needed.
import 'package:xml/xml.dart';

import '../../../../fixtures/passkeys/vectors.dart';

void main() {
  const password = 'test-password';

  late VaultKdbxService service;
  late Directory tempDir;
  late String databasePath;

  setUp(() async {
    service = VaultKdbxService();
    tempDir = await Directory.systemTemp.createTemp('vault_kdbx_service_test_');
    databasePath = '${tempDir.path}/vault.kdbx';
    await _createDatabase(databasePath: databasePath, password: password);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('changes password and key file together', () async {
    final keyFile = File('${tempDir.path}/vault.key');
    await keyFile.writeAsBytes(List<int>.generate(64, (index) => index));

    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: password,
      newPassword: 'new-password',
      newKeyFilePath: keyFile.path,
    );

    await expectLater(
      service.loadVault(
        databasePath: databasePath,
        password: 'new-password',
        keyFilePath: keyFile.path,
      ),
      completes,
    );
    await expectLater(
      service.loadVault(databasePath: databasePath, password: password),
      throwsA(anything),
    );
  });

  test('changes password only and rejects old password', () async {
    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: password,
      newPassword: 'new-password',
    );

    await expectLater(
      service.loadVault(databasePath: databasePath, password: 'new-password'),
      completes,
    );
    await expectLater(
      service.loadVault(databasePath: databasePath, password: password),
      throwsA(anything),
    );
  });

  test('adds, changes, and removes key file atomically', () async {
    final firstKey = File('${tempDir.path}/first.key');
    final secondKey = File('${tempDir.path}/second.key');
    await firstKey.writeAsBytes(List<int>.filled(64, 1));
    await secondKey.writeAsBytes(List<int>.filled(64, 2));

    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: password,
      newPassword: password,
      newKeyFilePath: firstKey.path,
    );
    await expectLater(
      service.loadVault(
        databasePath: databasePath,
        password: password,
        keyFilePath: firstKey.path,
      ),
      completes,
    );

    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: password,
      currentKeyFilePath: firstKey.path,
      newPassword: password,
      newKeyFilePath: secondKey.path,
    );
    await expectLater(
      service.loadVault(
        databasePath: databasePath,
        password: password,
        keyFilePath: secondKey.path,
      ),
      completes,
    );
    await expectLater(
      service.loadVault(
        databasePath: databasePath,
        password: password,
        keyFilePath: firstKey.path,
      ),
      throwsA(anything),
    );

    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: password,
      currentKeyFilePath: secondKey.path,
      newPassword: password,
    );
    await expectLater(
      service.loadVault(databasePath: databasePath, password: password),
      completes,
    );
    await expectLater(
      service.loadVault(
        databasePath: databasePath,
        password: password,
        keyFilePath: secondKey.path,
      ),
      throwsA(anything),
    );
  });

  test('changes key-only vault and removes key by adding password', () async {
    final firstKey = File('${tempDir.path}/key-only-first.key');
    final secondKey = File('${tempDir.path}/key-only-second.key');
    await firstKey.writeAsBytes(List<int>.filled(64, 3));
    await secondKey.writeAsBytes(List<int>.filled(64, 4));
    await _createDatabase(
      databasePath: databasePath,
      password: '',
      keyFilePath: firstKey.path,
    );

    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: '',
      currentKeyFilePath: firstKey.path,
      newPassword: '',
      newKeyFilePath: secondKey.path,
    );
    await expectLater(
      service.loadVault(
        databasePath: databasePath,
        password: '',
        keyFilePath: secondKey.path,
      ),
      completes,
    );

    await service.changeCredentials(
      databasePath: databasePath,
      currentPassword: '',
      currentKeyFilePath: secondKey.path,
      newPassword: 'fallback-password',
    );
    await expectLater(
      service.loadVault(
        databasePath: databasePath,
        password: 'fallback-password',
      ),
      completes,
    );
  });

  test('wrong current credentials leave original database readable', () async {
    final originalBytes = await File(databasePath).readAsBytes();

    await expectLater(
      service.beginCredentialChange(
        databasePath: databasePath,
        currentPassword: 'wrong-password',
        newPassword: 'new-password',
      ),
      throwsA(anything),
    );

    expect(await File(databasePath).readAsBytes(), originalBytes);
    await expectLater(
      service.loadVault(databasePath: databasePath, password: password),
      completes,
    );
  });

  test('write failure leaves original database untouched', () async {
    final originalBytes = await File(databasePath).readAsBytes();
    final failingService = VaultKdbxService(
      credentialTempWriter: (_, _) async => throw FileSystemException('write'),
    );

    await expectLater(
      failingService.beginCredentialChange(
        databasePath: databasePath,
        currentPassword: password,
        newPassword: 'new-password',
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await File(databasePath).readAsBytes(), originalBytes);
  });

  test(
    'truncated temp file fails verification without replacing original',
    () async {
      final originalBytes = await File(databasePath).readAsBytes();
      final truncatingService = VaultKdbxService(
        credentialTempWriter: (file, _) =>
            file.writeAsBytes(const [1, 2, 3], flush: true),
      );

      await expectLater(
        truncatingService.beginCredentialChange(
          databasePath: databasePath,
          currentPassword: password,
          newPassword: 'new-password',
        ),
        throwsA(anything),
      );

      expect(await File(databasePath).readAsBytes(), originalBytes);
    },
  );

  test('credential rollback restores old credentials', () async {
    final change = await service.beginCredentialChange(
      databasePath: databasePath,
      currentPassword: password,
      newPassword: 'new-password',
    );
    await expectLater(
      service.loadVault(databasePath: databasePath, password: 'new-password'),
      completes,
    );

    await service.rollbackCredentialChange(change);

    await expectLater(
      service.loadVault(databasePath: databasePath, password: password),
      completes,
    );
    await expectLater(
      service.loadVault(databasePath: databasePath, password: 'new-password'),
      throwsA(anything),
    );
  });

  // P1-4: invalidate/complete/rollback hash protocol, audited on the vault
  // save path and the credential-change (rekey) install/rollback path.
  group('registry hash protocol (P1-4)', () {
    test('a vault write refreshes the registry hash after success', () async {
      final registry = _HashRegistryRepository();
      final now = DateTime.utc(2026);
      registry.records.add(
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: databasePath,
          displayName: 'vault.kdbx',
          sourceType: DatabaseSourceType.local,
          fileHash: 'old-hash',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final trackedService = VaultKdbxService(
        fileHashRecorder: DatabaseFileHashRecorder(
          registryRepository: registry,
        ),
      );
      final rootGroupId = await _rootGroupId(
        trackedService,
        databasePath,
        password,
      );

      await trackedService.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'GitHub',
        username: 'user',
        entryPassword: 'secret',
        url: '',
        notes: '',
      );

      expect(
        registry.records.single.fileHash,
        md5.convert(await File(databasePath).readAsBytes()).toString(),
      );
    });

    test('a registry hash-refresh failure after a successful write leaves the '
        'hash absent, never stale', () async {
      final registry = _HashRegistryRepository();
      final now = DateTime.utc(2026);
      registry.records.add(
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: databasePath,
          displayName: 'vault.kdbx',
          sourceType: DatabaseSourceType.local,
          fileHash: 'old-hash',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final trackedService = VaultKdbxService(
        fileHashRecorder: DatabaseFileHashRecorder(
          registryRepository: registry,
        ),
      );
      final rootGroupId = await _rootGroupId(
        trackedService,
        databasePath,
        password,
      );
      // Call 1 = the invalidation write inside beginWrite (must succeed);
      // call 2 = the post-write refresh (fails here).
      registry.failUpsertOnCall = 2;

      await expectLater(
        trackedService.createEntry(
          databasePath: databasePath,
          password: password,
          groupId: rootGroupId,
          title: 'Durable entry',
          username: 'user',
          entryPassword: 'secret',
          url: '',
          notes: '',
        ),
        completes,
      );

      expect(
        (await trackedService.loadAllEntries(
          databasePath: databasePath,
          password: password,
        )).single.title,
        'Durable entry',
        reason: 'the durable write itself must not be affected',
      );
      expect(registry.records.single.fileHash, isNull);
    });

    test('a registry invalidation failure blocks the write entirely', () async {
      final registry = _HashRegistryRepository();
      final now = DateTime.utc(2026);
      registry.records.add(
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: databasePath,
          displayName: 'vault.kdbx',
          sourceType: DatabaseSourceType.local,
          fileHash: 'old-hash',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final trackedService = VaultKdbxService(
        fileHashRecorder: DatabaseFileHashRecorder(
          registryRepository: registry,
        ),
      );
      final rootGroupId = await _rootGroupId(
        trackedService,
        databasePath,
        password,
      );
      final before = await File(databasePath).readAsBytes();
      registry.failUpsertOnCall = 1;

      await expectLater(
        trackedService.createEntry(
          databasePath: databasePath,
          password: password,
          groupId: rootGroupId,
          title: 'Blocked entry',
          username: 'user',
          entryPassword: 'secret',
          url: '',
          notes: '',
        ),
        throwsStateError,
      );

      expect(await File(databasePath).readAsBytes(), before);
      expect(registry.records.single.fileHash, 'old-hash');
    });

    test(
      'a writer failure restores the previous registry hash, not absent',
      () async {
        final registry = _HashRegistryRepository();
        final now = DateTime.utc(2026);
        registry.records.add(
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: databasePath,
            displayName: 'vault.kdbx',
            sourceType: DatabaseSourceType.local,
            fileHash: 'old-hash',
            createdAt: now,
            updatedAt: now,
          ),
        );
        final rootGroupId = await _rootGroupId(
          VaultKdbxService(),
          databasePath,
          password,
        );
        final before = await File(databasePath).readAsBytes();
        final trackedService = VaultKdbxService(
          safeWriter: _FailingSafeVaultFileWriter(),
          fileHashRecorder: DatabaseFileHashRecorder(
            registryRepository: registry,
          ),
        );

        await expectLater(
          trackedService.createEntry(
            databasePath: databasePath,
            password: password,
            groupId: rootGroupId,
            title: 'Failed entry',
            username: 'user',
            entryPassword: 'secret',
            url: '',
            notes: '',
          ),
          throwsException,
        );

        expect(await File(databasePath).readAsBytes(), before);
        expect(registry.records.single.fileHash, 'old-hash');
      },
    );

    test('credential change (rekey) install and rollback keep the registry '
        'hash aligned with the file on disk', () async {
      final originalBytes = await File(databasePath).readAsBytes();
      final originalHash = md5.convert(originalBytes).toString();
      final now = DateTime.utc(2026);
      final registry = _HashRegistryRepository()
        ..records.add(
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: databasePath,
            displayName: 'vault.kdbx',
            sourceType: DatabaseSourceType.local,
            fileHash: originalHash,
            createdAt: now,
            updatedAt: now,
          ),
        );
      final trackedService = VaultKdbxService(
        fileHashRecorder: DatabaseFileHashRecorder(
          registryRepository: registry,
        ),
      );

      final change = await trackedService.beginCredentialChange(
        databasePath: databasePath,
        currentPassword: password,
        newPassword: 'new-password',
      );
      final changedHash = md5
          .convert(await File(databasePath).readAsBytes())
          .toString();
      expect(registry.records.single.fileHash, changedHash);
      expect(changedHash, isNot(originalHash));

      await trackedService.rollbackCredentialChange(change);

      expect(await File(databasePath).readAsBytes(), originalBytes);
      expect(registry.records.single.fileHash, originalHash);
    });

    test('startup reconciliation fills a missing hash', () async {
      final registry = _HashRegistryRepository();
      final now = DateTime.utc(2026);
      registry.records.add(
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: databasePath,
          displayName: 'vault.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: now,
          updatedAt: now,
        ),
      );

      await DatabaseFileHashRecorder(registryRepository: registry)
          .reconcileMissingHashes();

      expect(
        registry.records.single.fileHash,
        md5.convert(await File(databasePath).readAsBytes()).toString(),
      );
    });

    test('reconciliation never overwrites an already-trusted hash', () async {
      final registry = _HashRegistryRepository();
      final now = DateTime.utc(2026);
      registry.records.add(
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: databasePath,
          displayName: 'vault.kdbx',
          sourceType: DatabaseSourceType.local,
          fileHash: 'trusted-hash',
          createdAt: now,
          updatedAt: now,
        ),
      );

      await DatabaseFileHashRecorder(registryRepository: registry)
          .reconcileMissingHashes();

      expect(registry.records.single.fileHash, 'trusted-hash');
    });

    test('reconciliation completes without throwing when the registry list '
        'itself fails (e.g. a corrupt registry file), so a crash reading the '
        'registry never blocks app startup', () async {
      final registry = _HashRegistryRepository();
      final now = DateTime.utc(2026);
      registry.records.add(
        DatabaseRecord(
          databaseId: 'db-1',
          canonicalPath: databasePath,
          displayName: 'vault.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: now,
          updatedAt: now,
        ),
      );
      registry.failListWith = const FormatException('corrupt registry');

      await expectLater(
        DatabaseFileHashRecorder(registryRepository: registry)
            .reconcileMissingHashes(),
        completes,
      );

      expect(
        registry.records.single.fileHash,
        isNull,
        reason: 'a listing failure must skip reconciliation, not crash it',
      );
    });
  });

  test('maps created and modified timestamps for new entries', () async {
    final rootGroupId = await _rootGroupId(service, databasePath, password);
    await service.createEntry(
      databasePath: databasePath,
      password: password,
      groupId: rootGroupId,
      title: 'GitHub',
      username: 'camillo',
      entryPassword: 'p@ss-1',
      url: 'https://github.com',
      notes: 'note',
    );

    final entries = await service.loadAllEntries(
      databasePath: databasePath,
      password: password,
    );
    final entry = entries.single;

    expect(entry.createdAt, isNotNull);
    expect(entry.updatedAt, isNotNull);
    expect(entry.lastPasswordChangedAt, entry.createdAt);
  });

  group('passkey fields (spec 023 T013)', () {
    const pemKey = 'KPEX_PASSKEY_PRIVATE_KEY_PEM';
    const passkeyStrings = {
      'KPEX_PASSKEY_RELYING_PARTY': ('webauthn.io', false),
      'KPEX_PASSKEY_CREDENTIAL_ID': ('AQID', true),
      'KPEX_PASSKEY_USER_HANDLE': ('BAUG', true),
      'KPEX_PASSKEY_USERNAME': ('alice', false),
      pemKey: (es256PrivateKeyPem, true),
      'KPEX_PASSKEY_FLAG_BE': ('1', false),
      'KPEX_PASSKEY_FLAG_BS': ('1', false),
      // Not understood by the parser: must survive untouched (FR-003).
      'KPEX_PASSKEY_PRF': ('opaque', true),
    };

    Future<Map<String, (String, bool)>> rawPasskeyStrings() async {
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        Credentials(ProtectedValue.fromString(password)),
      );
      final entry = file.body.rootGroup.getAllEntries().single;
      return {
        for (final s in entry.stringEntries)
          if (s.key.key.startsWith('KPEX_PASSKEY_'))
            s.key.key: (s.value?.getText() ?? '', s.value is ProtectedValue),
      };
    }

    /// Writes the KeePassXC layout with the raw library, as KeePassXC would.
    Future<String> createPasskeyEntry() async {
      final credentials = Credentials(ProtectedValue.fromString(password));
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        credentials,
      );
      final entry = KdbxEntry.create(file, file.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('webauthn.io'))
        ..setString(KdbxKeyCommon.USER_NAME, PlainValue('alice'))
        ..setString(KdbxKey('Recovery'), ProtectedValue.fromString('r'));
      for (final MapEntry(:key, value: (text, protected))
          in passkeyStrings.entries) {
        entry.setString(
          KdbxKey(key),
          protected ? ProtectedValue.fromString(text) : PlainValue(text),
        );
      }
      file.body.rootGroup.addEntry(entry);
      await File(databasePath).writeAsBytes(await file.save(), flush: true);
      return entry.uuid.uuid;
    }

    test('reads passkeys and keeps them out of customFields', () async {
      await createPasskeyEntry();
      final entry = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;

      expect(entry.hasPasskey, isTrue);
      expect(entry.passkeys.single.relyingPartyId, 'webauthn.io');
      expect(entry.passkeys.single.usable, isTrue);
      expect(entry.passkeyDigest, isNotNull);
      expect(entry.customFields.map((f) => f.key), ['Recovery']);
      expect(entry.toString(), isNot(contains('PRIVATE KEY')));
    });

    test('passkeyDigest changes when a field loses its protection', () async {
      final id = await createPasskeyEntry();
      Future<String?> digest() async => (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single.passkeyDigest;
      final before = await digest();

      // Same text, protection flipped: exactly what a downgrading writer does.
      final credentials = Credentials(ProtectedValue.fromString(password));
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        credentials,
      );
      final entry = file.body.rootGroup.entries.singleWhere(
        (e) => e.uuid.uuid == id,
      );
      final pemKey = KdbxKey(PasskeyParser.privateKeyPemKey);
      entry.setString(pemKey, PlainValue(entry.getString(pemKey)!.getText()));
      await File(databasePath).writeAsBytes(await file.save(), flush: true);

      expect(await digest(), isNot(before));
    });

    test(
      'a title-only save leaves every passkey string byte-identical',
      () async {
        final entryId = await createPasskeyEntry();
        final before = await rawPasskeyStrings();
        final entry = (await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        )).single;

        await service.updateEntry(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          title: 'renamed',
          username: entry.username,
          entryPassword: entry.password,
          url: entry.url,
          notes: entry.notes,
          customFields: entry.customFields,
        );

        expect(await rawPasskeyStrings(), before);
        expect(before.keys, contains('KPEX_PASSKEY_PRF'));
      },
    );

    test(
      'a writer cannot inject passkey fields through customFields',
      () async {
        final rootGroupId = await _rootGroupId(service, databasePath, password);
        await service.createEntry(
          databasePath: databasePath,
          password: password,
          groupId: rootGroupId,
          title: 'x',
          username: 'u',
          entryPassword: 'p',
          url: '',
          notes: '',
          customFields: const [
            VaultCustomField(key: pemKey, value: 'injected'),
            VaultCustomField(key: 'ok', value: 'kept'),
          ],
        );
        expect(await rawPasskeyStrings(), isEmpty);
      },
    );

    test(
      'history revisions carry no passkey material and diff by name',
      () async {
        final entryId = await createPasskeyEntry();
        final entry = (await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        )).single;
        await service.updateEntry(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          title: 'renamed',
          username: entry.username,
          entryPassword: entry.password,
          url: entry.url,
          notes: entry.notes,
          customFields: entry.customFields,
        );

        final history = await service.loadEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
        );
        final revision = history.revisions.single;
        expect(revision.customFields.map((f) => f.key), ['Recovery']);
        expect(revision.toString(), isNot(contains('PRIVATE KEY')));
        expect(revision.passkeyDigest, entry.passkeyDigest);

        final renamed = (await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        )).single;
        expect(
          changedFieldsForRevision(revision: revision, currentEntry: renamed),
          {VaultEntryField.title},
        );
      },
    );

    test('restoring a revision leaves the passkey intact', () async {
      final entryId = await createPasskeyEntry();
      final before = await rawPasskeyStrings();
      final entry = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;
      await service.updateEntry(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        title: 'renamed',
        username: entry.username,
        entryPassword: entry.password,
        url: entry.url,
        notes: entry.notes,
        customFields: entry.customFields,
      );
      final revision = (await service.loadEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      )).revisions.single;

      await service.restoreEntryRevision(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        replacedAt: revision.replacedAt,
        ordinal: revision.ordinal,
      );

      expect(await rawPasskeyStrings(), before);
    });

    // ---- T203: deletePasskey ------------------------------------------

    /// Adds a second passkey group (`_1`) to the entry, as KeePassDX does.
    Future<void> addSecondPasskey(String entryId) async {
      final credentials = Credentials(ProtectedValue.fromString(password));
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        credentials,
      );
      final entry = file.body.rootGroup.entries.singleWhere(
        (e) => e.uuid.uuid == entryId,
      );
      entry
        ..setString(
          KdbxKey('KPEX_PASSKEY_RELYING_PARTY_1'),
          PlainValue('example.org'),
        )
        ..setString(
          KdbxKey('KPEX_PASSKEY_CREDENTIAL_ID_1'),
          ProtectedValue.fromString('BAUG'),
        )
        ..setString(
          KdbxKey(r'KPEX_PASSKEY_PRIVATE_KEY_PEM_1'),
          ProtectedValue.fromString(es256PrivateKeyPem),
        );
      await File(databasePath).writeAsBytes(await file.save(), flush: true);
    }

    Future<VaultEntry> loadSingleEntry() async => (await service.loadAllEntries(
      databasePath: databasePath,
      password: password,
    )).single;

    test('removes the passkey and leaves the rest of the entry', () async {
      final entryId = await createPasskeyEntry();
      final before = await loadSingleEntry();

      await service.deletePasskey(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        relyingPartyId: 'webauthn.io',
        credentialId: before.passkeys.single.credentialId,
      );

      final after = await loadSingleEntry();
      expect(after.passkeys, isEmpty);
      expect(after.passkeyDigest, isNull);
      // Every KPEX string went, the unparsed `PRF` included: it belonged to
      // the credential that is gone.
      expect(await rawPasskeyStrings(), isEmpty);
      // The record itself is untouched.
      expect(after.title, before.title);
      expect(after.username, before.username);
      expect(after.customFields.map((f) => f.key), ['Recovery']);
    });

    test('appends one history revision', () async {
      final entryId = await createPasskeyEntry();
      final before = await loadSingleEntry();

      await service.deletePasskey(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        relyingPartyId: 'webauthn.io',
        credentialId: before.passkeys.single.credentialId,
      );

      final history = await service.loadEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      );
      expect(history.revisions, hasLength(1));
      expect(history.revisions.single.toString(), isNot(contains('PRIVATE')));
    });

    test('deleting one of two groups leaves the other whole', () async {
      final entryId = await createPasskeyEntry();
      await addSecondPasskey(entryId);
      final before = await loadSingleEntry();
      expect(before.passkeys, hasLength(2));
      final first = before.passkeys.singleWhere(
        (p) => p.relyingPartyId == 'webauthn.io',
      );

      await service.deletePasskey(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        relyingPartyId: 'webauthn.io',
        credentialId: first.credentialId,
      );

      final after = await loadSingleEntry();
      // The empty suffix is a prefix of `_1`: a prefix match here would have
      // taken both.
      expect(after.passkeys.single.relyingPartyId, 'example.org');
      expect((await rawPasskeyStrings()).keys, everyElement(endsWith('_1')));
    });

    test(
      'a second delete of the same passkey throws PasskeyNotFound',
      () async {
        final entryId = await createPasskeyEntry();
        final credentialId =
            (await loadSingleEntry()).passkeys.single.credentialId;

        Future<void> attempt() => service.deletePasskey(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          relyingPartyId: 'webauthn.io',
          credentialId: credentialId,
        );

        await attempt();
        await expectLater(attempt(), throwsA(isA<PasskeyNotFound>()));
      },
    );

    // ---- US3: createPasskey -------------------------------------------

    VaultPasskey newPasskey({
      String relyingPartyId = 'example.org',
      List<int> credentialId = const [7, 7, 7],
      List<int>? userHandle = const [8, 8],
      String username = 'ada',
    }) => VaultPasskey(
      relyingPartyId: relyingPartyId,
      credentialId: Uint8List.fromList(credentialId),
      userHandle: userHandle == null ? null : Uint8List.fromList(userHandle),
      username: username,
      privateKeyPem: es256PrivateKeyPem,
      algorithm: VaultPasskeyAlgorithm.es256,
    );

    Future<String> createPlainEntry({
      String url = 'https://example.org',
    }) async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Example',
        username: 'ada',
        entryPassword: '',
        url: url,
        notes: '',
      );
      return (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single.id;
    }

    test('writes the KeePassXC layout, with its protection flags', () async {
      final entryId = await createPlainEntry();

      await service.createPasskey(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        passkey: newPasskey(),
      );

      final raw = await rawPasskeyStrings();
      // Secret and account material protected; routing and flags not — the
      // same split KeePassXC writes, which is what keeps the file usable
      // there.
      expect(raw['KPEX_PASSKEY_PRIVATE_KEY_PEM']!.$2, isTrue);
      expect(raw['KPEX_PASSKEY_CREDENTIAL_ID']!.$2, isTrue);
      expect(raw['KPEX_PASSKEY_USER_HANDLE']!.$2, isTrue);
      expect(raw['KPEX_PASSKEY_RELYING_PARTY']!.$2, isFalse);
      expect(raw['KPEX_PASSKEY_USERNAME']!.$2, isFalse);
      expect(raw['KPEX_PASSKEY_FLAG_BE']!.$2, isFalse);
      // Unpadded base64url, as KeePassXC spells it.
      expect(raw['KPEX_PASSKEY_CREDENTIAL_ID']!.$1, 'BwcH');
      expect(raw['KPEX_PASSKEY_USER_HANDLE']!.$1, 'CAg');

      final stored = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single.passkeys.single;
      expect(stored.usable, isTrue);
      expect(stored.relyingPartyId, 'example.org');
      expect(stored.algorithm, VaultPasskeyAlgorithm.es256);
    });

    test(
      'a second passkey goes in the next group, keeping the first',
      () async {
        final entryId = await createPasskeyEntry();

        await service.createPasskey(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          passkey: newPasskey(),
        );

        final stored = (await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        )).single.passkeys;
        expect(
          stored.map((p) => p.relyingPartyId),
          containsAll(['webauthn.io', 'example.org']),
        );
        expect(stored.map((p) => p.fieldSuffix), containsAll(['', '_1']));
        // The unparsed field of the original group is untouched.
        expect((await rawPasskeyStrings()).keys, contains('KPEX_PASSKEY_PRF'));
      },
    );

    // FR-019: never silently.
    test('a clash on (rpId, userHandle) throws and writes nothing', () async {
      final entryId = await createPasskeyEntry();
      final before = await rawPasskeyStrings();

      await expectLater(
        service.createPasskey(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          // The fixture entry's handle is `BAUG` = 0x04 0x05 0x06.
          passkey: newPasskey(
            relyingPartyId: 'webauthn.io',
            userHandle: const [4, 5, 6],
          ),
        ),
        throwsA(isA<PasskeyAlreadyExists>()),
      );
      expect(await rawPasskeyStrings(), before);
    });

    test('the same site with a different account is not a clash', () async {
      final entryId = await createPasskeyEntry();

      await service.createPasskey(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        passkey: newPasskey(
          relyingPartyId: 'webauthn.io',
          userHandle: const [1, 1, 1],
        ),
      );

      expect(
        (await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        )).single.passkeys,
        hasLength(2),
      );
    });

    test('replaceExisting overwrites exactly the clashing group', () async {
      final entryId = await createPasskeyEntry();

      await service.createPasskey(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        passkey: newPasskey(
          relyingPartyId: 'webauthn.io',
          userHandle: const [4, 5, 6],
          credentialId: const [9, 9, 9],
        ),
        replaceExisting: true,
      );

      final stored = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single.passkeys;
      expect(stored, hasLength(1));
      expect(stored.single.credentialId, Uint8List.fromList([9, 9, 9]));
      // The replaced group went whole, unparsed field included: it belonged
      // to the credential that is gone.
      expect(
        (await rawPasskeyStrings()).keys,
        isNot(contains('KPEX_PASSKEY_PRF')),
      );
    });

    test('a passkey with no user handle writes no handle field', () async {
      final entryId = await createPlainEntry(url: '');

      await service.createPasskey(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        passkey: newPasskey(userHandle: null),
      );

      expect(
        (await rawPasskeyStrings()).keys,
        isNot(contains('KPEX_PASSKEY_USER_HANDLE')),
      );
    });

    test('an unknown entry throws and writes nothing', () async {
      await createPasskeyEntry();
      final before = await rawPasskeyStrings();

      await expectLater(
        service.createPasskey(
          databasePath: databasePath,
          password: password,
          entryId: 'no-such-entry',
          passkey: newPasskey(),
        ),
        throwsA(isA<Exception>()),
      );
      expect(await rawPasskeyStrings(), before);
    });

    test(
      'a credential id that does not match throws, and writes nothing',
      () async {
        final entryId = await createPasskeyEntry();
        final before = await rawPasskeyStrings();

        await expectLater(
          service.deletePasskey(
            databasePath: databasePath,
            password: password,
            entryId: entryId,
            relyingPartyId: 'webauthn.io',
            credentialId: Uint8List.fromList([9, 9, 9]),
          ),
          throwsA(isA<PasskeyNotFound>()),
        );
        expect(await rawPasskeyStrings(), before);
      },
    );
  });

  group('protected custom fields (spec 023 T010, SC-008)', () {
    Future<Map<String, bool>> protectionByKey() async {
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        Credentials(ProtectedValue.fromString(password)),
      );
      final entry = file.body.rootGroup.getAllEntries().single;
      return {
        for (final key in ['Recovery', 'Note'])
          key: entry.getString(KdbxKey(key)) is ProtectedValue,
      };
    }

    test('writes the flag as given and reads it back', () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Bank',
        username: 'user',
        entryPassword: 'p',
        url: '',
        notes: '',
        customFields: const [
          VaultCustomField(key: 'Recovery', value: 'abc', isProtected: true),
          VaultCustomField(key: 'Note', value: 'plain'),
        ],
      );

      expect(await protectionByKey(), {'Recovery': true, 'Note': false});

      final entry = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;
      final byKey = {for (final f in entry.customFields) f.key: f};
      expect(byKey['Recovery']!.isProtected, isTrue);
      expect(byKey['Recovery']!.value, 'abc');
      expect(byKey['Note']!.isProtected, isFalse);
    });

    test('an unrelated save never downgrades a protected field', () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Bank',
        username: 'user',
        entryPassword: 'p',
        url: '',
        notes: '',
        customFields: const [
          VaultCustomField(key: 'Recovery', value: 'abc', isProtected: true),
          VaultCustomField(key: 'Note', value: 'plain'),
        ],
      );
      final first = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;

      await service.updateEntry(
        databasePath: databasePath,
        password: password,
        entryId: first.id,
        title: 'Bank renamed',
        username: first.username,
        entryPassword: first.password,
        url: first.url,
        notes: first.notes,
        customFields: first.customFields,
      );

      expect(await protectionByKey(), {'Recovery': true, 'Note': false});
    });
  });

  test(
    'keeps password change timestamp at creation when password does not change',
    () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Mail',
        username: 'user',
        entryPassword: 'same-password',
        url: '',
        notes: '',
      );

      final first = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;

      await service.updateEntry(
        databasePath: databasePath,
        password: password,
        entryId: first.id,
        title: 'Mail Personal',
        username: first.username,
        entryPassword: first.password,
        url: first.url,
        notes: first.notes,
        customFields: first.customFields,
      );

      final updated = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;

      expect(updated.lastPasswordChangedAt, first.createdAt);
    },
  );

  test('sets last password change timestamp to update timestamp when password changes', () async {
    final rootGroupId = await _rootGroupId(service, databasePath, password);
    await service.createEntry(
      databasePath: databasePath,
      password: password,
      groupId: rootGroupId,
      title: 'Bank',
      username: 'user',
      entryPassword: 'old-password',
      url: '',
      notes: '',
    );

    final first = (await service.loadAllEntries(
      databasePath: databasePath,
      password: password,
    )).single;

    await service.updateEntry(
      databasePath: databasePath,
      password: password,
      entryId: first.id,
      title: first.title,
      username: first.username,
      entryPassword: 'new-password',
      url: first.url,
      notes: first.notes,
      customFields: first.customFields,
    );

    final updated = (await service.loadAllEntries(
      databasePath: databasePath,
      password: password,
    )).single;

    expect(updated.lastPasswordChangedAt, updated.updatedAt);
  });

  test(
    'updateEntry persists changed title, username, password, url, notes',
    () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Original Title',
        username: 'original_user',
        entryPassword: 'original_pass',
        url: 'https://original.com',
        notes: 'original notes',
      );

      final original = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;

      await service.updateEntry(
        databasePath: databasePath,
        password: password,
        entryId: original.id,
        title: 'Updated Title',
        username: 'updated_user',
        entryPassword: 'updated_pass',
        url: 'https://updated.com',
        notes: 'updated notes',
      );

      final updated = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;

      expect(updated.title, 'Updated Title');
      expect(updated.username, 'updated_user');
      expect(updated.password, 'updated_pass');
      expect(updated.url, 'https://updated.com');
      expect(updated.notes, 'updated notes');
    },
  );

  // spec-016 C3: the save-capture flow tells the user the previous password
  // stays in the entry's history. Nothing in this repo writes that history —
  // the KDBX writer does it — so this test is what makes the claim true rather
  // than assumed.
  test(
    'updateEntry keeps the previous password in the entry history',
    () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Example',
        username: 'alice',
        entryPassword: 'first-password',
        url: 'https://example.com',
        notes: '',
      );

      final created = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;

      await service.updateEntry(
        databasePath: databasePath,
        password: password,
        entryId: created.id,
        title: created.title,
        username: created.username,
        entryPassword: 'second-password',
        url: created.url,
        notes: created.notes,
      );

      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        Credentials(ProtectedValue.fromString(password)),
      );
      final entry = file.body.rootGroup.getAllEntries().single;

      expect(
        entry.getString(KdbxKeyCommon.PASSWORD)?.getText(),
        'second-password',
      );
      expect(
        entry.history.map(
          (revision) => revision.getString(KdbxKeyCommon.PASSWORD)?.getText(),
        ),
        contains('first-password'),
      );
    },
  );

  group('mergeEntries', () {
    test(
      'copies notes from secondary to primary when primary notes is empty',
      () async {
        final rootGroupId = await _rootGroupId(service, databasePath, password);
        final primaryId = await service.createEntry(
          databasePath: databasePath,
          password: password,
          groupId: rootGroupId,
          title: 'Primary',
          username: 'alice',
          entryPassword: 'pw',
          url: 'https://github.com',
          notes: '',
        );
        final secondaryId = await service.createEntry(
          databasePath: databasePath,
          password: password,
          groupId: rootGroupId,
          title: 'Secondary',
          username: 'alice',
          entryPassword: 'pw',
          url: 'https://github.com',
          notes: 'important note',
        );

        await service.mergeEntries(
          databasePath: databasePath,
          password: password,
          primaryId: primaryId,
          secondaryIds: [secondaryId],
        );

        final all = await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        );
        final primary = all.firstWhere((e) => e.id == primaryId);
        expect(primary.notes, 'important note');
      },
    );

    test('does not overwrite primary notes when already set', () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      final primaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Primary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: 'keep me',
      );
      final secondaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Secondary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: 'do not copy',
      );

      await service.mergeEntries(
        databasePath: databasePath,
        password: password,
        primaryId: primaryId,
        secondaryIds: [secondaryId],
      );

      final all = await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      );
      final primary = all.firstWhere((e) => e.id == primaryId);
      expect(primary.notes, 'keep me');
    });

    test('copies custom field from secondary absent in primary', () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      final primaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Primary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: '',
        customFields: [const VaultCustomField(key: 'PIN', value: '1234')],
      );
      final secondaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Secondary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: '',
        customFields: [
          const VaultCustomField(key: 'Recovery', value: 'abc123'),
        ],
      );

      await service.mergeEntries(
        databasePath: databasePath,
        password: password,
        primaryId: primaryId,
        secondaryIds: [secondaryId],
      );

      final all = await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      );
      final primary = all.firstWhere((e) => e.id == primaryId);
      final fieldKeys = primary.customFields.map((f) => f.key).toList();
      expect(fieldKeys, containsAll(['PIN', 'Recovery']));
    });

    test('copies missing URLs from secondary as KP2A_URL_n fields', () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      final primaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Primary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: '',
        customFields: [
          const VaultCustomField(key: 'KP2A_URL_1', value: 'https://a.com'),
        ],
      );
      final secondaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Secondary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://gitlab.com',
        notes: '',
        customFields: [
          // Same as primary's URL after normalization — must not duplicate.
          const VaultCustomField(
            key: 'KP2A_URL_1',
            value: 'http://github.com/',
          ),
          const VaultCustomField(key: 'KP2A_URL_2', value: 'https://b.com'),
        ],
      );

      await service.mergeEntries(
        databasePath: databasePath,
        password: password,
        primaryId: primaryId,
        secondaryIds: [secondaryId],
      );

      final all = await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      );
      final primary = all.firstWhere((e) => e.id == primaryId);
      expect(primary.url, 'https://github.com');
      final urlValues = primary.customFields
          .where((f) => f.key.startsWith('KP2A_URL_'))
          .map((f) => f.value)
          .toList();
      expect(
        urlValues,
        unorderedEquals([
          'https://a.com',
          'https://gitlab.com',
          'https://b.com',
        ]),
      );
    });

    test('moves secondary to recycle bin after merge', () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      final primaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Primary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: '',
      );
      final secondaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Secondary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: '',
      );

      await service.mergeEntries(
        databasePath: databasePath,
        password: password,
        primaryId: primaryId,
        secondaryIds: [secondaryId],
      );

      final recycleBinEntries = await service.loadRecycleBinEntries(
        databasePath: databasePath,
        password: password,
      );
      expect(recycleBinEntries.map((e) => e.id), contains(secondaryId));

      final all = await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      );
      final activeIds = all.map((e) => e.id).toSet();
      expect(activeIds, contains(primaryId));
      expect(activeIds, isNot(contains(secondaryId)));
    });

    test('loadVault allEntries excludes entries in recycle bin', () async {
      final rootGroupId = await _rootGroupId(service, databasePath, password);
      final primaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Primary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: '',
      );
      final secondaryId = await service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: rootGroupId,
        title: 'Secondary',
        username: 'alice',
        entryPassword: 'pw',
        url: 'https://github.com',
        notes: '',
      );

      await service.mergeEntries(
        databasePath: databasePath,
        password: password,
        primaryId: primaryId,
        secondaryIds: [secondaryId],
      );

      final snapshot = await service.loadVault(
        databasePath: databasePath,
        password: password,
      );
      final activeIds = snapshot.allEntries.map((e) => e.id).toSet();

      expect(activeIds, contains(primaryId));
      expect(activeIds, isNot(contains(secondaryId)));
    });
  });

  // ===========================================================================
  // spec 008 Gate 0 (T001-T004) — merge feasibility spike.
  //
  // Test-only. Nothing here is production code and nothing here may be
  // promoted to `lib/` before Gate 2 (T201 domain freeze).
  //
  // Hard rules enforced by this group:
  //   * parity is SEMANTIC (canonical manifest), never byte-equality: salts,
  //     IVs and ciphertext legitimately differ across saves;
  //   * `KdbxFile.merge` is forbidden (library marks it
  //     "FIXME: THiS iS NOT YET FINISHED, DO NOT USE") — asserted by source
  //     scan in T004;
  //   * mutation works on the opened KDBX object graph, never by rebuilding
  //     from `VaultSnapshot`.
  // ===========================================================================
  group('merge feasibility', () {
    late Directory spikeDir;

    setUp(() async {
      spikeDir = await Directory.systemTemp.createTemp('kdbx_merge_spike_');
    });

    tearDown(() async {
      if (await spikeDir.exists()) {
        await spikeDir.delete(recursive: true);
      }
    });

    // -----------------------------------------------------------------------
    // T001 — KDBX semantic matrix.
    // -----------------------------------------------------------------------
    for (final version in _SpikeVersion.values) {
      test('T001 ${version.label} preserves every supported construct '
          'across save and reopen', () async {
        final credentials = _passwordOnlyCredentials();
        final original = _buildFixture(
          version: version,
          credentials: credentials,
        );

        final before = _manifest(original);
        final saved = await original.save();
        final reopened = await KdbxFormat().read(saved, credentials);
        final after = _manifest(reopened);

        expect(
          after,
          before,
          reason:
              'semantic manifest diverged across ${version.label} round-trip',
        );

        // Category-level assertions so a regression names the failing
        // construct instead of dumping the whole manifest.
        expect(after['header'], before['header'], reason: 'header/KDF/cipher');
        expect(
          after['meta'],
          before['meta'],
          reason: 'metadata/settings/custom data/custom icons',
        );
        expect(
          after['deletedObjects'],
          before['deletedObjects'],
          reason: 'DeletedObjects tombstones',
        );
        expect(
          after['groups'],
          before['groups'],
          reason: 'group hierarchy/moves/recycle bin',
        );
        expect(
          after['entries'],
          before['entries'],
          reason: 'entries/strings/attachments/history',
        );

        // The fixture must actually exercise every category, otherwise the
        // round-trip above proves nothing.
        final entries = after['entries']! as Map<String, Object?>;
        final meta = after['meta']! as Map<String, Object?>;
        expect(
          after['deletedObjects'],
          isNotEmpty,
          reason: 'fixture must contain a permanent tombstone',
        );
        expect(meta['customData'], isNotEmpty);
        expect(meta['customIcons'], isNotEmpty);
        expect(meta['recycleBinUuid'], isNotNull);

        final conflicted =
            entries[_fixtureConflictEntryUuid]! as Map<String, Object?>;
        expect(
          conflicted['history'],
          isNotEmpty,
          reason: 'fixture must contain history entries',
        );

        final rich = entries[_fixtureRichEntryUuid]! as Map<String, Object?>;
        final strings = rich['strings']! as Map<String, Object?>;
        // Original key spelling preserved verbatim, including case.
        expect(strings.keys, contains(_fixtureProtectedCustomKey));
        expect(strings.keys, contains(_fixturePlainCustomKey));
        expect(
          (strings[_fixtureProtectedCustomKey]! as Map)['protected'],
          isTrue,
        );
        expect((strings[_fixturePlainCustomKey]! as Map)['protected'], isFalse);
        // Presence semantics: empty string is present, not missing.
        expect(strings.keys, contains(_fixtureEmptyStringKey));
        expect((strings[_fixtureEmptyStringKey]! as Map)['value'], '');

        // Colors: the VALUE, not merely its presence. A manifest that only
        // recorded presence would compare equal even if both sides were null.
        expect(rich['foregroundColor'], _fixtureForegroundColor);
        expect(rich['backgroundColor'], _fixtureBackgroundColor);

        // Entry AutoType: unmodelled by the library, preserved as raw XML.
        expect(rich['autoType'], isNotNull);
        expect(rich['autoType'], contains(_fixtureAutoTypeSequence));

        final binaries = rich['binaries']! as Map<String, Object?>;
        expect(binaries.keys, contains(_fixtureProtectedAttachmentName));
        expect(binaries.keys, contains(_fixturePlainAttachmentName));
        // Presence semantics: zero-byte attachment is present, not missing.
        expect(binaries.keys, contains(_fixtureEmptyAttachmentName));
        expect((binaries[_fixtureEmptyAttachmentName]! as Map)['length'], 0);
        expect(
          (binaries[_fixtureProtectedAttachmentName]! as Map)['protected'],
          isTrue,
        );
      });
    }

    // -----------------------------------------------------------------------
    // T001 — constructs the library does not model, read off the entry's own
    // exported `XmlElement`. Both were previously recorded as unverifiable.
    // -----------------------------------------------------------------------
    test('T001 entry colors round-trip with their RGB values, not just '
        'their presence', () async {
      final credentials = _passwordOnlyCredentials();
      final original = _buildFixture(
        version: _SpikeVersion.v4,
        credentials: credentials,
      );
      final reopened = await KdbxFormat().read(
        await original.save(),
        credentials,
      );
      final rich = _entryByUuid(reopened, _fixtureRichEntryUuid);

      // `KdbxColor` is opaque, the XML is not.
      expect(_xmlText(rich, 'ForegroundColor'), _fixtureForegroundColor);
      expect(_xmlText(rich, 'BackgroundColor'), _fixtureBackgroundColor);

      // And the wrapper still reports the colors as set, so both views agree.
      expect(rich.foregroundColor.get()?.isNull, isFalse);
      expect(rich.backgroundColor.get()?.isNull, isFalse);

      // A differing value must be detectable, otherwise the assertion above
      // would pass for any color at all.
      rich.foregroundColor.set(KdbxColor.parse('#0000FF'));
      final mutated = await KdbxFormat().read(
        await reopened.save(),
        credentials,
      );
      expect(
        _xmlText(
          _entryByUuid(mutated, _fixtureRichEntryUuid),
          'ForegroundColor',
        ),
        '#0000FF',
      );
    });

    test('T001 entry AutoType survives save and reopen as an untouched '
        'XML node', () async {
      final credentials = _passwordOnlyCredentials();
      final original = _buildFixture(
        version: _SpikeVersion.v4,
        credentials: credentials,
      );
      final reopened = await KdbxFormat().read(
        await original.save(),
        credentials,
      );

      final autoType = _xmlOf(
        _entryByUuid(reopened, _fixtureRichEntryUuid),
        'AutoType',
      );
      expect(autoType, isNotNull, reason: 'the whole node must survive');
      expect(
        autoType!.findElements('DefaultSequence').single.innerText,
        _fixtureAutoTypeSequence,
      );

      final association = autoType.findElements('Association').single;
      expect(
        association.findElements('Window').single.innerText,
        _fixtureAutoTypeWindow,
      );
      expect(
        association.findElements('KeystrokeSequence').single.innerText,
        _fixtureAutoTypeAssociationSequence,
      );
      expect(autoType.findElements('Enabled').single.innerText, 'True');
    });

    // -----------------------------------------------------------------------
    // T002 — Credential round-trip. Semantic parity only, never bytes.
    // -----------------------------------------------------------------------
    for (final version in _SpikeVersion.values) {
      for (final withKeyFile in const [false, true]) {
        final label = withKeyFile ? 'password + key file' : 'password only';
        test('T002 ${version.label} round-trips with $label', () async {
          // Obviously fake, non-secret test material.
          final keyFileBytes = withKeyFile
              ? Uint8List.fromList(
                  List<int>.generate(64, (index) => (index * 7) & 0xFF),
                )
              : null;
          final credentials = Credentials.composite(
            ProtectedValue.fromString(_spikePassword),
            keyFileBytes,
          );

          final original = _buildFixture(
            version: version,
            credentials: credentials,
          );
          final before = _manifest(original);

          final path = '${spikeDir.path}/${version.name}_$withKeyFile.kdbx';
          await File(path).writeAsBytes(await original.save(), flush: true);

          final firstBytes = await File(path).readAsBytes();
          final reopened = await KdbxFormat().read(firstBytes, credentials);
          expect(_manifest(reopened), before);

          // Re-save the reopened file and reopen again: proves the candidate
          // produced by an adapter is itself reopenable with the ORIGINAL
          // credentials (spec FR-1 "reopened with original credentials").
          final secondBytes = await reopened.save();
          final reopenedTwice = await KdbxFormat().read(
            secondBytes,
            credentials,
          );
          expect(_manifest(reopenedTwice), before);

          // Byte-equality is explicitly NOT a criterion.
          expect(
            secondBytes,
            isNot(orderedEquals(firstBytes)),
            reason:
                'salts/IVs are expected to differ; parity must stay semantic',
          );

          // Wrong credentials must still fail after the round-trip.
          await expectLater(
            KdbxFormat().read(
              secondBytes,
              Credentials.composite(
                ProtectedValue.fromString('wrong-$_spikePassword'),
                keyFileBytes,
              ),
            ),
            throwsA(anything),
          );
        });
      }
    }

    // -----------------------------------------------------------------------
    // T003 — Adapter mutation spike.
    //
    // Works on the opened object graph. Imports one-sided group, entry,
    // custom field and attachment, and applies one real field conflict
    // choice, while unrelated semantics stay byte-for-byte identical in the
    // canonical manifest.
    // -----------------------------------------------------------------------
    test('T003 imports one-sided data and applies one conflict choice '
        'without touching unrelated semantics', () async {
      final credentials = _passwordOnlyCredentials();
      final local = _buildFixture(
        version: _SpikeVersion.v4,
        credentials: credentials,
      );
      final remote = _buildFixture(
        version: _SpikeVersion.v4,
        credentials: credentials,
      );

      // Give the two sides a shared lineage, as a real pair of replicas has.
      remote.body.rootGroup.forceSetUuid(local.body.rootGroup.uuid);

      // --- build the remote-only data the adapter must import -------------
      final remoteOnlyGroup = remote.createGroup(
        parent: remote.body.rootGroup,
        name: 'Remote Only Group',
      );
      final remoteOnlyEntry = KdbxEntry.create(remote, remoteOnlyGroup);
      remoteOnlyGroup.addEntry(remoteOnlyEntry);
      remoteOnlyEntry.setString(
        KdbxKeyCommon.TITLE,
        PlainValue('Remote Only Entry'),
      );
      remoteOnlyEntry.createBinary(
        isProtected: true,
        name: 'remote-only.bin',
        bytes: Uint8List.fromList([9, 8, 7]),
      );

      // Remote-only custom field + attachment inside an entry that exists on
      // BOTH sides (same entry UUID) — spec FR-4 union case.
      final remoteRich = _entryByUuid(remote, _fixtureRichEntryUuid);
      remoteRich.setString(
        KdbxKey(_remoteOnlyCustomKey),
        ProtectedValue.fromString('remote-only-value'),
      );
      remoteRich.createBinary(
        isProtected: false,
        name: _remoteOnlyAttachmentName,
        bytes: Uint8List.fromList([42, 42]),
      );

      // A real field conflict: same key, different value on each side.
      final localConflict = _entryByUuid(local, _fixtureConflictEntryUuid);
      final remoteConflict = _entryByUuid(remote, _fixtureConflictEntryUuid);
      remoteConflict.setString(
        KdbxKeyCommon.URL,
        PlainValue('https://remote.example.invalid'),
      );
      expect(
        localConflict.getString(KdbxKeyCommon.URL)!.getText(),
        isNot(remoteConflict.getString(KdbxKeyCommon.URL)!.getText()),
      );

      // Snapshot the parts of the LOCAL manifest that must not move.
      final untouchedBefore = _manifestExcluding(
        local,
        entryUuids: {_fixtureRichEntryUuid, _fixtureConflictEntryUuid},
        // The import below adds a child group to the root, which re-stamps the
        // root's own lastModificationTime. Symmetric with the `after` call.
        remodifiedGroupUuids: {local.body.rootGroup.uuid.uuid},
      );

      // --- apply the adapter operations on the open object graph ----------
      // 1. import remote-only group + its entries.
      final importedGroup = local.createGroup(
        parent: local.body.rootGroup,
        name: remoteOnlyGroup.name.get()!,
      )..forceSetUuid(remoteOnlyGroup.uuid);
      for (final entry in remoteOnlyGroup.entries) {
        entry.cloneInto(importedGroup);
      }

      // 2. import remote-only custom field + attachment into the shared entry.
      final localRich = _entryByUuid(local, _fixtureRichEntryUuid);
      localRich.setString(
        KdbxKey(_remoteOnlyCustomKey),
        remoteRich.getString(KdbxKey(_remoteOnlyCustomKey)),
      );
      final remoteBinary = remoteRich.binaryEntries.firstWhere(
        (e) => e.key.key == _remoteOnlyAttachmentName,
      );
      localRich.createBinary(
        isProtected: remoteBinary.value.isProtected,
        name: remoteBinary.key.key,
        bytes: remoteBinary.value.value,
      );

      // 3. resolve the single real conflict by choosing the remote value.
      localConflict.setString(
        KdbxKeyCommon.URL,
        remoteConflict.getString(KdbxKeyCommon.URL),
      );

      // --- serialize, reopen with the ORIGINAL credentials, verify --------
      final candidate = await KdbxFormat().read(
        await local.save(),
        credentials,
      );

      final untouchedAfter = _manifestExcluding(
        candidate,
        entryUuids: {_fixtureRichEntryUuid, _fixtureConflictEntryUuid},
        excludeGroupUuids: {importedGroup.uuid.uuid},
        remodifiedGroupUuids: {candidate.body.rootGroup.uuid.uuid},
      );
      expect(
        untouchedAfter,
        untouchedBefore,
        reason: 'unrelated supported semantics must be untouched by a merge',
      );

      final entries = _manifest(candidate)['entries']! as Map<String, Object?>;

      // one-sided group + entry survived with their original UUIDs.
      expect(entries.keys, contains(remoteOnlyEntry.uuid.uuid));
      expect(
        _groupByUuid(candidate, remoteOnlyGroup.uuid).name.get(),
        'Remote Only Group',
      );

      // one-sided custom field + attachment landed in the shared entry, and
      // the local-only ones were NOT dropped.
      final rich = entries[_fixtureRichEntryUuid]! as Map<String, Object?>;
      final richStrings = rich['strings']! as Map<String, Object?>;
      final richBinaries = rich['binaries']! as Map<String, Object?>;
      expect(richStrings.keys, contains(_remoteOnlyCustomKey));
      expect(richStrings.keys, contains(_fixtureProtectedCustomKey));
      expect(richStrings.keys, contains(_fixturePlainCustomKey));
      expect(
        (richStrings[_remoteOnlyCustomKey]! as Map)['protected'],
        isTrue,
        reason: 'protection flag must survive import',
      );
      expect(richBinaries.keys, contains(_remoteOnlyAttachmentName));
      expect(richBinaries.keys, contains(_fixtureProtectedAttachmentName));
      expect(richBinaries.keys, contains(_fixturePlainAttachmentName));

      // the chosen conflict value won, with exact bytes.
      final conflict =
          entries[_fixtureConflictEntryUuid]! as Map<String, Object?>;
      final conflictStrings = conflict['strings']! as Map<String, Object?>;
      expect(
        (conflictStrings[KdbxKeyCommon.KEY_URL]! as Map)['value'],
        'https://remote.example.invalid',
      );
    });

    // -----------------------------------------------------------------------
    // T004 — Tombstone / lineage spike.
    // -----------------------------------------------------------------------
    test(
      'T004 inspects and re-emits deletion evidence without KdbxFile.merge',
      () async {
        final credentials = _passwordOnlyCredentials();
        final file = _buildFixture(
          version: _SpikeVersion.v4,
          credentials: credentials,
        );

        // Inspect: the fixture permanently deleted one entry, so a tombstone
        // must be readable and must NOT correspond to any live object.
        final tombstones = file.body.deletedObjects;
        expect(tombstones, hasLength(1));
        final tombstoned = tombstones.single.uuid;
        expect(tombstones.single.deletionTime.get(), isNotNull);
        final liveUuids = file.body.rootGroup
            .getAllGroupsAndEntries()
            .map((o) => o.uuid)
            .toSet();
        expect(liveUuids, isNot(contains(tombstoned)));

        // Recycle-bin move and permanent tombstone stay distinct: the
        // recycle-binned entry is still live, just re-parented.
        final recycleBinUuid = file.body.meta.recycleBinUUID.get();
        expect(recycleBinUuid, isNotNull);
        final binned = _entryByUuid(file, _fixtureRecycledEntryUuid);
        expect(binned.parent!.uuid, recycleBinUuid);
        expect(liveUuids, contains(binned.uuid));

        // Re-emit: a tombstone can be authored by the adapter itself.
        final reEmitted = KdbxUuid.random();
        file.ctx.addDeletedObject(reEmitted);
        expect(
          file.body.deletedObjects.map((o) => o.uuid),
          contains(reEmitted),
        );

        // Both the inspected and the re-emitted tombstone survive a round-trip.
        final reopened = await KdbxFormat().read(
          await file.save(),
          credentials,
        );
        final reopenedTombstones = reopened.body.deletedObjects
            .map((o) => o.uuid)
            .toSet();
        expect(reopenedTombstones, contains(tombstoned));
        expect(reopenedTombstones, contains(reEmitted));

        // Neutralizing a tombstone (spec FR-5 "Keep") is possible too.
        reopened.body.deletedObjects.removeWhere((o) => o.uuid == reEmitted);
        final afterKeep = await KdbxFormat().read(
          await reopened.save(),
          credentials,
        );
        expect(
          afterKeep.body.deletedObjects.map((o) => o.uuid),
          isNot(contains(reEmitted)),
        );
        expect(
          afterKeep.body.deletedObjects.map((o) => o.uuid),
          contains(tombstoned),
        );
      },
    );

    test('T004 forbidden KdbxFile.merge is never called', () {
      // Acceptance criterion 3. Static evidence, checked over production
      // sources AND over this spike itself.
      final offenders = <String>[];
      for (final dir in const [
        'lib/features/password_manager',
        'lib/core',
        'test/features/password_manager',
      ]) {
        for (final file
            in Directory(dir)
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.dart'))) {
          final source = file.readAsStringSync();
          // The receiver token must contain `kdbx`. A bare `merge\s*\(` also
          // matches `mergeEntries` (an unrelated `VaultKdbxService` API) and
          // every other `merge` in the tree: too wide to be evidence.
          if (RegExp(
            r'(?<![A-Za-z0-9_])[A-Za-z0-9_]*[Kk]dbx[A-Za-z0-9_]*\.merge\s*\(',
          ).hasMatch(source)) {
            offenders.add(file.path);
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'KdbxFile.merge is unfinished upstream and forbidden by spec',
      );
    });

    test('T004 root group UUID lineage is compared before diff', () async {
      final credentials = _passwordOnlyCredentials();
      final local = _buildFixture(
        version: _SpikeVersion.v4,
        credentials: credentials,
      );
      final foreign = _buildFixture(
        version: _SpikeVersion.v4,
        credentials: credentials,
      );

      // Two independently created databases never share a root UUID, so
      // "same Drive file id" is provably not sufficient evidence of lineage.
      expect(local.body.rootGroup.uuid, isNot(foreign.body.rootGroup.uuid));
      expect(
        _lineageMatches(local, foreign),
        isFalse,
        reason: 'wrongLineage must be detectable before any session/write',
      );

      final replica = await KdbxFormat().read(await local.save(), credentials);
      expect(_lineageMatches(local, replica), isTrue);
    });

    group('T004 pre-diff UUID validation rejects', () {
      late Credentials credentials;
      late KdbxFile file;

      setUp(() {
        credentials = _passwordOnlyCredentials();
        file = _buildFixture(
          version: _SpikeVersion.v4,
          credentials: credentials,
        );
        expect(_validateSide(file), isNull, reason: 'fixture must start valid');
      });

      test('duplicate entry UUID', () {
        final entries = file.body.rootGroup.getAllEntries();
        entries.last.forceSetUuid(entries.first.uuid);
        expect(_validateSide(file), _UuidViolation.duplicateEntry);
      });

      test('duplicate group UUID', () {
        final groups = file.body.rootGroup.getAllGroups();
        expect(groups.length, greaterThan(1));
        groups.last.forceSetUuid(groups.first.uuid);
        expect(_validateSide(file), _UuidViolation.duplicateGroup);
      });

      test('group-entry UUID collision', () {
        final group = file.body.rootGroup.getAllGroups().first;
        file.body.rootGroup.getAllEntries().first.forceSetUuid(group.uuid);
        expect(_validateSide(file), _UuidViolation.groupEntryCollision);
      });

      test('nil live UUID', () {
        file.body.rootGroup.getAllEntries().first.forceSetUuid(KdbxUuid.NIL);
        expect(_validateSide(file), _UuidViolation.nilUuid);
      });

      test('cross-side object kind mismatch', () {
        final other = _buildFixture(
          version: _SpikeVersion.v4,
          credentials: credentials,
        );
        other.body.rootGroup.forceSetUuid(file.body.rootGroup.uuid);

        // A UUID that exists on neither side yet, so each side stays
        // internally valid and only the CROSS-side comparison can fail.
        final sharedUuid = KdbxUuid.random();
        final localEntry = KdbxEntry.create(file, file.body.rootGroup)
          ..forceSetUuid(sharedUuid);
        file.body.rootGroup.addEntry(localEntry);
        other
            .createGroup(parent: other.body.rootGroup, name: 'Same Uuid Group')
            .forceSetUuid(sharedUuid);

        expect(_validateSide(file), isNull);
        expect(_validateSide(other), isNull);
        expect(
          _crossSideKindMismatch(file, other),
          isTrue,
          reason: 'kind mismatch is only visible when both sides are compared',
        );
      });
    });

    // -----------------------------------------------------------------------
    // T004 — header-version detector. Step 5 of the pre-diff validator claims
    // the library itself refuses an out-of-range major version. That claim is
    // only evidence once it is exercised, so it is exercised here.
    // -----------------------------------------------------------------------
    test('T004 unsupported KDBX major version is rejected by the library', () {
      const majorVersionOffset = 10;

      Future<void> readWithMajor(int major) async {
        final credentials = _passwordOnlyCredentials();
        final saved = await _buildFixture(
          version: _SpikeVersion.v4,
          credentials: credentials,
        ).save();
        final bytes = Uint8List.fromList(saved);
        ByteData.sublistView(bytes)
            .setUint16(majorVersionOffset, major, Endian.little);
        await KdbxFormat().read(bytes, credentials);
      }

      // 5.x and beyond: the library refuses before anything is decrypted.
      for (final major in const [5, 9]) {
        expect(
          readWithMajor(major),
          throwsA(isA<KdbxUnsupportedException>()),
          reason: 'major $major must not be accepted',
        );
      }

      // Below 3.x the failure is NOT a KdbxUnsupportedException: the header
      // parser fails earlier with a RangeError. Recorded verbatim so the
      // adapter does not assume a single exception type for "unsupported".
      expect(readWithMajor(2), throwsA(isA<RangeError>()));
    });
  });

  group('loadEntryHistory (spec 017 T103)', () {
    Future<String> createEntry({String entryPassword = 'p0'}) async {
      final groupId = await _rootGroupId(service, databasePath, password);
      return service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: groupId,
        title: 'Mail 0',
        username: 'ada',
        entryPassword: entryPassword,
        url: 'https://mail.example',
        notes: 'notes 0',
      );
    }

    Future<void> editEntry(String entryId, int revision) {
      return service.updateEntry(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        title: 'Mail $revision',
        username: 'ada',
        entryPassword: 'p$revision',
        url: 'https://mail.example',
        notes: 'notes $revision',
      );
    }

    test('three edits produce three revisions, newest first', () async {
      final entryId = await createEntry();
      for (var revision = 1; revision <= 3; revision++) {
        await editEntry(entryId, revision);
      }

      // FR-015: reading the history is a read. Asserted on the bytes rather
      // than by inspection, so a future write on this path fails here.
      final digestBefore = sha256.convert(
        await File(databasePath).readAsBytes(),
      );

      final history = await service.loadEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      );

      expect(
        sha256.convert(await File(databasePath).readAsBytes()),
        digestBefore,
        reason: 'loadEntryHistory must not rewrite the vault',
      );

      expect(history.revisions, hasLength(3));
      expect(history.revisions.map((revision) => revision.password), [
        'p2',
        'p1',
        'p0',
      ]);
      expect(history.revisions.map((revision) => revision.title), [
        'Mail 2',
        'Mail 1',
        'Mail 0',
      ]);
      expect(history.revisions.map((revision) => revision.notes), [
        'notes 2',
        'notes 1',
        'notes 0',
      ]);
      expect(
        history.revisions.every((revision) => revision.entryId == entryId),
        isTrue,
      );
      expect(
        history.revisions.every((revision) => revision.replacedAt.isUtc),
        isTrue,
      );
    });

    // FR-001: `KdbxEntry.merge` (kdbx 2.4.2 `kdbx_entry.dart`) appends the
    // other side's revisions to `history` without reordering them, so after a
    // two-device sync the stored order is not chronological. Reproduced here
    // by rewriting the stored timestamps out of file order.
    test(
      'revisions are ordered by timestamp, not by position in the file',
      () async {
        final entryId = await createEntry();
        for (var revision = 1; revision <= 3; revision++) {
          await editEntry(entryId, revision);
        }

        final credentials = Credentials(ProtectedValue.fromString(password));
        final file = await KdbxFormat().read(
          await File(databasePath).readAsBytes(),
          credentials,
        );
        final entry = file.body.rootGroup.getAllEntries().firstWhere(
          (candidate) => candidate.uuid.uuid == entryId,
        );
        expect(entry.history, hasLength(3));
        // File order stays p0, p1, p2; the timestamps say p0 is the newest and
        // p1/p2 share a second (KDBX stores whole seconds).
        final base = DateTime.utc(2026, 3, 1, 12);
        entry.history[0].times.lastModificationTime.set(
          base.add(const Duration(seconds: 30)),
        );
        entry.history[1].times.lastModificationTime.set(
          base.add(const Duration(seconds: 20)),
        );
        entry.history[2].times.lastModificationTime.set(
          base.add(const Duration(seconds: 20)),
        );
        await File(databasePath).writeAsBytes(await file.save());

        final history = await service.loadEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
        );

        final times = history.revisions
            .map((revision) => revision.replacedAt)
            .toList();
        for (var i = 1; i < times.length; i++) {
          expect(
            times[i].isAfter(times[i - 1]),
            isFalse,
            reason: 'revisions must be newest first: $times',
          );
        }
        // The tie between the two revisions of the same second resolves to
        // reversed file order, deterministically — `List.sort` is not stable.
        expect(history.revisions.map((revision) => revision.password), [
          'p0',
          'p2',
          'p1',
        ]);
      },
    );

    test('an untouched entry returns an empty list, not an error', () async {
      final entryId = await createEntry();

      final history = await service.loadEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      );

      expect(history.revisions, isEmpty);
      expect(history.retention, isNotNull);
    });

    test('retention matches meta.historyMaxItems / historyMaxSize', () async {
      final entryId = await createEntry();

      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        Credentials(ProtectedValue.fromString(password)),
      );
      final expectedMaxItems = file.body.meta.historyMaxItems.get();
      final expectedMaxSize = file.body.meta.historyMaxSize.get();

      final history = await service.loadEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      );

      expect(history.retention.maxItems, expectedMaxItems);
      expect(history.retention.maxSizeBytes, expectedMaxSize);
      expect(expectedMaxItems, isNotNull);
      expect(expectedMaxSize, isNotNull);
    });

    test(
      'a revision carries custom fields, otp and attachment names',
      () async {
        final groupId = await _rootGroupId(service, databasePath, password);
        final entryId = await service.createEntry(
          databasePath: databasePath,
          password: password,
          groupId: groupId,
          title: 'Mail',
          username: 'ada',
          entryPassword: 'p0',
          url: 'https://mail.example',
          notes: 'notes',
          customFields: const [
            VaultCustomField(key: 'otp', value: 'otpauth://totp/Mail?secret=A'),
          ],
        );
        final attachment = File('${tempDir.path}/key.pem');
        await attachment.writeAsBytes(const [1, 2, 3]);
        await service.addAttachment(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          filePath: attachment.path,
        );
        await service.updateEntry(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          title: 'Mail',
          username: 'ada',
          entryPassword: 'p1',
          url: 'https://mail.example',
          notes: 'notes',
        );

        final history = await service.loadEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
        );

        final newest = history.revisions.first;
        expect(newest.otpUri, 'otpauth://totp/Mail?secret=A');
        expect(newest.customFields.map((field) => field.key), contains('otp'));
        expect(newest.attachmentNames, ['key.pem']);
      },
    );

    // The editor stages attachment changes and saves them with the fields.
    group('updateEntry with attachment changes', () {
      Future<List<String>> attachmentNames(String entryId) async {
        final snapshot = await service.loadVault(
          databasePath: databasePath,
          password: password,
        );
        return snapshot.allEntries
            .firstWhere((entry) => entry.id == entryId)
            .attachments
            .map((attachment) => attachment.key)
            .toList();
      }

      Future<String> attachmentFile(String name) async {
        final file = File('${tempDir.path}/$name');
        await file.writeAsBytes(const [1, 2, 3]);
        return file.path;
      }

      Future<void> update(
        String entryId, {
        List<String> added = const [],
        List<String> removed = const [],
      }) {
        return service.updateEntry(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          title: 'Mail',
          username: 'ada',
          entryPassword: 'p1',
          url: 'https://mail.example',
          notes: 'edited',
          addedAttachmentPaths: added,
          removedAttachmentKeys: removed,
        );
      }

      Future<int> revisionCount(String entryId) async {
        final history = await service.loadEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
        );
        return history.revisions.length;
      }

      test('removals and adds land in one history revision', () async {
        final entryId = await createEntry();
        await update(entryId, added: [await attachmentFile('old.pem')]);
        final before = await revisionCount(entryId);

        await update(
          entryId,
          added: [await attachmentFile('a.txt'), await attachmentFile('b.txt')],
          removed: ['old.pem'],
        );

        expect(await attachmentNames(entryId), ['a.txt', 'b.txt']);
        expect(await revisionCount(entryId), before + 1);
      });

      test('a key that is already gone does not block the rest', () async {
        final entryId = await createEntry();

        await update(
          entryId,
          added: [await attachmentFile('a.txt')],
          removed: ['gone.txt'],
        );

        expect(await attachmentNames(entryId), ['a.txt']);
      });

      test(
        'an unreadable source fails the update and writes nothing',
        () async {
          final entryId = await createEntry();
          await update(entryId, added: [await attachmentFile('keep.pem')]);
          final before = await File(databasePath).readAsBytes();

          await expectLater(
            update(
              entryId,
              added: ['${tempDir.path}/missing.txt'],
              removed: ['keep.pem'],
            ),
            throwsA(anything),
          );

          expect(await File(databasePath).readAsBytes(), before);
          expect(await attachmentNames(entryId), ['keep.pem']);
        },
      );
    });

    test('an unknown entry throws', () async {
      await createEntry();

      await expectLater(
        service.loadEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: 'not-an-entry',
        ),
        throwsA(anything),
      );
    });
  });

  group('restoreEntryRevision (spec 017 T301)', () {
    Future<String> createEntry({
      List<VaultCustomField> customFields = const [],
    }) async {
      final groupId = await _rootGroupId(service, databasePath, password);
      return service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: groupId,
        title: 'Mail 0',
        username: 'ada',
        entryPassword: 'p0',
        url: 'https://mail.example',
        notes: 'notes 0',
        customFields: customFields,
      );
    }

    Future<void> editEntry(String entryId, int revision) {
      return service.updateEntry(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        title: 'Mail $revision',
        username: 'ada',
        entryPassword: 'p$revision',
        url: 'https://mail.example',
        notes: 'notes $revision',
      );
    }

    Future<VaultEntryHistory> history(String entryId) =>
        service.loadEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
        );

    Future<VaultEntry> current(String entryId) async =>
        (await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        )).firstWhere((entry) => entry.id == entryId);

    // FR-007: reversibility is a property of the KDBX writer, asserted here
    // rather than assumed — the pre-restore state must land in history.
    test(
      'restores the fields and keeps the pre-restore state in history',
      () async {
        final entryId = await createEntry();
        await editEntry(entryId, 1);
        await editEntry(entryId, 2);
        final oldest = (await history(entryId)).revisions.last;
        expect(oldest.password, 'p0');

        await service.restoreEntryRevision(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          replacedAt: oldest.replacedAt,
          ordinal: oldest.ordinal,
        );

        final entry = await current(entryId);
        expect(entry.title, 'Mail 0');
        expect(entry.password, 'p0');
        expect(entry.notes, 'notes 0');
        final after = await history(entryId);
        expect(after.revisions, hasLength(3));
        expect(after.revisions.first.password, 'p2');
      },
    );

    test('restores the OTP carried in the custom fields', () async {
      final entryId = await createEntry(
        customFields: const [
          VaultCustomField(key: 'otp', value: 'otpauth://totp/Mail?secret=A'),
        ],
      );
      await editEntry(entryId, 1); // updateEntry with no custom fields drops it
      expect((await current(entryId)).otpUri, isNull);
      final revision = (await history(entryId)).revisions.single;

      await service.restoreEntryRevision(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        replacedAt: revision.replacedAt,
      );

      expect((await current(entryId)).otpUri, 'otpauth://totp/Mail?secret=A');
    });

    // FR-006a: attachments are outside the restore.
    test('leaves attachments unchanged', () async {
      final entryId = await createEntry();
      await editEntry(entryId, 1);
      final attachment = File('${tempDir.path}/key.pem');
      await attachment.writeAsBytes(const [1, 2, 3]);
      await service.addAttachment(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        filePath: attachment.path,
      );
      final revision = (await history(entryId)).revisions.last;
      expect(revision.attachmentNames, isEmpty);

      await service.restoreEntryRevision(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        replacedAt: revision.replacedAt,
        ordinal: revision.ordinal,
      );

      final entry = await current(entryId);
      expect(entry.password, 'p0');
      expect(entry.attachments.map((a) => a.name), ['key.pem']);
    });

    // Two revisions in the same second: the list tells them apart by
    // `ordinal`, and restore must act on the one the list showed — not on
    // whichever the file happens to hold first.
    test('a same-second sibling is restored by its ordinal', () async {
      final entryId = await createEntry();
      await editEntry(entryId, 1);
      await editEntry(entryId, 2);
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        Credentials(ProtectedValue.fromString(password)),
      );
      final entry = file.body.rootGroup.getAllEntries().single;
      final sameSecond = DateTime.utc(2026, 3, 1, 12);
      for (final revision in entry.history) {
        revision.times.lastModificationTime.set(sameSecond);
      }
      await File(databasePath).writeAsBytes(await file.save());

      final revisions = (await history(entryId)).revisions;
      expect(revisions.map((r) => r.ordinal), [0, 1]);
      expect(revisions.map((r) => r.password), ['p1', 'p0']);

      await service.restoreEntryRevision(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        replacedAt: revisions[1].replacedAt,
        ordinal: revisions[1].ordinal,
      );

      expect((await current(entryId)).password, 'p0');
    });

    test('an unknown timestamp throws and writes nothing', () async {
      final entryId = await createEntry();
      await editEntry(entryId, 1);
      final before = await File(databasePath).readAsBytes();

      await expectLater(
        service.restoreEntryRevision(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          replacedAt: DateTime.utc(1999),
        ),
        throwsStateError,
      );

      expect(await File(databasePath).readAsBytes(), before);
      expect((await current(entryId)).password, 'p1');
    });

    // FR-011: the write goes through the protected writer.
    test('a writer failure leaves the file untouched', () async {
      final entryId = await createEntry();
      await editEntry(entryId, 1);
      final revision = (await history(entryId)).revisions.single;
      final before = await File(databasePath).readAsBytes();

      await expectLater(
        VaultKdbxService(safeWriter: _FailingSafeVaultFileWriter())
            .restoreEntryRevision(
              databasePath: databasePath,
              password: password,
              entryId: entryId,
              replacedAt: revision.replacedAt,
            ),
        throwsException,
      );

      expect(await File(databasePath).readAsBytes(), before);
    });
  });

  group('deleteEntryRevision / clearEntryHistory (spec 017 T401)', () {
    Future<String> createEntry() async {
      final groupId = await _rootGroupId(service, databasePath, password);
      return service.createEntry(
        databasePath: databasePath,
        password: password,
        groupId: groupId,
        title: 'Mail 0',
        username: 'ada',
        entryPassword: 'p0',
        url: 'https://mail.example',
        notes: 'notes 0',
      );
    }

    Future<void> editEntry(String entryId, int revision) {
      return service.updateEntry(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        title: 'Mail $revision',
        username: 'ada',
        entryPassword: 'p$revision',
        url: 'https://mail.example',
        notes: 'notes $revision',
      );
    }

    /// A fresh service, so the read is a reopen of the file and not a view
    /// on anything cached.
    Future<List<String>> passwordsInHistory(String entryId) async =>
        (await VaultKdbxService().loadEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
        )).revisions.map((revision) => revision.password).toList();

    /// Three edits, so the history reads p2, p1, p0 (newest first).
    Future<String> entryWithThreeRevisions() async {
      final entryId = await createEntry();
      for (var revision = 1; revision <= 3; revision++) {
        await editEntry(entryId, revision);
      }
      // Distinct seconds, so each revision has its own timestamp.
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        Credentials(ProtectedValue.fromString(password)),
      );
      final entry = file.body.rootGroup.getAllEntries().single;
      final base = DateTime.utc(2026, 3, 1, 12);
      for (final (index, revision) in entry.history.indexed) {
        revision.times.lastModificationTime.set(
          base.add(Duration(minutes: index)),
        );
      }
      await File(databasePath).writeAsBytes(await file.save());
      return entryId;
    }

    // FR-009: exactly the named one goes; the outer two keep their order.
    test(
      'deleting the middle of three leaves the outer two in order',
      () async {
        final entryId = await entryWithThreeRevisions();
        final middle = (await passwordsInHistory(entryId));
        expect(middle, ['p2', 'p1', 'p0']);
        final revisions = (await service.loadEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
        )).revisions;

        await service.deleteEntryRevision(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          replacedAt: revisions[1].replacedAt,
        );

        expect(await passwordsInHistory(entryId), ['p2', 'p0']);
      },
    );

    test('a same-second sibling is deleted by its ordinal', () async {
      final entryId = await createEntry();
      await editEntry(entryId, 1);
      await editEntry(entryId, 2);
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        Credentials(ProtectedValue.fromString(password)),
      );
      final entry = file.body.rootGroup.getAllEntries().single;
      final sameSecond = DateTime.utc(2026, 3, 1, 12);
      for (final revision in entry.history) {
        revision.times.lastModificationTime.set(sameSecond);
      }
      await File(databasePath).writeAsBytes(await file.save());
      final revisions = (await service.loadEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      )).revisions;
      expect(revisions.map((r) => r.password), ['p1', 'p0']);

      await service.deleteEntryRevision(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        replacedAt: revisions[1].replacedAt,
        ordinal: revisions[1].ordinal,
      );

      expect(await passwordsInHistory(entryId), ['p1']);
    });

    test('an unknown timestamp throws and writes nothing', () async {
      final entryId = await entryWithThreeRevisions();
      final before = await File(databasePath).readAsBytes();

      await expectLater(
        service.deleteEntryRevision(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          replacedAt: DateTime.utc(1999),
        ),
        throwsStateError,
      );

      expect(await File(databasePath).readAsBytes(), before);
    });

    // FR-010: the list is emptied and stays empty across a reopen.
    test('clearing leaves an empty list', () async {
      final entryId = await entryWithThreeRevisions();

      await service.clearEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      );

      expect(await passwordsInHistory(entryId), isEmpty);
      // The entry itself is untouched.
      final entry = (await service.loadAllEntries(
        databasePath: databasePath,
        password: password,
      )).single;
      expect(entry.password, 'p3');
      expect(entry.title, 'Mail 3');
    });

    // FR-014: neither operation changes what the writer records afterwards.
    test('an ordinary edit after a delete or clear records exactly one '
        'revision', () async {
      final entryId = await entryWithThreeRevisions();
      final revisions = (await service.loadEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      )).revisions;
      await service.deleteEntryRevision(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
        replacedAt: revisions[0].replacedAt,
      );
      expect(await passwordsInHistory(entryId), hasLength(2));

      await editEntry(entryId, 4);
      expect(await passwordsInHistory(entryId), hasLength(3));

      await service.clearEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      );
      expect(await passwordsInHistory(entryId), isEmpty);

      await editEntry(entryId, 5);
      expect(await passwordsInHistory(entryId), ['p4']);
    });

    // FR-011: both writes go through the protected writer.
    test('a writer failure leaves the file untouched', () async {
      final entryId = await entryWithThreeRevisions();
      final revisions = (await service.loadEntryHistory(
        databasePath: databasePath,
        password: password,
        entryId: entryId,
      )).revisions;
      final before = await File(databasePath).readAsBytes();
      final failing = VaultKdbxService(
        safeWriter: _FailingSafeVaultFileWriter(),
      );

      await expectLater(
        failing.deleteEntryRevision(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
          replacedAt: revisions[0].replacedAt,
        ),
        throwsException,
      );
      await expectLater(
        failing.clearEntryHistory(
          databasePath: databasePath,
          password: password,
          entryId: entryId,
        ),
        throwsException,
      );

      expect(await File(databasePath).readAsBytes(), before);
      expect(await passwordsInHistory(entryId), ['p2', 'p1', 'p0']);
    });
  });

  group('spec 023 T207 — merging an entry that holds a passkey', () {
    const passkeyStrings = {
      'KPEX_PASSKEY_RELYING_PARTY': ('webauthn.io', false),
      'KPEX_PASSKEY_CREDENTIAL_ID': ('AQID', true),
      'KPEX_PASSKEY_USER_HANDLE': ('BAUG', true),
      'KPEX_PASSKEY_USERNAME': ('alice', false),
      'KPEX_PASSKEY_PRIVATE_KEY_PEM': (es256PrivateKeyPem, true),
      'KPEX_PASSKEY_FLAG_BE': ('1', false),
      'KPEX_PASSKEY_FLAG_BS': ('1', false),
      // Not understood by the parser: must travel with its credential.
      'KPEX_PASSKEY_PRF': ('opaque', true),
    };

    /// Writes two entries with the raw library, as KeePassXC would: one plain
    /// password entry and one passkey entry. [handle] is the base64url user
    /// handle of the passkey, so two passkeys can be given the same account or
    /// different ones.
    Future<(String passwordEntryId, String passkeyEntryId)> seed({
      String handle = 'BAUG',
      bool passkeyEntryAlsoHasPasskeyOnPrimary = false,
      String primaryHandle = 'BAUG',
    }) async {
      final credentials = Credentials(ProtectedValue.fromString(password));
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        credentials,
      );
      final root = file.body.rootGroup;

      final passwordEntry = KdbxEntry.create(file, root)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('webauthn.io'))
        ..setString(KdbxKeyCommon.USER_NAME, PlainValue('alice'))
        ..setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('secret-pw'),
        )
        ..setString(KdbxKeyCommon.URL, PlainValue('https://webauthn.io'));
      if (passkeyEntryAlsoHasPasskeyOnPrimary) {
        for (final MapEntry(:key, value: (text, protected))
            in passkeyStrings.entries) {
          final value = key == 'KPEX_PASSKEY_USER_HANDLE'
              ? primaryHandle
              : text;
          passwordEntry.setString(
            KdbxKey(key),
            protected ? ProtectedValue.fromString(value) : PlainValue(value),
          );
        }
      }
      root.addEntry(passwordEntry);

      final passkeyEntry = KdbxEntry.create(file, root)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('webauthn.io passkey'))
        ..setString(KdbxKeyCommon.USER_NAME, PlainValue('alice'))
        ..setString(KdbxKeyCommon.URL, PlainValue('https://webauthn.io'));
      for (final MapEntry(:key, value: (text, protected))
          in passkeyStrings.entries) {
        final value = key == 'KPEX_PASSKEY_USER_HANDLE' ? handle : text;
        passkeyEntry.setString(
          KdbxKey(key),
          protected ? ProtectedValue.fromString(value) : PlainValue(value),
        );
      }
      root.addEntry(passkeyEntry);

      await File(databasePath).writeAsBytes(await file.save(), flush: true);
      return (passwordEntry.uuid.uuid, passkeyEntry.uuid.uuid);
    }

    Future<Map<String, (String, bool)>> passkeyStringsOf(String entryId) async {
      final file = await KdbxFormat().read(
        await File(databasePath).readAsBytes(),
        Credentials(ProtectedValue.fromString(password)),
      );
      final entry = file.body.rootGroup.getAllEntries().firstWhere(
        (candidate) => candidate.uuid.uuid == entryId,
      );
      return {
        for (final s in entry.stringEntries)
          if (s.key.key.startsWith('KPEX_PASSKEY_'))
            s.key.key: (s.value?.getText() ?? '', s.value is ProtectedValue),
      };
    }

    test(
      'the passkey moves onto the kept entry with protection intact',
      () async {
        final (passwordEntryId, passkeyEntryId) = await seed();

        await service.mergeEntries(
          databasePath: databasePath,
          password: password,
          primaryId: passwordEntryId,
          secondaryIds: [passkeyEntryId],
        );

        final merged = passkeyStringsOf(passwordEntryId);
        expect(await merged, passkeyStrings);

        final entries = await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        );
        final kept = entries.firstWhere((e) => e.id == passwordEntryId);
        expect(kept.hasPasskey, isTrue);
        expect(kept.passkeys.single.relyingPartyId, 'webauthn.io');
        expect(kept.passkeys.single.usable, isTrue);
        // FR-011a: one entry holding both.
        expect(kept.password, 'secret-pw');
        // And the passkey entry is in the bin, not among the active entries.
        expect(entries.map((e) => e.id), isNot(contains(passkeyEntryId)));
      },
    );

    test('a field of the namespace is never copied on its own', () async {
      final (passwordEntryId, passkeyEntryId) = await seed();

      await service.mergeEntries(
        databasePath: databasePath,
        password: password,
        primaryId: passwordEntryId,
        secondaryIds: [passkeyEntryId],
      );

      // One whole group, no half group and no renumbered stragglers.
      final strings = await passkeyStringsOf(passwordEntryId);
      expect(
        strings.keys.every((key) => !key.contains('_1')),
        isTrue,
        reason: 'the primary had no passkey, so the group keeps the base keys',
      );
      expect(strings, hasLength(passkeyStrings.length));
    });

    test(
      'a second passkey for another account lands in the next suffix',
      () async {
        final (passwordEntryId, passkeyEntryId) = await seed(
          handle: 'BwgJ',
          passkeyEntryAlsoHasPasskeyOnPrimary: true,
        );

        await service.mergeEntries(
          databasePath: databasePath,
          password: password,
          primaryId: passwordEntryId,
          secondaryIds: [passkeyEntryId],
        );

        final entries = await service.loadAllEntries(
          databasePath: databasePath,
          password: password,
        );
        final kept = entries.firstWhere((e) => e.id == passwordEntryId);
        expect(kept.passkeys, hasLength(2));
        expect(
          kept.passkeys.map((passkey) => passkey.fieldSuffix),
          containsAll(<String>['', '_1']),
        );
      },
    );

    test('the same account on both sides refuses the whole merge', () async {
      final (passwordEntryId, passkeyEntryId) = await seed(
        passkeyEntryAlsoHasPasskeyOnPrimary: true,
      );
      final before = await File(databasePath).readAsBytes();

      await expectLater(
        service.mergeEntries(
          databasePath: databasePath,
          password: password,
          primaryId: passwordEntryId,
          secondaryIds: [passkeyEntryId],
        ),
        throwsA(isA<PasskeyMergeConflict>()),
      );

      // Nothing written: not the notes, not the URLs, not the bin move.
      expect(await File(databasePath).readAsBytes(), before);
    });

    test('the refusal names the relying party', () async {
      final (passwordEntryId, passkeyEntryId) = await seed(
        passkeyEntryAlsoHasPasskeyOnPrimary: true,
      );

      await expectLater(
        service.mergeEntries(
          databasePath: databasePath,
          password: password,
          primaryId: passwordEntryId,
          secondaryIds: [passkeyEntryId],
        ),
        throwsA(
          isA<PasskeyMergeConflict>().having(
            (error) => error.relyingPartyId,
            'relyingPartyId',
            'webauthn.io',
          ),
        ),
      );
    });
  });
}

// =============================================================================
// spec 008 Gate 0 spike support (test-only).
// =============================================================================

const _spikePassword = 'spike-not-a-real-password';

// Stable UUIDs so assertions can address fixture objects by identity.
const _fixtureRichEntryUuid = 'AAAAAAAAAAAAAAAAAAAAAQ==';
const _fixtureConflictEntryUuid = 'AAAAAAAAAAAAAAAAAAAAAg==';
const _fixtureRecycledEntryUuid = 'AAAAAAAAAAAAAAAAAAAAAw==';
const _fixtureDeletedEntryUuid = 'AAAAAAAAAAAAAAAAAAAABA==';
const _fixtureChildGroupUuid = 'AAAAAAAAAAAAAAAAAAAABQ==';
const _fixtureMovedGroupUuid = 'AAAAAAAAAAAAAAAAAAAABg==';

// Deliberately mixed-case keys: the spec requires original key spelling to
// survive verbatim.
const _fixtureProtectedCustomKey = 'Custom_TOTP Seed';
const _fixturePlainCustomKey = 'custom_Plain Note';
const _fixtureEmptyStringKey = 'Custom_Empty';
const _fixtureProtectedAttachmentName = 'protected-payload.bin';
const _fixturePlainAttachmentName = 'plain-payload.bin';
const _fixtureEmptyAttachmentName = 'zero-byte.bin';
const _fixtureForegroundColor = '#FF0000';
const _fixtureBackgroundColor = '#00FF00';
const _fixtureAutoTypeSequence = '{USERNAME}{TAB}{PASSWORD}';
const _fixtureAutoTypeWindow = 'Firefox';
const _fixtureAutoTypeAssociationSequence = '{PASSWORD}';
const _remoteOnlyCustomKey = 'Custom_RemoteOnly';
const _remoteOnlyAttachmentName = 'remote-only-extra.bin';

enum _SpikeVersion {
  v3('KDBX 3'),
  v4('KDBX 4');

  const _SpikeVersion(this.label);
  final String label;

  KdbxHeader createHeader() =>
      this == _SpikeVersion.v3 ? KdbxHeader.createV3() : KdbxHeader.createV4();
}

enum _UuidViolation {
  duplicateEntry,
  duplicateGroup,
  groupEntryCollision,
  nilUuid,
}

Credentials _passwordOnlyCredentials() =>
    Credentials(ProtectedValue.fromString(_spikePassword));

/// Builds one database exercising every construct the installed library
/// supports, so the round-trip assertions have something to prove.
KdbxFile _buildFixture({
  required _SpikeVersion version,
  required Credentials credentials,
}) {
  final file = KdbxFormat().create(
    credentials,
    'Spike DB',
    generator: 'spec-008-spike',
    header: version.createHeader(),
  );
  final root = file.body.rootGroup;

  // --- metadata / settings -------------------------------------------------
  final meta = file.body.meta;
  meta.databaseDescription.set('spike fixture');
  meta.defaultUserName.set('spike-user');
  meta.historyMaxItems.set(11);
  meta.historyMaxSize.set(1024 * 1024);
  meta.maintenanceHistoryDays.set(42);
  meta.customData['spike.key'] = 'spike.value';
  meta.customData['spike.other'] = 'spike.other.value';

  final customIcon = KdbxCustomIcon(
    uuid: KdbxUuid.random(),
    data: Uint8List.fromList(List<int>.generate(16, (i) => i * 3)),
  );
  meta.addCustomIcon(customIcon);

  // --- hierarchy + a move --------------------------------------------------
  final child = file.createGroup(parent: root, name: 'Child Group')
    ..forceSetUuid(KdbxUuid(_fixtureChildGroupUuid))
    ..notes.set('child notes')
    ..enableAutoType.set(true)
    ..customIcon = customIcon;

  final moved = file.createGroup(parent: root, name: 'Moved Group')
    ..forceSetUuid(KdbxUuid(_fixtureMovedGroupUuid));
  // Real move: created under root, relocated under child.
  KdbxDao(file).move(moved, child);

  // --- rich entry: strings + attachments -----------------------------------
  final rich = KdbxEntry.create(file, child)
    ..forceSetUuid(KdbxUuid(_fixtureRichEntryUuid));
  child.addEntry(rich);
  rich
    ..setString(KdbxKeyCommon.TITLE, PlainValue('Rich Entry'))
    ..setString(KdbxKeyCommon.USER_NAME, PlainValue('rich-user'))
    ..setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString('rich-not-a-real-password'),
    )
    ..setString(KdbxKeyCommon.URL, PlainValue('https://rich.example.invalid'))
    ..setString(KdbxKey('Notes'), PlainValue('rich notes'))
    ..setString(
      KdbxKey(_fixtureProtectedCustomKey),
      ProtectedValue.fromString('JBSWY3DPEHPK3PXP'),
    )
    ..setString(KdbxKey(_fixturePlainCustomKey), PlainValue('plain custom'))
    // presence != value: empty string must round-trip as PRESENT.
    ..setString(KdbxKey(_fixtureEmptyStringKey), PlainValue(''))
    ..tags.set('tag-a;tag-b')
    ..overrideURL.set('cmd://spike')
    // `KdbxColor` is opaque (no RGB accessor, no `==`), but the value is not:
    // `ColorNode.set` writes the RGB code into the entry's own XML node, which
    // is public and exported. The manifest compares the value, not presence.
    ..foregroundColor.set(KdbxColor.parse(_fixtureForegroundColor))
    ..backgroundColor.set(KdbxColor.parse(_fixtureBackgroundColor));

  // Entry-level AutoType has no model in `kdbx 2.4.2`. It is authored as a raw
  // XML child so the round-trip covers the construct FR-1 requires preserved.
  rich.node.children.add(_autoTypeElement());

  rich.createBinary(
    isProtected: true,
    name: _fixtureProtectedAttachmentName,
    bytes: Uint8List.fromList(List<int>.generate(32, (i) => (i * 5) & 0xFF)),
  );
  rich.createBinary(
    isProtected: false,
    name: _fixturePlainAttachmentName,
    bytes: Uint8List.fromList(const [1, 2, 3, 4, 5]),
  );
  // presence != value: zero-byte attachment must round-trip as PRESENT.
  rich.createBinary(
    isProtected: false,
    name: _fixtureEmptyAttachmentName,
    bytes: Uint8List(0),
  );

  // --- conflict entry: gets real history via repeated modification ---------
  final conflict = KdbxEntry.create(file, root)
    ..forceSetUuid(KdbxUuid(_fixtureConflictEntryUuid));
  root.addEntry(conflict);
  conflict
    ..setString(KdbxKeyCommon.TITLE, PlainValue('Conflict Entry'))
    ..setString(KdbxKeyCommon.URL, PlainValue('https://v1.example.invalid'));
  // Gate 0 finding: `setString` does NOT push history automatically while the
  // entry is still dirty from creation, so history has to be authored the same
  // way the library authors it internally — via `cloneInto(toHistoryEntry:)`.
  conflict.history.add(conflict.cloneInto(root, toHistoryEntry: true));
  conflict.setString(
    KdbxKeyCommon.URL,
    PlainValue('https://v2.example.invalid'),
  );
  conflict.history.add(conflict.cloneInto(root, toHistoryEntry: true));
  conflict.setString(
    KdbxKeyCommon.URL,
    PlainValue('https://local.example.invalid'),
  );

  // --- recycle bin: live object, just re-parented --------------------------
  final recycled = KdbxEntry.create(file, root)
    ..forceSetUuid(KdbxUuid(_fixtureRecycledEntryUuid));
  root.addEntry(recycled);
  recycled.setString(KdbxKeyCommon.TITLE, PlainValue('Recycled Entry'));
  KdbxDao(file).deleteEntry(recycled);

  // --- permanent deletion: produces a DeletedObjects tombstone -------------
  final doomed = KdbxEntry.create(file, root)
    ..forceSetUuid(KdbxUuid(_fixtureDeletedEntryUuid));
  root.addEntry(doomed);
  doomed.setString(KdbxKeyCommon.TITLE, PlainValue('Doomed Entry'));
  KdbxDao(file).deletePermanently(doomed);

  return file;
}

/// Canonical semantic manifest.
///
/// Deliberately excludes everything that legitimately differs between two
/// serializations of the same logical database: KDF salt, master seed,
/// encryption IV, ciphertext and `HeaderHash`. Comparing these would make the
/// spike assert byte-equality, which the spec forbids.
Map<String, Object?> _manifest(KdbxFile file) {
  final groups = <String, Object?>{};
  final entries = <String, Object?>{};

  for (final object in file.body.rootGroup.getAllGroupsAndEntries()) {
    if (object is KdbxGroup) {
      groups[object.uuid.uuid] = _groupManifest(object);
    } else if (object is KdbxEntry) {
      entries[object.uuid.uuid] = _entryManifest(object);
    }
  }

  return {
    'header': _headerManifest(file),
    'meta': _metaManifest(file.body.meta),
    'deletedObjects': _sortedMap({
      for (final deleted in file.body.deletedObjects)
        deleted.uuid.uuid: deleted.deletionTime.get()?.toIso8601String(),
    }),
    'groups': _sortedMap(groups),
    'entries': _sortedMap(entries),
  };
}

/// [_manifest] with the given objects removed, so a mutation spike can prove
/// everything it did NOT intend to touch is unchanged.
///
/// [remodifiedGroupUuids] names the groups the spike itself re-parents into.
/// `kdbx` stamps a group's `lastModificationTime` from the wall clock whenever
/// a child is added (`KdbxGroup.addGroup` -> `modify` -> `times.modifiedNow`),
/// so the parent of an imported child is legitimately re-stamped. KDBX stores
/// that field with one-second precision, which made the comparison pass only
/// while the snapshot and the import happened to fall inside the same second.
/// The pointer to the new child is already filtered out below; this drops the
/// timestamp that adding it moved. Every other group keeps a strict comparison.
Map<String, Object?> _manifestExcluding(
  KdbxFile file, {
  Set<String> entryUuids = const {},
  Set<String> excludeGroupUuids = const {},
  Set<String> remodifiedGroupUuids = const {},
}) {
  final manifest = _manifest(file);
  final entries = Map<String, Object?>.from(
    manifest['entries']! as Map<String, Object?>,
  )..removeWhere((uuid, _) => entryUuids.contains(uuid));
  final groups = Map<String, Object?>.from(
    manifest['groups']! as Map<String, Object?>,
  )..removeWhere((uuid, _) => excludeGroupUuids.contains(uuid));

  // Entries living inside an excluded group are excluded with it.
  entries.removeWhere((_, value) {
    final parent = (value! as Map<String, Object?>)['parent'];
    return parent is String && excludeGroupUuids.contains(parent);
  });

  // An excluded group must also disappear from its parent's sibling order,
  // otherwise "unrelated data" would include the pointer to the new group.
  for (final uuid in groups.keys) {
    final group = Map<String, Object?>.from(
      groups[uuid]! as Map<String, Object?>,
    );
    group['groupOrder'] = (group['groupOrder']! as List)
        .where((child) => !excludeGroupUuids.contains(child))
        .toList();
    group['entryOrder'] = (group['entryOrder']! as List)
        .where((child) => !entryUuids.contains(child))
        .toList();
    if (remodifiedGroupUuids.contains(uuid)) {
      group['times'] = Map<String, Object?>.from(
        group['times']! as Map<String, Object?>,
      )..remove('lastModificationTime');
    }
    groups[uuid] = group;
  }

  return {...manifest, 'entries': entries, 'groups': groups};
}

/// Takes the whole file because `KdbxHeader` is not an exported type.
Map<String, Object?> _headerManifest(KdbxFile file) {
  final header = file.header;
  final manifest = <String, Object?>{
    'version': '${header.version.major}.${header.version.minor}',
    'cipher': header.cipher.toString(),
    'compression': header.compression.toString(),
  };
  if (header.version.major >= KdbxVersion.V4.major) {
    final kdf = header.readKdfParameters;
    manifest['kdfUuid'] = base64.encode(
      KdfField.uuid.read(kdf) ?? Uint8List(0),
    );
    manifest['kdfIterations'] = KdfField.iterations.read(kdf);
    manifest['kdfMemory'] = KdfField.memory.read(kdf);
    manifest['kdfParallelism'] = KdfField.parallelism.read(kdf);
    manifest['kdfVersion'] = KdfField.version.read(kdf);
  }
  return manifest;
}

Map<String, Object?> _metaManifest(KdbxMeta meta) => {
  'databaseName': meta.databaseName.get(),
  'databaseDescription': meta.databaseDescription.get(),
  'defaultUserName': meta.defaultUserName.get(),
  'recycleBinEnabled': meta.recycleBinEnabled.get(),
  'recycleBinUuid': meta.recycleBinUUID.get()?.uuid,
  'historyMaxItems': meta.historyMaxItems.get(),
  'historyMaxSize': meta.historyMaxSize.get(),
  'maintenanceHistoryDays': meta.maintenanceHistoryDays.get(),
  'entryTemplatesGroup': meta.entryTemplatesGroup.get()?.uuid,
  'customData': _sortedMap({
    for (final entry in meta.customData.entries) entry.key: entry.value,
  }),
  'customIcons': _sortedMap({
    for (final icon in meta.customIcons.values)
      icon.uuid.uuid: base64.encode(icon.data),
  }),
};

Map<String, Object?> _groupManifest(KdbxGroup group) => {
  'name': group.name.get(),
  'notes': group.notes.get(),
  'parent': group.parent?.uuid.uuid,
  'icon': group.icon.get()?.index,
  'customIcon': group.customIconUuid.get()?.uuid,
  'expanded': group.expanded.get(),
  'enableAutoType': group.enableAutoType.get(),
  'enableSearching': group.enableSearching.get(),
  'defaultAutoTypeSequence': group.defaultAutoTypeSequence.get(),
  // Sibling order is part of the semantics the adapter must preserve.
  'groupOrder': group.groups.map((g) => g.uuid.uuid).toList(),
  'entryOrder': group.entries.map((e) => e.uuid.uuid).toList(),
  'times': _timesManifest(group),
};

Map<String, Object?> _entryManifest(KdbxEntry entry) => {
  'parent': entry.parent?.uuid.uuid,
  'icon': entry.icon.get()?.index,
  'customIcon': entry.customIconUuid.get()?.uuid,
  'tags': entry.tags.get(),
  'overrideURL': entry.overrideURL.get(),
  // `KdbxColor` exposes no RGB accessor and defines no `==`, but that only
  // makes the WRAPPER opaque: the value itself is readable, because
  // `KdbxNode.node` is a public, exported `XmlElement` and `ColorNode.set`
  // writes the RGB code straight into it. Semantic verification of colors is
  // therefore possible — see `_xmlText`.
  'foregroundColor': _xmlText(entry, 'ForegroundColor'),
  'backgroundColor': _xmlText(entry, 'BackgroundColor'),
  // Entry-level AutoType is not modelled by `kdbx 2.4.2` at all, so it is
  // compared as raw XML for the same reason.
  'autoType': _xmlOf(entry, 'AutoType')?.toXmlString(),
  'times': _timesManifest(entry),
  'strings': _sortedMap({
    for (final string in entry.stringEntries)
      // Key spelling is preserved verbatim, never canonicalized.
      string.key.key: <String, Object?>{
        'protected': string.value is ProtectedValue,
        'value': string.value?.getText(),
      },
  }),
  'binaries': _sortedMap({
    for (final binary in entry.binaryEntries)
      binary.key.key: <String, Object?>{
        'protected': binary.value.isProtected,
        'inline': binary.value.isInline,
        'length': binary.value.value.length,
        // Exact bytes, compared by digest rather than by dumping them.
        'sha256': sha256.convert(binary.value.value).toString(),
      },
  }),
  // History order is meaningful; do not sort it.
  'history': entry.history.map(_entryManifest).toList(),
};

/// Entry-level `<AutoType>` node as KeePass writes it.
///
/// `kdbx 2.4.2` has no model for it, so the spike authors the XML directly.
XmlElement _autoTypeElement() => XmlElement(XmlName('AutoType'), [], [
  XmlElement(XmlName('Enabled'), [], [XmlText('True')]),
  XmlElement(XmlName('DataTransferObfuscation'), [], [XmlText('0')]),
  XmlElement(XmlName('DefaultSequence'), [], [
    XmlText(_fixtureAutoTypeSequence),
  ]),
  XmlElement(XmlName('Association'), [], [
    XmlElement(XmlName('Window'), [], [XmlText(_fixtureAutoTypeWindow)]),
    XmlElement(XmlName('KeystrokeSequence'), [], [
      XmlText(_fixtureAutoTypeAssociationSequence),
    ]),
  ]),
]);

/// Direct child element of a KDBX object's own XML node, or `null`.
///
/// `KdbxNode.node` is public and exported from `package:kdbx/kdbx.dart`, so
/// constructs the library does not model are still fully observable.
XmlElement? _xmlOf(KdbxObject object, String name) {
  final matches = object.node.findElements(name).toList();
  return matches.isEmpty ? null : matches.single;
}

String? _xmlText(KdbxObject object, String name) =>
    _xmlOf(object, name)?.innerText;

/// Takes the owning object because `KdbxTimes` is not an exported type.
Map<String, Object?> _timesManifest(KdbxObject object) {
  final times = object.times;
  return {
    'creationTime': times.creationTime.get()?.toIso8601String(),
    'lastModificationTime': times.lastModificationTime.get()?.toIso8601String(),
    'locationChanged': times.locationChanged.get()?.toIso8601String(),
    'expiryTime': times.expiryTime.get()?.toIso8601String(),
    'expires': times.expires.get(),
    'usageCount': times.usageCount.get(),
  };
}

Map<String, Object?> _sortedMap(Map<String, Object?> source) {
  final keys = source.keys.toList()..sort();
  return {for (final key in keys) key: source[key]};
}

KdbxEntry _entryByUuid(KdbxFile file, String uuid) =>
    file.body.rootGroup.getAllEntries().firstWhere((e) => e.uuid.uuid == uuid);

KdbxGroup _groupByUuid(KdbxFile file, KdbxUuid uuid) =>
    file.body.rootGroup.getAllGroups().firstWhere((g) => g.uuid == uuid);

/// spec FR-2: Drive file id is not lineage evidence; root group UUID is.
bool _lineageMatches(KdbxFile local, KdbxFile remote) =>
    local.body.rootGroup.uuid == remote.body.rootGroup.uuid;

/// spec FR-2 per-side validation, run before any diff/session/write.
_UuidViolation? _validateSide(KdbxFile file) {
  final groupUuids = <String>{};
  final entryUuids = <String>{};

  for (final object in file.body.rootGroup.getAllGroupsAndEntries()) {
    final uuid = object.uuid;
    if (uuid.isNil) {
      return _UuidViolation.nilUuid;
    }
    if (object is KdbxGroup) {
      if (!groupUuids.add(uuid.uuid)) {
        return _UuidViolation.duplicateGroup;
      }
    } else {
      if (!entryUuids.add(uuid.uuid)) {
        return _UuidViolation.duplicateEntry;
      }
    }
  }

  // Global uniqueness across BOTH collections, not just within one.
  if (groupUuids.intersection(entryUuids).isNotEmpty) {
    return _UuidViolation.groupEntryCollision;
  }
  return null;
}

/// spec FR-2: a UUID present on both sides must denote the same object kind.
bool _crossSideKindMismatch(KdbxFile local, KdbxFile remote) {
  Map<String, String> kinds(KdbxFile file) => {
    for (final object in file.body.rootGroup.getAllGroupsAndEntries())
      object.uuid.uuid: object is KdbxGroup ? 'group' : 'entry',
  };

  final localKinds = kinds(local);
  final remoteKinds = kinds(remote);
  for (final entry in localKinds.entries) {
    final remoteKind = remoteKinds[entry.key];
    if (remoteKind != null && remoteKind != entry.value) {
      return true;
    }
  }
  return false;
}

Future<void> _createDatabase({
  required String databasePath,
  required String password,
  String? keyFilePath,
}) async {
  final keyBytes = keyFilePath == null
      ? null
      : await File(keyFilePath).readAsBytes();
  final credentials = Credentials.composite(
    ProtectedValue.fromString(password),
    keyBytes,
  );
  final kdbx = KdbxFormat().create(credentials, 'Test DB');
  final bytes = await kdbx.save();
  await File(databasePath).writeAsBytes(bytes, flush: true);
}

Future<String> _rootGroupId(
  VaultKdbxService service,
  String databasePath,
  String password,
) async {
  final snapshot = await service.loadVault(
    databasePath: databasePath,
    password: password,
  );
  return snapshot.rootGroupId;
}

class _HashRegistryRepository implements DatabaseRegistryRepository {
  final List<DatabaseRecord> records = [];
  int? failUpsertOnCall;
  int upsertCalls = 0;
  Object? failListWith;

  @override
  Future<DatabaseRecord?> findByHash(String fileHash) async => null;

  @override
  Future<DatabaseRecord?> findBySource({
    required DatabaseSourceType sourceType,
    required String sourceRef,
  }) async => null;

  @override
  Future<String?> getActive() async => null;

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
  Future<List<DatabaseRecord>> list() async {
    final error = failListWith;
    if (error != null) {
      throw error;
    }
    return List.of(records);
  }

  @override
  Future<void> remove(String databaseId) async {}

  @override
  Future<void> setActive(String? databaseId) async {}

  @override
  Future<void> upsert(DatabaseRecord record) async {
    upsertCalls += 1;
    if (failUpsertOnCall == upsertCalls) {
      throw StateError('registry write failed');
    }
    records.removeWhere((item) => item.databaseId == record.databaseId);
    records.add(record);
  }
}

class _FailingSafeVaultFileWriter extends SafeVaultFileWriter {
  @override
  Future<SafeVaultFileWriteResult> write({
    required String targetPath,
    required Uint8List bytes,
    bool backupExistingTarget = false,
    String? operation,
  }) async {
    throw Exception('writer unavailable');
  }
}
