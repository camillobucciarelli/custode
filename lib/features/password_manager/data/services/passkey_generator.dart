import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../domain/models/vault_passkey.dart';

/// spec 023 US3 — a newly created WebAuthn credential, ready to be written to
/// the vault and reported to the relying party.
class GeneratedPasskey {
  const GeneratedPasskey({
    required this.passkey,
    required this.attestationObject,
    required this.publicKeyCose,
    required this.authenticatorData,
    required this.publicKeySpki,
  });

  /// What goes into the entry's `KPEX_PASSKEY_*` fields.
  final VaultPasskey passkey;

  /// CBOR `{fmt: "none", attStmt: {}, authData}` — the registration response
  /// the site parses to learn the public key.
  final Uint8List attestationObject;

  /// The COSE_Key the site will verify future assertions with. Kept separately
  /// because some relying parties read it from `getPublicKey()` rather than
  /// out of the attestation object.
  final Uint8List publicKeyCose;

  /// The authenticator data inside [attestationObject]. Android's registration
  /// response JSON carries it as a field of its own.
  final Uint8List authenticatorData;

  /// The public key as DER `SubjectPublicKeyInfo`, which is what
  /// `getPublicKey()` returns to a page.
  final Uint8List publicKeySpki;
}

/// spec 023 US3 — creates ES256 passkeys.
///
/// ES256 only, deliberately. It is the one algorithm every relying party
/// accepts and the one all three platform authenticators verify. A site
/// that accepts only another algorithm is left to the browser.
///
/// Self-attestation is not used either: `fmt: "none"` with an empty statement
/// is what a software authenticator honestly is, and the target relying
/// parties do not require attestation (spec Assumptions).
class PasskeyGenerator {
  PasskeyGenerator({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  static const _credentialIdBytes = 32;

  /// Signature counter, flags and the AAGUID all come from the same decision:
  /// this authenticator does not identify itself and does not count.
  ///
  /// A zero AAGUID is what "no attestation, no model identity" means in
  /// WebAuthn, and it is what a synced software credential can honestly claim.
  static final _aaguid = Uint8List(16);

  GeneratedPasskey generate({
    required String relyingPartyId,
    required String username,
    Uint8List? userHandle,
    DateTime? createdAt,
  }) {
    final keyPair = _generateEs256KeyPair();
    final private = keyPair.privateKey as ECPrivateKey;
    final public = keyPair.publicKey as ECPublicKey;

    final credentialId = _randomBytes(_credentialIdBytes);
    final publicKeyCose = _coseKeyFor(public);
    final authData = _authenticatorData(
      relyingPartyId: relyingPartyId,
      credentialId: credentialId,
      publicKeyCose: publicKeyCose,
    );

    return GeneratedPasskey(
      passkey: VaultPasskey(
        relyingPartyId: relyingPartyId,
        credentialId: credentialId,
        userHandle: userHandle ?? credentialId,
        username: username,
        privateKeyPem: _pkcs8Pem(private, public),
        algorithm: VaultPasskeyAlgorithm.es256,
        // A credential in a synced vault is by definition backed up, and
        // saying otherwise would make relying parties warn the user that their
        // passkey is device-bound when it is not.
        backupEligible: true,
        backupState: true,
        createdAt: createdAt,
      ),
      attestationObject: _attestationObject(authData),
      publicKeyCose: publicKeyCose,
      authenticatorData: authData,
      publicKeySpki: _spkiFor(public),
    );
  }

  AsymmetricKeyPair<PublicKey, PrivateKey> _generateEs256KeyPair() {
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECDomainParameters('prime256v1')),
          _secureRandom(),
        ),
      );
    return generator.generateKeyPair();
  }

  /// pointycastle needs its own `SecureRandom`; seeding it from [_random] is
  /// what lets a test pin the key while production keeps `Random.secure`.
  SecureRandom _secureRandom() {
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    return FortunaRandom()..seed(KeyParameter(seed));
  }

  Uint8List _randomBytes(int length) => Uint8List.fromList(
    List<int>.generate(length, (_) => _random.nextInt(256)),
  );

  /// `rpIdHash ‖ flags ‖ signCount ‖ attestedCredentialData`.
  ///
  /// The AT flag (0x40) is what tells the site this authData carries a new
  /// credential; without it a relying party rejects the registration even
  /// though the bytes that follow are correct.
  Uint8List _authenticatorData({
    required String relyingPartyId,
    required Uint8List credentialId,
    required Uint8List publicKeyCose,
  }) {
    final hash = SHA256Digest().process(
      Uint8List.fromList(utf8.encode(relyingPartyId)),
    );
    const flags = 0x01 | 0x04 | 0x08 | 0x10 | 0x40; // UP|UV|BE|BS|AT
    return Uint8List.fromList([
      ...hash,
      flags,
      0, 0, 0, 0, // signCount
      ..._aaguid,
      (credentialId.length >> 8) & 0xff,
      credentialId.length & 0xff,
      ...credentialId,
      ...publicKeyCose,
    ]);
  }

  /// `SubjectPublicKeyInfo` for a P-256 key: the fixed algorithm header, then
  /// the uncompressed point `04 ‖ x ‖ y`.
  Uint8List _spkiFor(ECPublicKey key) {
    final q = key.Q!;
    return Uint8List.fromList([
      0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
      0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
      0x42, 0x00, 0x04,
      ..._fixedLength(q.x!.toBigInteger()!, 32),
      ..._fixedLength(q.y!.toBigInteger()!, 32),
    ]);
  }

  /// `{1: 2, 3: -7, -1: 1, -2: x, -3: y}` — an EC2 COSE_Key for P-256.
  ///
  /// Map keys are written in WebAuthn's canonical order. Relying parties that
  /// re-encode the key to compare it byte for byte reject any other order.
  Uint8List _coseKeyFor(ECPublicKey key) {
    final q = key.Q!;
    final x = _fixedLength(q.x!.toBigInteger()!, 32);
    final y = _fixedLength(q.y!.toBigInteger()!, 32);
    return Uint8List.fromList([
      0xa5, // map(5)
      0x01, 0x02, // kty: EC2
      0x03, 0x26, // alg: ES256 (-7)
      0x20, 0x01, // crv: P-256
      0x21, 0x58, 0x20, ...x, // x: bytes(32)
      0x22, 0x58, 0x20, ...y, // y: bytes(32)
    ]);
  }

  /// `{fmt: "none", attStmt: {}, authData: …}`, CBOR, canonical order.
  ///
  /// Hand-encoded rather than pulled from a CBOR package: this is the only
  /// CBOR this app writes, its shape is fixed, and a dependency for three
  /// map entries would be more surface than the bytes are worth.
  Uint8List _attestationObject(Uint8List authData) {
    return Uint8List.fromList([
      0xa3, // map(3)
      // "fmt": "none"
      0x63, 0x66, 0x6d, 0x74,
      0x64, 0x6e, 0x6f, 0x6e, 0x65,
      // "attStmt": {}
      0x67, 0x61, 0x74, 0x74, 0x53, 0x74, 0x6d, 0x74,
      0xa0,
      // "authData": bytes(…)
      0x68, 0x61, 0x75, 0x74, 0x68, 0x44, 0x61, 0x74, 0x61,
      ..._cborByteStringHeader(authData.length),
      ...authData,
    ]);
  }

  static List<int> _cborByteStringHeader(int length) {
    if (length < 24) return [0x40 | length];
    if (length < 0x100) return [0x58, length];
    if (length < 0x10000) return [0x59, (length >> 8) & 0xff, length & 0xff];
    throw ArgumentError.value(length, 'length', 'authData is implausibly long');
  }

  /// PKCS#8 `PrivateKeyInfo` wrapping an `ECPrivateKey`, PEM-armoured — the
  /// exact shape `PasskeyParser` and every platform signer read back.
  String _pkcs8Pem(ECPrivateKey private, ECPublicKey public) {
    final d = _fixedLength(private.d!, 32);
    final q = public.Q!;
    // Uncompressed point: 0x04 ‖ X ‖ Y.
    final point = Uint8List.fromList([
      0x04,
      ..._fixedLength(q.x!.toBigInteger()!, 32),
      ..._fixedLength(q.y!.toBigInteger()!, 32),
    ]);

    final ecPrivateKey = _derSequence([
      _derInteger(BigInt.one),
      _derOctetString(d),
      // [0] EXPLICIT parameters — the P-256 OID.
      _derTagged(0xa0, _derOid(const [1, 2, 840, 10045, 3, 1, 7])),
      // [1] EXPLICIT publicKey BIT STRING.
      _derTagged(0xa1, _derBitString(point)),
    ]);

    final privateKeyInfo = _derSequence([
      _derInteger(BigInt.zero),
      _derSequence([
        _derOid(const [1, 2, 840, 10045, 2, 1]), // id-ecPublicKey
        _derOid(const [1, 2, 840, 10045, 3, 1, 7]), // prime256v1
      ]),
      _derOctetString(ecPrivateKey),
    ]);

    final body = base64.encode(privateKeyInfo);
    final lines = <String>[
      for (var i = 0; i < body.length; i += 64)
        body.substring(i, i + 64 > body.length ? body.length : i + 64),
    ];
    return '-----BEGIN PRIVATE KEY-----\n'
        '${lines.join('\n')}\n'
        '-----END PRIVATE KEY-----';
  }

  /// Left-pads to [length]: a scalar with leading zero bytes is still 32 bytes
  /// wide in WebAuthn and in an `ECPrivateKey`, and trimming it produces a key
  /// that parses but verifies against nothing.
  static Uint8List _fixedLength(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  static Uint8List _derLength(int length) {
    if (length < 0x80) return Uint8List.fromList([length]);
    if (length < 0x100) return Uint8List.fromList([0x81, length]);
    return Uint8List.fromList([0x82, (length >> 8) & 0xff, length & 0xff]);
  }

  static Uint8List _derWrap(int tag, List<int> body) =>
      Uint8List.fromList([tag, ..._derLength(body.length), ...body]);

  static Uint8List _derSequence(List<Uint8List> items) =>
      _derWrap(0x30, [for (final item in items) ...item]);

  static Uint8List _derOctetString(Uint8List value) => _derWrap(0x04, value);

  static Uint8List _derTagged(int tag, Uint8List value) => _derWrap(tag, value);

  static Uint8List _derBitString(Uint8List value) =>
      _derWrap(0x03, [0, ...value]);

  static Uint8List _derInteger(BigInt value) {
    if (value == BigInt.zero) return _derWrap(0x02, const [0]);
    var bytes = <int>[];
    var remaining = value;
    while (remaining > BigInt.zero) {
      bytes.insert(0, (remaining & BigInt.from(0xff)).toInt());
      remaining = remaining >> 8;
    }
    if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
    return _derWrap(0x02, bytes);
  }

  static Uint8List _derOid(List<int> arcs) {
    final body = <int>[arcs[0] * 40 + arcs[1]];
    for (final arc in arcs.skip(2)) {
      if (arc < 0x80) {
        body.add(arc);
        continue;
      }
      final chunks = <int>[];
      var remaining = arc;
      while (remaining > 0) {
        chunks.insert(0, remaining & 0x7f);
        remaining >>= 7;
      }
      for (var i = 0; i < chunks.length - 1; i++) {
        body.add(chunks[i] | 0x80);
      }
      body.add(chunks.last);
    }
    return _derWrap(0x06, body);
  }
}
