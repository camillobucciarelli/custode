// spec 015 T014: widget assertions for the two-step wizard — the three key
// modes, the optional password with and without confirmation, the invalid
// name blocking step 1, and a failure that keeps the wizard mounted with
// its draft intact. These replace per-state goldens; the spec names the
// omitted axes (1024x768, dark) in its golden inventory.
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/theme/app_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/screens/create_database_screen.dart';

import 'database_selection_unlock_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(resetDatabaseTestDi);

  Future<void> pumpWizard(WidgetTester tester) async {
    final result = await pumpableCreateDatabaseScreen();
    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();
  }

  Future<void> pumpWebWizard(WidgetTester tester) async {
    final result = await pumpableCreateDatabaseScreen(webMode: true);
    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();
  }

  Future<void> goToCredentials(WidgetTester tester) async {
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  group('FR-8 name validation blocks step 1', () {
    testWidgets('an invalid character disables Continue and shows the error', (
      tester,
    ) async {
      await pumpWizard(tester);

      await tester.enterText(find.byType(TextFormField), 'bad:name.kdbx');
      await tester.pumpAndSettle();

      expect(find.text('Invalid characters in file name.'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(
        button.onPressed,
        isNull,
        reason: 'FR-8: no silent sanitisation — the step must not advance',
      );

      // Still on step 1 even if something tried to advance.
      expect(find.text('Name your database'), findsOneWidget);
    });

    testWidgets('a valid name advances to the single credentials step', (
      tester,
    ) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      expect(find.text('Choose your credentials'), findsOneWidget);
      expect(find.text('Step 2 of 2'), findsOneWidget);
    });
  });

  group('FR-3 optional password', () {
    testWidgets('empty password: no confirmation field, no strength meter, '
        'and the inert submit states why', (tester) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      expect(find.text('Confirm Password'), findsNothing);
      expect(find.text('Weak'), findsNothing);
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
      expect(
        find.text(
          'Set a master password or choose a key file to protect the '
          'database.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('non-empty password: confirmation mandatory, mismatch shown '
        'at the field', (tester) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'kv-test-only-not-a-real-password',
      );
      await tester.pumpAndSettle();

      expect(find.text('Confirm Password'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).at(1), 'different');
      await tester.pumpAndSettle();

      expect(find.text('Passwords do not match.'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);

      await tester.enterText(
        find.byType(TextFormField).at(1),
        'kv-test-only-not-a-real-password',
      );
      await tester.pumpAndSettle();
      final enabled = tester.widget<ElevatedButton>(
        find.byType(ElevatedButton),
      );
      expect(enabled.onPressed, isNotNull);
    });
  });

  group('FR-4 three-way key control', () {
    testWidgets('the three modes are mutually exclusive radio options', (
      tester,
    ) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      expect(find.text('No key file'), findsOneWidget);
      expect(find.text('Select an existing file'), findsOneWidget);
      expect(find.text('Generate automatically'), findsOneWidget);
      expect(find.byType(RadioListTile<KeyFileMode>), findsNWidgets(3));
    });

    testWidgets('generate mode is a factor by itself and shows the permanent '
        'FR-13 backup warning inline', (tester) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      await tester.tap(find.text('Generate automatically'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Back up the generated key file: losing it makes the database '
          'inaccessible.',
        ),
        findsOneWidget,
      );
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(
        button.onPressed,
        isNotNull,
        reason: 'FR-2: a generated key file is a valid sole factor',
      );
    });

    testWidgets('switching back to "No key file" removes the key factor', (
      tester,
    ) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      await tester.tap(find.text('Generate automatically'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No key file'));
      await tester.pumpAndSettle();

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
    });
  });

  group('FR-10/FR-11 failure keeps the wizard mounted', () {
    testWidgets('a refused submission renders in the wizard with the draft '
        'intact', (tester) async {
      await pumpWizard(tester);
      await tester.enterText(find.byType(TextFormField), 'MyVault.kdbx');
      await tester.pumpAndSettle();
      await goToCredentials(tester);

      // FR-11 refusal: biometrics on with no password to store.
      await tester.tap(find.text('Generate automatically'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable biometric protection'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      // Wizard still mounted, on the credentials step, with the message.
      expect(find.byType(CreateDatabaseScreen), findsOneWidget);
      expect(find.text('Choose your credentials'), findsOneWidget);
      expect(
        find.textContaining('Biometric unlock needs a master password'),
        findsOneWidget,
      );

      // Draft intact: going back shows the typed name.
      await tester.tap(find.byIcon(AppIcons.back));
      await tester.pumpAndSettle();
      expect(find.text('MyVault.kdbx'), findsOneWidget);
    });
  });

  group('FR-14 web download-only path (T021/T022)', () {
    testWidgets('no biometric step, keeps-nothing notice, and the two-gesture '
        'order: database download stays blocked until the key download is '
        'requested', (tester) async {
      await pumpWebWizard(tester);
      await goToCredentials(tester);

      expect(find.text('Enable biometric protection'), findsNothing);
      expect(
        find.textContaining('Reloading the page loses this draft'),
        findsOneWidget,
      );

      await tester.tap(find.text('Generate automatically'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare downloads'));
      await tester.pumpAndSettle();

      // Download phase: key first, database gated.
      expect(find.text('Download key file'), findsOneWidget);
      final databaseButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Download database'),
      );
      expect(
        databaseButton.onPressed,
        isNull,
        reason:
            'FR-14: creation stays blocked until the key download has '
            'been requested',
      );
      expect(
        find.textContaining('Download the key file first'),
        findsOneWidget,
      );
    });

    testWidgets('password-only on web needs no key gesture and persists '
        'nothing', (tester) async {
      await pumpWebWizard(tester);
      await goToCredentials(tester);

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'kv-test-only-not-a-real-password',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'kv-test-only-not-a-real-password',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare downloads'));
      await tester.pumpAndSettle();

      expect(find.text('Download key file'), findsNothing);
      final databaseButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Download database'),
      );
      expect(databaseButton.onPressed, isNotNull);
    });
  });
}
