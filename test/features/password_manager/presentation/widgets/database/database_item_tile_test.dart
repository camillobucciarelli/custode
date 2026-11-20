// Spec 025 FR-L3/FR-L4: status line, credential tags, missing row. Also PR
// #188 review: the hover surface replaced InkWell, so keyboard activation must
// be wired explicitly: a focused tile activates with Enter and Space.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/widgets/kv_tag.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/database_selection_item.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_item_tile.dart';

DatabaseSelectionItem _item({
  bool biometrics = false,
  bool keyFile = false,
  bool missing = false,
  bool active = false,
  String? remoteProviderId,
  DateTime? lastSyncAt,
  String? lastSyncError,
}) => DatabaseSelectionItem(
  databaseId: 'db-1',
  canonicalPath: '/vault/db.kdbx',
  displayName: 'Personal',
  sourceType: DatabaseSourceType.local,
  biometricProtectionEnabled: biometrics,
  keyFileConfigured: keyFile,
  isMissing: missing,
  isActive: active,
  remoteProviderId: remoteProviderId,
  lastSyncAt: lastSyncAt,
  lastSyncError: lastSyncError,
);

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.lightTheme,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  Future<({int Function() opened, int Function() located})> pumpTile(
    WidgetTester tester,
    DatabaseSelectionItem item, {
    double? width,
  }) async {
    var opened = 0;
    var located = 0;
    final tile = DatabaseItemTile(
      item: item,
      onOpen: () async => opened++,
      onExport: () async {},
      onRemove: () async {},
      onLocate: item.isMissing ? () async => located++ : null,
    );
    await tester.pumpWidget(
      _app(width == null ? tile : SizedBox(width: width, child: tile)),
    );
    return (opened: () => opened, located: () => located);
  }

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('a focused tile activates with ${key.keyLabel}', (
      tester,
    ) async {
      final counts = await pumpTile(tester, _item());

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.hasFocus,
        isTrue,
        reason: 'tab moves focus onto the tile',
      );

      await tester.sendKeyEvent(key);
      await tester.pump();

      expect(counts.opened(), 1);
    });
  }

  testWidgets('tap still activates', (tester) async {
    final counts = await pumpTile(tester, _item());
    await tester.tap(find.text('Personal'));
    expect(counts.opened(), 1);
  });

  group('status line (FR-L3)', () {
    final now = DateTime(2026, 3, 12, 12);

    test('nothing for a database that is only on this device', () {
      expect(
        databaseStatusLine(_item(lastSyncAt: DateTime(2026, 3, 12)), now: now),
        isNull,
      );
    });

    test('Synced <relative> for a remote database', () {
      expect(
        databaseStatusLine(
          _item(
            remoteProviderId: 'google_drive',
            lastSyncAt: DateTime(2026, 3, 12, 11, 58),
          ),
          now: now,
        ),
        'Synced today',
      );
      expect(
        databaseStatusLine(
          _item(
            remoteProviderId: 'google_drive',
            lastSyncAt: DateTime(2026, 3, 9, 12),
          ),
          now: now,
        ),
        'Synced 3 days ago',
      );
    });

    test('the existing sync error wins over the last sync time', () {
      expect(
        databaseStatusLine(
          _item(
            remoteProviderId: 'google_drive',
            lastSyncAt: DateTime(2026, 3, 12),
            lastSyncError: 'Reconnect Google Drive',
          ),
          now: now,
        ),
        'Reconnect Google Drive',
      );
    });

    test('nothing while a linked database has never synced', () {
      expect(
        databaseStatusLine(_item(remoteProviderId: 'google_drive'), now: now),
        isNull,
      );
    });
  });

  testWidgets('credential tags come from the item flags', (tester) async {
    await pumpTile(tester, _item());
    expect(find.byType(KvTag), findsNothing);

    await pumpTile(tester, _item(biometrics: true, keyFile: true));
    expect(find.widgetWithText(KvTag, 'Biometrics'), findsOneWidget);
    expect(find.widgetWithText(KvTag, 'Key file'), findsOneWidget);
    // The retired subtitles are gone: the group header says where it lives.
    expect(find.textContaining('On this device'), findsNothing);
    expect(find.textContaining('biometrics on'), findsNothing);
  });

  testWidgets('the menu is labelled with the database name and is 44 px', (
    tester,
  ) async {
    await pumpTile(tester, _item());
    final menu = find.byTooltip('More actions for Personal');
    expect(menu, findsOneWidget);
    expect(tester.getSize(menu).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(menu).height, greaterThanOrEqualTo(44));
  });

  testWidgets('a missing row says File not found, offers Locate, and a tap '
      'on the row still opens it', (tester) async {
    final counts = await pumpTile(
      tester,
      _item(missing: true, biometrics: true, keyFile: true),
    );

    expect(find.text('File not found'), findsOneWidget);
    expect(find.byType(KvTag), findsNothing);
    final locate = find.widgetWithText(TextButton, 'Locate');
    expect(tester.getSize(locate).height, greaterThanOrEqualTo(44));

    await tester.tap(locate);
    expect(counts.located(), 1);
    expect(counts.opened(), 0);

    await tester.tap(find.text('Personal'));
    expect(counts.opened(), 1, reason: 'Unlock owns the repair state');
    expect(counts.located(), 1);
  });

  testWidgets('status and two tags wrap on a narrow row without overflow', (
    tester,
  ) async {
    await pumpTile(
      tester,
      _item(
        remoteProviderId: 'google_drive',
        lastSyncError: 'Google Drive needs you to sign in again',
        biometrics: true,
        keyFile: true,
        active: true,
      ),
      width: 320,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Biometrics'), findsOneWidget);
    expect(find.text('Key file'), findsOneWidget);
  });
}
