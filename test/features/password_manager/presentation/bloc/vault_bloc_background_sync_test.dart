import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpStatus, SocketException;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:password_manager/features/password_manager/data/datasources/google_token_data_source.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_oauth_pkce_service.dart';
import 'package:password_manager/features/password_manager/data/services/drive_auth_service.dart';
import 'package:password_manager/features/password_manager/data/services/google_drive_api_service.dart';
import 'package:password_manager/features/password_manager/data/services/google_oauth_config.dart';
import 'package:password_manager/features/password_manager/domain/errors/google_authorization_required_exception.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_csv_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_duplicate_service.dart';
import 'package:password_manager/features/password_manager/domain/models/apple_autofill_v2_models.dart';
import 'package:password_manager/features/password_manager/domain/models/cloud_storage_error.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_status.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/domain/models/sync_conflict.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_event.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_state.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_database_now_usecase.dart';

void main() {
  _autoSyncAfterMutationTests();

  group('VaultState background sync fields', () {
    test('isSyncing defaults to false', () {
      final state = VaultState(databasePath: '/db.kdbx');
      expect(state.isSyncing, isFalse);
    });

    test('isSyncReloadPending defaults to false', () {
      final state = VaultState(databasePath: '/db.kdbx');
      expect(state.isSyncReloadPending, isFalse);
    });

    test('copyWith sets isSyncing', () {
      final state = VaultState(databasePath: '/db.kdbx');
      expect(state.copyWith(isSyncing: true).isSyncing, isTrue);
    });

    test('copyWith sets isSyncReloadPending', () {
      final state = VaultState(databasePath: '/db.kdbx');
      expect(
        state.copyWith(isSyncReloadPending: true).isSyncReloadPending,
        isTrue,
      );
    });

    test('clearSyncReloadPending resets isSyncReloadPending to false', () {
      final state = VaultState(
        databasePath: '/db.kdbx',
        isSyncReloadPending: true,
      );
      expect(
        state.copyWith(clearSyncReloadPending: true).isSyncReloadPending,
        isFalse,
      );
    });

    test('isSyncing change makes states non-equal', () {
      final a = VaultState(databasePath: '/db.kdbx', isSyncing: true);
      final b = VaultState(databasePath: '/db.kdbx', isSyncing: false);
      expect(a, isNot(equals(b)));
    });

    test('isSyncReloadPending change makes states non-equal', () {
      final a = VaultState(databasePath: '/db.kdbx', isSyncReloadPending: true);
      final b = VaultState(
        databasePath: '/db.kdbx',
        isSyncReloadPending: false,
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('BackgroundDriveSync event', () {
    test('two instances are equal', () {
      expect(const BackgroundDriveSync(), equals(const BackgroundDriveSync()));
    });
  });

  test(
    'reconnect failure event preserves stack without exposing diagnostics',
    () {
      final stackTrace = StackTrace.current;
      final event = GoogleDriveReconnectFailed(
        error: Exception('raw-provider-detail'),
        stackTrace: stackTrace,
        remoteFiles: false,
      );

      expect(identical(event.stackTrace, stackTrace), isTrue);
      expect(event.toString(), isNot(contains('raw-provider-detail')));
    },
  );

  group('ConnectGoogleDrive error copy', () {
    test('an unrecognized Google failure keeps its platform code and '
        'description instead of collapsing to the generic sentence', () async {
      final repo = _FakeSyncRepo()
        ..connectError = Exception(
          'Google sign-in failed (uiUnavailable): No Activity is available',
        );
      final bloc = _makeBloc(repo, _FakeVaultKdbxService());
      addTearDown(bloc.close);

      bloc.add(const ConnectGoogleDrive());
      await _waitUntil(() => bloc.state.syncStatus == DatabaseSyncStatus.error);

      final error = bloc.state.syncError!;
      expect(error, contains('uiUnavailable'));
      expect(error, contains('No Activity is available'));
      expect(error, isNot(contains('Exception:')));
    });

    test('recognized failures keep their existing copy', () async {
      final repo = _FakeSyncRepo()
        ..connectError = Exception('Google sign-in cancelled.');
      final bloc = _makeBloc(repo, _FakeVaultKdbxService());
      addTearDown(bloc.close);

      bloc.add(const ConnectGoogleDrive());
      await _waitUntil(() => bloc.state.syncStatus == DatabaseSyncStatus.error);

      expect(bloc.state.syncError, 'Google sign-in cancelled.');
    });
  });

  group('Apple autofill lifecycle', () {
    test('publishes after vault is loaded', () async {
      final repo = _FakeSyncRepo()..mapping = _testMapping;
      final kdbx = _FakeVaultKdbxService();
      final appleAutofill = _FakeAppleAutofillV2Coordinator();
      final bloc = _makeBloc(
        repo,
        kdbx,
        appleAutofillV2Coordinator: appleAutofill,
      );
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      await _waitUntil(() => appleAutofill.publishCallCount > 0);

      expect(appleAutofill.lastDatabasePath, _kDbPath);
      expect(appleAutofill.lastEntries, _emptySnapshot.allEntries);
    });
  });

  group('Apple autofill pending associations', () {
    test('confirm empty URL sets URL and clears pending', () async {
      final entry = _entry(url: '');
      final kdbx = _FakeVaultKdbxService()
        ..snapshot = _snapshotWithEntry(entry);
      final pending = _pendingAssociation(
        serviceIdentifierType: 'url',
        serviceIdentifierValue: 'https://Example.com/login?x=1#frag',
      );
      final appleAutofill = _FakeAppleAutofillV2Coordinator()
        ..pendingAssociations = [pending];
      final bloc = _makeBloc(
        _FakeSyncRepo(),
        kdbx,
        appleAutofillV2Coordinator: appleAutofill,
      );
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      await _waitUntil(
        () => bloc.state.pendingAppleAutofillAssociations.length == 1,
      );

      bloc.add(ConfirmAppleAutofillPendingAssociation(pending.id));
      await _waitUntil(
        () =>
            kdbx.updateCallCount == 1 &&
            appleAutofill.clearPendingCallCount == 1 &&
            bloc.state.pendingAppleAutofillAssociations.isEmpty,
      );

      expect(kdbx.lastUpdatedEntryId, entry.id);
      expect(kdbx.lastUpdatedTitle, entry.title);
      expect(kdbx.lastUpdatedUsername, entry.username);
      expect(kdbx.lastUpdatedUrl, 'https://example.com');
      expect(kdbx.lastUpdatedNotes, entry.notes);
      expect(kdbx.lastUpdatedCustomFields, isEmpty);
      expect(appleAutofill.lastClearedPendingIds, [pending.id]);
    });

    test('confirm existing URL adds KPH URL and preserves URL', () async {
      final entry = _entry(
        url: 'https://existing.example/login',
        customFields: const [VaultCustomField(key: 'note', value: 'keep')],
      );
      final kdbx = _FakeVaultKdbxService()
        ..snapshot = _snapshotWithEntry(entry);
      final pending = _pendingAssociation(
        serviceIdentifierType: 'domain',
        serviceIdentifierValue: 'Example.com/path?x=1#frag',
      );
      final appleAutofill = _FakeAppleAutofillV2Coordinator()
        ..pendingAssociations = [pending];
      final bloc = _makeBloc(
        _FakeSyncRepo(),
        kdbx,
        appleAutofillV2Coordinator: appleAutofill,
      );
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      await _waitUntil(
        () => bloc.state.pendingAppleAutofillAssociations.length == 1,
      );

      bloc.add(ConfirmAppleAutofillPendingAssociation(pending.id));
      await _waitUntil(
        () =>
            kdbx.updateCallCount == 1 &&
            appleAutofill.clearPendingCallCount == 1 &&
            bloc.state.pendingAppleAutofillAssociations.isEmpty,
      );

      expect(kdbx.lastUpdatedUrl, entry.url);
      expect(kdbx.lastUpdatedCustomFields, [
        const VaultCustomField(key: 'note', value: 'keep'),
        const VaultCustomField(key: 'KPH: URL', value: 'example.com'),
      ]);
      expect(appleAutofill.lastClearedPendingIds, [pending.id]);
    });

    test('confirm Android package adds KPH androidPackage', () async {
      final entry = _entry(
        url: 'https://existing.example/login',
        customFields: const [VaultCustomField(key: 'note', value: 'keep')],
      );
      final kdbx = _FakeVaultKdbxService()
        ..snapshot = _snapshotWithEntry(entry);
      final pending = _pendingAssociation(
        serviceIdentifierType: 'androidPackage',
        serviceIdentifierValue:
            'androidapp://Com.Example.App/path?token=secret#frag',
      );
      final appleAutofill = _FakeAppleAutofillV2Coordinator()
        ..pendingAssociations = [pending];
      final bloc = _makeBloc(
        _FakeSyncRepo(),
        kdbx,
        appleAutofillV2Coordinator: appleAutofill,
      );
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      await _waitUntil(
        () => bloc.state.pendingAppleAutofillAssociations.length == 1,
      );

      bloc.add(ConfirmAppleAutofillPendingAssociation(pending.id));
      await _waitUntil(
        () =>
            kdbx.updateCallCount == 1 &&
            appleAutofill.clearPendingCallCount == 1 &&
            bloc.state.pendingAppleAutofillAssociations.isEmpty,
      );

      expect(kdbx.lastUpdatedUrl, entry.url);
      expect(kdbx.lastUpdatedCustomFields, [
        const VaultCustomField(key: 'note', value: 'keep'),
        const VaultCustomField(
          key: 'KPH: androidPackage',
          value: 'com.example.app',
        ),
      ]);
      expect(appleAutofill.lastClearedPendingIds, [pending.id]);
    });

    test('confirm iOS bundle adds sanitized KPH iosBundle', () async {
      final entry = _entry(
        url: 'https://existing.example/login',
        customFields: const [VaultCustomField(key: 'note', value: 'keep')],
      );
      final kdbx = _FakeVaultKdbxService()
        ..snapshot = _snapshotWithEntry(entry);
      final pending = _pendingAssociation(
        serviceIdentifierType: 'bundleId',
        serviceIdentifierValue:
            'iosbundleid://Com.Example.Ios/path?token=secret#frag',
        platform: 'ios',
      );
      final appleAutofill = _FakeAppleAutofillV2Coordinator()
        ..pendingAssociations = [pending];
      final bloc = _makeBloc(
        _FakeSyncRepo(),
        kdbx,
        appleAutofillV2Coordinator: appleAutofill,
      );
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      await _waitUntil(
        () => bloc.state.pendingAppleAutofillAssociations.length == 1,
      );

      bloc.add(ConfirmAppleAutofillPendingAssociation(pending.id));
      await _waitUntil(
        () =>
            kdbx.updateCallCount == 1 &&
            appleAutofill.clearPendingCallCount == 1 &&
            bloc.state.pendingAppleAutofillAssociations.isEmpty,
      );

      expect(kdbx.lastUpdatedUrl, entry.url);
      expect(kdbx.lastUpdatedCustomFields, [
        const VaultCustomField(key: 'note', value: 'keep'),
        const VaultCustomField(key: 'KPH: iosBundle', value: 'com.example.ios'),
      ]);
      expect(
        kdbx.lastUpdatedCustomFields.toString(),
        isNot(contains('token=secret')),
      );
      expect(appleAutofill.lastClearedPendingIds, [pending.id]);
    });

    test(
      'confirm duplicate platform association only clears pending',
      () async {
        final entry = _entry(
          url: 'https://existing.example/login',
          customFields: const [
            VaultCustomField(
              key: 'KPH: androidPackage',
              value: 'com.example.app',
            ),
          ],
        );
        final kdbx = _FakeVaultKdbxService()
          ..snapshot = _snapshotWithEntry(entry);
        final pending = _pendingAssociation(
          serviceIdentifierType: 'androidPackage',
          serviceIdentifierValue: 'Com.Example.App',
          platform: 'android',
        );
        final appleAutofill = _FakeAppleAutofillV2Coordinator()
          ..pendingAssociations = [pending];
        final bloc = _makeBloc(
          _FakeSyncRepo(),
          kdbx,
          appleAutofillV2Coordinator: appleAutofill,
        );
        addTearDown(bloc.close);

        bloc.add(const InitializeVault());
        await _waitUntil(
          () => bloc.state.pendingAppleAutofillAssociations.length == 1,
        );

        bloc.add(ConfirmAppleAutofillPendingAssociation(pending.id));
        await _waitUntil(
          () =>
              appleAutofill.clearPendingCallCount == 1 &&
              bloc.state.pendingAppleAutofillAssociations.isEmpty,
        );

        expect(kdbx.updateCallCount, 0);
        expect(appleAutofill.lastClearedPendingIds, [pending.id]);
      },
    );

    test('reject clears pending and does not update', () async {
      final entry = _entry(url: '');
      final kdbx = _FakeVaultKdbxService()
        ..snapshot = _snapshotWithEntry(entry);
      final pending = _pendingAssociation();
      final appleAutofill = _FakeAppleAutofillV2Coordinator()
        ..pendingAssociations = [pending];
      final bloc = _makeBloc(
        _FakeSyncRepo(),
        kdbx,
        appleAutofillV2Coordinator: appleAutofill,
      );
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      await _waitUntil(
        () => bloc.state.pendingAppleAutofillAssociations.length == 1,
      );

      bloc.add(RejectAppleAutofillPendingAssociation(pending.id));
      await _waitUntil(
        () =>
            appleAutofill.clearPendingCallCount == 1 &&
            bloc.state.pendingAppleAutofillAssociations.isEmpty,
      );

      expect(kdbx.updateCallCount, 0);
      expect(appleAutofill.lastClearedPendingIds, [pending.id]);
    });
  });

  group('InitializeVault — session secret (spec-011 FR-1/FR-2)', () {
    test('an absent session secret fails with the locked-state error and '
        'never opens the vault with an empty password', () async {
      final repo = _FakeSyncRepo();
      final kdbx = _FakeVaultKdbxService();
      // Holder deliberately left empty: session is locked.
      final bloc = _makeBloc(
        repo,
        kdbx,
        sessionSecretHolder: SessionSecretHolder(),
      );
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      // Waits for the failure to actually surface instead of sleeping for a
      // fixed 30ms: this is the FR-1/FR-2 guard that the vault is never opened
      // with an empty password, so it must not be able to pass by sampling
      // before the handler ran.
      await _waitUntil(() => bloc.state.errorMessage != null);

      expect(bloc.state.errorMessage, 'Unable to load vault credentials.');
      expect(bloc.state.isLoading, isFalse);
      expect(kdbx.loadCallCount, 0);
    });

    test('a populated session secret is used to load the vault', () async {
      final repo = _FakeSyncRepo();
      final kdbx = _FakeVaultKdbxService();
      final bloc = _makeBloc(
        repo,
        kdbx,
        sessionSecretHolder: SessionSecretHolder()..set('pw'),
      );
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      await _waitUntil(() => bloc.state.currentGroupId == 'root');

      expect(bloc.state.errorMessage, isNull);
      expect(kdbx.loadCallCount, greaterThanOrEqualTo(1));
    });
  });

  group('InitializeVault — Drive check deferred', () {
    late _FakeSyncRepo repo;
    late _FakeVaultKdbxService kdbx;
    late VaultBloc bloc;

    setUp(() {
      repo = _FakeSyncRepo()..mapping = _testMapping;
      kdbx = _FakeVaultKdbxService();
      bloc = _makeBloc(repo, kdbx);
    });

    tearDown(() async => bloc.close());

    test('vault loads (loadVault called) without network Drive check during init', () async {
      // isConnectedResult is false, but mapping exists.
      // InitializeVault must NOT call isConnected() — if it did,
      // isDriveConnected would be set to false and syncStatus to disconnected.
      // Instead, preload from local mapping sets isDriveLinked: true, syncStatus: idle.
      bloc.add(const InitializeVault());
      await _waitUntil(() => bloc.state.currentGroupId == 'root');

      expect(kdbx.loadCallCount, greaterThanOrEqualTo(1));
      expect(bloc.state.isDriveLinked, isTrue);
      expect(bloc.state.syncStatus, equals(DatabaseSyncStatus.idle));
      expect(bloc.state.isLoading, isFalse);
    });
  });

  test('cleanup failure still surfaces authorization renewal during Drive list load', () async {
    http.Request? refreshRequest;
    final httpClient = MockClient((request) async {
      refreshRequest = request;
      return http.Response(
        jsonEncode({'error': 'invalid_grant'}),
        HttpStatus.badRequest,
      );
    });
    addTearDown(httpClient.close);

    final storedTokens = _StoredGoogleTokenDataSource(
      DesktopOAuthTokenSet(
        accessToken: 'expired-access-token',
        refreshToken: 'old-client-refresh-token',
        expiresAt: DateTime.utc(2000),
      ).toJson(),
      throwOnClear: true,
    );
    final auth = DriveAuthService(
      config: const GoogleOAuthConfig(
        mobileClientId: null,
        androidServerClientId: null,
        desktopClientId: 'current-client-id',
        desktopClientSecret: 'current-client-secret',
      ),
      googleTokenDataSource: storedTokens,
      desktopOAuthPkceService: DesktopOAuthPkceService(httpClient: httpClient),
      isDesktopOverride: true,
    );
    final api = GoogleDriveApiService(
      driveAuthService: auth,
      httpClient: httpClient,
    );
    final repo = _FakeSyncRepo()
      ..mapping = _testMapping.copyWith(autoSyncEnabled: false)
      ..isConnectedResult = true
      ..listRemoteFilesOverride = (_) async {
        await api.listKdbxFilesInDrive();
        fail('token refresh must fail before any listing is returned');
      };
    final bloc = _makeBloc(repo, _FakeVaultKdbxService());
    addTearDown(bloc.close);

    bloc.add(const BackgroundDriveSync());
    await _waitUntil(
      () => bloc.state.isDriveConnected && bloc.state.isDriveLinked,
    );
    bloc.add(const LoadRemoteFiles());
    await _waitUntil(() => bloc.state.remoteFilesError != null);

    final request = refreshRequest;
    expect(request, isNotNull);
    expect(request!.url.host, 'oauth2.googleapis.com');
    expect(Uri.splitQueryString(request.body), {
      'client_id': 'current-client-id',
      'client_secret': 'current-client-secret',
      'grant_type': 'refresh_token',
      'refresh_token': 'old-client-refresh-token',
    });
    expect(storedTokens.value, isNotNull);
    expect(bloc.state.isDriveConnected, isFalse);
    expect(bloc.state.isDriveLinked, isFalse);
    expect(
      bloc.state.remoteFilesError,
      'Google authorization expired. Reconnect Google Drive to continue.',
    );
    expect(bloc.state.remoteFilesReconnectRequired, isTrue);
  });

  group('BackgroundDriveSync', () {
    late _FakeSyncRepo repo;
    late _FakeVaultKdbxService kdbx;
    late VaultBloc bloc;

    setUp(() {
      repo = _FakeSyncRepo()
        ..mapping = _testMapping
        ..isConnectedResult = true;
      kdbx = _FakeVaultKdbxService();
      bloc = _makeBloc(repo, kdbx);
    });

    tearDown(() async => bloc.close());

    test(
      'emits isSyncing: true then false when connected and linked',
      () async {
        final states = <VaultState>[];
        final sub = bloc.stream.listen(states.add);

        bloc.add(const BackgroundDriveSync());
        // The full cycle is observable: isSyncing goes true, then back to
        // false in the `finally`. Waiting for both edges beats sleeping for a
        // fixed 30ms and hoping the cycle fitted inside it.
        await _waitUntil(
          () => states.any((s) => s.isSyncing) && !bloc.state.isSyncing,
        );
        await sub.cancel();

        expect(states.any((s) => s.isSyncing), isTrue);
        expect(states.last.isSyncing, isFalse);
      },
    );

    test('never emits syncStatus: syncing during background sync', () async {
      final states = <VaultState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(const BackgroundDriveSync());
      await _waitUntil(
        () => states.any((s) => s.isSyncing) && !bloc.state.isSyncing,
      );
      await sub.cancel();

      expect(
        states.any((s) => s.syncStatus == DatabaseSyncStatus.syncing),
        isFalse,
      );
    });

    test('does not emit isSyncing when not connected', () async {
      repo.isConnectedResult = false;
      final states = <VaultState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(const BackgroundDriveSync());
      // Not connected: the handler emits the refreshed Drive state and returns
      // before `isSyncing` is ever set. That single emission is the anchor —
      // the negative assertion below is only meaningful once it has landed.
      await _waitUntil(() => states.isNotEmpty);
      await sub.cancel();

      expect(states.any((s) => s.isSyncing), isFalse);
    });

    test('reloads vault after successful sync when not saving', () async {
      // kdbx.loadCallCount starts at 0 (no InitializeVault fired)
      bloc.add(const BackgroundDriveSync());
      await _waitUntil(() => kdbx.loadCallCount >= 1 && !bloc.state.isSyncing);

      // _reload is called: loadVault must have been called at least once
      expect(kdbx.loadCallCount, greaterThanOrEqualTo(1));
      expect(bloc.state.isSyncReloadPending, isFalse);
    });

    test('runs deferred sync reload after save completes', () async {
      final operations = <String>[];
      final repo = _FakeSyncRepo()
        ..mapping = _testMapping
        ..isConnectedResult = true;
      final kdbx = _FakeVaultKdbxService(operations: operations);
      final bloc = _makeBloc(repo, kdbx);
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      // Wait for init AND the background sync cycle it kicks off to finish,
      // so `operations.clear()` cannot run while that cycle is still writing
      // to the list. `loadCallCount == 2` is init's load plus the background
      // reload; a fixed sleep here only approximated the same thing.
      await _waitUntil(
        () =>
            bloc.state.currentGroupId == 'root' &&
            kdbx.loadCallCount >= 2 &&
            !bloc.state.isSyncing,
      );
      operations.clear();

      kdbx.createEntryCompleter = Completer<String>();
      bloc.add(
        const CreateVaultEntry(
          title: 'Example',
          username: 'user',
          password: 'pass',
          url: 'https://example.com',
          notes: '',
        ),
      );
      await _waitUntil(() => bloc.state.isSaving);

      bloc.add(const BackgroundDriveSync());
      await _waitUntil(() => bloc.state.isSyncReloadPending);

      kdbx.createEntryCompleter!.complete('entry-1');
      await _waitUntil(
        () => !bloc.state.isSaving && !bloc.state.isSyncReloadPending,
      );

      expect(kdbx.loadCallCount, greaterThanOrEqualTo(2));
      expect(
        operations,
        containsAllInOrder(const ['createEntry', 'loadVault']),
      );
    });

    test('sets isDriveConnected: false silently when auth fails', () async {
      repo.isConnectedResult = false;

      final states = <VaultState>[];
      final sub = bloc.stream.listen(states.add);

      bloc.add(const BackgroundDriveSync());
      // Not connected: one refresh emission, then the handler returns.
      await _waitUntil(() => states.isNotEmpty);
      await sub.cancel();

      // With isConnectedResult: false, refreshSyncState sets isDriveConnected: false
      // No exception, no error message, no popup
      expect(bloc.state.errorMessage, isNull);
      expect(states.any((s) => s.isSyncing), isFalse);
    });

    test('terminal auth failure requires explicit reconnect', () async {
      repo.syncNowError = const GoogleAuthorizationRequiredException();

      bloc.add(const BackgroundDriveSync());
      await _waitUntil(
        () =>
            bloc.state.syncError ==
            'Google authorization expired. Reconnect Google Drive to continue.',
      );

      expect(bloc.state.isDriveConnected, isFalse);
      expect(bloc.state.isDriveLinked, isFalse);
      expect(bloc.state.syncStatus, DatabaseSyncStatus.error);
      expect(bloc.state.driveReconnectRequired, isTrue);

      bloc.add(const ClearVaultSyncFeedback());
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.driveReconnectRequired, isTrue);
      expect(
        bloc.state.syncError,
        'Google authorization expired. Reconnect Google Drive to continue.',
      );
    });
  });

  group('SyncCurrentDatabaseNow', () {
    test('reloads vault after manual sync', () async {
      final repo = _FakeSyncRepo()
        ..mapping = _testMapping
        ..isConnectedResult = true;
      final kdbx = _FakeVaultKdbxService();
      final bloc = _makeBloc(repo, kdbx);
      addTearDown(bloc.close);

      bloc.add(const SyncCurrentDatabaseNow());
      await _waitUntil(() => kdbx.loadCallCount >= 1);

      expect(kdbx.loadCallCount, greaterThanOrEqualTo(1));
    });

    // spec-005 T7 non-negotiable: offline is derived ONLY from a
    // connection-level failure, never from an HTTP error status.
    test(
      'SocketException sets isOffline, leaves syncStatus alone (not error)',
      () async {
        // autoSyncEnabled:false so InitializeVault's own BackgroundDriveSync
        // cycle never calls `_performSync` itself — otherwise it races the
        // explicit `SyncCurrentDatabaseNow` under test against this same
        // always-throwing fake.
        final repo = _FakeSyncRepo()
          ..mapping = _testMapping.copyWith(autoSyncEnabled: false)
          ..isConnectedResult = true
          ..syncNowError = const SocketException('Failed host lookup');
        final kdbx = _FakeVaultKdbxService();
        final bloc = _makeBloc(repo, kdbx);
        addTearDown(bloc.close);

        bloc.add(const InitializeVault());
        await _waitUntil(
          () => bloc.state.isDriveConnected && bloc.state.isDriveLinked,
        );

        bloc.add(const SyncCurrentDatabaseNow());
        await _waitUntil(() => bloc.state.isOffline);

        expect(bloc.state.isOffline, isTrue);
        expect(
          bloc.state.syncStatus,
          isNot(DatabaseSyncStatus.error),
          reason: 'offline must not be reported as the generic error status',
        );
      },
    );

    test('a non-network error (HTTP-status-like) sets syncStatus.error, not isOffline', () async {
      final repo = _FakeSyncRepo()
        ..mapping = _testMapping.copyWith(autoSyncEnabled: false)
        ..isConnectedResult = true
        ..syncNowError = Exception('HTTP 500 Internal Server Error');
      final kdbx = _FakeVaultKdbxService();
      final bloc = _makeBloc(repo, kdbx);
      addTearDown(bloc.close);

      bloc.add(const InitializeVault());
      await _waitUntil(
        () => bloc.state.isDriveConnected && bloc.state.isDriveLinked,
      );

      bloc.add(const SyncCurrentDatabaseNow());
      await _waitUntil(() => bloc.state.syncStatus == DatabaseSyncStatus.error);

      expect(bloc.state.syncStatus, DatabaseSyncStatus.error);
      expect(
        bloc.state.isOffline,
        isFalse,
        reason: 'a transient server error must never look like "offline"',
      );
    });
  });
  // spec 010 Phase 4: the provider port converts every remote failure into a
  // typed `CloudStorageException`; presentation maps by code and never shows
  // `toString()`.
  group('CloudStorageException mapping', () {
    const authRequired = CloudStorageException(
      CloudStorageErrorCode.authorizationRequired,
    );
    const authMessage =
        'Google authorization expired. Reconnect Google Drive to continue.';

    Future<VaultBloc> connectedBloc(_FakeSyncRepo repo) async {
      final bloc = _makeBloc(repo, _FakeVaultKdbxService());
      addTearDown(bloc.close);
      bloc.add(const InitializeVault());
      await _waitUntil(() => bloc.state.isDriveConnected);
      return bloc;
    }

    for (final (code, expected) in [
      (CloudStorageErrorCode.cancelled, 'Google sign-in cancelled.'),
      (CloudStorageErrorCode.forbidden, 'Google Drive permission not granted.'),
      (
        CloudStorageErrorCode.serverFailure,
        'Cloud storage service is temporarily unavailable.',
      ),
    ]) {
      test('connect with $code shows "$expected"', () async {
        final repo = _FakeSyncRepo()
          ..connectError = CloudStorageException(code);
        final bloc = _makeBloc(repo, _FakeVaultKdbxService());
        addTearDown(bloc.close);

        bloc.add(const ConnectGoogleDrive());
        await _waitUntil(
          () => bloc.state.syncStatus == DatabaseSyncStatus.error,
        );

        expect(bloc.state.syncError, expected);
      });
    }

    test('syncNow with authorizationRequired requires reconnect', () async {
      final repo = _FakeSyncRepo()
        ..mapping = _testMapping.copyWith(autoSyncEnabled: false)
        ..isConnectedResult = true
        ..syncNowError = authRequired;
      final bloc = await connectedBloc(repo);
      await _waitUntil(() => bloc.state.isDriveLinked);

      bloc.add(const SyncCurrentDatabaseNow());
      await _waitUntil(() => bloc.state.driveReconnectRequired);

      expect(bloc.state.syncError, authMessage);
      expect(bloc.state.isDriveConnected, isFalse);
    });

    test('syncNow with networkUnavailable is offline, not error', () async {
      final repo = _FakeSyncRepo()
        ..mapping = _testMapping.copyWith(autoSyncEnabled: false)
        ..isConnectedResult = true
        ..syncNowError = const CloudStorageException(
          CloudStorageErrorCode.networkUnavailable,
        );
      final bloc = await connectedBloc(repo);
      await _waitUntil(() => bloc.state.isDriveLinked);

      bloc.add(const SyncCurrentDatabaseNow());
      await _waitUntil(() => bloc.state.isOffline);

      expect(bloc.state.syncStatus, DatabaseSyncStatus.idle);
      expect(bloc.state.syncError, isNull);
    });

    test('syncNow with timeout is a plain error, never offline', () async {
      final repo = _FakeSyncRepo()
        ..mapping = _testMapping.copyWith(autoSyncEnabled: false)
        ..isConnectedResult = true
        ..syncNowError = const CloudStorageException(
          CloudStorageErrorCode.timeout,
        );
      final bloc = await connectedBloc(repo);
      await _waitUntil(() => bloc.state.isDriveLinked);

      bloc.add(const SyncCurrentDatabaseNow());
      await _waitUntil(() => bloc.state.syncStatus == DatabaseSyncStatus.error);

      expect(bloc.state.isOffline, isFalse);
      expect(bloc.state.syncError, 'Unable to sync with Google Drive.');
    });

    test(
      'BackgroundDriveSync with authorizationRequired requires reconnect',
      () async {
        final repo = _FakeSyncRepo()
          ..mapping = _testMapping
          ..isConnectedResult = true
          ..syncNowError = authRequired;
        final bloc = _makeBloc(repo, _FakeVaultKdbxService());
        addTearDown(bloc.close);

        bloc.add(const BackgroundDriveSync());
        await _waitUntil(() => bloc.state.driveReconnectRequired);

        expect(bloc.state.syncError, authMessage);
        expect(bloc.state.isDriveConnected, isFalse);
      },
    );

    test(
      'BackgroundDriveSync with networkUnavailable is offline, not error',
      () async {
        final repo = _FakeSyncRepo()
          ..mapping = _testMapping
          ..isConnectedResult = true
          ..syncNowError = const CloudStorageException(
            CloudStorageErrorCode.networkUnavailable,
          );
        final bloc = _makeBloc(repo, _FakeVaultKdbxService());
        addTearDown(bloc.close);

        bloc.add(const BackgroundDriveSync());
        await _waitUntil(() => bloc.state.isOffline);

        expect(bloc.state.syncStatus, DatabaseSyncStatus.idle);
      },
    );

    test(
      'connect with authorizationRequired shows copy without reconnect flag',
      () async {
        final repo = _FakeSyncRepo()..connectError = authRequired;
        final bloc = _makeBloc(repo, _FakeVaultKdbxService());
        addTearDown(bloc.close);

        bloc.add(const ConnectGoogleDrive());
        await _waitUntil(
          () => bloc.state.syncStatus == DatabaseSyncStatus.error,
        );

        expect(
          bloc.state.syncError,
          'Google account not connected. Reconnect Google Drive.',
        );
        expect(bloc.state.driveReconnectRequired, isFalse);
      },
    );

    test('link with authorizationRequired requires reconnect', () async {
      final repo = _FakeSyncRepo()
        ..isConnectedResult = true
        ..linkError = authRequired;
      final bloc = await connectedBloc(repo);

      bloc.add(const LinkCurrentDatabaseToDrive(remoteFileId: 'remote-1'));
      await _waitUntil(() => bloc.state.driveReconnectRequired);

      expect(bloc.state.syncError, authMessage);
      expect(bloc.state.isDriveConnected, isFalse);
    });

    test(
      'LoadRemoteFiles with authorizationRequired flags reconnect',
      () async {
        final repo = _FakeSyncRepo()
          ..isConnectedResult = true
          ..listRemoteFilesOverride = (_) async => throw authRequired;
        final bloc = await connectedBloc(repo);

        bloc.add(const LoadRemoteFiles());
        await _waitUntil(() => bloc.state.remoteFilesError != null);

        expect(bloc.state.remoteFilesReconnectRequired, isTrue);
        expect(bloc.state.remoteFilesError, authMessage);
        expect(bloc.state.isDriveConnected, isFalse);
      },
    );
  });
}

const _kDbPath = '/vault/test.kdbx';

/// Waits until [predicate] holds, yielding to the event loop between checks.
///
/// The bound is deliberately far larger than anything these fakes can need:
/// every wait here completes in microseconds once the handler completes, so
/// the timeout is a deadlock detector, not a "is this machine fast enough"
/// budget. The previous 1s bound was the latter — on a loaded CI it could
/// expire while the condition was still on its way to becoming true, turning a
/// passing test into a random failure. The predicate is unchanged, so a real
/// regression still fails; it just fails for the right reason.
// The debounce timer outlives the handler that armed it, so it cannot use
// that handler's emitter (done by then). It must enqueue a sync event —
// the old emitter-capturing version made auto-sync a silent no-op.
void _autoSyncAfterMutationTests() {
  group('auto-sync after a vault mutation', () {
    late _FakeSyncRepo repo;
    late _FakeVaultKdbxService kdbx;
    late VaultBloc bloc;

    setUp(() {
      repo = _FakeSyncRepo()
        ..mapping = _testMapping
        ..isConnectedResult = true;
      kdbx = _FakeVaultKdbxService()
        ..snapshot = VaultSnapshot(
          rootGroupId: 'root',
          currentGroupId: 'root',
          groups: const [],
          entries: [_entry()],
          allEntries: [_entry()],
        );
      bloc = _makeBloc(repo, kdbx);
    });

    tearDown(() async => bloc.close());

    test(
      'an entry update triggers a debounced sync that actually runs',
      () async {
        bloc.add(const InitializeVault());
        await _waitUntil(() => bloc.state.currentGroupId == 'root');
        bloc.add(const BackgroundDriveSync());
        await _waitUntil(
          () => bloc.state.isDriveConnected && bloc.state.isDriveLinked,
        );
        final syncsBefore = repo.syncNowCallCount;

        bloc.add(
          const UpdateVaultEntry(
            entryId: 'entry-1',
            title: 'Renamed',
            username: 'user',
            password: 'pw',
            url: '',
            notes: '',
          ),
        );

        await _waitUntil(
          () => repo.syncNowCallCount > syncsBefore,
          timeout: const Duration(seconds: 10),
        );
        await _waitUntil(
          () => bloc.state.syncStatus == DatabaseSyncStatus.success,
        );
      },
    );

    test('no auto-sync when autoSyncEnabled is false', () async {
      repo.mapping = _testMapping.copyWith(autoSyncEnabled: false);
      bloc.add(const InitializeVault());
      await _waitUntil(() => bloc.state.currentGroupId == 'root');
      bloc.add(const BackgroundDriveSync());
      await _waitUntil(
        () => bloc.state.isDriveConnected && bloc.state.isDriveLinked,
      );
      final syncsBefore = repo.syncNowCallCount;

      bloc.add(
        const UpdateVaultEntry(
          entryId: 'entry-1',
          title: 'Renamed',
          username: 'user',
          password: 'pw',
          url: '',
          notes: '',
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(repo.syncNowCallCount, syncsBefore);
    });
  });
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

final _emptySnapshot = VaultSnapshot(
  rootGroupId: 'root',
  currentGroupId: 'root',
  groups: const [],
  entries: const [],
  allEntries: const [],
);

const _testMapping = DatabaseSyncMapping(
  databasePath: _kDbPath,
  providerId: 'google_drive',
  remoteFileId: 'file-123',
  remoteFileName: 'test.kdbx',
  autoSyncEnabled: true,
);

VaultEntry _entry({
  String id = 'entry-1',
  String url = '',
  List<VaultCustomField> customFields = const [],
}) {
  return VaultEntry(
    id: id,
    groupId: 'root',
    title: 'Example',
    username: 'user',
    password: 'secret',
    url: url,
    notes: 'notes',
    customFields: customFields,
  );
}

VaultSnapshot _snapshotWithEntry(VaultEntry entry) {
  return VaultSnapshot(
    rootGroupId: 'root',
    currentGroupId: 'root',
    groups: const [],
    entries: [entry],
    allEntries: [entry],
  );
}

AppleAutofillV2PendingAssociation _pendingAssociation({
  String id = 'pending-1',
  String entryId = 'entry-1',
  String serviceIdentifierType = 'url',
  String serviceIdentifierValue = 'https://example.com',
  String? platform,
}) {
  return AppleAutofillV2PendingAssociation(
    id: id,
    databaseId: 'database-id',
    entryId: entryId,
    serviceIdentifierType: serviceIdentifierType,
    serviceIdentifierValue: serviceIdentifierValue,
    displayService: serviceIdentifierValue,
    createdAtEpochMs: 1,
    platform: platform,
  );
}

VaultSnapshot _snapshotReplacingEntry(
  VaultSnapshot snapshot, {
  required String entryId,
  required String title,
  required String username,
  required String password,
  required String url,
  required String notes,
  required List<VaultCustomField> customFields,
}) {
  VaultEntry replace(VaultEntry entry) {
    if (entry.id != entryId) {
      return entry;
    }
    return VaultEntry(
      id: entry.id,
      groupId: entry.groupId,
      title: title,
      username: username,
      password: password,
      url: url,
      notes: notes,
      customFields: List<VaultCustomField>.of(customFields),
      attachments: entry.attachments,
      otpUri: entry.otpUri,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
      lastPasswordChangedAt: entry.lastPasswordChangedAt,
    );
  }

  return VaultSnapshot(
    rootGroupId: snapshot.rootGroupId,
    currentGroupId: snapshot.currentGroupId,
    groups: snapshot.groups,
    entries: snapshot.entries.map(replace).toList(growable: false),
    allEntries: snapshot.allEntries.map(replace).toList(growable: false),
  );
}

// --- Fakes ---

class _FakeVaultKdbxService implements VaultKdbxService {
  _FakeVaultKdbxService({List<String>? operations})
    : operations = operations ?? <String>[];

  final List<String> operations;
  VaultSnapshot snapshot = _emptySnapshot;
  int loadCallCount = 0;
  int updateCallCount = 0;
  Completer<String>? createEntryCompleter;
  String? lastUpdatedEntryId;
  String? lastUpdatedTitle;
  String? lastUpdatedUsername;
  String? lastUpdatedUrl;
  String? lastUpdatedNotes;
  List<VaultCustomField>? lastUpdatedCustomFields;

  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async {
    operations.add('loadVault');
    loadCallCount++;
    return snapshot;
  }

  @override
  Future<String> createEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String groupId,
    required String title,
    required String username,
    required String entryPassword,
    required String url,
    required String notes,
    List<VaultCustomField> customFields = const [],
  }) async {
    operations.add('createEntry');
    final completer = createEntryCompleter;
    if (completer != null) {
      return completer.future;
    }
    return 'entry-1';
  }

  @override
  Future<void> updateEntry({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
    required String title,
    required String username,
    required String entryPassword,
    required String url,
    required String notes,
    List<VaultCustomField> customFields = const [],
    List<String> addedAttachmentPaths = const [],
    List<String> removedAttachmentKeys = const [],
  }) async {
    operations.add('updateEntry');
    updateCallCount += 1;
    lastUpdatedEntryId = entryId;
    lastUpdatedTitle = title;
    lastUpdatedUsername = username;
    lastUpdatedUrl = url;
    lastUpdatedNotes = notes;
    lastUpdatedCustomFields = List<VaultCustomField>.of(customFields);
    snapshot = _snapshotReplacingEntry(
      snapshot,
      entryId: entryId,
      title: title,
      username: username,
      password: entryPassword,
      url: url,
      notes: notes,
      customFields: customFields,
    );
  }

  @override
  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async => [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeSyncRepo implements DatabaseSyncRepository {
  DatabaseSyncMapping? mapping;
  bool isConnectedResult = false;
  SyncNowResult syncResult = const SyncNowSuccess();
  int syncNowCallCount = 0;

  /// spec-005 T7: when set, `syncNow` throws this instead of returning
  /// [syncResult] — lets tests exercise `SocketException` (offline) vs any
  /// other error (HTTP-status-like) without a real network stack.
  Object? syncNowError;
  Future<List<RemoteFile>> Function(String? query)? listRemoteFilesOverride;

  @override
  Future<bool> isConnected() async => isConnectedResult;

  @override
  Future<DatabaseSyncMapping?> getMapping(String path) async => mapping;

  @override
  Future<List<DatabaseSyncMapping>> getAllMappings() async =>
      mapping == null ? const [] : [mapping!];

  @override
  Future<SyncNowResult> syncNow(
    String path, {
    SyncConflictResolution? resolution,
  }) async {
    syncNowCallCount += 1;
    final error = syncNowError;
    if (error != null) {
      throw error;
    }
    return syncResult;
  }

  /// When set, `connect` throws this instead of succeeding — lets tests
  /// exercise the connect error copy without a real Google Sign-In stack.
  Object? connectError;

  @override
  Future<void> connect() async {
    final error = connectError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> removeMapping(String p) async {}

  @override
  Future<DatabaseSyncMappingPathMove> moveMappingPath({
    required String fromDatabasePath,
    required String toDatabasePath,
  }) async => DatabaseSyncMappingPathMove(
    fromDatabasePath: fromDatabasePath,
    toDatabasePath: toDatabasePath,
    sourceBefore: null,
    destinationBefore: null,
  );

  @override
  Future<void> restoreMappingPathMove(DatabaseSyncMappingPathMove move) async {}

  @override
  Future<void> setAutoSync(String p, bool e) async {}

  @override
  Future<List<RemoteFile>> listRemoteFiles({String? query}) async {
    return listRemoteFilesOverride?.call(query) ?? [];
  }

  @override
  Future<Uint8List> downloadRemoteFile(String id) async =>
      throw UnimplementedError();

  /// When set, `linkDatabaseToRemote` throws this instead of succeeding.
  Object? linkError;

  @override
  Future<DatabaseSyncMapping> linkDatabaseToRemote({
    required String databasePath,
    String? remoteFileId,
    String? remoteFileName,
  }) async => throw linkError ?? UnimplementedError();

  @override
  Future<StorageAccountSummary> getConnectedAccount() async =>
      const StorageAccountSummary(displayLabel: 'Google Drive account');
}

class _StoredGoogleTokenDataSource implements GoogleTokenDataSource {
  _StoredGoogleTokenDataSource(this.value, {this.throwOnClear = false});

  final bool throwOnClear;
  String? value;

  @override
  Future<void> clearDesktopCredentialsJson() async {
    if (throwOnClear) {
      throw StateError('synthetic secure-storage failure');
    }
    value = null;
  }

  @override
  Future<String?> getDesktopCredentialsJson() async => value;

  @override
  Future<void> saveDesktopCredentialsJson(String json) async => value = json;
}

VaultBloc _makeBloc(
  _FakeSyncRepo repo,
  _FakeVaultKdbxService kdbx, {
  AppleAutofillV2CoordinatorContract appleAutofillV2Coordinator =
      const NoopAppleAutofillV2Coordinator(),
  SessionSecretHolder? sessionSecretHolder,
}) {
  return VaultBloc(
    databasePath: _kDbPath,
    getSelectedKeyFilePath: () async => null,
    sessionSecretHolder:
        sessionSecretHolder ?? (SessionSecretHolder()..set('')),
    vaultKdbxService: kdbx,
    vaultCsvImportService: VaultCsvImportService(),
    vaultDuplicateService: VaultDuplicateService(),
    databaseSyncRepository: repo,
    linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(repo),
    syncDatabaseNow: SyncDatabaseNowUseCase(repo),
    appleAutofillV2Coordinator: appleAutofillV2Coordinator,
  );
}

class _FakeAppleAutofillV2Coordinator
    implements AppleAutofillV2CoordinatorContract {
  List<AppleAutofillV2PendingAssociation> pendingAssociations = [];
  int publishCallCount = 0;
  int clearCallCount = 0;
  int readPendingCallCount = 0;
  int clearPendingCallCount = 0;
  String? lastDatabasePath;
  List<VaultEntry>? lastEntries;
  List<String>? lastClearedPendingIds;

  @override
  Future<void> publishVault({
    required String databasePath,
    required List<VaultEntry> entries,
  }) async {
    publishCallCount += 1;
    lastDatabasePath = databasePath;
    lastEntries = entries;
  }

  @override
  Future<void> clearCredentials({String? databasePath}) async {
    clearCallCount += 1;
  }

  @override
  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  }) async {
    readPendingCallCount += 1;
    return List<AppleAutofillV2PendingAssociation>.of(pendingAssociations);
  }

  @override
  Future<void> clearPendingAssociations({List<String>? ids}) async {
    clearPendingCallCount += 1;
    lastClearedPendingIds = ids == null ? null : List<String>.of(ids);
    if (ids == null) {
      pendingAssociations = [];
      return;
    }

    final idSet = ids.toSet();
    pendingAssociations = pendingAssociations
        .where((association) => !idSet.contains(association.id))
        .toList(growable: false);
  }
}
