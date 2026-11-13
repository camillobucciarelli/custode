import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_passkey_signer.dart';
import 'package:password_manager/features/password_manager/data/services/ed25519.dart';
import 'package:password_manager/features/password_manager/data/services/passkey_parser.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:pointycastle/export.dart';

import '../../../../fixtures/passkeys/vectors.dart';

VaultPasskey passkeyFor(String pem) => VaultPasskey(
  relyingPartyId: webauthnIoRpId,
  credentialId: Uint8List.fromList([9, 8, 7]),
  userHandle: Uint8List.fromList([1]),
  privateKeyPem: pem,
  algorithm: PasskeyParser.algorithmOf(pem),
  username: 'alice',
);

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List signedMessage(DesktopPasskeyAssertion a) => Uint8List.fromList([
  ...a.authenticatorData,
  ...SHA256Digest().process(a.clientDataJson),
]);

/// SubjectPublicKeyInfo → the BIT STRING payload.
Uint8List spkiKeyBytes(String pem) =>
    DerNode.parse(PasskeyParser.pemToDer(pem)!).children[1].bitStringBytes;

void main() {
  const signer = DesktopPasskeySigner();
  const challenge = 'dGVzdC1jaGFsbGVuZ2U';
  const origin = 'https://webauthn.io';

  test('authenticatorData matches the vector', () {
    final bytes = DesktopPasskeySigner.authenticatorData(
      rpId: webauthnIoRpId,
      backupEligible: true,
      backupState: true,
    );
    expect(hex(bytes), webauthnIoAuthenticatorDataHex);
    expect(bytes, hasLength(37));
  });

  test('flags drop BE/BS when the stored flags are off', () {
    final bytes = DesktopPasskeySigner.authenticatorData(
      rpId: webauthnIoRpId,
      backupEligible: false,
      backupState: false,
    );
    expect(bytes[32], 0x05);
  });

  test('clientDataJSON is the WebAuthn get serialization', () {
    final json = jsonDecode(
      utf8.decode(
        DesktopPasskeySigner.clientDataJson(
          challenge: challenge,
          origin: origin,
        ),
      ),
    );
    expect(json, {
      'type': 'webauthn.get',
      'challenge': challenge,
      'origin': origin,
      'crossOrigin': false,
    });
  });

  test('ES256 signature verifies with the public key', () {
    final assertion = signer.sign(
      passkey: passkeyFor(es256PrivateKeyPem),
      challenge: challenge,
      origin: origin,
    );
    final domain = ECDomainParameters('prime256v1');
    final q = domain.curve.decodePoint(spkiKeyBytes(es256PublicKeyPem));
    final sig = DerNode.parse(assertion.signature).children;
    final verifier = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, domain)));
    expect(
      verifier.verifySignature(
        signedMessage(assertion),
        ECSignature(sig[0].bigInt, sig[1].bigInt),
      ),
      isTrue,
    );
    expect(assertion.credentialId, [9, 8, 7]);
    expect(assertion.userHandle, [1]);
  });

  test('RS256 signature verifies with the public key', () {
    final assertion = signer.sign(
      passkey: passkeyFor(rs256PrivateKeyPem),
      challenge: challenge,
      origin: origin,
    );
    final rsa = DerNode.parse(spkiKeyBytes(rs256PublicKeyPem)).children;
    final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(
        false,
        PublicKeyParameter<RSAPublicKey>(
          RSAPublicKey(rsa[0].bigInt, rsa[1].bigInt),
        ),
      );
    expect(
      verifier.verifySignature(
        signedMessage(assertion),
        RSASignature(assertion.signature),
      ),
      isTrue,
    );
    expect(assertion.signature, hasLength(256));
  });

  test('EdDSA signs with the raw 64-byte signature', () {
    final assertion = signer.sign(
      passkey: passkeyFor(eddsaPrivateKeyPem),
      challenge: challenge,
      origin: origin,
    );
    // The private key seed inside the fixture's PKCS#8. `ed25519_test.dart`
    // pins the primitive against RFC 8032 and OpenSSL with this same key.
    final seed = PasskeyParser.pemToDer(eddsaPrivateKeyPem)!.sublist(16);
    expect(Ed25519.publicKey(seed), spkiKeyBytes(eddsaPublicKeyPem));
    expect(assertion.signature, hasLength(64));
    expect(assertion.signature, Ed25519.sign(seed, signedMessage(assertion)));
  });

  test('an Ed25519 key that is not a 32-byte seed is a bad key', () {
    // The same PKCS#8 with a 31-byte seed.
    const shortSeedPem = '''
-----BEGIN PRIVATE KEY-----
MC0CAQAwBQYDK2VwBCEEH0/KNjFb/g7qelADCTqrUfJnMgM3wVBpkXgH6uT7QnU=
-----END PRIVATE KEY-----
''';
    expect(
      () => signer.sign(
        passkey: passkeyFor(shortSeedPem),
        challenge: challenge,
        origin: origin,
      ),
      throwsA(
        isA<DesktopPasskeySignException>().having(
          (e) => e.reason,
          'reason',
          VaultPasskeyUnusableReason.badKey,
        ),
      ),
    );
  });

  test('an unusable passkey is refused with its own reason', () {
    final broken = VaultPasskey(
      relyingPartyId: webauthnIoRpId,
      credentialId: Uint8List(0),
      privateKeyPem: truncatedPrivateKeyPem,
      algorithm: VaultPasskeyAlgorithm.unknown,
      unusableReason: VaultPasskeyUnusableReason.badKey,
    );
    expect(
      () => signer.sign(passkey: broken, challenge: challenge, origin: origin),
      throwsA(
        isA<DesktopPasskeySignException>().having(
          (e) => e.reason,
          'reason',
          VaultPasskeyUnusableReason.badKey,
        ),
      ),
    );
  });

  test('exception text carries no key material', () {
    const e = DesktopPasskeySignException(VaultPasskeyUnusableReason.badKey);
    expect(e.toString(), 'DesktopPasskeySignException(badKey)');
  });
}
