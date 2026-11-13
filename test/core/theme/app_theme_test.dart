import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/app_colors.dart';
import 'package:password_manager/core/theme/app_elevation.dart';
import 'package:password_manager/core/theme/app_glyph.dart';
import 'package:password_manager/core/theme/app_motion.dart';
import 'package:password_manager/core/theme/app_radii.dart';
import 'package:password_manager/core/theme/app_spacing.dart';
import 'package:password_manager/core/theme/app_text_styles.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/theme/custode_colors.dart';
import 'package:password_manager/core/widgets/kv_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  test(
    'bundled Organic fonts are available without runtime fetching',
    () async {
      const assets = <String>[
        'assets/fonts/Caprasimo-Regular.ttf',
        'assets/fonts/Figtree-Regular.ttf',
        'assets/fonts/Figtree-SemiBold.ttf',
        'assets/fonts/Figtree-Bold.ttf',
      ];

      for (final asset in assets) {
        final bytes = await rootBundle.load(asset);
        expect(bytes.lengthInBytes, greaterThan(0), reason: asset);
      }
    },
  );

  test('bundled font and icon licenses register once', () async {
    AppTheme.lightTheme;
    AppTheme.darkTheme;

    final licenses = await LicenseRegistry.licenses.toList();
    final fonts = licenses
        .where((entry) => entry.packages.contains('Caprasimo'))
        .toList();
    final icons = licenses
        .where((entry) => entry.packages.contains('Lucide Icons'))
        .toList();

    expect(fonts, hasLength(1));
    expect(
      fonts.single.packages,
      containsAll(<String>['Caprasimo', 'Figtree']),
    );
    expect(fonts.single.paragraphs.length, greaterThan(0));
    expect(icons, hasLength(1));
    expect(icons.single.paragraphs.length, greaterThan(0));
  });

  test('Organic ramps expose exact implementation values', () {
    expect(
      const <Color>[
        AppColors.neutral100,
        AppColors.neutral200,
        AppColors.neutral300,
        AppColors.neutral400,
        AppColors.neutral500,
        AppColors.neutral600,
        AppColors.neutral700,
        AppColors.neutral800,
        AppColors.neutral900,
      ],
      const <Color>[
        Color(0xFFF9F4ED),
        Color(0xFFEEE7DB),
        Color(0xFFDCD3C4),
        Color(0xFFC0B6A5),
        Color(0xFFA19786),
        Color(0xFF82796A),
        Color(0xFF665F53),
        Color(0xFF474238),
        Color(0xFF2E2B25),
      ],
    );
    expect(AppColors.text, const Color(0xFF201E1D));
    expect(AppColors.divider, const Color(0x29201E1D));
    expect(
      const <Color>[
        AppColors.accent100,
        AppColors.accent200,
        AppColors.accent300,
        AppColors.accent400,
        AppColors.accent500,
        AppColors.accent600,
        AppColors.accent700,
        AppColors.accent800,
        AppColors.accent900,
      ],
      const <Color>[
        Color(0xFFFFF2EB),
        Color(0xFFFFE1D0),
        Color(0xFFFFC6A5),
        Color(0xFFF6A06B),
        Color(0xFFD67F48),
        Color(0xFFB2622D),
        Color(0xFF8C491A),
        Color(0xFF643312),
        Color(0xFF402310),
      ],
    );
    expect(
      const <Color>[
        AppColors.accent2_100,
        AppColors.accent2_200,
        AppColors.accent2_300,
        AppColors.accent2_400,
        AppColors.accent2_500,
        AppColors.accent2_600,
        AppColors.accent2_700,
        AppColors.accent2_800,
        AppColors.accent2_900,
      ],
      const <Color>[
        Color(0xFFF0FAE1),
        Color(0xFFE1EECC),
        Color(0xFFCCDBB2),
        Color(0xFFAEBF92),
        Color(0xFF8FA073),
        Color(0xFF728157),
        Color(0xFF56633F),
        Color(0xFF3D472B),
        Color(0xFF272E1B),
      ],
    );
  });

  test('all semantic roles match independent light and dark tables', () {
    final expectedLight = <String, Color>{
      'ground': AppColors.neutral100,
      'surface': AppColors.neutral200,
      'surfaceNested': AppColors.neutral100,
      'canvas': AppColors.neutral300,
      'textPrimary': AppColors.text,
      'textSecondary': AppColors.neutral700,
      'textTertiary': AppColors.neutral700,
      'divider': AppColors.divider,
      'actionFill': AppColors.accent300,
      'actionText': AppColors.accent900,
      'actionEmphasis': AppColors.accent400,
      'attentionTint': AppColors.accent100,
      'attentionText': AppColors.accent900,
      'linkText': AppColors.accent800,
      'positiveFill': AppColors.accent2_400,
      'positiveTint': AppColors.accent2_100,
      'positiveText': AppColors.accent2_900,
      'selectionBorder': AppColors.accent400,
      'iconNeutral': AppColors.neutral700,
    };
    final expectedDark = <String, Color>{
      'ground': AppColors.neutral900,
      'surface': AppColors.neutral800,
      'surfaceNested': AppColors.neutral900,
      'canvas': AppColors.neutral900,
      'textPrimary': AppColors.neutral100,
      'textSecondary': AppColors.neutral100.withValues(alpha: 0.62),
      'textTertiary': AppColors.neutral100.withValues(alpha: 0.62),
      'divider': AppColors.neutral100.withValues(alpha: 0.22),
      'actionFill': AppColors.accent300,
      'actionText': AppColors.accent900,
      'actionEmphasis': AppColors.accent400,
      'attentionTint': AppColors.accent800,
      'attentionText': AppColors.accent200,
      'linkText': AppColors.accent300,
      'positiveFill': AppColors.accent2_400,
      'positiveTint': AppColors.accent2_800,
      'positiveText': AppColors.accent2_200,
      'selectionBorder': AppColors.accent300,
      'iconNeutral': AppColors.neutral100.withValues(alpha: 0.72),
    };

    expect(_semanticRoles(CustodeColors.light), expectedLight);
    expect(_semanticRoles(CustodeColors.dark), expectedDark);
    expect(expectedLight, hasLength(19));
    expect(expectedDark, hasLength(19));
  });

  for (final theme in <({String name, CustodeColors colors})>[
    (name: 'light', colors: CustodeColors.light),
    (name: 'dark', colors: CustodeColors.dark),
  ]) {
    test('${theme.name} declared text/background pairs meet 4.5:1', () {
      final colors = theme.colors;
      final surfaces = <String, Color>{
        'ground': colors.ground,
        'surface': colors.surface,
        'surfaceNested': colors.surfaceNested,
      };
      final pairs =
          <({String text, Color foreground, String background, Color bg})>[
            for (final entry in surfaces.entries) ...[
              (
                text: 'textPrimary',
                foreground: colors.textPrimary,
                background: entry.key,
                bg: entry.value,
              ),
              (
                text: 'textSecondary',
                foreground: colors.textSecondary,
                background: entry.key,
                bg: entry.value,
              ),
              (
                text: 'textTertiary',
                foreground: colors.textTertiary,
                background: entry.key,
                bg: entry.value,
              ),
              (
                text: 'linkText',
                foreground: colors.linkText,
                background: entry.key,
                bg: entry.value,
              ),
            ],
            (
              text: 'actionText',
              foreground: colors.actionText,
              background: 'actionFill',
              bg: colors.actionFill,
            ),
            (
              text: 'actionText',
              foreground: colors.actionText,
              background: 'actionEmphasis',
              bg: colors.actionEmphasis,
            ),
            (
              text: 'attentionText',
              foreground: colors.attentionText,
              background: 'attentionTint',
              bg: colors.attentionTint,
            ),
            (
              text: 'positiveText',
              foreground: colors.positiveText,
              background: 'positiveTint',
              bg: colors.positiveTint,
            ),
          ];

      for (final pair in pairs) {
        expect(
          _contrastRatio(pair.foreground, pair.bg),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.name} ${pair.text} on ${pair.background} must pass',
        );
      }
    });
  }

  test('metric and type tokens expose approved scale', () {
    expect(
      const [
        AppSpacing.s1,
        AppSpacing.s2,
        AppSpacing.s3,
        AppSpacing.s4,
        AppSpacing.s6,
        AppSpacing.s8,
      ],
      const [4.4, 8.8, 13.2, 17.6, 26.4, 35.2],
    );
    expect(
      const [
        AppRadii.row,
        AppRadii.rowCompact,
        AppRadii.rowNested,
        AppRadii.card,
        AppRadii.cardLarge,
        AppRadii.sheet,
        AppRadii.pill,
        AppRadii.iconSquare,
        AppRadii.avatar,
        AppRadii.frame,
        AppRadii.tabletFrame,
      ],
      const [22, 20, 16, 24, 28, 32, 999, 14, 999, 46, 22],
    );
    expect(AppTextStyles.heroHeadline.fontFamily, 'Caprasimo');
    expect(AppTextStyles.body.fontFamily, 'Figtree');
    expect(AppTextStyles.labelMicro.fontSize, 10);
    expect(AppTextStyles.named, hasLength(21));
    expect(AppTextStyles.named.keys, <String>[
      'heroHeadline',
      'screenTitle',
      'screenTitleLarge',
      'sheetTitle',
      'sheetTitleLarge',
      'panelTitle',
      'panelTitleLarge',
      'numeric',
      'numericLarge',
      'rowTitle',
      'fieldValue',
      'fieldValueDense',
      'body',
      'secondary',
      'meta',
      'metaLarge',
      'labelUpper',
      'labelMicro',
      'secret',
      'secretLarge',
      'otpCode',
    ]);
    expect(AppTextStyles.named.values.map((style) => style.fontSize), <double>[
      38,
      28,
      30,
      22,
      24,
      18,
      20,
      18,
      22,
      15,
      15,
      14.5,
      13.5,
      12.5,
      11.5,
      12,
      11,
      10,
      13.5,
      16,
      21,
    ]);
  });

  test('elevation and motion tokens expose approved values', () {
    expect(
      <List<BoxShadow>>[
        AppElevation.sm,
        AppElevation.md,
        AppElevation.lg,
        AppElevation.darkLg,
      ].map((shadows) => shadows.single.blurRadius),
      <double>[2, 10, 32, 32],
    );
    expect(
      <List<BoxShadow>>[
        AppElevation.sm,
        AppElevation.md,
        AppElevation.lg,
        AppElevation.darkLg,
      ].map((shadows) => shadows.single.offset),
      const <Offset>[Offset(0, 1), Offset(0, 3), Offset(0, 12), Offset(0, 12)],
    );
    expect(
      const <Duration>[
        AppMotion.row,
        AppMotion.button,
        AppMotion.sheetIn,
        AppMotion.sheetOut,
        AppMotion.unlock,
        AppMotion.copyVisibility,
        AppMotion.copyIn,
        AppMotion.copyOut,
        AppMotion.spinner,
      ].map((duration) => duration.inMilliseconds),
      <int>[190, 220, 240, 180, 280, 1600, 200, 200, 900],
    );
    expect(AppMotion.inCurve, Curves.easeOutCubic);
    expect(AppMotion.outCurve, Curves.easeInCubic);
    expect(AppMotion.spinnerCurve, Curves.linear);
  });

  test('vendored glyph assets enforce Lucide geometry', () async {
    final assets = <String>{...AppGlyph.values.map((glyph) => glyph.assetPath)};
    // spec-019 T021 added `arrow-up-down` for the phone header's sort
    // control (DQ-8); 2026-08-31 added `link` (remote-file picker's
    // contextual link action) and `log-out` (Settings' Close database).
    expect(assets, hasLength(45));

    for (final asset in assets) {
      final svg = await rootBundle.loadString(asset);
      expect(svg, contains('viewBox="0 0 24 24"'), reason: asset);
      expect(svg, contains('fill="none"'), reason: asset);
      expect(svg, contains('stroke="currentColor"'), reason: asset);
      expect(svg, contains('stroke-width="2.75"'), reason: asset);
      expect(svg, contains('stroke-linecap="round"'), reason: asset);
      expect(svg, contains('stroke-linejoin="round"'), reason: asset);
      expect(
        RegExp(r'fill="(?!none)[^"]+"').hasMatch(svg),
        isFalse,
        reason: asset,
      );
      expect(
        RegExp(r'stroke-width="(?!2\.75)[^"]+"').hasMatch(svg),
        isFalse,
        reason: asset,
      );
    }
  });

  testWidgets('KvIcon renders fixed asset geometry and optional semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const KvIcon(
          glyph: AppGlyph.add,
          size: 19,
          color: AppColors.accent800,
          semanticLabel: 'Add entry',
        ),
      ),
    );
    await tester.pump();

    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(picture.width, 19);
    expect(picture.height, 19);
    expect(find.bySemanticsLabel('Add entry'), findsOneWidget);
    expect(
      (picture.bytesLoader as SvgAssetLoader).assetName,
      AppGlyph.add.assetPath,
    );
    expect(
      (picture.bytesLoader as SvgAssetLoader).theme!.currentColor,
      AppColors.accent800,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const KvIcon(glyph: AppGlyph.add),
      ),
    );
    await tester.pump();

    final decorative = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(decorative.semanticsLabel, isNull);
    expect(decorative.excludeFromSemantics, isTrue);
    expect(find.bySemanticsLabel('Add entry'), findsNothing);
  });

  for (final theme in <({String name, ThemeData data, CustodeColors colors})>[
    (name: 'light', data: AppTheme.lightTheme, colors: CustodeColors.light),
    (name: 'dark', data: AppTheme.darkTheme, colors: CustodeColors.dark),
  ]) {
    test('${theme.name} ThemeData registers Organic primitives', () {
      final data = theme.data;
      final colors = theme.colors;
      final isDark = theme.name == 'dark';
      final filled = data.filledButtonTheme.style!;
      final outlined = data.outlinedButtonTheme.style!;
      final text = data.textButtonTheme.style!;
      final icon = data.iconButtonTheme.style!;

      expect(data.extension<CustodeColors>(), same(colors));
      expect(data.textTheme.bodyMedium!.fontFamily, 'Figtree');
      expect(data.textTheme.headlineMedium!.fontFamily, 'Caprasimo');
      expect(data.colorScheme.primary, colors.linkText);
      expect(data.colorScheme.secondary, colors.positiveText);
      expect(data.colorScheme.error, colors.attentionText);

      final foregroundRoles = <String, Color>{
        'primary': data.colorScheme.primary,
        'secondary': data.colorScheme.secondary,
        'tertiary': data.colorScheme.tertiary,
        'error': data.colorScheme.error,
      };
      for (final role in foregroundRoles.entries) {
        for (final surface in <Color>[
          colors.ground,
          colors.surface,
          colors.surfaceNested,
        ]) {
          expect(
            _contrastRatio(role.value, surface),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.name} ${role.key} must work as foreground',
          );
        }
      }
      for (final pair in <({String name, Color foreground, Color background})>[
        (
          name: 'onPrimary/primary',
          foreground: data.colorScheme.onPrimary,
          background: data.colorScheme.primary,
        ),
        (
          name: 'onSecondary/secondary',
          foreground: data.colorScheme.onSecondary,
          background: data.colorScheme.secondary,
        ),
        (
          name: 'onTertiary/tertiary',
          foreground: data.colorScheme.onTertiary,
          background: data.colorScheme.tertiary,
        ),
        (
          name: 'onError/error',
          foreground: data.colorScheme.onError,
          background: data.colorScheme.error,
        ),
        (
          name: 'onPrimaryContainer/primaryContainer',
          foreground: data.colorScheme.onPrimaryContainer,
          background: data.colorScheme.primaryContainer,
        ),
        (
          name: 'onSecondaryContainer/secondaryContainer',
          foreground: data.colorScheme.onSecondaryContainer,
          background: data.colorScheme.secondaryContainer,
        ),
        (
          name: 'onErrorContainer/errorContainer',
          foreground: data.colorScheme.onErrorContainer,
          background: data.colorScheme.errorContainer,
        ),
      ]) {
        expect(
          _contrastRatio(pair.foreground, pair.background),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.name} ${pair.name} must pass',
        );
      }

      expect(filled.backgroundColor!.resolve({}), colors.actionFill);
      expect(
        filled.backgroundColor!.resolve({WidgetState.hovered}),
        colors.actionEmphasis,
      );
      expect(
        filled.backgroundColor!.resolve({WidgetState.pressed}),
        AppColors.accent500,
      );
      expect(
        filled.backgroundColor!.resolve({WidgetState.disabled}),
        colors.surface,
      );
      expect(filled.side!.resolve({WidgetState.focused})!.width, 2);
      expect(filled.minimumSize!.resolve({}), const Size(44, 48));
      expect(filled.animationDuration, AppMotion.button);

      expect(
        outlined.backgroundColor!.resolve({}),
        isDark ? AppColors.neutral800 : Colors.transparent,
      );
      expect(
        outlined.backgroundColor!.resolve({WidgetState.hovered}),
        isDark ? AppColors.neutral700 : colors.surfaceNested,
      );
      expect(
        outlined.backgroundColor!.resolve({WidgetState.pressed}),
        isDark ? AppColors.neutral600 : colors.canvas,
      );
      expect(
        outlined.backgroundColor!.resolve({WidgetState.hovered}),
        isNot(outlined.backgroundColor!.resolve({WidgetState.pressed})),
      );
      expect(outlined.side!.resolve({WidgetState.focused})!.width, 2);
      expect(
        outlined.foregroundColor!.resolve({WidgetState.disabled}),
        colors.textSecondary,
      );
      expect(outlined.minimumSize!.resolve({}), const Size(44, 48));
      expect(outlined.animationDuration, AppMotion.button);

      expect(text.minimumSize!.resolve({}), const Size(44, 44));
      expect(text.side!.resolve({WidgetState.focused})!.width, 2);
      expect(text.animationDuration, AppMotion.button);

      expect(icon.foregroundColor!.resolve({}), colors.iconNeutral);
      expect(
        icon.backgroundColor!.resolve({}),
        isDark ? AppColors.neutral800 : Colors.transparent,
      );
      expect(
        icon.backgroundColor!.resolve({WidgetState.hovered}),
        isDark ? AppColors.neutral700 : colors.surfaceNested,
      );
      expect(
        icon.backgroundColor!.resolve({WidgetState.pressed}),
        isDark ? AppColors.neutral600 : colors.canvas,
      );
      expect(
        icon.backgroundColor!.resolve({WidgetState.hovered}),
        isNot(icon.backgroundColor!.resolve({WidgetState.pressed})),
      );
      expect(icon.side!.resolve({WidgetState.focused})!.width, 2);
      expect(icon.minimumSize!.resolve({}), const Size(44, 44));
      expect(icon.animationDuration, AppMotion.button);

      final input = data.inputDecorationTheme;
      expect((input.focusedBorder! as OutlineInputBorder).borderSide.width, 2);
      expect(
        (input.errorBorder! as OutlineInputBorder).borderSide.color,
        colors.attentionText,
      );
      expect(input.disabledBorder, isA<OutlineInputBorder>());

      expect(
        data.switchTheme.trackColor!.resolve({WidgetState.selected}),
        colors.actionFill,
      );
      expect(
        data.switchTheme.trackOutlineWidth!.resolve({WidgetState.focused}),
        2,
      );
      expect(
        data.checkboxTheme.fillColor!.resolve({WidgetState.selected}),
        colors.actionFill,
      );
      expect(
        (data.checkboxTheme.side! as WidgetStateBorderSide).resolve({
          WidgetState.focused,
        })!.width,
        2,
      );
    });
  }

  testWidgets('button focus, hover, press, and target size render from theme', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('button'),
              focusNode: focusNode,
              onPressed: () {},
              child: const Text('Unlock'),
            ),
          ),
        ),
      ),
    );

    final button = find.byKey(const ValueKey('button'));
    Material material() => tester.widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)).first,
    );

    expect(tester.getSize(button).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(44));

    focusNode.requestFocus();
    await tester.pumpAndSettle();
    expect((material().shape! as RoundedRectangleBorder).side.width, 2);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(button));
    await tester.pump(AppMotion.button);
    expect(material().color, CustodeColors.dark.actionEmphasis);

    await mouse.down(tester.getCenter(button));
    await tester.pump(AppMotion.button);
    expect(material().color, AppColors.accent500);
    await mouse.up();
  });

  testWidgets('dark neutral control states render as distinct colors', (
    tester,
  ) async {
    const buttonKey = ValueKey('neutral-control');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Center(
            child: OutlinedButton(
              key: buttonKey,
              onPressed: () {},
              child: const Text('State'),
            ),
          ),
        ),
      ),
    );

    Material material() => tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(buttonKey),
            matching: find.byType(Material),
          )
          .first,
    );

    expect(material().color, AppColors.neutral800);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.byKey(buttonKey)));
    await tester.pump(AppMotion.button);
    expect(material().color, AppColors.neutral700);

    await mouse.down(tester.getCenter(find.byKey(buttonKey)));
    await tester.pump(AppMotion.button);
    expect(material().color, AppColors.neutral600);
    await mouse.up();
  });

  testWidgets('motion duration follows accessibility setting', (tester) async {
    Duration? enabled;
    Duration? disabled;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: false),
        child: Builder(
          builder: (context) {
            enabled = AppMotion.duration(context, AppMotion.button);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (context) {
            disabled = AppMotion.duration(context, AppMotion.button);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(enabled, AppMotion.button);
    expect(disabled, Duration.zero);
  });
}

Map<String, Color> _semanticRoles(CustodeColors colors) => <String, Color>{
  'ground': colors.ground,
  'surface': colors.surface,
  'surfaceNested': colors.surfaceNested,
  'canvas': colors.canvas,
  'textPrimary': colors.textPrimary,
  'textSecondary': colors.textSecondary,
  'textTertiary': colors.textTertiary,
  'divider': colors.divider,
  'actionFill': colors.actionFill,
  'actionText': colors.actionText,
  'actionEmphasis': colors.actionEmphasis,
  'attentionTint': colors.attentionTint,
  'attentionText': colors.attentionText,
  'linkText': colors.linkText,
  'positiveFill': colors.positiveFill,
  'positiveTint': colors.positiveTint,
  'positiveText': colors.positiveText,
  'selectionBorder': colors.selectionBorder,
  'iconNeutral': colors.iconNeutral,
};

double _contrastRatio(Color foreground, Color background) {
  final opaqueForeground = Color.alphaBlend(foreground, background);
  final foregroundLuminance = opaqueForeground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final high = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final low = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (high + 0.05) / (low + 0.05);
}
