// spec-006 T6/T15/AC8: the iOS enablement screen's "what is shared"
// disclosure must match the fields `AppleAutofillV2Coordinator` actually
// publishes to `SharedAutofillStore` — verified against the REAL payload
// (`AppleAutofillV2Credential.toChannelMap()`), not a hand-typed parallel
// list that could silently drift out of sync (the risk plan.md calls out:
// "The 'not passwords' claim on the iOS screen drifts from reality").
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/services/apple_autofill_v2_payload_mapper.dart';
import 'package:password_manager/features/password_manager/presentation/screens/autofill_enablement_screen.dart';

void main() {
  group('AC8: published-payload keys vs. the screen\'s disclosed fields', () {
    test('AutofillEnablementScreen.sharedFieldKeys equals the real '
        'AppleAutofillV2Credential.toChannelMap() key set', () {
      const mapper = AppleAutofillV2PayloadMapper();
      const entry = VaultEntry(
        id: 'e1',
        groupId: 'root',
        title: 'GitHub',
        username: 'camillo@bucciarelli.dev',
        password: 'super-secret-password',
        url: 'https://github.com',
        notes: 'must not be published',
      );

      final credential = mapper.mapEntry(entry);
      expect(credential, isNotNull);
      final publishedKeys = credential!.toChannelMap().keys.toSet();

      // The literal, structural guard: if a dev ever adds/renames a field
      // on the wire (e.g. nests the password under a different key, or
      // adds a new sensitive field) without updating the screen's
      // disclosure, this fails — same for the reverse (the screen
      // claiming a field that isn't actually sent).
      expect(
        AutofillEnablementScreen.sharedFieldKeys,
        publishedKeys,
        reason:
            'AutofillEnablementScreen.sharedFieldKeys must name every key '
            'AppleAutofillV2Credential.toChannelMap() actually publishes '
            '(currently: $publishedKeys) — update both together.',
      );

      // The specific, non-negotiable check this test exists for: the
      // payload DOES include a password today (the Credential Provider
      // extension needs it on-device to fill it), so the claim must not
      // hide that fact.
      expect(
        publishedKeys.contains('password'),
        isTrue,
        reason:
            'Sanity check on the fixture entry itself — if this ever '
            'becomes false because the mapper changed, the "password" '
            'key must be removed from sharedFieldKeys too.',
      );
    });
  });

  group('AutofillEnablementScreen', () {
    testWidgets('discloses passwords explicitly, not a "not passwords" claim', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const AutofillEnablementScreen(entryCount: 42),
        ),
      );
      await tester.pumpAndSettle();

      // AC8 anti-regression: must NOT ship the literal, now-known-false
      // claim from tasks.md ("not passwords").
      expect(find.textContaining('not passwords'), findsNothing);

      // Must positively disclose that a password copy is kept + how it is
      // protected (Face ID gate), not just titles/usernames/sites.
      expect(find.textContaining('password'), findsWidgets);
      expect(find.textContaining('biometrics'), findsWidgets);
      expect(find.textContaining('42 titles'), findsOneWidget);
    });
  });
}
