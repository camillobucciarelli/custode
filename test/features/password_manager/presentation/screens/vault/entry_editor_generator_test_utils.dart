// spec-004: shared widget/golden test harness for entry detail, editor and
// generator. Same fake-DI pattern as vault_shell_test_utils.dart
// (spec-002), extended with a caller-supplied VaultSnapshot and mutable
// biometric knobs so tests can drive reveal/biometric-gate scenarios.
import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/utils/clipboard_guard.dart';
import 'package:password_manager/core/theme/theme_cubit.dart';
import 'package:password_manager/features/password_manager/data/datasources/biometric_data_source.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_pending_generation_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_csv_import_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_duplicate_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/database_sync_mapping.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_attachment.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry_revision.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_group.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';
import 'package:password_manager/features/password_manager/domain/repositories/database_sync_repository.dart';
import 'package:password_manager/features/password_manager/domain/services/password_generator_service.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/vault/vault_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/otpauth_deep_link_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/vault_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault_screen.dart';
import 'package:password_manager/injection_container.dart' as di;
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/sync_database_now_usecase.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kEntryTestDatabasePath = '/tmp/entry_editor_generator_test.kdbx';
const kRootGroupId = 'root';

/// Root-only group, plus a fixture entry set covering: strong password (no
/// OTP), TOTP entry (period=30), and a weak password reused by two entries.
VaultSnapshot buildFixtureSnapshot() {
  final now = DateTime(2026, 3, 12, 9, 30);
  final created = DateTime(2024, 1, 4);

  const root = VaultGroup(id: kRootGroupId, name: 'Vault', parentId: null);

  final github = VaultEntry(
    id: 'e-github',
    groupId: kRootGroupId,
    title: 'GitHub',
    username: 'camillo@bucciarelli.dev',
    password: 't7\$Krm-4Qz!p2Vwe',
    url: 'https://github.com',
    notes:
        'Recovery codes in the attachment. SSO via Google disabled on '
        'purpose.',
    customFields: const [
      VaultCustomField(key: 'Codice cliente', value: '88-4412-C'),
    ],
    attachments: const [
      VaultAttachment(key: 'a1', name: 'mfa-recovery-codes.txt', size: 1229),
    ],
    createdAt: created,
    updatedAt: now,
    lastPasswordChangedAt: now.subtract(const Duration(days: 120)),
  );

  final banca = VaultEntry(
    id: 'e-banca',
    groupId: kRootGroupId,
    title: 'Banca Sella',
    username: 'CB77219',
    // Deliberately different from GitHub's password: sharing one would
    // make both entries spuriously "reused" and always show the
    // weak/reused strip, defeating the entry_detail_hidden golden (which
    // wants GitHub in its plain "Strong, not reused" state).
    password: 'q9!Ztn-3Xpr%Ke7w',
    url: 'https://sella.it',
    notes: '',
    otpUri: 'otpauth://totp/Sella:CB77219?secret=JBSWY3DPEHPK3PXP&period=30&digits=6',
    createdAt: created,
    updatedAt: now,
    lastPasswordChangedAt: now.subtract(const Duration(days: 60)),
  );

  final netflix = VaultEntry(
    id: 'e-netflix',
    groupId: kRootGroupId,
    title: 'Netflix',
    username: 'famiglia@bucciarelli.dev',
    password: 'abc123',
    url: 'https://netflix.com',
    notes: '',
    createdAt: created,
    updatedAt: now,
    lastPasswordChangedAt: now.subtract(const Duration(days: 900)),
  );

  final netflixReuse = VaultEntry(
    id: 'e-netflix-2',
    groupId: kRootGroupId,
    title: 'Netflix (kids)',
    username: 'kids@bucciarelli.dev',
    password: 'abc123',
    url: 'https://netflix.com',
    notes: '',
    createdAt: created,
    updatedAt: now,
  );

  final entries = [github, banca, netflix, netflixReuse];
  return VaultSnapshot(
    rootGroupId: kRootGroupId,
    currentGroupId: kRootGroupId,
    groups: const [root],
    entries: entries,
    allEntries: entries,
  );
}

class EntryTestHarness {
  EntryTestHarness({VaultSnapshot? snapshot})
    : snapshot = snapshot ?? buildFixtureSnapshot();

  VaultSnapshot snapshot;
  bool biometricAvailable = false;
  bool biometricEnabledForDatabase = false;

