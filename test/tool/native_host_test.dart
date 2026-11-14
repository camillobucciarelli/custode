import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/browser_exact_origin.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_autofill_cache.dart';

import '../../tool/native_host_protocol.dart';

void main() {
  group('Native Messaging frame codec', () {
    test('encodes and decodes little-endian JSON frames', () {
      final frame = encodeNativeMessage({
        'version': nativeProtocolVersion,
        'id': 'hello-1',
        'type': 'hello',
        'payload': <String, Object?>{},
      });

      final payloadLength = ByteData.sublistView(
        frame,
        0,
        4,
      ).getUint32(0, Endian.little);
      expect(payloadLength, frame.length - 4);

      final decoded = decodeNativeMessageFrame(frame);
      expect(decoded['version'], nativeProtocolVersion);
      expect(decoded['id'], 'hello-1');
      expect(decoded['type'], 'hello');
    });

    test('rejects oversized payloads before JSON decoding', () {
      final header = ByteData(4)
        ..setUint32(0, maxNativeMessagePayloadBytes + 1, Endian.little);
      final frame = Uint8List.fromList(header.buffer.asUint8List());

      expect(
        () => decodeNativeMessageFrame(frame),
        throwsA(
          isA<NativeHostProtocolException>().having(
            (error) => error.code,
            'code',
            'payload_too_large',
          ),
        ),
      );
    });

    test('reads multiple frames from chunked stream', () async {
      final hello = encodeNativeMessage({
        'version': nativeProtocolVersion,
        'id': 'one',
        'type': 'hello',
      });
      final status = encodeNativeMessage({
        'version': nativeProtocolVersion,
        'id': 'two',
        'type': 'status',
      });
      final combined = Uint8List.fromList([...hello, ...status]);
      final reader = NativeMessageStreamReader(
        Stream<List<int>>.fromIterable([
          combined.sublist(0, 3),
          combined.sublist(3, 11),
          combined.sublist(11),
        ]),
      );

      expect((await reader.readMessage())?['id'], 'one');
      expect((await reader.readMessage())?['id'], 'two');
      expect(await reader.readMessage(), isNull);
    });
  });

  group('Native Messaging v2 protocol', () {
    test('hello returns host metadata and safe-mode status', () async {
      final store = DesktopBrowserAutofillCacheStore(
        directory: await Directory.systemTemp.createTemp('kv-native-host-'),
      );
      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'hello-1',
        'type': 'hello',
      }, store: store);

      expect(response['ok'], isTrue);
      expect(response['id'], 'hello-1');
      expect(response['type'], 'hello');

      final data = response['data']! as Map<String, Object?>;
      final host = data['host']! as Map<String, Object?>;
      final appBridge = data['appBridge']! as Map<String, Object?>;

      expect(host['name'], nativeHostName);
      expect(host['protocolVersion'], nativeProtocolVersion);
      expect(appBridge['connected'], isFalse);
      expect(data['supportedMessages'], contains('queryCredentials'));
      expect(data['supportedMessages'], contains('searchCredentials'));
      expect(data['supportedMessages'], contains('createPendingAssociation'));
      expect(data['supportedMessages'], contains('revealForFill'));
    });

    test(
      'queryCredentials returns a safe app bridge error, never secrets',
      () async {
        final store = DesktopBrowserAutofillCacheStore(
          directory: await Directory.systemTemp.createTemp('kv-native-host-'),
        );
        final response = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'query-1',
          'type': 'queryCredentials',
          'payload': {'url': 'https://example.com', 'limit': 5},
        }, store: store);

        expect(response['ok'], isFalse);
        expect(response['type'], 'queryCredentials');
        final error = response['error']! as Map<String, Object?>;
        expect(error['code'], 'app_bridge_unavailable');

        final encoded = jsonEncode(response);
        expect(encoded, isNot(contains('kv-test-only-not-a-real-password')));
        expect(encoded, isNot(contains('passwordValue')));
        expect(encoded, isNot(contains('credentials":[')));
      },
    );

    test(
      'revealForFill returns one-shot credentials via local bridge',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'kv-native-host-',
        );
        final store = DesktopBrowserAutofillCacheStore(directory: directory);
        await store.writeMetadataCache(
          const DesktopBrowserAutofillMetadataCache(
            version: desktopBrowserAutofillCacheVersion,
            databaseId: 'db-1',
            cacheGeneration: 'cache-gen-1',
            generatedAtEpochMs: 1,
            entries: [
              DesktopBrowserAutofillCredentialMetadata(
                id: 'entry-123',
                title: 'Example',
                username: 'alice',
                displayService: 'example.com',
                serviceIdentifiers: [
                  DesktopBrowserAutofillServiceIdentifier(
                    type: 'domain',
                    value: 'example.com',
                  ),
                ],
                updatedAtEpochMs: 1,
              ),
            ],
          ),
        );
        final bridge = await _FakeRevealBridge.start(
          responseData: const {
            'entryId': 'entry-123',
            'username': 'alice',
            'password': 'super-secret',
          },
        );
        addTearDown(bridge.close);
        await store.writeBridgeDescriptor(
          bridge.descriptor(databaseId: 'db-1'),
        );

        final response = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'reveal-1',
          'type': 'revealForFill',
          'payload': {'entryId': 'entry-123', 'origin': 'https://example.com'},
        }, store: store);

        expect(response['ok'], isTrue);
        final data = response['data']! as Map<String, Object?>;
        expect(data['entryId'], 'entry-123');
        expect(data['username'], 'alice');
        expect(data['password'], 'super-secret');
        expect(bridge.requestCount, 1);
        expect(bridge.lastPayload?['origin'], 'https://example.com');
        final descriptorJson = await store.bridgeDescriptorFile!.readAsString();
        expect(descriptorJson, isNot(contains('super-secret')));
      },
    );

    test('revealForFill denies possible/manual non-exact match', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-native-host-',
      );
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      await store.writeMetadataCache(
        const DesktopBrowserAutofillMetadataCache(
          version: desktopBrowserAutofillCacheVersion,
          databaseId: 'db-1',
          cacheGeneration: 'cache-gen-1',
          generatedAtEpochMs: 1,
          entries: [
            DesktopBrowserAutofillCredentialMetadata(
              id: 'bank',
              title: 'Example Bank',
              username: 'alice',
              displayService: 'examplebank.com',
              serviceIdentifiers: [
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'domain',
                  value: 'examplebank.com',
                ),
              ],
              updatedAtEpochMs: 1,
            ),
          ],
        ),
      );
      final bridge = await _FakeRevealBridge.start(
        responseData: const {
          'entryId': 'bank',
          'username': 'alice',
          'password': 'super-secret',
        },
      );
      addTearDown(bridge.close);
      await store.writeBridgeDescriptor(bridge.descriptor(databaseId: 'db-1'));

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'reveal-possible',
        'type': 'revealForFill',
        'payload': {'entryId': 'bank', 'origin': 'https://bank-login.test'},
      }, store: store);

      expect(response['ok'], isFalse);
      final error = response['error']! as Map<String, Object?>;
      expect(error['code'], 'strong_match_required');
      expect(bridge.requestCount, 0);
      expect(jsonEncode(response), isNot(contains('super-secret')));
    });

    test(
      'revealForFill denies example.com credential on phishing host',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'kv-native-host-',
        );
        final store = DesktopBrowserAutofillCacheStore(directory: directory);
        await store.writeMetadataCache(
          const DesktopBrowserAutofillMetadataCache(
            version: desktopBrowserAutofillCacheVersion,
            databaseId: 'db-1',
            cacheGeneration: 'cache-gen-1',
            generatedAtEpochMs: 1,
            entries: [
              DesktopBrowserAutofillCredentialMetadata(
                id: 'example',
                title: 'Example',
                username: 'alice',
                displayService: 'example.com',
                serviceIdentifiers: [
                  DesktopBrowserAutofillServiceIdentifier(
                    type: 'domain',
                    value: 'example.com',
                  ),
                ],
                updatedAtEpochMs: 1,
              ),
            ],
          ),
        );
        final bridge = await _FakeRevealBridge.start(
          responseData: const {
            'entryId': 'example',
            'username': 'alice',
            'password': 'super-secret',
          },
        );
        addTearDown(bridge.close);
        await store.writeBridgeDescriptor(
          bridge.descriptor(databaseId: 'db-1'),
        );

        final response = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'reveal-phish',
          'type': 'revealForFill',
          'payload': {
            'entryId': 'example',
            'origin': 'https://example.com.evil.com',
          },
        }, store: store);

        expect(response['ok'], isFalse);
        final error = response['error']! as Map<String, Object?>;
        expect(error['code'], 'strong_match_required');
        expect(bridge.requestCount, 0);
        expect(jsonEncode(response), isNot(contains('super-secret')));
      },
    );

    group('revealForFill origin scheme and port binding', () {
      const httpsEntry = [
        DesktopBrowserAutofillServiceIdentifier(
          type: 'url',
          value: 'https://example.test',
        ),
        DesktopBrowserAutofillServiceIdentifier(
          type: 'domain',
          value: 'example.test',
        ),
      ];

      test('denies https entry on a downgraded http page', () async {
        _expectRevealRefused(
          await _revealForFill(
            identifiers: httpsEntry,
            origin: 'http://example.test',
          ),
        );
      });

      test('still allows the matching https page', () async {
        final result = await _revealForFill(
          identifiers: httpsEntry,
          origin: 'https://example.test',
        );

        expect(result.response['ok'], isTrue);
        final data = result.response['data']! as Map<String, Object?>;
        expect(data['password'], 'test-only-secret');
        expect(result.bridgeCalls, 1);
      });

      test('denies a port mismatch on the same host', () async {
        _expectRevealRefused(
          await _revealForFill(
            identifiers: const [
              DesktopBrowserAutofillServiceIdentifier(
                type: 'url',
                value: 'https://example.test:8443',
              ),
              DesktopBrowserAutofillServiceIdentifier(
                type: 'domain',
                value: 'example.test',
              ),
            ],
            origin: 'https://example.test',
          ),
        );
      });

      test(
        'denies an unexpected port on a pinned default-port entry',
        () async {
          _expectRevealRefused(
            await _revealForFill(
              identifiers: httpsEntry,
              origin: 'https://example.test:8443',
            ),
          );
        },
      );

      test('allows a domain-only entry on an https page', () async {
        final result = await _revealForFill(
          identifiers: const [
            DesktopBrowserAutofillServiceIdentifier(
              type: 'domain',
              value: 'example.test',
            ),
          ],
          origin: 'https://example.test',
        );

        expect(result.response['ok'], isTrue);
        expect(result.bridgeCalls, 1);
      });

      test('denies a domain-only entry on an http page', () async {
        _expectRevealRefused(
          await _revealForFill(
            identifiers: const [
              DesktopBrowserAutofillServiceIdentifier(
                type: 'domain',
                value: 'example.test',
              ),
            ],
            origin: 'http://example.test',
          ),
        );
      });

      test('allows the http entry / https page upgrade', () async {
        final result = await _revealForFill(
          identifiers: const [
            DesktopBrowserAutofillServiceIdentifier(
              type: 'url',
              value: 'http://example.test',
            ),
            DesktopBrowserAutofillServiceIdentifier(
              type: 'domain',
              value: 'example.test',
            ),
          ],
          origin: 'https://example.test',
        );

        expect(result.response['ok'], isTrue);
        expect(result.bridgeCalls, 1);
      });

      test('denies the upgrade when the port differs', () async {
        _expectRevealRefused(
          await _revealForFill(
            identifiers: const [
              DesktopBrowserAutofillServiceIdentifier(
                type: 'url',
                value: 'http://example.test:8080',
              ),
              DesktopBrowserAutofillServiceIdentifier(
                type: 'domain',
                value: 'example.test',
              ),
            ],
            origin: 'https://example.test',
          ),
        );
      });

      group('hosts that cannot obtain a WebPKI certificate', () {
        // A URL stored without a scheme emits a `domain` identifier and no
        // `url` pin, so the page scheme is decided here.
        for (final host in const [
          '192.168.1.10',
          '10.4.0.7',
          '172.16.9.9',
          '127.0.0.1',
          '169.254.10.10',
          'nas',
          'router.local',
          'printer.home.arpa',
          'wiki.internal',
          'vault.lan',
        ]) {
          test('allows $host over http', () async {
            final result = await _revealForFill(
              identifiers: [
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'domain',
                  value: host,
                ),
              ],
              origin: 'http://$host',
            );

            expect(result.response['ok'], isTrue);
            expect(result.bridgeCalls, 1);
          });
        }

        for (final host in const ['bank.example', '1.1.1.1', 'example.test']) {
          test('denies $host over http', () async {
            _expectRevealRefused(
              await _revealForFill(
                identifiers: [
                  DesktopBrowserAutofillServiceIdentifier(
                    type: 'domain',
                    value: host,
                  ),
                ],
                origin: 'http://$host',
              ),
            );
          });
        }

        test('denies an http page when the entry pins https', () async {
          _expectRevealRefused(
            await _revealForFill(
              identifiers: const [
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'url',
                  value: 'https://192.168.1.10',
                ),
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'domain',
                  value: '192.168.1.10',
                ),
              ],
              origin: 'http://192.168.1.10',
            ),
          );
        });

        // This layer canonicalizes the page origin itself before handing it to
        // the policy. Collapsing `m.`/`www.`/`mobile.` there would make `m.me`
        // arrive as the single-label `me` and pass as non-public.
        for (final host in const ['m.me', 'www.com', 'mobile.io']) {
          test('denies $host over http', () async {
            _expectRevealRefused(
              await _revealForFill(
                identifiers: [
                  DesktopBrowserAutofillServiceIdentifier(
                    type: 'domain',
                    value: host,
                  ),
                ],
                origin: 'http://$host',
              ),
            );
          });
        }
      });

      group('a written port binds without a scheme pin', () {
        for (final (domain, origin) in const [
          ('bank.example:8443', 'https://bank.example:9999'),
          ('bank.example:8443', 'https://bank.example'),
          ('192.168.1.10:8443', 'http://192.168.1.10:9999'),
          ('192.168.1.10:8443', 'http://192.168.1.10'),
        ]) {
          test('denies $domain on $origin', () async {
            _expectRevealRefused(
              await _revealForFill(
                identifiers: [
                  DesktopBrowserAutofillServiceIdentifier(
                    type: 'domain',
                    value: domain,
                  ),
                ],
                origin: origin,
              ),
            );
          });
        }

        for (final (domain, origin) in const [
          ('bank.example:8443', 'https://bank.example:8443'),
          ('192.168.1.10:8443', 'http://192.168.1.10:8443'),
        ]) {
          test('allows $domain on $origin', () async {
            final result = await _revealForFill(
              identifiers: [
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'domain',
                  value: domain,
                ),
              ],
              origin: origin,
            );

            expect(result.response['ok'], isTrue);
            expect(result.bridgeCalls, 1);
          });
        }
      });
    });

    test('revealForFill denies descriptor/database mismatch', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-native-host-',
      );
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      await store.writeMetadataCache(
        const DesktopBrowserAutofillMetadataCache(
          version: desktopBrowserAutofillCacheVersion,
          databaseId: 'db-1',
          cacheGeneration: 'cache-gen-1',
          generatedAtEpochMs: 1,
          entries: [
            DesktopBrowserAutofillCredentialMetadata(
              id: 'entry-123',
              title: 'Example',
              username: 'alice',
              displayService: 'example.com',
              serviceIdentifiers: [
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'domain',
                  value: 'example.com',
                ),
              ],
              updatedAtEpochMs: 1,
            ),
          ],
        ),
      );
      final bridge = await _FakeRevealBridge.start(
        responseData: const {
          'entryId': 'entry-123',
          'username': 'alice',
          'password': 'super-secret',
        },
      );
      addTearDown(bridge.close);
      await store.writeBridgeDescriptor(bridge.descriptor(databaseId: 'db-2'));

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'reveal-mismatch',
        'type': 'revealForFill',
        'payload': {'entryId': 'entry-123', 'origin': 'https://example.com'},
      }, store: store);

      expect(response['ok'], isFalse);
      final error = response['error']! as Map<String, Object?>;
      expect(error['code'], 'database_mismatch');
      expect(bridge.requestCount, 0);
    });

    test('rejects legacy secret-bearing request fields', () async {
      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'legacy-1',
        'type': 'queryCredentials',
        'masterPassword': 'kv-test-only-not-a-real-password',
        'payload': {'url': 'https://example.com'},
      });

      expect(response['ok'], isFalse);
      final error = response['error']! as Map<String, Object?>;
      expect(error['code'], 'legacy_fields_rejected');
      expect(
        jsonEncode(response),
        isNot(contains('kv-test-only-not-a-real-password')),
      );
    });

    test('rejects unsupported message types', () async {
      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'bad-1',
        'type': 'findCredentials',
      });

      expect(response['ok'], isFalse);
      final error = response['error']! as Map<String, Object?>;
      expect(error['code'], 'unsupported_type');
    });

    test('queryCredentials returns exact host strong matches only', () async {
      final store = DesktopBrowserAutofillCacheStore(
        directory: await Directory.systemTemp.createTemp('kv-native-host-'),
      );
      await store.writeMetadataCache(
        const DesktopBrowserAutofillMetadataCache(
          version: desktopBrowserAutofillCacheVersion,
          databaseId: 'db-1',
          cacheGeneration: 'cache-gen-1',
          generatedAtEpochMs: 1,
          entries: [
            DesktopBrowserAutofillCredentialMetadata(
              id: 'exact',
              title: 'Example',
              username: 'alice',
              displayService: 'example.com',
              serviceIdentifiers: [
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'domain',
                  value: 'example.com',
                ),
              ],
              updatedAtEpochMs: 1,
            ),
            DesktopBrowserAutofillCredentialMetadata(
              id: 'phishing',
              title: 'Phishing',
              username: 'mallory',
              displayService: 'example.com.evil.com',
              serviceIdentifiers: [
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'domain',
                  value: 'example.com.evil.com',
                ),
              ],
              updatedAtEpochMs: 1,
            ),
          ],
        ),
      );

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'query-strong',
        'type': 'queryCredentials',
        'payload': {'url': 'https://example.com', 'limit': 10},
      }, store: store);

      expect(response['ok'], isTrue);
      final data = response['data']! as Map<String, Object?>;
      final strongMatches = data['strongMatches']! as List<Object?>;
      final possibleMatches = data['possibleMatches']! as List<Object?>;
      expect(strongMatches, hasLength(1));
      expect(
        (strongMatches.single as Map<String, Object?>)['entryId'],
        'exact',
      );
      expect(jsonEncode(strongMatches), isNot(contains('phishing')));
      expect(jsonEncode(possibleMatches), isNot(contains('phishing')));
    });

    test('partial target token is possible match only', () async {
      final store = DesktopBrowserAutofillCacheStore(
        directory: await Directory.systemTemp.createTemp('kv-native-host-'),
      );
      await store.writeMetadataCache(
        const DesktopBrowserAutofillMetadataCache(
          version: desktopBrowserAutofillCacheVersion,
          databaseId: 'db-1',
          cacheGeneration: 'cache-gen-1',
          generatedAtEpochMs: 1,
          entries: [
            DesktopBrowserAutofillCredentialMetadata(
              id: 'bank',
              title: 'Example Bank',
              username: 'alice',
              displayService: 'examplebank.com',
              serviceIdentifiers: [
                DesktopBrowserAutofillServiceIdentifier(
                  type: 'domain',
                  value: 'examplebank.com',
                ),
              ],
              updatedAtEpochMs: 1,
            ),
          ],
        ),
      );

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'query-possible',
        'type': 'queryCredentials',
        'payload': {
          'url': 'https://bank-login.test',
          'title': 'Bank login',
          'limit': 10,
        },
      }, store: store);

      expect(response['ok'], isTrue);
      final data = response['data']! as Map<String, Object?>;
      expect(data['strongMatches'], isEmpty);
      final possibleMatches = data['possibleMatches']! as List<Object?>;
      expect(possibleMatches, hasLength(1));
      final match = possibleMatches.single as Map<String, Object?>;
      expect(match['entryId'], 'bank');
      expect(match['matchType'], 'possible');
    });

    test(
      'createPendingAssociation stores sanitized desktop target only',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'kv-native-host-',
        );
        final store = DesktopBrowserAutofillCacheStore(directory: directory);
        await store.writeMetadataCache(
          const DesktopBrowserAutofillMetadataCache(
            version: desktopBrowserAutofillCacheVersion,
            databaseId: 'db-1',
            cacheGeneration: 'cache-gen-1',
            generatedAtEpochMs: 1,
            entries: [
              DesktopBrowserAutofillCredentialMetadata(
                id: 'entry-1',
                title: 'Example',
                username: 'alice',
                displayService: 'old.example',
                serviceIdentifiers: [
                  DesktopBrowserAutofillServiceIdentifier(
                    type: 'domain',
                    value: 'old.example',
                  ),
                ],
                updatedAtEpochMs: 1,
              ),
            ],
          ),
        );

        final response = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'pending-1',
          'type': 'createPendingAssociation',
          'payload': {
            'entryId': 'entry-1',
            'url': 'https://Example.com/login?token=secret#frag',
          },
        }, store: store);

        expect(response['ok'], isTrue);
        final pending = await store.readPendingAssociations();
        expect(pending, hasLength(1));
        expect(pending.single.databaseId, 'db-1');
        expect(pending.single.entryId, 'entry-1');
        expect(pending.single.serviceIdentifierType, 'domain');
        expect(pending.single.serviceIdentifierValue, 'example.com');
        expect(pending.single.displayService, 'example.com');
        expect(pending.single.platform, desktopBrowserAutofillPlatform);
        final encoded = await store.pendingAssociationsFile!.readAsString();
        expect(encoded, isNot(contains('/login')));
        expect(encoded, isNot(contains('token=secret')));
        expect(encoded, isNot(contains('frag')));
        expect(encoded, isNot(contains('password')));
      },
    );
  });

  group('009 A014 — popup fill eligibility', () {
    test('a host-level strong match the reveal policy would refuse is not '
        'presented as fillable', () async {
      final store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [
          // Stored as https, so the popup policy refuses it on an http page
          // even though the host matches.
          _overlayEntry(id: 'https-only', exactOrigin: 'https://example.com'),
        ],
      );
      final bridge = await _FakeOverlayBridge.start();
      addTearDown(bridge.close);
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          databaseId: 'db-a',
          cacheGeneration: 'cache-a',
          bridgeGeneration: 'bridge-a',
        ),
      );

      Future<Map<String, Object?>> queryAt(String url) async {
        final response = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'popup-query',
          'type': 'queryCredentials',
          'payload': {'url': url, 'limit': 10},
        }, store: store);
        final data = response['data']! as Map<String, Object?>;
        return (data['strongMatches']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .single;
      }

      expect((await queryAt('https://example.com'))['fillEligible'], isTrue);
      expect((await queryAt('http://example.com'))['fillEligible'], isFalse);
    });

    test('nothing is fillable while the reveal bridge is absent', () async {
      final store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [_overlayEntry()],
      );

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'popup-query-2',
        'type': 'queryCredentials',
        'payload': {'url': 'https://example.com'},
      }, store: store);

      final data = response['data']! as Map<String, Object?>;
      expect(data['fillAvailable'], isFalse);
      final strong = (data['strongMatches']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(strong.single['fillEligible'], isFalse);
    });
  });

  group('009 A008 — overlay capability negotiation', () {
    test('hello advertises the exact-origin capability and types', () async {
      final store = DesktopBrowserAutofillCacheStore(
        directory: await Directory.systemTemp.createTemp('kv-overlay-host-'),
      );
      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'hello-cap',
        'type': 'hello',
      }, store: store);

      final data = response['data']! as Map<String, Object?>;
      expect(data['capabilities'], contains('overlayExactOriginV1'));
      expect(data['supportedMessages'], contains('overlayQueryCredentials'));
      expect(data['supportedMessages'], contains('overlayRevealForFill'));
    });

    test('an old host cannot serve overlay requests at all', () async {
      // The overlay request types did not exist before this slice, so an old
      // host classifies them as unknown and refuses. Had the strict policy been
      // a new field on `revealForFill`, that same old host would have ignored
      // the field and revealed under the lenient rule.
      expect(
        _preSlice009MessageTypes,
        isNot(contains('overlayQueryCredentials')),
      );
      expect(_preSlice009MessageTypes, isNot(contains('overlayRevealForFill')));

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'old-host',
        'type': 'overlayRevealForFill',
        'payload': {'entryId': 'entry-1', 'origin': 'https://example.com'},
      }, store: DesktopBrowserAutofillCacheStore(directory: Directory.current));
      // Sanity: this host does support it, so the refusal above comes from the
      // frozen list, not from the current binary.
      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        isNot('unsupported_type'),
      );
    });
  });

  group('009 A010 — overlayQueryCredentials', () {
    test('returns bounded metadata with no username or password', () async {
      final store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [
          _overlayEntry(),
          _overlayEntry(
            id: 'domain-only',
            domain: 'example.com',
            withExactOrigin: false,
          ),
          _overlayEntry(
            id: 'elsewhere',
            domain: 'other.example',
            exactOrigin: 'https://other.example',
          ),
        ],
      );
      final bridge = await _FakeOverlayBridge.start();
      addTearDown(bridge.close);
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          databaseId: 'db-a',
          cacheGeneration: 'cache-a',
          bridgeGeneration: 'bridge-a',
        ),
      );

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'overlay-query-1',
        'type': 'overlayQueryCredentials',
        'payload': {
          'url': 'https://example.com/login?token=x#frag',
          'matchPolicy': overlayMatchPolicy,
          'limit': 10,
        },
      }, store: store);

      expect(response['ok'], isTrue);
      final data = response['data']! as Map<String, Object?>;
      expect(data['matchPolicy'], overlayMatchPolicy);
      expect(data['target'], 'https://example.com');
      expect(data['sessionBinding'], {
        'databaseId': 'db-a',
        'cacheGeneration': 'cache-a',
        'bridgeGeneration': 'bridge-a',
      });

      final items = (data['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items, hasLength(2));
      final exact = items.firstWhere((i) => i['entryId'] == 'entry-1');
      expect(exact['matchType'], 'exact-origin');
      expect(exact['fillEligible'], isTrue);
      expect(exact.keys, [
        'entryId',
        'title',
        'displayService',
        'matchType',
        'fillEligible',
      ]);

      final possible = items.firstWhere((i) => i['entryId'] == 'domain-only');
      expect(possible['matchType'], 'possible');
      expect(possible['fillEligible'], isFalse);

      final encoded = jsonEncode(response);
      expect(encoded, isNot(contains('alice')));
      expect(encoded, isNot(contains('username')));
      expect(encoded, isNot(contains('password')));
      expect(encoded, isNot(contains('elsewhere')));
    });

    test('rejects a request that does not declare the strict policy', () async {
      final store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [_overlayEntry()],
      );

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'overlay-query-2',
        'type': 'overlayQueryCredentials',
        'payload': {'url': 'https://example.com'},
      }, store: store);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'invalid_request',
      );
    });

    test('nothing is fillable while the bridge is not current', () async {
      final store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [_overlayEntry()],
      );

      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'overlay-query-3',
        'type': 'overlayQueryCredentials',
        'payload': {
          'url': 'https://example.com',
          'matchPolicy': overlayMatchPolicy,
        },
      }, store: store);

      final data = response['data']! as Map<String, Object?>;
      expect(data['fillAvailable'], isFalse);
      expect(data['sessionBinding'], isNull);
      final items = (data['items']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(items.single['fillEligible'], isFalse);
    });

    test('a republish during the query returns stale_session', () async {
      final store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [_overlayEntry()],
      );
      final bridge = await _FakeOverlayBridge.start();
      addTearDown(bridge.close);
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          databaseId: 'db-a',
          cacheGeneration: 'cache-a',
          bridgeGeneration: 'bridge-a',
        ),
      );

      // The re-read before responding is what catches this: the vault is
      // republished after the snapshot was taken but before the answer is
      // written. `_RepublishingStore` fires that republish deterministically on
      // the re-read.
      final response = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'overlay-query-4',
        'type': 'overlayQueryCredentials',
        'payload': {
          'url': 'https://example.com',
          'matchPolicy': overlayMatchPolicy,
        },
      }, store: _RepublishingStore(store));
      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'stale_session',
      );
    });
  });

  group('009 A011 — overlayRevealForFill', () {
    late DesktopBrowserAutofillCacheStore store;
    late _FakeOverlayBridge bridge;

    Future<void> publish({
      String databaseId = 'db-a',
      String cacheGeneration = 'cache-a',
      String bridgeGeneration = 'bridge-a',
      List<DesktopBrowserAutofillCredentialMetadata>? entries,
    }) async {
      await store.writeMetadataCache(
        DesktopBrowserAutofillMetadataCache(
          version: desktopBrowserAutofillCacheVersion,
          databaseId: databaseId,
          cacheGeneration: cacheGeneration,
          generatedAtEpochMs: 1,
          entries: entries ?? [_overlayEntry()],
        ),
      );
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          databaseId: databaseId,
          cacheGeneration: cacheGeneration,
          bridgeGeneration: bridgeGeneration,
        ),
      );
    }

    setUp(() async {
      store = DesktopBrowserAutofillCacheStore(
        directory: await Directory.systemTemp.createTemp('kv-overlay-host-'),
      );
      bridge = await _FakeOverlayBridge.start();
      addTearDown(bridge.close);
      await publish();
    });

    test('reveals for an exact origin and echoes the binding', () async {
      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
      );

      expect(response['ok'], isTrue);
      final data = response['data']! as Map<String, Object?>;
      expect(data['password'], _overlaySecret);
      expect(data['matchPolicy'], overlayMatchPolicy);
      expect(data['sessionBinding'], {
        'databaseId': 'db-a',
        'cacheGeneration': 'cache-a',
        'bridgeGeneration': 'bridge-a',
      });
      expect(bridge.lastPayload?['matchPolicy'], overlayMatchPolicy);
      expect(bridge.lastPayload?['origin'], 'https://example.com');
    });

    test('an implicit default port matches an explicit one', () async {
      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com:443',
      );
      expect(response['ok'], isTrue);
    });

    test('a domain-only entry can never reveal', () async {
      await publish(entries: [_overlayEntry(withExactOrigin: false)]);

      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
      );

      expect(response['ok'], isFalse);
      expect((response['error']! as Map<String, Object?>)['code'], 'forbidden');
      expect(bridge.requestCount, 0);
      _expectNoSecret(response);
    });

    for (final entry in const {
      'scheme': 'http://example.com',
      'non-default port': 'https://example.com:8443',
      'phishing suffix': 'https://example.com.evil.test',
      'www label': 'https://www.example.com',
      'm label': 'https://m.example.com',
      'mobile label': 'https://mobile.example.com',
    }.entries) {
      test('${entry.key} differs and is refused', () async {
        final response = await _overlayReveal(
          store: store,
          origin: entry.value,
        );

        expect(response['ok'], isFalse);
        final error = response['error']! as Map<String, Object?>;
        expect(error['code'], 'forbidden');
        expect(bridge.requestCount, 0, reason: 'the app is never contacted');
        _expectNoSecret(response);
        // The refusal must not disclose which rule rejected it.
        final message = (error['message']! as String).toLowerCase();
        for (final leak in const ['scheme', 'port', 'host', 'label', 'http']) {
          expect(message, isNot(contains(leak)));
        }
      });
    }

    for (final mismatch in const [
      ('databaseId', 'db-b', 'cache-a', 'bridge-a'),
      ('cacheGeneration', 'db-a', 'cache-b', 'bridge-a'),
      ('bridgeGeneration', 'db-a', 'cache-a', 'bridge-b'),
    ]) {
      test('${mismatch.$1} mismatch is stale_session before the app', () async {
        final response = await _overlayReveal(
          store: store,
          origin: 'https://example.com',
          databaseId: mismatch.$2,
          cacheGeneration: mismatch.$3,
          bridgeGeneration: mismatch.$4,
        );

        expect(response['ok'], isFalse);
        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'stale_session',
        );
        expect(bridge.requestCount, 0);
        _expectNoSecret(response);
      });
    }

    test('a republish of the same vault invalidates an older grant', () async {
      // Same database, same entry, same origin — only the cache generation
      // moved. The grant minted before the republish must be dead anyway.
      await publish(cacheGeneration: 'cache-a2');

      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
        cacheGeneration: 'cache-a',
      );

      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'stale_session',
      );
      expect(bridge.requestCount, 0);
      _expectNoSecret(response);
    });

    test('a bridge restart invalidates an older grant', () async {
      await publish(bridgeGeneration: 'bridge-a2');

      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
        bridgeGeneration: 'bridge-a',
      );

      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'stale_session',
      );
      expect(bridge.requestCount, 0);
      _expectNoSecret(response);
    });

    test(
      'a delayed response is stale after a same-vault republish too',
      () async {
        // Weaker signal than a vault switch — the database id never changes —
        // so the post-response re-read has to compare the generations, not just
        // the database.
        bridge.onRequest = () async {
          await publish(cacheGeneration: 'cache-a2');
        };

        final response = await _overlayReveal(
          store: store,
          origin: 'https://example.com',
        );

        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'stale_session',
        );
        _expectNoSecret(response);
      },
    );

    test('a request without the strict policy is refused', () async {
      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
        matchPolicy: 'host',
      );

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'invalid_request',
      );
      expect(bridge.requestCount, 0);
    });

    test('an app response that does not echo the binding is dropped', () async {
      bridge.overrideData = {
        'entryId': 'entry-1',
        'matchPolicy': overlayMatchPolicy,
        'origin': 'https://example.com',
        'databaseId': 'db-a',
        'cacheGeneration': 'cache-b',
        'bridgeGeneration': 'bridge-a',
        'username': 'alice',
        'password': _overlaySecret,
      };

      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
      );

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_invalid_response',
      );
      _expectNoSecret(response);
    });

    test('A013 — a delayed vault A response after a switch to vault B with the '
        'same entry UUID and origin is stale_session', () async {
      // The app answers under vault A's binding, but by the time it answers,
      // vault B — same entry UUID, same origin, different secret — is the
      // published one. Only the post-response re-read catches this.
      bridge.onRequest = () async {
        await publish(
          databaseId: 'db-b',
          cacheGeneration: 'cache-b',
          bridgeGeneration: 'bridge-b',
          entries: [_overlayEntry()],
        );
      };

      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
      );

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'stale_session',
      );
      _expectNoSecret(response);

      // And the old grant cannot be replayed against vault B either.
      final replay = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
      );
      expect(
        (replay['error']! as Map<String, Object?>)['code'],
        'stale_session',
      );
    });

    test('an app without the overlay endpoint fails closed', () async {
      // A pre-009 app bridge has no `/overlay-reveal`; it answers `not_found`
      // and the host must not retry on the lenient `/reveal`.
      await bridge.close();
      final legacy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => legacy.close(force: true));
      var revealCalls = 0;
      legacy.listen((request) async {
        if (request.uri.path == '/reveal') {
          revealCalls += 1;
        }
        request.response.statusCode = HttpStatus.notFound;
        request.response.write(
          jsonEncode({
            'ok': false,
            'error': {'code': 'not_found'},
          }),
        );
        await request.response.close();
      });
      await store.writeBridgeDescriptor(
        DesktopBrowserAutofillBridgeDescriptor(
          version: desktopBrowserAutofillBridgeDescriptorVersion,
          port: legacy.port,
          token: bridge.token,
          databaseId: 'db-a',
          cacheGeneration: 'cache-a',
          bridgeGeneration: 'bridge-a',
          createdAtEpochMs: 1,
        ),
      );

      final response = await _overlayReveal(
        store: store,
        origin: 'https://example.com',
      );

      expect(response['ok'], isFalse);
      expect(revealCalls, 0);
      _expectNoSecret(response);
    });
  });

  // 009 / B007–B008 — generatePendingEntry.
  //
  // GitGuardian note: the test secret is assembled with join() and uses a
  // neutral name on purpose; no username/password literal pairs appear.
  group('009 B007/B008 — generatePendingEntry', () {
    late DesktopBrowserAutofillCacheStore store;
    late _FakeGenerateBridge bridge;

    setUp(() async {
      store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [_overlayEntry()],
      );
      bridge = await _FakeGenerateBridge.start();
      addTearDown(bridge.close);
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          databaseId: 'db-a',
          cacheGeneration: 'cache-a',
          bridgeGeneration: 'bridge-a',
        ),
      );
    });

    test('hello advertises the capability only when the app descriptor '
        'declares it', () async {
      final advertised = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'hello-gen',
        'type': 'hello',
      }, store: store);
      final data = advertised['data']! as Map<String, Object?>;
      expect(data['capabilities'], contains('generatePendingEntryV1'));
      expect(data['supportedMessages'], contains('generatePendingEntry'));

      // The host binary alone never advertises it: the capability follows
      // the app contract, not the host build.
      expect(nativeHostCapabilities, isNot(contains('generatePendingEntryV1')));

      // Old app: descriptor without the capability field.
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          databaseId: 'db-a',
          cacheGeneration: 'cache-a',
          bridgeGeneration: 'bridge-a',
          appCapabilities: const [],
        ),
      );
      final notAdvertised = await handleNativeHostRequest({
        'version': nativeProtocolVersion,
        'id': 'hello-gen-2',
        'type': 'hello',
      }, store: store);
      expect(
        (notAdvertised['data']! as Map<String, Object?>)['capabilities'],
        isNot(contains('generatePendingEntryV1')),
      );
    });

    test('a malformed appCapabilities field fails closed: no advertisement, '
        'no generation', () async {
      final capability = desktopBrowserGeneratePendingCapability;
      final malformed = <String, Object?>{
        'not a list': {'x': 1},
        'oversize list': List<String>.generate(
          17,
          (i) => i == 0 ? capability : 'cap-$i',
        ),
        'non-string element': <Object?>[capability, 5],
        'empty element': <Object?>[capability, ''],
        'oversize element': <Object?>[capability, 'a' * 65],
      };

      for (final entry in malformed.entries) {
        await store.bridgeDescriptorFile!.writeAsString(
          jsonEncode({
            'version': desktopBrowserAutofillBridgeDescriptorVersion,
            'port': bridge.server.port,
            'token': bridge.token,
            'databaseId': 'db-a',
            'cacheGeneration': 'cache-a',
            'bridgeGeneration': 'bridge-a',
            'createdAtEpochMs': 1,
            'appCapabilities': entry.value,
          }),
        );

        final hello = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'hello-malformed',
          'type': 'hello',
        }, store: store);
        expect(
          (hello['data']! as Map<String, Object?>)['capabilities'],
          isNot(contains(capability)),
          reason: entry.key,
        );

        final response = await _generatePending(store: store);
        expect(response['ok'], isFalse, reason: entry.key);
        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'unsupported_capability',
          reason: entry.key,
        );
      }
      expect(bridge.requestCount, 0);
    });

    test('an old host cannot serve generation at all', () async {
      // The request type did not exist before this slice, so an old host
      // answers `unsupported_type` — structural fail-closed, no fallback.
      expect(_preSlice009MessageTypes, isNot(contains('generatePendingEntry')));
    });

    test('an old app without the capability returns unsupported_capability, '
        'never a fallback', () async {
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          databaseId: 'db-a',
          cacheGeneration: 'cache-a',
          bridgeGeneration: 'bridge-a',
          appCapabilities: const [],
        ),
      );

      final response = await _generatePending(store: store);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'unsupported_capability',
      );
      expect(bridge.requestCount, 0);
      _expectNoGeneratedSecret(response);
    });

    test('returns the one-shot secret with expiry, echoed binding and '
        'settings revision', () async {
      final response = await _generatePending(store: store);

      expect(response['ok'], isTrue);
      final data = response['data']! as Map<String, Object?>;
      expect(data['pendingGenerationId'], 'pending-1');
      expect(data['password'], _generatedNativeValue);
      expect(data['settingsRevision'], 7);
      final expiresAt = data['expiresAtEpochMs']! as int;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      expect(expiresAt, greaterThan(nowMs));
      expect(expiresAt, lessThanOrEqualTo(nowMs + 5 * 60 * 1000 + 10000));
      expect(data['sessionBinding'], {
        'databaseId': 'db-a',
        'cacheGeneration': 'cache-a',
        'bridgeGeneration': 'bridge-a',
      });
      // Settings never travel: the app bridge request carried none.
      expect(jsonEncode(bridge.lastPayload), isNot(contains('settings')));
      expect(jsonEncode(bridge.lastPayload), isNot(contains('length')));
    });

    test('a non-default port survives canonicalization end to end', () async {
      final response = await _generatePending(
        store: store,
        origin: 'https://example.com:8443/login?next=/x',
      );

      expect(response['ok'], isTrue);
      expect(bridge.lastPayload!['origin'], 'https://example.com:8443');
      expect(
        (response['data']! as Map<String, Object?>)['origin'],
        'https://example.com:8443',
      );
    });

    test('malformed requests are invalid_request before any bridge '
        'call', () async {
      final cases = <Map<String, Object?>>[
        {'origin': 'https://example.com'}, // missing expected binding
        {
          // forbidden scheme
          'origin': 'ftp://example.com',
          'expectedDatabaseId': 'db-a',
          'expectedCacheGeneration': 'cache-a',
          'expectedBridgeGeneration': 'bridge-a',
        },
        {
          // extension scheme
          'origin': 'chrome-extension://abcdefg',
          'expectedDatabaseId': 'db-a',
          'expectedCacheGeneration': 'cache-a',
          'expectedBridgeGeneration': 'bridge-a',
        },
        {
          // settings are app-owned: rejected, not ignored
          'origin': 'https://example.com',
          'expectedDatabaseId': 'db-a',
          'expectedCacheGeneration': 'cache-a',
          'expectedBridgeGeneration': 'bridge-a',
          'settings': {'legnth': 4},
        },
      ];
      for (final payload in cases) {
        final response = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'gen-bad',
          'type': 'generatePendingEntry',
          'payload': payload,
        }, store: store);
        expect(response['ok'], isFalse, reason: jsonEncode(payload));
        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'invalid_request',
          reason: jsonEncode(payload),
        );
      }
      expect(bridge.requestCount, 0);
    });

    test('a locked app (no cache) cannot generate', () async {
      final locked = DesktopBrowserAutofillCacheStore(
        directory: await Directory.systemTemp.createTemp('kv-gen-locked-'),
      );
      final response = await _generatePending(store: locked);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_unavailable',
      );
      expect(bridge.requestCount, 0);
    });

    for (final mismatch in const [
      'expectedDatabaseId',
      'expectedCacheGeneration',
      'expectedBridgeGeneration',
    ]) {
      test('$mismatch mismatch is stale_session before the app is '
          'contacted', () async {
        final response = await _generatePending(
          store: store,
          databaseId: mismatch == 'expectedDatabaseId' ? 'db-other' : 'db-a',
          cacheGeneration: mismatch == 'expectedCacheGeneration'
              ? 'other'
              : 'cache-a',
          bridgeGeneration: mismatch == 'expectedBridgeGeneration'
              ? 'other'
              : 'bridge-a',
        );

        expect(response['ok'], isFalse);
        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'stale_session',
        );
        expect(bridge.requestCount, 0);
        _expectNoGeneratedSecret(response);
      });
    }

    test('a stalled app bridge is app_bridge_timeout, not a hang', () async {
      bridge.stall = true;

      final response = await _generatePending(store: store);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_timeout',
      );
      _expectNoGeneratedSecret(response);
    });

    test('an oversize password in the app response is refused', () async {
      bridge.overrideData = (payload, nowMs) => {
        ..._echoData(payload, nowMs),
        'password': 'a' * (32 * 1024 + 1),
      };

      final response = await _generatePending(store: store);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_invalid_response',
      );
    });

    test('an oversize app response body is refused at transport '
        'level', () async {
      bridge.overrideData = (payload, nowMs) => {
        ..._echoData(payload, nowMs),
        'padding': 'b' * (70 * 1024),
      };

      final response = await _generatePending(store: store);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_error',
      );
      _expectNoGeneratedSecret(response);
    });

    for (final broken in const [
      'settingsRevision',
      'expiresAtEpochMs',
      'pendingGenerationId',
      'databaseId',
      'cacheGeneration',
      'bridgeGeneration',
    ]) {
      test('a response with broken $broken is app_bridge_invalid_response '
          'and drops the secret', () async {
        bridge.overrideData = (payload, nowMs) => {
          ..._echoData(payload, nowMs),
          // Wrong type/ownership per field: revision 0 is not a committed
          // revision, expiry beyond 5 minutes breaks the pending contract,
          // and a binding echo that differs is another session's answer.
          if (broken == 'settingsRevision') 'settingsRevision': 0,
          if (broken == 'expiresAtEpochMs')
            'expiresAtEpochMs': nowMs + 10 * 60 * 1000,
          if (broken == 'pendingGenerationId') 'pendingGenerationId': '',
          if (broken == 'databaseId') 'databaseId': 'db-other',
          if (broken == 'cacheGeneration') 'cacheGeneration': 'other',
          if (broken == 'bridgeGeneration') 'bridgeGeneration': 'other',
        };

        final response = await _generatePending(store: store);

        expect(response['ok'], isFalse);
        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'app_bridge_invalid_response',
        );
        _expectNoGeneratedSecret(response);
      });
    }

    test('a vault republish after the app answered is stale_session', () async {
      final republishing = _RepublishingStore(store);
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          databaseId: 'db-a',
          cacheGeneration: 'cache-a',
          bridgeGeneration: 'bridge-a',
        ),
      );

      final response = await _generatePending(store: republishing);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'stale_session',
      );
      expect(bridge.requestCount, 1);
      _expectNoGeneratedSecret(response);
    });

    test('the native host persists and logs nothing: the secret exists only '
        'in the one-shot response', () async {
      Future<List<String>> filesUnder(Directory directory) async {
        return [
          await for (final f in directory.list(recursive: true))
            if (f is File) f.path,
        ];
      }

      final filesBefore = await filesUnder(store.directory!);
      final printed = <String>[];
      final recordedStderr = _RecordingStderr();
      late Map<String, Object?> response;
      // stderr is captured through IOOverrides so a `stderr.writeln` added to
      // the handler would land in the recorder, not the real fd. This is the
      // runtime check; the primary defence is the static writer inventory
      // guard, which scans `tool/` and fails on any filesystem writer there
      // (including one aimed at Directory.systemTemp, which no runtime scan
      // watches).
      await IOOverrides.runZoned(
        () => runZoned(
          () async {
            response = await _generatePending(store: store);
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => printed.add(line),
          ),
        ),
        stderr: () => recordedStderr,
      );

      expect(response['ok'], isTrue);
      // The true secret is searched for on every surface the host can write:
      // no new file, no existing file containing it, nothing printed.
      final filesAfter = await filesUnder(store.directory!);
      expect(filesAfter, unorderedEquals(filesBefore));
      for (final path in filesAfter) {
        expect(
          await File(path).readAsString(),
          isNot(contains(_generatedNativeValue)),
          reason: 'secret leaked to ${Uri.file(path).pathSegments.last}',
        );
      }
      expect(printed.join('\n'), isNot(contains(_generatedNativeValue)));
      expect(
        recordedStderr.buffer.toString(),
        isNot(contains(_generatedNativeValue)),
      );
    });
  });

  // ===========================================================================
  // 023 / T501 — passkeyAssert. The host is a courier: it forwards the
  // request to the app and hands back the signature, holding no key and
  // making no credential decision of its own.
  // ===========================================================================

  group('023 T501 — passkeyAssert', () {
    late DesktopBrowserAutofillCacheStore store;
    late _FakePasskeyBridge bridge;

    Map<String, Object?> request({
      String origin = 'https://example.com',
      String rpId = 'example.com',
      String challenge = 'Y2hhbGxlbmdl',
      Object? allowCredentials,
    }) => {
      'version': nativeProtocolVersion,
      'id': 'pk-1',
      'type': 'passkeyAssert',
      'payload': {
        'origin': origin,
        'rpId': rpId,
        'challenge': challenge,
        'allowCredentials': ?allowCredentials,
      },
    };

    setUp(() async {
      store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [_overlayEntry()],
      );
      bridge = await _FakePasskeyBridge.start();
      addTearDown(bridge.close);
      await store.writeBridgeDescriptor(bridge.descriptor());
    });

    test(
      'hello advertises the capability only when the app declares it',
      () async {
        final advertised = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'hello-pk',
          'type': 'hello',
        }, store: store);
        final data = advertised['data']! as Map<String, Object?>;
        expect(data['capabilities'], contains('passkeyAssertV1'));
        expect(data['supportedMessages'], contains('passkeyAssert'));

        // The host binary alone never claims it: signing belongs to the app.
        expect(nativeHostCapabilities, isNot(contains('passkeyAssertV1')));

        await store.writeBridgeDescriptor(
          bridge.descriptor(appCapabilities: const []),
        );
        final notAdvertised = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'hello-pk-2',
          'type': 'hello',
        }, store: store);
        expect(
          (notAdvertised['data']! as Map<String, Object?>)['capabilities'],
          isNot(contains('passkeyAssertV1')),
        );
      },
    );

    test('an old host answers unsupported_type, so the page falls back', () {
      // The frozen pre-009 list is the shape of a host the user may still
      // have installed. Its absence there is what makes the fallback
      // structural rather than contingent on a field check.
      expect(_preSlice009MessageTypes, isNot(contains('passkeyAssert')));
    });

    test('forwards the request and returns the assertion', () async {
      final response = await handleNativeHostRequest(request(), store: store);

      expect(response['ok'], isTrue);
      final data = response['data']! as Map<String, Object?>;
      expect(data['credentialId'], 'AQIDBAU');
      expect(data['signature'], 'c2ln');
      expect(data['authenticatorData'], 'YXV0aA');
      expect(data['clientDataJSON'], 'Y2xpZW50');
      expect(data['userHandle'], 'CQk');

      // What the app was asked, including the binding it did not have to
      // trust the extension for.
      expect(bridge.lastPayload!['databaseId'], 'db-a');
      expect(bridge.lastPayload!['rpId'], 'example.com');
      expect(bridge.lastPayload!['origin'], 'https://example.com');
    });

    test('a refusal is passed through as a reason, not an error', () async {
      bridge.refusalReason = 'declined';

      final response = await handleNativeHostRequest(request(), store: store);

      expect(response['ok'], isTrue);
      expect((response['data']! as Map<String, Object?>)['reason'], 'declined');
    });

    test('allowCredentials is forwarded, bounded, and filtered', () async {
      await handleNativeHostRequest(
        request(allowCredentials: ['AQIDBAU', 42, '', true]),
        store: store,
      );

      // Non-strings are dropped rather than rejecting the whole request: an
      // allow list is a hint, and a malformed one must not become a signing
      // failure the page cannot explain.
      expect(bridge.lastPayload!['allowCredentials'], ['AQIDBAU']);
    });

    test('allowCredentials that is not a list is refused', () async {
      final response = await handleNativeHostRequest(
        request(allowCredentials: 'AQIDBAU'),
        store: store,
      );

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'invalid_request',
      );
      expect(bridge.requestCount, 0);
    });

    test('a non-http(s) origin never reaches the app', () async {
      final response = await handleNativeHostRequest(
        request(origin: 'file:///etc/passwd'),
        store: store,
      );

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'invalid_request',
      );
      expect(bridge.requestCount, 0);
    });

    test('a missing challenge never reaches the app', () async {
      final response = await handleNativeHostRequest(
        request(challenge: '   '),
        store: store,
      );

      expect(response['ok'], isFalse);
      expect(bridge.requestCount, 0);
    });

    test(
      'an app that cannot sign is told apart from one that refused',
      () async {
        await store.writeBridgeDescriptor(
          bridge.descriptor(appCapabilities: const []),
        );

        final response = await handleNativeHostRequest(request(), store: store);

        expect(response['ok'], isFalse);
        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'passkey_unavailable',
        );
        expect(bridge.requestCount, 0);
      },
    );

    test('no descriptor at all is app_bridge_unavailable', () async {
      await store.clearBridgeDescriptor();

      final response = await handleNativeHostRequest(request(), store: store);

      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_unavailable',
      );
    });

    test('a truncated app response is refused rather than half-used', () async {
      bridge.overrideData = (_) => {'credentialId': 'AQIDBAU'};

      final response = await handleNativeHostRequest(request(), store: store);

      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_invalid_response',
      );
    });

    test('a response carrying privateKeyPem is rejected', () async {
      bridge.overrideData = (_) => {
        'credentialId': 'AQIDBAU',
        'authenticatorData': 'YXV0aA',
        'signature': 'c2ln',
        'clientDataJSON': 'Y2xpZW50',
        'privateKeyPem': '-----BEGIN PRIVATE KEY-----',
      };

      final response = await handleNativeHostRequest(request(), store: store);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_invalid_response',
      );
      expect(jsonEncode(response), isNot(contains('PRIVATE KEY')));
    });

    test(
      'the challenge and credential ids never echo back in an error',
      () async {
        final response = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'pk-echo',
          'type': 'passkeyAssert',
          'payload': {
            'origin': 'file:///nope',
            'rpId': 'example.com',
            'challenge': 'super-distinctive-challenge',
            'allowCredentials': ['super-distinctive-credential'],
          },
        }, store: store);

        final encoded = jsonEncode(response);
        expect(encoded, isNot(contains('super-distinctive-challenge')));
        expect(encoded, isNot(contains('super-distinctive-credential')));
      },
    );
  });

  // 023 US3 — the registration courier. The finding this covers: the relying
  // party's own `user.id` was never forwarded, so the app minted a handle of
  // its own and the site could not resolve a discoverable sign-in back to an
  // account.
  group('023 US3 — passkeyCreate', () {
    late DesktopBrowserAutofillCacheStore store;
    late _FakePasskeyBridge bridge;

    Map<String, Object?> request({
      String origin = 'https://example.com',
      String rpId = 'example.com',
      String challenge = 'Y2hhbGxlbmdl',
      String username = 'ada',
      Object? userHandle = 'AQIDBA',
    }) => {
      'version': nativeProtocolVersion,
      'id': 'pk-create-1',
      'type': 'passkeyCreate',
      'payload': {
        'origin': origin,
        'rpId': rpId,
        'challenge': challenge,
        'username': username,
        'userHandle': ?userHandle,
      },
    };

    setUp(() async {
      store = await _overlayStore(
        databaseId: 'db-a',
        cacheGeneration: 'cache-a',
        entries: [_overlayEntry()],
      );
      bridge = await _FakePasskeyBridge.start();
      addTearDown(bridge.close);
      await store.writeBridgeDescriptor(
        bridge.descriptor(
          appCapabilities: const [desktopBrowserPasskeyCreateCapability],
        ),
      );
    });

    test('forwards the request and returns the new credential', () async {
      final response = await handleNativeHostRequest(request(), store: store);

      expect(response['ok'], isTrue);
      final data = response['data']! as Map<String, Object?>;
      expect(data['credentialId'], 'AQIDBAU');
      expect(data['attestationObject'], 'YXR0');
      expect(data['clientDataJSON'], 'Y2xpZW50');
      expect(data['publicKeyCose'], 'Y29zZQ');

      expect(bridge.lastPayload!['databaseId'], 'db-a');
      expect(bridge.lastPayload!['rpId'], 'example.com');
      expect(bridge.lastPayload!['origin'], 'https://example.com');
      expect(bridge.lastPayload!['username'], 'ada');
      // The account identifier the relying party issued, forwarded as given.
      expect(bridge.lastPayload!['userHandle'], 'AQIDBA');
    });

    test('an absent user handle reaches the app as an empty string', () async {
      await handleNativeHostRequest(request(userHandle: null), store: store);

      expect(bridge.lastPayload!['userHandle'], '');
    });

    test('an over-long user handle is dropped, not forwarded', () async {
      // Longer than the base64url form of WebAuthn\'s 64-byte ceiling, so it
      // is not a handle this authenticator could have been issued.
      await handleNativeHostRequest(
        request(userHandle: 'A' * 200),
        store: store,
      );

      expect(bridge.lastPayload!['userHandle'], '');
    });

    test(
      'hello advertises the capability only when the app declares it',
      () async {
        final advertised = await handleNativeHostRequest({
          'version': nativeProtocolVersion,
          'id': 'hello-create',
          'type': 'hello',
        }, store: store);
        final data = advertised['data']! as Map<String, Object?>;
        expect(data['capabilities'], contains('passkeyCreateV1'));
        expect(data['supportedMessages'], contains('passkeyCreate'));
        expect(nativeHostCapabilities, isNot(contains('passkeyCreateV1')));

        await store.writeBridgeDescriptor(
          bridge.descriptor(appCapabilities: const []),
        );
        final response = await handleNativeHostRequest(request(), store: store);
        expect(response['ok'], isFalse);
        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'passkey_create_unavailable',
        );
        expect(bridge.requestCount, 0);
      },
    );

    test('an old host answers unsupported_type, so the page falls back', () {
      expect(_preSlice009MessageTypes, isNot(contains('passkeyCreate')));
    });

    test('a {reason} refusal is passed through unchanged', () async {
      bridge.refusalReason = 'user_cancelled';

      final response = await handleNativeHostRequest(request(), store: store);

      expect(response['ok'], isTrue);
      expect(response['data'], {'reason': 'user_cancelled'});
    });

    for (final missing in [
      'credentialId',
      'attestationObject',
      'clientDataJSON',
    ]) {
      test('a response without $missing is refused', () async {
        bridge.overrideData = (_) => {
          'credentialId': 'AQIDBAU',
          'attestationObject': 'YXR0',
          'clientDataJSON': 'Y2xpZW50',
        }..remove(missing);

        final response = await handleNativeHostRequest(request(), store: store);

        expect(response['ok'], isFalse);
        expect(
          (response['error']! as Map<String, Object?>)['code'],
          'app_bridge_invalid_response',
        );
      });
    }

    test('a response carrying privateKeyPem is rejected', () async {
      bridge.overrideData = (_) => {
        'credentialId': 'AQIDBAU',
        'attestationObject': 'YXR0',
        'clientDataJSON': 'Y2xpZW50',
        'publicKeyCose': 'Y29zZQ',
        'privateKeyPem': '-----BEGIN PRIVATE KEY-----',
      };

      final response = await handleNativeHostRequest(request(), store: store);

      expect(response['ok'], isFalse);
      expect(
        (response['error']! as Map<String, Object?>)['code'],
        'app_bridge_invalid_response',
      );
      expect(jsonEncode(response), isNot(contains('PRIVATE KEY')));
    });
  });
}

