// Spec 025 FR-L2: grouping by sync provider, order inside a group, header
// with and without an account, search.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/database_selection_item.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_grouped_list.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_item_tile.dart';

DatabaseSelectionItem _item(String name, {bool remote = false}) =>
    DatabaseSelectionItem(
      databaseId: name,
      canonicalPath: '/vault/$name.kdbx',
      displayName: name,
      // Deliberately `local` everywhere: grouping follows the mapping.
      sourceType: DatabaseSourceType.local,
      remoteProviderId: remote ? 'google_drive' : null,
    );

Future<void> _pump(
  WidgetTester tester,
  List<DatabaseSelectionItem> items, {
  StorageAccountSummary? account,
}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.lightTheme,
    home: Scaffold(
      body: SingleChildScrollView(
        child: DatabaseGroupedList(
          items: items,
          remoteAccount: account,
          onOpen: (_) async {},
          onExport: (_) async {},
          onRemove: (_) async {},
          onLocate: (_) async {},
        ),
      ),
    ),
  ),
);

List<String> _tileNames(WidgetTester tester) => tester
    .widgetList<DatabaseItemTile>(find.byType(DatabaseItemTile))
    .map((tile) => tile.item.displayName)
    .toList();

void main() {
  testWidgets('local group first, then the provider group, each keeping the '
      'incoming (most recently opened) order', (tester) async {
    await _pump(
      tester,
      [
        _item('Personal', remote: true),
        _item('Work'),
        _item('Family', remote: true),
        _item('Archive'),
      ],
      account: const StorageAccountSummary(
        displayLabel: 'mara@example.com',
        email: 'mara@example.com',
      ),
    );

    expect(_tileNames(tester), ['Work', 'Archive', 'Personal', 'Family']);
    final local = tester.getTopLeft(find.text('On this device')).dy;
    final remote = tester
        .getTopLeft(find.text('Google Drive · mara@example.com'))
        .dy;
    expect(local, lessThan(tester.getTopLeft(find.text('Work')).dy));
    expect(tester.getTopLeft(find.text('Archive')).dy, lessThan(remote));
    expect(remote, lessThan(tester.getTopLeft(find.text('Personal')).dy));
  });

  testWidgets('without an account the remote header is the bare label', (
    tester,
  ) async {
    await _pump(tester, [_item('Personal', remote: true)]);

    expect(find.text('Google Drive'), findsOneWidget);
    // No empty local group.
    expect(find.text('On this device'), findsNothing);
  });

  testWidgets('group headers are semantic headers', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, [_item('Work'), _item('Personal', remote: true)]);

    for (final label in ['On this device', 'Google Drive']) {
      expect(
        tester.getSemantics(find.text(label)),
        matchesSemantics(label: label, isHeader: true),
      );
    }
    handle.dispose();
  });

  testWidgets('search appears above five databases and filters every group', (
    tester,
  ) async {
    await _pump(tester, [_item('Only')]);
    expect(find.byType(TextField), findsNothing);

    await _pump(tester, [
      for (final name in ['Alpha', 'Beta', 'Gamma', 'Delta']) _item(name),
      _item('Alpine', remote: true),
      _item('Omega', remote: true),
    ]);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'alp');
    await tester.pump();
    expect(_tileNames(tester), ['Alpha', 'Alpine']);
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'omeg');
    await tester.pump();
    expect(_tileNames(tester), ['Omega']);
    expect(find.text('On this device'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.byType(DatabaseItemTile), findsNothing);
    expect(find.text('No database matches your search.'), findsOneWidget);
  });
}
