// spec-018 T003/T004 — CHARACTERISATION, not aspiration.
//
// US5 says mobile navigation is correct today and must not regress. These
// tests are written BEFORE any production edit and pass against unmodified
// code. If a later change breaks one, that is a US5 regression (FR-012) and
// the fix is the production code — never this file.
//
// Do not "update" an expectation here to make a build green. The whole value
// of the file is that it predates the change.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

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

  tearDown(resetVaultShellTestDi);

  Future<NavigationFixtureVaultKdbxService> pumpMobileVault(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = NavigationFixtureVaultKdbxService();
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: service),
    );
    await tester.pumpAndSettle();
    return service;
  }

  Future<void> openGmailDetail(WidgetTester tester) async {
    await tester.tap(find.text('Gmail').last);
    await tester.pumpAndSettle();
  }

  // ---- T003: navigation ---------------------------------------------------

  testWidgets('mobile: activating a record opens its detail', (tester) async {
    await pumpMobileVault(tester);

    expect(find.text('Gmail'), findsWidgets);
    expect(find.byKey(const ValueKey('entry-detail-body')), findsNothing);

    await openGmailDetail(tester);

    expect(tester.takeException(), isNull);
    // The detail surface is identifiable by its copy affordance, which the
    // list rows do not have.
    expect(find.byKey(const ValueKey('entry-detail-body')), findsOneWidget);
  });

  testWidgets('mobile: the detail is a pushed route with a back affordance', (
    tester,
  ) async {
    await pumpMobileVault(tester);
    await openGmailDetail(tester);

    final back = find.byTooltip('Back');
    expect(back, findsOneWidget, reason: 'a pushed detail must be poppable');

    await tester.tap(back);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('entry-detail-body')), findsNothing);
    // The list survived the round trip intact.
    expect(find.text('Gmail'), findsWidgets);
    expect(find.text('Banca Sella'), findsWidgets);
  });

  testWidgets('mobile: the bottom tab bar keeps its four destinations', (
    tester,
  ) async {
    await pumpMobileVault(tester);

    for (final label in ['Vault', 'Health', 'Sync', 'Settings']) {
      expect(find.text(label), findsWidgets, reason: '$label destination');
    }
  });

  // ---- T004: record actions ----------------------------------------------

  testWidgets('mobile: Delete from the pushed detail reaches the vault', (
    tester,
  ) async {
    final service = await pumpMobileVault(tester);
    await openGmailDetail(tester);

    await tester.tap(find.byTooltip('Record actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Destructive actions confirm first (Constitution VII).
    expect(find.text('Move this record to recycle bin?'), findsOneWidget);
    expect(
      service.calls,
      isEmpty,
      reason: 'nothing may be written before the user confirms',
    );

    // The confirm button reuses the action's own label ('Delete'), so target
    // the button rather than the text — the overflow menu used that word too.
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      service.calls.map((call) => '${call.kind}:${call.entryId}'),
      contains('delete:${NavigationFixtureVaultKdbxService.gmail.id}'),
      reason: 'the confirmed delete must reach the vault, not be dropped',
    );
  });

  testWidgets('mobile: cancelling Delete writes nothing', (tester) async {
    final service = await pumpMobileVault(tester);
    await openGmailDetail(tester);

    await tester.tap(find.byTooltip('Record actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(service.calls, isEmpty);
  });

  testWidgets(
    'mobile: the record-action menu offers Move, Delete; attachments are a section',
    (tester) async {
      await pumpMobileVault(tester);
      await openGmailDetail(tester);

      // Edit is its own header button; the rest live in the overflow.
      expect(find.byTooltip('Edit'), findsOneWidget);
      // FR-011 as amended by spec 020: attachments are a permanent body
      // section, not an overflow item. Amended 2026-11-13: the section lists
      // the files; the `Manage` dialog is retired.
      expect(find.text('Attachments'), findsOneWidget);
      expect(find.text('No attachments'), findsOneWidget);

      await tester.tap(find.byTooltip('Record actions'));
      await tester.pumpAndSettle();

      expect(find.text('Move'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Attachments'), findsOneWidget);
    },
  );

  testWidgets('mobile: Edit opens the editor for that record', (tester) async {
    await pumpMobileVault(tester);
    await openGmailDetail(tester);

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Save'), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsOneWidget);
  });
}
