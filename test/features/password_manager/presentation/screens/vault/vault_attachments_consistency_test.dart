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
import 'package:file_picker/file_picker.dart';
// The plugin does not export its platform interface, which is its only seam
// for standing in for the system picker.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

/// Stands in for the system picker: hands back the queued file paths in
/// order, and one directory.
class _FakeFilePicker extends FilePickerPlatform {
  _FakeFilePicker({this.files = const [], this.directory});

  final List<String> files;
  final String? directory;
  var _next = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    final path = files[_next++];
    return FilePickerResult([
      PlatformFile(path: path, name: path.split('/').last, size: 12),
    ]);
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetVaultShellTestDi);

  void usePicker(_FakeFilePicker picker) {
    final original = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
  }

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

  testWidgets('the detail exports one file to the chosen folder', (
    tester,
  ) async {
    usePicker(_FakeFilePicker(directory: '/tmp/exports'));
    final service = await pumpAt(tester, 1024);
    await openRecord(tester, 'GitHub');

    await tester.ensureVisible(find.byTooltip('Export attachment').last);
    await tester.tap(find.byTooltip('Export attachment').last);
    await tester.pumpAndSettle();

    expect(service.calls.map((call) => call.kind), ['exportAttachment']);
    expect(service.calls.single.entryId, 'entry-github');
    expect(service.calls.single.fields, {
      'key': 'recovery',
      'directory': '/tmp/exports',
    });
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

      // One write carries the fields and the removal together.
      expect(service.calls.map((call) => call.kind), ['update']);
      expect(service.calls.single.entryId, 'entry-github');
      expect(service.calls.single.fields['removed'], 'ssh');
      // Back on the detail, which now lists the one that is left.
      expect(find.text('id_ed25519.pub'), findsNothing);
      expect(find.text('recovery-codes.txt'), findsOneWidget);
    });

    // The reported defect, end to end: a file picked while editing was listed
    // in the form and then dropped by the save.
    testWidgets('a file picked while editing is saved with the record', (
      tester,
    ) async {
      usePicker(
        _FakeFilePicker(
          files: ['/tmp/backup-codes.txt', '/tmp/backup-codes.txt'],
        ),
      );
      final service = await pumpAt(tester, 1024);
      await openRecord(tester, 'GitHub');
      await openEditor(tester);

      await tester.ensureVisible(find.byTooltip('Add attachment'));
      await tester.tap(find.byTooltip('Add attachment'));
      await tester.pumpAndSettle();
      expect(find.text('backup-codes.txt'), findsOneWidget);
      expect(find.text('Added when you save'), findsOneWidget);

      // Picking the same file again does not list it twice.
      await tester.ensureVisible(find.byTooltip('Add attachment'));
      await tester.tap(find.byTooltip('Add attachment'));
      await tester.pumpAndSettle();
      expect(find.text('backup-codes.txt'), findsOneWidget);
      expect(service.calls, isEmpty);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(service.calls.map((call) => call.kind), ['update']);
      expect(service.calls.single.fields['added'], '/tmp/backup-codes.txt');
      expect(service.calls.single.fields.containsKey('removed'), isFalse);
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
  // carries a picked file hands it to the same write as the fields. Before,
  // `UpdateVaultEntry` had no such field and a file picked while editing was
  // listed and then dropped.
  const updateWithAttachments = UpdateVaultEntry(
    entryId: 'entry-github',
    title: 'GitHub',
    username: 'dev',
    password: 'Sample-Pass-2b!x',
    url: 'github.com',
    notes: '',
    attachmentPaths: ['/tmp/backup-codes.txt'],
    removedAttachmentKeys: ['recovery'],
  );

  VaultBloc blocOf(WidgetTester tester) => tester
      .element(find.byKey(const ValueKey('vault-detail-pane')))
      .read<VaultBloc>();

  testWidgets('an update writes its attachment changes with the fields', (
    tester,
  ) async {
    final service = await pumpAt(tester, 1024);
    await openRecord(tester, 'GitHub');

    blocOf(tester).add(updateWithAttachments);
    await tester.pumpAndSettle();

    // A single write: one save, one history revision, all or nothing.
    expect(service.calls.map((call) => call.kind), ['update']);
    expect(service.calls.single.fields['added'], '/tmp/backup-codes.txt');
    expect(service.calls.single.fields['removed'], 'recovery');
  });

  testWidgets('a failed update says so and keeps the files', (tester) async {
    final service = await pumpAt(tester, 1024);
    await openRecord(tester, 'GitHub');
    service.updateFailure = Exception('Attachment source file not found.');

    final bloc = blocOf(tester);
    final errors = <String?>[];
    final subscription = bloc.stream.listen(
      (state) => errors.add(state.errorMessage),
    );
    addTearDown(subscription.cancel);
    bloc.add(updateWithAttachments);
    await tester.pumpAndSettle();

    expect(errors, contains('Unable to update entry.'));
    expect(find.text('id_ed25519.pub'), findsOneWidget);
    expect(find.text('recovery-codes.txt'), findsOneWidget);
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
