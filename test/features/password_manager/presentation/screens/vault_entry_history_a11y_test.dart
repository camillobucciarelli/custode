// spec 017 T502 — Constitution V on the history view: every text/background
// pairing at 4.5:1 or better in both themes, rows at 44 dp or taller, and a
// 2 px focus ring on every focusable.
//
// Two layers, so a bad token fails here and not only in a golden diff:
//   1. the token matrix — the exact (foreground, background) pairs the view
//      composes, checked arithmetically for light and dark;
//   2. the rendered view — every `Text` inside the dialog resolves to one of
//      those foregrounds, so a stray hard-coded colour cannot slip past 1.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/custode_colors.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry_revision.dart';

import 'vault/entry_editor_generator_test_utils.dart';

double _contrastRatio(Color foreground, Color background) {
  final opaqueForeground = Color.alphaBlend(foreground, background);
  final a = opaqueForeground.computeLuminance();
  final b = background.computeLuminance();
  final high = a > b ? a : b;
  final low = a > b ? b : a;
  return (high + 0.05) / (low + 0.05);
}

/// The pairs the history view and its confirmations put on screen.
List<({String label, Color foreground, Color background})> _pairs(
  CustodeColors colors,
) => [
  // Dialog title/body and the revision card.
  (
    label: 'textPrimary on surface',
    foreground: colors.textPrimary,
    background: colors.surface,
  ),
  // "Changed: …", the retention line — the smallest secondary text.
  (
    label: 'textSecondary on surface',
    foreground: colors.textSecondary,
    background: colors.surface,
  ),
  // The masked password row sits on surfaceNested.
  (
    label: 'textPrimary on surfaceNested',
    foreground: colors.textPrimary,
    background: colors.surfaceNested,
  ),
  (
    label: 'textSecondary on surfaceNested',
    foreground: colors.textSecondary,
    background: colors.surfaceNested,
  ),
  // "Password changed" tag.
  (
    label: 'attentionText on attentionTint',
    foreground: colors.attentionText,
    background: colors.attentionTint,
  ),
  // Text buttons: restore, delete, clear, close.
  (
    label: 'linkText on surface',
    foreground: colors.linkText,
    background: colors.surface,
  ),
  // The destructive confirm button and the warning glyph beside the title.
  (
    label: 'surface on attentionText',
    foreground: colors.surface,
    background: colors.attentionText,
  ),
  (
    label: 'attentionText on surface',
    foreground: colors.attentionText,
    background: colors.surface,
  ),
];

