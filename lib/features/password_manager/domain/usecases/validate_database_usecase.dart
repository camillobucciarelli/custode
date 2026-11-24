import 'dart:io';
import 'dart:typed_data';

import 'package:loggy/loggy.dart';

/// Typed validation result instead of a bool-only collapse, so callers can
/// distinguish "file absent" from "file present but not a valid KDBX
/// structure" (C-3: these map to different `DatabaseAccessFailure`s).
enum DatabaseFileValidation { valid, missing, invalidStructure }

class ValidateDatabaseUseCase {
  Future<DatabaseFileValidation> call(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return DatabaseFileValidation.missing;
    }

    try {
      final RandomAccessFile raf = await file.open(mode: FileMode.read);
      // Ensure file has at least 8 bytes for checking signatures
      if (await file.length() < 8) {
        await raf.close();
        return DatabaseFileValidation.invalidStructure;
      }

      final Uint8List headerBytes = await raf.read(8);
      await raf.close();

      final ByteData bd = ByteData.sublistView(headerBytes);
      final int sig1 = bd.getUint32(0, Endian.little);
      final int sig2 = bd.getUint32(4, Endian.little);

      // KDBX Magic numbers
      // Signature 1: 0x9AA2D903
      // Signature 2: 0xB54BFB67 (KDBX 3.x and 4.x)
      if (sig1 == 0x9AA2D903 && sig2 == 0xB54BFB67) {
        return DatabaseFileValidation.valid;
      }

      return DatabaseFileValidation.invalidStructure;
    } catch (e, st) {
      logError('Failed while validating KDBX file header.', e, st);
      return DatabaseFileValidation.invalidStructure;
    }
  }
}
