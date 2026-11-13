// Shared widget/golden-test harness for spec-003 database selection/unlock
// screens. Registers a real `DatabaseSessionCoordinator` wired to the
// in-memory fake domain ports (same fakes the BLoC-level tests use) into
// the global `di.sl` GetIt container, and provides a real
// `DatabaseSelectionBloc` / `DatabaseUnlockBloc` above the pumped screen.
//
// Callers MUST call `resetDatabaseTestDi()` in `tearDown`.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/data/datasources/biometric_data_source.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_pending_generation_service.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/get_active_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/resolve_database_duplicate_usecase.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_event.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/otpauth_deep_link_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/screens/create_database_screen.dart';
import 'package:password_manager/features/password_manager/presentation/screens/database_selection_screen.dart';
import 'package:password_manager/features/password_manager/presentation/screens/database_unlock_screen.dart';
import 'package:password_manager/injection_container.dart' as di;
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';

import '../coordinators/fake_database_ports.dart';

class DatabaseTestHarness {
  DatabaseTestHarness({
    required this.fileRepository,
    required this.sessionRepository,
    required this.registryRepository,
    required this.securityRepository,
    required this.syncRepository,
    required this.unlockUseCase,
    required this.coordinator,
  });

  final FakeDatabaseFileRepository fileRepository;
  final FakeDatabaseSessionRepository sessionRepository;
  final FakeDatabaseRegistryRepository registryRepository;
  final FakeDatabaseSecurityRepository securityRepository;
  final FakeDatabaseSyncRepository syncRepository;
  final FakeUnlockDatabaseUseCase unlockUseCase;
  final DatabaseSessionCoordinator coordinator;
}

DatabaseTestHarness _buildHarness() {
  final fileRepository = FakeDatabaseFileRepository();
  final sessionRepository = FakeDatabaseSessionRepository();
  final registryRepository = FakeDatabaseRegistryRepository();
  final securityRepository = FakeDatabaseSecurityRepository();
  final syncRepository = FakeDatabaseSyncRepository();
  final unlockUseCase = FakeUnlockDatabaseUseCase();
  final coordinator = DatabaseSessionCoordinator(
    sessionSecretHolder: SessionSecretHolder(),
    databaseFileRepository: fileRepository,
    databaseSessionRepository: sessionRepository,
    databaseRegistryRepository: registryRepository,
    databaseSecurityRepository: securityRepository,
    databaseSyncRepository: syncRepository,
    linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(syncRepository),
    getActiveDatabaseUseCase: GetActiveDatabaseUseCase(registryRepository),
    resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
      registryRepository,
    ),
    unlockDatabaseUseCase: unlockUseCase,
    createDatabaseUseCase: CreateDatabaseUseCase(
      databaseFileRepository: fileRepository,
    ),
  );

  di.sl.registerLazySingleton<DatabaseSessionCoordinator>(() => coordinator);
  // `DatabaseUnlockScreen` navigates to `VaultScreen` on a successful
  // unlock (`state.unlocked`), and `VaultScreen`'s shell resolves
  // `OtpAuthDeepLinkCoordinator` via `di.sl` in `initState` (matches
  // production `injection_container.dart`) — register it here so any pump
  // helper that drives a real unlock success doesn't crash resolving it.
  di.sl.registerLazySingleton<OtpAuthDeepLinkCoordinator>(
    () => OtpAuthDeepLinkCoordinator(),
  );
  // 009 / B005: `VaultScreen`'s `_PendingGenerationBanner` resolves this on
  // init, same reason as the OtpAuthDeepLinkCoordinator above.
  di.sl.registerLazySingleton<DesktopBrowserPendingGenerationService>(
    () => DesktopBrowserPendingGenerationService(),
  );
  // `DatabaseSelectionScreen` navigates to `DatabaseUnlockScreen` on any
  // `DatabaseSelectionSuccess` (initial open, Locate match, duplicate
  // resolution, create) and that screen resolves its bloc through DI —
  // register it here so every pump helper can reach that navigation
  // without registering it ad hoc per call site.
  di.sl.registerFactoryParam<DatabaseUnlockBloc, String, void>(
    (path, _) => DatabaseUnlockBloc(
      databasePath: path,
      biometricDataSource: _FakeBiometricDataSource(available: false),
      databaseSessionCoordinator: coordinator,
    ),
  );

  return DatabaseTestHarness(
    fileRepository: fileRepository,
    sessionRepository: sessionRepository,
    registryRepository: registryRepository,
    securityRepository: securityRepository,
    syncRepository: syncRepository,
    unlockUseCase: unlockUseCase,
    coordinator: coordinator,
  );
}

