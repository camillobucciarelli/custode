// Copilot review fix (spec-005 PR #9): `_selectedId` in
// `_RemoteFilePickerScreenState` used to only ever be assigned once
// (`_selectedId ??= state.remoteFiles.first.id`). If the user typed a
// search query that removed the currently-selected file from the list, the
// stale id survived — no row showed as selected, yet "Link" stayed enabled
// and would have completed with an id no longer visible to the user.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/features/password_manager/domain/models/cloud_storage_error.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/errors/google_authorization_required_exception.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_conflict.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/google_drive_reconnect_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/remote_file_row.dart';
import 'package:password_manager/injection_container.dart' as di;

import '../../coordinators/fake_database_ports.dart';
import 'vault_shell_test_utils.dart';

const _fileA = RemoteFile(
  providerId: 'google_drive',
  id: 'a1',
  name: 'Alpha.kdbx',
);
const _fileB = RemoteFile(
  providerId: 'google_drive',
  id: 'b1',
  name: 'Beta.kdbx',
);

void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Connected but not-yet-linked repo so the Sync tab renders the "Pick an
/// existing .kdbx" entry point. `listRemoteFiles` filters by query the same
/// way the real Drive API search would, so typing in the search box can
/// remove a file from the list — the scenario the fix targets.
class _FakeUnlinkedSyncRepository extends FakeDatabaseSyncRepository {
  @override
  Future<bool> isConnected() async => true;

  @override
  Future<DatabaseSyncMapping?> getMapping(String databasePath) async => null;

  @override
  Future<List<DatabaseSyncMapping>> getAllMappings() async => const [];

  @override
  Future<StorageAccountSummary> getConnectedAccount() async =>
      const StorageAccountSummary(displayLabel: 'Google Drive account');

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) async {
    const all = [_fileA, _fileB];
    if (query == null || query.isEmpty) return all;
    return all
        .where((f) => f.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
  }
}

/// spec 010 T105: another database linked to the same opaque id under a
/// different provider (`a1`) and one linked to the same tuple (`b1`).
class _LinkedElsewhereSyncRepository extends _FakeUnlinkedSyncRepository {
  @override
  Future<List<DatabaseSyncMapping>> getAllMappings() async => const [
    DatabaseSyncMapping(
      databasePath: '/other/one.kdbx',
      providerId: 'other_provider_zz',
      remoteFileId: 'a1',
      remoteFileName: 'Alpha.kdbx',
      autoSyncEnabled: true,
    ),
    DatabaseSyncMapping(
      databasePath: '/other/two.kdbx',
      providerId: 'google_drive',
      remoteFileId: 'b1',
      remoteFileName: 'Beta.kdbx',
      autoSyncEnabled: true,
    ),
  ];
}

class _RecoveringUnlinkedSyncRepository extends _FakeUnlinkedSyncRepository {
  int listCalls = 0;
  int authorizationFailures = 1;
  Object authorizationError = const GoogleAuthorizationRequiredException();
  final queries = <String?>[];
  Object? connectError;
  Completer<void>? connectGate;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    await connectGate?.future;
    if (connectError != null) throw connectError!;
  }

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) async {
    listCalls += 1;
    queries.add(query);
    if (listCalls <= authorizationFailures) {
      throw authorizationError;
    }
    return super.listRemoteFiles(query: query);
  }
}

class _BackgroundReconnectSyncRepository extends FakeDatabaseSyncRepository {
  _BackgroundReconnectSyncRepository() {
    connected = true;
    mappings[kTestDatabasePath] = const DatabaseSyncMapping(
      databasePath: kTestDatabasePath,
      providerId: 'google_drive',
      remoteFileId: 'remote-1',
      remoteFileName: 'Vault.kdbx',
      autoSyncEnabled: true,
    );
  }

