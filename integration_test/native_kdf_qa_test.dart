// Manual QA probe for the native KDF (packages/kdbx hook/build.dart). No CI job
// runs this and `flutter test` never collects `integration_test/`.
//
//   fvm flutter test integration_test/native_kdf_qa_test.dart -d <device>
//
// Creates, saves and reopens an Argon2id and an AES-KDF vault at the KeePassXC
// defaults with the default (native) KDF, reopens them with pure-Dart Argon2
// (AES-KDF: times the Dart transform alone), and prints the timings.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kdbx/kdbx.dart';
// ignore: implementation_imports
import 'package:kdbx/src/crypto/key_encrypter_kdf.dart';
// ignore: implementation_imports
import 'package:kdbx/src/internal/native_kdf.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final credentials = Credentials(ProtectedValue.fromString('NativeKdfQa!'));
  final configs = <String, KdbxKdfConfig>{
    'Argon2id 64 MiB, 10 iterations, p=4': const KdbxArgon2KdfConfig(
      type: KdfType.Argon2id,
    ),
    'AES-KDF 1,000,000 rounds': const KdbxAesKdfConfig(),
  };

  for (final MapEntry(key: label, value: kdf) in configs.entries) {
    testWidgets(label, (tester) async {
      final aes = Uint8List.fromList(List.generate(32, (i) => i));
      debugPrint(
        'native AES-KDF available: '
        '${tryNativeAesKdf(aes, Uint8List(32), 1)}',
      );
      final file = KdbxFormat().create(
        credentials,
        'qa',
        header: KdbxHeader.createV4(kdf: kdf),
      );

      final watch = Stopwatch()..start();
      final bytes = await tester.runAsync(file.save);
      debugPrint(
        '$label create+save (native): ${watch.elapsedMilliseconds} ms',
      );

      watch.reset();
      final native = await tester.runAsync(
        () => KdbxFormat().read(bytes!, credentials),
      );
      debugPrint('$label open (native): ${watch.elapsedMilliseconds} ms');

      expect(native!.body.rootGroup.name.get(), 'qa');

      watch.reset();
      if (kdf is KdbxArgon2KdfConfig) {
        final dart = await tester.runAsync(
          () =>
              KdbxFormat(const PointyCastleArgon2()).read(bytes!, credentials),
        );
        expect(dart!.body.rootGroup.name.get(), 'qa');
      } else {
        KeyEncrypterKdf.encryptAesSync(
          EncryptAesArgs(aes, Uint8List(32), 1000000),
          native: (_, _, _) => false,
        );
      }
      debugPrint('$label KDF in Dart: ${watch.elapsedMilliseconds} ms');
    });
  }
}
