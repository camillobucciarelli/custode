import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:password_manager/core/update/update_check_cubit.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('isNewerVersion compares components numerically', () {
    expect(isNewerVersion('0.10.0', '0.9.9'), isTrue);
    expect(isNewerVersion('1.0.0', '0.99.99'), isTrue);
    expect(isNewerVersion('0.7.0', '0.7.0'), isFalse);
    expect(isNewerVersion('0.6.9', '0.7.0'), isFalse);
    for (final bad in ['', '1.0', '1.0.0.1', 'v1.0.0', '1.0.0-beta', '1.a.0']) {
      expect(isNewerVersion(bad, '0.7.0'), isFalse, reason: bad);
    }
  });

  late int calls;
  late DateTime clock;

  Future<UpdateCheckCubit> build(
    Map<String, Object> prefs,
    http.Response Function() respond, {
    bool supported = true,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    calls = 0;
    return UpdateCheckCubit(
      await SharedPreferences.getInstance(),
      MockClient((_) async {
        calls++;
        return respond();
      }),
      now: () => clock,
      supported: supported,
    );
  }

  http.Response ok(String version) =>
      http.Response('{"version":"$version","build":5}', 200);

  setUp(() => clock = DateTime(2026, 1, 1, 12));

  test('disabled setting makes no HTTP call', () async {
    final cubit = await build({}, () => ok('9.0.0'));
    await cubit.checkOnStart();
    expect(calls, 0);
    expect(cubit.state.enabled, isFalse);
    expect(cubit.state.availableVersion, isNull);
  });

  test('unsupported platform never checks nor enables', () async {
    final cubit = await build(
      {UpdateCheckCubit.enabledKey: true},
      () => ok('9.0.0'),
      supported: false,
    );
    await cubit.checkOnStart();
    await cubit.setEnabled(true);
    expect(calls, 0);
    expect(cubit.state.enabled, isFalse);
  });

  test(
    'enabling checks immediately and surfaces a newer version once',
    () async {
      final cubit = await build({}, () => ok('9.0.0'));
      await cubit.setEnabled(true);
      expect(calls, 1);
      expect(cubit.state.availableVersion, '9.0.0');
      expect(cubit.state.announce, isTrue);
      // Same version again: shown in settings, but not announced twice.
      clock = clock.add(const Duration(hours: 25));
      await cubit.checkOnStart();
      expect(calls, 2);
      expect(cubit.state.availableVersion, '9.0.0');
      expect(cubit.state.announce, isFalse);
    },
  );

  test('start check is throttled to once per 24 hours', () async {
    final cubit = await build({
      UpdateCheckCubit.enabledKey: true,
    }, () => ok('9.0.0'));
    await cubit.checkOnStart();
    expect(calls, 1);
    clock = clock.add(const Duration(hours: 23));
    await cubit.checkOnStart();
    expect(calls, 1);
    clock = clock.add(const Duration(hours: 2));
    await cubit.checkOnStart();
    expect(calls, 2);
  });

  test('failures are silent and leave state and throttle unchanged', () async {
    for (final respond in <http.Response Function()>[
      () => http.Response('nope', 500),
      () => http.Response('not json', 200),
      () => http.Response('{"version":"1.0"}', 200),
      () => http.Response('{"version":"<b>9.0.0</b>"}', 200),
      () => http.Response('[]', 200),
      () => throw Exception('offline'),
    ]) {
      final cubit = await build({UpdateCheckCubit.enabledKey: true}, respond);
      await cubit.checkOnStart();
      expect(calls, 1);
      expect(cubit.state.availableVersion, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(UpdateCheckCubit.lastCheckKey), isNull);
    }
  });

  test('a remote version that is not newer shows nothing', () async {
    final cubit = await build({
      UpdateCheckCubit.enabledKey: true,
    }, () => ok(kApplicationVersion));
    await cubit.checkOnStart();
    expect(cubit.state.availableVersion, isNull);
  });

  test('a known newer version is restored from preferences', () async {
    final cubit = await build({
      UpdateCheckCubit.enabledKey: true,
      UpdateCheckCubit.latestKey: '9.0.0',
    }, () => ok('9.0.0'));
    expect(cubit.state.availableVersion, '9.0.0');
  });
}
