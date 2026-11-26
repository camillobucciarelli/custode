@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:argon2_ffi_base/argon2_ffi_base.dart';
import 'package:convert/convert.dart';
import 'package:ffi/ffi.dart';
import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/crypto/key_encrypter_kdf.dart';
import 'package:kdbx/src/internal/native_kdf.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';

// argon2_context from phc-winner-argon2 include/argon2.h, to run the RFC 9106
// vectors (they use a secret and associated data, which kdbx does not pass).
final class _Argon2Context extends Struct {
  external Pointer<Uint8> out;
  @Uint32()
  external int outlen;
  external Pointer<Uint8> pwd;
  @Uint32()
  external int pwdlen;
  external Pointer<Uint8> salt;
  @Uint32()
  external int saltlen;
  external Pointer<Uint8> secret;
  @Uint32()
  external int secretlen;
  external Pointer<Uint8> ad;
  @Uint32()
  external int adlen;
  @Uint32()
  external int tCost;
  @Uint32()
  external int mCost;
  @Uint32()
  external int lanes;
  @Uint32()
  external int threads;
  @Uint32()
  external int version;
  external Pointer<Void> allocateCbk;
  external Pointer<Void> freeCbk;
  @Uint32()
  external int flags;
}

@Native<Int32 Function(Pointer<_Argon2Context>, Int32)>(
  symbol: 'argon2_ctx',
  assetId: 'package:kdbx/src/internal/native_kdf_ffi.dart',
)
external int _argon2Ctx(Pointer<_Argon2Context> ctx, int type);

Uint8List _fill(int length, int byte) =>
    Uint8List(length)..fillRange(0, length, byte);

Uint8List _rfcNative(int type) {
  return using((arena) {
    Pointer<Uint8> buf(Uint8List bytes) {
      final p = arena<Uint8>(bytes.length);
      p.asTypedList(bytes.length).setAll(0, bytes);
      return p;
    }

    final ctx = arena<_Argon2Context>();
    ctx.ref
      ..out = arena<Uint8>(32)
      ..outlen = 32
      ..pwd = buf(_fill(32, 1))
      ..pwdlen = 32
      ..salt = buf(_fill(16, 2))
      ..saltlen = 16
      ..secret = buf(_fill(8, 3))
      ..secretlen = 8
      ..ad = buf(_fill(12, 4))
      ..adlen = 12
      ..tCost = 3
      ..mCost = 32
      ..lanes = 4
      ..threads = 4
      ..version = 0x13
      ..allocateCbk = nullptr
      ..freeCbk = nullptr
      ..flags = 0;
    expect(_argon2Ctx(ctx, type), 0);
    return Uint8List.fromList(ctx.ref.out.asTypedList(32));
  });
}

Uint8List _rfcDart(int type) {
  final kdf = pc.Argon2BytesGenerator()
    ..init(
      pc.Argon2Parameters(
        type,
        _fill(16, 2),
        desiredKeyLength: 32,
        secret: _fill(8, 3),
        additional: _fill(12, 4),
        iterations: 3,
        memory: 32,
        lanes: 4,
        version: 0x13,
      ),
    );
  return kdf.process(_fill(32, 1));
}

Argon2Arguments _args(
  String password,
  String salt, {
  required int type,
  int memory = 1 << 16,
  int iterations = 2,
  int parallelism = 1,
}) => Argon2Arguments(
  Uint8List.fromList(password.codeUnits),
  Uint8List.fromList(salt.codeUnits),
  memory,
  iterations,
  32,
  parallelism,
  type,
  0x13,
);

Uint8List _aesDart(EncryptAesArgs args) =>
    KeyEncrypterKdf.encryptAesSync(args, native: (_, _, _) => false);

Uint8List _throwingArgon2(Argon2Arguments args) =>
    throw StateError('native disabled');