/// Captures everything written to the process `stderr` inside an
/// [IOOverrides] zone. Only the write surface is implemented; any other use
/// of the [Stdout] API by the handler under test is itself a violation and
/// fails loudly.
class _RecordingStderr implements Stdout {
  final buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void writeAll(Iterable<Object?> objects, [String sep = '']) =>
      buffer.writeAll(objects, sep);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) =>
      buffer.write(utf8.decode(data, allowMalformed: true));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected stderr use: ${invocation.memberName}');
}

final _generatedNativeValue = ['kv', 'gen', 'native', 'value', '7f2'].join('-');

Future<Map<String, Object?>> _generatePending({
  required DesktopBrowserAutofillCacheStore store,
  String origin = 'https://example.com',
  String databaseId = 'db-a',
  String cacheGeneration = 'cache-a',
  String bridgeGeneration = 'bridge-a',
}) {
  return handleNativeHostRequest({
    'version': nativeProtocolVersion,
    'id': 'generate-1',
    'type': 'generatePendingEntry',
    'payload': {
      'origin': origin,
      'expectedDatabaseId': databaseId,
      'expectedCacheGeneration': cacheGeneration,
      'expectedBridgeGeneration': bridgeGeneration,
    },
  }, store: store);
}

void _expectNoGeneratedSecret(Map<String, Object?> response) {
  expect(jsonEncode(response), isNot(contains(_generatedNativeValue)));
}

