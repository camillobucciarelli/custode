import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_glyph.dart';
import 'package:password_manager/core/widgets/kv_icon.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/presentation/utils/platform_utils.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_source_sheet.dart';

import '../../../presentation/coordinators/fake_database_ports.dart';
import '../../screens/database_selection_unlock_test_utils.dart';

void main() {
  tearDown(() async {
    debugPlatformCapabilities = null;
    await resetDatabaseTestDi();
  });

  /// Opens the sheet over a host and reports what it resolved to.
  Future<DatabaseTestHarness> open(
    WidgetTester tester,
    List<DatabaseSource?> results, {
    FakeDatabaseSyncRepository? sync,
  }) async {
    final harness = (await pumpableSelectionScreen(syncRepository: sync))
        .harness;
    await tester.pumpWidget(
      pumpableSheetHost(
        onOpen: (context) async =>
            results.add(await showDatabaseSourceSheet(context)),
      ),
    );
    await tester.pumpAndSettle();
    return harness;
  }

  testWidgets('not connected: Connect action, privacy line, no sign-in', (
    tester,
  ) async {
    final sync = FakeDatabaseSyncRepository();
    await open(tester, [], sync: sync);

    expect(find.text('Where is your database?'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Pick a .kdbx file'), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(
      find.text(
        'Custode only reads the file you pick. Your master password never '
        'leaves this device.',
      ),
      findsOneWidget,
    );
    expect(sync.connectCalls, 0);
  });

  testWidgets('the title is a heading and This device is not drawn as a '
      'desktop monitor', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, []);

    expect(
      tester.getSemantics(find.text('Where is your database?')),
      isSemantics(isHeader: true),
    );
    expect(
      tester.widgetList<KvIcon>(find.byType(KvIcon)).map((icon) => icon.glyph),
      isNot(contains(AppGlyph.desktop)),
    );
    handle.dispose();
  });

  testWidgets('connected with an email shows it and no Connect action', (
    tester,
  ) async {
    final sync = FakeDatabaseSyncRepository()
      ..connected = true
      ..account = const StorageAccountSummary(
        displayLabel: 'mara@example.com',
        email: 'mara@example.com',
      );
    await open(tester, [], sync: sync);

    expect(find.text('mara@example.com'), findsOneWidget);
    expect(find.text('Not connected'), findsNothing);
    expect(find.text('Connect'), findsNothing);
    expect(sync.connectCalls, 0);
  });

  testWidgets('connected without an email falls back to the generic label', (
    tester,
  ) async {
    final sync = FakeDatabaseSyncRepository()..connected = true;
    await open(tester, [], sync: sync);

    expect(find.text('Google Drive account'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
  });

  testWidgets('an account lookup failure degrades to Not connected', (
    tester,
  ) async {
    final sync = FakeDatabaseSyncRepository()
      ..connected = true
      ..accountError = Exception('offline');
    await open(tester, [], sync: sync);

    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('web override: Drive stays in place, disabled, with its reason', (
    tester,
  ) async {
    debugPlatformCapabilities = const PlatformCapabilities(
      supportsRemoteSource: false,
      supportsBiometricUnlock: false,
      persistsDatabases: false,
    );
    final results = <DatabaseSource?>[];
    await open(tester, results);

    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('Not available in the browser'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    await tester.tap(find.text('Google Drive'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(find.text('Where is your database?'), findsOneWidget);
  });

  for (final entry in {
    'This device': DatabaseSource.device,
    'Google Drive': DatabaseSource.remote,
  }.entries) {
    testWidgets('${entry.key} resolves to ${entry.value.name}', (tester) async {
      final results = <DatabaseSource?>[];
      await open(tester, results);

      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();

      expect(results, [entry.value]);
    });
  }

  testWidgets('dismissal resolves to null', (tester) async {
    final results = <DatabaseSource?>[];
    await open(tester, results);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(results, [null]);
    expect(tester.takeException(), isNull);
  });
}
