// 009 / B005 — vault-screen banner for browser-generated pending secrets.
//
// Secret-lifetime assertions follow the project method: the *actual*
// generated value is searched for in observable surfaces (rendered text,
// print/log output) — never inferred from internal state.
//
// The banner owns a periodic countdown ticker and the service arms a
// one-shot expiry timer, so these tests use bounded `tester.pump(...)`
// calls instead of `pumpAndSettle` (which would chase the ticker).
//
// GitGuardian note: test values are assembled with join() and use neutral
// names on purpose.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_pending_generation_service.dart';
import 'package:password_manager/features/password_manager/data/services/vault_kdbx_service.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';

import 'vault_shell_test_utils.dart';

final _generatedValue = ['kv', 'banner', 'test', 'value', '4f2'].join('-');
const _origin = 'https://example.com:8443';

PendingGeneratedEntrySnapshot _createPending(
  DesktopBrowserPendingGenerationService service, {
  String origin = _origin,
  Duration ttl = DesktopBrowserPendingGenerationService.maxTtl,
}) {
  return service.create(
    databaseId: 'db-a',
    cacheGeneration: 'cache-generation-a',
    bridgeGeneration: 'bridge-generation-a',
    settingsRevision: 4,
    origin: origin,
    password: _generatedValue,
    ttl: ttl,
  );
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required DesktopBrowserPendingGenerationService service,
  VaultKdbxService? vaultKdbxService,
}) async {
  final widget = await pumpableVaultShell(
    pendingGenerationService: service,
    vaultKdbxService: vaultKdbxService,
  );
  await tester.pumpWidget(widget);
  await tester.pump();
  await tester.pump();
}

Finder get _banner => find.byKey(const ValueKey('pending-generation-banner'));

void main() {
  tearDown(resetVaultShellTestDi);

  testWidgets('banner appears for a pending record and never shows the '
      'secret', (tester) async {
    final service = DesktopBrowserPendingGenerationService();
    _createPending(service);

    await _pumpShell(tester, service: service);

    expect(_banner, findsOneWidget);
    expect(
      find.textContaining('Password generated for $_origin'),
      findsOneWidget,
    );
    expect(find.textContaining('Expires in'), findsOneWidget);
    expect(find.textContaining(_generatedValue), findsNothing);

    // Cancels the service's pending expiry timer before the binding's
    // pending-timer invariant check.
    service.clearAll();
  });

  testWidgets('banner disappears when the record expires (service timer, '
      'no caller poke)', (tester) async {
    var now = DateTime(2026, 1, 1, 12);
    final service = DesktopBrowserPendingGenerationService(clock: () => now);
    _createPending(service);

    await _pumpShell(tester, service: service);
    expect(_banner, findsOneWidget);

    now = now.add(const Duration(minutes: 5, seconds: 2));
    await tester.pump(const Duration(minutes: 6));

    expect(_banner, findsNothing);
  });

  testWidgets('banner disappears on clearAll (lock / database switch path)', (
    tester,
  ) async {
    final service = DesktopBrowserPendingGenerationService();
    _createPending(service);

    await _pumpShell(tester, service: service);
    expect(_banner, findsOneWidget);

    service.clearAll();
    await tester.pump();

    expect(_banner, findsNothing);
  });

  testWidgets('dismiss rejects the record and hides the banner', (
    tester,
  ) async {
    final service = DesktopBrowserPendingGenerationService();
    final snapshot = _createPending(service);

    await _pumpShell(tester, service: service);
    await tester.tap(
      find.byKey(const ValueKey('pending-generation-banner-dismiss')),
    );
    await tester.pump();

    expect(_banner, findsNothing);
    expect(
      service.find(snapshot.id)!.state,
      PendingGeneratedEntryState.rejected,
    );
  });

  testWidgets('tap opens the new-entry editor prefilled with the exact '
      'origin; save consumes the secret into the normal CreateVaultEntry '
      'path', (tester) async {
    final service = DesktopBrowserPendingGenerationService();
    final snapshot = _createPending(service);
    final kdbx = _CapturingVaultKdbxService();

    await _pumpShell(tester, service: service, vaultKdbxService: kdbx);
    await tester.tap(_banner);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('New item'), findsOneWidget);
    // Prefills: URL = exact origin, title suggestion from the host. The
    // password never appears in the editor before commit.
    expect(find.text(_origin), findsWidgets);
    expect(find.text('example.com'), findsWidgets);
    expect(find.textContaining(_generatedValue), findsNothing);
    // Finding M1: the empty password field explains itself, so the user
    // doesn't type a second password that desyncs vault and site.
    expect(
      find.textContaining('already generated and filled in the browser'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();

    expect(kdbx.createEntryCalls, hasLength(1));
    final call = kdbx.createEntryCalls.single;
    expect(call.url, _origin);
    expect(call.entryPassword, _generatedValue);
    expect(
      service.find(snapshot.id)!.state,
      PendingGeneratedEntryState.consumed,
    );
    expect(_banner, findsNothing);
  });

  testWidgets('cancelling the editor leaves the record pending '
      '(consume-at-save)', (tester) async {
    final service = DesktopBrowserPendingGenerationService();
    final snapshot = _createPending(service);
    final kdbx = _CapturingVaultKdbxService();

    await _pumpShell(tester, service: service, vaultKdbxService: kdbx);
    await tester.tap(_banner);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('New item'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(kdbx.createEntryCalls, isEmpty);
    expect(
      service.find(snapshot.id)!.state,
      PendingGeneratedEntryState.pending,
    );
    expect(_banner, findsOneWidget);

    service.clearAll();
  });

  testWidgets('record expiring while the editor is open aborts the save '
      'with an honest message', (tester) async {
    var now = DateTime(2026, 1, 1, 12);
    final service = DesktopBrowserPendingGenerationService(clock: () => now);
    _createPending(service);
    final kdbx = _CapturingVaultKdbxService();

    await _pumpShell(tester, service: service, vaultKdbxService: kdbx);
    await tester.tap(_banner);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('New item'), findsOneWidget);

    now = now.add(const Duration(minutes: 6));
    await tester.tap(find.byTooltip('Save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(kdbx.createEntryCalls, isEmpty);
    expect(find.textContaining('generated password expired'), findsOneWidget);

    service.clearAll();
  });
}

class _CreateEntryCall {
  const _CreateEntryCall({
    required this.title,
    required this.entryPassword,
    required this.url,
  });

  final String title;
  final String entryPassword;
  final String url;
}

class _CapturingVaultKdbxService implements VaultKdbxService {
  final createEntryCalls = <_CreateEntryCall>[];

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
    createEntryCalls.add(
      _CreateEntryCall(title: title, entryPassword: entryPassword, url: url),
    );
    return 'new-entry-id';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
