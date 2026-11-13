import 'dart:convert';

import 'package:flutter/services.dart';

import '../../domain/models/apple_autofill_v2_models.dart';
import '../../domain/models/vault_entry.dart';
import 'apple_autofill_v2_coordinator.dart';
import 'passkey_coordinator.dart';

/// Why a platform registration can or cannot go on.
enum PasskeyRegistrationStatus {
  /// A vault is open and unlocked.
  ready,

  /// No vault is open in the app.
  noVault,

  /// A vault is open but its session is locked.
  locked,

  /// A passkey for the same site and account exists and the caller did not
  /// ask to replace it.
  alreadyExists,

  /// The backup or the vault write failed. Nothing was created.
  failed,

  /// The vault holds the new passkey.
  done,
}

/// spec 023 slice 4 (D11) — the app half of creating a passkey from Android
/// Credential Manager or the macOS AutoFill extension.
///
/// The platform surface owns the confirmation and the user presence check.
/// This module owns the write and shows nothing: `prepare` says whether a
/// write can happen and whether it replaces a passkey, `commit` writes and
/// returns what the relying party needs. The private key never leaves the
/// app, and nothing is returned before the vault write completes (FR-020).
///
/// It joins the autofill composite only to learn which vault is open: the
/// session coordinators call [publishVault] on every unlock and reload and
/// [clearCredentials] on every lock and close.
class PlatformPasskeyRegistrationCoordinator
    implements AppleAutofillV2CoordinatorContract {
  PlatformPasskeyRegistrationCoordinator({
    required this.passkeyCoordinator,
    required this.currentKeyFilePath,
    this.onPasskeyWritten,
  });

  static const prepareMethod = 'preparePasskeyRegistration';
  static const commitMethod = 'commitPasskeyRegistration';

  final PasskeyCoordinator passkeyCoordinator;
  final Future<String?> Function() currentKeyFilePath;

  /// Called after a write, so the app window reloads the vault and the
  /// platform caches learn the new passkey.
  final void Function()? onPasskeyWritten;

  String? _databasePath;

  /// Answer the two native calls on [channel]. Other calls are left
  /// unimplemented, as they were before this handler existed.
  void attach(MethodChannel channel) {
    channel.setMethodCallHandler(handleMethodCall);
  }

  Future<Object?> handleMethodCall(MethodCall call) async {
    final arguments = call.arguments;
    final map = arguments is Map ? arguments : const <Object?, Object?>{};
    switch (call.method) {
      case prepareMethod:
        return prepare(
          relyingPartyId: _string(map['rpId']),
          userHandle: _decode(map['userHandle']),
        );
      case commitMethod:
        return commit(
          relyingPartyId: _string(map['rpId']),
          username: _string(map['username']),
          userHandle: _decode(map['userHandle']),
          replaceExisting: map['replaceExisting'] == true,
        );
      default:
        throw MissingPluginException();
    }
  }

  /// `{status, replaces}`: `status` is `ready`, `noVault` or `locked`;
  /// `replaces` is true when a passkey for the site and account exists.
  Future<Map<String, Object?>> prepare({
    required String relyingPartyId,
    required Uint8List? userHandle,
  }) async {
    final status = _sessionStatus();
    if (status != PasskeyRegistrationStatus.ready) {
      return {'status': status.name, 'replaces': false};
    }
    final replaces = await passkeyCoordinator.hasPasskeyFor(
      databasePath: _databasePath!,
      keyFilePath: await currentKeyFilePath(),
      relyingPartyId: relyingPartyId,
      userHandle: userHandle,
    );
    return {'status': status.name, 'replaces': replaces};
  }

  /// `{status}` and, when `status` is `done`, the unpadded base64url values
  /// `credentialId`, `userHandle`, `attestationObject`, `authenticatorData`,
  /// `publicKeyCose` and `publicKeySpki`.
  Future<Map<String, Object?>> commit({
    required String relyingPartyId,
    required String username,
    required Uint8List? userHandle,
    required bool replaceExisting,
  }) async {
    final status = _sessionStatus();
    if (status != PasskeyRegistrationStatus.ready) {
      return {'status': status.name};
    }
    if (relyingPartyId.isEmpty) {
      return {'status': PasskeyRegistrationStatus.failed.name};
    }
    final result = await passkeyCoordinator.createPasskeyForSite(
      databasePath: _databasePath!,
      keyFilePath: await currentKeyFilePath(),
      relyingPartyId: relyingPartyId,
      username: username,
      userHandle: userHandle,
      replaceExisting: replaceExisting,
    );
    final created = result.created;
    if (created == null) {
      final failure = switch (result.outcome) {
        PasskeyOutcome.vaultLocked => PasskeyRegistrationStatus.locked,
        PasskeyOutcome.alreadyExists => PasskeyRegistrationStatus.alreadyExists,
        PasskeyOutcome.notFound ||
        PasskeyOutcome.failed ||
        PasskeyOutcome.done => PasskeyRegistrationStatus.failed,
      };
      return {'status': failure.name};
    }
    onPasskeyWritten?.call();
    return {
      'status': PasskeyRegistrationStatus.done.name,
      'credentialId': _encode(created.passkey.credentialId),
      'userHandle': _encode(
        created.passkey.userHandle ?? created.passkey.credentialId,
      ),
      'attestationObject': _encode(created.attestationObject),
      'authenticatorData': _encode(created.authenticatorData),
      'publicKeyCose': _encode(created.publicKeyCose),
      'publicKeySpki': _encode(created.publicKeySpki),
    };
  }

  PasskeyRegistrationStatus _sessionStatus() {
    if (_databasePath == null) return PasskeyRegistrationStatus.noVault;
    if (!passkeyCoordinator.sessionSecretHolder.hasSecret) {
      return PasskeyRegistrationStatus.locked;
    }
    return PasskeyRegistrationStatus.ready;
  }

  static String _string(Object? value) => value is String ? value.trim() : '';

  static Uint8List? _decode(Object? value) {
    if (value is! String || value.isEmpty) return null;
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      return null;
    }
  }

  static String _encode(Uint8List bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  @override
  Future<void> publishVault({
    required String databasePath,
    required List<VaultEntry> entries,
  }) async {
    _databasePath = databasePath;
  }

  @override
  Future<void> clearCredentials({String? databasePath}) async {
    if (databasePath == null || databasePath == _databasePath) {
      _databasePath = null;
    }
  }

  @override
  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  }) async => const [];

  @override
  Future<void> clearPendingAssociations({List<String>? ids}) async {}
}
