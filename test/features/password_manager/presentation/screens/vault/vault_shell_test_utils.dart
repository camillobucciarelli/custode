// Shared widget-test harness for spec-002 navigation-shell tests.
//
// `VaultScreen` resolves several collaborators through the global GetIt
// (`di.sl`) container. This file registers minimal fakes so [VaultScreen]
// can be pumped in a widget test without touching platform channels, real
// kdbx I/O, or the full production DI graph. Callers MUST call
// `resetVaultShellTestDi()` in `tearDown` to avoid leaking registrations
// between tests.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/utils/clipboard_guard.dart';
import 'package:password_manager/core/theme/theme_cubit.dart';
import 'package:password_manager/features/password_manager/data/datasources/biometric_data_source.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_passkey_approval_service.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_pending_generation_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_csv_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_duplicate_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/services/password_generator_service.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/duplicate_merge_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/entry_history_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/google_drive_reconnect_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/otpauth_deep_link_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/vault_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';
import 'package:password_manager/injection_container.dart' as di;
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_database_now_usecase.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kTestDatabasePath = '/tmp/vault_shell_test.kdbx';

/// Registers fakes into the global `di.sl` GetIt instance and returns a
/// ready-to-pump `VaultScreen` wrapped in the app theme + ThemeCubit it
/// needs. Uses an empty vault snapshot (no entries/groups) so the shell
/// renders deterministically for geometry/golden assertions.
Future<Widget> pumpableVaultShell({
  String databasePath = kTestDatabasePath,
  ThemeMode? themeMode,
  // spec-005 T19/AC3: lets a caller inject a spy repository (e.g. to count
  // `connect()` calls before/after a user action) instead of the default
  // fake. Defaults preserve every pre-spec-005 call site's behaviour.
  DatabaseSyncRepository? databaseSyncRepository,
  // spec-005 T20: lets a caller inject a vault with real entries (e.g. a
  // duplicate pair) instead of the default always-empty snapshot.
  VaultKdbxService? vaultKdbxService,
  // spec-006 T16: seed the lock/privacy overlay debug flags on VaultScreen.
  bool debugInitiallyLocked = false,
  bool debugInitiallyBackground = false,
  // spec-006 T16: lets a golden seed a pending Apple AutoFill association
  // (screen 7, "Link AutoFill credential?") instead of the default Noop.
  AppleAutofillV2CoordinatorContract? appleAutofillV2Coordinator,
  // Lets a caller inject a spy/fake coordinator (e.g. to count calls) instead
  // of the default always-empty fake.
  VaultSessionCoordinator? vaultSessionCoordinator,
  // 009 / B005: lets a caller seed pending browser-generated records the
  // `_PendingGenerationBanner` resolves via `di.sl`.
  DesktopBrowserPendingGenerationService? pendingGenerationService,
  // spec 017 T304: lets the history tests hand the bloc a recording
  // coordinator, so "confirming calls it once" is assertable.
  EntryHistoryCoordinator? entryHistoryCoordinator,
  // spec 023 T707: lets a caller drive the browser-bridge passkey
  // confirmations. Registered only when passed, because
  // `_PasskeyApprovalListener` is deliberately a no-op on a host that never
  // registered the service — every other shell test relies on that.
  DesktopPasskeyApprovalService? passkeyApprovalService,
  // spec 023 T207: the merge sequence, when a test needs the merge to run.
  DuplicateMergeCoordinator? duplicateMergeCoordinator,
}) async {
  SharedPreferences.setMockInitialValues({});
  final sharedPreferences = await SharedPreferences.getInstance();
  final resolvedSyncRepository =
      databaseSyncRepository ?? _FakeDatabaseSyncRepository();

  di.sl.registerLazySingleton<OtpAuthDeepLinkCoordinator>(
    () => OtpAuthDeepLinkCoordinator(),
  );
  // spec-006 T16: `_LockOverlay` resolves this on init — not previously
  // needed by any pre-spec-006 test that pumped `VaultScreen`.
  di.sl.registerLazySingleton<BiometricDataSource>(
    () => _FakeBiometricDataSource(),
  );
  di.sl.registerLazySingleton<VaultSessionCoordinator>(
    () => vaultSessionCoordinator ?? _FakeVaultSessionCoordinator(),
  );
  // 009 / B005: `_PendingGenerationBanner` resolves this on init.
  di.sl.registerLazySingleton<DesktopBrowserPendingGenerationService>(
    () => pendingGenerationService ?? DesktopBrowserPendingGenerationService(),
  );
  // spec-005: `_DuplicateGroupCard`/merge preview and the remote-file
  // picker resolve these directly via `di.sl` (matches production
  // `injection_container.dart`) — same instance as passed to `VaultBloc`.
  di.sl.registerLazySingleton<VaultDuplicateService>(
    () => VaultDuplicateService(),
  );
  di.sl.registerLazySingleton<DatabaseSyncRepository>(
    () => resolvedSyncRepository,
  );
  // The editor's generator column resolves this directly. Fixed seed for the
  // same reason `entry_editor_generator_test_utils.dart` uses one: a real
  // `Random.secure()` draw would make anything that photographs the result
  // box flaky.
  // spec-019 FR-010: the records list can copy a password now, and the copy
  // goes through the same guard the detail uses.
  di.sl.registerLazySingleton<ClipboardGuard>(() => ClipboardGuard());
  di.sl.registerLazySingleton<PasswordGeneratorService>(
    () => PasswordGeneratorService(random: math.Random(42)),
  );
  di.sl.registerLazySingleton<GoogleDriveReconnectCoordinator>(
    () => GoogleDriveReconnectCoordinator(
      databaseSyncRepository: resolvedSyncRepository,
    ),
  );
  if (passkeyApprovalService != null) {
    di.sl.registerLazySingleton<DesktopPasskeyApprovalService>(
      () => passkeyApprovalService,
    );
  }
  di.sl.registerFactoryParam<VaultBloc, String, void>(
    (path, _) => VaultBloc(
      databasePath: path,
      getSelectedKeyFilePath: () async => null,
      sessionSecretHolder: SessionSecretHolder()..set(''),
      vaultKdbxService: vaultKdbxService ?? _FakeVaultKdbxService(),
      vaultCsvImportService: VaultCsvImportService(),
      vaultDuplicateService: VaultDuplicateService(),
      databaseSyncRepository: resolvedSyncRepository,
      linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(resolvedSyncRepository),
      syncDatabaseNow: SyncDatabaseNowUseCase(resolvedSyncRepository),
      appleAutofillV2Coordinator:
          appleAutofillV2Coordinator ?? const NoopAppleAutofillV2Coordinator(),
      entryHistoryCoordinator: entryHistoryCoordinator,
      duplicateMergeCoordinator: duplicateMergeCoordinator,
    ),
  );

  return BlocProvider<ThemeCubit>(
    create: (_) => ThemeCubit(sharedPreferences),
    child: Builder(
      builder: (context) {
        final resolvedThemeMode =
            themeMode ?? context.watch<ThemeCubit>().state;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en', 'US'),
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: resolvedThemeMode,
          home: VaultScreen(
            databasePath: databasePath,
            debugInitiallyLocked: debugInitiallyLocked,
            debugInitiallyBackground: debugInitiallyBackground,
          ),
        );
      },
    ),
  );
}

