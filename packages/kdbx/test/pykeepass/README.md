# pykeepass fixtures

Copied unchanged from https://github.com/libkeepass/pykeepass (`tests/`,
branch `master`, GPL-3.0, same license as this package) to test that we open
KDBX 4 files written by other KeePass implementations.

| File | Cipher | KDF | Credentials | Generator |
| --- | --- | --- | --- | --- |
| `test4_twofish.kdbx` | Twofish | Argon2d | `password` + `test4.key` | KeePass |
| `test4_chacha20.kdbx` | ChaCha20 | Argon2d | `password` + `test4.key` | KeePass |
| `test4_aeskdf.kdbx` | AES-256 | AES-KDF | `password` + `test4.key` | KeePass |
| `test4_argon2id.kdbx` | AES-256 | Argon2id | `password` | KeePassXC |