Map<String, Object?> _echoData(Map<String, Object?> payload, int nowMs) {
  return {
    'pendingGenerationId': 'pending-1',
    'expiresAtEpochMs': nowMs + 4 * 60 * 1000,
    'databaseId': payload['databaseId'],
    'cacheGeneration': payload['cacheGeneration'],
    'bridgeGeneration': payload['bridgeGeneration'],
    'settingsRevision': 7,
    'password': _generatedNativeValue,
  };
}

/// Fake app bridge implementing `/generate-pending`, echoing the binding the
/// way the real app does so the host's echo validation runs for real.
class _FakeGenerateBridge {
  _FakeGenerateBridge._({required this.server, required this.token}) {
    server.listen(_handleRequest);
  }

  static Future<_FakeGenerateBridge> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeGenerateBridge._(
      server: server,
      token: 'fake-token-fake-token-fake-token-fake-token',
    );
  }

  final HttpServer server;
  final String token;
  int requestCount = 0;
  Map<String, Object?>? lastPayload;
  bool stall = false;
  Map<String, Object?> Function(Map<String, Object?> payload, int nowMs)?
  overrideData;

  DesktopBrowserAutofillBridgeDescriptor descriptor({
    required String databaseId,
    required String cacheGeneration,
    required String bridgeGeneration,
    List<String> appCapabilities = const [
      desktopBrowserGeneratePendingCapability,
    ],
  }) {
    return DesktopBrowserAutofillBridgeDescriptor(
      version: desktopBrowserAutofillBridgeDescriptorVersion,
      port: server.port,
      token: token,
      databaseId: databaseId,
      cacheGeneration: cacheGeneration,
      bridgeGeneration: bridgeGeneration,
      createdAtEpochMs: 1,
      appCapabilities: appCapabilities,
    );
  }

  Future<void> close() async {
    await server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    requestCount += 1;
    if (stall) {
      // Never answer; the host's 2-second budget must fire. The server is
      // force-closed in teardown.
      return;
    }
    request.response.headers.contentType = ContentType.json;
    if (request.method != 'POST' || request.uri.path != '/generate-pending') {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error': {'code': 'not_found'},
        }),
      );
      await request.response.close();
      return;
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $token') {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error': {'code': 'unauthorized'},
        }),
      );
      await request.response.close();
      return;
    }

    final payload = jsonDecode(
      await utf8.decoder.bind(request).join(),
    ) as Map<String, Object?>;
    lastPayload = payload;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    request.response.statusCode = HttpStatus.ok;
    request.response.write(
      jsonEncode({
        'ok': true,
        'data': overrideData?.call(payload, nowMs) ?? _echoData(payload, nowMs),
      }),
    );
    await request.response.close();
  }
}

