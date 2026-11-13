// `closeWhen`, added for spec 023's passkey prompts: a confirmation whose
// subject stops being true while the user is reading it must not stay on
// screen. The passkey request behind such a dialog has its own deadline, and a
// dialog whose positive action does nothing is worse than no dialog.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/widgets/kv_confirm_dialog.dart';

void main() {
  Future<(Future<bool?>, ValueNotifier<bool>)> open(WidgetTester tester) async {
    final close = ValueNotifier<bool>(false);
    late Future<bool?> answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => answer = showKvConfirmDialog(
              context,
              title: 'Sign in to example.com?',
              body: 'A page is asking to sign in.',
              confirmLabel: 'Sign in',
              closeWhen: close,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (answer, close);
  }

  testWidgets('the dialog closes itself, resolving null', (tester) async {
    final (answer, close) = await open(tester);
    expect(find.text('Sign in'), findsOneWidget);

    close.value = true;
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsNothing);
    // `null`, the same as a dismissal: nothing was chosen.
    expect(await answer, isNull);
    close.dispose();
  });

  testWidgets('false does not close it', (tester) async {
    final (_, close) = await open(tester);

    close.value = false;
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    close.dispose();
  });

  testWidgets('a dialog with no signal behaves as before', (tester) async {
    late Future<bool?> answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => answer = showKvConfirmDialog(
              context,
              title: 'Delete?',
              body: 'This cannot be undone.',
              confirmLabel: 'Delete',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(await answer, isTrue);
  });

  testWidgets('a signal that fires after the answer pops nothing', (
    tester,
  ) async {
    final (answer, close) = await open(tester);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);

    // The request expiring a moment after the user answered must not pop the
    // route that is now on top — the screen the user came back to.
    close.value = true;
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    close.dispose();
  });
}
