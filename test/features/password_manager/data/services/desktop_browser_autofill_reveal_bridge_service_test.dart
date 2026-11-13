import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/browser_exact_origin.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_autofill_cache.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_autofill_reveal_bridge_service.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_pending_generation_service.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/repositories/password_generator_settings_repository.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/domain/services/password_generator_service.dart';

import '../../../../fixtures/passkeys/vectors.dart';

void main() {
  group('DesktopBrowserAutofillRevealBridgeService', () {
    test('returns credentials only from authenticated exact reveal', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-reveal-bridge-',
      );
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final service = DesktopBrowserAutofillRevealBridgeService(
        store: store,
        mapper: const DesktopBrowserAutofillMetadataMapper(),
      );
      addTearDown(service.stop);

      await service.start(
        databasePath: '/vaults/example.kdbx',
        entries: [
          _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'super-secret',
            url: 'https://example.com/login',
          ),
        ],
      );

      final descriptor = await store.readBridgeDescriptor();
      expect(descriptor, isNotNull);
      final descriptorJson = await store.bridgeDescriptorFile!.readAsString();
      expect(descriptorJson, isNot(contains('super-secret')));
      expect(descriptorJson, isNot(contains('alice')));

      final response = await _postBridge(
        descriptor: descriptor!,
        body: {
          'databaseId': descriptor.databaseId,
          'entryId': 'entry-1',
          'origin': 'https://example.com',
        },
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.json['ok'], isTrue);
      final data = response.json['data']! as Map<String, Object?>;
      expect(data['entryId'], 'entry-1');
      expect(data['username'], 'alice');
      expect(data['password'], 'super-secret');
    });

    test('returns authenticated status without credential data', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-reveal-bridge-',
      );
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final service = DesktopBrowserAutofillRevealBridgeService(
        store: store,
        mapper: const DesktopBrowserAutofillMetadataMapper(),
      );
      addTearDown(service.stop);
      await service.start(
        databasePath: '/vaults/example.kdbx',
        entries: [
          _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'super-secret',
            url: 'https://example.com/login',
          ),
        ],
      );
      final descriptor = (await store.readBridgeDescriptor())!;

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/status',
        body: const {},
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.json, {
        'ok': true,
        'data': {'databaseId': descriptor.databaseId},
      });
      expect(jsonEncode(response.json), isNot(contains('alice')));
      expect(jsonEncode(response.json), isNot(contains('super-secret')));
    });

    test('rejects reveal without valid bearer token', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-reveal-bridge-',
      );
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final service = DesktopBrowserAutofillRevealBridgeService(
        store: store,
        mapper: const DesktopBrowserAutofillMetadataMapper(),
      );
      addTearDown(service.stop);

      await service.start(
        databasePath: '/vaults/example.kdbx',
        entries: [
          _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'super-secret',
            url: 'https://example.com/login',
          ),
        ],
      );

      final descriptor = (await store.readBridgeDescriptor())!;
      final response = await _postBridge(
        descriptor: descriptor,
        authorizationToken: 'wrong-token',
        body: {
          'databaseId': descriptor.databaseId,
          'entryId': 'entry-1',
          'origin': 'https://example.com',
        },
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      final error = response.json['error']! as Map<String, Object?>;
      expect(error['code'], 'unauthorized');
      expect(jsonEncode(response.json), isNot(contains('super-secret')));
    });

    test('denies phishing host that only contains credential host', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-reveal-bridge-',
      );
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final service = DesktopBrowserAutofillRevealBridgeService(
        store: store,
        mapper: const DesktopBrowserAutofillMetadataMapper(),
      );
      addTearDown(service.stop);

      await service.start(
        databasePath: '/vaults/example.kdbx',
        entries: [
          _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'super-secret',
            url: 'https://example.com',
          ),
        ],
      );

      final descriptor = (await store.readBridgeDescriptor())!;
      final response = await _postBridge(
        descriptor: descriptor,
        body: {
          'databaseId': descriptor.databaseId,
          'entryId': 'entry-1',
          'origin': 'https://example.com.evil.com',
        },
      );

      expect(response.statusCode, HttpStatus.forbidden);
      expect(jsonEncode(response.json), isNot(contains('super-secret')));
      final error = response.json['error']! as Map<String, Object?>;
      expect(error['code'], 'strong_match_required');
    });

    group('origin scheme and port binding', () {
      test('denies https entry on a downgraded http page', () async {
        _expectRevealRefused(
          await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: 'https://example.test/login',
            ),
            origin: 'http://example.test',
          ),
        );
      });

      test('still allows the matching https page', () async {
        final response = await _reveal(
          entry: _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'test-only-secret',
            url: 'https://example.test/login',
          ),
          origin: 'https://example.test',
        );

        expect(response.statusCode, HttpStatus.ok);
        final data = response.json['data']! as Map<String, Object?>;
        expect(data['password'], 'test-only-secret');
      });

      test('denies a port mismatch on the same host', () async {
        _expectRevealRefused(
          await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: 'https://example.test:8443/login',
            ),
            origin: 'https://example.test',
          ),
        );
      });

      test('allows a domain-only entry on an https page', () async {
        final response = await _reveal(
          entry: _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'test-only-secret',
            url: '',
            customFields: const [
              VaultCustomField(key: 'domain', value: 'example.test'),
            ],
          ),
          origin: 'https://example.test',
        );

        expect(response.statusCode, HttpStatus.ok);
        final data = response.json['data']! as Map<String, Object?>;
        expect(data['password'], 'test-only-secret');
      });

      test('denies a domain-only entry on an http page', () async {
        _expectRevealRefused(
          await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: '',
              customFields: const [
                VaultCustomField(key: 'domain', value: 'example.test'),
              ],
            ),
            origin: 'http://example.test',
          ),
        );
      });

      test('allows the http entry / https page upgrade', () async {
        final response = await _reveal(
          entry: _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'test-only-secret',
            url: 'http://example.test/login',
          ),
          origin: 'https://example.test',
        );

        expect(response.statusCode, HttpStatus.ok);
        final data = response.json['data']! as Map<String, Object?>;
        expect(data['password'], 'test-only-secret');
      });
    });

    group('hosts that cannot obtain a WebPKI certificate', () {
      // A URL stored without a scheme declares no origin, so it must not be
      // pinned to an inferred `https://`. On these hosts `https` is not
      // obtainable at all, so `http` is the only origin they can ever have.
      for (final host in const [
        '192.168.1.10', // RFC 1918
        '10.4.0.7', // RFC 1918
        '172.16.9.9', // RFC 1918
        '127.0.0.1', // RFC 1122 loopback
        '169.254.10.10', // RFC 3927 link-local
        'nas', // single label
        'router.local', // RFC 6762
        'printer.home.arpa', // RFC 8375
        'wiki.internal',
        'vault.lan',
      ]) {
        test('allows $host over http when stored without a scheme', () async {
          final response = await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: host,
            ),
            origin: 'http://$host',
          );

          expect(response.statusCode, HttpStatus.ok);
          final data = response.json['data']! as Map<String, Object?>;
          expect(data['password'], 'test-only-secret');
        });
      }

      // The other side of the same criterion: on these hosts `https` *is*
      // obtainable, so a bare host stays denied over cleartext http.
      for (final host in const [
        'bank.example', // bare public domain: the most common entry shape
        '1.1.1.1', // a public IP literal can hold a WebPKI certificate
        'example.test', // RFC 2606, deliberately kept out of the allow set
      ]) {
        test('denies $host over http when stored without a scheme', () async {
          _expectRevealRefused(
            await _reveal(
              entry: _entry(
                id: 'entry-1',
                username: 'alice',
                password: 'test-only-secret',
                url: host,
              ),
              origin: 'http://$host',
            ),
          );
        });

        test('still allows $host over https', () async {
          final response = await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: host,
            ),
            origin: 'https://$host',
          );

          expect(response.statusCode, HttpStatus.ok);
        });
      }

      test(
        'denies an explicit https entry on a private-IP http page',
        () async {
          // The de-pin only covers inferred schemes: a declared origin still wins.
          _expectRevealRefused(
            await _reveal(
              entry: _entry(
                id: 'entry-1',
                username: 'alice',
                password: 'test-only-secret',
                url: 'https://192.168.1.10',
              ),
              origin: 'http://192.168.1.10',
            ),
          );
        },
      );
    });

    group('default ports written explicitly', () {
      // Guards a `dart:core` Uri property, not our own code: Uri drops a port
      // equal to the scheme default, so `https://h:443` and `https://h` share
      // one normalized origin. An SDK upgrade that changed it would otherwise
      // start denying these silently.
      for (final (entryUrl, origin) in const [
        ('https://example.test:443/login', 'https://example.test'),
        ('https://example.test/login', 'https://example.test:443'),
        ('http://example.test:80/login', 'http://example.test'),
        ('http://example.test/login', 'http://example.test:80'),
      ]) {
        test('allows $entryUrl on $origin', () async {
          final response = await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: entryUrl,
            ),
            origin: origin,
          );

          expect(response.statusCode, HttpStatus.ok);
          final data = response.json['data']! as Map<String, Object?>;
          expect(data['password'], 'test-only-secret');
        });
      }

      test('denies a non-default port against a default-port entry', () async {
        _expectRevealRefused(
          await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: 'https://example.test:443/login',
            ),
            origin: 'https://example.test:8443',
          ),
        );
      });
    });

    group('the host collapse must not widen the non-WebPKI set', () {
      // `_cleanHost` strips `www.`/`m.`/`mobile.` for *matching*. Asking the
      // WebPKI question of the stripped host turned every `www.X`/`m.X` into a
      // single-label name, which is the one shape the set admits — `m.me` is a
      // real Meta host with a public certificate.
      for (final host in const ['m.me', 'www.com', 'mobile.io']) {
        test('denies $host over http when stored without a scheme', () async {
          _expectRevealRefused(
            await _reveal(
              entry: _entry(
                id: 'entry-1',
                username: 'alice',
                password: 'test-only-secret',
                url: host,
              ),
              origin: 'http://$host',
            ),
          );
        });

        test('still allows $host over https', () async {
          final response = await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: host,
            ),
            origin: 'https://$host',
          );

          expect(response.statusCode, HttpStatus.ok);
          final data = response.json['data']! as Map<String, Object?>;
          expect(data['password'], 'test-only-secret');
        });
      }

      // The genuinely single-label hosts must keep their http allowance: they
      // have no public parent zone, so `https` really is unobtainable there.
      for (final host in const ['router', 'nas']) {
        test('still allows $host over http', () async {
          final response = await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: host,
            ),
            origin: 'http://$host',
          );

          expect(response.statusCode, HttpStatus.ok);
          final data = response.json['data']! as Map<String, Object?>;
          expect(data['password'], 'test-only-secret');
        });
      }

      test('denies a bare www. public host over http', () async {
        _expectRevealRefused(
          await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: 'www.bank.example',
            ),
            origin: 'http://www.bank.example',
          ),
        );
      });
    });

    group('a written port keeps binding when the scheme is inferred', () {
      // The de-pin drops the *scheme* claim the user never made; it must not
      // drop the *port* claim they did make. Without this, a hostile service on
      // another port of the same host — the LAN/shared-host case the de-pin
      // exists to serve — would be authorized.
      for (final (storedUrl, origin) in const [
        ('bank.example:8443', 'https://bank.example:9999'),
        ('bank.example:8443', 'https://bank.example'),
        ('192.168.1.10:8443', 'http://192.168.1.10:9999'),
        ('192.168.1.10:8443', 'http://192.168.1.10'),
      ]) {
        test('denies $storedUrl on $origin', () async {
          _expectRevealRefused(
            await _reveal(
              entry: _entry(
                id: 'entry-1',
                username: 'alice',
                password: 'test-only-secret',
                url: storedUrl,
              ),
              origin: origin,
            ),
          );
        });
      }

      for (final (storedUrl, origin) in const [
        ('bank.example:8443', 'https://bank.example:8443'),
        ('192.168.1.10:8443', 'http://192.168.1.10:8443'),
        // No port written, no port asserted: unchanged from `main`.
        ('bank.example', 'https://bank.example:9999'),
        ('192.168.1.10', 'http://192.168.1.10:9999'),
        // A written default port must survive the inferred `https://` both
        // ways, or the assertion would depend on a scheme the user never wrote.
        ('bank.example:443', 'https://bank.example'),
        ('192.168.1.10:80', 'http://192.168.1.10'),
      ]) {
        test('allows $storedUrl on $origin', () async {
          final response = await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: storedUrl,
            ),
            origin: origin,
          );

          expect(response.statusCode, HttpStatus.ok);
          final data = response.json['data']! as Map<String, Object?>;
          expect(data['password'], 'test-only-secret');
        });
      }

      test('the port also binds through a domain custom field', () async {
        _expectRevealRefused(
          await _reveal(
            entry: _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'test-only-secret',
              url: '',
              customFields: const [
                VaultCustomField(key: 'domain', value: '192.168.1.10:8443'),
              ],
            ),
            origin: 'http://192.168.1.10:8080',
          ),
        );
      });
    });

    test('denies a www-stripped https entry on an http page', () async {
      // `_cleanHost` still collapses `www.`/`m.`/`mobile.` onto the bare host,
      // so `https://www.bank.example` and `http://bank.example` compare on the
      // same host. Freezing the case here: the strip must never turn into a
      // downgrade until it is removed.
      _expectRevealRefused(
        await _reveal(
          entry: _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'test-only-secret',
            url: 'https://www.bank.example/login',
          ),
          origin: 'http://bank.example',
        ),
      );
    });

    test('stop removes descriptor and closes bridge', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-reveal-bridge-',
      );
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final service = DesktopBrowserAutofillRevealBridgeService(
        store: store,
        mapper: const DesktopBrowserAutofillMetadataMapper(),
      );

      await service.start(
        databasePath: '/vaults/example.kdbx',
        entries: [
          _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'super-secret',
            url: 'https://example.com',
          ),
        ],
      );
      final descriptor = await store.readBridgeDescriptor();
      expect(descriptor, isNotNull);
      expect(await store.bridgeDescriptorFile!.exists(), isTrue);

      await service.stop();

      expect(await store.readBridgeDescriptor(), isNull);
      expect(await store.bridgeDescriptorFile!.exists(), isFalse);
      await expectLater(
        _postBridge(
          descriptor: descriptor!,
          body: {
            'databaseId': descriptor.databaseId,
            'entryId': 'entry-1',
            'origin': 'https://example.com',
          },
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('009 A012 — origin-bound overlay reveal', () {
    test('reveals for an exact origin and echoes the binding', () async {
      final bridge = await _startOverlayBridge();

      final response = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/overlay-reveal',
        body: _overlayBody(bridge.descriptor),
      );

      expect(response.statusCode, HttpStatus.ok);
      final data = response.json['data']! as Map<String, Object?>;
      expect(data['password'], 'test-only-secret');
      expect(data['matchPolicy'], overlayMatchPolicy);
      expect(data['origin'], 'https://example.com');
      expect(data['databaseId'], bridge.descriptor.databaseId);
      expect(data['cacheGeneration'], bridge.descriptor.cacheGeneration);
      expect(data['bridgeGeneration'], bridge.descriptor.bridgeGeneration);
      expect(bridge.descriptor.cacheGeneration, isNotEmpty);
      expect(bridge.descriptor.bridgeGeneration, isNotEmpty);
    });

    test(
      'a domain-only entry is refused where the popup would allow it',
      () async {
        final entry = _entry(
          id: 'entry-1',
          username: 'alice',
          password: 'test-only-secret',
          // No scheme: the entry stays domain-only, which the popup policy
          // authorizes on an https page and the overlay policy never does.
          url: 'example.com',
        );
        final bridge = await _startOverlayBridge(entries: [entry]);

        final popup = await _postBridge(
          descriptor: bridge.descriptor,
          body: {
            'databaseId': bridge.descriptor.databaseId,
            'entryId': 'entry-1',
            'origin': 'https://example.com',
          },
        );
        expect(
          popup.statusCode,
          HttpStatus.ok,
          reason: 'popup policy unchanged',
        );

        final overlay = await _postBridge(
          descriptor: bridge.descriptor,
          path: '/overlay-reveal',
          body: _overlayBody(bridge.descriptor),
        );
        expect(overlay.statusCode, HttpStatus.forbidden);
        expect(
          (overlay.json['error']! as Map<String, Object?>)['code'],
          'forbidden',
        );
        expect(jsonEncode(overlay.json), isNot(contains('test-only-secret')));
      },
    );

    test('a www. entry does not authorize the bare host, end to end', () async {
      final bridge = await _startOverlayBridge(
        entries: [
          _entry(
            id: 'entry-1',
            username: 'alice',
            password: 'test-only-secret',
            url: 'https://www.example.com/login',
          ),
        ],
      );

      final onOwnOrigin = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/overlay-reveal',
        body: _overlayBody(
          bridge.descriptor,
          origin: 'https://www.example.com',
        ),
      );
      expect(onOwnOrigin.statusCode, HttpStatus.ok);

      // `_cleanHost` collapses these two names for possible-match ranking. That
      // collapse must never reach the overlay authorization path.
      final onBareHost = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/overlay-reveal',
        body: _overlayBody(bridge.descriptor, origin: 'https://example.com'),
      );
      expect(onBareHost.statusCode, HttpStatus.forbidden);
      expect(jsonEncode(onBareHost.json), isNot(contains('test-only-secret')));
    });

    test('an unknown entry and an unauthorized origin look alike', () async {
      final bridge = await _startOverlayBridge();

      final unknown = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/overlay-reveal',
        body: _overlayBody(bridge.descriptor, entryId: 'no-such-entry'),
      );
      final unauthorized = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/overlay-reveal',
        body: _overlayBody(
          bridge.descriptor,
          origin: 'https://www.example.com',
        ),
      );

      expect(unknown.statusCode, unauthorized.statusCode);
      expect(unknown.json, unauthorized.json);
    });

    for (final mismatch in const [
      'databaseId',
      'cacheGeneration',
      'bridgeGeneration',
    ]) {
      test('$mismatch mismatch is stale_session, not a secret', () async {
        final bridge = await _startOverlayBridge();
        // The hook runs after the credential lookup, so a stale request that
        // never reaches it proves the *first* check refused it before the
        // credential map was ever consulted (SR-4: before lookup, and again
        // before response).
        var reachedLookup = 0;
        bridge.service.debugBeforeOverlayRevealResponse = () async {
          reachedLookup += 1;
        };

        final response = await _postBridge(
          descriptor: bridge.descriptor,
          path: '/overlay-reveal',
          body: _overlayBody(
            bridge.descriptor,
            databaseId: mismatch == 'databaseId' ? 'db-other' : null,
            cacheGeneration: mismatch == 'cacheGeneration' ? 'other' : null,
            bridgeGeneration: mismatch == 'bridgeGeneration' ? 'other' : null,
          ),
        );

        expect(response.statusCode, HttpStatus.conflict);
        expect(
          (response.json['error']! as Map<String, Object?>)['code'],
          'stale_session',
        );
        expect(reachedLookup, 0);
        expect(jsonEncode(response.json), isNot(contains('test-only-secret')));
      });
    }

    test('a request without the strict policy is refused', () async {
      final bridge = await _startOverlayBridge();

      final response = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/overlay-reveal',
        body: _overlayBody(bridge.descriptor, matchPolicy: 'host'),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(
        (response.json['error']! as Map<String, Object?>)['code'],
        'invalid_request',
      );
    });

    test('the overlay endpoint still requires the bearer token', () async {
      final bridge = await _startOverlayBridge();

      final response = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/overlay-reveal',
        body: _overlayBody(bridge.descriptor),
        authorizationToken: 'wrong-token-wrong-token-wrong-token',
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(jsonEncode(response.json), isNot(contains('test-only-secret')));
    });

    test(
      'a vault switch between the lookup and the response is stale_session',
      () async {
        final bridge = await _startOverlayBridge();
        // The second check exists exactly for this window: everything was
        // current when the credential was found, and is not current any more
        // when the answer would be written.
        bridge.service.debugBeforeOverlayRevealResponse = () async {
          await bridge.store.writeBridgeDescriptor(
            DesktopBrowserAutofillBridgeDescriptor(
              version: desktopBrowserAutofillBridgeDescriptorVersion,
              port: bridge.descriptor.port,
              token: bridge.descriptor.token,
              databaseId: 'sha256:other-vault',
              cacheGeneration: 'other-cache-generation',
              bridgeGeneration: 'other-bridge-generation',
              createdAtEpochMs: 2,
            ),
          );
        };

        final response = await _postBridge(
          descriptor: bridge.descriptor,
          path: '/overlay-reveal',
          body: _overlayBody(bridge.descriptor),
        );

        expect(response.statusCode, HttpStatus.conflict);
        expect(
          (response.json['error']! as Map<String, Object?>)['code'],
          'stale_session',
        );
        final encoded = jsonEncode(response.json);
        expect(encoded, isNot(contains('test-only-secret')));
        expect(encoded, isNot(contains('other-vault-secret')));
      },
    );
  });

  // 009 / B006 — the app-owned `/generate-pending` endpoint.
  //
  // Secret-lifetime assertions follow the project method: the *actual*
  // generated value returned by the endpoint is searched for in every
  // observable surface (store files on disk, print/log output) — never
  // inferred from internal state.
  group('generate-pending endpoint (B006)', () {
    test('returns one-shot password, pending id, expiry, echoed binding and '
        'settings revision from the committed app snapshot', () async {
      final bridge = await _startGenerationBridge();

      final response = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/generate-pending',
        body: _generateBody(bridge.descriptor),
      );

      expect(response.statusCode, HttpStatus.ok);
      final data = response.json['data']! as Map<String, Object?>;
      final password = data['password']! as String;
      // Generated with the committed snapshot, never caller input:
      // digits-only, length 24 is this test's committed settings shape.
      expect(password.length, 24);
      expect(RegExp(r'^[0-9]+$').hasMatch(password), isTrue);
      expect(data['settingsRevision'], 7);
      expect(data['databaseId'], bridge.descriptor.databaseId);
      expect(data['cacheGeneration'], bridge.descriptor.cacheGeneration);
      expect(data['bridgeGeneration'], bridge.descriptor.bridgeGeneration);
      final pendingId = data['pendingGenerationId']! as String;
      expect(pendingId, isNotEmpty);
      expect(pendingId, isNot(contains(password)));
      final expiresAt = data['expiresAtEpochMs']! as int;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      expect(expiresAt, greaterThan(nowMs));
      expect(expiresAt, lessThanOrEqualTo(nowMs + 5 * 60 * 1000));

      // The record is app-owned and consumable exactly once, bound to the
      // exact origin of the request.
      final draft = bridge.pending.consume(
        pendingId,
        origin: 'https://example.com',
      );
      expect(draft, isNotNull);
      expect(draft!.password, password);
      expect(draft.settingsRevision, 7);
      expect(
        bridge.pending.consume(pendingId, origin: 'https://example.com'),
        isNull,
      );
    });

    test('a non-default port is part of the pending record origin', () async {
      final bridge = await _startGenerationBridge();

      final response = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/generate-pending',
        body: _generateBody(
          bridge.descriptor,
          origin: 'https://example.com:8443',
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final data = response.json['data']! as Map<String, Object?>;
      final pendingId = data['pendingGenerationId']! as String;
      // The default-port origin cannot consume a record created for the
      // non-default port — ownership is the full exact-origin tuple.
      expect(
        bridge.pending.consume(pendingId, origin: 'https://example.com'),
        isNull,
      );
      expect(
        bridge.pending.consume(pendingId, origin: 'https://example.com:8443'),
        isNotNull,
      );
    });

    test('descriptor advertises the capability only when the endpoint '
        'exists', () async {
      final withGeneration = await _startGenerationBridge();
      expect(
        withGeneration.descriptor.appCapabilities,
        contains(desktopBrowserGeneratePendingCapability),
      );

      // A bridge without the generation dependencies is the pre-B1 app: no
      // capability in the descriptor, `not_found` on the route.
      final without = await _startOverlayBridge();
      expect(without.descriptor.appCapabilities, isEmpty);
      final response = await _postBridge(
        descriptor: without.descriptor,
        path: '/generate-pending',
        body: _generateBody(without.descriptor),
      );
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('a settings field in the request is invalid_request, not '
        'ignored', () async {
      final bridge = await _startGenerationBridge();

      for (final smuggled in <Map<String, Object?>>[
        {
          'settings': <String, Object?>{'length': 4},
        },
        {'length': 4},
        {'includeSymbols': false},
      ]) {
        final response = await _postBridge(
          descriptor: bridge.descriptor,
          path: '/generate-pending',
          body: {..._generateBody(bridge.descriptor), ...smuggled},
        );
        expect(response.statusCode, HttpStatus.badRequest);
        expect(
          (response.json['error']! as Map<String, Object?>)['code'],
          'invalid_request',
        );
      }
      // Nothing was generated for any of them.
      expect(bridge.pending.pendingCount, 0);
    });

    test('requires the bearer token', () async {
      final bridge = await _startGenerationBridge();

      final response = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/generate-pending',
        body: _generateBody(bridge.descriptor),
        authorizationToken: 'wrong-token-wrong-token-wrong-token',
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(bridge.pending.pendingCount, 0);
    });

    test('refuses a non-exact or non-http(s) origin', () async {
      final bridge = await _startGenerationBridge();

      for (final origin in const [
        'ftp://example.com',
        'chrome-extension://abcdefg',
        'https://alice@example.com',
        'not a url',
      ]) {
        final response = await _postBridge(
          descriptor: bridge.descriptor,
          path: '/generate-pending',
          body: _generateBody(bridge.descriptor, origin: origin),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: origin);
      }
      expect(bridge.pending.pendingCount, 0);
    });

    for (final mismatch in const [
      'databaseId',
      'cacheGeneration',
      'bridgeGeneration',
    ]) {
      test('$mismatch mismatch is stale_session before generation', () async {
        final bridge = await _startGenerationBridge();

        final response = await _postBridge(
          descriptor: bridge.descriptor,
          path: '/generate-pending',
          body: _generateBody(
            bridge.descriptor,
            databaseId: mismatch == 'databaseId' ? 'db-other' : null,
            cacheGeneration: mismatch == 'cacheGeneration' ? 'other' : null,
            bridgeGeneration: mismatch == 'bridgeGeneration' ? 'other' : null,
          ),
        );

        expect(response.statusCode, HttpStatus.conflict);
        expect(
          (response.json['error']! as Map<String, Object?>)['code'],
          'stale_session',
        );
        // Stale sessions never generate: no pending record, no secret.
        expect(bridge.pending.pendingCount, 0);
      });
    }

    test('bounded rate: requests beyond the window are refused without '
        'generating', () async {
      final bridge = await _startGenerationBridge();
      final limit = DesktopBrowserAutofillRevealBridgeService
          .maxGenerateRequestsPerMinute;

      for (var i = 0; i < limit; i += 1) {
        final response = await _postBridge(
          descriptor: bridge.descriptor,
          path: '/generate-pending',
          body: _generateBody(bridge.descriptor),
        );
        expect(response.statusCode, HttpStatus.ok);
      }

      final refused = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/generate-pending',
        body: _generateBody(bridge.descriptor),
      );
      expect(refused.statusCode, HttpStatus.tooManyRequests);
      expect(
        (refused.json['error']! as Map<String, Object?>)['code'],
        'rate_limited',
      );
      // The pending set stays bounded regardless (service ceiling).
      expect(
        bridge.pending.pendingCount,
        lessThanOrEqualTo(DesktopBrowserPendingGenerationService.maxRecords),
      );
    });

    test('a session torn down between generation and response is stale_session '
        'and the pending secret is dropped', () async {
      final bridge = await _startGenerationBridge();
      // The durable descriptor flips to another session while the response
      // is about to be written — exactly the window the SR-4 re-check
      // closes on the overlay path.
      bridge.service.debugBeforeGeneratePendingResponse = () async {
        await bridge.store.writeBridgeDescriptor(
          DesktopBrowserAutofillBridgeDescriptor(
            version: desktopBrowserAutofillBridgeDescriptorVersion,
            port: bridge.descriptor.port,
            token: bridge.descriptor.token,
            databaseId: 'sha256:other-vault',
            cacheGeneration: 'other-cache-generation',
            bridgeGeneration: 'other-bridge-generation',
            createdAtEpochMs: 2,
          ),
        );
      };

      final response = await _postBridge(
        descriptor: bridge.descriptor,
        path: '/generate-pending',
        body: _generateBody(bridge.descriptor),
      );

      expect(response.statusCode, HttpStatus.conflict);
      expect(
        (response.json['error']! as Map<String, Object?>)['code'],
        'stale_session',
      );
      // The record created mid-flight was rejected: nothing pending, and
      // its secret reference is gone.
      expect(bridge.pending.pendingCount, 0);
    });

    test('the generated secret never reaches any store file or log', () async {
      final bridge = await _startGenerationBridge();

      final printed = <String>[];
      late String password;
      await runZoned(
        () async {
          final response = await _postBridge(
            descriptor: bridge.descriptor,
            path: '/generate-pending',
            body: _generateBody(bridge.descriptor),
          );
          expect(response.statusCode, HttpStatus.ok);
          password =
              (response.json['data']! as Map<String, Object?>)['password']!
                  as String;
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      await for (final fileEntity in bridge.store.directory!.list(
        recursive: true,
        followLinks: false,
      )) {
        if (fileEntity is File) {
          expect(
            await fileEntity.readAsString(),
            isNot(contains(password)),
            reason: 'secret leaked to ${fileEntity.uri.pathSegments.last}',
          );
        }
      }
      expect(printed.join('\n'), isNot(contains(password)));
    });
  });

  // ===========================================================================
  // spec 023 T502 — `/passkey-assert`: the app signs, nothing else sees the
  // key (FR-013a), and the user authorises every signature (FR-015).
  // ===========================================================================

  group('passkey-assert endpoint (023 T502)', () {
    Future<
      ({
        DesktopBrowserAutofillBridgeDescriptor descriptor,
        List<PasskeyAssertionPrompt> prompts,
      })
    >
    startWithPasskey({
      bool approve = true,
      bool withConfirm = true,
      List<VaultEntry>? entries,
    }) async {
      final directory = await Directory.systemTemp.createTemp('kv-passkey-');
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final prompts = <PasskeyAssertionPrompt>[];
      final service = DesktopBrowserAutofillRevealBridgeService(
        store: store,
        mapper: const DesktopBrowserAutofillMetadataMapper(),
        confirmPasskeyAssertion: withConfirm
            ? (prompt) async {
                prompts.add(prompt);
                return approve;
              }
            : null,
      );
      addTearDown(service.stop);
      addTearDown(() => directory.delete(recursive: true));

      await service.start(
        databasePath: '/vaults/example.kdbx',
        entries:
            entries ??
            [
              _entry(
                id: 'entry-1',
                username: 'alice',
                password: '',
                url: 'https://example.com/login',
                passkeys: [_passkey()],
              ),
            ],
      );
      final descriptor = (await store.readBridgeDescriptor())!;
      return (descriptor: descriptor, prompts: prompts);
    }

    Map<String, Object?> body(
      DesktopBrowserAutofillBridgeDescriptor descriptor, {
      String origin = 'https://example.com',
      String rpId = 'example.com',
      List<String>? allowCredentials,
    }) => {
      'databaseId': descriptor.databaseId,
      'origin': origin,
      'rpId': rpId,
      'challenge': 'Y2hhbGxlbmdl',
      'allowCredentials': ?allowCredentials,
    };

    test('signs after the user approves, and returns no key', () async {
      final (:descriptor, :prompts) = await startWithPasskey();

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-assert',
        body: body(descriptor),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.json['ok'], isTrue);
      final data = response.json['data']! as Map<String, Object?>;
      expect(data['credentialId'], 'AQIDBAU');
      expect(data['authenticatorData'], isA<String>());
      expect(data['signature'], isA<String>());
      expect(data['userHandle'], 'CQk');
      // The clientDataJSON the site will verify, and the only place the
      // challenge and origin appear.
      final clientData = utf8.decode(
        base64Url.decode(
          base64Url.normalize(data['clientDataJSON']! as String),
        ),
      );
      expect(clientData, contains('"type":"webauthn.get"'));
      expect(clientData, contains('"challenge":"Y2hhbGxlbmdl"'));
      expect(clientData, contains('"origin":"https://example.com"'));
      // FR-013a: nothing in the response resembles the key.
      expect(jsonEncode(response.json), isNot(contains('PRIVATE KEY')));
      expect(jsonEncode(response.json), isNot(contains('MIGHAgEA')));

      // FR-015: the user was asked, and told what they were approving.
      expect(prompts, hasLength(1));
      expect(prompts.single.relyingPartyId, 'example.com');
      expect(prompts.single.origin, 'https://example.com');
      expect(prompts.single.username, 'ada');
    });

    test('a declined prompt signs nothing', () async {
      final (:descriptor, :prompts) = await startWithPasskey(approve: false);

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-assert',
        body: body(descriptor),
      );

      expect(response.json['ok'], isFalse);
      expect((response.json['data']! as Map)['reason'], 'declined');
      expect(prompts, hasLength(1));
    });

    test(
      'with no confirmation hook the endpoint declines everything',
      () async {
        final (:descriptor, prompts: _) = await startWithPasskey(
          withConfirm: false,
        );

        final response = await _postBridge(
          descriptor: descriptor,
          path: '/passkey-assert',
          body: body(descriptor),
        );

        expect((response.json['data']! as Map)['reason'], 'declined');
        // ...and the capability was never advertised, so the extension leaves
        // `navigator.credentials.get` alone in the first place.
        expect(descriptor.appCapabilities, isNot(contains('passkeyAssertV1')));
      },
    );

    test(
      'the capability appears only when a passkey is actually held',
      () async {
        final (:descriptor, prompts: _) = await startWithPasskey(
          entries: [
            _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'pw',
              url: 'https://example.com/login',
            ),
          ],
        );

        expect(descriptor.appCapabilities, isNot(contains('passkeyAssertV1')));
      },
    );

    test('a passkey for another site is never offered (FR-014)', () async {
      final (:descriptor, :prompts) = await startWithPasskey();

      // The page is evil-example.com; a bare suffix match would hand it the
      // example.com passkey.
      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-assert',
        body: body(
          descriptor,
          origin: 'https://evil-example.com',
          rpId: 'example.com',
        ),
      );

      expect((response.json['data']! as Map)['reason'], 'rp_mismatch');
      expect(prompts, isEmpty);
    });

    test('a subdomain may use its parent domain\'s passkey', () async {
      final (:descriptor, :prompts) = await startWithPasskey();

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-assert',
        body: body(
          descriptor,
          origin: 'https://login.example.com',
          rpId: 'example.com',
        ),
      );

      expect(response.json['ok'], isTrue);
      expect(prompts, hasLength(1));
    });

    test(
      'allowCredentials that names another credential finds nothing',
      () async {
        final (:descriptor, :prompts) = await startWithPasskey();

        final response = await _postBridge(
          descriptor: descriptor,
          path: '/passkey-assert',
          body: body(descriptor, allowCredentials: ['bm90LW1pbmU']),
        );

        expect((response.json['data']! as Map)['reason'], 'no_credential');
        expect(prompts, isEmpty);
      },
    );

    test(
      'an unusable passkey is not held, so there is nothing to sign',
      () async {
        final (:descriptor, prompts: _) = await startWithPasskey(
          entries: [
            _entry(
              id: 'entry-1',
              username: 'alice',
              password: '',
              url: 'https://example.com/login',
              passkeys: [
                _passkey(unusableReason: VaultPasskeyUnusableReason.badKey),
              ],
            ),
          ],
        );

        final response = await _postBridge(
          descriptor: descriptor,
          path: '/passkey-assert',
          body: body(descriptor),
        );

        expect((response.json['data']! as Map)['reason'], 'no_credential');
      },
    );

    test('an Ed25519 passkey signs with a raw 64-byte signature', () async {
      final (:descriptor, prompts: _) = await startWithPasskey(
        entries: [
          _entry(
            id: 'entry-1',
            username: 'alice',
            password: '',
            url: 'https://example.com/login',
            passkeys: [
              _passkey(
                pem: eddsaPrivateKeyPem,
                algorithm: VaultPasskeyAlgorithm.eddsa,
              ),
            ],
          ),
        ],
      );

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-assert',
        body: body(descriptor),
      );

      expect(response.json['ok'], isTrue);
      final signature = (response.json['data']! as Map)['signature']! as String;
      expect(base64Url.decode(base64Url.normalize(signature)), hasLength(64));
    });

    test(
      'an unknown algorithm cannot be signed and says so rather than failing',
      () async {
        final (:descriptor, prompts: _) = await startWithPasskey(
          entries: [
            _entry(
              id: 'entry-1',
              username: 'alice',
              password: '',
              url: 'https://example.com/login',
              passkeys: [_passkey(algorithm: VaultPasskeyAlgorithm.unknown)],
            ),
          ],
        );

        final response = await _postBridge(
          descriptor: descriptor,
          path: '/passkey-assert',
          body: body(descriptor),
        );

        expect(
          (response.json['data']! as Map)['reason'],
          'unsupported_algorithm',
        );
      },
    );

    // A passkey-only entry is held for signing, not for filling: answering
    // /reveal for it would hand the popup an empty password.
    test('a passkey-only entry cannot be revealed as a password', () async {
      final (:descriptor, prompts: _) = await startWithPasskey();

      final response = await _postBridge(
        descriptor: descriptor,
        body: {
          'databaseId': descriptor.databaseId,
          'entryId': 'entry-1',
          'origin': 'https://example.com',
        },
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect(
        (response.json['error']! as Map)['code'],
        'credential_unavailable',
      );
    });

    test('a request for another database is refused', () async {
      final (:descriptor, :prompts) = await startWithPasskey();

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-assert',
        body: {...body(descriptor), 'databaseId': 'sha256:other'},
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(prompts, isEmpty);
    });

    // ---- US3: /passkey-create ------------------------------------------

    Future<
      ({
        DesktopBrowserAutofillBridgeDescriptor descriptor,
        List<PasskeyCreationPrompt> prompts,
        List<(String entryId, bool replace, Uint8List? userHandle)> writes,
      })
    >
    startForCreate({
      PasskeyCreationDecision? decision = const PasskeyCreationDecision(
        entryId: 'entry-1',
      ),
      PasskeyCreationOutcome outcome = const PasskeyCreationOutcome(
        reason: null,
        credentialId: 'Y3JlZA',
        attestationObject: 'YXR0',
        publicKeyCose: 'Y29zZQ',
      ),
      bool withHooks = true,
      List<VaultEntry>? entries,
    }) async {
      final directory = await Directory.systemTemp.createTemp('kv-pk-create-');
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final prompts = <PasskeyCreationPrompt>[];
      final writes = <(String, bool, Uint8List?)>[];
      final service = DesktopBrowserAutofillRevealBridgeService(
        store: store,
        mapper: const DesktopBrowserAutofillMetadataMapper(),
      );
      if (withHooks) {
        service
          ..confirmPasskeyCreation = (prompt) async {
            prompts.add(prompt);
            return decision;
          }
          ..writePasskey =
              ({
                required String entryId,
                required String relyingPartyId,
                required String username,
                required Uint8List? userHandle,
                required bool replaceExisting,
              }) async {
                writes.add((entryId, replaceExisting, userHandle));
                return outcome;
              };
      }
      addTearDown(service.stop);
      addTearDown(() => directory.delete(recursive: true));

      await service.start(
        databasePath: '/vaults/example.kdbx',
        entries:
            entries ??
            [
              _entry(
                id: 'entry-1',
                username: 'alice',
                password: 'pw',
                url: 'https://example.com/login',
              ),
            ],
      );
      return (
        descriptor: (await store.readBridgeDescriptor())!,
        prompts: prompts,
        writes: writes,
      );
    }

    Map<String, Object?> createBody(
      DesktopBrowserAutofillBridgeDescriptor descriptor, {
      String origin = 'https://example.com',
      String rpId = 'example.com',
      // base64url for the bytes [1, 2, 3, 4]; `null` omits the field, as a
      // registration with no `user.id` does.
      String? userHandle = 'AQIDBA',
    }) => {
      'databaseId': descriptor.databaseId,
      'origin': origin,
      'rpId': rpId,
      'challenge': 'Y2hhbGxlbmdl',
      'username': 'ada',
      'userHandle': ?userHandle,
    };

    test('creates after the user chooses a record', () async {
      final (:descriptor, :prompts, :writes) = await startForCreate();

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-create',
        body: createBody(descriptor),
      );

      expect(response.json['ok'], isTrue);
      final data = response.json['data']! as Map<String, Object?>;
      expect(data['credentialId'], 'Y3JlZA');
      expect(data['attestationObject'], 'YXR0');
      expect(data['publicKeyCose'], 'Y29zZQ');
      // The client data a registration is verified against says `create`, not
      // `get`: a relying party checks the type and rejects the other one.
      final clientData = utf8.decode(
        base64Url.decode(
          base64Url.normalize(data['clientDataJSON']! as String),
        ),
      );
      expect(clientData, contains('"type":"webauthn.create"'));
      expect(clientData, contains('"challenge":"Y2hhbGxlbmdl"'));

      // The user was asked, and the record that matches the site was offered.
      expect(prompts.single.relyingPartyId, 'example.com');
      expect(prompts.single.candidateEntries.single.entryId, 'entry-1');
      expect(
        prompts.single.candidateEntries.single.holdsPasskeyForThisSite,
        isFalse,
      );
      expect(writes.single.$1, 'entry-1');
      expect(writes.single.$2, isFalse);
      // The relying party's own handle reached the writer, byte for byte: a
      // credential stored under a handle the site never issued is one a
      // discoverable sign-in cannot resolve to an account.
      expect(writes.single.$3, Uint8List.fromList([1, 2, 3, 4]));
    });

    // A relying party may register without a `user.id`, and a page may send
    // something that is not base64url. Neither is a reason to fail a
    // registration the user already approved: the app falls back to a handle
    // of its own, which is what `PasskeyGenerator` does with a null.
    test('a missing or malformed user handle is treated as absent', () async {
      for (final handle in [null, '', 'not base64url!!']) {
        final (:descriptor, prompts: _, :writes) = await startForCreate();

        final response = await _postBridge(
          descriptor: descriptor,
          path: '/passkey-create',
          body: createBody(descriptor, userHandle: handle),
        );

        expect(response.json['ok'], isTrue, reason: 'handle: $handle');
        expect(writes.single.$3, isNull, reason: 'handle: $handle');
      }
    });

    test('a declined prompt writes nothing', () async {
      final (:descriptor, :prompts, :writes) = await startForCreate(
        decision: null,
      );

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-create',
        body: createBody(descriptor),
      );

      expect((response.json['data']! as Map)['reason'], 'declined');
      expect(prompts, hasLength(1));
      expect(writes, isEmpty);
    });

    test(
      'with no hooks the endpoint declines, and advertises nothing',
      () async {
        final (:descriptor, prompts: _, writes: _) = await startForCreate(
          withHooks: false,
        );

        final response = await _postBridge(
          descriptor: descriptor,
          path: '/passkey-create',
          body: createBody(descriptor),
        );

        expect((response.json['data']! as Map)['reason'], 'declined');
        expect(descriptor.appCapabilities, isNot(contains('passkeyCreateV1')));
      },
    );

    test('the create capability appears when both hooks are wired', () async {
      final (:descriptor, prompts: _, writes: _) = await startForCreate();

      expect(descriptor.appCapabilities, contains('passkeyCreateV1'));
    });

    // FR-014's rule applies to creation too.
    test('a page cannot create a passkey for another site', () async {
      final (:descriptor, :prompts, :writes) = await startForCreate();

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-create',
        body: createBody(
          descriptor,
          origin: 'https://evil-example.com',
          rpId: 'example.com',
        ),
      );

      expect((response.json['data']! as Map)['reason'], 'rp_mismatch');
      expect(prompts, isEmpty);
      expect(writes, isEmpty);
    });

    // FR-020: the site hears about a credential only once it is written.
    test('a failed write reports the reason and no credential', () async {
      final (:descriptor, prompts: _, :writes) = await startForCreate(
        outcome: const PasskeyCreationOutcome(reason: 'write_failed'),
      );

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-create',
        body: createBody(descriptor),
      );

      expect(response.json['ok'], isFalse);
      expect((response.json['data']! as Map)['reason'], 'write_failed');
      expect(writes, hasLength(1));
    });

    test(
      'an entry already holding a passkey is flagged as a replacement',
      () async {
        final (:descriptor, :prompts, writes: _) = await startForCreate(
          entries: [
            _entry(
              id: 'entry-1',
              username: 'alice',
              password: 'pw',
              url: 'https://example.com/login',
              passkeys: [_passkey()],
            ),
          ],
        );

        await _postBridge(
          descriptor: descriptor,
          path: '/passkey-create',
          body: createBody(descriptor),
        );

        expect(
          prompts.single.candidateEntries.single.holdsPasskeyForThisSite,
          isTrue,
          reason: 'the confirmation must be able to say what would be replaced',
        );
      },
    );

    test('a request for another database is refused', () async {
      final (:descriptor, :prompts, writes: _) = await startForCreate();

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-create',
        body: {...createBody(descriptor), 'databaseId': 'sha256:other'},
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(prompts, isEmpty);
    });

    test('an unauthenticated request never reaches the prompt', () async {
      final (:descriptor, :prompts) = await startWithPasskey();

      final response = await _postBridge(
        descriptor: descriptor,
        path: '/passkey-assert',
        body: body(descriptor),
        authorizationToken: 'wrong',
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(prompts, isEmpty);
    });
  });
}