/// The v2 request types that existed before spec 009 Slice A1.
///
/// Frozen on purpose: it is the shape of a native host the user may still have
/// installed. The overlay types must be absent from it, because that absence is
/// what makes an old host answer `unsupported_type` instead of silently
/// applying the lenient host-only policy to an overlay request.
const _preSlice009MessageTypes = <String>[
  'hello',
  'status',
  'queryCredentials',
  'searchCredentials',
  'createPendingAssociation',
  'revealForFill',
];

const _overlaySecret = 'overlay-only-secret';

/// Republishes the vault the second time the metadata cache is read, i.e.
/// exactly on the "re-read immediately before responding" step of SR-4.
///
/// A subclass rather than a mock so that the production handler, the production
/// store and the production comparison all run unmodified.
class _RepublishingStore extends DesktopBrowserAutofillCacheStore {
  _RepublishingStore(this.delegate) : super(directory: delegate.directory);

  final DesktopBrowserAutofillCacheStore delegate;
  int reads = 0;

  @override
  Future<DesktopBrowserAutofillMetadataCache?> readMetadataCache() async {
    reads += 1;
    if (reads == 2) {
      await delegate.writeMetadataCache(
        DesktopBrowserAutofillMetadataCache(
          version: desktopBrowserAutofillCacheVersion,
          databaseId: 'db-a',
          cacheGeneration: 'cache-a2',
          generatedAtEpochMs: 2,
          entries: [_overlayEntry()],
        ),
      );
    }
    return super.readMetadataCache();
  }
}

