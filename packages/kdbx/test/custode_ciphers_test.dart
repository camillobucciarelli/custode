// Custode: Twofish, Argon2id and configurable kdbx4 headers.
// See CUSTODE_CHANGES.md.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_var_dictionary.dart' show ValueType;
import 'package:pointycastle/export.dart' show KeyParameter, TwofishEngine;
import 'package:test/test.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

void main() {
  final format = KdbxFormat();
  const password = 'correct horse battery staple';

  // Low costs keep the 9 combinations fast.
  const kdfs = <KdbxKdfConfig>[
    KdbxAesKdfConfig(rounds: 1000),
    KdbxArgon2KdfConfig(
      type: KdfType.Argon2,
      iterations: 1,
      memoryBytes: 64 * 1024,
      parallelism: 2,
    ),
    KdbxArgon2KdfConfig(
      type: KdfType.Argon2id,
      iterations: 1,
      memoryBytes: 64 * 1024,
      parallelism: 2,
    ),
  ];

  group('round trip', () {
    for (final cipher in Cipher.values) {
      for (final kdf in kdfs) {
        test('$cipher + ${kdf.type}', () async {
          final file = format.create(
            Credentials(ProtectedValue.fromString(password)),
            'db',
            header: KdbxHeader.createV4(cipher: cipher, kdf: kdf),
          );
          final entry = KdbxEntry.create(file, file.body.rootGroup);
          file.body.rootGroup.addEntry(entry);
          entry.setString(KdbxKeyCommon.TITLE, PlainValue('mail'));
          entry.setString(
            KdbxKeyCommon.PASSWORD,
            ProtectedValue.fromString('s3cret'),
          );
          final bytes = await file.save();

          final locked = KdbxHeader.readFromBytes(bytes);
          expect(locked.version, KdbxVersion.V4);
          expect(locked.cipher, cipher);
          expect(locked.kdfConfig, kdf);

          final read = await format.read(
            bytes,
            Credentials(ProtectedValue.fromString(password)),
          );
          expect(read.header.cipher, cipher);
          expect(read.header.kdfConfig, kdf);
          final entries = read.body.rootGroup.entries;
          expect(entries, hasLength(1));
          expect(
            entries.single.getString(KdbxKeyCommon.TITLE)!.getText(),
            'mail',
          );
          expect(
            entries.single.getString(KdbxKeyCommon.PASSWORD)!.getText(),
            's3cret',
          );

          await expectLater(
            format.read(bytes, Credentials(ProtectedValue.fromString('x'))),
            throwsA(isA<KdbxInvalidKeyException>()),
          );
        });
      }
    }
  });

  test('createV4() without arguments keeps the upstream defaults', () {
    final header = KdbxHeader.createV4();
    expect(header.cipher, Cipher.aes);
    expect(
      header.kdfConfig,
      const KdbxArgon2KdfConfig(
        type: KdfType.Argon2,
        iterations: 2,
        memoryBytes: 1024 * 1024,
        parallelism: 1,
      ),
    );
  });

  test('AES-KDF rounds are written as UInt64 like KeePass', () {
    final bytes = const KdbxAesKdfConfig(rounds: 7).toParameters().write();
    // VarDictionary entry: type byte, then key length + key "R".
    final at = _hex(bytes).indexOf('0501000000${_hex(utf8.encode('R'))}');
    expect(at, isNot(-1));
  });

  test(
    'AES-KDF rounds stored as Int64 (older Custode files) still open',
    () async {
      final credentials = Credentials(ProtectedValue.fromString(password));
      final header = KdbxHeader.createV4(
        kdf: const KdbxAesKdfConfig(rounds: 1000),
      );
      // What upstream kdbx 2.6.0, and so older Custode versions, wrote.
      final parameters = header.readKdfParameters
        ..set(ValueType.typeInt64, 'R', 1234);
      header.writeKdfParameters(parameters);
      final bytes = await format
          .create(credentials, 'int64', header: header)
          .save();
      expect(_hex(bytes), contains('0d01000000${_hex(utf8.encode('R'))}'));

      final opened = await format.read(bytes, credentials);
      expect(opened.header.kdfConfig, isA<KdbxAesKdfConfig>());
      expect((opened.header.kdfConfig as KdbxAesKdfConfig).rounds, 1234);

      final resaved = await opened.save();
      final reopened = await format.read(resaved, credentials);
      expect((reopened.header.kdfConfig as KdbxAesKdfConfig).rounds, 1234);
      expect(
        (KdbxHeader.readFromBytes(resaved).kdfConfig as KdbxAesKdfConfig)
            .rounds,
        1234,
      );
    },
  );

  group('third-party files (pykeepass fixtures)', () {
    Future<KdbxFile> open(String name, {bool keyFile = true}) async {
      final bytes = await File('test/pykeepass/$name').readAsBytes();
      final key = keyFile
          ? await File('test/pykeepass/test4.key').readAsBytes()
          : null;
      return format.read(
        bytes,
        Credentials.composite(ProtectedValue.fromString('password'), key),
      );
    }

    final cases = {
      'test4_twofish.kdbx': (Cipher.twofish, KdfType.Argon2, true, 'KeePass'),
      'test4_chacha20.kdbx': (Cipher.chaCha20, KdfType.Argon2, true, 'KeePass'),
      'test4_aeskdf.kdbx': (Cipher.aes, KdfType.Aes, true, 'KeePass'),
      'test4_argon2id.kdbx': (Cipher.aes, KdfType.Argon2id, false, 'KeePassXC'),
    };
    cases.forEach((name, expected) {
      final (cipher, kdf, keyFile, generator) = expected;
      test(name, () async {
        final locked = KdbxHeader.readFromBytes(
          await File('test/pykeepass/$name').readAsBytes(),
        );
        expect(locked.cipher, cipher);
        expect(locked.kdfConfig.type, kdf);

        final file = await open(name, keyFile: keyFile);
        expect(file.header.cipher, cipher);
        expect(file.header.kdfConfig.type, kdf);
        // Decrypting, the HMAC check and parsing the XML all passed; the
        // argon2id fixture is an empty database, so check the XML loaded.
        expect(file.body.rootGroup.name.get(), isNotEmpty);
        expect(file.body.meta.generator.get(), generator);

        // And what we write back opens again.
        final again = await format.read(await file.save(), file.credentials);
        expect(again.header.cipher, cipher);
        expect(
          again.body.rootGroup.getAllEntries().length,
          file.body.rootGroup.getAllEntries().length,
        );
      });
    });
  });

  group('known-answer tests', () {
    test('Argon2id through the KDF path (phc-winner-argon2 test.c)', () async {
      // hashtest(0x13, t=2, m=1<<8 KiB, p=2, "password", "somesalt", Argon2_id)
      final params = VarDictionary([
        KdfField.uuid.item(
          KeyEncrypterKdf.kdfUuidForType(KdfType.Argon2id).toBytes(),
        ),
        KdfField.salt.item(Uint8List.fromList(utf8.encode('somesalt'))),
        KdfField.parallelism.item(2),
        KdfField.memory.item(256 * 1024),
        KdfField.iterations.item(2),
        KdfField.version.item(0x13),
      ]);
      final out = await KeyEncrypterKdf(format.argon2).encrypt(
        Uint8List.fromList(utf8.encode('password')),
        params,
      );
      expect(
        _hex(out),
        '6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037',
      );
    });

    test('Twofish-256 block (Bouncy Castle TwofishTest vector 0)', () {
      final engine = TwofishEngine()
        ..init(
          true,
          KeyParameter(
            _unhex(
              '000102030405060708090a0b0c0d0e0f'
              '101112131415161718191a1b1c1d1e1f',
            ),
          ),
        );
      final out = Uint8List(16);
      engine.processBlock(
        _unhex('000102030405060708090a0b0c0d0e0f'),
        0,
        out,
        0,
      );
      expect(_hex(out), '8ef0272c42db838bcf7b07af0ec30f38');
    });
  });
}
