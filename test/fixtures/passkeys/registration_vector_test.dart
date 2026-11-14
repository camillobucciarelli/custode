// T010 (passkeys on all platforms) — the shared vectors the Dart, Swift and
// Kotlin registration encoders must all reproduce byte for byte.
//
// `registration_vector.json` and `pending_record_v1.json` are derived here
// from `PasskeyGenerator` and pointycastle AES-256-GCM; this test fails when
// the committed files differ from what the Dart side produces today.
//
// To regenerate after a deliberate format change:
//
//   UPDATE_PASSKEY_VECTORS=1 fvm flutter test test/fixtures/passkeys/registration_vector_test.dart
//
// then update the Swift and Kotlin encoders in the same change, since they are
// pinned to the same files.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/passkey_generator.dart';
import 'package:password_manager/features/password_manager/data/services/passkey_parser.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:pointycastle/export.dart';

const _fixtureNote =
    'FIXTURE ONLY. The key material in this file is public test data. It must '
    'never be used for a real credential or to protect real data.';

const _rpId = 'example.com';

/// Yields 0x00, 0x01, 0x02, ... so the generator's output is pinned by this
/// file alone, not by the unspecified sequence of `Random(seed)`.
///
/// `PasskeyGenerator` draws 32 bytes to seed its key generator, then 32 for
/// the credential id, which therefore is 0x20..0x3f.
class _CountingRandom implements Random {
  var _next = 0;

  @override
  int nextInt(int max) => _next++ % max;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _base64UrlUnpadded(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _pretty(Map<String, Object?> json) =>
    '${const JsonEncoder.withIndent('  ').convert(json)}\n';

GeneratedPasskey _generate() =>
    PasskeyGenerator(random: _CountingRandom()).generate(
      relyingPartyId: _rpId,
      username: 'alice',
      userHandle: Uint8List.fromList(List.generate(16, (i) => 0xa0 + i)),
    );

Map<String, Object?> _registrationVector(GeneratedPasskey created) {
  final cose = created.publicKeyCose;
  // authData is the attestation object minus its fixed CBOR prefix:
  // a3 "fmt" "none" "attStmt" a0 "authData" 58 <len>.
  final authData = created.attestationObject.sublist(30);
  return {
    'note': _fixtureNote,
    'rpId': _rpId,
    'privateKeyPkcs8Pem': created.passkey.privateKeyPem,
    'publicKeyXHex': _hex(cose.sublist(10, 42)),
    'publicKeyYHex': _hex(cose.sublist(45, 77)),
    'credentialIdHex': _hex(created.passkey.credentialId),
    'rpIdHashHex': _hex(authData.sublist(0, 32)),
    'flagsHex': _hex(authData.sublist(32, 33)),
    'signCount': 0,
    'aaguidHex': _hex(authData.sublist(37, 53)),
    'coseKeyHex': _hex(cose),
    'authDataHex': _hex(authData),
    'attestationObjectHex': _hex(created.attestationObject),
  };
}

Map<String, Object?> _pendingRecord(GeneratedPasskey created) {
  final key = Uint8List.fromList(List.generate(32, (i) => 0x40 + i));
  final nonce = Uint8List.fromList(List.generate(12, (i) => 0x80 + i));

  const version = 1;
  const recordId = '00000000-0000-4000-8000-000000000001';
  const databaseId = 'fixture-database-id';
  const createdAtEpochMs = 1767225600000;
  // Insertion order is the serialised key order.
  final payload = <String, Object?>{
    'rpId': created.passkey.relyingPartyId,
    'credentialId': _base64UrlUnpadded(created.passkey.credentialId),
    'userHandle': _base64UrlUnpadded(created.passkey.userHandle!),
    'username': created.passkey.username,
    'displayName': 'Alice',
    'privateKeyPem': created.passkey.privateKeyPem,
    'algorithm': 'ES256',
    'be': true,
    'bs': true,
    'origin': 'https://example.com',
  };
  final payloadJson = jsonEncode(payload);

  // The envelope repeats rpId, credentialId and username in the clear so that
  // native code can list and match pending records without opening the seal.
  final rpId = payload['rpId']! as String;
  final credentialId = payload['credentialId']! as String;
  final username = payload['username']! as String;
  final usernameB64 = _base64UrlUnpadded(utf8.encode(username));
  final aad =
      '$version|$recordId|$databaseId|$createdAtEpochMs|$rpId|$credentialId|'
      '$usernameB64';

  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(key),
        128,
        nonce,
        Uint8List.fromList(utf8.encode(aad)),
      ),
    );
  final ciphertextAndTag = cipher.process(
    Uint8List.fromList(utf8.encode(payloadJson)),
  );

