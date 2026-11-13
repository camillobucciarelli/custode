// spec-003: DatabaseSelectionScreen behaviour/copy/layout.
//
// `FilePicker.pickFiles`/`saveFile` hit real platform channels with no test
// handler, so flows that begin with a picker (Locate, Open existing,
// duplicate detection from a fresh selection) are exercised by dispatching
// the same typed BLoC event the screen's picker callback would dispatch
// after a successful pick — this tests the screen's *reaction* to that
// event (sheet auto-open, navigation, error copy) without fighting the
// picker plugin.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_result.dart';
import 'package:password_manager/features/password_manager/domain/models/database_import_transaction.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_event.dart';
import 'package:password_manager/features/password_manager/presentation/screens/create_database_screen.dart';
import 'package:password_manager/features/password_manager/presentation/screens/database_unlock_screen.dart';

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
      expect(find.text('Duplicate database detected'), findsOneWidget);

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

      await tester.tap(find.text('Use existing'));
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
  });
}
