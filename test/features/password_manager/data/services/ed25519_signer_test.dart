import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/ed25519_signer.dart';
import 'package:password_manager/features/password_manager/data/services/passkey_parser.dart';

import '../../../../fixtures/passkeys/vectors.dart';

Uint8List unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // RFC 8032 section 7.1.
  final vectors = <String, (String, Uint8List, String)>{
    'TEST 1': (
      '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
      Uint8List(0),
      'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
          '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
    ),
    'TEST 2': (
      '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
      unhex('72'),
      '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
          '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
    ),
    'TEST 3': (
      'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
      unhex('af82'),
      '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac'
          '18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
    ),
    'TEST SHA(abc)': (
      '833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42',
      Uint8List.fromList(sha512.convert(utf8.encode('abc')).bytes),
      'dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b589'
          '09351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704',
    ),
  };

  for (final entry in vectors.entries) {
    test('RFC 8032 ${entry.key}', () {
      final (seed, message, signature) = entry.value;
      expect(hex(Ed25519Signer.sign(unhex(seed), message)), signature);
    });
  }

  test('matches an OpenSSL 3.6.4 signature over a fixed message', () {
    // Ed25519 is deterministic. Produced with:
    //   openssl pkeyutl -sign -inkey key.pem -rawin -in msg.bin -out sig.bin
    // key.pem = eddsaPrivateKeyPem, msg.bin = the ASCII text below, no newline.
    final der = PasskeyParser.pemToDer(eddsaPrivateKeyPem)!;
    final seed = Uint8List.fromList(der.sublist(der.length - 32));
    final message = utf8.encode('custode passkey openssl cross-check');
    expect(
      hex(Ed25519Signer.sign(seed, Uint8List.fromList(message))),
      'ad1706710f8a1fd0f8433882920d05139bad2b39012746ab0bbe2a84180e066b'
      '98f7cf296f023f2a60ce3708d5890d9b58dc8caaf3544a0715d3dd678f5c3601',
    );
  });

  test('a seed that is not 32 bytes is rejected', () {
    expect(
      () => Ed25519Signer.sign(Uint8List(31), Uint8List(0)),
      throwsFormatException,
    );
  });
}
