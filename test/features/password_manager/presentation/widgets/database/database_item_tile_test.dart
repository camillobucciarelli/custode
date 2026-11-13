// PR #188 review: the hover surface replaced InkWell, so keyboard activation
// must be wired explicitly — a focused tile activates with Enter and Space.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/models/database_selection_item.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_item_tile.dart';

DatabaseSelectionItem _item() => const DatabaseSelectionItem(
  databaseId: 'db-1',
  canonicalPath: '/vault/db.kdbx',
  displayName: 'Personal',
  sourceType: DatabaseSourceType.local,
);

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.lightTheme,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('a focused tile activates with ${key.keyLabel}', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        _app(
          DatabaseItemTile(
            item: _item(),
            onOpen: () async => opened++,
            onExport: () async {},
            onRemove: () async {},
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.hasFocus,
        isTrue,
        reason: 'tab moves focus onto the tile',
      );

      await tester.sendKeyEvent(key);
      await tester.pump();

      expect(opened, 1);
    });
  }

  testWidgets('tap still activates', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _app(
        DatabaseItemTile(
          item: _item(),
          onOpen: () async => opened++,
          onExport: () async {},
          onRemove: () async {},
        ),
      ),
    );
    await tester.tap(find.text('Personal'));
    expect(opened, 1);
  });
}