/// 009 / A012 — the origin-bound overlay endpoint on the app bridge.
///
/// Publishes a metadata cache first, exactly like the coordinator does, because
/// the bridge copies its `cacheGeneration` from the published cache.
Future<
  ({
    DesktopBrowserAutofillBridgeDescriptor descriptor,
    DesktopBrowserAutofillRevealBridgeService service,
    DesktopBrowserAutofillCacheStore store,
  })
>
_startOverlayBridge({List<VaultEntry>? entries}) async {
  final store = DesktopBrowserAutofillCacheStore(
    directory: await Directory.systemTemp.createTemp('kv-overlay-bridge-'),
  );
  const mapper = DesktopBrowserAutofillMetadataMapper();
  final vaultEntries =
      entries ??
      [
        _entry(
          id: 'entry-1',
          username: 'alice',
          password: 'test-only-secret',
          url: 'https://example.com/login',
        ),
      ];
  await store.writeMetadataCache(
    mapper.mapVault(
      databasePath: '/vaults/example.kdbx',
      entries: vaultEntries,
    ),
  );
  final service = DesktopBrowserAutofillRevealBridgeService(
    store: store,
    mapper: mapper,
  );
  addTearDown(service.stop);
  await service.start(
    databasePath: '/vaults/example.kdbx',
    entries: vaultEntries,
  );
  return (
    descriptor: (await store.readBridgeDescriptor())!,
    service: service,
    store: store,
  );
}

