import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:password_manager/core/update/http_update_check_gateway.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<String?> fetch(Future<http.Response> Function() respond) async {
    SharedPreferences.setMockInitialValues({});
    final gateway = HttpUpdateCheckGateway(
      await SharedPreferences.getInstance(),
      MockClient((_) => respond()),
    );
    return gateway.fetchLatestVersion();
  }

  test('returns a valid X.Y.Z version', () async {
    expect(
      await fetch(
        () async => http.Response('{"version":"1.2.3","build":5}', 200),
      ),
      '1.2.3',
    );
  });

  test('rejects non-200, malformed and invalid payloads', () async {
    for (final response in <http.Response>[
      http.Response('nope', 500),
      http.Response('not json', 200),
      http.Response('{"version":"1.0"}', 200),
      http.Response('{"version":"<b>9.0.0</b>"}', 200),
      http.Response('{"version":9}', 200),
      http.Response('[]', 200),
    ]) {
      expect(await fetch(() async => response), isNull, reason: response.body);
    }
  });

  test('exceptions are swallowed', () async {
    expect(await fetch(() async => throw Exception('offline')), isNull);
  });

  test('a request that never completes times out to null', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({});
      String? result = 'unset';
      SharedPreferences.getInstance().then((prefs) {
        HttpUpdateCheckGateway(
          prefs,
          MockClient((_) => Completer<http.Response>().future),
        ).fetchLatestVersion().then((v) => result = v);
      });
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 11));
      expect(result, isNull);
    });
  });

  test('persists values under stable keys', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final gateway = HttpUpdateCheckGateway(
      prefs,
      MockClient((_) async => http.Response('', 500)),
    );
    expect(gateway.enabled, isFalse);
    await gateway.setEnabled(true);
    await gateway.setLastCheckMs(7);
    await gateway.setLatestVersion('1.0.0');
    await gateway.setNotifiedVersion('1.0.0');
    expect(prefs.getBool(HttpUpdateCheckGateway.enabledKey), isTrue);
    expect(gateway.lastCheckMs, 7);
    expect(gateway.latestVersion, '1.0.0');
    expect(gateway.notifiedVersion, '1.0.0');
  });
}