void main() {
  group('Argon2 known answers', () {
    // RFC 9106 section 5 (phc-winner-argon2 kats/argon2d, kats/argon2id).
    const rfc = {
      0: '512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb',
      2: '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
    };
    for (final MapEntry(key: type, value: tag) in rfc.entries) {
      test('RFC 9106 Argon2${type == 0 ? 'd' : 'id'} native', () {
        expect(hex.encode(_rfcNative(type)), tag);
      });
      test('RFC 9106 Argon2${type == 0 ? 'd' : 'id'} Dart', () {
        expect(hex.encode(_rfcDart(type)), tag);
      });
    }

    // phc-winner-argon2 src/test.c, Argon2id v0x13, through the kdbx path.
    final testC = {
      _args('password', 'somesalt', type: 2):
          '09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7',
      _args('password', 'somesalt', type: 2, memory: 256, parallelism: 2):
          '6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037',
      _args('password', 'diffsalt', type: 2):
          'bdf32b05ccc42eb15d58fd19b1f856b113da1e9a5874fdcc544308565aa8141c',
    };
    for (final (i, MapEntry(key: args, value: tag)) in testC.entries.indexed) {
      test('test.c Argon2id #$i native', () {
        expect(hex.encode(nativeArgon2(args)!), tag);
      });
    }
  });

  group('Argon2 native vs Dart', () {
    final random = Random(42);
    Uint8List bytes(int n) =>
        Uint8List.fromList(List.generate(n, (_) => random.nextInt(256)));
    final cases = [
      // KeePassXC defaults for new databases.
      (type: 2, memory: 1 << 16, iterations: 10, parallelism: 4),
      (type: 0, memory: 1 << 10, iterations: 2, parallelism: 1),
      (type: 0, memory: 4096, iterations: 3, parallelism: 3),
      (type: 2, memory: 2048, iterations: 1, parallelism: 2),
      (type: 2, memory: 8192, iterations: 5, parallelism: 8),
    ];
    for (final c in cases) {
      test('$c', () {
        final args = Argon2Arguments(
          bytes(32),
          bytes(32),
          c.memory,
          c.iterations,
          32,
          c.parallelism,
          c.type,
          0x13,
        );
        final native = nativeArgon2(args);
        expect(native, isNotNull);
        expect(native, const PointyCastleArgon2().argon2(args));
      });
    }
  });

  group('AES-KDF', () {
    // SHA-256 of 32 bytes 0xa0..0xbf after N rounds of AES-256-ECB under the
    // key 0x00..0x1f, computed with Apple CommonCrypto.
    const answers = {
      0: '00e988677eecf94c0bb9233371c7c0d6f4db8ebdcdecb7c5ebaa666f17249227',
      1: '0840164f13cf49ca292088ff5b487405bd0438e9f55b3a0ccb9c1e6bfe8cb2c2',
      6000: '1397a1674912081423b8fabe338f5f70c67e325b6ac85158d93ca904adcfe0f2',
      1000000:
          '0ed5720e3c83efcf19fde33e23a0eba4d9b8fc492956279cf513240738124f65',
    };
    EncryptAesArgs args(int rounds) => EncryptAesArgs(
      Uint8List.fromList(List.generate(32, (i) => i)),
      Uint8List.fromList(List.generate(32, (i) => 0xa0 + i)),
      rounds,
    );
    for (final MapEntry(key: rounds, value: hash) in answers.entries) {
      test('$rounds rounds native', () {
        final data = Uint8List.fromList(args(rounds).key);
        expect(
          tryNativeAesKdf(args(rounds).encryptionKey!, data, rounds),
          isTrue,
        );
        expect(hex.encode(KeyEncrypterKdf.encryptAesSync(args(rounds))), hash);
      });
      if (rounds <= 6000) {
        test('$rounds rounds Dart', () {
          expect(hex.encode(_aesDart(args(rounds))), hash);
        });
      }
    }

    test('native vs Dart on random inputs', () {
      final random = Random(7);
      for (var i = 0; i < 20; i++) {
        final a = EncryptAesArgs(
          Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
          Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
          random.nextInt(3000),
        );
        expect(KeyEncrypterKdf.encryptAesSync(a), _aesDart(a));
      }
    });

    test('declines sizes other than 32 bytes, leaving data untouched', () {
      final data = Uint8List(16);
      expect(tryNativeAesKdf(Uint8List(32), data, 10), isFalse);
      expect(data, Uint8List(16));
    });
  });

  group('fallback', () {
    final args = _args('password', 'somesalt', type: 2);
    const tag =
        '09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7';

    test('Argon2 falls back to Dart when native throws or declines', () {
      expect(
        hex.encode(NativeArgon2(native: _throwingArgon2).argon2(args)),
        tag,
      );
      expect(hex.encode(NativeArgon2(native: (_) => null).argon2(args)), tag);
    });

    test('native declines a version it does not know', () {
      final odd = Argon2Arguments(args.key, args.salt, 256, 2, 32, 1, 2, 0x11);
      expect(nativeArgon2(odd), isNull);
    });

    test('a vault opens with the native Argon2 path failing', () async {
      final credentials = Credentials(ProtectedValue.fromString('pw'));
      final header = KdbxHeader.createV4(
        kdf: const KdbxArgon2KdfConfig(
          type: KdfType.Argon2id,
          memoryBytes: 1 << 20,
          iterations: 2,
          parallelism: 2,
        ),
      );
      final file = KdbxFormat().create(credentials, 'native', header: header);
      final bytes = await file.save();
      final reopened = await KdbxFormat(
        NativeArgon2(native: _throwingArgon2),
      ).read(bytes, credentials);
      expect(reopened.body.rootGroup.name.get(), 'native');
    });

    test('AES-KDF falls back to Dart when native is unavailable', () {
      final a = EncryptAesArgs(
        Uint8List.fromList(List.generate(32, (i) => i)),
        Uint8List.fromList(List.generate(32, (i) => 0xa0 + i)),
        6000,
      );
      expect(
        hex.encode(_aesDart(a)),
        '1397a1674912081423b8fabe338f5f70c67e325b6ac85158d93ca904adcfe0f2',
      );
    });
  });
}
