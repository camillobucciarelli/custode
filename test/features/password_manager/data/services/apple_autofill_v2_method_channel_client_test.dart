import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/apple_autofill_v2_method_channel_client.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/models/pending_passkey_registration.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppleAutofillV2MethodChannelClient', () {
    const channel = MethodChannel(
      AppleAutofillV2MethodChannelClient.channelName,
    );
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'publishCredentials':
                final args = call.arguments as Map<dynamic, dynamic>;
                final entries = args['entries'] as List<dynamic>;
                return {
                  'publishedCount': entries.length,
                  'skippedCount': 0,
                  'identityCount': entries.length,
                  'identityStoreSynced': true,
                  'warnings': <String>[],
                };
              case 'clearCredentials':
                return {
                  'cleared': true,
                  'identityStoreCleared': true,
                  'keychainKeyCleared': true,
                  'warnings': <String>[],
                };
              case 'readPendingAssociations':
                return [
                  {
                    'id': 'pending-1',
                    'databaseId': 'db-1',
                    'entryId': 'entry-1',
                    'serviceIdentifierType': 'url',
                    'serviceIdentifierValue':
                        'https://Example.com/login?token=secret#frag',
                    'displayService':
                        'https://Example.com/login?token=secret#frag',
                    'createdAtEpochMs': 123,
                    'platform': 'ios',
                  },
                ];
              case 'clearPendingAssociations':
                final args = call.arguments as Map<dynamic, dynamic>?;
                final ids = args?['ids'] as List<dynamic>?;
                return {
                  'clearedCount': ids?.length ?? 1,
                  'warnings': <String>[],
                };
              case 'takePendingCaptureToken':
                return 'token-1';
              case 'readPendingCapture':
                final args = call.arguments as Map<dynamic, dynamic>;
                if (args['token'] != 'token-1') {
                  throw PlatformException(
                    code: 'android_autofill_capture_missing',
                    message: 'No pending capture for this token.',
                  );
                }
                return {
                  'token': 'token-1',
                  'username': 'alice',
                  'password': 'submitted-secret',
                  'packageName': 'com.example.app',
                  'webDomain': null,
                  'capturedAtEpochMs': 42,
                };
              case 'resolvePendingCapture':
                return {'clearedCount': 1, 'warnings': <String>[]};
              case 'getStatus':
                return {
                  'version': 2,
                  'appGroupAvailable': true,
                  'keychainAccessGroupAvailable': true,
                  'metadataCount': 1,
                  'encryptedCacheAvailable': true,
                  'cacheAvailable': true,
                  'databaseId': 'db-1',
                  'generatedAtEpochMs': 123,
                };
            }
            fail('Unexpected method ${call.method}');
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('publishCredentials carries the requested auth session ttl', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      await client.publishCredentials(
        databaseId: 'db-1',
        credentials: const [
          AppleAutofillV2Credential(
            id: 'entry-1',
            title: 'Example',
            username: 'alice',
            password: 'super-secret',
            url: null,
            serviceIdentifiers: [],
          ),
        ],
        authSessionTtlMs: 30000,
      );

      final args = calls.single.arguments as Map<dynamic, dynamic>;
      expect(args['authSessionTtlMs'], 30000);
    });

    test('publishCredentials sends the native v2 payload', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      final result = await client.publishCredentials(
        databaseId: 'db-1',
        credentials: const [
          AppleAutofillV2Credential(
            id: 'entry-1',
            title: 'Example',
            username: 'alice',
            password: 'super-secret',
            url: 'https://example.com',
            serviceIdentifiers: [
              AppleAutofillV2ServiceIdentifier.domain('example.com'),
              AppleAutofillV2ServiceIdentifier.url('https://example.com'),
              AppleAutofillV2ServiceIdentifier.bundleId('com.example.app'),
              AppleAutofillV2ServiceIdentifier.androidPackage(
                'com.example.android',
              ),
            ],
          ),
        ],
      );

      expect(result.publishedCount, 1);
      expect(calls.single.method, 'publishCredentials');
      final args = calls.single.arguments as Map<dynamic, dynamic>;
      expect(args['databaseId'], 'db-1');
      expect(args['authSessionTtlMs'], 0);
      final entries = args['entries'] as List<dynamic>;
      final entry = entries.single as Map<dynamic, dynamic>;
      expect(entry['id'], 'entry-1');
      expect(entry['title'], 'Example');
      expect(entry['username'], 'alice');
      expect(entry['password'], 'super-secret');
      expect(entry['url'], 'https://example.com');
      expect(entry['serviceIdentifiers'], [
        {'type': 'domain', 'value': 'example.com'},
        {'type': 'url', 'value': 'https://example.com'},
        {'type': 'bundleId', 'value': 'com.example.app'},
        {'type': 'androidPackage', 'value': 'com.example.android'},
      ]);
    });

    test('clearCredentials passes optional databaseId', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      final result = await client.clearCredentials(databaseId: 'db-1');

      expect(result.cleared, isTrue);
      expect(calls.single.method, 'clearCredentials');
      expect(calls.single.arguments, {'databaseId': 'db-1'});
    });

    test('getStatus marks supported native status', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      final status = await client.getStatus();

      expect(status.supported, isTrue);
      expect(status.version, 2);
      expect(status.metadataCount, 1);
      expect(status.databaseId, 'db-1');
    });

    test(
      'readPendingAssociations returns metadata-only pending links',
      () async {
        final client = AppleAutofillV2MethodChannelClient(
          channel: channel,
          isSupportedOverride: true,
        );

        final associations = await client.readPendingAssociations();

        expect(calls.single.method, 'readPendingAssociations');
        expect(associations.single.id, 'pending-1');
        expect(associations.single.databaseId, 'db-1');
        expect(associations.single.entryId, 'entry-1');
        expect(associations.single.serviceIdentifierType, 'url');
        expect(
          associations.single.serviceIdentifierValue,
          'https://example.com',
        );
        expect(associations.single.displayService, 'example.com');
        expect(associations.single.platform, 'ios');
        expect(associations.single.toString(), isNot(contains('token=secret')));
        expect(
          associations.single.props.toString(),
          isNot(contains('token=secret')),
        );
      },
    );

    test('clearPendingAssociations passes optional ids', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      final result = await client.clearPendingAssociations(
        ids: const ['pending-1'],
      );

      expect(result.clearedCount, 1);
      expect(calls.single.method, 'clearPendingAssociations');
      expect(calls.single.arguments, {
        'ids': ['pending-1'],
      });
    });

    test(
      'unsupported platforms are no-op and do not call MethodChannel',
      () async {
        final client = AppleAutofillV2MethodChannelClient(
          channel: channel,
          isSupportedOverride: false,
        );

        final publish = await client.publishCredentials(
          databaseId: 'db-1',
          credentials: const [],
        );
        final clear = await client.clearCredentials();
        final pending = await client.readPendingAssociations();
        final clearPending = await client.clearPendingAssociations();
        final status = await client.getStatus();

        expect(publish.warnings, contains('unsupported_platform'));
        expect(clear.warnings, contains('unsupported_platform'));
        expect(pending, isEmpty);
        expect(clearPending.warnings, contains('unsupported_platform'));
        expect(status.supported, isFalse);
        expect(calls, isEmpty);
      },
    );

    test('readPendingCapture returns the captured credential once', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      final capture = await client.readPendingCapture('token-1');

      expect(capture?.token, 'token-1');
      expect(capture?.username, 'alice');
      expect(capture?.password, 'submitted-secret');
      expect(capture?.association, 'com.example.app');
    });

    test('a capture that is gone reads as null, not as an error', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      expect(await client.readPendingCapture('other-token'), isNull);
    });

    test('the captured password is never rendered', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      final capture = await client.readPendingCapture('token-1');

      expect(capture.toString(), isNot(contains('submitted-secret')));
      expect(capture.toString(), isNot(contains('alice')));
      expect(capture!.props.join(), isNot(contains('submitted-secret')));
    });

    test('resolvePendingCapture reports the outcome', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: true,
      );

      final result = await client.resolvePendingCapture(
        token: 'token-1',
        outcome: AndroidAutofillCaptureOutcome.declined,
      );

      expect(result.clearedCount, 1);
      final args = calls.single.arguments as Map<dynamic, dynamic>;
      expect(args['outcome'], 'declined');
    });

    group('android system settings', () {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var reply = true;

      setUp(() {
        reply = true;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return reply;
        });
      });

      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test('forward to the matching native methods', () async {
        final client = AppleAutofillV2MethodChannelClient(channel: channel);

        expect(await client.getAutofillServiceEnabled(), isTrue);
        expect(await client.openAutofillSettings(), isTrue);
        expect(await client.openPasskeyProviderSettings(), isTrue);
        expect(calls.map((c) => c.method), [
          'getAutofillServiceEnabled',
          'openAutofillSettings',
          'openPasskeyProviderSettings',
        ]);
      });

      test('relay a false answer', () async {
        reply = false;
        final client = AppleAutofillV2MethodChannelClient(channel: channel);

        expect(await client.getAutofillServiceEnabled(), isFalse);
        expect(await client.openAutofillSettings(), isFalse);
        expect(await client.openPasskeyProviderSettings(), isFalse);
      });

      test('are false, without a call, off Android', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final client = AppleAutofillV2MethodChannelClient(channel: channel);

        expect(await client.getAutofillServiceEnabled(), isFalse);
        expect(await client.openAutofillSettings(), isFalse);
        expect(await client.openPasskeyProviderSettings(), isFalse);
        expect(calls, isEmpty);
      });
    });

    test('an unsupported platform refuses instead of answering null', () async {
      final client = AppleAutofillV2MethodChannelClient(
        channel: channel,
        isSupportedOverride: false,
      );

      expect(
        () => client.readPendingCapture('token-1'),
        throwsUnsupportedError,
      );
      expect(
        () => client.resolvePendingCapture(
          token: 'token-1',
          outcome: AndroidAutofillCaptureOutcome.saved,
        ),
        throwsUnsupportedError,
      );
      expect(await client.takePendingCaptureToken(), isNull);
    });
  });

  group('pending passkey registrations', () {
    const channel = MethodChannel(
      AppleAutofillV2MethodChannelClient.channelName,
    );
    const sentinel = 'SENTINEL-PRIVATE-KEY';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    Map<String, Object?> record({String recordId = 'rec-1'}) => {
      'recordId': recordId,
      'databaseId': 'db-1',
      'createdAtEpochMs': 1700000000000,
      'rpId': 'example.com',
      'credentialId': 'AQID',
      'userHandle': 'BAU',
      'username': 'alice',
      'displayName': 'Alice',
      'privateKeyPem': sentinel,
      'algorithm': 'ES256',
      'be': true,
      'bs': true,
      'origin': 'https://example.com',
    };

    late List<MethodCall> calls;

    void answer(Future<Object?> Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return handler(call);
      });
    }

    setUp(() => calls = []);

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    // One Dart client serves both native sides over the same channel name.
    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      group(platform.name, () {
        setUp(() => debugDefaultTargetPlatformOverride = platform);

        test('reads records and the native unreadable count', () async {
          answer(
            (_) async => {
              'records': [
                record(),
                {...record(recordId: 'rec-2'), 'userHandle': null}
                  ..['displayName'] = null,
              ],
              'unreadableCount': 2,
            },
          );

          final result = await AppleAutofillV2MethodChannelClient(
            channel: channel,
          ).readPendingPasskeyRegistrations();

          expect(calls.single.method, 'readPendingPasskeyRegistrations');
          expect(calls.single.arguments, isNull);
          expect(result.unreadableCount, 2);
          expect(result.records, hasLength(2));
          final first = result.records.first;
          expect(first.recordId, 'rec-1');
          expect(first.databaseId, 'db-1');
          expect(
            first.createdAt,
            DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
          );
          expect(first.rpId, 'example.com');
          expect(first.credentialId, [1, 2, 3]);
          expect(first.userHandle, [4, 5]);
          expect(first.username, 'alice');
          expect(first.displayName, 'Alice');
          expect(first.privateKeyPem, sentinel);
          expect(first.algorithm, VaultPasskeyAlgorithm.es256);
          expect(first.be, isTrue);
          expect(first.bs, isTrue);
          expect(first.origin, 'https://example.com');
          expect(result.records.last.userHandle, isNull);
          expect(result.records.last.displayName, isNull);
        });

        test('a native side without the method has nothing pending', () async {
          // No handler registered: the binding answers MissingPluginException,
          // which is also what `result.notImplemented()` becomes.
          final client = AppleAutofillV2MethodChannelClient(channel: channel);

          expect(
            await client.readPendingPasskeyRegistrations(),
            const PendingPasskeyRegistrations(),
          );
          expect(await client.resolvePendingPasskeyRegistration('r'), isFalse);
        });

        test('malformed records are counted, never thrown', () async {
          answer(
            (_) async => {
              'records': [
                record(),
                'not a map',
                {...record(), 'privateKeyPem': null},
                {...record(), 'credentialId': '***'},
                {...record(), 'userHandle': 7},
                {...record(), 'algorithm': 'PS512'},
                {...record(), 'createdAtEpochMs': 'yesterday'},
                {...record()}..remove('recordId'),
              ],
              'unreadableCount': 1,
            },
          );

          final result = await AppleAutofillV2MethodChannelClient(
            channel: channel,
          ).readPendingPasskeyRegistrations();

          expect(result.records.single.recordId, 'rec-1');
          expect(result.unreadableCount, 8);
        });

        test('a result of the wrong shape reads as empty', () async {
          answer((_) async => {'records': 'nope', 'unreadableCount': 'x'});

          expect(
            await AppleAutofillV2MethodChannelClient(channel: channel)
                .readPendingPasskeyRegistrations(),
            const PendingPasskeyRegistrations(),
          );
        });

        test('count asks the native side for a number, no arguments', () async {
          answer((_) async => 4);

          final count = await AppleAutofillV2MethodChannelClient(
            channel: channel,
          ).countPendingPasskeyRegistrations();

          expect(count, 4);
          expect(calls.single.method, 'countPendingPasskeyRegistrations');
          expect(calls.single.arguments, isNull);
        });

        test('count is 0 when not implemented or failing', () async {
          final client = AppleAutofillV2MethodChannelClient(channel: channel);
          // No handler: MissingPluginException.
          expect(await client.countPendingPasskeyRegistrations(), 0);
          answer((_) async => throw PlatformException(code: 'io'));
          expect(await client.countPendingPasskeyRegistrations(), 0);
        });

        test('resolve sends the record id', () async {
          answer((_) async => true);

          final resolved = await AppleAutofillV2MethodChannelClient(
            channel: channel,
          ).resolvePendingPasskeyRegistration('rec-1');

          expect(resolved, isTrue);
          expect(calls.single.method, 'resolvePendingPasskeyRegistration');
          expect(calls.single.arguments, {'recordId': 'rec-1'});
        });

        test('a native resolve failure is not swallowed', () async {
          answer((_) async => throw PlatformException(code: 'io'));

          expect(
            AppleAutofillV2MethodChannelClient(channel: channel)
                .resolvePendingPasskeyRegistration('rec-1'),
            throwsA(isA<PlatformException>()),
          );
        });
      });
    }

    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      test('${platform.name} answers empty without a channel call', () async {
        debugDefaultTargetPlatformOverride = platform;
        answer((_) async => fail('channel must not be called'));
        final client = AppleAutofillV2MethodChannelClient(channel: channel);

        expect(
          await client.readPendingPasskeyRegistrations(),
          const PendingPasskeyRegistrations(),
        );
        expect(await client.resolvePendingPasskeyRegistration('r'), isFalse);
        expect(await client.countPendingPasskeyRegistrations(), 0);
        expect(calls, isEmpty);
      });
    }

    test('the private key is absent from props and toString', () async {
      final parsed = PendingPasskeyRegistration.tryFromChannelMap(record())!;
      final result = PendingPasskeyRegistrations(records: [parsed]);

      expect(parsed.privateKeyPem, sentinel);
      for (final text in [
        parsed.toString(),
        parsed.props.toString(),
        result.toString(),
        result.props.toString(),
      ]) {
        expect(text, isNot(contains(sentinel)));
      }
      expect(parsed.toString(), contains('rec-1'));
      expect(parsed.toString(), contains('example.com'));
    });
  });
}
