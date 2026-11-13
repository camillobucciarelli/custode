import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/clipboard_guard.dart';
import '../presentation/bloc/database_selection/database_selection_bloc.dart';
import '../presentation/bloc/database_unlock/database_unlock_bloc.dart';
import '../presentation/bloc/vault/vault_bloc.dart';
import '../presentation/coordinators/android_autofill_save_coordinator.dart';
import '../presentation/coordinators/apple_autofill_v2_coordinator.dart';
import '../presentation/coordinators/database_session_coordinator.dart';
import '../presentation/coordinators/desktop_browser_autofill_coordinator.dart';
import '../presentation/coordinators/duplicate_merge_coordinator.dart';
import '../presentation/coordinators/entry_history_coordinator.dart';
import '../presentation/coordinators/passkey_coordinator.dart';
import '../presentation/coordinators/platform_passkey_registration_coordinator.dart';
import '../data/services/apple_autofill_v2_method_channel_client.dart';
import '../data/services/desktop_passkey_approval_service.dart';
import '../presentation/coordinators/google_drive_reconnect_coordinator.dart';
import '../presentation/coordinators/otpauth_deep_link_coordinator.dart';
import '../presentation/coordinators/session_secret_holder.dart';
import '../domain/repositories/database_registry_repository.dart';
import '../presentation/coordinators/sync_merge_coordinator.dart';
import '../presentation/coordinators/vault_session_coordinator.dart';

