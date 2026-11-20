// spec 023 T405 / passkeys-all-platforms T015 — the "Passkeys" settings row.
//
// FR-013: below API 34 the platform has no credential provider to register
// with, so the row must say so rather than offer a switch that does nothing.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/repositories/autofill_ports.dart';
import 'package:password_manager/injection_container.dart' as di;

import '../../bloc/vault/vault_bloc_harness.dart';
import 'vault_shell_test_utils.dart';

class _FakeAutofillClient implements AppleAutofillV2Client {
  _FakeAutofillClient(
    this.availability, {
    this.autofillEnabled = false,
    this.launchSucceeds = true,
  });

  final AndroidPasskeyProviderAvailability availability;
  final bool autofillEnabled;
  final bool launchSucceeds;
  int openAutofillCalls = 0;
  int openPasskeyCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<AndroidPasskeyProviderAvailability>
  getPasskeyProviderAvailability() async => availability;

  @override
  Future<bool?> getExtensionEnabled() async => null;

  @override
  Future<bool> getAutofillServiceEnabled() async => autofillEnabled;

  @override
  Future<bool> openAutofillSettings() async {
    openAutofillCalls++;
    return launchSucceeds;
  }

  @override
  Future<bool> openPasskeyProviderSettings() async {
    openPasskeyCalls++;
    return launchSucceeds;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(resetVaultShellTestDi);

  /// The override is cleared inside the body, not in `tearDown`:
  /// `_verifyInvariants` runs before teardown and fails a test that leaves a
  /// foundation debug variable set.
  Future<void> asPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> asAndroid(Future<void> Function() body) =>
      asPlatform(TargetPlatform.android, body);

  Future<_FakeAutofillClient> openSettings(
    WidgetTester tester, {
    required AndroidPasskeyProviderAvailability availability,
    bool autofillEnabled = false,
    bool launchSucceeds = true,
  }) async {
    final widget = await pumpableVaultShell();
    final client = _FakeAutofillClient(
      availability,
      autofillEnabled: autofillEnabled,
      launchSucceeds: launchSucceeds,
    );
    di.sl.registerLazySingleton<AppleAutofillV2Client>(() => client);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Settings'));
    await tester.pumpAndSettle();
    return client;
  }

  const api34 = AndroidPasskeyProviderAvailability(
    available: true,
    apiLevel: 34,
  );

  testWidgets('Autofill row on Android opens system settings', (tester) async {
    await asAndroid(() async {
      final client = await openSettings(tester, availability: api34);
      await tester.ensureVisible(find.text('Autofill & browsers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Autofill & browsers'));
      await tester.pumpAndSettle();

      expect(client.openAutofillCalls, 1);
      expect(find.textContaining('being rebuilt'), findsNothing);
    });
  });

  testWidgets('Autofill row on Android shows manual hint if launch fails', (
    tester,
  ) async {
    await asAndroid(() async {
      await openSettings(tester, availability: api34, launchSucceeds: false);
      await tester.ensureVisible(find.text('Autofill & browsers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Autofill & browsers'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Android Settings'), findsOneWidget);
    });
  });

  testWidgets('Passkeys row on Android opens the credential provider', (
    tester,
  ) async {
    await asAndroid(() async {
      final client = await openSettings(tester, availability: api34);
      await tester.ensureVisible(find.text('Passkeys'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Passkeys'));
      await tester.pumpAndSettle();

      expect(client.openPasskeyCalls, 1);
      expect(client.openAutofillCalls, 0);
    });
  });

  testWidgets('Passkeys row below API 34 opens nothing and says why', (
    tester,
  ) async {
    await asAndroid(() async {
      final client = await openSettings(
        tester,
        availability: const AndroidPasskeyProviderAvailability(
          available: false,
          apiLevel: 31,
        ),
      );
      await tester.ensureVisible(find.text('Passkeys'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Passkeys'));
      await tester.pumpAndSettle();

      expect(client.openPasskeyCalls, 0);
      expect(find.textContaining('Android 14'), findsWidgets);
    });
  });

  for (final (enabled, label) in [
    (true, 'Autofill enabled'),
    (false, 'Autofill not enabled yet'),
  ]) {
    testWidgets('Autofill row subtitle on Android: $label', (tester) async {
      await asAndroid(() async {
        await openSettings(
          tester,
          availability: api34,
          autofillEnabled: enabled,
        );
        expect(find.text(label), findsOneWidget);
      });
    });
  }

  testWidgets('on API 34+ the row says passkey sign-in is available', (
    tester,
  ) async {
    await asAndroid(() async {
      await openSettings(
        tester,
        availability: const AndroidPasskeyProviderAvailability(
          available: true,
          apiLevel: 34,
        ),
      );

      expect(find.text('Passkeys'), findsOneWidget);
      expect(find.textContaining('system credential provider'), findsOneWidget);
      expect(find.textContaining('only on this device'), findsOneWidget);
    });
  });

  testWidgets('below API 34 the row says the device is too old, and why', (
    tester,
  ) async {
    await asAndroid(() async {
      await openSettings(
        tester,
        availability: const AndroidPasskeyProviderAvailability(
          available: false,
          apiLevel: 31,
        ),
      );

      expect(find.text('Passkeys'), findsOneWidget);
      expect(find.textContaining('Not available:'), findsOneWidget);
      expect(find.textContaining('needs Android 14 or later'), findsOneWidget);
      // The device's own level, so the user can tell what they have.
      expect(find.textContaining('API 31'), findsOneWidget);
    });
  });

  testWidgets('with no client registered the row is simply absent', (
    tester,
  ) async {
    await asAndroid(() async {
      await tester.pumpWidget(await pumpableVaultShell());
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Settings'));
      await tester.pumpAndSettle();

      // A host without the platform channel must not show a row it cannot
      // answer for — and must not crash reaching for it.
      expect(find.text('Passkeys'), findsNothing);
    });
  });

  for (final (platform, expected) in [
    (TargetPlatform.iOS, 'through AutoFill'),
    (TargetPlatform.macOS, 'through AutoFill'),
    (TargetPlatform.windows, 'through the Custode extension only'),
    (TargetPlatform.linux, 'through the Custode extension only'),
  ]) {
    testWidgets('on $platform the row says what works and why', (tester) async {
      await asPlatform(platform, () async {
        await tester.pumpWidget(await pumpableVaultShell());
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('Settings'));
        await tester.pumpAndSettle();

        expect(find.text('Passkeys'), findsOneWidget);
        expect(find.textContaining(expected), findsOneWidget);
        final apple =
            platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
        expect(
          find.textContaining('only on this device'),
          apple ? findsOneWidget : findsNothing,
        );
      });
    });
  }

  testWidgets('nothing waiting: no "Passkeys waiting" row', (tester) async {
    await asAndroid(() async {
      await tester.pumpWidget(await pumpableVaultShell());
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Passkeys waiting'), findsNothing);
    });
  });

  testWidgets('waiting passkeys are counted', (tester) async {
    await tester.pumpWidget(
      await pumpableVaultShell(
        vaultKdbxService: FakeVaultKdbxService(snapshot: nestedSnapshot()),
        pendingPasskeyAdoptionCoordinator:
            FakePendingPasskeyAdoptionCoordinator(waiting: 2),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Passkeys waiting'), findsOneWidget);
    expect(find.textContaining('2 on this device'), findsOneWidget);
  });
}