  return {
    'note': _fixtureNote,
    'payloadSerialisation':
        'payloadJson is the exact plaintext that was sealed: UTF-8, compact '
        '(no whitespace between tokens), keys in payloadKeyOrder, "/" not '
        'escaped, newlines inside privateKeyPem escaped as \\n. Absent '
        'userHandle or displayName are written as JSON null, not omitted. A '
        'writer should emit this shape; a reader must parse the decrypted '
        'JSON and not compare its bytes, since records sealed by another '
        'encoder may differ in escaping.',
    'payloadKeyOrder': payload.keys.toList(),
    'envelopeKeyOrder': [
      'version',
      'algorithm',
      'keyId',
      'recordId',
      'databaseId',
      'createdAtEpochMs',
      'rpId',
      'credentialId',
      'username',
      'sealed',
    ],
    'sealedLayout':
        'base64 (standard, padded) of nonce (12 bytes) + ciphertext + tag '
        '(16 bytes); AES-256-GCM, AAD = UTF-8 of aad.',
    'aadLayout':
        'aad is the UTF-8 bytes of '
        'version|recordId|databaseId|createdAtEpochMs|rpId|credentialId|'
        'usernameB64, joined with "|" and built from the envelope fields. '
        'createdAtEpochMs is written in decimal, credentialId is the '
        'envelope string as is (unpadded base64url), and usernameB64 is the '
        'unpadded base64url of the username UTF-8 bytes (aadUsernameB64 '
        'here), so a username containing "|" cannot make two envelopes share '
        'an AAD. The envelope rpId, credentialId and username are plaintext '
        'so records can be listed and matched without decrypting; they are '
        'authenticated by the AAD, so altering any of them makes the seal '
        'fail to open. After opening, a reader must also check that the '
        'payload rpId, credentialId and username equal the envelope values '
        'and treat any mismatch as an unreadable record.',
    'aesKeyHex': _hex(key),
    'nonceHex': _hex(nonce),
    'aad': aad,
    'aadUsernameB64': usernameB64,
    'payloadJson': payloadJson,
    'envelope': {
      'version': version,
      'algorithm': 'AES-256-GCM',
      'keyId': 'passkey-pending-v1',
      'recordId': recordId,
      'databaseId': databaseId,
      'createdAtEpochMs': createdAtEpochMs,
      'rpId': rpId,
      'credentialId': credentialId,
      'username': username,
      'sealed': base64.encode([...nonce, ...ciphertextAndTag]),
    },
  };
}

void _expectCommitted(String path, Map<String, Object?> json) {
  final file = File(path);
  final expected = _pretty(json);
  if (Platform.environment['UPDATE_PASSKEY_VECTORS'] == '1') {
    file.writeAsStringSync(expected);
    return;
  }
  expect(
    // Windows checkouts may convert LF to CRLF; the JSON content is what matters.
    file.readAsStringSync().replaceAll('\r\n', '\n'),
    expected,
    reason:
        '$path is out of date. If the change is deliberate, rerun with '
        'UPDATE_PASSKEY_VECTORS=1 and update the Swift and Kotlin encoders.',
  );
}

