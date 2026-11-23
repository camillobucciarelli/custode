import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/biometric_data_source.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/errors/database_access_failure.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/get_active_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/resolve_database_duplicate_usecase.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_event.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_state.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';

import '../coordinators/fake_database_ports.dart';

void main() {
  group('DatabaseUnlockBloc', () {
    late _FakeBiometricDataSource biometric;
    late FakeDatabaseFileRepository fileRepository;
    late FakeDatabaseSessionRepository sessionRepository;
    late FakeDatabaseRegistryRepository registryRepository;
    late FakeDatabaseSecurityRepository securityRepository;
    late FakeDatabaseSyncRepository syncRepository;
    late FakeUnlockDatabaseUseCase unlockUseCase;
    late DatabaseSessionCoordinator coordinator;
    late DatabaseUnlockBloc bloc;

    setUp(() {
      biometric = _FakeBiometricDataSource();
      fileRepository = FakeDatabaseFileRepository();
      sessionRepository = FakeDatabaseSessionRepository();
      registryRepository = FakeDatabaseRegistryRepository();
      securityRepository = FakeDatabaseSecurityRepository();
      syncRepository = FakeDatabaseSyncRepository();
      unlockUseCase = FakeUnlockDatabaseUseCase();
      coordinator = DatabaseSessionCoordinator(
        sessionSecretHolder: SessionSecretHolder(),
        databaseFileRepository: fileRepository,
        databaseSessionRepository: sessionRepository,
        databaseRegistryRepository: registryRepository,
        databaseSecurityRepository: securityRepository,
        databaseSyncRepository: syncRepository,
        linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
        getActiveDatabaseUseCase: GetActiveDatabaseUseCase(registryRepository),
        resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
          registryRepository,
        ),
        unlockDatabaseUseCase: unlockUseCase,
        createDatabaseUseCase: CreateDatabaseUseCase(
          databaseFileRepository: fileRepository,
        ),
      );
      bloc = DatabaseUnlockBloc(
        databasePath: '/tmp/vault.kdbx',
        biometricDataSource: biometric,
        databaseSessionCoordinator: coordinator,
      );
    });

    tearDown(() async {
      await bloc.close();
    });

    test(
      'initializes and unlocks manually when biometric not required',
      () async {
        final states = <DatabaseUnlockState>[];
        final sub = bloc.stream.listen(states.add);

        bloc.add(const InitializeDatabaseUnlock());
        await _untilLast(states, (s) => s.phase == UnlockPhase.ready);

        expect(states.any((s) => s.isLoading), isTrue);
        expect(states.last.phase, UnlockPhase.ready);
        expect(states.last.biometricVerified, isTrue);

        bloc.add(
          const UnlockWithManualCredentials(
            password: 'secret',
            keyFilePath: null,
          ),
        );
        await _untilLast(states, (s) => s.unlocked);

        // C-4: `decrypting` is entered before the await, then `unlocked`.
        expect(states.map((s) => s.phase), contains(UnlockPhase.decrypting));
        expect(states.last.unlocked, isTrue);
        expect(unlockUseCase.callCount, 1);

        await sub.cancel();
      },
    );

    test('unlocks with a selected key file and passes its path on', () async {
      fileRepository.existingPaths.add('/tmp/vault.key');
      final states = <DatabaseUnlockState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(const InitializeDatabaseUnlock());
      await _untilLast(states, (s) => s.phase == UnlockPhase.ready);
      bloc.add(const UpdateKeyFilePath('/tmp/vault.key'));
      await _untilLast(states, (s) => s.keyFilePath == '/tmp/vault.key');
      bloc.add(
        const UnlockWithManualCredentials(
          password: 'secret',
          keyFilePath: '/tmp/vault.key',
        ),
      );
      await _untilLast(states, (s) => s.unlocked);

      expect(unlockUseCase.lastKeyFilePath, '/tmp/vault.key');

      await sub.cancel();
    });

    test('retrying failed biometric authentication does not unlock and leaves '
        'the vault untouched', () async {
      biometric.available = true;
      biometric.authenticateResult = false;

      final states = <DatabaseUnlockState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(const InitializeDatabaseUnlock());
      await _untilLast(states, (s) => s.phase == UnlockPhase.ready);
      bloc.add(const RetryBiometricAuthentication());
      await _untilLast(
        states,
        (s) => s.biometricPrompted && !s.biometricVerified,
      );

      expect(states.last.biometricVerified, isFalse);
      expect(unlockUseCase.callCount, 0);

      await sub.cancel();
    });

    test('a non-typed failure while selecting a key file surfaces an error '
        'instead of escaping the handler', () async {
      fileRepository.existingPaths.add('/tmp/vault.key');
      fileRepository.ensureManagedKeyFileError = StateError('import failed');

      final states = <DatabaseUnlockState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(const InitializeDatabaseUnlock());
      await _untilLast(states, (s) => s.phase == UnlockPhase.ready);
      bloc.add(const UpdateKeyFilePath('/tmp/vault.key'));
      await _untilLast(states, (s) => s.errorMessage != null);

      expect(states.last.phase, UnlockPhase.ready);
      expect(states.last.errorMessage, 'Unable to use the selected key file.');
      expect(states.last.keyFilePath, isNull);

      await sub.cancel();
    });

    group('manual unlock fallback from the biometric gate', () {
      /// Registers the db + a biometric-required security profile so
      /// `initializeUnlock` actually enters the gate, and makes every
      /// biometric attempt fail (broken-sensor scenario).
      void seedBiometricRequiredWithBrokenSensor() {
        biometric.available = true;
        biometric.authenticateResult = false;
        registryRepository.records = [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: '/tmp/vault.kdbx',
            displayName: 'vault.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ];
        securityRepository.profiles['db-1'] = const DatabaseSecurityProfile(
          databaseId: 'db-1',
          biometricProtectionEnabled: true,
        );
      }

      test(
        'biometric fail -> fallback requested -> manual unlock succeeds',
        () async {
          seedBiometricRequiredWithBrokenSensor();

          final states = <DatabaseUnlockState>[];
          final sub = bloc.stream.listen(states.add);

          bloc.add(const InitializeDatabaseUnlock());
          await _untilLast(
            states,
            (s) => s.phase == UnlockPhase.biometricGate && s.biometricPrompted,
          );

          expect(states.last.phase, UnlockPhase.biometricGate);

          // Gate still enforced before the fallback is requested.
          bloc.add(
            const UnlockWithManualCredentials(
              password: 'secret',
              keyFilePath: null,
            ),
          );
          // The gate rejection is itself an emission, so this waits on the
          // behaviour under test rather than on the clock.
          await _untilLast(
            states,
            (s) =>
                s.errorMessage ==
                'Use biometric authentication before unlocking the database.',
          );
          expect(unlockUseCase.callCount, 0);

          bloc.add(const RequestManualUnlockFallback());
          await _untilLast(states, (s) => s.manualFallbackRequested);

          expect(states.last.phase, UnlockPhase.ready);
          expect(states.last.manualFallbackRequested, isTrue);
          expect(states.last.biometricVerified, isFalse);

          bloc.add(
            const UnlockWithManualCredentials(
              password: 'secret',
              keyFilePath: null,
            ),
          );
          await _untilLast(states, (s) => s.unlocked);

          expect(states.map((s) => s.phase), contains(UnlockPhase.decrypting));
          expect(states.last.unlocked, isTrue);
          expect(unlockUseCase.callCount, 1);

          await sub.cancel();
        },
      );

      test('repeated biometric failures still allow the fallback', () async {
        seedBiometricRequiredWithBrokenSensor();

        final states = <DatabaseUnlockState>[];
        final sub = bloc.stream.listen(states.add);

        bloc.add(const InitializeDatabaseUnlock());
        await _untilLast(
          states,
          (s) => s.phase == UnlockPhase.biometricGate && s.biometricPrompted,
        );

        // Both retries settle on the same terminal state, so they are
        // sequenced on the emission count: a predicate over `states.last`
        // cannot tell the second attempt from the first.
        var mark = states.length;
        bloc.add(const RetryBiometricAuthentication());
        await _until(() => states.length >= mark + 2);
        mark = states.length;
        bloc.add(const RetryBiometricAuthentication());
        await _until(() => states.length >= mark + 2);

        expect(states.last.phase, UnlockPhase.biometricGate);

        bloc.add(const RequestManualUnlockFallback());
        await _untilLast(states, (s) => s.manualFallbackRequested);

        expect(states.last.phase, UnlockPhase.ready);
        expect(states.last.manualFallbackRequested, isTrue);

        await sub.cancel();
      });

      test(
        'fallback does not alter the persisted biometric requirement',
        () async {
          seedBiometricRequiredWithBrokenSensor();

          bloc.add(const InitializeDatabaseUnlock());
          await _until(
            () =>
                bloc.state.phase == UnlockPhase.biometricGate &&
                bloc.state.biometricPrompted,
          );
          bloc.add(const RequestManualUnlockFallback());
          await _until(() => bloc.state.manualFallbackRequested);
          bloc.add(
            const UnlockWithManualCredentials(
              password: 'secret',
              keyFilePath: null,
            ),
          );
          await _until(() => bloc.state.unlocked);

          expect(bloc.state.unlocked, isTrue);
          expect(
            securityRepository.profiles['db-1']!.biometricProtectionEnabled,
            isTrue,
          );

          // Next launch (fresh bloc) gates on biometrics again.
          final nextLaunchBloc = DatabaseUnlockBloc(
            databasePath: '/tmp/vault.kdbx',
            biometricDataSource: biometric,
            databaseSessionCoordinator: coordinator,
          );
          nextLaunchBloc.add(const InitializeDatabaseUnlock());
          await _until(
            () =>
                nextLaunchBloc.state.phase == UnlockPhase.biometricGate &&
                nextLaunchBloc.state.biometricPrompted,
          );
          expect(nextLaunchBloc.state.phase, UnlockPhase.biometricGate);
          expect(nextLaunchBloc.state.manualFallbackRequested, isFalse);
          await nextLaunchBloc.close();
        },
      );
    });

    test(
      'typed InvalidCredentialsFailure keeps phase ready with copy',
      () async {
        unlockUseCase.error = const InvalidCredentialsFailure();

        final states = <DatabaseUnlockState>[];
        final sub = bloc.stream.listen(states.add);

        bloc.add(const InitializeDatabaseUnlock());
        await _untilLast(states, (s) => s.phase == UnlockPhase.ready);
        bloc.add(
          const UnlockWithManualCredentials(
            password: 'wrong',
            keyFilePath: null,
          ),
        );
        await _untilLast(states, (s) => s.failure != null);

        expect(states.last.phase, UnlockPhase.ready);
        expect(states.last.failure, isA<InvalidCredentialsFailure>());
        expect(
          states.last.errorMessage,
          'Incorrect master password or key file.',
        );

        await sub.cancel();
      },
    );

    test('typed CorruptDatabaseFailure moves to failure phase, never says '
        'wrong password', () async {
      unlockUseCase.error = const CorruptDatabaseFailure('vault.kdbx');

      final states = <DatabaseUnlockState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(const InitializeDatabaseUnlock());
      await _untilLast(states, (s) => s.phase == UnlockPhase.ready);
      bloc.add(
        const UnlockWithManualCredentials(
          password: 'secret',
          keyFilePath: null,
        ),
      );
      await _untilLast(states, (s) => s.phase == UnlockPhase.failure);

      expect(states.last.phase, UnlockPhase.failure);
      expect(states.last.failure, isA<CorruptDatabaseFailure>());
      expect(states.last.errorMessage, isNot(contains('password')));

      await sub.cancel();
    });

    test(
      'a subsequent generic failure clears a previous typed failure '
      '(regression: stale typed field error must not stick around)',
      () async {
        unlockUseCase.error = const InvalidCredentialsFailure();

        final states = <DatabaseUnlockState>[];
        final sub = bloc.stream.listen(states.add);

        bloc.add(const InitializeDatabaseUnlock());
        await _untilLast(states, (s) => s.phase == UnlockPhase.ready);
        bloc.add(
          const UnlockWithManualCredentials(
            password: 'wrong',
            keyFilePath: null,
          ),
        );
        await _untilLast(states, (s) => s.failure != null);

        expect(states.last.failure, isA<InvalidCredentialsFailure>());

        unlockUseCase.error = Exception('boom');
        bloc.add(
          const UnlockWithManualCredentials(
            password: 'wrong-again',
            keyFilePath: null,
          ),
        );
        await _untilLast(
          states,
          (s) =>
              s.errorMessage ==
              'Unable to unlock database with provided credentials.',
        );

        expect(states.last.failure, isNull);
        expect(
          states.last.errorMessage,
          'Unable to unlock database with provided credentials.',
        );

        await sub.cancel();
      },
    );

    test('no fake progress: progress stays null through decrypting', () async {
      final states = <DatabaseUnlockState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(const InitializeDatabaseUnlock());
      await _untilLast(states, (s) => s.phase == UnlockPhase.ready);
      bloc.add(
        const UnlockWithManualCredentials(
          password: 'secret',
          keyFilePath: null,
        ),
      );
      await _untilLast(states, (s) => s.unlocked);

      expect(states.every((s) => s.progress == null), isTrue);

      await sub.cancel();
    });

    // spec-016: the system biometric prompt covers the app while it is up, so it
    // is the only place a user unlocking by fingerprint can be told that an
    // autofill save is waiting on them.
    group('unlock prompt wording', () {
      test('says why when an autofill capture is waiting', () async {
        biometric.available = true;
        final capturePendingBloc = DatabaseUnlockBloc(
          databasePath: '/tmp/vault.kdbx',
          biometricDataSource: biometric,
          databaseSessionCoordinator: coordinator,
          isAutofillCapturePending: () => true,
        );
        addTearDown(capturePendingBloc.close);

        capturePendingBloc.add(const RetryBiometricAuthentication());
        await _until(() => biometric.reasons.isNotEmpty);

        expect(
          biometric.reasons.single,
          'Authenticate to save the password you just submitted',
        );
      });

      test('keeps the generic wording otherwise', () async {
        biometric.available = true;

        bloc.add(const RetryBiometricAuthentication());
        await _until(() => biometric.reasons.isNotEmpty);

        expect(
          biometric.reasons.single,
          'Authenticate to unlock your password database',
        );
      });
    });
  });

  group('DatabaseUnlockState.copyWith', () {
    test('failure survives when clearError:true and failure is explicit', () {
      const state = DatabaseUnlockState(databasePath: '/tmp/vault.kdbx');
      const someFailure = InvalidCredentialsFailure();

      final result = state.copyWith(clearError: true, failure: someFailure);

      expect(result.failure, someFailure);
    });

    test('keyFilePath survives when clearKeyFilePath:true and keyFilePath is '
        'explicit', () {
      const state = DatabaseUnlockState(databasePath: '/tmp/vault.kdbx');

      final result = state.copyWith(clearKeyFilePath: true, keyFilePath: 'x');

      expect(result.keyFilePath, 'x');
    });
  });
}

