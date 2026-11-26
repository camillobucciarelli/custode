import 'dart:typed_data';

import 'package:kdbx/kdbx.dart';

/// What a successful unlock decrypted: the file and the exact bytes it was
/// decrypted from. Handed to [DatabaseFileRepository.adoptUnlockedDatabase]
/// once the session holds the secret, so the vault's first read does not run
/// the key derivation a second time.
class UnlockedDatabase {
  const UnlockedDatabase({
    required this.databasePath,
    required this.bytes,
    required this.file,
  });

  final String databasePath;
  final Uint8List bytes;
  final KdbxFile file;
}