/// 009 / B006 — a bridge with the generation dependencies wired, standing in
/// for the running unlocked app. The committed settings snapshot is
/// digits-only length 24 at revision 7, so tests can assert the generated
/// shape without ever embedding a literal credential value.
Future<
  ({
    DesktopBrowserAutofillBridgeDescriptor descriptor,
    DesktopBrowserAutofillRevealBridgeService service,
    DesktopBrowserAutofillCacheStore store,
    DesktopBrowserPendingGenerationService pending,
  })
>
_startGenerationBridge() async {
  final store = DesktopBrowserAutofillCacheStore(
    directory: await Directory.systemTemp.createTemp('kv-generate-bridge-'),
  );
  const mapper = DesktopBrowserAutofillMetadataMapper();
  final vaultEntries = [
    _entry(
      id: 'entry-1',
      username: 'alice',
      password: 'test-only-secret',
      url: 'https://example.com/login',
    ),
  ];
  await store.writeMetadataCache(
    mapper.mapVault(
      databasePath: '/vaults/example.kdbx',
      entries: vaultEntries,
    ),
  );
  final pending = DesktopBrowserPendingGenerationService();
  final service = DesktopBrowserAutofillRevealBridgeService(
    store: store,
    mapper: mapper,
    settingsRepository: _FixedSettingsRepository(
      const GeneratorSettingsSnapshot(
        revision: 7,
        length: 24,
        includeLowercase: false,
        includeUppercase: false,
        includeDigits: true,
        includeSymbols: false,
      ),
    ),
    passwordGenerator: PasswordGeneratorService(),
    pendingGeneration: pending,
  );
  addTearDown(service.stop);
  await service.start(
    databasePath: '/vaults/example.kdbx',
    entries: vaultEntries,
  );
  return (
    descriptor: (await store.readBridgeDescriptor())!,
    service: service,
    store: store,
    pending: pending,
  );
}

