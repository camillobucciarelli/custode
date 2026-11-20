import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/theme/app_glyph.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/source_chip.dart';

void main() {
  group('databaseSourceLabel', () {
    test('local is This device even when an account is known', () {
      expect(databaseSourceLabel(remote: false), 'This device');
      expect(
        databaseSourceLabel(
          remote: false,
          account: const StorageAccountSummary(
            displayLabel: 'a',
            email: 'a@b.c',
          ),
        ),
        'This device',
      );
    });

    test('remote with email appends it', () {
      expect(
        databaseSourceLabel(
          remote: true,
          account: const StorageAccountSummary(
            displayLabel: 'mara@example.com',
            email: 'mara@example.com',
          ),
        ),
        'Google Drive · mara@example.com',
      );
    });

    test('remote without email or account is the bare provider name', () {
      expect(databaseSourceLabel(remote: true), 'Google Drive');
      expect(
        databaseSourceLabel(
          remote: true,
          account: const StorageAccountSummary(
            displayLabel: 'Google Drive account',
          ),
        ),
        'Google Drive',
      );
    });
  });

  test(
    'F9g: This device has a device-neutral glyph, not a desktop monitor',
    () {
      expect(databaseSourceGlyph(remote: false), AppGlyph.folder);
      expect(databaseSourceGlyph(remote: true), AppGlyph.cloud);
    },
  );

  testWidgets('SourceChip renders the label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const Scaffold(body: SourceChip(remote: true)),
      ),
    );
    expect(find.text('Google Drive'), findsOneWidget);
  });
}
