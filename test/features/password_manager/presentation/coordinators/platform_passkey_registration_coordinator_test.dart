// spec 023 slice 4 (T802, T804) — the app half of a platform registration,
// through the method channel surface the native side calls.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/passkey_generator.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/errors/passkey_errors.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/passkey_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/platform_passkey_registration_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';

import 'fake_database_ports.dart';

class _FakeVaultKdbxService implements VaultKdbxService {
  final List<(VaultPasskey passkey, bool replace, String? keyFile)> creates =
      [];
  bool holdsPasskey = false;
  Object? createError;

  @override
  Future<String> createPasskeyForSite({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required VaultPasskey passkey,
    bool replaceExisting = false,
  }) async {
    if (createError != null) throw createError!;
    creates.add((passkey, replaceExisting, keyFilePath));
    return 'entry-1';
  }

  @override
  Future<bool> hasPasskeyFor({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String relyingPartyId,
    required Uint8List? userHandle,
  }) async => holdsPasskey;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List unb64(Object? value) =>
    base64Url.decode(base64Url.normalize(value! as String));

void main() {
  late Directory tempDir;
  late String databasePath;
  late _FakeVaultKdbxService service;
  late SessionSecretHolder holder;
  late PlatformPasskeyRegistrationCoordinator coordinator;
  late int written;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('platform_passkey_');
    databasePath = '${tempDir.path}/vault.kdbx';
    await File(databasePath).writeAsBytes(const [1, 2, 3], flush: true);
    service = _FakeVaultKdbxService();
    holder = SessionSecretHolder()..set('secret');
    written = 0;
    coordinator = PlatformPasskeyRegistrationCoordinator(
      passkeyCoordinator: PasskeyCoordinator(
        vaultKdbxService: service,
        sessionSecretHolder: holder,
        databaseFileRepository: FakeDatabaseFileRepository(),
        generator: PasskeyGenerator(random: Random(7)),
      ),
      currentKeyFilePath: () async => '/keys/vault.key',
      onPasskeyWritten: () => written++,
    );
  });

  tearDown(() => tempDir.delete(recursive: true));

  Future<Map<Object?, Object?>> call(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async =>
      (await coordinator.handleMethodCall(MethodCall(method, arguments)))!
          as Map<Object?, Object?>;

  Future<void> open() =>
      coordinator.publishVault(databasePath: databasePath, entries: const []);

  const commitArguments = {
    'rpId': 'webauthn.io',
    'username': 'ada',
    'userHandle': 'BAUG',
    'replaceExisting': false,
  };

  group('prepare', () {
    test('no open vault is noVault', () async {
      expect(
        await call('preparePasskeyRegistration', {'rpId': 'webauthn.io'}),
        {'status': 'noVault', 'replaces': false},
      );
    });

    test('an open vault with a locked session is locked', () async {
      await open();
      holder.clear();

      final answer = await call('preparePasskeyRegistration', {
        'rpId': 'webauthn.io',
      });

      expect(answer['status'], 'locked');
    });

    test(
      'a ready vault reports whether the passkey would be replaced',
      () async {
        await open();

        expect(
          (await call('preparePasskeyRegistration', {
            'rpId': 'webauthn.io',
            'userHandle': 'BAUG',
          }))['replaces'],
          isFalse,
        );
        service.holdsPasskey = true;
        expect(
          await call('preparePasskeyRegistration', {
            'rpId': 'webauthn.io',
            'userHandle': 'BAUG',
          }),
          {'status': 'ready', 'replaces': true},
        );
      },
    );

    test('a closed vault is forgotten', () async {
      await open();
      await coordinator.clearCredentials();

      expect(
        (await call('preparePasskeyRegistration', {
          'rpId': 'webauthn.io',
        }))['status'],
        'noVault',
      );
    });
  });

  group('commit', () {
    test('writes, then returns what the relying party needs', () async {
      await open();

      final answer = await call('commitPasskeyRegistration', commitArguments);

      expect(answer['status'], 'done');
      final (passkey, replace, keyFile) = service.creates.single;
      expect(passkey.relyingPartyId, 'webauthn.io');
      expect(passkey.username, 'ada');
      expect(passkey.userHandle, Uint8List.fromList([4, 5, 6]));
      expect(replace, isFalse);
      expect(keyFile, '/keys/vault.key');
      expect(unb64(answer['credentialId']), passkey.credentialId);
      expect(unb64(answer['userHandle']), [4, 5, 6]);

      // The authenticator data is the one inside the attestation object, and
      // it carries the credential id.
      final authData = unb64(answer['authenticatorData']);
      expect(authData[32] & 0x40, 0x40, reason: 'AT flag');
      expect(
        latin1.decode(unb64(answer['attestationObject'])),
        contains(latin1.decode(authData)),
      );
      // SubjectPublicKeyInfo ends with the point the COSE key carries.
      final spki = unb64(answer['publicKeySpki']);
      final cose = unb64(answer['publicKeyCose']);
      expect(spki, hasLength(91));
      expect(spki.sublist(27, 59), cose.sublist(10, 42));
      expect(spki.sublist(59), cose.sublist(45));
      expect(written, 1);
    });

    test('no private key crosses the channel', () async {
      await open();

      final answer = await call('commitPasskeyRegistration', commitArguments);

      final pem = service.creates.single.$1.privateKeyPem;
      final body = pem.split('\n')[1];
      expect(jsonEncode(answer), isNot(contains(body)));
      expect(jsonEncode(answer), isNot(contains('PRIVATE KEY')));
    });

    test('a clash without replaceExisting is alreadyExists', () async {
      await open();
      service.createError = const PasskeyAlreadyExists(
        entryId: 'entry-1',
        relyingPartyId: 'webauthn.io',
      );

      final answer = await call('commitPasskeyRegistration', commitArguments);

      expect(answer, {'status': 'alreadyExists'});
      expect(written, 0);
    });

    test('replaceExisting reaches the write', () async {
      await open();

      await call('commitPasskeyRegistration', {
        ...commitArguments,
        'replaceExisting': true,
      });

      expect(service.creates.single.$2, isTrue);
    });

    test('a failed write returns no credential', () async {
      await open();
      service.createError = StateError('save failed');

      final answer = await call('commitPasskeyRegistration', commitArguments);

      expect(answer, {'status': 'failed'});
      expect(written, 0);
    });

    test('a locked or closed vault writes nothing', () async {
      expect(await call('commitPasskeyRegistration', commitArguments), {
        'status': 'noVault',
      });
      await open();
      holder.clear();
      expect(await call('commitPasskeyRegistration', commitArguments), {
        'status': 'locked',
      });
      expect(service.creates, isEmpty);
    });

    test('a request with no relying party is refused', () async {
      await open();

      final answer = await call('commitPasskeyRegistration', {
        'username': 'ada',
      });

      expect(answer, {'status': 'failed'});
      expect(service.creates, isEmpty);
    });
  });

  test('another method is left unimplemented', () {
    expect(
      () => coordinator.handleMethodCall(
        const MethodCall('receivePendingCapture'),
      ),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