Map<String, Object?> _generateBody(
  DesktopBrowserAutofillBridgeDescriptor descriptor, {
  String origin = 'https://example.com',
  String? databaseId,
  String? cacheGeneration,
  String? bridgeGeneration,
}) {
  return {
    'origin': origin,
    'databaseId': databaseId ?? descriptor.databaseId,
    'cacheGeneration': cacheGeneration ?? descriptor.cacheGeneration,
    'bridgeGeneration': bridgeGeneration ?? descriptor.bridgeGeneration,
  };
}

/// Settings are app-owned: the bridge must only ever read the committed
/// snapshot. Save/reset are unreachable from the endpoint by construction.
class _FixedSettingsRepository implements PasswordGeneratorSettingsRepository {
  _FixedSettingsRepository(this.snapshot);

  final GeneratorSettingsSnapshot snapshot;

  @override
  Future<GeneratorSettingsSnapshot> read() async => snapshot;

  @override
  Future<GeneratorSettingsSnapshot> save(
    GeneratorSettingsSnapshot draft, {
    required int expectedRevision,
  }) => throw UnsupportedError('the bridge endpoint never writes settings');

  @override
  Future<GeneratorSettingsSnapshot> reset() =>
      throw UnsupportedError('the bridge endpoint never writes settings');