void registerPasswordManagerPresentationDependencies(GetIt sl) {
  // App-lifetime singleton, not per-screen: a screen-owned instance had its
  // pending 30s clear timer cancelled by that screen's dispose() the moment
  // the user navigated away right after copying (spec-004 FR-3 bug).
  sl.registerLazySingleton<ClipboardGuard>(() => ClipboardGuard());

  // spec-011 FR-1: single session-scoped instance shared by both session
  // coordinators and VaultBloc — the in-memory transport for the master
  // password of the unlocked session.
  sl.registerLazySingleton<SessionSecretHolder>(() => SessionSecretHolder());

  sl.registerLazySingleton<AppleAutofillV2CoordinatorContract>(
    () => CompositeAutofillV2Coordinator([
      AppleAutofillV2Coordinator(client: sl(), mapper: sl()),
      DesktopBrowserAutofillCoordinator(
        store: sl(),
        mapper: sl(),
        revealBridge: sl(),
        pendingGeneration: sl(),
        // spec 023: creating a passkey needs both a writer and a way to ask
        // the user where it goes. Either missing and the bridge advertises no
        // passkey capability at all.
        passkeyCoordinator: sl(),
        passkeyApprovals: sl(),
        // spec 014 FR-8: the same source `VaultBloc` reads, so a browser-side
        // write opens a key-file-protected vault exactly as an in-app one does.
        //
        // Resolved inside the closure, not here: `VaultSessionCoordinator`
        // takes this very coordinator as its autofill contract, so looking it
        // up while this one is being constructed would be a cycle.
        currentKeyFilePath: () =>
            sl<VaultSessionCoordinator>().getSelectedKeyFilePath(),
      ),
      // spec 023 slice 4: learns which vault is open, for registrations that
      // start on the platform side.
      sl<PlatformPasskeyRegistrationCoordinator>(),
    ]),
  );

  // spec-016 US3: Android save capture. Registered everywhere, inert wherever
  // the client reports no capture support.
  sl.registerLazySingleton<AndroidAutofillSaveCoordinator>(
    () => AndroidAutofillSaveCoordinator(
      client: sl(),
      mapper: sl(),
      vaultKdbxService: sl(),
      sessionSecretHolder: sl(),
    ),
  );

  sl.registerLazySingleton<DatabaseSessionCoordinator>(
    () => DatabaseSessionCoordinator(
      databaseFileRepository: sl(),
      databaseSessionRepository: sl(),
      databaseRegistryRepository: sl(),
      databaseSecurityRepository: sl(),
      databaseSyncRepository: sl(),
      linkDatabaseToRemote: sl(),
      metadataRecoveryRepository: sl(),
      getActiveDatabaseUseCase: sl(),
      resolveDatabaseDuplicateUseCase: sl(),
      unlockDatabaseUseCase: sl(),
      createDatabaseUseCase: sl(),
      sessionSecretHolder: sl(),
      appleAutofillV2Coordinator: sl(),
    ),
  );

  sl.registerLazySingleton<SyncMergeCoordinator>(
    () => SyncMergeCoordinator(
      startReview: sl(),
      updateDecision: sl(),
      commit: sl(),
      cancel: sl(),
      invalidate: sl(),
      recoverPending: sl(),
    ),
  );

  sl.registerLazySingleton<VaultSessionCoordinator>(
    () => VaultSessionCoordinator(
      databaseFileRepository: sl(),
      databaseRenameTransaction: sl(),
      localDataSource: sl(),
      databaseRegistryRepository: sl(),
      databaseSecurityRepository: sl(),
      secureDataSource: sl(),
      databaseSyncRepository: sl(),
      vaultKdbxService: sl(),
      sessionSecretHolder: sl(),
      appleAutofillV2Coordinator: sl(),
      syncMergeCoordinator: sl(),
    ),
  );

  sl.registerLazySingleton<GoogleDriveReconnectCoordinator>(
    () => GoogleDriveReconnectCoordinator(databaseSyncRepository: sl()),
  );

  sl.registerLazySingleton<OtpAuthDeepLinkCoordinator>(
    () => OtpAuthDeepLinkCoordinator(),
  );

  // spec 017 T302: restore and clear sequencing for the history view.
  sl.registerLazySingleton<EntryHistoryCoordinator>(
    () => EntryHistoryCoordinator(
      vaultKdbxService: sl(),
      sessionSecretHolder: sl(),
      databaseFileRepository: sl(),
    ),
  );

  // spec 023 T207: dated backup + merge sequencing for Vault health.
  sl.registerLazySingleton<DuplicateMergeCoordinator>(
    () => DuplicateMergeCoordinator(
      vaultKdbxService: sl(),
      sessionSecretHolder: sl(),
      databaseFileRepository: sl(),
    ),
  );

  // spec 023 T204: dated backup + delete sequencing for the passkey section.
  sl.registerLazySingleton<PasskeyCoordinator>(
    () => PasskeyCoordinator(
      vaultKdbxService: sl(),
      sessionSecretHolder: sl(),
      databaseFileRepository: sl(),
    ),
  );

  // spec 023 slice 4: Android Credential Manager and the macOS AutoFill
  // extension create passkeys through the running app. The handler is
  // attached on those two platforms only; elsewhere nothing calls it.
  sl.registerLazySingleton<PlatformPasskeyRegistrationCoordinator>(() {
    final coordinator = PlatformPasskeyRegistrationCoordinator(
      passkeyCoordinator: sl(),
      currentKeyFilePath: () =>
          sl<VaultSessionCoordinator>().getSelectedKeyFilePath(),
      onPasskeyWritten: sl<DesktopPasskeyApprovalService>().notePasskeyWritten,
    );
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      coordinator.attach(
        const MethodChannel(AppleAutofillV2MethodChannelClient.channelName),
      );
    }
    return coordinator;
  });

  sl.registerFactory(
    () => DatabaseSelectionBloc(databaseSessionCoordinator: sl()),
  );

  sl.registerFactoryParam<DatabaseUnlockBloc, String, void>(
    (databasePath, _) => DatabaseUnlockBloc(
      databasePath: databasePath,
      biometricDataSource: sl(),
      databaseSessionCoordinator: sl(),
      isAutofillCapturePending: () =>
          sl<AndroidAutofillSaveCoordinator>().hasClaimedCapture,
    ),
  );

  sl.registerFactoryParam<VaultBloc, String, void>(
    (databasePath, _) => VaultBloc(
      databasePath: databasePath,
      getSelectedKeyFilePath:
          sl<VaultSessionCoordinator>().getSelectedKeyFilePath,
      sessionSecretHolder: sl(),
      vaultKdbxService: sl(),
      vaultCsvImportService: sl(),
      vaultDuplicateService: sl(),
      databaseSyncRepository: sl(),
      linkDatabaseToRemote: sl(),
      syncDatabaseNow: sl(),
      appleAutofillV2Coordinator: sl(),
      androidAutofillSaveCoordinator: sl(),
      // spec-019 FR-006g: the folder expansion set outlives the session.
      folderExpansionPreferences: sl<SharedPreferences>(),
      syncMergeCoordinator: sl(),
      entryHistoryCoordinator: sl(),
      duplicateMergeCoordinator: sl(),
      passkeyCoordinator: sl(),
      resolveDatabaseId: (databasePath) async {
        final records = await sl<DatabaseRegistryRepository>().list();
        for (final record in records) {
          if (record.canonicalPath == databasePath) return record.databaseId;
        }
        return null;
      },
      resolveDisplayName: (databasePath) async {
        final records = await sl<DatabaseRegistryRepository>().list();
        for (final record in records) {
          if (record.canonicalPath == databasePath) return record.displayName;
        }
        return null;
      },
    ),
  );
}
