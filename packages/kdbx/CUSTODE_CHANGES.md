# Custode changes to kdbx 2.6.0

Vendored from pub.dev `kdbx` 2.6.0 (https://github.com/authpass/kdbx.dart),
GPL-3.0, see `LICENSE`. Goal: open, create and save every algorithm KeePassXC
offers (AES-256, ChaCha20, Twofish x AES-KDF, Argon2d, Argon2id).

## Library

- `lib/src/internal/consts.dart`: `Cipher.twofish`, UUID
  `ad68f29f-576f-4bb9-a36a-d47af965346c`.
- `lib/src/kdbx_format.dart`: kdbx 4 encrypt/decrypt route Twofish through the
  AES path. The AES-only helpers became `_cbcCipherV4` (AES or Twofish engine in
  CBC with the header IV), `_decryptContentV4` and `_encryptContentV4Cbc`, all
  with PKCS7 padding via `AesHelper`. kdbx 3 stays AES-only.
- `lib/src/crypto/key_encrypter_kdf.dart`:
  - `KdfType.Argon2id`, UUID `9e298b19-56db-4773-b23d-fc3ec6f0a1e6`
    (`KdfType.Argon2` keeps its name and means Argon2d).
  - The kdbx 4 AES-KDF UUID `7c02bb82-79a7-4ac0-927d-114a00648238` is read as
    AES-KDF, as KeePassXC does. We still write the classic
    `c9d9f39a-628a-4460-bf74-0d08c18a4fea`, as KeePass and KeePassXC do.
  - Argon2 passes the type to the Argon2 implementation (0 = d, 2 = id) instead
    of a hardcoded 0.
  - `KdfField.rounds` is `UInt64` instead of `Int64`, the type KeePass and
    KeePassXC write; KeePass 2 does not read an `Int64` round count.
- `lib/src/kdbx_header.dart`:
  - `KdbxHeader.createV4({Cipher cipher = Cipher.aes, KdbxKdfConfig? kdf})`.
    Without `kdf` the upstream defaults stay (Argon2d, 1 MiB, 2 iterations,
    parallelism 1).
  - `KdbxHeader.readFromBytes(Uint8List)`: outer header only, no credentials.
  - `KdbxHeader.kdfConfig`: KDF type and cost of an open or locked file (kdbx 3
    reports AES-KDF with its transform rounds).
  - `KdbxKdfConfig` (sealed), `KdbxAesKdfConfig`, `KdbxArgon2KdfConfig`.
- `lib/src/kdbx_dao.dart` / `lib/src/kdbx_file.dart`: `deletePermanently` of
  the recycle bin, or of a group containing it, calls the new
  `KdbxFile.internalForgetRecycleBin()`, which sets `meta.recycleBinUUID` to
  NIL and clears the memoised `recycleBin`. Upstream kept both, so a later
  `deleteEntry`/`deleteGroup` on the same open file moved the object into the
  detached group and the next save dropped it.
- `lib/src/internal/pointycastle_argon2.dart`: `argon2Async` runs in
  `Isolate.run` (inline on web), so key derivation no longer blocks the
  calling (UI) isolate. AES-KDF already ran in an isolate upstream.
- `lib/kdbx.dart` also exports `Cipher`, `KdbxHeader`, the three
  `Kdbx*KdfConfig` types, `VarDictionary` and `PointyCastleArgon2` (the app's
  tests subclass it to count key derivations).

## Defaults for new databases

From KeePassXC `develop` (`src/crypto/kdf/Argon2Kdf.h`, `src/crypto/kdf/Kdf.h`):

| KDF | Default |
| --- | --- |
| Argon2d / Argon2id | 64 MiB (`ARGON2_DEFAULT_MEMORY = 1 << 16` KiB), 10 iterations (`ARGON2_DEFAULT_ROUNDS`), parallelism 4 (`ARGON2_DEFAULT_PARALLELISM`), version 0x13 |
| AES-KDF | 1,000,000 rounds (`KDF_DEFAULT_ROUNDS`) |

KeePassXC benchmarks the iteration count to about one second and lowers
parallelism to the CPU count; these are fixed values instead. Measured with
this package's pure-Dart Argon2 (pointycastle), AOT on an Apple Silicon Mac:
Argon2 defaults about 1.2 s, AES-KDF defaults about 1.1 s. Slower phones take
several times longer.

## Tests and fixtures

- `test/custode_ciphers_test.dart`: round trip of every cipher x KDF, header
  only read, Argon2id known answer through the KDF path (phc-winner-argon2
  `src/test.c`), Twofish-256 known answer (Bouncy Castle `TwofishTest`), and
  third-party files.
  Also an AES-KDF file whose `R` is stored as `Int64`, as upstream (and older
  Custode versions) wrote: opens, re-saves, re-opens, header-only read.
- `test/deleted_objects_test.dart`: permanent deletion of the recycle bin, then
  a delete to trash on the same file, survives a save and re-read.
- `test/pykeepass/`: KDBX 4 files written by KeePass and KeePassXC, copied from
  pykeepass (GPL-3.0). See its README.
- `.gitignore` for the files `dart pub get` and the upstream tests write.
- Removed the upstream prebuilt FFI Argon2 binaries
  (`argon2_ffi_plugin.dll`, `libargon2_ffi.dylib`, `libargon2_ffi_plugin.so`);
  `test/internal/test_utils.dart` uses the default pure-Dart Argon2 instead,
  and `test/kdbx4_test.dart` no longer requires FFI.
  The README section on building them is upstream text and no longer applies.
- `test/kdbx4_test.dart`, `test/kdbx4_test_pointycastle.dart`: dropped the `src/kdbx_header.dart` import, now covered by `package:kdbx/kdbx.dart`.