  @override
  Stream<GeneratorSettingsSnapshot> watch() => const Stream.empty();
}

Map<String, Object?> _overlayBody(
  DesktopBrowserAutofillBridgeDescriptor descriptor, {
  String entryId = 'entry-1',
  String origin = 'https://example.com',
  String? databaseId,
  String? cacheGeneration,
  String? bridgeGeneration,
  String matchPolicy = overlayMatchPolicy,
}) {
  return {
    'entryId': entryId,
    'origin': origin,
    'matchPolicy': matchPolicy,
    'databaseId': databaseId ?? descriptor.databaseId,
    'cacheGeneration': cacheGeneration ?? descriptor.cacheGeneration,
    'bridgeGeneration': bridgeGeneration ?? descriptor.bridgeGeneration,
  };
}

Future<_RevealHttpResponse> _postBridge({
  required DesktopBrowserAutofillBridgeDescriptor descriptor,
  required Map<String, Object?> body,
  String path = '/reveal',
  String? authorizationToken,
}) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.postUrl(
      Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: descriptor.port,
        path: path,
      ),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${authorizationToken ?? descriptor.token}',
    );
    request.write(jsonEncode(body));
    final response = await request.close();
    final payload = await utf8.decoder.bind(response).join();
    final decoded = jsonDecode(payload) as Map<String, Object?>;
    return _RevealHttpResponse(statusCode: response.statusCode, json: decoded);
  } finally {
    client.close(force: true);
  }
}

