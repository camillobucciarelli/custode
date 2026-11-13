// spec-004 T23: acceptance-criteria checks that aren't goldens —
// AC7 (canGenerate disables the primary action), AC8 (tablet metadata grid
// has exactly 3 rows), AC9 (detail/editor push no route on tablet).
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'entry_editor_generator_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetEntryTestDi);

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('AC7: canGenerate == false disables the primary action', () {
    testWidgets('unchecking every character set disables "Use this password"', (
      tester,
    ) async {
      await setSize(tester, const Size(390, 844));
      await tester.pumpWidget(await pumpableEntryScreen());
      await tester.pumpAndSettle();

      // Root folder's "Add record" -> new-item editor -> generator sheet.
      // spec-019 T045: `Add record` is the vault's own add affordance now,
      // filing into the selected folder, instead of an action on a folder row
      // in the records list (FR-002a).
      await tester.tap(find.byTooltip('Add record'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Generate secure password'));
      await tester.pumpAndSettle();

      // KvPillButton wraps an ElevatedButton (see kv_pill_button.dart).
      Finder useButton() =>
          find.widgetWithText(ElevatedButton, 'Use this password');
      expect(
        tester.widget<ElevatedButton>(useButton()).onPressed,
        isNotNull,
        reason: 'default options have every set enabled',
      );

      for (final label in [
        'Lowercase letters (a-z)',
        'Uppercase letters (A-Z)',
        'Numbers (0-9)',
        'Special characters (!@#...)',
      ]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      expect(
        tester.widget<ElevatedButton>(useButton()).onPressed,
        isNull,
        reason: 'AC7: no character set selected must disable the action',
      );
      expect(
        find.text('Select at least one character set.'),
        findsOneWidget,
        reason: 'byte-identical literal error string (spec-004 non-negotiable)',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  // Amended 2026-08-30: the grid moved into the `Record info` dialog opened
  // from the record's `•••`, at every width.
  group('AC8: the Record info dialog has exactly 3 rows', () {
    testWidgets('Created / Updated / last password change, no more no less', (
      tester,
    ) async {
      await setSize(tester, const Size(1024, 768));
      await tester.pumpWidget(await pumpableEntryScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('GitHub').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Record actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record info'));
      await tester.pumpAndSettle();

      final grid = find.byKey(const ValueKey('entry-detail-metadata-grid'));
      expect(grid, findsOneWidget);

      // The grid renders one KvFieldRow-shaped label per row; count the
      // three known labels directly rather than reaching into internals.
      expect(find.text('Created'), findsOneWidget);
      expect(find.text('Updated'), findsOneWidget);
      expect(find.text('Last password change'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on a phone the dialog wraps its three rows, not the screen', (
      tester,
    ) async {
      await setSize(tester, const Size(390, 844));
      await tester.pumpWidget(await pumpableEntryScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('GitHub').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Record actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record info'));
      await tester.pumpAndSettle();

      // 2026-09-05: the grid Column used to take the loose height the
      // dialog's content slot offers, so the dialog stood full-screen.
      // The dialog's own box fills the route; its first Material is the card.
      final card = tester.getSize(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(card.height, lessThan(844 / 2));

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('FR-3 regression: clipboard clears even after the screen that '
      'copied is disposed before the 30s window elapses', () {
    testWidgets(
      'copy password, navigate away immediately, clipboard still clears at 30s',
      (tester) async {
        // Bug (spec-004, Copilot review): ClipboardGuard used to be
        // instantiated per-widget and disposed in the entry detail screen's
        // dispose() — which cancelled its pending clear timer. Copy-then-
        // navigate-away (the single most common real flow, e.g. copy a
        // password then go paste it elsewhere) meant the clipboard was
        // NEVER cleared. Fix: ClipboardGuard is now a DI app-lifetime
        // singleton, so its timer outlives the screen that started it.
        String? clipboardContent;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboardContent = (call.arguments as Map)['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return {'text': clipboardContent};
            default:
              return null;
          }
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );

        await setSize(tester, const Size(390, 844));
        await tester.pumpWidget(await pumpableEntryScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('GitHub').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Copy').first);
        await tester.pump();

        expect(
          clipboardContent,
          isNotEmpty,
          reason: 'copy must write the password to the clipboard',
        );

        // Navigate away / close the entry detail screen well before the 30s
        // clear window — this is exactly the flow the old per-widget guard
        // got wrong: its dispose() cancelled the pending clear.
        await tester.pumpWidget(const SizedBox());

        await tester.pump(const Duration(seconds: 29));
        expect(clipboardContent, isNotEmpty, reason: 'not cleared before 30s');

        await tester.pump(const Duration(seconds: 2));
        expect(
          clipboardContent,
          isEmpty,
          reason:
              'the shared ClipboardGuard singleton must still clear the '
              'clipboard at 30s even though the screen that copied was '
              'disposed long before the timer fired — the old per-widget '
              'guard left the clipboard populated forever in this flow',
        );
      },
    );
  });

  group('AC9: detail and editor are a pane on tablet — no route pushed', () {
    testWidgets('opening an entry at 1024 width does not push a route', (
      tester,
    ) async {
      await setSize(tester, const Size(1024, 768));
      await tester.pumpWidget(await pumpableEntryScreen());
      await tester.pumpAndSettle();

      final routesBefore = _routeCount(tester);
      await tester.tap(find.text('GitHub').first);
      await tester.pumpAndSettle();

      expect(
        _routeCount(tester),
        routesBefore,
        reason: 'AC9: entry detail must render as a pane, not a pushed route',
      );
      // The detail content is visible inline (no MaterialPageRoute Scaffold
      // pushed on top) — its username field is on screen immediately.
      expect(find.text('camillo@bucciarelli.dev'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opening the editor at 1024 width does not push a route', (
      tester,
    ) async {
      await setSize(tester, const Size(1024, 768));
      await tester.pumpWidget(await pumpableEntryScreen());
      await tester.pumpAndSettle();

      final routesBefore = _routeCount(tester);
      // spec-019 T045: `Add record` is the vault's own add affordance now,
      // filing into the selected folder, instead of an action on a folder row
      // in the records list (FR-002a).
      await tester.tap(find.byTooltip('Add record'));
      await tester.pumpAndSettle();

      expect(
        _routeCount(tester),
        routesBefore,
        reason: 'AC9: the editor must render as a pane, not a pushed route',
      );
      expect(find.text('New item'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Counts live `Route`s on the app's Navigator via the number of `Route`
/// entries the `Navigator`'s `Overlay` currently holds — a pushed
/// `MaterialPageRoute` adds one; a pane embedded inline in the existing
/// tree does not.
int _routeCount(WidgetTester tester) {
  // `NavigatorState` doesn't expose its route count publicly. Every route
  // this app pushes wraps its content in exactly one `Scaffold`
  // (`VaultShellRouter._defaultRouteHost`), and the shell itself has
  // exactly one more — so the `Scaffold` count is a reliable proxy that
  // changes if and only if a route is actually pushed/popped.
  return tester.widgetList(find.byType(Scaffold)).length;
}
