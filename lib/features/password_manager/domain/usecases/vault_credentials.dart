import 'dart:typed_data';

import 'package:kdbx/kdbx.dart';

/// spec 015 FR-2/FR-12: the one place that turns a (password, key-file)
/// pair into KDBX [Credentials], shared by create and unlock so the matrix
/// they accept is identical.
///
/// An empty password means "no password factor" and contributes nothing to
/// the composite. Passing `ProtectedValue.fromString('')` instead would make
/// a key-only vault openable only with an explicit empty string, which is a
/// different (and wrong) credential. A whitespace-only password such as `" "`
/// is still a real password factor, as KeePassXC treats it, so it is not
/// trimmed.
Credentials composeVaultCredentials({
  required String password,
  Uint8List? keyFileBytes,
}) {
  return Credentials.composite(
    password.isEmpty ? null : ProtectedValue.fromString(password),
    keyFileBytes,
  );
}
