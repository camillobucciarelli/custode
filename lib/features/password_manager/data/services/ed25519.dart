import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Ed25519 signing (RFC 8032, section 5.1.6), for the desktop passkey signer.
///
/// `pointycastle` 4.0.0 has no Ed25519, and the app signs in Dart on Windows
/// and Linux, so an Ed25519 passkey could not sign in there. This is the
/// signing half only: the relying party verifies, the app never does.
///
/// The arithmetic uses `BigInt`, which is not constant time. That is the same
/// property the ES256 and RS256 paths have through `pointycastle`, and the
/// signature is made only after the user confirms the sign-in in the app.
///
/// The tests pin the RFC 8032 section 7.1 vectors and a signature made by
/// OpenSSL with the fixture key. Ed25519 is deterministic, so a wrong step
/// changes the output.
abstract final class Ed25519 {
  static final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _l =
      (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');
  static final BigInt _d =
      (-BigInt.from(121665) * BigInt.from(121666).modInverse(_p)) % _p;

  static final BigInt _baseY =
      (BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p;
  static final BigInt _baseX = BigInt.parse(
    '15112221349535400772501151409588531511454012693041857206046113283949847762202',
  );
  static final _Point _base = _Point(
    _baseX,
    _baseY,
    BigInt.one,
    (_baseX * _baseY) % _p,
  );

  /// The 32-byte public key of a 32-byte private key seed.
  static Uint8List publicKey(Uint8List seed) {
    final hash = _expand(seed);
    return _encodePoint(_base * _scalar(hash));
  }

  /// The 64-byte signature `R ‖ S` of [message].
  static Uint8List sign(Uint8List seed, Uint8List message) {
    final hash = _expand(seed);
    final a = _scalar(hash);
    final prefix = Uint8List.sublistView(hash, 32, 64);
    final encodedA = _encodePoint(_base * a);

    final r = _littleEndian(_sha512([prefix, message])) % _l;
    final encodedR = _encodePoint(_base * r);
    final k = _littleEndian(_sha512([encodedR, encodedA, message])) % _l;
    final s = (r + k * a) % _l;

    return Uint8List.fromList([...encodedR, ..._toLittleEndian(s)]);
  }

  static Uint8List _expand(Uint8List seed) {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed.length', 'must be 32');
    }
    return _sha512([seed]);
  }

  /// The clamped secret scalar from the lower half of the expanded seed.
  static BigInt _scalar(Uint8List hash) {
    final lower = Uint8List.fromList(Uint8List.sublistView(hash, 0, 32));
    lower[0] &= 0xf8;
    lower[31] &= 0x7f;
    lower[31] |= 0x40;
    return _littleEndian(lower);
  }

  static Uint8List _sha512(List<Uint8List> parts) {
    final digest = SHA512Digest();
    for (final part in parts) {
      digest.update(part, 0, part.length);
    }
    final out = Uint8List(64);
    digest.doFinal(out, 0);
    return out;
  }

  static BigInt _littleEndian(Uint8List bytes) {
    var value = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      value = (value << 8) | BigInt.from(bytes[i]);
    }
    return value;
  }

  static Uint8List _toLittleEndian(BigInt value) {
    final out = Uint8List(32);
    var rest = value;
    final mask = BigInt.from(0xff);
    for (var i = 0; i < 32; i++) {
      out[i] = (rest & mask).toInt();
      rest >>= 8;
    }
    return out;
  }

  /// `y` in little-endian, with the sign of `x` in the top bit.
  static Uint8List _encodePoint(_Point point) {
    final inverse = point.z.modInverse(_p);
    final x = (point.x * inverse) % _p;
    final y = (point.y * inverse) % _p;
    final out = _toLittleEndian(y);
    if (x.isOdd) out[31] |= 0x80;
    return out;
  }
}

/// A point in extended twisted Edwards coordinates (RFC 8032, section 5.1.4).
class _Point {
  const _Point(this.x, this.y, this.z, this.t);

  static final _Point identity = _Point(
    BigInt.zero,
    BigInt.one,
    BigInt.one,
    BigInt.zero,
  );

  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;

  _Point operator +(_Point other) {
    final p = Ed25519._p;
    final two = BigInt.two;
    final a = ((y - x) * (other.y - other.x)) % p;
    final b = ((y + x) * (other.y + other.x)) % p;
    final c = (t * two * Ed25519._d * other.t) % p;
    final d = (z * two * other.z) % p;
    final e = b - a;
    final f = d - c;
    final g = d + c;
    final h = b + a;
    return _Point((e * f) % p, (g * h) % p, (f * g) % p, (e * h) % p);
  }

  _Point operator *(BigInt scalar) {
    var result = identity;
    var addend = this;
    var rest = scalar;
    while (rest > BigInt.zero) {
      if (rest.isOdd) result = result + addend;
      addend = addend + addend;
      rest >>= 1;
    }
    return result;
  }
}