Future<DesktopBrowserAutofillCacheStore> _overlayStore({
  required String databaseId,
  required String cacheGeneration,
  required List<DesktopBrowserAutofillCredentialMetadata> entries,
}) async {
  final store = DesktopBrowserAutofillCacheStore(
    directory: await Directory.systemTemp.createTemp('kv-overlay-host-'),
  );
  await store.writeMetadataCache(
    DesktopBrowserAutofillMetadataCache(
      version: desktopBrowserAutofillCacheVersion,
      databaseId: databaseId,
      cacheGeneration: cacheGeneration,
      generatedAtEpochMs: 1,
      entries: entries,
    ),
  );
  return store;
}

DesktopBrowserAutofillCredentialMetadata _overlayEntry({
  String id = 'entry-1',
  String exactOrigin = 'https://example.com',
  String domain = 'example.com',
  bool withExactOrigin = true,
}) {
  return DesktopBrowserAutofillCredentialMetadata(
    id: id,
    title: 'Example',
    username: 'alice',
    displayService: domain,
    serviceIdentifiers: [
      DesktopBrowserAutofillServiceIdentifier(type: 'domain', value: domain),
      if (withExactOrigin)
        DesktopBrowserAutofillServiceIdentifier(
          type: exactOriginServiceIdentifierType,
          value: exactOrigin,
        ),
    ],
    updatedAtEpochMs: 1,
  );
}