void main() {
  const directory = 'test/fixtures/passkeys';

  test('registration_vector.json is what PasskeyGenerator produces', () {
    _expectCommitted(
      '$directory/registration_vector.json',
      _registrationVector(_generate()),
    );
  });

  test('pending_record_v1.json is what AES-256-GCM produces', () {
    _expectCommitted(
      '$directory/pending_record_v1.json',
      _pendingRecord(_generate()),
    );
  });

  // The slices above assume the generator's layout. These pin that assumption
  // to independent facts, so a shifted offset cannot regenerate into a vector
  // that is self-consistent and wrong.
  test('the registration vector agrees with independent derivations', () {
    final vector = _registrationVector(_generate());

    expect(
      vector['rpIdHashHex'],
      _hex(crypto.sha256.convert(utf8.encode(_rpId)).bytes),
    );
    expect(vector['flagsHex'], '5d'); // UP|UV|BE|BS|AT
    expect(vector['aaguidHex'], '0' * 32);
    expect(vector['credentialIdHex'], _hex(List.generate(32, (i) => 0x20 + i)));
    expect(
      vector['authDataHex'],
      '${vector['rpIdHashHex']}5d00000000${'0' * 32}0020'
      '${vector['credentialIdHex']}${vector['coseKeyHex']}',
    );
    expect(
      vector['coseKeyHex'],
      'a5010203262001215820${vector['publicKeyXHex']}'
      '225820${vector['publicKeyYHex']}',
    );

    // x and y really are the public point of the private key in the PEM.
    final pem = vector['privateKeyPkcs8Pem']! as String;
    expect(PasskeyParser.algorithmOf(pem), VaultPasskeyAlgorithm.es256);
    final der = base64.decode(
      pem.split('\n').where((line) => !line.startsWith('-----')).join(),
    );
    // Fixed PKCS#8 P-256 layout: d at 36..68, uncompressed point after 0x04.
    final d = BigInt.parse(_hex(der.sublist(36, 68)), radix: 16);
    final q = (ECDomainParameters('prime256v1').G * d)!;
    expect(
      q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0'),
      vector['publicKeyXHex'],
    );
    expect(
      q.y!.toBigInteger()!.toRadixString(16).padLeft(64, '0'),
      vector['publicKeyYHex'],
    );
  });

  test('the sealed fixture decrypts back to payloadJson', () {
    final record = _pendingRecord(_generate());
    final envelope = record['envelope']! as Map<String, Object?>;
    final sealed = base64.decode(envelope['sealed']! as String);

    Uint8List open(String aad) {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(
              Uint8List.fromList(List.generate(32, (i) => 0x40 + i)),
            ),
            128,
            sealed.sublist(0, 12),
            Uint8List.fromList(utf8.encode(aad)),
          ),
        );
      return cipher.process(sealed.sublist(12));
    }

    final aad = record['aad']! as String;
    expect(utf8.decode(open(aad)), record['payloadJson']);
    // Re-binding to another vault changes the AAD and must not authenticate.
    expect(
      () => open(aad.replaceFirst('fixture-database-id', 'other-database')),
      throwsA(anything),
    );

    // The AAD is rebuilt from the envelope, so the plaintext fields native
    // code matches on are authenticated: editing rpId alone breaks the seal.
    String aadOf(Map<String, Object?> e) => [
      e['version'],
      e['recordId'],
      e['databaseId'],
      e['createdAtEpochMs'],
      e['rpId'],
      e['credentialId'],
      _base64UrlUnpadded(utf8.encode(e['username']! as String)),
    ].join('|');

    expect(aadOf(envelope), aad);
    expect(
      () => open(aadOf({...envelope, 'rpId': 'evil.example'})),
      throwsA(anything),
    );

    // The envelope copies agree with what was sealed.
    final payload = jsonDecode(utf8.decode(open(aad))) as Map<String, Object?>;
    for (final field in ['rpId', 'credentialId', 'username']) {
      expect(envelope[field], payload[field]);
    }
    expect(record['envelopeKeyOrder'], envelope.keys.toList());
  });
}
