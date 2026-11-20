// Spec 025 T404 (FR-X5): Settings chooses and removes the database key file
// through the shared picker and `KeyFileRow`, the same slot unlock and create
// use. The re-key itself stays in `VaultSessionCoordinator`.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/utils/mobile_file_storage.dart';
import 'package:password_manager/features/password_manager/domain/usecases/create_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/get_active_database_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/link_database_to_remote_usecase.dart';
import 'package:password_manager/features/password_manager/domain/usecases/resolve_database_duplicate_usecase.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/database_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/session_secret_holder.dart';
import 'package:password_manager/features/password_manager/presentation/coordinators/vault_session_coordinator.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/key_file_picker.dart';
import 'package:password_manager/injection_container.dart' as di;

import '../../coordinators/fake_database_ports.dart';
import 'vault_shell_test_utils.dart';

const _keyPath = '/managed/keys/personal.key';

void main() {
  tearDown(() async {
    debugKeyFileLister = null;
    await resetVaultShellTestDi();
  });

  Future<_RecordingCoordinator> openSettings(
    WidgetTester tester, {
    String? persistedKey,
    bool refuse = false,
  }) async {
    final coordinator = _RecordingCoordinator(persistedKey, refuse: refuse);
    final widget = await pumpableVaultShell(
      vaultSessionCoordinator: coordinator,
    );
    // The shared picker asks this coordinator which keys are in use.
    final registry = FakeDatabaseRegistryRepository();
    final files = FakeDatabaseFileRepository();
    final sync = FakeDatabaseSyncRepository();
    di.sl.registerLazySingleton<DatabaseSessionCoordinator>(
      () => DatabaseSessionCoordinator(
        sessionSecretHolder: SessionSecretHolder(),
        databaseFileRepository: files,
        databaseSessionRepository: FakeDatabaseSessionRepository(),
        databaseRegistryRepository: registry,
        databaseSecurityRepository: FakeDatabaseSecurityRepository(),
        databaseSyncRepository: sync,
        linkDatabaseToRemote: LinkDatabaseToRemoteUseCase(sync),
        getActiveDatabaseUseCase: GetActiveDatabaseUseCase(registry),
        resolveDatabaseDuplicateUseCase: ResolveDatabaseDuplicateUseCase(
          registry,
          sync,
        ),
        unlockDatabaseUseCase: FakeUnlockDatabaseUseCase(),
        createDatabaseUseCase: CreateDatabaseUseCase(
          databaseFileRepository: files,
        ),
      ),
    );
    debugKeyFileLister = ({required subdirectory}) async => [
      AppStorageFileEntry(
        name: 'personal.key',
        path: _keyPath,
        sizeBytes: 64,
        modifiedAt: DateTime(2026, 1, 10),
      ),
    ];

    await tester.pumpWidget(widget);
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Settings'));
    await tester.pumpAndSettle();
    return coordinator;
  }

  testWidgets('choosing a key file goes through the shared picker and '
      're-keys with its path', (tester) async {
    final coordinator = await openSettings(tester);
    final row = find.text('Add a key file');
    await tester.ensureVisible(row);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Internal key files'), findsOneWidget);
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(coordinator.requests.single.keyFilePath, _keyPath);
    expect(coordinator.requests.single.changePassword, isFalse);
    expect(find.text('personal.key'), findsOneWidget);
    expect(find.text('Add a key file'), findsNothing);
  });

  testWidgets('removing the key file asks first, then re-keys without it', (
    tester,
  ) async {
    final coordinator = await openSettings(tester, persistedKey: _keyPath);
    final remove = find.byTooltip('Remove key file');
    await tester.ensureVisible(remove);
    expect(find.text('personal.key'), findsOneWidget);

    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.text('Remove key file?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(coordinator.requests, isEmpty);
    expect(find.text('personal.key'), findsOneWidget);

    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(coordinator.requests.single.keyFilePath, isNull);
    expect(find.text('Add a key file'), findsOneWidget);
  });

  testWidgets('a refused removal (last credential) restores the row', (
    tester,
  ) async {
    final coordinator = await openSettings(
      tester,
      persistedKey: _keyPath,
      refuse: true,
    );
    final remove = find.byTooltip('Remove key file');
    await tester.ensureVisible(remove);

    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(coordinator.requests, hasLength(1));
    expect(find.text('Unable to update database settings.'), findsOneWidget);
    expect(find.text('personal.key'), findsOneWidget);
  });
}

class _RecordingCoordinator implements VaultSessionCoordinator {
  _RecordingCoordinator(this._persistedKey, {required this.refuse});

  final String? _persistedKey;
  final bool refuse;
  final requests = <DatabaseSettingsUpdateRequest>[];

  @override
  Future<String?> getPersistedKeyFilePath(String databasePath) async =>
      _persistedKey;

  @override
  Future<String?> getSelectedKeyFilePath() async => null;

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
  ) async {
    requests.add(request);
    if (refuse) {
      throw Exception('At least one unlock credential is required.');
    }
    return DatabaseSettingsUpdateResult(
      databasePath: request.currentDatabasePath,
      passwordChanged: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
