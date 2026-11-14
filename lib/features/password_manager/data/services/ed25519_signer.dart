import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Ed25519 signing, RFC 8032 section 5.1.6, SHA-512 from `package:crypto`.
/// No installed dependency offers Ed25519 (pointycastle 4.0.0 has none).
///
/// ponytail: BigInt arithmetic, not constant-time. Fine for a per-user-action
/// passkey assertion on a desktop; move to a constant-time native or FFI
/// implementation if signing ever runs in bulk or on attacker-timed input.
class Ed25519Signer {
  const Ed25519Signer._();

  /// [seed] is the 32-byte private key; anything else is a `FormatException`.
  /// The key is never kept, logged or printed.
  static Uint8List sign(Uint8List seed, Uint8List message) {
    if (seed.length != 32) throw const FormatException('Ed25519 seed length');
    final h = sha512.convert(seed).bytes;
    final a = _le(Uint8List.fromList(h.sublist(0, 32)));
    final s =
        (a & ((BigInt.one << 254) - BigInt.from(8))) | (BigInt.one << 254);
    final publicKey = _encode(_mul(s, _base));
    final r = _le(_hash([...h.sublist(32), ...message])) % _l;
    final rEnc = _encode(_mul(r, _base));
    final k = _le(_hash([...rEnc, ...publicKey, ...message])) % _l;
    final sig = (r + k * s) % _l;
    return Uint8List.fromList([...rEnc, ..._leBytes(sig, 32)]);
  }

  static final _p = (BigInt.one << 255) - BigInt.from(19);
  static final _l =
      (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');
  static final _d =
      (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
  static final _base = (
    BigInt.parse(
      '15112221349535400772501151409588531511454012693041857206046113283949847762202',
    ),
    BigInt.parse(
      '46316835694926478169428394003475163141307993866256225615783033603165251855960',
    ),
    BigInt.one,
    (BigInt.parse(
              '15112221349535400772501151409588531511454012693041857206046113283949847762202',
            ) *
            BigInt.parse(
              '46316835694926478169428394003475163141307993866256225615783033603165251855960',
            )) %
        _p,
  );

  // Extended coordinates (X, Y, Z, T), RFC 8032 section 5.1.4.
  static (BigInt, BigInt, BigInt, BigInt) _add(
    (BigInt, BigInt, BigInt, BigInt) p,
    (BigInt, BigInt, BigInt, BigInt) q,
  ) {
    final a = (p.$2 - p.$1) * (q.$2 - q.$1) % _p;
    final b = (p.$2 + p.$1) * (q.$2 + q.$1) % _p;
    final c = p.$4 * BigInt.two * _d * q.$4 % _p;
    final d = p.$3 * BigInt.two * q.$3 % _p;
    final e = b - a, f = d - c, g = d + c, h = b + a;
    return (e * f % _p, g * h % _p, f * g % _p, e * h % _p);
  }

  static (BigInt, BigInt, BigInt, BigInt) _mul(
    BigInt n,
    (BigInt, BigInt, BigInt, BigInt) point,
  ) {
    var q = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
    var addend = point;
    for (var i = 0; i < n.bitLength; i++) {
      if ((n >> i).isOdd) q = _add(q, addend);
      addend = _add(addend, addend);
    }
    return q;
  }

  static Uint8List _encode((BigInt, BigInt, BigInt, BigInt) point) {
    final zInv = point.$3.modInverse(_p);
    final x = point.$1 * zInv % _p;
    final y = point.$2 * zInv % _p;
    return _leBytes(y | (x.isOdd ? BigInt.one << 255 : BigInt.zero), 32);
  }

  static Uint8List _hash(List<int> bytes) =>
      Uint8List.fromList(sha512.convert(bytes).bytes);

  static BigInt _le(Uint8List bytes) {
    var n = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      n = (n << 8) | BigInt.from(bytes[i]);
    }
    return n;
  }

  static Uint8List _leBytes(BigInt n, int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = ((n >> (8 * i)) & BigInt.from(0xff)).toInt();
    }
    return out;
  }
}
