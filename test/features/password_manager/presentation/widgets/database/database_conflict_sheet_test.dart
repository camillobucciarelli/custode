import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/features/password_manager/domain/models/database_dedup_result.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_conflict_sheet.dart';

import '../../screens/database_selection_unlock_test_utils.dart';

void main() {
  Future<List<DatabaseDuplicateResolution?>> open(
    WidgetTester tester, {
    bool recommendExisting = true,
    bool importedRemote = true,
    bool allowReplace = true,
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    final results = <DatabaseDuplicateResolution?>[];
    await tester.pumpWidget(
      pumpableSheetHost(
        themeMode: themeMode,
        onOpen: (context) async => results.add(
          await showDatabaseConflictSheet(
            context,
            importedName: 'Personal.kdbx',
            importedRemote: importedRemote,
            existingName: 'Personal.kdbx',
            existingRemote: false,
            recommendExisting: recommendExisting,
            allowReplace: allowReplace,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('names both files with their sources and the four options', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('This database is already here'), findsOneWidget);
    expect(find.text('Importing'), findsOneWidget);
    expect(find.text('Existing'), findsOneWidget);
    expect(find.text('Personal.kdbx (Google Drive)'), findsOneWidget);
    expect(find.text('Personal.kdbx (This device)'), findsOneWidget);
    expect(find.text('Open the existing one'), findsOneWidget);
    expect(find.text('Nothing is imported or changed.'), findsOneWidget);
    expect(find.text('Keep both'), findsOneWidget);
    expect(find.text('Add this file as a separate database.'), findsOneWidget);
    expect(find.text('Replace existing'), findsOneWidget);
    expect(
      find.text('Custode backs up the existing file first.'),
      findsOneWidget,
    );
    expect(find.text('Cancel'), findsOneWidget);
  });

  for (final entry in {
    'Open the existing one': DatabaseDuplicateResolution.useExisting,
    'Keep both': DatabaseDuplicateResolution.keepBoth,
    'Replace existing': DatabaseDuplicateResolution.replaceExisting,
    'Cancel': DatabaseDuplicateResolution.cancel,
  }.entries) {
    testWidgets('${entry.key} resolves to ${entry.value.name}', (tester) async {
      final results = await open(tester);

      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();

      expect(results, [entry.value]);
    });
  }

  testWidgets('barrier dismissal returns null so callers cancel', (
    tester,
  ) async {
    final results = await open(tester);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(results, [null]);
  });

  testWidgets('a source or hash match recommends the existing one', (
    tester,
  ) async {
    await open(tester, recommendExisting: true);

    expect(find.text('Recommended'), findsOneWidget);
  });

  testWidgets('a name-only match carries no recommendation', (tester) async {
    await open(tester, recommendExisting: false);

    expect(find.text('Recommended'), findsNothing);
  });

  testWidgets('F6: Replace existing is not offered when it is not allowed; '
      'the other three stay', (tester) async {
    await open(tester, recommendExisting: false, allowReplace: false);

    expect(find.text('Replace existing'), findsNothing);
    expect(find.text('Open the existing one'), findsOneWidget);
    expect(find.text('Keep both'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('the title is a heading', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    expect(
      tester.getSemantics(find.text('This database is already here')),
      isSemantics(isHeader: true),
    );
    handle.dispose();
  });

  testWidgets('a local import is labelled This device', (tester) async {
    await open(tester, importedRemote: false);

    expect(find.text('Personal.kdbx (This device)'), findsNWidgets(2));
  });

  testWidgets('dark theme builds the same sheet without errors', (
    tester,
  ) async {
    await open(tester, themeMode: ThemeMode.dark);

    expect(tester.takeException(), isNull);
    expect(find.text('Recommended'), findsOneWidget);
  });
}
