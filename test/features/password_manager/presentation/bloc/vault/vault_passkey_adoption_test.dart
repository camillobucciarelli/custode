// Passkeys-all-platforms T014 — adoption events: translate and delegate. The
// bloc sequences nothing; it hands the user's answer to the coordinator, then
// reloads (which republishes the autofill cache) and reports.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/pending_passkey_adoption_coordinator.dart';

import 'vault_bloc_harness.dart';

const _adopted = AdoptedPasskey(
  recordId: 'r1',
  rpId: 'webauthn.io',
  username: 'ada@example.com',
  entryId: 'e-root',
  createdNewEntry: false,
  backupPath: '/tmp/vault.20260301-120000-000000.pre-adopt-passkey.kdbx',
);

const _clash = PasskeyClashRequest(
  recordId: 'r2',
  rpId: 'passkeys.io',
  username: 'ada',
  candidateEntryIds: ['e-root'],
);

const _other = PendingPasskeyOtherVault(
  recordId: 'r3',
  rpId: 'example.org',
  username: 'bob',
  databaseId: 'sha256:other',
);

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('unlock adopts, reloads, republishes and names site, account and '
      'backup', () async {
    final autofill = RecordingAutofillCoordinator();
    final coordinator = FakePendingPasskeyAdoptionCoordinator(
      adoptResult: const PendingPasskeyAdoptionResult(adopted: [_adopted]),
    );
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      autofill: autofill,
      pendingPasskeyAdoptionCoordinator: coordinator,
    );
    addTearDown(bloc.close);

    bloc.add(const InitializeVault());
    await _settle();

    expect(coordinator.adoptCalls, 1);
    // One publish for the unlock load, one after the adoption.
    expect(autofill.published.length, 2);
    expect(
      bloc.state.infoMessage,
      'Passkey for webauthn.io (ada@example.com) was added to your vault. '
      'A backup was saved as '
      'vault.20260301-120000-000000.pre-adopt-passkey.kdbx.',
    );
    expect(bloc.state.errorMessage, isNull);
  });

  test('nothing waiting changes nothing', () async {
    final autofill = RecordingAutofillCoordinator();
    final coordinator = FakePendingPasskeyAdoptionCoordinator();
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      autofill: autofill,
      pendingPasskeyAdoptionCoordinator: coordinator,
    );
    addTearDown(bloc.close);

    bloc.add(const InitializeVault());
    await _settle();

    expect(autofill.published.length, 1);
    expect(bloc.state.infoMessage, isNull);
    expect(bloc.state.passkeyClashes, isEmpty);
    expect(bloc.state.passkeyOtherVault, isEmpty);
  });

  test('resume runs adoption again; a locked vault is silent', () async {
    final coordinator = FakePendingPasskeyAdoptionCoordinator(
      adoptResult: const PendingPasskeyAdoptionResult(
        status: PendingPasskeyAdoptionStatus.vaultLocked,
      ),
    );
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: coordinator,
    );
    addTearDown(bloc.close);

    bloc.add(const AdoptPendingPasskeys());
    await _settle();

    expect(coordinator.adoptCalls, 1);
    expect(bloc.state.errorMessage, isNull);
  });

  test(
    'clashes, other-vault records and unreadable ones become state',
    () async {
      final bloc = buildTestVaultBloc(
        snapshot: nestedSnapshot(),
        pendingPasskeyAdoptionCoordinator:
            FakePendingPasskeyAdoptionCoordinator(
              adoptResult: const PendingPasskeyAdoptionResult(
                clashes: [_clash],
                otherVault: [_other],
                unreadableCount: 2,
              ),
            ),
      );
      addTearDown(bloc.close);

      bloc.add(const AdoptPendingPasskeys());
      await _settle();

      expect(bloc.state.passkeyClashes, [_clash]);
      expect(bloc.state.passkeyOtherVault, [_other]);
      expect(bloc.state.infoMessage, '2 waiting passkeys could not be read.');
    },
  );

  test('one unreadable record is worded in the singular', () async {
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: FakePendingPasskeyAdoptionCoordinator(
        adoptResult: const PendingPasskeyAdoptionResult(unreadableCount: 1),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(const AdoptPendingPasskeys());
    await _settle();

    expect(bloc.state.infoMessage, '1 waiting passkey could not be read.');
  });

  test(
    'a failed write reports the backup and says nothing was deleted',
    () async {
      final bloc = buildTestVaultBloc(
        snapshot: nestedSnapshot(),
        pendingPasskeyAdoptionCoordinator:
            FakePendingPasskeyAdoptionCoordinator(
              adoptResult: const PendingPasskeyAdoptionResult(
                failures: [
                  PendingPasskeyFailure(
                    recordId: 'r1',
                    rpId: 'webauthn.io',
                    username: 'ada',
                    stage: PendingPasskeyFailureStage.write,
                    errorType: 'StateError',
                    backupPath:
                        '/tmp/vault.20260301-120000.pre-adopt-passkey.kdbx',
                  ),
                ],
              ),
            ),
      );
      addTearDown(bloc.close);

      bloc.add(const AdoptPendingPasskeys());
      await _settle();

      expect(
        bloc.state.errorMessage,
        'Unable to add the passkey for webauthn.io (ada). It is still waiting '
        'and nothing was deleted. The backup '
        'vault.20260301-120000.pre-adopt-passkey.kdbx was kept.',
      );
    },
  );

  test(
    'a resolve failure says the vault holds it, once per record and session',
    () async {
      final coordinator = FakePendingPasskeyAdoptionCoordinator(
        adoptResult: const PendingPasskeyAdoptionResult(
          adopted: [
            AdoptedPasskey(
              recordId: 'r1',
              rpId: 'webauthn.io',
              username: 'ada',
              entryId: 'e1',
              createdNewEntry: true,
              backupPath: '/tmp/vault.bak.kdbx',
            ),
          ],
          failures: [
            PendingPasskeyFailure(
              recordId: 'r1',
              rpId: 'webauthn.io',
              username: 'ada',
              stage: PendingPasskeyFailureStage.resolve,
              errorType: 'StateError',
            ),
          ],
        ),
      );
      final bloc = buildTestVaultBloc(
        snapshot: nestedSnapshot(),
        pendingPasskeyAdoptionCoordinator: coordinator,
      );
      addTearDown(bloc.close);

      bloc.add(const AdoptPendingPasskeys());
      await _settle();

      expect(
        bloc.state.errorMessage,
        'The passkey for webauthn.io (ada) is in your vault; its waiting '
        'copy on this device could not be removed.',
      );
      expect(bloc.state.infoMessage, isNull);

      // r1 again plus a new r2: only r2 is worded.
      PendingPasskeyFailure failure(String id, String rp) =>
          PendingPasskeyFailure(
            recordId: id,
            rpId: rp,
            username: '',
            stage: PendingPasskeyFailureStage.resolve,
            errorType: 'StateError',
          );
      coordinator.adoptResult = PendingPasskeyAdoptionResult(
        failures: [failure('r1', 'webauthn.io'), failure('r2', 'other.io')],
      );
      bloc.add(const AdoptPendingPasskeys());
      await _settle();

      expect(
        bloc.state.errorMessage,
        'The passkey for other.io is in your vault; its waiting copy on '
        'this device could not be removed.',
      );
    },
  );

  test(
    'a deferred question stays away from automatic runs until asked again',
    () async {
      final coordinator = FakePendingPasskeyAdoptionCoordinator(
        adoptResult: const PendingPasskeyAdoptionResult(
          clashes: [_clash],
          otherVault: [_other],
        ),
      );
      final bloc = buildTestVaultBloc(
        snapshot: nestedSnapshot(),
        pendingPasskeyAdoptionCoordinator: coordinator,
      );
      addTearDown(bloc.close);

      bloc.add(const AdoptPendingPasskeys());
      await _settle();
      bloc
        ..add(DeferPasskeyAdoptionPrompt(_clash.recordId))
        ..add(DeferPasskeyAdoptionPrompt(_other.recordId));
      await _settle();
      bloc.add(const AdoptPendingPasskeys());
      await _settle();

      expect(bloc.state.passkeyClashes, isEmpty);
      expect(bloc.state.passkeyOtherVault, isEmpty);

      bloc.add(const AdoptPendingPasskeys(includeDeferred: true));
      await _settle();

      expect(bloc.state.passkeyClashes, [_clash]);
      expect(bloc.state.passkeyOtherVault, [_other]);
    },
  );

  test('a read failure is reported and changes nothing', () async {
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: FakePendingPasskeyAdoptionCoordinator(
        adoptResult: const PendingPasskeyAdoptionResult(
          status: PendingPasskeyAdoptionStatus.readFailed,
          readErrorCode: 'x',
        ),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(const AdoptPendingPasskeys());
    await _settle();

    expect(bloc.state.errorMessage, contains('Unable to read'));
  });

  test('ResolvePasskeyClash hands the decision over and retires the '
      'question', () async {
    final coordinator = FakePendingPasskeyAdoptionCoordinator(
      adoptResult: const PendingPasskeyAdoptionResult(
        clashes: [_clash],
        otherVault: [_other],
      ),
      actionResult: const PendingPasskeyAdoptionResult(
        adopted: [
          AdoptedPasskey(
            recordId: 'r2',
            rpId: 'passkeys.io',
            username: 'ada',
            entryId: 'e-root',
            createdNewEntry: true,
            backupPath: '/tmp/b.kdbx',
          ),
        ],
      ),
    );
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: coordinator,
    );
    addTearDown(bloc.close);
    bloc.add(const AdoptPendingPasskeys());
    await _settle();

    bloc.add(
      const ResolvePasskeyClash(
        recordId: 'r2',
        decision: PasskeyClashDecision.replace,
        replaceEntryId: 'e-root',
      ),
    );
    await _settle();

    expect(coordinator.clashDecisions, [
      ('r2', PasskeyClashDecision.replace, 'e-root'),
    ]);
    expect(bloc.state.passkeyClashes, isEmpty);
    // The other-vault question is untouched by an answer to a clash.
    expect(bloc.state.passkeyOtherVault, [_other]);
    expect(bloc.state.infoMessage, contains('passkeys.io (ada)'));
    expect(bloc.state.isSaving, isFalse);
  });

  test('a clash that comes back is asked again', () async {
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: FakePendingPasskeyAdoptionCoordinator(
        actionResult: const PendingPasskeyAdoptionResult(clashes: [_clash]),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(
      const ResolvePasskeyClash(
        recordId: 'r2',
        decision: PasskeyClashDecision.keepBoth,
      ),
    );
    await _settle();

    expect(bloc.state.passkeyClashes, [_clash]);
  });

  test('MovePendingPasskeyToThisVault delegates and retires the '
      'record', () async {
    final coordinator = FakePendingPasskeyAdoptionCoordinator(
      adoptResult: const PendingPasskeyAdoptionResult(otherVault: [_other]),
    );
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: coordinator,
    );
    addTearDown(bloc.close);
    bloc.add(const AdoptPendingPasskeys());
    await _settle();

    bloc.add(const MovePendingPasskeyToThisVault('r3'));
    await _settle();

    expect(coordinator.moved, ['r3']);
    expect(bloc.state.passkeyOtherVault, isEmpty);
  });

  test('a failed move keeps the record and says nothing was deleted', () async {
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: FakePendingPasskeyAdoptionCoordinator(
        actionResult: const PendingPasskeyAdoptionResult(
          failures: [
            PendingPasskeyFailure(
              recordId: 'r3',
              rpId: 'example.org',
              username: 'bob',
              stage: PendingPasskeyFailureStage.backup,
              errorType: 'FileSystemException',
            ),
          ],
        ),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(const MovePendingPasskeyToThisVault('r3'));
    await _settle();

    expect(bloc.state.errorMessage, contains('nothing was deleted'));
    expect(bloc.state.errorMessage, isNot(contains('backup')));
  });

  test('DiscardPendingPasskey deletes through the coordinator', () async {
    final coordinator = FakePendingPasskeyAdoptionCoordinator(
      adoptResult: const PendingPasskeyAdoptionResult(otherVault: [_other]),
    );
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: coordinator,
    );
    addTearDown(bloc.close);
    bloc.add(const AdoptPendingPasskeys());
    await _settle();

    bloc.add(const DiscardPendingPasskey('r3'));
    await _settle();

    expect(coordinator.discarded, ['r3']);
    expect(bloc.state.passkeyOtherVault, isEmpty);
    expect(
      bloc.state.infoMessage,
      'The waiting passkey for example.org was discarded.',
    );
  });

  test('a failed discard keeps the question and the record', () async {
    final coordinator = FakePendingPasskeyAdoptionCoordinator(
      adoptResult: const PendingPasskeyAdoptionResult(otherVault: [_other]),
    )..discardError = PlatformException(code: 'io', message: 'PRIVATE KEY');
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: coordinator,
    );
    addTearDown(bloc.close);
    bloc.add(const AdoptPendingPasskeys());
    await _settle();

    bloc.add(const DiscardPendingPasskey('r3'));
    await _settle();

    expect(bloc.state.passkeyOtherVault, [_other]);
    expect(bloc.state.errorMessage, contains('nothing was deleted'));
    expect(bloc.state.errorMessage, isNot(contains('PRIVATE')));
  });

  test('DeferPasskeyAdoptionPrompt drops the question without calling the '
      'coordinator', () async {
    final coordinator = FakePendingPasskeyAdoptionCoordinator(
      adoptResult: const PendingPasskeyAdoptionResult(
        clashes: [_clash],
        otherVault: [_other],
      ),
    );
    final bloc = buildTestVaultBloc(
      snapshot: nestedSnapshot(),
      pendingPasskeyAdoptionCoordinator: coordinator,
    );
    addTearDown(bloc.close);
    bloc.add(const AdoptPendingPasskeys());
    await _settle();

    bloc.add(const DeferPasskeyAdoptionPrompt('r2'));
    bloc.add(const DeferPasskeyAdoptionPrompt('r3'));
    await _settle();

    expect(bloc.state.passkeyClashes, isEmpty);
    expect(bloc.state.passkeyOtherVault, isEmpty);
    expect(coordinator.clashDecisions, isEmpty);
    expect(coordinator.discarded, isEmpty);
    expect(coordinator.moved, isEmpty);
  });

  test('without a coordinator every adoption event is a no-op', () async {
    final bloc = buildTestVaultBloc(snapshot: nestedSnapshot());
    addTearDown(bloc.close);

    bloc
      ..add(const AdoptPendingPasskeys())
      ..add(const DiscardPendingPasskey('r'))
      ..add(const MovePendingPasskeyToThisVault('r'));
    await _settle();

    expect(bloc.state.errorMessage, isNull);
    expect(bloc.state.infoMessage, isNull);
  });
}
