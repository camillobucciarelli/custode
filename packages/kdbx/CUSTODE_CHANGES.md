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
- `lib/src/kdbx_format.dart`: Twofish runs through `_BlockCopyCipher`, which
  copies each 16-byte input block into a scratch buffer before handing it to
  `TwofishEngine`. pointycastle 4.0.0 `TwofishEngine._decryptBlock` calls
  `_unpack32Le(input.sublist(inOff))`, copying the whole rest of the
  ciphertext for every block, so CBC decryption was quadratic: about 11 s for
  1 MiB, against 11 ms with the adapter. To report upstream to pointycastle
  (`lib/block/twofish.dart`, `_encryptBlock` has the same pattern); drop the
  adapter once a fixed release is out.
- `lib/src/kdbx_format.dart`, `lib/src/kdbx_header.dart`,
  `lib/src/kdbx_file.dart`: a kdbx 4 save reuses the derived (transformed)
  key. It rotates the master seed, the encryption IV and the inner stream key,
  keeps the KDF salt, and builds the new keys from SHA256(masterSeed ||
  transformedKey) and its HMAC counterpart, so it runs no KDF. The KDF runs,
  with a new salt, only when there is no cached key (a new file, a kdbx 3
  upgrade), the credentials changed (the `credentials` setter drops the key),
  or the KDF parameters or the cipher differ from those the key was recorded
  with (`KdbxFile.reusableTransformedKey` compares `kdfFingerprint` and
  `cipher`). `KdbxHeader.generateSalts` takes `rotateKdfSalt`.
  - A deliberate deviation: KeePassXC (`Kdbx4Writer.cpp`) and KeePass 2
    (`KdbxFile.Write.cs`) rotate the KDF salt on every save. The file stays a
    fully valid kdbx 4 file; only the salt is older. Upstream rotated it on
    every save too, so each save paid a full KDF (about 1.2 s at the defaults
    below).
  - `KdbxFile.transformedKeyCredentials` now stays valid across saves, until
    a credential or KDF change. Custode does not store it.
  - If challenge-response (YubiKey) support is added, the KDF salt must rotate
    on every save again: kdbx 4 challenge-response uses it as the challenge.
  - kdbx 3 saves are unchanged (every seed rotates, the KDF runs).
- `lib/src/kdbx_format.dart`: `KdbxFormat.read(bytes, credentials,
  {KdbxFile? keySource})`. When `keySource` was opened with the same
  credentials (hash compared) and its derived key was recorded for the KDF
  parameters and salt of `bytes`, the read reuses that key instead of running
  the KDF. The decrypt and every integrity check run in full and the result
  keeps `credentials`, so it can be saved. Any mismatch ignores `keySource`.
  The app uses it to re-read its own saves (cache misses, reads during an
  edit, sync merge sides and the merge candidate check) without a KDF.
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
- Native KDF (Dart native assets). `hook/build.dart` compiles `src/` with
  `native_toolchain_c` (CBuilder, -O3) into the `kdbx_native` code asset, for
  every target that runs hooks (Android, iOS, macOS, Windows, Linux, and
  `dart test`/`dart build cli`). Web has no FFI and uses
  `native_kdf_stub.dart`. `dart compile exe` rejects programs that import a
  package with hooks: use `dart build cli` for those.
  - `src/argon2/`: phc-winner-argon2 reference implementation (`ref.c`, not
    `opt.c`), CC0 / Apache-2.0, `src/argon2/LICENSE`, upstream commit
    `f57e61e19229e23c4445b85494dbf7c07de721cb` (master, 2021-06-25, tag
    `20190702` + 27). Unmodified; its pthread/Win32 thread support is on, so
    lanes run in parallel.
  - `src/aes_kdf.c`: the AES-KDF rounds (AES-256-ECB of the two 16-byte
    halves) on AES-NI (x86_64) or ARMv8 crypto (arm64), with runtime CPU
    detection. Returns "unsupported" elsewhere (32-bit ARM/x86, CPUs without
    the instructions); the SHA-256 at the end stays in Dart.
  - `lib/src/internal/native_kdf.dart` (+ `_ffi.dart`, `_stub.dart`):
    `@Native` bindings. `NativeArgon2` extends `PointyCastleArgon2` (same
    `Isolate.run`) and falls back to it when the library fails to load or
    returns an error; `KdbxFormat()` now defaults to it.
    `KeyEncrypterKdf.encryptAesSync` tries native AES-KDF first, then the
    pointycastle loop. Inputs are copied to native memory and wiped after.
  - Measured AOT on an Apple M5 Pro (KeePassXC defaults): Argon2id 64 MiB /
    10 / p=4 about 1.3 s Dart against 70 to 110 ms native; AES-KDF
    1,000,000 rounds about 1.1 s Dart against 7 ms native.
  - Dependencies: `native_toolchain_c`, `hooks`, `code_assets`, `ffi`; SDK
    lower bound raised to 3.10 (hooks).
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
  Also save reusing the derived key: every cipher x KDF reopens with a fresh
  read, the master seed and IV change between saves while the KDF salt does
  not, a save after a read runs no KDF, new credentials or KDF parameters run
  it (and new credentials rotate the salt), and a wrong password still fails.
  `test/transformed_key_test.dart` was updated to match. A read with a
  `keySource` runs no KDF and the result saves; other credentials or another
  salt ignore it.
  Also a ~1 MiB Twofish payload that must decrypt in under 2 s.
  Also an AES-KDF file whose `R` is stored as `Int64`, as upstream (and older
  Custode versions) wrote: opens, re-saves, re-opens, header-only read.
- `test/native_kdf_test.dart`: RFC 9106 Argon2d/Argon2id vectors (native via
  `argon2_ctx`, Dart via pointycastle), phc-winner-argon2 `test.c` Argon2id
  vectors through the kdbx path, AES-KDF known answers (computed with Apple
  CommonCrypto), native vs Dart on random parameters (including the
  KeePassXC defaults), and the fallbacks. `test/kdbx4_test_pointycastle.dart`
  passes `PointyCastleArgon2` explicitly.
- `test/deleted_objects_test.dart`: permanent deletion of the recycle bin, then
  a delete to trash on the same file, survives a save and re-read.
- `test/pykeepass/`: KDBX 4 files written by KeePass and KeePassXC, copied from
  pykeepass (GPL-3.0). See its README.
- `.gitignore` for the files `dart pub get` and the upstream tests write.
- Removed the upstream prebuilt FFI Argon2 binaries
  (`argon2_ffi_plugin.dll`, `libargon2_ffi.dylib`, `libargon2_ffi_plugin.so`);
  `test/internal/test_utils.dart` uses the default pure-Dart Argon2 instead,
  and `test/kdbx4_test.dart` no longer requires FFI.
  The README section on building them was replaced by a pointer to the native
  KDF above, and `bin/kdbx.dart` uses the default `KdbxFormat()` instead of
  `Argon2FfiFlutter`.
- `test/kdbx4_test.dart`, `test/kdbx4_test_pointycastle.dart`: dropped the `src/kdbx_header.dart` import, now covered by `package:kdbx/kdbx.dart`.
