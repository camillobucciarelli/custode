// spec-003: DatabaseSelectionScreen behaviour/copy/layout.
//
// `FilePicker.pickFiles`/`saveFile` hit real platform channels with no test
// handler, so flows that begin with a picker (Locate, Open existing,
// duplicate detection from a fresh selection) are exercised by dispatching
// the same typed BLoC event the screen's picker callback would dispatch
// after a successful pick — this tests the screen's *reaction* to that
// event (sheet auto-open, navigation, error copy) without fighting the
// picker plugin.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_transaction.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/core/widgets/kv_spinner.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_event.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/screens/create_database_screen.dart';
import 'package:password_manager/features/password_manager/presentation/screens/database_selection_screen.dart';
import 'package:password_manager/features/password_manager/presentation/screens/database_unlock_screen.dart';

import '../coordinators/fake_database_ports.dart';
import 'database_selection_unlock_test_utils.dart';

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

  tearDown(resetDatabaseTestDi);

  DatabaseRecord buildRecord({
    required String id,
    required String path,
    String? fileHash,
  }) {
    return DatabaseRecord(
      databaseId: id,
      canonicalPath: path,
      displayName: path.split('/').last,
      sourceType: DatabaseSourceType.local,
      fileHash: fileHash,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  group('Locate (FR-1)', () {
    testWidgets('hash match navigates to unlock and updates the record', (
      tester,
    ) async {
      const missingPath = '/tmp/missing.kdbx';
      const foundPath = '/tmp/found-on-disk.kdbx';
      final result = await pumpableSelectionScreen(
        records: [buildRecord(id: 'db-1', path: missingPath, fileHash: 'abc')],
      );
      result.harness.fileRepository.existingPaths.add(foundPath);
      result.harness.fileRepository.openExistingPathResult = (path) =>
          DatabaseImportResult(
            path: path,
            fileName: 'found-on-disk.kdbx',
            fileHash: 'abc',
            sourceType: DatabaseSourceType.local,
          );

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseSelectionBloc>()
          .add(
            const LocateMissingDatabase(
              databaseId: 'db-1',
              selectedPath: foundPath,
            ),
          );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DatabaseUnlockScreen), findsOneWidget);
      expect(
        result.harness.registryRepository.records.single.canonicalPath,
        foundPath,
      );
    });

    testWidgets('hash mismatch shows guidance and mutates nothing', (
      tester,
    ) async {
      const missingPath = '/tmp/missing.kdbx';
      const wrongPath = '/tmp/wrong-file.kdbx';
      final result = await pumpableSelectionScreen(
        records: [buildRecord(id: 'db-1', path: missingPath, fileHash: 'abc')],
      );
      result.harness.fileRepository.existingPaths.add(wrongPath);
      result.harness.fileRepository.openExistingPathResult = (path) =>
          DatabaseImportResult(
            path: path,
            fileName: 'wrong-file.kdbx',
            fileHash: 'different-hash',
            sourceType: DatabaseSourceType.local,
          );

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseSelectionBloc>()
          .add(
            const LocateMissingDatabase(
              databaseId: 'db-1',
              selectedPath: wrongPath,
            ),
          );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DatabaseUnlockScreen), findsNothing);
      expect(
        result.harness.registryRepository.records.single.canonicalPath,
        missingPath,
        reason: 'mismatch must leave the record unchanged',
      );
      expect(
        find.textContaining('does not match the missing database'),
        findsOneWidget,
      );
    });
  });

  group('Duplicate resolution (FR-4)', () {
    Future<({dynamic result, WidgetTester tester})> pumpDuplicatePrompt(
      WidgetTester tester,
    ) async {
      final result = await pumpableSelectionScreen(
        // A second, unrelated record prevents `checkInitialDatabase`'s
        // single-database auto-open from touching `db-existing` before the
        // test's own dispatch (auto-open would rewrite its fileHash via
        // `openExistingPath`, corrupting the dedup fixture).
        records: [
          buildRecord(
            id: 'db-existing',
            path: '/tmp/existing.kdbx',
            fileHash: 'dup-hash',
          ),
          buildRecord(
            id: 'db-other',
            path: '/tmp/other.kdbx',
            fileHash: 'unrelated',
          ),
        ],
      );
      result.harness.fileRepository.existingPaths.addAll([
        '/tmp/imported.kdbx',
        '/tmp/existing.kdbx',
        '/tmp/other.kdbx',
      ]);
      result.harness.fileRepository.stageResult = const StagedDatabaseImport(
        imported: DatabaseImportResult(
          path: '/tmp/imported.kdbx',
          fileName: 'imported.kdbx',
          fileHash: 'dup-hash',
          sourceType: DatabaseSourceType.local,
        ),
        preferredFileName: 'imported.kdbx',
      );

      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseSelectionBloc>()
          .add(
            const SelectExistingDatabase(
              fileName: 'imported.kdbx',
              selectedPath: '/tmp/imported.kdbx',
            ),
          );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('This database is already here'), findsOneWidget);

      return (result: result, tester: tester);
    }

    testWidgets('Keep both creates a second record', (tester) async {
      final ctx = await pumpDuplicatePrompt(tester);
      final result = ctx.result;

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 2 pre-existing fixture records + 1 new "kept both" record.
      expect(result.harness.registryRepository.records, hasLength(3));
    });

    testWidgets('Replace existing keeps records at the same count/id', (
      tester,
    ) async {
      final ctx = await pumpDuplicatePrompt(tester);
      final result = ctx.result;

      await tester.tap(find.text('Replace existing'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(result.harness.registryRepository.records, hasLength(2));
      expect(
        result.harness.registryRepository.records.map((r) => r.databaseId),
        contains('db-existing'),
      );
    });

    testWidgets('Use existing discards the staged import', (tester) async {
      final ctx = await pumpDuplicatePrompt(tester);
      final result = ctx.result;

      await tester.tap(find.text('Open the existing one'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(result.harness.registryRepository.records, hasLength(2));
      expect(result.harness.fileRepository.discarded, isNotEmpty);
    });

    testWidgets('Cancel discards the staged import and mutates nothing', (
      tester,
    ) async {
      final ctx = await pumpDuplicatePrompt(tester);
      final result = ctx.result;

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(result.harness.registryRepository.records, hasLength(2));
      expect(
        result.harness.registryRepository.records.map((r) => r.databaseId),
        contains('db-existing'),
      );
      expect(result.harness.fileRepository.discarded, isNotEmpty);
      expect(find.byType(DatabaseUnlockScreen), findsNothing);
    });
  });

  group('Open flow (spec 025)', () {
    testWidgets('welcome offers exactly two actions', (tester) async {
      final result = await pumpableSelectionScreen();
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(find.text('Create new database'), findsOneWidget);
      expect(find.text('Open a database'), findsOneWidget);
      expect(find.text('Open existing database'), findsNothing);
      expect(find.text('Open from Google Drive'), findsNothing);
      expect(
        find.text(
          'Custode keeps your passwords in a KeePass database. Keep it on '
          'this device or in your own cloud.',
        ),
        findsOneWidget,
      );
    });

    Future<void> pumpListAndOpenAddSheet(WidgetTester tester) async {
      final result = await pumpableSelectionScreen(
        records: [
          buildRecord(id: 'db-a', path: '/tmp/a.kdbx'),
          buildRecord(id: 'db-b', path: '/tmp/b.kdbx'),
        ],
        existingPaths: {'/tmp/a.kdbx', '/tmp/b.kdbx'},
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      // No inline add surface: the two actions live behind the "+".
      expect(find.text('Create new database'), findsNothing);
      expect(find.text('Open a database'), findsNothing);

      await tester.tap(find.byTooltip('Add database'));
      await tester.pumpAndSettle();
    }

    testWidgets('the list "+" opens the Add sheet with the same two actions', (
      tester,
    ) async {
      await pumpListAndOpenAddSheet(tester);

      expect(find.text('Add a database'), findsOneWidget);
      expect(find.text('Create new database'), findsOneWidget);
      expect(find.text('Start an empty vault'), findsOneWidget);
      expect(find.text('Open a database'), findsOneWidget);
      expect(find.text('From this device or Google Drive'), findsOneWidget);
      expect(find.text('Open existing database'), findsNothing);
      expect(find.text('Open from Google Drive'), findsNothing);
    });

    testWidgets('Add sheet: Create goes straight to the wizard', (
      tester,
    ) async {
      await pumpListAndOpenAddSheet(tester);

      await tester.tap(find.text('Create new database'));
      await tester.pumpAndSettle();

      expect(find.text('Add a database'), findsNothing);
      expect(find.byType(CreateDatabaseScreen), findsOneWidget);
      expect(find.text('Where is your database?'), findsNothing);
    });

    testWidgets('Add sheet: Open runs the single open path (Source sheet)', (
      tester,
    ) async {
      await pumpListAndOpenAddSheet(tester);

      await tester.tap(find.text('Open a database'));
      await tester.pumpAndSettle();

      expect(find.text('Add a database'), findsNothing);
      expect(find.text('Where is your database?'), findsOneWidget);
      expect(find.byType(CreateDatabaseScreen), findsNothing);
    });

    testWidgets('dismissing the Add sheet does nothing', (tester) async {
      await pumpListAndOpenAddSheet(tester);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Add a database'), findsNothing);
      expect(find.text('Databases'), findsOneWidget);
      expect(find.byType(CreateDatabaseScreen), findsNothing);
    });

    testWidgets('Open a database starts with the source sheet', (tester) async {
      final result = await pumpableSelectionScreen();
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open a database'));
      await tester.pumpAndSettle();

      expect(find.text('Where is your database?'), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('Google Drive'), findsOneWidget);
    });

    testWidgets('choosing a Drive file opens it and lands on Unlock with no '
        'snackbar', (tester) async {
      final sync = FakeDatabaseSyncRepository()
        ..remoteFiles = const [
          RemoteFile(
            providerId: 'google_drive',
            id: 'remote-1',
            name: 'Family.kdbx',
          ),
        ];
      final result = await pumpableSelectionScreen(syncRepository: sync);
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open a database'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Drive'));
      await tester.pumpAndSettle();
      expect(find.text('Open from Google Drive'), findsOneWidget);
      await tester.tap(find.text('Family.kdbx'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DatabaseUnlockScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(sync.mappings, hasLength(1));
    });

    testWidgets('the busy state is labelled and keeps the screen mounted', (
      tester,
    ) async {
      final download = Completer<Uint8List>();
      final sync = _HangingDownloadSyncRepository(download.future);
      final result = await pumpableSelectionScreen(syncRepository: sync);
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseSelectionBloc>()
          .add(
            const SelectDriveDatabase(
              remoteProviderId: 'google_drive',
              remoteFileId: 'remote-1',
              remoteFileName: 'Family.kdbx',
            ),
          );
      await tester.pump();
      await tester.pump();

      expect(find.text('Downloading from Google Drive…'), findsOneWidget);
      expect(find.byType(KvSpinner), findsOneWidget);
      // The welcome content is still in the tree under the overlay.
      expect(find.text('Create new database'), findsOneWidget);

      download.complete(Uint8List(0));
      await tester.pumpAndSettle();
      expect(find.byType(DatabaseUnlockScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('Databases list (spec 025 S4)', () {
    testWidgets('opening a database labels the busy state with its name, '
        'then lands on Unlock', (tester) async {
      final result = await pumpableSelectionScreen(
        records: [
          buildRecord(id: 'db-a', path: '/tmp/a.kdbx'),
          buildRecord(id: 'db-b', path: '/tmp/b.kdbx'),
        ],
        existingPaths: {'/tmp/a.kdbx', '/tmp/b.kdbx'},
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      final open = Completer<void>();
      result.harness.fileRepository.openExistingPathGate = open.future;

      await tester.tap(find.text('b.kdbx'));
      await tester.pump();

      expect(find.text('Opening b.kdbx…'), findsOneWidget);
      expect(find.byType(KvSpinner), findsOneWidget);
      expect(find.text('a.kdbx'), findsOneWidget, reason: 'list stays mounted');

      open.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DatabaseUnlockScreen), findsOneWidget);
      expect(find.byType(KvSpinner), findsNothing);
    });

    testWidgets('groups by sync mapping and heads the remote group with the '
        'connected account', (tester) async {
      final sync = FakeDatabaseSyncRepository()
        ..connected = true
        ..account = const StorageAccountSummary(
          displayLabel: 'mara@example.com',
          email: 'mara@example.com',
        )
        // A `local` record linked later from Sync is remote all the same.
        ..mappings['/tmp/b.kdbx'] = const DatabaseSyncMapping(
          databasePath: '/tmp/b.kdbx',
          providerId: 'google_drive',
          remoteFileId: 'remote-b',
          remoteFileName: 'b.kdbx',
        );
      final result = await pumpableSelectionScreen(
        records: [
          buildRecord(id: 'db-a', path: '/tmp/a.kdbx'),
          buildRecord(id: 'db-b', path: '/tmp/b.kdbx'),
        ],
        existingPaths: {'/tmp/a.kdbx', '/tmp/b.kdbx'},
        syncRepository: sync,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      final local = tester.getTopLeft(find.text('On this device')).dy;
      final remote = tester
          .getTopLeft(find.text('Google Drive · mara@example.com'))
          .dy;
      final a = tester.getTopLeft(find.text('a.kdbx')).dy;
      final b = tester.getTopLeft(find.text('b.kdbx')).dy;
      expect(local < a && a < remote && remote < b, isTrue);
      expect(sync.connectCalls, 0);
    });

    testWidgets('a missing row opens Unlock in its missing state', (
      tester,
    ) async {
      final result = await pumpableSelectionScreen(
        records: [
          buildRecord(id: 'db-a', path: '/tmp/a.kdbx'),
          buildRecord(id: 'db-gone', path: '/tmp/gone.kdbx'),
        ],
        existingPaths: {'/tmp/a.kdbx'},
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      expect(find.text('File not found'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Locate'), findsOneWidget);

      await tester.tap(find.text('gone.kdbx'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DatabaseUnlockScreen), findsOneWidget);
      expect(find.text("gone.kdbx can't be found"), findsOneWidget);
      expect(find.text('Locate file'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('Conflict sheet dismissal (spec 025 FR-O7)', () {
    Future<DatabaseTestHarness> pumpPrompt(
      WidgetTester tester, {
      String importedHash = 'dup-hash',
      String importedName = 'imported.kdbx',
      FakeDatabaseSyncRepository? syncRepository,
    }) async {
      final result = await pumpableSelectionScreen(
        syncRepository: syncRepository,
        records: [
          buildRecord(
            id: 'db-existing',
            path: '/tmp/existing.kdbx',
            fileHash: 'dup-hash',
          ).copyWith(displayName: 'Personal.kdbx'),
          buildRecord(
            id: 'db-other',
            path: '/tmp/other.kdbx',
            fileHash: 'unrelated',
          ),
        ],
        existingPaths: {'/tmp/existing.kdbx', '/tmp/other.kdbx'},
      );
      result.harness.fileRepository.existingPaths.add('/tmp/imported.kdbx');
      result.harness.fileRepository.stageResult = StagedDatabaseImport(
        imported: DatabaseImportResult(
          path: '/tmp/imported.kdbx',
          fileName: importedName,
          fileHash: importedHash,
          sourceType: DatabaseSourceType.local,
        ),
        preferredFileName: importedName,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseSelectionBloc>()
          .add(
            SelectExistingDatabase(
              fileName: importedName,
              selectedPath: '/tmp/imported.kdbx',
            ),
          );
      await tester.pumpAndSettle();
      expect(find.text('This database is already here'), findsOneWidget);
      return result.harness;
    }

    testWidgets('a barrier tap cancels and discards the staged import', (
      tester,
    ) async {
      final harness = await pumpPrompt(tester);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('This database is already here'), findsNothing);
      expect(harness.fileRepository.discarded, hasLength(1));
      expect(harness.registryRepository.records, hasLength(2));
      expect(find.byType(DatabaseUnlockScreen), findsNothing);
    });

    testWidgets('system back cancels and discards the staged import', (
      tester,
    ) async {
      final harness = await pumpPrompt(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('This database is already here'), findsNothing);
      expect(harness.fileRepository.discarded, hasLength(1));
      expect(harness.registryRepository.records, hasLength(2));
    });

    testWidgets('a hash match recommends opening the existing one', (
      tester,
    ) async {
      await pumpPrompt(tester);

      expect(find.text('Recommended'), findsOneWidget);
      expect(find.text('Personal.kdbx (This device)'), findsOneWidget);
    });

    testWidgets('the existing database is remote when it has a sync mapping, '
        'whatever its source type', (tester) async {
      final sync = FakeDatabaseSyncRepository()
        ..mappings['/tmp/existing.kdbx'] = const DatabaseSyncMapping(
          databasePath: '/tmp/existing.kdbx',
          providerId: 'google_drive',
          remoteFileId: 'remote-existing',
          remoteFileName: 'Personal.kdbx',
        );
      await pumpPrompt(tester, syncRepository: sync);

      expect(find.text('Personal.kdbx (Google Drive)'), findsOneWidget);
      expect(find.text('imported.kdbx (This device)'), findsOneWidget);
    });

    testWidgets('a name-only match shows no recommendation', (tester) async {
      await pumpPrompt(
        tester,
        importedHash: 'other-content',
        importedName: 'Personal.kdbx',
      );

      expect(find.text('Recommended'), findsNothing);
      expect(find.text('Open the existing one'), findsOneWidget);
      expect(find.text('Keep both'), findsOneWidget);
      expect(find.text('Replace existing'), findsOneWidget);
    });

    testWidgets('F6: a name-only match on a remote-linked database offers '
        'Open existing, Keep both and Cancel, not Replace', (tester) async {
      final sync = FakeDatabaseSyncRepository()
        ..mappings['/tmp/existing.kdbx'] = const DatabaseSyncMapping(
          databasePath: '/tmp/existing.kdbx',
          providerId: 'google_drive',
          remoteFileId: 'remote-existing',
          remoteFileName: 'Personal.kdbx',
        );
      await pumpPrompt(
        tester,
        syncRepository: sync,
        importedHash: 'other-content',
        importedName: 'Personal.kdbx',
      );

      expect(find.text('Replace existing'), findsNothing);
      expect(find.text('Open the existing one'), findsOneWidget);
      expect(find.text('Keep both'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });
  });

  group('Create flow (FR-2)', () {
    testWidgets('tapping Create new database pushes CreateDatabaseScreen', (
      tester,
    ) async {
      final result = await pumpableSelectionScreen();
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create new database'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(CreateDatabaseScreen), findsOneWidget);
    });

    /// Drives the real wizard and coordinator through [fill] on step 2 and
    /// returns the harness once creation has finished. Only the KDBX build
    /// is faked (`FakeCreateDatabaseUseCase`): it runs off the test clock.
    Future<DatabaseTestHarness> createVault(
      WidgetTester tester,
      Future<void> Function() fill, {
      FakeDatabaseSyncRepository? syncRepository,
      Future<void> Function()? onStep1,
    }) async {
      final result = await pumpableSelectionScreen(
        syncRepository: syncRepository,
        fakeCreate: true,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create new database'));
      await tester.pumpAndSettle();
      await onStep1?.call();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await fill();
      await tester.tap(find.text('Create database'));
      await tester.pumpAndSettle();
      return result.harness;
    }

    Future<void> typePassword(WidgetTester tester) async {
      await tester.enterText(find.byType(TextFormField).at(0), 'pw-for-test');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(1), 'pw-for-test');
      await tester.pumpAndSettle();
    }

    Future<void> generateKey(WidgetTester tester) async {
      await tester.tap(find.text('Add a key file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate a new key file'));
      await tester.pumpAndSettle();
    }

    void expectLandedInVault(WidgetTester tester) {
      expect(tester.takeException(), isNull);
      expect(find.text('vault:/tmp/created.kdbx'), findsOneWidget);
      expect(find.byType(DatabaseUnlockScreen), findsNothing);
      expect(find.byType(CreateDatabaseScreen), findsNothing);
      expect(find.byType(DatabaseSelectionScreen), findsNothing);
    }

    testWidgets('password only lands in the vault, one navigation', (
      tester,
    ) async {
      final harness = await createVault(tester, () => typePassword(tester));

      expectLandedInVault(tester);
      expect(harness.coordinator.sessionSecretHolder.read(), 'pw-for-test');
    });

    testWidgets('key file only lands in the vault with the empty password', (
      tester,
    ) async {
      final harness = await createVault(tester, () => generateKey(tester));

      expectLandedInVault(tester);
      expect(harness.coordinator.sessionSecretHolder.read(), '');
      final profile = harness.securityRepository.profiles.values.single;
      expect(profile.keyFilePath, isNotNull);
    });

    testWidgets('password and key file land in the vault', (tester) async {
      final harness = await createVault(tester, () async {
        await typePassword(tester);
        await generateKey(tester);
      });

      expectLandedInVault(tester);
      expect(harness.coordinator.sessionSecretHolder.read(), 'pw-for-test');
      expect(
        harness.securityRepository.profiles.values.single.keyFilePath,
        isNotNull,
      );
    });

    testWidgets('a Drive upload failure still lands in the vault with the '
        'notice to link it from Sync', (tester) async {
      final sync = _FailingLinkSyncRepository()..connected = true;
      await createVault(
        tester,
        () => typePassword(tester),
        syncRepository: sync,
        onStep1: () async {
          await tester.tap(find.text('Google Drive'));
          await tester.pumpAndSettle();
        },
      );

      expectLandedInVault(tester);
      expect(
        find.text(remoteCreateFailedNotice),
        findsOneWidget,
        reason: 'the single notice shows over the vault',
      );
    });

    testWidgets('success without a usable session secret goes through '
        'Unlock, not the vault', (tester) async {
      final result = await pumpableSelectionScreen(
        records: [buildRecord(id: 'db-1', path: '/tmp/a.kdbx')],
        existingPaths: {'/tmp/a.kdbx'},
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      await tester.tap(find.text('a.kdbx'));
      await tester.pumpAndSettle();

      expect(find.byType(DatabaseUnlockScreen), findsOneWidget);
      expect(find.textContaining('vault:'), findsNothing);
    });
  });
}

class _FailingLinkSyncRepository extends FakeDatabaseSyncRepository {
  @override
  Future<DatabaseSyncMapping> linkDatabaseToRemote({
    required String databasePath,
    String? remoteFileId,
    String? remoteFileName,
  }) async => throw Exception('upload failed');
}

class _HangingDownloadSyncRepository extends FakeDatabaseSyncRepository {
  _HangingDownloadSyncRepository(this._download);

  final Future<Uint8List> _download;

  @override
  Future<Uint8List> downloadRemoteFile(
    String fileId, {
    required String providerId,
  }) => _download;
}