Future<Map<String, Object?>> _overlayReveal({
  required DesktopBrowserAutofillCacheStore store,
  required String origin,
  String entryId = 'entry-1',
  String databaseId = 'db-a',
  String cacheGeneration = 'cache-a',
  String bridgeGeneration = 'bridge-a',
  String matchPolicy = overlayMatchPolicy,
}) {
  return handleNativeHostRequest({
    'version': nativeProtocolVersion,
    'id': 'overlay-reveal-1',
    'type': 'overlayRevealForFill',
    'payload': {
      'entryId': entryId,
      'origin': origin,
      'matchPolicy': matchPolicy,
      'expectedDatabaseId': databaseId,
      'expectedCacheGeneration': cacheGeneration,
      'expectedBridgeGeneration': bridgeGeneration,
    },
  }, store: store);
}

void _expectNoSecret(Map<String, Object?> response) {
  final encoded = jsonEncode(response);
  expect(encoded, isNot(contains(_overlaySecret)));
  expect(encoded, isNot(contains('alice')));
}

/// Fake app bridge implementing `/overlay-reveal`.
///
/// Echoes the SR-4 binding exactly as the real app does, so the native host's
/// own echo validation is exercised rather than bypassed. [onRequest] runs
/// before the response is written and is how the delayed vault A -> B
/// regression swaps the published vault mid-flight.
class _FakeOverlayBridge {
  _FakeOverlayBridge._({required this.server, required this.token}) {
    server.listen(_handleRequest);
  }

