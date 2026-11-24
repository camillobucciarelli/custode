import 'dart:ffi';
import 'dart:typed_data';

import 'package:argon2_ffi_base/argon2_ffi_base.dart';
import 'package:ffi/ffi.dart';

// Symbols of the `kdbx_native` code asset built by `hook/build.dart`. Not leaf
// calls: Argon2 runs for seconds and must not hold up the isolate group's GC.

@Native<
  Int32 Function(
    Uint32,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Int32,
    Uint32,
  )
>(symbol: 'argon2_hash')
external int _argon2Hash(
  int tCost,
  int mCost,
  int parallelism,
  Pointer<Uint8> pwd,
  int pwdLen,
  Pointer<Uint8> salt,
  int saltLen,
  Pointer<Uint8> hash,
  int hashLen,
  Pointer<Uint8> encoded,
  int encodedLen,
  int type,
  int version,
);

@Native<Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint64)>(
  symbol: 'kdbx_aes_kdf',
)
external int _aesKdf(Pointer<Uint8> key, Pointer<Uint8> data, int rounds);

const _uint32Max = 0xFFFFFFFF;

/// Argon2 with the native reference implementation, or `null` when the
/// arguments are out of its range or it returns an error. Throws when the
/// library cannot be loaded.
Uint8List? nativeArgon2(Argon2Arguments args) {
  bool inUint32(int v) => v > 0 && v <= _uint32Max;
  if (!inUint32(args.iterations) ||
      !inUint32(args.memory) ||
      !inUint32(args.parallelism) ||
      !inUint32(args.length) ||
      args.type < 0 ||
      args.type > 2 ||
      (args.version != 0x10 && args.version != 0x13)) {
    return null;
  }
  final key = _copy(args.key);
  final salt = _copy(args.salt);
  final hash = calloc<Uint8>(args.length);
  try {
    final rc = _argon2Hash(
      args.iterations,
      args.memory,
      args.parallelism,
      key,
      args.key.length,
      salt,
      args.salt.length,
      hash,
      args.length,
      nullptr,
      0,
      args.type, // 0 = d, 1 = i, 2 = id, as in argon2_type.
      args.version,
    );
    return rc == 0 ? Uint8List.fromList(hash.asTypedList(args.length)) : null;
  } finally {
    _wipeAndFree(key, args.key.length);
    _wipeAndFree(salt, args.salt.length);
    _wipeAndFree(hash, args.length);
  }
}

/// Runs the AES-KDF rounds on [data] in place with hardware AES. `false`
/// (and [data] untouched) when the CPU lacks AES instructions or the sizes
/// are not the kdbx ones. Throws when the library cannot be loaded.
bool nativeAesKdf(Uint8List key, Uint8List data, int rounds) {
  if (key.length != 32 || data.length != 32 || rounds < 0) {
    return false;
  }
  final k = _copy(key);
  final d = _copy(data);
  try {
    if (_aesKdf(k, d, rounds) != 0) {
      return false;
    }
    data.setAll(0, d.asTypedList(32));
    return true;
  } finally {
    _wipeAndFree(k, 32);
    _wipeAndFree(d, 32);
  }
}

Pointer<Uint8> _copy(Uint8List bytes) {
  final p = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedList(bytes.length).setAll(0, bytes);
  return p;
}

void _wipeAndFree(Pointer<Uint8> p, int length) {
  p.asTypedList(length).fillRange(0, length, 0);
  calloc.free(p);
}
