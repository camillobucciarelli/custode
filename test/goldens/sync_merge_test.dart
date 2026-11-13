// spec-008 T606 — the exact 12-entry golden inventory from FR-11.
//
// One case table; `cases.length == 12` is asserted before any case runs and
// every filename is matched exactly. Dynamic behaviour is NOT captured here —
// it lives in the named widget assertions (T608).
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_merge_models.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';
import 'package:password_manager/features/password_manager/domain/services/sync_merge_policy.dart';

import '../features/password_manager/presentation/widgets/sync/sync_merge_screen_fixtures.dart';

enum _Scenario {
  review,
  fieldText,
  fieldSecret,
  fieldAttachment,
  ready,
  recovery,
  scale,
}

typedef _Case = ({String name, _Scenario scenario, Size size, ThemeMode theme});

const _phone = Size(390, 844);
const _tablet = Size(1024, 768);

const cases = <_Case>[
  (
    name: 'sync_merge_review_phone_light.png',
    scenario: _Scenario.review,
    size: _phone,
    theme: ThemeMode.light,
  ),
  (
    name: 'sync_merge_review_phone_dark.png',
    scenario: _Scenario.review,
    size: _phone,
    theme: ThemeMode.dark,
  ),
  (
    name: 'sync_merge_field_text_phone_light.png',
    scenario: _Scenario.fieldText,
    size: _phone,
    theme: ThemeMode.light,
  ),
  (
    name: 'sync_merge_field_secret_phone_dark.png',
    scenario: _Scenario.fieldSecret,
    size: _phone,
    theme: ThemeMode.dark,
  ),
  (
    name: 'sync_merge_field_attachment_phone_light.png',
    scenario: _Scenario.fieldAttachment,
    size: _phone,
    theme: ThemeMode.light,
  ),
  (
    name: 'sync_merge_ready_phone_light.png',
    scenario: _Scenario.ready,
    size: _phone,
    theme: ThemeMode.light,
  ),
  (
    name: 'sync_merge_recovery_phone_dark.png',
    scenario: _Scenario.recovery,
    size: _phone,
    theme: ThemeMode.dark,
  ),
  (
    name: 'sync_merge_scale_phone_light.png',
    scenario: _Scenario.scale,
    size: _phone,
    theme: ThemeMode.light,
  ),
  (
    name: 'sync_merge_review_tablet_light.png',
    scenario: _Scenario.review,
    size: _tablet,
    theme: ThemeMode.light,
  ),
  (
    name: 'sync_merge_review_tablet_dark.png',
    scenario: _Scenario.review,
    size: _tablet,
    theme: ThemeMode.dark,
  ),
  (
    name: 'sync_merge_field_tablet_light.png',
    scenario: _Scenario.fieldText,
    size: _tablet,
    theme: ThemeMode.light,
  ),
  (
    name: 'sync_merge_ready_tablet_light.png',
    scenario: _Scenario.ready,
    size: _tablet,
    theme: ThemeMode.light,
  ),
];

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

  test('the golden case table has exactly 12 entries with unique names', () {
    expect(cases.length, 12);
    expect(cases.map((c) => c.name).toSet().length, 12);
  });

  for (final testCase in cases) {
    testWidgets(testCase.name, (tester) async {
      await setMergeTestSize(tester, testCase.size);
      final harness = MergeScreenHarness(
        decisions: testCase.scenario == _Scenario.scale
            ? scaleDecisions()
            : null,
      );
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.app(themeMode: testCase.theme));
      await harness.startReview(tester);

      switch (testCase.scenario) {
        case _Scenario.review:
        case _Scenario.scale:
          break;
        case _Scenario.fieldText:
          await tester.tap(find.text('Notes'));
          await tester.pumpAndSettle();
        case _Scenario.fieldSecret:
          await tester.tap(find.textContaining('Credentials'));
          await tester.pumpAndSettle();
        case _Scenario.fieldAttachment:
          await tester.tap(find.text('Attachment'));
          await tester.pumpAndSettle();
        case _Scenario.ready:
          harness.bloc.add(
            const ApplySyncMergeShortcut(MergeShortcut.preferLocal),
          );
          await tester.pumpAndSettle();
        case _Scenario.recovery:
          harness.port.commitOutcome = const MergeRejected(
            MergeFailureCode.uploadOutcomeAmbiguous,
            localCommitCompleted: true,
          );
          harness.bloc.add(
            const ApplySyncMergeShortcut(MergeShortcut.preferLocal),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Merge and sync'));
          await tester.pumpAndSettle();
      }

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(testCase.name),
      );
    });
  }
}
