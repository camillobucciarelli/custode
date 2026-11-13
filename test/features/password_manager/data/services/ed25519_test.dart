import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/ed25519.dart';

Uint8List unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('RFC 8032 section 7.1 vectors', () {
    test('TEST 1: empty message', () {
      final seed = unhex(
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
      );
      expect(
        hex(Ed25519.publicKey(seed)),
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
      );
      expect(
        hex(Ed25519.sign(seed, Uint8List(0))),
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
    });

    test('TEST 2: one byte', () {
      final seed = unhex(
        '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
      );
      expect(
        hex(Ed25519.publicKey(seed)),
        '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
      );
      expect(
        hex(Ed25519.sign(seed, unhex('72'))),
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
        '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      );
    });
  });

  // Signed by OpenSSL 3.0.13 with the fixture key of
  // test/fixtures/passkeys/vectors.dart:
  //   openssl pkeyutl -sign -inkey k.pem -rawin -in m.bin
  test('matches OpenSSL on the fixture key', () {
    final seed = unhex(
      '4fca36315bfe0eea7a5003093aab51f267320337c15069917807eae4fb427527',
    );
    expect(
      hex(Ed25519.publicKey(seed)),
      '7ef84b87485eb4000faae74c14dd19907eabe8816e902c5404911120363c7527',
    );
    expect(
      hex(
        Ed25519.sign(
          seed,
          Uint8List.fromList(utf8.encode('custode ed25519 cross-check')),
        ),
      ),
      '0af236ab4412f7d7558f654b17ee54eccb4f9f504b4fe044e4dd1347cd1446b2'
      '1be55c7d73b9e4b184ae4736d37e619c7a63527766ee0e2aa85010b8b3db6102',
    );
  });

  test('a seed that is not 32 bytes is refused', () {
    expect(
      () => Ed25519.sign(Uint8List(31), Uint8List(0)),
      throwsArgumentError,
    );
    expect(() => Ed25519.publicKey(Uint8List(33)), throwsArgumentError);
  });
}
