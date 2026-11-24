import 'dart:typed_data';

import 'package:kdbx/src/kdbx_object.dart';

enum Cipher {
  /// the only cipher supported in kdbx <= 3
  aes,

  /// Support since kdbx 4.
  chaCha20,

  /// Twofish-256 in CBC mode. Support since kdbx 4 (as in KeePassXC).
  twofish,
}

class CryptoConsts {
  static const CIPHER_IDS = <Cipher, KdbxUuid>{
    Cipher.aes: KdbxUuid('McHy5r9xQ1C+WAUhavxa/w=='),
    Cipher.chaCha20: KdbxUuid('1gOKK4tvTLWlJDOaMdu1mg=='),
    // ad68f29f-576f-4bb9-a36a-d47af965346c
    Cipher.twofish: KdbxUuid('rWjyn1dvS7mjatR6+WU0bA=='),
  };
  static final cipherByUuid = CIPHER_IDS.map(
    (key, value) => MapEntry(value, key),
  );

  static Cipher? cipherFromBytes(Uint8List bytes) =>
      cipherByUuid[KdbxUuid.fromBytes(bytes)];
}
