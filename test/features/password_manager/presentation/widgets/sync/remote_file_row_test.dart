// FR-2 / T8: RemoteFileRow renders the real `RemoteFile.size` when
// present, and omits it (no stray separator) when null.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/remote_file_row.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('shows formatted size when present', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RemoteFileRow(
          file: RemoteFile(
            providerId: 'google_drive',
            id: 'f1',
            name: 'Personal.kdbx',
            size: 2400000,
          ),
          selected: false,
          isLinkedElsewhere: false,
        ),
      ),
    );

    expect(find.textContaining('2.3 MB'), findsOneWidget);
  });

  testWidgets('omits size with no stray separator when null', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RemoteFileRow(
          file: RemoteFile(
            providerId: 'google_drive',
            id: 'f1',
            name: 'Work.kdbx',
          ),
          selected: false,
          isLinkedElsewhere: false,
        ),
      ),
    );

    expect(find.textContaining('MB'), findsNothing);
    expect(find.textContaining('KB'), findsNothing);
    expect(find.textContaining('·'), findsNothing);
  });
}
