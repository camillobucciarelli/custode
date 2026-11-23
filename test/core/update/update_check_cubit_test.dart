import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/update/update_check_cubit.dart';
import 'package:password_manager/core/update/update_check_gateway.dart';

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

  late _FakeGateway gateway;
  late DateTime clock;

  UpdateCheckCubit build({
    bool enabled = false,
    String? latest,
    String? Function()? respond,
    bool supported = true,
  }) {
    gateway = _FakeGateway(enabled: enabled, latest: latest, respond: respond);
    return UpdateCheckCubit(gateway, now: () => clock, supported: supported);
  }

  setUp(() => clock = DateTime(2026, 1, 1, 12));

  test('disabled setting makes no fetch', () async {
    final cubit = build(respond: () => '9.0.0');
    await cubit.checkOnStart();
    expect(gateway.calls, 0);
    expect(cubit.state.enabled, isFalse);
    expect(cubit.state.availableVersion, isNull);
  });

  test('unsupported platform never checks nor enables', () async {
    final cubit = build(
      enabled: true,
      respond: () => '9.0.0',
      supported: false,
    );
    await cubit.checkOnStart();
    await cubit.setEnabled(true);
    expect(gateway.calls, 0);
    expect(cubit.state.enabled, isFalse);
  });

  test(
    'enabling checks immediately and surfaces a newer version once',
    () async {
      final cubit = build(respond: () => '9.0.0');
      await cubit.setEnabled(true);
      expect(gateway.calls, 1);
      expect(cubit.state.availableVersion, '9.0.0');
      expect(cubit.state.announce, isTrue);
      // Same version again: shown in settings, but not announced twice.
      clock = clock.add(const Duration(hours: 25));
      await cubit.checkOnStart();
      expect(gateway.calls, 2);
      expect(cubit.state.availableVersion, '9.0.0');
      expect(cubit.state.announce, isFalse);
    },
  );

  test('start check is throttled to once per 24 hours', () async {
    final cubit = build(enabled: true, respond: () => '9.0.0');
    await cubit.checkOnStart();
    expect(gateway.calls, 1);
    clock = clock.add(const Duration(hours: 23));
    await cubit.checkOnStart();
    expect(gateway.calls, 1);
    clock = clock.add(const Duration(hours: 2));
    await cubit.checkOnStart();
    expect(gateway.calls, 2);
  });

  test(
    'a failed fetch is silent and leaves state and throttle alone',
    () async {
      final cubit = build(enabled: true, respond: () => null);
      await cubit.checkOnStart();
      expect(gateway.calls, 1);
      expect(cubit.state.availableVersion, isNull);
      expect(gateway.lastCheckMs, isNull);
      expect(gateway.latestVersion, isNull);
    },
  );

  test('a remote version that is not newer shows nothing', () async {
    final cubit = build(enabled: true, respond: () => kApplicationVersion);
    await cubit.checkOnStart();
    expect(cubit.state.availableVersion, isNull);
    expect(gateway.lastCheckMs, isNotNull);
  });

  group('checkNow', () {
    test('up to date, even with the opt-in off, keeps enabled false', () async {
      final cubit = build(respond: () => kApplicationVersion);
      expect(await cubit.checkNow(), UpdateCheckOutcome.upToDate);
      expect(cubit.state.outcome, UpdateCheckOutcome.upToDate);
      expect(cubit.state.checking, isFalse);
      expect(cubit.state.enabled, isFalse);
      expect(gateway.enabled, isFalse);
      expect(gateway.calls, 1);
    });

    test('newer version is reported without flipping enabled', () async {
      final cubit = build(respond: () => '9.0.0');
      expect(await cubit.checkNow(), UpdateCheckOutcome.available);
      expect(cubit.state.availableVersion, '9.0.0');
      expect(cubit.state.announce, isFalse);
      expect(cubit.state.enabled, isFalse);
      expect(gateway.enabled, isFalse);
    });

    test('failure is reported', () async {
      final cubit = build(respond: () => null);
      expect(await cubit.checkNow(), UpdateCheckOutcome.failed);
      expect(cubit.state.outcome, UpdateCheckOutcome.failed);
    });

    test('emits a checking state while pending', () async {
      final cubit = build(respond: () => '9.0.0');
      final states = <bool>[];
      cubit.stream.listen((s) => states.add(s.checking));
      await cubit.checkNow();
      await Future<void>.delayed(Duration.zero);
      expect(states, [true, false]);
    });
  });

  test('a known newer version is restored from the gateway', () {
    final cubit = build(enabled: true, latest: '9.0.0');
    expect(cubit.state.availableVersion, '9.0.0');
  });
}

class _FakeGateway implements UpdateCheckGateway {
  _FakeGateway({required this.enabled, String? latest, this.respond})
    : latestVersion = latest;

  final String? Function()? respond;
  int calls = 0;

  @override
  bool enabled;
  @override
  int? lastCheckMs;
  @override
  String? latestVersion;
  @override
  String? notifiedVersion;

  @override
  Future<void> setEnabled(bool value) async => enabled = value;
  @override
  Future<void> setLastCheckMs(int value) async => lastCheckMs = value;
  @override
  Future<void> setLatestVersion(String value) async => latestVersion = value;
  @override
  Future<void> setNotifiedVersion(String value) async =>
      notifiedVersion = value;

  @override
  Future<String?> fetchLatestVersion() async {
    calls++;
    return respond?.call();
  }
}