  static Future<_FakeOverlayBridge> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeOverlayBridge._(
      server: server,
      token: 'fake-token-fake-token-fake-token-fake-token',
    );
  }

  final HttpServer server;
  final String token;
  int requestCount = 0;
  Map<String, Object?>? lastPayload;
  Future<void> Function()? onRequest;
  Map<String, Object?>? overrideData;

  DesktopBrowserAutofillBridgeDescriptor descriptor({
    required String databaseId,
    required String cacheGeneration,
    required String bridgeGeneration,
  }) {
    return DesktopBrowserAutofillBridgeDescriptor(
      version: desktopBrowserAutofillBridgeDescriptorVersion,
      port: server.port,
      token: token,
      databaseId: databaseId,
      cacheGeneration: cacheGeneration,
      bridgeGeneration: bridgeGeneration,
      createdAtEpochMs: 1,
    );
  }

  Future<void> close() async {
    await server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    requestCount += 1;
    request.response.headers.contentType = ContentType.json;
    if (request.method != 'POST' || request.uri.path != '/overlay-reveal') {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error': {'code': 'not_found'},
        }),
      );
      await request.response.close();
      return;
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $token') {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error': {'code': 'unauthorized'},
        }),
      );
      await request.response.close();
      return;
    }

    final payload = jsonDecode(
      await utf8.decoder.bind(request).join(),
    ) as Map<String, Object?>;
    lastPayload = payload;
    await onRequest?.call();

    request.response.statusCode = HttpStatus.ok;
    request.response.write(
      jsonEncode({
        'ok': true,
        'data':
            overrideData ??
            {
              'entryId': payload['entryId'],
              'matchPolicy': payload['matchPolicy'],
              'origin': payload['origin'],
              'databaseId': payload['databaseId'],
              'cacheGeneration': payload['cacheGeneration'],
              'bridgeGeneration': payload['bridgeGeneration'],
              'username': 'alice',
              'password': _overlaySecret,
            },
      }),
    );
    await request.response.close();
  }
}

