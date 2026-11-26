import 'dart:typed_data';

import 'package:argon2_ffi_base/argon2_ffi_base.dart';

/// No FFI (web): always `null`, the caller uses the Dart implementation.
Uint8List? nativeArgon2(Argon2Arguments args) => null;

/// No FFI (web): always `false`, the caller uses the Dart implementation.
bool nativeAesKdf(Uint8List key, Uint8List data, int rounds) => false;