  int syncCalls = 0;
  Completer<void>? connectGate;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    await connectGate?.future;
    connected = true;
  }

  @override
  Future<SyncNowResult> syncNow(
    String databasePath, {
    SyncConflictResolution? resolution,
  }) async {
    syncCalls += 1;
    if (syncCalls == 1) {
      throw const GoogleAuthorizationRequiredException();
    }
    return const SyncNowSuccess();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    await (FontLoader(
      'Caprasimo',
    )..addFont(rootBundle.load('assets/fonts/Caprasimo-Regular.ttf'))).load();
    await (FontLoader('Figtree')
          ..addFont(rootBundle.load('assets/fonts/Figtree-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-Bold.ttf')))
        .load();
  });

  testWidgets(
    'stale selection is dropped when the filtered list no longer contains it',
    (tester) async {
      addTearDown(resetVaultShellTestDi);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        await pumpableVaultShell(
          databaseSyncRepository: _FakeUnlinkedSyncRepository(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pick an existing .kdbx'));
      await tester.pumpAndSettle();

      // Nothing is pre-selected — Link is contextual to a selected row and
      // must not exist yet (2026-08-31 redesign: no default selection).
      expect(
        tester
            .widgetList<RemoteFileRow>(find.byType(RemoteFileRow))
            .where((r) => r.selected),
        isEmpty,
      );
      expect(find.byTooltip('Link this file'), findsNothing);

      // User selects Beta — its row now carries the contextual Link button.
      await tester.tap(find.text('Beta.kdbx'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<RemoteFileRow>(find.byType(RemoteFileRow))
            .where((r) => r.selected)
            .single
            .file
            .id,
        'b1',
      );
      expect(find.byTooltip('Link this file'), findsOneWidget);

      // User types a query that filters Beta out of the results.
      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.pumpAndSettle();

      // Beta's row is gone entirely — the stale id must not survive.
      expect(find.text('Beta.kdbx'), findsNothing);
      final rows = tester.widgetList<RemoteFileRow>(find.byType(RemoteFileRow));
      expect(rows, hasLength(1));
      // The stale selection is dropped, nothing looks chosen, and the
      // contextual Link button is gone with it.
      expect(rows.single.selected, isFalse);
      expect(find.byTooltip('Link this file'), findsNothing);
    },
  );

  testWidgets(
    'stale selection is dropped when the filtered list becomes completely '
    'empty (not just narrowed) — "Link" must disable, not stay wired to a '
    'file no longer in the list at all',
    (tester) async {
      addTearDown(resetVaultShellTestDi);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        await pumpableVaultShell(
          databaseSyncRepository: _FakeUnlinkedSyncRepository(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pick an existing .kdbx'));
      await tester.pumpAndSettle();

      // Select Alpha so there is a live selection to go stale.
      await tester.tap(find.text('Alpha.kdbx'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<RemoteFileRow>(find.byType(RemoteFileRow))
            .where((r) => r.selected)
            .single
            .file
            .id,
        'a1',
      );

      // A query that matches nothing empties the list entirely — the
      // isEmpty early-return branch, not just a narrower non-empty list.
      await tester.enterText(find.byType(TextField), 'zzz-no-match');
      await tester.pumpAndSettle();

      expect(find.text('No .kdbx files found.'), findsOneWidget);
      expect(find.byType(RemoteFileRow), findsNothing);

      // The stale 'a1' selection must be cleared even though the isEmpty
      // branch returns before reaching the old post-check location — no
      // contextual Link button may survive pointing at an invisible file.
      expect(find.byTooltip('Link this file'), findsNothing);
    },
  );

  testWidgets(
    'auth-expired picker stays open and reconnect retries list once',
    (tester) async {
      addTearDown(resetVaultShellTestDi);
      _usePhoneViewport(tester);
      final repository = _RecoveringUnlinkedSyncRepository()
        ..remoteFiles = const [_fileA];

      await tester.pumpWidget(
        await pumpableVaultShell(databaseSyncRepository: repository),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick an existing .kdbx'));
      await tester.pumpAndSettle();

      expect(find.text('Link to a Drive file'), findsOneWidget);
      expect(find.text('Google authorization expired'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);

      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();

      expect(repository.connectCalls, 1);
      expect(repository.listCalls, 2);
      expect(find.text('Link to a Drive file'), findsOneWidget);
      expect(find.text('Alpha.kdbx'), findsOneWidget);
    },
  );

  testWidgets('picker reconnect failure stays open and Retry can succeed', (
    tester,
  ) async {
    addTearDown(resetVaultShellTestDi);
    _usePhoneViewport(tester);
    final repository = _RecoveringUnlinkedSyncRepository()
      ..remoteFiles = const [_fileA]
      ..connectError = Exception('Google sign-in cancelled.');

    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repository),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick an existing .kdbx'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Link to a Drive file'), findsOneWidget);
    expect(find.text('Google sign-in cancelled.'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Retry Google Drive connection'),
      findsOneWidget,
    );

    repository.connectError = null;
    await tester.tap(find.bySemanticsLabel('Retry Google Drive connection'));
    await tester.pumpAndSettle();

    expect(repository.connectCalls, 2);
    expect(repository.listCalls, 2);
    expect(find.text('Alpha.kdbx'), findsOneWidget);
  });

  testWidgets('linked-elsewhere compares the (providerId, id) tuple', (
    tester,
  ) async {
    addTearDown(resetVaultShellTestDi);
    _usePhoneViewport(tester);

    await tester.pumpWidget(
      await pumpableVaultShell(
        databaseSyncRepository: _LinkedElsewhereSyncRepository(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick an existing .kdbx'));
    await tester.pumpAndSettle();

    final rows = {
      for (final row in tester.widgetList<RemoteFileRow>(
        find.byType(RemoteFileRow),
      ))
        row.file.id: row.isLinkedElsewhere,
    };
    expect(rows, {'a1': false, 'b1': true});
    expect(find.text('Linked'), findsOneWidget);
  });

  testWidgets('typed authorizationRequired offers picker reconnect', (
    tester,
  ) async {
    addTearDown(resetVaultShellTestDi);
    _usePhoneViewport(tester);
    final repository = _RecoveringUnlinkedSyncRepository()
      ..remoteFiles = const [_fileA]
      ..authorizationError = const CloudStorageException(
        CloudStorageErrorCode.authorizationRequired,
      );

    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repository),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick an existing .kdbx'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Reconnect Google Drive'), findsOneWidget);
    expect(find.text('Google authorization expired'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
    await tester.pumpAndSettle();
    expect(repository.connectCalls, 1);
    expect(find.text('Alpha.kdbx'), findsOneWidget);
  });

  testWidgets('rapid picker reconnect taps start one connect', (tester) async {
    addTearDown(resetVaultShellTestDi);
    _usePhoneViewport(tester);
    final repository = _RecoveringUnlinkedSyncRepository()
      ..remoteFiles = const [_fileA]
      ..connectGate = Completer<void>();

    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repository),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick an existing .kdbx'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reconnect'));
    await tester.tap(find.text('Reconnect'));
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .hideCurrentSnackBar();
    await tester.pump();

    expect(repository.connectCalls, 1);
    expect(find.bySemanticsLabel('Reconnect Google Drive'), findsOneWidget);
    expect(find.text('Google authorization expired'), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Reconnecting...'),
          )
          .onPressed,
      isNull,
    );
    // The contextual Link button only exists on a selected row — during an
    // auth error the list (and any selection) is gone with it.
    expect(find.byTooltip('Link this file'), findsNothing);

    // Unrelated BLoC traffic must not complete this auth gesture or re-enable
    // another OAuth launch while the first operation is pending.
    final bloc = tester
        .element(find.text('Link to a Drive file'))
        .read<VaultBloc>();
    bloc.add(const ClearVaultInfo());
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
    expect(repository.connectCalls, 1);

    repository.connectGate!.complete();
    await tester.pumpAndSettle();
    expect(repository.listCalls, 2);
  });

  testWidgets(
    'query stays local during auth error and Link cannot close picker',
    (tester) async {
      addTearDown(resetVaultShellTestDi);
      _usePhoneViewport(tester);
      final repository = _RecoveringUnlinkedSyncRepository()
        ..remoteFiles = const [_fileA];

      await tester.pumpWidget(
        await pumpableVaultShell(databaseSyncRepository: repository),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick an existing .kdbx'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.pumpAndSettle();

      expect(repository.listCalls, 1);
      expect(find.text('Google authorization expired'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Reconnect Google Drive',
        ),
        findsOneWidget,
      );
      // No contextual Link button exists while the auth error is showing —
      // nothing can close the picker but Back or a successful reconnect.
      expect(find.byTooltip('Link this file'), findsNothing);
      expect(find.text('Link to a Drive file'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
      await tester.pumpAndSettle();

      expect(repository.queries, [null, 'Alpha']);
      expect(find.text('Alpha.kdbx'), findsOneWidget);
    },
  );

  testWidgets('second auth failure stays inline without automatic loop', (
    tester,
  ) async {
    addTearDown(resetVaultShellTestDi);
    _usePhoneViewport(tester);
    final repository = _RecoveringUnlinkedSyncRepository()
      ..authorizationFailures = 2;

    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repository),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick an existing .kdbx'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
    await tester.pumpAndSettle();

    expect(repository.connectCalls, 1);
    expect(repository.listCalls, 2);
    expect(find.text('Google authorization expired'), findsOneWidget);
    expect(find.bySemanticsLabel('Reconnect Google Drive'), findsOneWidget);
  });

  testWidgets('closing picker while auth is pending prevents list retry', (
    tester,
  ) async {
    addTearDown(resetVaultShellTestDi);
    _usePhoneViewport(tester);
    final repository = _RecoveringUnlinkedSyncRepository()
      ..connectGate = Completer<void>();

    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repository),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick an existing .kdbx'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
    await tester.pump();
    await tester.tap(find.byType(IconButton).first);
    await tester.pumpAndSettle();

    repository.connectGate!.complete();
    await tester.pumpAndSettle();

    expect(repository.connectCalls, 1);
    expect(repository.listCalls, 1);
    expect(find.text('Link to a Drive file'), findsNothing);
  });

  testWidgets(
    'closed picker does not suppress hero continuation sharing its auth',
    (tester) async {
      addTearDown(resetVaultShellTestDi);
      _usePhoneViewport(tester);
      final repository = _RecoveringUnlinkedSyncRepository()
        ..connectGate = Completer<void>();

      await tester.pumpWidget(
        await pumpableVaultShell(databaseSyncRepository: repository),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick an existing .kdbx'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
      await tester.pump();
      await tester.tap(find.byType(IconButton).first);
      await tester.pumpAndSettle();

      final bloc = tester.element(find.text('Sync').last).read<VaultBloc>();
      final heroContinuation = di
          .sl<GoogleDriveReconnectCoordinator>()
          .reconnect(
            owner: Object(),
            bloc: bloc,
            continuation: GoogleDriveReconnectContinuation.resumeSync,
            isOwnerActive: () => true,
          );
      expect(repository.connectCalls, 1);

      repository.connectGate!.complete();
      await heroContinuation;
      await tester.pumpAndSettle();

      expect(repository.listCalls, 1);
      expect(find.text('Reconnect'), findsNothing);
    },
  );

  testWidgets('snackbar reconnect performs one connect and one resume sync', (
    tester,
  ) async {
    addTearDown(resetVaultShellTestDi);
    _usePhoneViewport(tester);
    final repository = _BackgroundReconnectSyncRepository();

    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repository),
    );
    await tester.pumpAndSettle();

    expect(repository.syncCalls, 1);
    expect(repository.connectCalls, 0);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Reconnect'));
    await tester.pumpAndSettle();

    expect(repository.connectCalls, 1);
    expect(repository.syncCalls, 2);
  });

  testWidgets(
    'rapid hero reconnect survives unrelated state and resumes once',
    (tester) async {
      addTearDown(resetVaultShellTestDi);
      _usePhoneViewport(tester);
      final repository = _BackgroundReconnectSyncRepository()
        ..connectGate = Completer<void>();

      await tester.pumpWidget(
        await pumpableVaultShell(databaseSyncRepository: repository),
      );
      await tester.pumpAndSettle();
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reconnect'));
      await tester.tap(find.text('Reconnect'));
      final bloc = tester.element(find.text('Sync').last).read<VaultBloc>();
      bloc.add(const ClearVaultInfo());
      await tester.pump();

      expect(repository.connectCalls, 1);
      expect(repository.syncCalls, 1);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Reconnect Google Drive',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Reconnecting...'),
            )
            .onPressed,
        isNull,
      );

      repository.connectGate!.complete();
      await tester.pumpAndSettle();
      expect(repository.connectCalls, 1);
      expect(repository.syncCalls, 2);
    },
  );

  testWidgets('background auth expiry waits for tap then resumes sync once', (
    tester,
  ) async {
    addTearDown(resetVaultShellTestDi);
    _usePhoneViewport(tester);
    final repository = _BackgroundReconnectSyncRepository();

    await tester.pumpWidget(
      await pumpableVaultShell(databaseSyncRepository: repository),
    );
    await tester.pumpAndSettle();

    expect(repository.syncCalls, 1);
    expect(repository.connectCalls, 0);

    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();
    expect(find.text('Reconnect'), findsOneWidget);

    await tester.tap(find.text('Reconnect'));
    await tester.pumpAndSettle();

    expect(repository.connectCalls, 1);
    expect(repository.syncCalls, 2);
  });
}
