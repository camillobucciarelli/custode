// Passkeys-all-platforms T014 — the adoption questions in the vault shell.
//
// Each case asserts what the coordinator was handed, not only what appeared:
// a dialog that reads right but resolves the wrong record or decision would
// pass a screenshot.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/pending_passkey_adoption_coordinator.dart';

import '../../bloc/vault/vault_bloc_harness.dart';
import 'vault_shell_test_utils.dart';

const _clash = PasskeyClashRequest(
  recordId: 'r-clash',
  rpId: 'webauthn.io',
  username: 'ada@example.com',
  candidateEntryIds: ['e-root'],
);

const _other = PendingPasskeyOtherVault(
  recordId: 'r-other',
  rpId: 'example.org',
  username: 'bob',
  databaseId: 'sha256:other',
);

const _otherNamed = PendingPasskeyOtherVault(
  recordId: 'r-other',
  rpId: 'example.org',
  username: 'bob',
  databaseId: 'sha256:other',
  vaultName: 'Work',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    await (FontLoader(
      'Caprasimo',
    )..addFont(rootBundle.load('assets/fonts/Caprasimo-Regular.ttf'))).load();
    await (FontLoader('Figtree')
          ..addFont(rootBundle.load('assets/fonts/Figtree-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-SemiBold.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-Bold.ttf')))
        .load();
  });

  tearDown(resetVaultShellTestDi);

  Future<FakePendingPasskeyAdoptionCoordinator> pumpShell(
    WidgetTester tester, {
    List<PasskeyClashRequest> clashes = const [],
    List<PendingPasskeyOtherVault> otherVault = const [],
    PendingPasskeyAdoptionResult actionResult =
        const PendingPasskeyAdoptionResult(),
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final coordinator = FakePendingPasskeyAdoptionCoordinator(
      adoptResult: PendingPasskeyAdoptionResult(
        clashes: clashes,
        otherVault: otherVault,
      ),
      actionResult: actionResult,
    );
    await tester.pumpWidget(
      await pumpableVaultShell(
        vaultKdbxService: FakeVaultKdbxService(snapshot: nestedSnapshot()),
        pendingPasskeyAdoptionCoordinator: coordinator,
      ),
    );
    await tester.pumpAndSettle();
    return coordinator;
  }

  group('clash', () {
    testWidgets('names site, account and the backup; keep both is explicit', (
      tester,
    ) async {
      final coordinator = await pumpShell(tester, clashes: [_clash]);

      expect(find.text('Replace the passkey for webauthn.io?'), findsOneWidget);
      expect(find.textContaining('“ada@example.com”'), findsOneWidget);
      expect(find.textContaining('A dated backup'), findsOneWidget);

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();

      expect(coordinator.clashDecisions, [
        ('r-clash', PasskeyClashDecision.keepBoth, null),
      ]);
    });

    testWidgets('replace hands over the chosen entry', (tester) async {
      final coordinator = await pumpShell(tester, clashes: [_clash]);

      await tester.tap(find.text('Replace old passkey'));
      await tester.pumpAndSettle();

      expect(coordinator.clashDecisions, [
        ('r-clash', PasskeyClashDecision.replace, 'e-root'),
      ]);
    });

    testWidgets('several candidates each get their own replace button', (
      tester,
    ) async {
      final coordinator = await pumpShell(
        tester,
        clashes: [
          const PasskeyClashRequest(
            recordId: 'r-clash',
            rpId: 'webauthn.io',
            username: 'ada@example.com',
            candidateEntryIds: ['e-root', 'e-work'],
          ),
        ],
      );

      expect(find.text('Replace old passkey'), findsNothing);
      await tester.tap(find.text('Replace the one on “Borealis”'));
      await tester.pumpAndSettle();

      expect(coordinator.clashDecisions, [
        ('r-clash', PasskeyClashDecision.replace, 'e-work'),
      ]);
    });

    testWidgets('deciding later calls nothing', (tester) async {
      final coordinator = await pumpShell(tester, clashes: [_clash]);

      await tester.tap(find.text('Decide later'));
      await tester.pumpAndSettle();

      expect(coordinator.clashDecisions, isEmpty);
      expect(find.text('Replace the passkey for webauthn.io?'), findsNothing);
    });
  });

  group('another vault', () {
    testWidgets('names the vault when it is known', (tester) async {
      await pumpShell(tester, otherVault: [_otherNamed]);

      expect(
        find.text('A passkey for example.org belongs to the vault “Work”'),
        findsOneWidget,
      );
      expect(
        find.textContaining('for the vault “Work”, not this one'),
        findsOneWidget,
      );
    });

    testWidgets('move asks for confirmation, then moves', (tester) async {
      final coordinator = await pumpShell(tester, otherVault: [_other]);

      expect(
        find.text('A passkey for example.org belongs to another vault'),
        findsOneWidget,
      );
      await tester.tap(find.text('Move to this vault'));
      await tester.pumpAndSettle();

      // Nothing has been moved yet: the confirmation is on screen.
      expect(find.text('Move this passkey to this vault?'), findsOneWidget);
      expect(coordinator.moved, isEmpty);

      await tester.tap(find.text('Move to this vault'));
      await tester.pumpAndSettle();

      expect(coordinator.moved, ['r-other']);
      expect(coordinator.discarded, isEmpty);
    });

    testWidgets('declining the move confirmation moves nothing', (
      tester,
    ) async {
      final coordinator = await pumpShell(tester, otherVault: [_other]);

      await tester.tap(find.text('Move to this vault'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(coordinator.moved, isEmpty);
      expect(coordinator.discarded, isEmpty);
    });

    testWidgets('discard says it is permanent and only then deletes', (
      tester,
    ) async {
      final coordinator = await pumpShell(tester, otherVault: [_other]);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('Discard this passkey?'), findsOneWidget);
      expect(find.textContaining('This is permanent'), findsOneWidget);
      expect(find.textContaining('will stop working'), findsOneWidget);
      expect(coordinator.discarded, isEmpty);

      await tester.tap(find.text('Discard passkey'));
      await tester.pumpAndSettle();

      expect(coordinator.discarded, ['r-other']);
      expect(coordinator.moved, isEmpty);
    });

    testWidgets('declining the discard confirmation deletes nothing', (
      tester,
    ) async {
      final coordinator = await pumpShell(tester, otherVault: [_other]);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(coordinator.discarded, isEmpty);
    });
  });

  group('messages', () {
    testWidgets('success names site and account and the backup', (
      tester,
    ) async {
      await pumpShell(
        tester,
        clashes: [_clash],
        actionResult: const PendingPasskeyAdoptionResult(
          adopted: [
            AdoptedPasskey(
              recordId: 'r-clash',
              rpId: 'webauthn.io',
              username: 'ada@example.com',
              entryId: 'e-root',
              createdNewEntry: true,
              backupPath: '/tmp/v.pre-adopt-passkey.kdbx',
            ),
          ],
        ),
      );

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Passkey for webauthn.io (ada@example.com) was added to your vault. '
          'A backup was saved as v.pre-adopt-passkey.kdbx.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('failure shows the backup path and deletes nothing', (
      tester,
    ) async {
      await pumpShell(
        tester,
        clashes: [_clash],
        actionResult: const PendingPasskeyAdoptionResult(
          failures: [
            PendingPasskeyFailure(
              recordId: 'r-clash',
              rpId: 'webauthn.io',
              username: 'ada@example.com',
              stage: PendingPasskeyFailureStage.write,
              errorType: 'StateError',
              backupPath: '/tmp/v.pre-adopt-passkey.kdbx',
            ),
          ],
        ),
      );

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();

      expect(find.textContaining('nothing was deleted'), findsOneWidget);
      expect(
        find.textContaining('The backup v.pre-adopt-passkey.kdbx was kept.'),
        findsOneWidget,
      );
    });

    testWidgets('unreadable records are counted, with no discard action', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        await pumpableVaultShell(
          pendingPasskeyAdoptionCoordinator:
              FakePendingPasskeyAdoptionCoordinator(
                adoptResult: const PendingPasskeyAdoptionResult(
                  unreadableCount: 3,
                ),
              ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('3 waiting passkeys could not be read.'),
        findsOneWidget,
      );
      expect(find.text('Discard'), findsNothing);
    });
  });

  testWidgets('nothing waiting shows nothing', (tester) async {
    await pumpShell(tester);

    expect(find.textContaining('passkey'), findsNothing);
  });
}
