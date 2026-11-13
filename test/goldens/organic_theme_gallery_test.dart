import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/app_glyph.dart';
import 'package:password_manager/core/theme/app_radii.dart';
import 'package:password_manager/core/theme/app_text_styles.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/theme/custode_colors.dart';
import 'package:password_manager/core/widgets/app_focus_ring.dart';
import 'package:password_manager/core/widgets/kv_icon.dart';

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

  const cases = <({String name, Size size, bool dark})>[
    (
      name: 'organic_theme_gallery_390x844_light.png',
      size: Size(390, 844),
      dark: false,
    ),
    (
      name: 'organic_theme_gallery_390x844_dark.png',
      size: Size(390, 844),
      dark: true,
    ),
    (
      name: 'organic_theme_gallery_1024x768_light.png',
      size: Size(1024, 768),
      dark: false,
    ),
    (
      name: 'organic_theme_gallery_1024x768_dark.png',
      size: Size(1024, 768),
      dark: true,
    ),
  ];

  for (final testCase in cases) {
    testWidgets(testCase.name, (tester) async {
      tester.view.physicalSize = testCase.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en', 'US'),
          theme: testCase.dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          home: MediaQuery(
            data: MediaQueryData(
              size: testCase.size,
              devicePixelRatio: 1,
              textScaler: TextScaler.noScaling,
              disableAnimations: true,
            ),
            child: const OrganicThemeGallery(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final layoutException = tester.takeException();
      expect(layoutException, isNull);
      expect(
        find.ancestor(
          of: find.byType(_ColorSamples),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.byType(_TypeSamples),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
      );
      for (final label in _roleNames) {
        expect(find.text(label), findsOneWidget, reason: label);
        _expectSupportingLabel(tester, 'role-$label', label);
      }
      for (final label in AppTextStyles.named.keys) {
        expect(find.text(label), findsOneWidget, reason: label);
        _expectSupportingLabel(tester, 'type-$label', label);
      }
      for (final label in _stateLabels) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.byType(KvIcon), findsNWidgets(5));
      final ringPainters = find.byKey(const ValueKey('app-focus-ring-painter'));
      expect(ringPainters, findsNWidgets(6));
      expect(
        tester
            .widgetList<CustomPaint>(ringPainters)
            .every((paint) => paint.painter != null),
        isTrue,
      );
      expect(_columnCount(tester, _roleNames.map((label) => 'role-$label')), 2);
      expect(
        _columnCount(
          tester,
          AppTextStyles.named.keys.map((label) => 'type-$label'),
        ),
        2,
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }
}

void _expectSupportingLabel(
  WidgetTester tester,
  String key,
  String expectedText,
) {
  final finder = find.byKey(ValueKey(key));
  final text = tester.widget<Text>(finder);
  final painter = TextPainter(
    text: TextSpan(text: expectedText, style: text.style),
    textDirection: TextDirection.ltr,
  )..layout();

  expect(text.softWrap, isFalse, reason: expectedText);
  expect(
    text.style!.fontSize,
    greaterThanOrEqualTo(11.5),
    reason: expectedText,
  );
  expect(
    painter.width,
    lessThanOrEqualTo(tester.getSize(finder).width + 0.01),
    reason: '$expectedText must not clip',
  );
}

class _SnapshotFocusNode extends FocusNode {
  @override
  bool get hasFocus => true;
}

int _columnCount(WidgetTester tester, Iterable<String> keys) => keys
    .map((key) => tester.getTopLeft(find.byKey(ValueKey(key))).dx.round())
    .toSet()
    .length;

const _roleNames = <String>[
  'ground',
  'surface',
  'surfaceNested',
  'canvas',
  'textPrimary',
  'textSecondary',
  'textTertiary',
  'divider',
  'actionFill',
  'actionText',
  'actionEmphasis',
  'attentionTint',
  'attentionText',
  'linkText',
  'positiveFill',
  'positiveTint',
  'positiveText',
  'selectionBorder',
  'iconNeutral',
];

const _stateLabels = <String>[
  'Filled enabled',
  'Filled focused',
  'Filled disabled',
  'Outline enabled',
  'Outline focused',
  'Outline disabled',
  'Input empty',
  'Input populated',
  'Input focused',
  'Input error',
  'Input disabled',
  'Switch off',
  'Switch on',
  'Switch focused',
  'Switch disabled',
  'Checkbox off',
  'Checkbox on',
  'Checkbox focused',
  'Checkbox disabled',
];

class OrganicThemeGallery extends StatelessWidget {
  const OrganicThemeGallery({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => constraints.maxWidth < 600
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _Panel(child: _ColorSamples(colors)),
                                      const SizedBox(height: 6),
                                      const _Panel(
                                        child: _PrimitiveStates(
                                          section: _PrimitiveSection.icons,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Expanded(
                                  child: _Panel(
                                    child: _TypeSamples(showHeading: false),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Expanded(
                              child: _Panel(
                                child: _PrimitiveStates(
                                  section: _PrimitiveSection.controls,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _Panel(child: _ColorSamples(colors)),
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: _Panel(child: _TypeSamples()),
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: _Panel(child: _PrimitiveStates()),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Padding(padding: const EdgeInsets.all(6), child: child),
  );
}

class _ColorSamples extends StatelessWidget {
  const _ColorSamples(this.colors);

  final CustodeColors colors;

  @override
  Widget build(BuildContext context) {
    final roles = <String, Color>{
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
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 2;
        const spacing = 4.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Semantic roles',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 3),
            Wrap(
              spacing: spacing,
              runSpacing: 2,
              children: [
                for (final role in roles.entries)
                  SizedBox(
                    width: itemWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: role.value,
                            border: Border.all(
                              color: colors.textPrimary,
                              width: 0.5,
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          role.key,
                          key: ValueKey('role-${role.key}'),
                          softWrap: false,
                          style: AppTextStyles.meta.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _TypeSamples extends StatelessWidget {
  const _TypeSamples({this.showHeading = true});

  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 2;
        const spacing = 1.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeading) ...[
              Text('Named type', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 3),
            ],
            Wrap(
              spacing: spacing,
              runSpacing: 1,
              children: [
                for (final sample in AppTextStyles.named.entries)
                  SizedBox(
                    width: itemWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sample.key,
                          key: ValueKey('type-${sample.key}'),
                          softWrap: false,
                          style: AppTextStyles.meta.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                        Text(
                          'A',
                          style: sample.value.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

enum _PrimitiveSection { all, actions, forms, icons, controls }

class _PrimitiveStates extends StatefulWidget {
  const _PrimitiveStates({this.section = _PrimitiveSection.all});

  final _PrimitiveSection section;

  @override
  State<_PrimitiveStates> createState() => _PrimitiveStatesState();
}

class _PrimitiveStatesState extends State<_PrimitiveStates> {
  final focused = WidgetStatesController(<WidgetState>{WidgetState.focused});
  final hovered = WidgetStatesController(<WidgetState>{WidgetState.hovered});
  final pressed = WidgetStatesController(<WidgetState>{WidgetState.pressed});
  final populated = TextEditingController(text: 'Vault value');
  final buttonFocus = _SnapshotFocusNode();
  final outlinedFocus = _SnapshotFocusNode();
  final inputFocus = _SnapshotFocusNode();
  final iconFocus = _SnapshotFocusNode();
  final switchFocus = _SnapshotFocusNode();
  final checkboxFocus = _SnapshotFocusNode();

  @override
  void dispose() {
    focused.dispose();
    hovered.dispose();
    pressed.dispose();
    populated.dispose();
    buttonFocus.dispose();
    outlinedFocus.dispose();
    inputFocus.dispose();
    iconFocus.dispose();
    switchFocus.dispose();
    checkboxFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = 8.0;
      const buttonSpacing = 8.0;
      final buttonWidth = (constraints.maxWidth - buttonSpacing * 5) / 6;
      const inputColumns = 5;
      final inputWidth =
          (constraints.maxWidth - spacing * (inputColumns - 1)) / inputColumns;
      const compactButtonStyle = ButtonStyle(
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        ),
        textStyle: WidgetStatePropertyAll(AppTextStyles.meta),
      );
      final showButtons = switch (widget.section) {
        _PrimitiveSection.all ||
        _PrimitiveSection.actions ||
        _PrimitiveSection.controls => true,
        _ => false,
      };
      final showIcons = switch (widget.section) {
        _PrimitiveSection.all ||
        _PrimitiveSection.actions ||
        _PrimitiveSection.icons => true,
        _ => false,
      };
      final showForms = switch (widget.section) {
        _PrimitiveSection.all ||
        _PrimitiveSection.forms ||
        _PrimitiveSection.controls => true,
        _ => false,
      };
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(switch (widget.section) {
            _PrimitiveSection.all => 'Primitive states',
            _PrimitiveSection.actions => 'Primitive actions',
            _PrimitiveSection.forms => 'Form states',
            _PrimitiveSection.icons => 'Icon states',
            _PrimitiveSection.controls => 'Control states',
          }, style: Theme.of(context).textTheme.titleSmall),
          if (showButtons) ...[
            SizedBox(
              height: widget.section == _PrimitiveSection.controls ? 1 : 3,
            ),
            Wrap(
              spacing: buttonSpacing,
              runSpacing: 3,
              children: [
                SizedBox(
                  width: buttonWidth,
                  child: FilledButton(
                    style: compactButtonStyle,
                    onPressed: () {},
                    child: const Text('Filled enabled'),
                  ),
                ),
                SizedBox(
                  width: buttonWidth,
                  child: AppFocusRing(
                    focusNode: buttonFocus,
                    borderRadius: BorderRadius.circular(AppRadii.rowCompact),
                    child: FilledButton(
                      focusNode: buttonFocus,
                      statesController: focused,
                      style: compactButtonStyle,
                      onPressed: () {},
                      child: const Text('Filled focused'),
                    ),
                  ),
                ),
                SizedBox(
                  width: buttonWidth,
                  child: FilledButton(
                    style: compactButtonStyle,
                    onPressed: null,
                    child: const Text('Filled disabled'),
                  ),
                ),
                SizedBox(
                  width: buttonWidth,
                  child: OutlinedButton(
                    style: compactButtonStyle,
                    onPressed: () {},
                    child: const Text('Outline enabled'),
                  ),
                ),
                SizedBox(
                  width: buttonWidth,
                  child: AppFocusRing(
                    focusNode: outlinedFocus,
                    borderRadius: BorderRadius.circular(AppRadii.rowCompact),
                    child: OutlinedButton(
                      focusNode: outlinedFocus,
                      statesController: focused,
                      style: compactButtonStyle,
                      onPressed: () {},
                      child: const Text('Outline focused'),
                    ),
                  ),
                ),
                SizedBox(
                  width: buttonWidth,
                  child: OutlinedButton(
                    style: compactButtonStyle,
                    onPressed: null,
                    child: const Text('Outline disabled'),
                  ),
                ),
              ],
            ),
          ],
          if (showButtons && showIcons) const SizedBox(height: 8),
          if (showIcons)
            Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: 8,
              runSpacing: 8,
              children: [
                _galleryIcon('Neutral icon', null),
                _galleryIcon('Hovered icon', hovered),
                _galleryIcon('Focused icon', focused, focusNode: iconFocus),
                _galleryIcon('Pressed icon', pressed),
                const IconButton(
                  onPressed: null,
                  icon: KvIcon(
                    glyph: AppGlyph.check,
                    size: 17,
                    semanticLabel: 'Disabled icon',
                  ),
                ),
              ],
            ),
          if ((showButtons || showIcons) && showForms)
            const SizedBox(height: 8),
          if (showForms) ...[
            Wrap(
              spacing: spacing,
              runSpacing: 3,
              children: [
                _inputSample(
                  width: inputWidth,
                  label: 'Input empty',
                  child: const TextField(decoration: InputDecoration()),
                ),
                _inputSample(
                  width: inputWidth,
                  label: 'Input populated',
                  child: TextField(
                    controller: populated,
                    decoration: const InputDecoration(),
                  ),
                ),
                _inputSample(
                  width: inputWidth,
                  label: 'Input focused',
                  child: AppFocusRing(
                    focusNode: inputFocus,
                    borderRadius: BorderRadius.circular(AppRadii.rowNested),
                    child: TextField(
                      focusNode: inputFocus,
                      showCursor: false,
                      decoration: const InputDecoration(),
                    ),
                  ),
                ),
                _inputSample(
                  width: inputWidth,
                  label: 'Input error',
                  child: const TextField(
                    decoration: InputDecoration(error: SizedBox.shrink()),
                  ),
                ),
                _inputSample(
                  width: inputWidth,
                  label: 'Input disabled',
                  child: const TextField(
                    enabled: false,
                    decoration: InputDecoration(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _toggleSample(
                  'Switch off',
                  Switch(value: false, onChanged: (_) {}),
                ),
                _toggleSample(
                  'Switch on',
                  Switch(value: true, onChanged: (_) {}),
                ),
                _toggleSample(
                  'Switch focused',
                  AppFocusRing(
                    focusNode: switchFocus,
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                    child: Switch(
                      focusNode: switchFocus,
                      value: true,
                      onChanged: (_) {},
                    ),
                  ),
                ),
                _toggleSample(
                  'Switch disabled',
                  const Switch(value: false, onChanged: null),
                ),
              ],
            ),
            Row(
              children: [
                _toggleSample(
                  'Checkbox off',
                  Checkbox(value: false, onChanged: (_) {}),
                ),
                _toggleSample(
                  'Checkbox on',
                  Checkbox(value: true, onChanged: (_) {}),
                ),
                _toggleSample(
                  'Checkbox focused',
                  AppFocusRing(
                    focusNode: checkboxFocus,
                    borderRadius: BorderRadius.circular(AppRadii.iconSquare),
                    child: Checkbox(
                      focusNode: checkboxFocus,
                      value: true,
                      onChanged: (_) {},
                    ),
                  ),
                ),
                _toggleSample(
                  'Checkbox disabled',
                  const Checkbox(value: false, onChanged: null),
                ),
              ],
            ),
          ],
        ],
      );
    },
  );

  Widget _galleryIcon(
    String label,
    WidgetStatesController? controller, {
    FocusNode? focusNode,
  }) {
    final icon = IconButton(
      focusNode: focusNode,
      statesController: controller,
      onPressed: () {},
      tooltip: label,
      icon: KvIcon(glyph: AppGlyph.check, size: 17, semanticLabel: label),
    );
    if (focusNode == null) return icon;
    return AppFocusRing(
      focusNode: focusNode,
      borderRadius: BorderRadius.circular(AppRadii.iconSquare),
      child: icon,
    );
  }

  Widget _inputSample({
    required double width,
    required String label,
    required Widget child,
  }) => SizedBox(
    width: width,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: AppTextStyles.meta),
        child,
      ],
    ),
  );

  Widget _toggleSample(String label, Widget control) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          control,
          Text(label, textAlign: TextAlign.center, style: AppTextStyles.meta),
        ],
      ),
    ),
  );
}