  /// When true, [BiometricDataSource.authenticate] never resolves —
  /// mirrors `hangBiometricAuthenticate` in database_and_unlock_test.dart,
  /// used to capture the biometric-gate sheet golden mid-flow.
  bool hangBiometricAuthenticate = false;
  bool biometricAuthenticateResult = true;

  /// spec 017 T501: what `loadEntryHistory` answers, by entry id. An entry
  /// absent here has no history — the empty state.
  final Map<String, VaultEntryHistory> histories = {};
}

Future<Widget> pumpableEntryScreen({
  EntryTestHarness? harness,
  ThemeMode themeMode = ThemeMode.light,
}) async {
  final resolvedHarness = harness ?? EntryTestHarness();
  SharedPreferences.setMockInitialValues({});
  final sharedPreferences = await SharedPreferences.getInstance();

  di.sl.registerLazySingleton<OtpAuthDeepLinkCoordinator>(
    () => OtpAuthDeepLinkCoordinator(),
  );
  // 009 / B005: `_PendingGenerationBanner` resolves this on init.
  di.sl.registerLazySingleton<DesktopBrowserPendingGenerationService>(
    () => DesktopBrowserPendingGenerationService(),
  );
  // `dispose:` matters here: mirrors the production lazy singleton
  // (password_manager_presentation_di.dart), and lets `resetEntryTestDi()`'s
  // `di.sl.reset()` cancel any pending 30s clear timer a test left running,
  // so it can't fire in — or leak into — the next test.
  di.sl.registerLazySingleton<ClipboardGuard>(
    () => ClipboardGuard(),
    dispose: (guard) => guard.dispose(),
  );
  di.sl.registerLazySingleton<VaultSessionCoordinator>(
    () => _FakeVaultSessionCoordinator(resolvedHarness),
  );
  di.sl.registerLazySingleton<BiometricDataSource>(
    () => _FakeBiometricDataSource(resolvedHarness),
  );
  if (!di.sl.isRegistered<PasswordGeneratorService>()) {
    // Fixed seed: goldens photograph the generator's result box (mono,
    // break-all) — a real Random.secure() draw would make those goldens
    // flaky (byte-diff on every run). See password_generator_service.dart.
    di.sl.registerLazySingleton<PasswordGeneratorService>(
      () => PasswordGeneratorService(random: math.Random(42)),
    );
  }
  final syncRepository = _FakeDatabaseSyncRepository();
  di.sl.registerFactoryParam<VaultBloc, String, void>(
    (path, _) => VaultBloc(
      databasePath: path,
      getSelectedKeyFilePath: () async => null,
      sessionSecretHolder: SessionSecretHolder()..set(''),
      vaultKdbxService: _FakeVaultKdbxService(resolvedHarness),
      vaultCsvImportService: VaultCsvImportService(),
      vaultDuplicateService: VaultDuplicateService(),
      databaseSyncRepository: syncRepository,
      linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
      syncDatabaseNow: SyncDatabaseNowUseCase(syncRepository),
    ),
  );

  return BlocProvider<ThemeCubit>(
    create: (_) => ThemeCubit(sharedPreferences),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('en', 'US'),
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      home: const VaultScreen(databasePath: kEntryTestDatabasePath),
    ),
  );
}

Future<void> resetEntryTestDi() => di.sl.reset();

class _FakeVaultKdbxService implements VaultKdbxService {
  _FakeVaultKdbxService(this.harness);

  final EntryTestHarness harness;

  @override
  Future<VaultSnapshot> loadVault({
    required String databasePath,
    required String password,
    String? keyFilePath,
    String? currentGroupId,
  }) async => harness.snapshot;

  @override
  Future<List<VaultEntry>> loadRecycleBinEntries({
    required String databasePath,
    required String password,
    String? keyFilePath,
  }) async => const [];

  @override
  Future<VaultEntryHistory> loadEntryHistory({
    required String databasePath,
    required String password,
    String? keyFilePath,
    required String entryId,
  }) async =>
      harness.histories[entryId] ??
      const VaultEntryHistory(
        revisions: [],
        retention: VaultHistoryRetention(maxItems: 10),
      );

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
  _FakeVaultSessionCoordinator(this.harness);

  final EntryTestHarness harness;

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
  }) async => harness.biometricEnabledForDatabase;

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

  _FakeBiometricDataSource(this.harness);

  final EntryTestHarness harness;

  @override
  Future<bool> isBiometricAvailable() async => harness.biometricAvailable;

  @override
  Future<bool> authenticate({required String reason}) async {
    if (harness.hangBiometricAuthenticate) {
      return Completer<bool>().future;
    }
    return harness.biometricAuthenticateResult;
  }
}