/// Pumps `DatabaseSelectionScreen` with [items] already registered, so the
/// bloc reaches the requested state (empty -> welcome; non-empty -> recent
/// list) without depending on real event timing.
Future<({Widget widget, DatabaseTestHarness harness})> pumpableSelectionScreen({
  List<DatabaseRecord> records = const [],
  Map<String, DatabaseSecurityProfile> securityProfiles = const {},
  Set<String> existingPaths = const {},
  ThemeMode themeMode = ThemeMode.light,
}) async {
  final harness = _buildHarness();
  harness.registryRepository.records = records;
  harness.securityRepository.profiles.addAll(securityProfiles);
  harness.fileRepository.existingPaths.addAll(existingPaths);

  final bloc = DatabaseSelectionBloc(
    databaseSessionCoordinator: harness.coordinator,
  )..add(CheckInitialDatabase());

  // Mirrors `main.dart`'s `PasswordManagerApp`: the bloc provider wraps the
  // whole `MaterialApp` (above the Navigator), not just `home`, so routes
  // pushed via `Navigator.push` (e.g. `CreateDatabaseScreen`) still resolve
  // it — a provider scoped only inside `home:` would NOT be an ancestor of
  // a later-pushed route's page.
  final widget = BlocProvider<DatabaseSelectionBloc>.value(
    value: bloc,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('en', 'US'),
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      home: const DatabaseSelectionScreen(),
    ),
  );

  return (widget: widget, harness: harness);
}

/// Pumps `DatabaseUnlockScreen` for [databasePath], optionally requiring
/// biometrics (`biometricProtectionEnabled` on the matching security
/// profile) and/or pre-seeding a key file path.
///
/// [hangBiometricAuthenticate]: when true, `authenticate()` never resolves
/// during the test — used to capture a stable `biometricGate` frame instead
/// of racing the bloc's auto-attempt-then-fail transition.
Future<({Widget widget, DatabaseTestHarness harness})> pumpableUnlockScreen({
  required String databasePath,
  List<DatabaseRecord> records = const [],
  Map<String, DatabaseSecurityProfile> securityProfiles = const {},
  bool biometricAvailable = false,
  bool biometricAuthenticateResult = true,
  bool hangBiometricAuthenticate = false,
  ThemeMode themeMode = ThemeMode.light,
}) async {
  final harness = _buildHarness();
  harness.registryRepository.records = records;
  harness.securityRepository.profiles.addAll(securityProfiles);
  harness.fileRepository.existingPaths.add(databasePath);

  // DatabaseUnlockScreen resolves its own bloc through DI (matches
  // production wiring in injection_container.dart). `_buildHarness()`
  // already registered a default (biometrics-unavailable) factory so other
  // pump helpers can reach the post-success navigation; replace it here
  // with one honouring this call's biometric parameters.
  di.sl.unregister<DatabaseUnlockBloc>();
  di.sl.registerFactoryParam<DatabaseUnlockBloc, String, void>(
    (path, _) => DatabaseUnlockBloc(
      databasePath: path,
      biometricDataSource: _FakeBiometricDataSource(
        available: biometricAvailable,
        authenticateResult: biometricAuthenticateResult,
        hangAuthenticate: hangBiometricAuthenticate,
      ),
      databaseSessionCoordinator: harness.coordinator,
    ),
  );

  final widget = MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('en', 'US'),
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    themeMode: themeMode,
    home: DatabaseUnlockScreen(databasePath: databasePath),
  );

  return (widget: widget, harness: harness);
}

/// Pumps `CreateDatabaseScreen` directly (no selection-list ancestry
/// needed): only requires a `DatabaseSelectionBloc` above it for step
/// policy (C-5).
Future<({Widget widget, DatabaseTestHarness harness})>
pumpableCreateDatabaseScreen({
  ThemeMode themeMode = ThemeMode.light,
  bool webMode = false,
}) async {
  final harness = _buildHarness();
  final bloc = DatabaseSelectionBloc(
    databaseSessionCoordinator: harness.coordinator,
  );

  final widget = MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('en', 'US'),
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    themeMode: themeMode,
    home: BlocProvider<DatabaseSelectionBloc>.value(
      value: bloc,
      child: CreateDatabaseScreen(debugWebMode: webMode ? true : null),
    ),
  );

  return (widget: widget, harness: harness);
}

/// Generic host for sheet/dialog goldens: opens [onOpen] once, right after
/// the first frame, so the golden captures the sheet already presented
/// (root navigator, as `KvBottomSheet.show` requires) without needing a
/// `tester.tap` round-trip.
Widget pumpableSheetHost({
  required Future<void> Function(BuildContext context) onOpen,
  ThemeMode themeMode = ThemeMode.light,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('en', 'US'),
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    themeMode: themeMode,
    home: _AutoOpenSheetHost(onOpen: onOpen),
  );
}

class _AutoOpenSheetHost extends StatefulWidget {
  const _AutoOpenSheetHost({required this.onOpen});

  final Future<void> Function(BuildContext context) onOpen;

  @override
  State<_AutoOpenSheetHost> createState() => _AutoOpenSheetHostState();
}

class _AutoOpenSheetHostState extends State<_AutoOpenSheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onOpen(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

Future<void> resetDatabaseTestDi() => di.sl.reset();

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

  _FakeBiometricDataSource({
    required this.available,
    this.authenticateResult = true,
    this.hangAuthenticate = false,
  });

  final bool available;
  final bool authenticateResult;
  final bool hangAuthenticate;
  final Completer<bool> _hangCompleter = Completer<bool>();

  @override
  Future<bool> authenticate({required String reason}) {
    if (hangAuthenticate) {
      return _hangCompleter.future;
    }
    return Future.value(authenticateResult);
  }

  @override
  Future<bool> isBiometricAvailable() async => available;
}
