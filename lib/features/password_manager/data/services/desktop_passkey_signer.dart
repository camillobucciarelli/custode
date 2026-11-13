import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../domain/models/vault_passkey.dart';
import 'ed25519.dart';
import 'passkey_parser.dart';

/// What the browser extension needs to answer `navigator.credentials.get`
/// (spec 023, `contracts/passkey_platform_bridges.md`). Never carries the key.
class DesktopPasskeyAssertion {
  const DesktopPasskeyAssertion({
    required this.credentialId,
    required this.authenticatorData,
    required this.signature,
    required this.clientDataJson,
    this.userHandle,
  });

  final Uint8List credentialId;
  final Uint8List authenticatorData;
  final Uint8List signature;
  final Uint8List clientDataJson;
  final Uint8List? userHandle;
}

class DesktopPasskeySignException implements Exception {
  const DesktopPasskeySignException(this.reason);

  final VaultPasskeyUnusableReason reason;

  @override
  String toString() => 'DesktopPasskeySignException(${reason.name})';
}

/// Spec 023 T014 — signs WebAuthn assertions in the app process for the
/// desktop bridge (plan D5/D6). ES256 and RS256 through `pointycastle`,
/// EdDSA through [Ed25519], because `pointycastle` has none (research R10).
/// No CBOR: assertions need none.
class DesktopPasskeySigner {
  const DesktopPasskeySigner();

  static const _flagUserPresent = 0x01;
  static const _flagUserVerified = 0x04;
  static const _flagBackupEligible = 0x08;
  static const _flagBackupState = 0x10;

  /// `rpIdHash ‖ flags ‖ signCount(0)` — 37 bytes.
  static Uint8List authenticatorData({
    required String rpId,
    required bool backupEligible,
    required bool backupState,
  }) {
    final hash = SHA256Digest().process(Uint8List.fromList(utf8.encode(rpId)));
    var flags = _flagUserPresent | _flagUserVerified;
    if (backupEligible) flags |= _flagBackupEligible;
    if (backupState) flags |= _flagBackupState;
    return Uint8List.fromList([...hash, flags, 0, 0, 0, 0]);
  }

  /// `challenge` is the base64url the site supplied; it is passed through
  /// verbatim, as the WebAuthn client data serialization requires.
  ///
  /// [type] is `webauthn.get` for a sign-in and `webauthn.create` for a
  /// registration (spec 023 US3); a relying party checks it and rejects the
  /// other one.
  static Uint8List clientDataJson({
    required String challenge,
    required String origin,
    String type = 'webauthn.get',
  }) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'type': type,
        'challenge': challenge,
        'origin': origin,
        'crossOrigin': false,
      }),
    ),
  );

  DesktopPasskeyAssertion sign({
    required VaultPasskey passkey,
    required String challenge,
    required String origin,
  }) {
    if (!passkey.usable) {
      throw DesktopPasskeySignException(passkey.unusableReason!);
    }
    final authData = authenticatorData(
      rpId: passkey.relyingPartyId,
      backupEligible: passkey.backupEligible,
      backupState: passkey.backupState,
    );
    final clientData = clientDataJson(challenge: challenge, origin: origin);
    final clientDataHash = SHA256Digest().process(clientData);
    final message = Uint8List.fromList([...authData, ...clientDataHash]);

    final Uint8List signature;
    switch (passkey.algorithm) {
      case VaultPasskeyAlgorithm.es256:
        signature = _signEs256(passkey.privateKeyPem, message);
      case VaultPasskeyAlgorithm.rs256:
        signature = _signRs256(passkey.privateKeyPem, message);
      case VaultPasskeyAlgorithm.eddsa:
        signature = _signEd25519(passkey.privateKeyPem, message);
      case VaultPasskeyAlgorithm.unknown:
        throw const DesktopPasskeySignException(
          VaultPasskeyUnusableReason.unsupportedAlgorithm,
        );
    }
    return DesktopPasskeyAssertion(
      credentialId: passkey.credentialId,
      authenticatorData: authData,
      signature: signature,
      clientDataJson: clientData,
      userHandle: passkey.userHandle,
    );
  }

  /// PKCS#8 → ECPrivateKey `SEQUENCE { version, privateKey OCTET STRING, … }`.
  static Uint8List _signEs256(String pem, Uint8List message) {
    final d = _pkcs8PrivateKey(pem).children[1].bigInt;
    final domain = ECDomainParameters('prime256v1');
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, domain)));
    final sig = signer.generateSignature(message) as ECSignature;
    return _derSequence([_derInteger(sig.r), _derInteger(sig.s)]);
  }

  /// PKCS#8 → RSAPrivateKey `SEQUENCE { version, n, e, d, p, q, … }`.
  static Uint8List _signRs256(String pem, Uint8List message) {
    final key = _pkcs8PrivateKey(pem).children;
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(
        true,
        PrivateKeyParameter<RSAPrivateKey>(
          RSAPrivateKey(
            key[1].bigInt,
            key[3].bigInt,
            key[4].bigInt,
            key[5].bigInt,
          ),
        ),
      );
    return signer.generateSignature(message).bytes;
  }

  /// PKCS#8 → CurvePrivateKey `OCTET STRING` holding the 32-byte seed
  /// (RFC 8410, section 7). The signature is the raw 64 bytes `R ‖ S`.
  static Uint8List _signEd25519(String pem, Uint8List message) {
    final key = _pkcs8PrivateKey(pem);
    if (key.tag != DerNode.octetString || key.content.length != 32) {
      throw const DesktopPasskeySignException(
        VaultPasskeyUnusableReason.badKey,
      );
    }
    return Ed25519.sign(key.content, message);
  }

  /// The algorithm-specific structure inside PKCS#8's `privateKey` OCTET
  /// STRING.
  static DerNode _pkcs8PrivateKey(String pem) {
    final der = PasskeyParser.pemToDer(pem);
    if (der == null) {
      throw const DesktopPasskeySignException(
        VaultPasskeyUnusableReason.badKey,
      );
    }
    try {
      return DerNode.parse(DerNode.parse(der).children[2].content);
    } on FormatException {
      throw const DesktopPasskeySignException(
        VaultPasskeyUnusableReason.badKey,
      );
    } on RangeError {
      throw const DesktopPasskeySignException(
        VaultPasskeyUnusableReason.badKey,
      );
    }
  }

  static Uint8List _derInteger(BigInt value) {
    var bytes = _bigIntBytes(value);
    if (bytes[0] & 0x80 != 0) bytes = Uint8List.fromList([0, ...bytes]);
    return Uint8List.fromList([
      DerNode.integer,
      ..._derLength(bytes.length),
      ...bytes,
    ]);
  }

  static Uint8List _derSequence(List<Uint8List> items) {
    final body = Uint8List.fromList([for (final i in items) ...i]);
    return Uint8List.fromList([
      DerNode.sequence,
      ..._derLength(body.length),
      ...body,
    ]);
  }

  static List<int> _derLength(int length) => length < 0x80
      ? [length]
      : [0x81, length]; // ponytail: signatures are < 256 bytes here

  static Uint8List _bigIntBytes(BigInt value) {
    final hex = value.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    return Uint8List.fromList([
      for (var i = 0; i < padded.length; i += 2)
        int.parse(padded.substring(i, i + 2), radix: 16),
    ]);
  }
}
