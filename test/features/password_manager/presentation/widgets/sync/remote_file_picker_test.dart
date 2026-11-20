import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/widgets/kv_bottom_sheet.dart';
import 'package:password_manager/features/password_manager/domain/errors/google_authorization_required_exception.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file_selection_data.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/drive_picker_skeleton.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/remote_file_picker.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/remote_file_row.dart';

import '../../coordinators/fake_database_ports.dart';
import '../../screens/database_selection_unlock_test_utils.dart';

/// Records the order of connection calls, with scriptable failures.
class _RecordingSyncRepository extends FakeDatabaseSyncRepository {
  final List<String> calls = [];
  Object? connectError;
  Object? listError;

  @override
  Future<void> connect() async {
    calls.add('connect');
    final error = connectError;
    if (error != null) throw error;
    await super.connect();
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    await super.disconnect();
  }

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) async {
    calls.add('list');
    final error = listError;
    if (error != null) throw error;
    return super.listRemoteFiles(query: query);
  }
}

const _family = RemoteFile(
  providerId: 'google_drive',
  id: 'f-family',
  name: 'Family.kdbx',
  size: 48000,
);
const _personal = RemoteFile(
  providerId: 'google_drive',
  id: 'f-personal',
  name: 'Personal.kdbx',
);

void main() {
  tearDown(resetDatabaseTestDi);

  /// Hosts `pickRemoteFile` behind a button so the real DI path is used.
  Future<List<RemoteFile?>> open(
    WidgetTester tester,
    FakeDatabaseSyncRepository sync,
  ) async {
    await pumpableSelectionScreen(syncRepository: sync);
    final results = <RemoteFile?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(await pickRemoteFile(context)),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    return results;
  }

  testWidgets('loading shows skeleton rows, then the files', (tester) async {
    final sync = _RecordingSyncRepository()
      ..connected = true
      ..remoteFiles = const [_family];
    await open(tester, sync);
    await tester.pump();

    expect(find.byType(DrivePickerSkeletonRow), findsWidgets);

    await tester.pumpAndSettle();
    expect(find.byType(DrivePickerSkeletonRow), findsNothing);
    expect(find.text('Open from Google Drive'), findsOneWidget);
    expect(find.text('Family.kdbx'), findsOneWidget);
    // Copy contract: sentence case, so a screen reader does not spell it.
    expect(find.text('Google account'), findsOneWidget);
    expect(find.text('GOOGLE ACCOUNT'), findsNothing);
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(
      tester.getSemantics(find.text('Open from Google Drive')),
      isSemantics(isHeader: true),
    );
    handle.dispose();
    expect(find.text('Search .kdbx files'), findsOneWidget);
    expect(find.textContaining('KB'), findsOneWidget);
    expect(
      find.text(
        'Custode only reads the file you pick. Your master password never '
        'leaves this device.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('empty offers Switch account and no create and upload', (
    tester,
  ) async {
    final sync = _RecordingSyncRepository()..connected = true;
    await open(tester, sync);
    await tester.pumpAndSettle();

    expect(
      find.text('No .kdbx files found for Google Drive account.'),
      findsOneWidget,
    );
    expect(find.text('Create & upload a new database'), findsNothing);
    expect(
      find.widgetWithText(ElevatedButton, 'Create & upload'),
      findsNothing,
    );
    expect(find.text('Switch account'), findsNWidgets(2));
  });

  testWidgets('Already added marks files whose (providerId, id) is mapped', (
    tester,
  ) async {
    final sync = _RecordingSyncRepository()
      ..connected = true
      ..remoteFiles = const [_family, _personal]
      ..mappings['/db/personal.kdbx'] = const DatabaseSyncMapping(
        databasePath: '/db/personal.kdbx',
        providerId: 'google_drive',
        remoteFileId: 'f-personal',
        remoteFileName: 'Personal.kdbx',
      )
      // Same opaque id under another provider is not "already added".
      ..mappings['/db/other.kdbx'] = const DatabaseSyncMapping(
        databasePath: '/db/other.kdbx',
        providerId: 'other_provider',
        remoteFileId: 'f-family',
        remoteFileName: 'Family.kdbx',
      );
    await open(tester, sync);
    await tester.pumpAndSettle();

    final rows = tester
        .widgetList<RemoteFileRow>(find.byType(RemoteFileRow))
        .toList();
    expect(
      {for (final r in rows) r.file.id: r.alreadyAdded},
      {'f-family': false, 'f-personal': true},
    );
    expect(find.text('Already added'), findsOneWidget);
  });

  testWidgets('tapping a file returns it', (tester) async {
    final sync = _RecordingSyncRepository()
      ..connected = true
      ..remoteFiles = const [_family];
    final results = await open(tester, sync);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Family.kdbx'));
    await tester.pumpAndSettle();

    expect(results, [_family]);
  });

  testWidgets('search narrows the list by name', (tester) async {
    final sync = _RecordingSyncRepository()
      ..connected = true
      ..remoteFiles = const [_family, _personal];
    await open(tester, sync);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'pers');
    await tester.pumpAndSettle();

    expect(find.text('Family.kdbx'), findsNothing);
    expect(find.text('Personal.kdbx'), findsOneWidget);
  });

  testWidgets('Switch account disconnects, reconnects, then lists again', (
    tester,
  ) async {
    final sync = _RecordingSyncRepository()
      ..connected = true
      ..remoteFiles = const [_family];
    await open(tester, sync);
    await tester.pumpAndSettle();
    sync.calls.clear();

    await tester.tap(find.text('Switch account'));
    await tester.pumpAndSettle();

    expect(sync.calls, ['disconnect', 'connect', 'list']);
    expect(find.text('Family.kdbx'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a cancelled sign-in leaves the sheet disconnected with the '
      'typed copy and Retry', (tester) async {
    final sync = _RecordingSyncRepository()
      ..connected = true
      ..remoteFiles = const [_family];
    await open(tester, sync);
    await tester.pumpAndSettle();
    sync.connectError = Exception('Google sign-in cancelled.');

    await tester.tap(find.text('Switch account'));
    await tester.pumpAndSettle();

    expect(sync.connected, isFalse);
    expect(
      find.text(
        'Google sign-in was cancelled during authorization. Please try again '
        'and grant Drive permissions.',
      ),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);

    sync.connectError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Family.kdbx'), findsOneWidget);
  });

  testWidgets('an expired grant offers Reconnect, which connects again', (
    tester,
  ) async {
    final sync = _RecordingSyncRepository()
      ..connected = true
      ..listError = const GoogleAuthorizationRequiredException();
    await open(tester, sync);
    await tester.pumpAndSettle();

    expect(find.text('Google authorization expired'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);

    sync
      ..listError = null
      ..remoteFiles = const [_family];
    await tester.tap(find.text('Reconnect'));
    await tester.pumpAndSettle();

    expect(sync.connectCalls, 1);
    expect(find.text('Family.kdbx'), findsOneWidget);
  });

  testWidgets('a mapping lookup failure never blocks choosing a file', (
    tester,
  ) async {
    await pumpableSelectionScreen();
    final results = <RemoteFile?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await KvBottomSheet.show<RemoteFile>(
                context: context,
                builder: (_) => RemoteFilePickerSheet(
                  load: () async => const RemoteFileSelectionData(
                    files: [_family],
                    account: StorageAccountSummary(displayLabel: 'Drive'),
                  ),
                  reconnect: () => Completer<RemoteFileSelectionData>().future,
                  switchAccount: () =>
                      Completer<RemoteFileSelectionData>().future,
                  loadMappings: () async => throw Exception('metadata'),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Family.kdbx'), findsOneWidget);
    expect(find.text('Already added'), findsNothing);
  });
}