VaultEntryHistory _history() => VaultEntryHistory(
  revisions: [
    VaultEntryRevision(
      entryId: 'e-github',
      replacedAt: DateTime.utc(2026, 3, 2, 10, 30),
      title: 'GitHub',
      username: 'camillo@bucciarelli.dev',
      password: 'Fixture-Old-Pass-9z',
      url: 'https://github.com',
      notes: '',
    ),
    VaultEntryRevision(
      entryId: 'e-github',
      replacedAt: DateTime.utc(2026, 1, 4, 8),
      title: 'GitHub',
      username: 'camillo@bucciarelli.dev',
      password: 'fixture-older-password',
      url: 'https://github.com',
      notes: '',
    ),
  ],
  retention: const VaultHistoryRetention(maxItems: 10),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    await (FontLoader('Figtree')
          ..addFont(rootBundle.load('assets/fonts/Figtree-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-SemiBold.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-Bold.ttf')))
        .load();
  });

  tearDown(resetEntryTestDi);

  group('token matrix', () {
    for (final (name, colors) in [
      ('light', CustodeColors.light),
      ('dark', CustodeColors.dark),
    ]) {
      test('every pairing is at least 4.5:1 ($name)', () {
        for (final pair in _pairs(colors)) {
          expect(
            _contrastRatio(pair.foreground, pair.background),
            greaterThanOrEqualTo(4.5),
            reason: '${pair.label} ($name)',
          );
        }
      });
    }
  });

  Future<void> openHistory(WidgetTester tester, ThemeMode themeMode) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = EntryTestHarness()..histories['e-github'] = _history();
    await tester.pumpWidget(
      await pumpableEntryScreen(harness: harness, themeMode: themeMode),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('View history'));
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  for (final (name, themeMode, colors) in [
    ('light', ThemeMode.light, CustodeColors.light),
    ('dark', ThemeMode.dark, CustodeColors.dark),
  ]) {
    testWidgets('every text in the view uses a declared foreground ($name)', (
      tester,
    ) async {
      await openHistory(tester, themeMode);
      final declared = {
        colors.textPrimary,
        colors.textSecondary,
        colors.attentionText,
        colors.linkText,
      };

      final texts = tester.widgetList<Text>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Text),
        ),
      );
      expect(texts, isNotEmpty);
      for (final text in texts) {
        final color = text.style?.color;
        // A null colour inherits from its button/dialog, whose foregrounds
        // are the theme's own tokens (checked in the matrix above).
        if (color == null) continue;
        expect(
          declared.contains(color),
          isTrue,
          reason: '"${text.data}" uses $color, not a declared token ($name)',
        );
      }
      await unmount(tester);
    });
  }

  testWidgets('every revision row is at least 44 dp tall', (tester) async {
    await openHistory(tester, ThemeMode.light);

    final cards = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_RevisionCard',
    );
    expect(cards, findsNWidgets(2));
    for (final card in cards.evaluate()) {
      expect(card.size!.height, greaterThanOrEqualTo(44));
    }
    // And every text button in the dialog too (Close, Restore, Delete,
    // Clear): the theme's 44 dp minimum, asserted rather than trusted.
    final buttons = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextButton),
    );
    expect(buttons, findsWidgets);
    for (final button in buttons.evaluate()) {
      expect(button.size!.height, greaterThanOrEqualTo(44));
    }
    await unmount(tester);
  });

  testWidgets('every focusable in the view draws a 2 px focus ring', (
    tester,
  ) async {
    await openHistory(tester, ThemeMode.light);
    final context = tester.element(find.byType(AlertDialog));
    final theme = Theme.of(context);
    const focused = {WidgetState.focused};

    // The view's focusables are text buttons and icon buttons, nothing
    // else — so these two theme sides cover every one of them.
    // `IconButton` delegates to a private M3 `ButtonStyleButton` of its
    // own; that inner widget is the same focusable, not a third kind.
    final focusables = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ButtonStyleButton &&
            !widget.runtimeType.toString().startsWith('_IconButton'),
      ),
    );
    expect(focusables, findsWidgets);
    for (final element in focusables.evaluate()) {
      expect(
        element.widget,
        anyOf(isA<TextButton>(), isA<IconButton>()),
        reason: '${element.widget.runtimeType} has no focus ring contract',
      );
    }

    for (final (label, style) in [
      ('TextButton', theme.textButtonTheme.style),
      ('IconButton', theme.iconButtonTheme.style),
    ]) {
      final side = style?.side?.resolve(focused);
      expect(side, isNotNull, reason: '$label focus side');
      expect(side!.width, 2, reason: '$label focus ring width');
      expect(side.color, CustodeColors.light.selectionBorder);
    }

    // And for real: once focused, the button's painted shape carries that
    // 2 px side — the ring is drawn, not merely configured.
    final restore = find.ancestor(
      of: find.text('Restore this version').first,
      matching: find.byType(TextButton),
    );
    Focus.of(tester.element(find.text('Restore this version').first))
        .requestFocus();
    await tester.pumpAndSettle();
    final material = tester.widget<Material>(
      find.descendant(of: restore, matching: find.byType(Material)).first,
    );
    final shape = material.shape;
    expect(shape, isA<OutlinedBorder>());
    expect((shape! as OutlinedBorder).side.width, 2);
    expect(
      (shape as OutlinedBorder).side.color,
      CustodeColors.light.selectionBorder,
    );
    await unmount(tester);
  });
}