class _RevealHttpResponse {
  const _RevealHttpResponse({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;
}

Future<_RevealHttpResponse> _reveal({
  required VaultEntry entry,
  required String origin,
}) async {
  final directory = await Directory.systemTemp.createTemp('kv-reveal-bridge-');
  final store = DesktopBrowserAutofillCacheStore(directory: directory);
  final service = DesktopBrowserAutofillRevealBridgeService(
    store: store,
    mapper: const DesktopBrowserAutofillMetadataMapper(),
  );
  addTearDown(service.stop);

  await service.start(databasePath: '/vaults/example.kdbx', entries: [entry]);
  final descriptor = (await store.readBridgeDescriptor())!;

  return _postBridge(
    descriptor: descriptor,
    body: {
      'databaseId': descriptor.databaseId,
      'entryId': entry.id,
      'origin': origin,
    },
  );
}

void _expectRevealRefused(_RevealHttpResponse response) {
  expect(response.statusCode, HttpStatus.forbidden);
  final error = response.json['error']! as Map<String, Object?>;
  expect(error['code'], 'strong_match_required');
  final encoded = jsonEncode(response.json);
  expect(encoded, isNot(contains('test-only-secret')));
  expect(encoded, isNot(contains('alice')));
  // The refusal must not tell the caller which rule rejected it.
  final message = (error['message']! as String).toLowerCase();
  expect(message, isNot(contains('scheme')));
  expect(message, isNot(contains('http')));
  expect(message, isNot(contains('port')));
}

VaultEntry _entry({
  required String id,
  required String username,
  required String password,
  required String url,
  List<VaultCustomField> customFields = const [],
  List<VaultPasskey> passkeys = const [],
}) {
  return VaultEntry(
    id: id,
    groupId: 'root',
    title: 'Example',
    username: username,
    password: password,
    url: url,
    notes: 'hidden',
    customFields: customFields,
    passkeys: passkeys,
  );
}

VaultPasskey _passkey({
  String relyingPartyId = 'example.com',
  String username = 'ada',
  String pem = es256PrivateKeyPem,
  List<int> credentialId = const [1, 2, 3, 4, 5],
  VaultPasskeyAlgorithm algorithm = VaultPasskeyAlgorithm.es256,
  VaultPasskeyUnusableReason? unusableReason,
}) => VaultPasskey(
  relyingPartyId: relyingPartyId,
  credentialId: Uint8List.fromList(credentialId),
  userHandle: Uint8List.fromList(const [9, 9]),
  username: username,
  privateKeyPem: pem,
  algorithm: algorithm,
  unusableReason: unusableReason,
);
