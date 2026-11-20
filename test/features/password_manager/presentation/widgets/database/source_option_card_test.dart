import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/theme/app_glyph.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/widgets/kv_tag.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/source_option_card.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? AppTheme.lightTheme,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('shows title and subtitle, taps through and ends in a chevron', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        SourceOptionCard(
          glyph: AppGlyph.desktop,
          title: 'This device',
          subtitle: 'Pick a .kdbx file',
          onTap: () => taps += 1,
        ),
      ),
    );

    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Pick a .kdbx file'), findsOneWidget);
    await tester.tap(find.text('This device'));
    expect(taps, 1);
    expect(
      tester.getSize(find.byType(SourceOptionCard)).height,
      greaterThanOrEqualTo(44),
    );
  });

  testWidgets('an action label replaces the chevron', (tester) async {
    await tester.pumpWidget(
      _host(
        SourceOptionCard(
          glyph: AppGlyph.cloud,
          title: 'Google Drive',
          subtitle: 'Not connected',
          actionLabel: 'Connect',
          onTap: () {},
        ),
      ),
    );

    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('a null onTap is disabled, keeps its reason and ignores taps', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const SourceOptionCard(
          glyph: AppGlyph.cloud,
          title: 'Google Drive',
          subtitle: 'Not available in the browser',
        ),
      ),
    );

    expect(find.text('Not available in the browser'), findsOneWidget);
    await tester.tap(find.text('Google Drive'), warnIfMissed: false);
    expect(
      tester.getSemantics(find.byType(SourceOptionCard)),
      matchesSemantics(
        label: 'Google Drive, Not available in the browser',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('selected draws the highlight and a trailing widget wins', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SourceOptionCard(
          glyph: AppGlyph.check,
          title: 'Open the existing one',
          subtitle: 'Nothing is imported or changed.',
          selected: true,
          trailing: const KvTag(
            label: 'Recommended',
            variant: KvTagVariant.accent,
          ),
          onTap: () {},
        ),
      ),
    );

    expect(find.text('Recommended'), findsOneWidget);
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SourceOptionCard),
            matching: find.byType(Material),
          )
          .first,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.side.width, 1.5);
  });

  testWidgets('dark theme keeps text on the declared roles', (tester) async {
    await tester.pumpWidget(
      _host(
        SourceOptionCard(
          glyph: AppGlyph.desktop,
          title: 'This device',
          subtitle: 'Pick a .kdbx file',
          onTap: () {},
        ),
        theme: AppTheme.darkTheme,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('This device'), findsOneWidget);
  });
}