/// Undo the registrations made by [pumpableVaultShell]. Call from `tearDown`.
Future<void> resetVaultShellTestDi() => di.sl.reset();

class _FakeBiometricDataSource implements BiometricDataSource {
  bool deviceAuthSupported = true;
  bool deviceCredentialResult = true;
  int deviceCredentialRequests = 0;

  @override
  Future<bool> isDeviceAuthSupported() async => deviceAuthSupported;

  @override
  Future<bool> authenticateWithDeviceCredential({
    required String reason,
  }) async {
    deviceCredentialRequests += 1;
    return deviceCredentialResult;
  }

  @override
  Future<bool> isBiometricAvailable() async => false;

  @override
  Future<bool> authenticate({required String reason}) async => false;
}

class _FakeVaultKdbxService implements VaultKdbxService {
  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async => const VaultSnapshot(
    rootGroupId: 'root',
    currentGroupId: 'root',
    groups: [],
    entries: [],
    allEntries: [],
  );

  @override
  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDatabaseSyncRepository implements DatabaseSyncRepository {
  @override
  Future<bool> isConnected() async => false;

  @override
  Future<DatabaseSyncMapping?> getMapping(String path) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVaultSessionCoordinator implements VaultSessionCoordinator {
  @override
  Future<String?> getSelectedKeyFilePath() async => null;

  @override
  Future<String?> getPersistedKeyFilePath(String databasePath) async => null;

  @override
  Future<Set<String>> getProtectedKeyFilePaths() async => const {};

  @override
  Future<void> changeDatabase({required String currentDatabasePath}) async {}

  @override
  Future<void> lockVault({required String currentDatabasePath}) async {}

  @override
  Future<bool> getBiometricProtectionEnabledForPath({
    required String databasePath,
  }) async => false;

  @override
  Future<int?> getInactivityLockTimeoutForPath({
    required String databasePath,
  }) async => null;

  @override
  Future<DatabaseSettingsUpdateResult> updateDatabaseSettings(
    DatabaseSettingsUpdateRequest request,
  ) => throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
