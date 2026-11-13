// Attachments read the same wherever a record is shown.
//
// The defect this pins: creating a record listed its attachments inside the
// editor, but editing one showed none of them. The editor opened with an
// empty attachment section, the detail showed only a count, and the files
// themselves lived behind a separate `Manage` dialog. A file picked while
// editing was listed and then dropped on save, because the update never
// carried it.
//
// Omitted axes (VR-002): behavioural, light theme only.
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetVaultShellTestDi);

  Future<NavigationFixtureVaultKdbxService> pumpAt(
    WidgetTester tester,
    double width,
  ) async {
    tester.view.physicalSize = Size(width, 900);
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

  Future<void> openRecord(WidgetTester tester, String title) async {
    // Below the folder-column widths the list shows one folder at a time, and
    // the record with attachments lives in `Devs`.
    if (find.text(title).evaluate().isEmpty) {
      await tester.tap(find.text('Devs').first);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Edit').last);
    await tester.pumpAndSettle();
  }

  // One column (390), two columns (708, 1024) and three (1280).
  const widths = <double>[390, 708, 1024, 1280];

  group('the detail lists the files, not only their count', () {
    for (final width in widths) {
      testWidgets('at $width both files are named with their size', (
        tester,
      ) async {
        await pumpAt(tester, width);
        await openRecord(tester, 'GitHub');

        expect(find.text('id_ed25519.pub'), findsOneWidget);
        expect(find.text('recovery-codes.txt'), findsOneWidget);
        expect(find.text('98 B'), findsOneWidget);
        expect(find.byTooltip('Export attachment'), findsNWidgets(2));
        // No second surface to manage them from.
        expect(find.text('Manage'), findsNothing);
      });

      testWidgets('at $width a record with none says so', (tester) async {
        await pumpAt(tester, width);
        await openRecord(tester, 'Gmail');

        expect(find.text('No attachments'), findsOneWidget);
        expect(find.byTooltip('Export attachment'), findsNothing);
      });
    }
  });

  group('the editor shows what the record already holds', () {
    for (final width in widths) {
      testWidgets('at $width editing lists the existing files', (tester) async {
        await pumpAt(tester, width);
        await openRecord(tester, 'GitHub');
        await openEditor(tester);

        expect(find.text('id_ed25519.pub'), findsOneWidget);
        expect(find.text('recovery-codes.txt'), findsOneWidget);
        expect(find.byTooltip('Remove attachment'), findsNWidgets(2));
        expect(find.byTooltip('Add attachment'), findsOneWidget);
      });
    }

    testWidgets('removing one is staged and applied on save', (tester) async {
      final service = await pumpAt(tester, 1024);
      await openRecord(tester, 'GitHub');
      await openEditor(tester);

      await tester.ensureVisible(find.byTooltip('Remove attachment').first);
      await tester.tap(find.byTooltip('Remove attachment').first);
      await tester.pumpAndSettle();

      // Staged: gone from the form, nothing written yet.
      expect(find.text('id_ed25519.pub'), findsNothing);
      expect(find.text('recovery-codes.txt'), findsOneWidget);
      expect(service.calls, isEmpty);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(service.calls.map((call) => call.kind), [
        'update',
        'removeAttachment',
      ]);
      expect(service.calls.last.entryId, 'entry-github');
      expect(service.calls.last.fields, {'key': 'ssh'});
      // Back on the detail, which now lists the one that is left.
      expect(find.text('id_ed25519.pub'), findsNothing);
      expect(find.text('recovery-codes.txt'), findsOneWidget);
    });

    testWidgets('cancelling a staged removal keeps the file', (tester) async {
      final service = await pumpAt(tester, 1024);
      await openRecord(tester, 'GitHub');
      await openEditor(tester);

      await tester.ensureVisible(find.byTooltip('Remove attachment').first);
      await tester.tap(find.byTooltip('Remove attachment').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(service.calls, isEmpty);
      expect(find.text('id_ed25519.pub'), findsOneWidget);
    });
  });

  // The system file picker has no test double, so the pick itself is not
  // driven here. What is pinned is the half that was missing: an update that
  // carries a picked file attaches it. Before, `UpdateVaultEntry` had no such
  // field and a file picked while editing was listed and then dropped.
  testWidgets('an update attaches the files it carries', (tester) async {
    final service = await pumpAt(tester, 1024);
    await openRecord(tester, 'GitHub');

    tester
        .element(find.byKey(const ValueKey('vault-detail-pane')))
        .read<VaultBloc>()
        .add(
          const UpdateVaultEntry(
            entryId: 'entry-github',
            title: 'GitHub',
            username: 'dev',
            password: 'Sample-Pass-2b!x',
            url: 'github.com',
            notes: '',
            attachmentPaths: ['/tmp/backup-codes.txt'],
            removedAttachmentKeys: ['recovery'],
          ),
        );
    await tester.pumpAndSettle();

    // Removals first, so a replaced file never collides with its old copy.
    expect(service.calls.map((call) => call.kind), [
      'update',
      'removeAttachment',
      'addAttachment',
    ]);
    expect(service.calls.last.fields, {'path': '/tmp/backup-codes.txt'});
  });

  group('the record menu no longer opens a separate attachments surface', () {
    for (final width in <double>[650, 1024]) {
      testWidgets('at $width a list row offers no Attachments item', (
        tester,
      ) async {
        await pumpAt(tester, width);
        await tester.tap(find.byTooltip('Record actions').first);
        await tester.pumpAndSettle();

        expect(find.text('Edit'), findsWidgets);
        expect(find.text('Attachments'), findsNothing);
      });
    }
  });
}