typedef _RevealAttempt = ({Map<String, Object?> response, int bridgeCalls});

Future<_RevealAttempt> _revealForFill({
  required List<DesktopBrowserAutofillServiceIdentifier> identifiers,
  required String origin,
}) async {
  final directory = await Directory.systemTemp.createTemp('kv-native-host-');
  final store = DesktopBrowserAutofillCacheStore(directory: directory);
  await store.writeMetadataCache(
    DesktopBrowserAutofillMetadataCache(
      version: desktopBrowserAutofillCacheVersion,
      databaseId: 'db-1',
      cacheGeneration: 'cache-gen-1',
      generatedAtEpochMs: 1,
      entries: [
        DesktopBrowserAutofillCredentialMetadata(
          id: 'entry-1',
          title: 'Example',
          username: 'alice',
          displayService: 'example.test',
          serviceIdentifiers: identifiers,
          updatedAtEpochMs: 1,
        ),
      ],
    ),
  );

  final bridge = await _FakeRevealBridge.start(
    responseData: const {
      'entryId': 'entry-1',
      'username': 'alice',
      'password': 'test-only-secret',
    },
  );
  addTearDown(bridge.close);
  await store.writeBridgeDescriptor(bridge.descriptor(databaseId: 'db-1'));

  final response = await handleNativeHostRequest({
    'version': nativeProtocolVersion,
    'id': 'reveal-origin',
    'type': 'revealForFill',
    'payload': {'entryId': 'entry-1', 'origin': origin},
  }, store: store);

  return (response: response, bridgeCalls: bridge.requestCount);
}

void _expectRevealRefused(_RevealAttempt attempt) {
  expect(attempt.response['ok'], isFalse);
  final error = attempt.response['error']! as Map<String, Object?>;
  expect(error['code'], 'strong_match_required');
  // The bridge must never be asked for the secret in the first place.
  expect(attempt.bridgeCalls, 0);
  final encoded = jsonEncode(attempt.response);
  expect(encoded, isNot(contains('test-only-secret')));
  expect(encoded, isNot(contains('alice')));
  // The refusal must not tell the caller which rule rejected it.
  final message = (error['message']! as String).toLowerCase();
  expect(message, isNot(contains('scheme')));
  expect(message, isNot(contains('http')));
  expect(message, isNot(contains('port')));
}

class _FakeRevealBridge {
  _FakeRevealBridge._({
    required this.server,
    required this.token,
    required this.responseData,
  }) {
    server.listen(_handleRequest);
  }

  static Future<_FakeRevealBridge> start({
    required Map<String, Object?> responseData,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeRevealBridge._(
      server: server,
      token: 'fake-token-fake-token-fake-token-fake-token',
      responseData: responseData,
    );
  }

  final HttpServer server;
  final String token;
  final Map<String, Object?> responseData;
  int requestCount = 0;
  Map<String, Object?>? lastPayload;

  DesktopBrowserAutofillBridgeDescriptor descriptor({
    required String databaseId,
  }) {
    return DesktopBrowserAutofillBridgeDescriptor(
      version: desktopBrowserAutofillBridgeDescriptorVersion,
      port: server.port,
      token: token,
      databaseId: databaseId,
      cacheGeneration: 'cache-gen-1',
      bridgeGeneration: 'bridge-gen-1',
      createdAtEpochMs: 1,
    );
  }

  Future<void> close() async {
    await server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    requestCount += 1;
    request.response.headers.contentType = ContentType.json;
    if (request.method != 'POST' || request.uri.path != '/reveal') {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error': {'code': 'not_found'},
        }),
      );
      await request.response.close();
      return;
    }

    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $token') {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error': {'code': 'unauthorized'},
        }),
      );
      await request.response.close();
      return;
    }

    final payload = await utf8.decoder.bind(request).join();
    lastPayload = jsonDecode(payload) as Map<String, Object?>;
    request.response.statusCode = HttpStatus.ok;
    request.response.write(jsonEncode({'ok': true, 'data': responseData}));
    await request.response.close();
  }
}

/// Fake app bridge implementing `/passkey-assert`. It answers with fixed
/// base64url strings: the host must not interpret them, only carry them.
class _FakePasskeyBridge {
  _FakePasskeyBridge._({required this.server, required this.token}) {
    server.listen(_handleRequest);
  }

  static Future<_FakePasskeyBridge> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakePasskeyBridge._(
      server: server,
      token: 'fake-token-fake-token-fake-token-fake-token',
    );
  }

  final HttpServer server;
  final String token;
  int requestCount = 0;
  Map<String, Object?>? lastPayload;
  String? refusalReason;
  Map<String, Object?> Function(Map<String, Object?> payload)? overrideData;

  DesktopBrowserAutofillBridgeDescriptor descriptor({
    List<String> appCapabilities = const [
      desktopBrowserPasskeyAssertCapability,
    ],
  }) {
    return DesktopBrowserAutofillBridgeDescriptor(
      version: desktopBrowserAutofillBridgeDescriptorVersion,
      port: server.port,
      token: token,
      databaseId: 'db-a',
      cacheGeneration: 'cache-a',
      bridgeGeneration: 'bridge-a',
      createdAtEpochMs: 1,
      appCapabilities: appCapabilities,
    );
  }

  Future<void> close() => server.close(force: true);

  Future<void> _handleRequest(HttpRequest request) async {
    requestCount += 1;
    request.response.headers.contentType = ContentType.json;
    final path = request.uri.path;
    if (request.method != 'POST' ||
        (path != '/passkey-assert' && path != '/passkey-create')) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error': {'code': 'not_found'},
        }),
      );
      await request.response.close();
      return;
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $token') {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error': {'code': 'unauthorized'},
        }),
      );
      await request.response.close();
      return;
    }

    final payload = jsonDecode(
      await utf8.decoder.bind(request).join(),
    ) as Map<String, Object?>;
    lastPayload = payload;

    request.response.statusCode = HttpStatus.ok;
    if (refusalReason != null) {
      request.response.write(
        jsonEncode({
          'ok': false,
          'data': {'reason': refusalReason},
        }),
      );
      await request.response.close();
      return;
    }
    request.response.write(
      jsonEncode({
        'ok': true,
        'data':
            overrideData?.call(payload) ??
            (path == '/passkey-create'
                ? {
                    'credentialId': 'AQIDBAU',
                    'attestationObject': 'YXR0',
                    'clientDataJSON': 'Y2xpZW50',
                    'publicKeyCose': 'Y29zZQ',
                  }
                : {
                    'credentialId': 'AQIDBAU',
                    'authenticatorData': 'YXV0aA',
                    'signature': 'c2ln',
                    'clientDataJSON': 'Y2xpZW50',
                    'userHandle': 'CQk',
                  }),
      }),
    );
    await request.response.close();
  }
}
