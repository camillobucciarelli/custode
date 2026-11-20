// FR-2 / T8: RemoteFileRow renders the real `RemoteFile.size` when
// present, and omits it (no stray separator) when null.
import 'package:flutter/rendering.dart';
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

  testWidgets('Already added never cuts the date and size: on a narrow row '
      'the tag drops under the metadata', (tester) async {
    Future<void> pumpAt(double width) => tester.pumpWidget(
      _wrap(
        Center(
          child: SizedBox(
            width: width,
            child: RemoteFileRow(
              file: RemoteFile(
                providerId: 'google_drive',
                id: 'f1',
                name: 'Personal.kdbx',
                size: 2400000,
                modifiedTime: DateTime(2026, 3, 12),
              ),
              selected: false,
              isLinkedElsewhere: false,
              alreadyAdded: true,
              showChevron: true,
            ),
          ),
        ),
      ),
    );

    const meta = 'Modified 12 Mar 2026 · 2.3 MB';
    // Wide: the tag sits beside the metadata.
    await pumpAt(900);
    final metaWidth = tester.getSize(find.text(meta)).width;
    final textColumn = find
        .ancestor(of: find.byType(Wrap), matching: find.byType(Column))
        .first;
    final rowChrome = 900 - tester.getSize(textColumn).width;
    expect(
      tester.getCenter(find.text('Already added')).dy,
      moreOrLessEquals(tester.getCenter(find.text(meta)).dy, epsilon: 2),
    );

    // Room for the metadata but not for the tag next to it: the tag drops to
    // its own run and the metadata keeps its full text.
    await pumpAt(rowChrome + metaWidth + 20);
    expect(tester.takeException(), isNull);
    expect(
      tester.renderObject<RenderParagraph>(find.text(meta)).didExceedMaxLines,
      isFalse,
    );
    expect(tester.getSize(find.text(meta)).width, metaWidth);
    expect(
      tester.getTopLeft(find.text('Already added')).dy,
      greaterThan(tester.getBottomLeft(find.text(meta)).dy),
    );
  });
}
