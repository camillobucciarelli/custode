import 'dart:typed_data';

import 'package:argon2_ffi_base/argon2_ffi_base.dart';
import 'package:kdbx/src/internal/native_kdf_stub.dart'
    if (dart.library.ffi) 'package:kdbx/src/internal/native_kdf_ffi.dart'
    as impl;
import 'package:kdbx/src/internal/pointycastle_argon2.dart';
import 'package:logging/logging.dart';

export 'package:kdbx/src/internal/native_kdf_stub.dart'
    if (dart.library.ffi) 'package:kdbx/src/internal/native_kdf_ffi.dart';

final _logger = Logger('native_kdf');

/// Argon2 through the native reference implementation, falling back to
/// [PointyCastleArgon2] when the library is missing (web, a build without
/// native assets) or returns an error. Runs in [Isolate.run] like its parent.
class NativeArgon2 extends PointyCastleArgon2 {
  const NativeArgon2({this.native = impl.nativeArgon2});

  /// The native call; tests swap it to force the fallback.
  final Uint8List? Function(Argon2Arguments args) native;

  @override
  bool get isFfi => true;

  @override
  Uint8List argon2(Argon2Arguments args) {
    try {
      final result = native(args);
      if (result != null) {
        return result;
      }
      _logger.fine('Native Argon2 declined the arguments, using Dart.');
    } catch (e) {
      _logger.fine('Native Argon2 unavailable, using Dart: $e');
    }
    return super.argon2(args);
  }
}

/// Runs the AES-KDF rounds on [data] in place natively. `false` (with [data]
/// untouched) when native AES is unavailable, so the caller runs Dart.
bool tryNativeAesKdf(Uint8List key, Uint8List data, int rounds) {
  try {
    return impl.nativeAesKdf(key, data, rounds);
  } catch (e) {
    _logger.fine('Native AES-KDF unavailable, using Dart: $e');
    return false;
  }
}
