import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import 'vault_passkey.dart';

/// A passkey created by the autofill surface while the app was not running,
/// waiting in the native sealed queue to be written to the vault
/// (passkeys-all-platforms spec, "Pending queue format (version 1)").
///
/// [privateKeyPem] is the secret: it is absent from [props] and [toString]
/// (SR-1). Hold an instance only for the adoption write (SR-8).
class PendingPasskeyRegistration extends Equatable {
  const PendingPasskeyRegistration({
    required this.recordId,
    required this.databaseId,
    required this.createdAt,
    required this.rpId,
    required this.credentialId,
    required this.username,
    required this.privateKeyPem,
    required this.algorithm,
    required this.be,
    required this.bs,
    required this.origin,
    this.userHandle,
    this.displayName,
  });

  final String recordId;
  final String databaseId;
  final DateTime createdAt;
  final String rpId;
  final Uint8List credentialId;
  final Uint8List? userHandle;
  final String username;
  final String? displayName;
  final String privateKeyPem;
  final VaultPasskeyAlgorithm algorithm;

  /// Backup eligible / backup state flags the credential was registered with.
  final bool be;
  final bool bs;

  /// `https://example.com` or `android:apk-key-hash:<...>`.
  final String origin;

  /// Parses one record of the `readPendingPasskeyRegistrations` channel
  /// result. Returns `null` for anything malformed: the caller counts it as
  /// unreadable. Never throws and never reports the offending content.
  static PendingPasskeyRegistration? tryFromChannelMap(Object? value) {
    if (value is! Map) return null;
    final recordId = value['recordId'];
    final databaseId = value['databaseId'];
    final createdAtEpochMs = value['createdAtEpochMs'];
    final rpId = value['rpId'];
    final credentialId = _decode(value['credentialId']);
    final rawUserHandle = value['userHandle'];
    final userHandle = _decode(rawUserHandle);
    final username = value['username'];
    final displayName = value['displayName'];
    final privateKeyPem = value['privateKeyPem'];
    final algorithm = _algorithms[value['algorithm']];
    final be = value['be'];
    final bs = value['bs'];
    final origin = value['origin'];
    if (recordId is! String || recordId.isEmpty) return null;
    if (databaseId is! String || databaseId.isEmpty) return null;
    if (createdAtEpochMs is! int) return null;
    if (rpId is! String || rpId.isEmpty) return null;
    if (credentialId == null || credentialId.isEmpty) return null;
    if (rawUserHandle != null && userHandle == null) return null;
    if (username is! String) return null;
    if (displayName is! String?) return null;
    if (privateKeyPem is! String || privateKeyPem.isEmpty) return null;
    if (algorithm == null) return null;
    if (be is! bool || bs is! bool) return null;
    if (origin is! String || origin.isEmpty) return null;
    return PendingPasskeyRegistration(
      recordId: recordId,
      databaseId: databaseId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdAtEpochMs,
        isUtc: true,
      ),
      rpId: rpId,
      credentialId: credentialId,
      userHandle: userHandle,
      username: username,
      displayName: displayName,
      privateKeyPem: privateKeyPem,
      algorithm: algorithm,
      be: be,
      bs: bs,
      origin: origin,
    );
  }

  @override
  List<Object?> get props => [
    recordId,
    databaseId,
    createdAt,
    rpId,
    credentialId,
    userHandle,
    username,
    displayName,
    algorithm,
    be,
    bs,
    origin,
  ];

  @override
  String toString() =>
      'PendingPasskeyRegistration(recordId: $recordId, rpId: $rpId)';
}

/// What the native queue handed over: the records that decrypted and parsed,
/// plus how many did not (failed authentication, missing key, malformed).
/// Unreadable records are never deleted automatically (SR-5).
class PendingPasskeyRegistrations extends Equatable {
  const PendingPasskeyRegistrations({
    this.records = const [],
    this.unreadableCount = 0,
  });

  final List<PendingPasskeyRegistration> records;
  final int unreadableCount;

  @override
  List<Object?> get props => [records, unreadableCount];

  @override
  String toString() =>
      'PendingPasskeyRegistrations(records: ${records.length}, '
      'unreadableCount: $unreadableCount)';
}

const _algorithms = {
  'ES256': VaultPasskeyAlgorithm.es256,
  'EdDSA': VaultPasskeyAlgorithm.eddsa,
  'RS256': VaultPasskeyAlgorithm.rs256,
};

/// base64url, padded or not. `null` when [value] is not a valid encoding.
Uint8List? _decode(Object? value) {
  if (value is! String) return null;
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    return null;
  }
}
