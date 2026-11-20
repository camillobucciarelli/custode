import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/create_database_step.dart';
import 'package:password_manager/features/password_manager/domain/models/database_dedup_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_transaction.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/get_active_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/resolve_database_duplicate_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/unlock_database_usecase.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_event.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_state.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';

import '../coordinators/fake_database_ports.dart';

void main() {
  group('DatabaseSelectionBloc', () {
    late FakeDatabaseFileRepository fileRepository;
    late FakeDatabaseSessionRepository sessionRepository;
    late FakeDatabaseRegistryRepository registryRepository;
    late FakeDatabaseSecurityRepository securityRepository;
    late FakeDatabaseSyncRepository syncRepository;
    late DatabaseSessionCoordinator coordinator;
    late DatabaseSelectionBloc bloc;

    setUp(() {
      fileRepository = FakeDatabaseFileRepository();
      sessionRepository = FakeDatabaseSessionRepository();
      registryRepository = FakeDatabaseRegistryRepository();
      securityRepository = FakeDatabaseSecurityRepository();
      syncRepository = FakeDatabaseSyncRepository();
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
          syncRepository,
        ),
        unlockDatabaseUseCase: UnlockDatabaseUseCase(),
        createDatabaseUseCase: CreateDatabaseUseCase(
          databaseFileRepository: fileRepository,
        ),
      );
      bloc = DatabaseSelectionBloc(databaseSessionCoordinator: coordinator);
    });

    tearDown(() async {
      await bloc.close();
    });

    test('carries the remote account with the list, across a busy state '
        '(spec 025 FR-L2)', () async {
      const account = StorageAccountSummary(
        displayLabel: 'mara@example.com',
        email: 'mara@example.com',
      );
      DatabaseRecord record(String id) => DatabaseRecord(
        databaseId: id,
        canonicalPath: '/tmp/$id.kdbx',
        displayName: '$id.kdbx',
        sourceType: DatabaseSourceType.local,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      registryRepository.records = [record('a'), record('b')];
      fileRepository.existingPaths.addAll(['/tmp/a.kdbx', '/tmp/b.kdbx']);
      syncRepository
        ..connected = true
        ..account = account
        ..mappings['/tmp/a.kdbx'] = const DatabaseSyncMapping(
          databasePath: '/tmp/a.kdbx',
          providerId: 'google_drive',
          remoteFileId: 'remote-1',
          remoteFileName: 'a.kdbx',
        );

      final states = <DatabaseSelectionState>[];
      final sub = bloc.stream.listen(states.add);
      bloc.add(CheckInitialDatabase());
      await bloc.stream.firstWhere((s) => s is DatabaseSelectionUnselected);
      bloc.add(const OpenRecentDatabase('/tmp/b.kdbx'));
      await bloc.stream.firstWhere((s) => s is DatabaseSelectionSuccess);
      await sub.cancel();

      expect(states, hasLength(3));
      expect(states[1], isA<DatabaseSelectionLoading>());
      expect(states.map((s) => s.remoteAccount), everyElement(account));
      expect(
        states.first.items.map((item) => item.remoteProviderId),
        unorderedEquals(['google_drive', null]),
      );
    });

    test(
      'emits duplicate decision required then success after resolution',
      () async {
        fileRepository.existingPaths.addAll([
          '/tmp/imported.kdbx',
          '/tmp/existing.kdbx',
        ]);
        fileRepository.stageResult = const StagedDatabaseImport(
          imported: DatabaseImportResult(
            path: '/tmp/imported.kdbx',
            fileName: 'imported.kdbx',
            fileHash: 'abc123',
            sourceType: DatabaseSourceType.local,
          ),
          preferredFileName: 'imported.kdbx',
        );
        registryRepository.records = [
          DatabaseRecord(
            databaseId: 'db-existing',
            canonicalPath: '/tmp/existing.kdbx',
            displayName: 'existing.kdbx',
            sourceType: DatabaseSourceType.local,
            fileHash: 'abc123',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        ];

        final states = <DatabaseSelectionState>[];
        final sub = bloc.stream.listen(states.add);

        bloc.add(
          const SelectExistingDatabase(
            fileName: 'imported.kdbx',
            selectedPath: '/tmp/imported.kdbx',
          ),
        );
        await _until(
          () => states
              .whereType<DatabaseSelectionDuplicateDecisionRequired>()
              .isNotEmpty,
        );

        expect(states.any((s) => s is DatabaseSelectionLoading), isTrue);
        expect(
          states.whereType<DatabaseSelectionDuplicateDecisionRequired>().length,
          1,
        );

        bloc.add(
          const ResolveDuplicateDecision(DatabaseDuplicateResolution.keepBoth),
        );
        await _until(
          () => states.whereType<DatabaseSelectionSuccess>().isNotEmpty,
        );

        expect(states.whereType<DatabaseSelectionSuccess>().length, 1);
        expect(registryRepository.records, hasLength(2));

        await sub.cancel();
      },
    );

    test('emits success for initial active database', () async {
      fileRepository.existingPaths.addAll(['/tmp/a.kdbx', '/tmp/b.kdbx']);
      registryRepository.records = [
        DatabaseRecord(
          databaseId: 'db-a',
          canonicalPath: '/tmp/a.kdbx',
          displayName: 'a.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          lastOpenedAt: DateTime(2026, 1),
        ),
        DatabaseRecord(
          databaseId: 'db-b',
          canonicalPath: '/tmp/b.kdbx',
          displayName: 'b.kdbx',
          sourceType: DatabaseSourceType.local,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          lastOpenedAt: DateTime(2026, 2),
        ),
      ];
      registryRepository.activeId = 'db-b';

      final states = <DatabaseSelectionState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(CheckInitialDatabase());
      await _until(
        () => states.whereType<DatabaseSelectionSuccess>().isNotEmpty,
      );

      // Spec 025 FR-X6: the first load stays `Initial`, no Loading flash.
      expect(states.any((s) => s is DatabaseSelectionLoading), isFalse);
      final success = states.whereType<DatabaseSelectionSuccess>().single;
      expect(success.path, '/tmp/b.kdbx');
      expect(
        success.items.map((item) => item.canonicalPath),
        containsAll(['/tmp/a.kdbx', '/tmp/b.kdbx']),
      );

      await sub.cancel();
    });

    group('busy labels (spec 025 FR-X6)', () {
      DatabaseRecord record(String id, String name) => DatabaseRecord(
        databaseId: id,
        canonicalPath: '/tmp/$name',
        displayName: name,
        sourceType: DatabaseSourceType.local,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        lastOpenedAt: DateTime(2026, 1),
      );

      Future<List<DatabaseSelectionLoading>> loadingStatesAfter(
        DatabaseSelectionEvent event,
      ) async {
        final states = <DatabaseSelectionState>[];
        final sub = bloc.stream.listen(states.add);
        bloc.add(event);
        await _until(
          () =>
              states.isNotEmpty &&
              states.last is! DatabaseSelectionLoading &&
              states.any((s) => s is DatabaseSelectionLoading),
        );
        await sub.cancel();
        return states.whereType<DatabaseSelectionLoading>().toList();
      }

      test('opening a local file is labelled with its name', () async {
        final loading = await loadingStatesAfter(
          const SelectExistingDatabase(
            fileName: 'Family.kdbx',
            selectedPath: '/tmp/Family.kdbx',
          ),
        );
        expect(loading.first.label, 'Opening Family.kdbx…');
      });

      test('a Drive download is labelled', () async {
        final loading = await loadingStatesAfter(
          const SelectDriveDatabase(
            remoteProviderId: 'google_drive',
            remoteFileId: 'remote-1',
            remoteFileName: 'Family.kdbx',
          ),
        );
        expect(loading.first.label, 'Downloading from Google Drive…');
      });

      test('opening and removing a listed database name it', () async {
        fileRepository.existingPaths.addAll(['/tmp/a.kdbx', '/tmp/b.kdbx']);
        registryRepository.records = [
          record('db-a', 'a.kdbx'),
          record('db-b', 'b.kdbx'),
        ];
        bloc.add(CheckInitialDatabase());
        await _until(() => bloc.state.items.isNotEmpty);

        final opening = await loadingStatesAfter(
          const OpenRecentDatabase('/tmp/a.kdbx'),
        );
        expect(opening.first.label, 'Opening a.kdbx…');
        expect(opening.first.items, isNotEmpty);

        final removing = await loadingStatesAfter(
          const RemoveRecentDatabase(
            path: '/tmp/b.kdbx',
            mode: RecentDatabaseRemovalMode.removeOnly,
          ),
        );
        expect(removing.first.label, 'Removing b.kdbx…');
      });
    });

    test('CreateDatabaseStep wizard advances only with valid facts and never '
        'carries a password in state.toString()', () async {
      final states = <DatabaseSelectionState>[];
      final sub = bloc.stream.listen(states.add);

      List<DatabaseSelectionCreateStep> stepStates() =>
          states.whereType<DatabaseSelectionCreateStep>().toList();

      bloc.add(const StartCreateDatabaseFlow());
      bloc.add(const AdvanceCreateDatabaseStep(fieldsNonEmpty: false));
      await _until(() => stepStates().isNotEmpty);

      final steps = stepStates();
      expect(steps.first.step, CreateDatabaseStep.nameAndStorage);
      // Empty fields must not advance the step.
      expect(steps.last.step, CreateDatabaseStep.nameAndStorage);

      bloc.add(const AdvanceCreateDatabaseStep(fieldsNonEmpty: true));
      await _until(
        () => stepStates().last.step == CreateDatabaseStep.credentials,
      );
      expect(stepStates().last.step, CreateDatabaseStep.credentials);
      // The assertion above samples once `masterPassword` is reached, so the
      // empty-fields event is now provably behind us (bloc events are FIFO).
      // Every step state emitted before it must still have been
      // `nameAndStorage` — this catches an advance-on-empty-fields
      // regression even if the earlier check sampled before that emission.
      expect(
        stepStates()
            .takeWhile((s) => s.step != CreateDatabaseStep.credentials)
            .every((s) => s.step == CreateDatabaseStep.nameAndStorage),
        isTrue,
        reason: 'empty fields must never advance the wizard',
      );

      bloc.add(const GoBackCreateDatabaseStep());
      await _until(
        () => stepStates().last.step == CreateDatabaseStep.nameAndStorage,
      );
      expect(stepStates().last.step, CreateDatabaseStep.nameAndStorage);

      for (final state in states) {
        expect(state.toString(), isNot(contains('super-secret-password')));
      }

      await sub.cancel();
    });
  });
}

/// Waits until [predicate] holds, yielding to the event loop between checks.
///
/// Replaces the `Future.delayed(20ms)` sleeps this file used to synchronise on
/// after every `bloc.add`. A fixed sleep is a bet on machine speed: when a
/// handler takes longer than the sleep, the assertions run against a
/// half-finished state and fail for reasons unrelated to the behaviour under
/// test. Waiting on the state itself is correct at any speed, and the wait
/// doubles as an assertion that the transition actually happened.
///
/// The deadline is not a speed budget — these waits complete in microseconds
/// once the handler completes. It exists only so a genuine deadlock reports a
/// useful message instead of hanging until the suite-level timeout.
Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the bloc to reach the expected state.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
