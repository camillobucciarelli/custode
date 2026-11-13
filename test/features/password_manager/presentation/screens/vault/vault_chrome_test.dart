// spec-019 T054 / US4 — the rail and tab bar say what they are.
//
// Three findings from the conformance audit, each asserted here: the rail
// showed a Lucide key instead of the app's mark (C-SH-03), two destinations
// carried glyphs `ICONS.md` does not name (C-03-13), and the selected
// destination was signalled by colour alone (C-03-14).
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_colors.dart';

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetVaultShellTestDi);

  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      await pumpableVaultShell(
        vaultKdbxService: NavigationFixtureVaultKdbxService(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Iterable<String> glyphAssets(WidgetTester tester) => tester
      .widgetList<SvgPicture>(find.byType(SvgPicture))
      .map((picture) => picture.bytesLoader.toString());

  testWidgets('FR-017 — Vault is a lock and Sync is refresh-cw', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    final assets = glyphAssets(tester).join('\n');

    expect(assets, contains('lock.svg'), reason: 'Vault destination (DQ-4)');
    expect(
      assets,
      contains('refresh-cw.svg'),
      reason: 'Sync destination (DQ-4)',
    );
    expect(assets, contains('shield-check.svg'), reason: 'Health');
    expect(assets, contains('settings.svg'), reason: 'Settings');
    // The two the audit found wrong must be gone from the chrome. `folder`
    // still appears — in the folder column, which is what it means there.
    expect(
      assets,
      isNot(contains('cloud.svg')),
      reason: 'the Sync destination no longer uses the cloud glyph',
    );
  });

  testWidgets('FR-016 — the rail carries the app mark, not a key glyph', (
    tester,
  ) async {
    await pumpAt(tester, 1024);
    final assets = glyphAssets(tester).join('\n');

    // 2026-08-30: the rail shows the full-colour mark (verbatim copy of the
    // design master), no longer the tinted monochrome silhouette.
    expect(assets, contains('custode-mark-color.svg'));

    // `key-round` still has a home — the empty detail pane draws it — so the
    // assertion is scoped to the chrome, where it stood in for the mark.
    final chromeAssets = tester
        .widgetList<SvgPicture>(
          find.ancestor(
            of: find.byTooltip('Vault'),
            matching: find.byType(SvgPicture),
          ),
        )
        .followedBy(
          tester.widgetList<SvgPicture>(
            find.descendant(
              of: find.ancestor(
                of: find.byTooltip('Vault'),
                matching: find.byType(Column),
              ),
              matching: find.byType(SvgPicture),
            ),
          ),
        )
        .map((picture) => picture.bytesLoader.toString())
        .join('\n');
    expect(
      chromeAssets,
      isNot(contains('key-round.svg')),
      reason: 'the Lucide key stood in for the mark and no longer appears',
    );
    expect(chromeAssets, contains('custode-mark-color.svg'));
  });

  for (final width in <double>[390, 1024]) {
    testWidgets('FR-018 — the selected destination is filled, at $width', (
      tester,
    ) async {
      await pumpAt(tester, width);

      final fills = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((box) => (box.decoration as BoxDecoration?)?.color)
          .where((color) => color == AppColors.accent200);

      expect(
        fills,
        isNotEmpty,
        reason:
            'the current destination is signalled by a fill, not only by '
            'a colour change on the glyph (C-03-14)',
      );
    });

    testWidgets('FR-018 — and it is still announced, at $width', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAt(tester, width);

      // The fill is in addition to the semantics, never instead of it
      // (Constitution V): colour alone is not a signal.
      final selectedDestinations = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where((widget) => widget.properties.selected ?? false)
          .where((widget) => widget.properties.label == 'Vault');
      expect(
        selectedDestinations,
        isNotEmpty,
        reason: 'the current destination announces itself as selected',
      );

      handle.dispose();
    });
  }
}