/// Waits until [predicate] holds, yielding to the event loop between checks.
///
/// This file used to synchronise on `Future.delayed(20ms)` after every
/// `bloc.add`. A fixed sleep encodes an assumption about how fast the machine
/// is: when a handler needs longer than the sleep, the assertions run against a
/// half-finished state and the test fails for reasons unrelated to the
/// behaviour under test. That is not theoretical — injecting a 40 ms delay into
/// `_FakeBiometricDataSource.isBiometricAvailable` (a slow sensor, or simply a
/// loaded CI) failed 7 tests in this file. Waiting on the state itself is
/// correct at any speed, and the wait doubles as an assertion that the
/// transition really happened.
///
/// The deadline is not a speed budget — every wait here completes in
/// microseconds once the handler completes. It exists only so a genuine
/// deadlock reports a useful message instead of hanging until the suite-level
/// timeout.
Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the bloc to reach the expected state.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

/// [_until], applied to the most recent state the test has collected.
Future<void> _untilLast(
  List<DatabaseUnlockState> states,
  bool Function(DatabaseUnlockState state) predicate,
) => _until(() => states.isNotEmpty && predicate(states.last));

class _FakeBiometricDataSource implements BiometricDataSource {
  bool deviceAuthSupported = true;
  bool deviceCredentialResult = true;
  int deviceCredentialRequests = 0;

  @override
  Future<bool> isDeviceAuthSupported() async => deviceAuthSupported;

  @override
  Future<bool> authenticateWithDeviceCredential({
    required String reason,
  }) async {
    deviceCredentialRequests += 1;
    return deviceCredentialResult;
  }

  bool available = false;
  bool authenticateResult = true;
  final List<String> reasons = [];

  @override
  Future<bool> authenticate({required String reason}) async {
    reasons.add(reason);
    return authenticateResult;
  }

  @override
  Future<bool> isBiometricAvailable() async {
    return available;
  }
}
