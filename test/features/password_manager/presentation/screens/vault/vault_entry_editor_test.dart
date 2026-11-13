// spec 023 US1b (T101) — the per-field "Secret" switch in the entry editor.
//
// A custom field the user marks secret is saved as a KDBX protected string
// (FR-002a) and, in the editor, its value is obscured with a show/hide
// affordance. Turning the switch off on a field that arrived protected asks
// first, naming the field.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/widgets/kv_switch.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_custom_field.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';

import 'vault_navigation_fixture.dart';
import 'vault_shell_test_utils.dart';

const _seed = 'abandon ability able about above absent';

const _wallet = VaultEntry(
  id: 'entry-wallet',
  groupId: NavigationFixtureVaultKdbxService.rootId,
  title: 'Wallet',
  username: 'me',
  password: 'Fixture-Pass-9d!z',
  url: '',
  notes: '',
  customFields: [
    VaultCustomField(key: 'Seed', value: _seed, isProtected: true),
    VaultCustomField(key: 'Network', value: 'mainnet'),
  ],
);

/// A vault written elsewhere may protect a URL-keyed custom string. The
/// editor's website list rebuilds its fields from plain text on save, so such
/// a field is kept as a custom field row instead, where it holds both its
/// Secret switch and its protection (FR-002a: never downgrade on an unrelated
/// save).
const _router = VaultEntry(
  id: 'entry-router',
  groupId: NavigationFixtureVaultKdbxService.rootId,
  title: 'Router',
  username: 'admin',
  password: 'Fixture-Pass-2c!k',
  url: '',
  notes: '',
  customFields: [
    VaultCustomField(
      key: 'KP2A_URL_1',
      value: 'https://admin.example',
      isProtected: true,
    ),
    VaultCustomField(key: 'KP2A_URL_2', value: 'https://plain.example'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetVaultShellTestDi);

  Future<NavigationFixtureVaultKdbxService> pump(
    WidgetTester tester, {
    List<VaultEntry> extraEntries = const [_wallet],
  }) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = NavigationFixtureVaultKdbxService()
      ..extraEntries.addAll(extraEntries);
    await tester.pumpWidget(
      await pumpableVaultShell(vaultKdbxService: service),
    );
    await tester.pumpAndSettle();
    return service;
  }

  Future<void> openEditor(WidgetTester tester, String title) async {
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('vault-detail-pane')),
        matching: find.byTooltip('Edit'),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder row(int id) => find.byKey(ValueKey('entry-custom-field-row-$id'));

  Finder switchIn(Finder row) =>
      find.descendant(of: row, matching: find.byType(KvSwitch));

  TextField valueFieldIn(WidgetTester tester, Finder row) => tester
      .widgetList<TextField>(
        find.descendant(of: row, matching: find.byType(TextField)),
      )
      .last;

  Future<void> tapSwitch(WidgetTester tester, Finder row) async {
    // The switch sits at the foot of a scrolling form.
    await tester.ensureVisible(switchIn(row));
    await tester.pumpAndSettle();
    await tester.tap(switchIn(row));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('a new field starts plain and readable', (tester) async {
    await pump(tester);
    await openEditor(tester, 'Gmail');
    await tester.tap(find.text('Custom field'));
    await tester.pumpAndSettle();

    expect(tester.widget<KvSwitch>(switchIn(row(0))).value, isFalse);
    expect(valueFieldIn(tester, row(0)).obscureText, isFalse);
    expect(find.byTooltip('Show value'), findsNothing);
  });

  testWidgets('switching Secret on obscures the value, the eye shows it', (
    tester,
  ) async {
    await pump(tester);
    await openEditor(tester, 'Gmail');
    await tester.tap(find.text('Custom field'));
    await tester.pumpAndSettle();

    await tapSwitch(tester, row(0));
    expect(valueFieldIn(tester, row(0)).obscureText, isTrue);

    await tester.ensureVisible(find.byTooltip('Show value'));
    await tester.tap(find.byTooltip('Show value'));
    await tester.pumpAndSettle();
    expect(valueFieldIn(tester, row(0)).obscureText, isFalse);
    expect(find.byTooltip('Hide value'), findsOneWidget);
  });

  testWidgets('saving carries the flag to the vault', (tester) async {
    final service = await pump(tester);
    await openEditor(tester, 'Gmail');
    await tester.tap(find.text('Custom field'));
    await tester.pumpAndSettle();

    final fields = find.descendant(
      of: row(0),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, 'PIN');
    await tester.enterText(fields.last, '1234');
    await tapSwitch(tester, row(0));
    await save(tester);

    final saved = service.calls.last;
    expect(saved.kind, 'update');
    expect(
      saved.customFields,
      contains(
        const VaultCustomField(key: 'PIN', value: '1234', isProtected: true),
      ),
    );
  });

  testWidgets(
    'switching off a field that arrived protected asks first; cancel keeps it',
    (tester) async {
      final service = await pump(tester);
      await openEditor(tester, 'Wallet');

      // Row 0 is Seed, row 1 is Network: the editor keeps the vault's order.
      expect(tester.widget<KvSwitch>(switchIn(row(0))).value, isTrue);
      expect(valueFieldIn(tester, row(0)).obscureText, isTrue);
      expect(tester.widget<KvSwitch>(switchIn(row(1))).value, isFalse);

      await tapSwitch(tester, row(0));
      expect(find.text('Stop protecting “Seed”?'), findsOneWidget);

      await tester.tap(find.text('Keep secret'));
      await tester.pumpAndSettle();
      expect(tester.widget<KvSwitch>(switchIn(row(0))).value, isTrue);

      await save(tester);
      expect(
        service.calls.last.customFields,
        contains(
          const VaultCustomField(key: 'Seed', value: _seed, isProtected: true),
        ),
      );
    },
  );

  testWidgets('confirming the switch-off saves the field as plain', (
    tester,
  ) async {
    final service = await pump(tester);
    await openEditor(tester, 'Wallet');

    await tapSwitch(tester, row(0));
    await tester.tap(find.text('Store as plain text'));
    await tester.pumpAndSettle();
    expect(tester.widget<KvSwitch>(switchIn(row(0))).value, isFalse);
    expect(valueFieldIn(tester, row(0)).obscureText, isFalse);

    await save(tester);
    expect(
      service.calls.last.customFields,
      contains(const VaultCustomField(key: 'Seed', value: _seed)),
    );
  });

  testWidgets('a protected URL-keyed field keeps its flag across a save', (
    tester,
  ) async {
    final service = await pump(tester, extraEntries: const [_router]);
    await openEditor(tester, 'Router');

    // It is a custom field row, switch on and value obscured — not a
    // website row, which would have neither.
    expect(tester.widget<KvSwitch>(switchIn(row(0))).value, isTrue);
    expect(valueFieldIn(tester, row(0)).obscureText, isTrue);

    await save(tester);

    final saved = service.calls.last.customFields;
    expect(
      saved,
      contains(
        const VaultCustomField(
          key: 'KP2A_URL_1',
          value: 'https://admin.example',
          isProtected: true,
        ),
      ),
    );
    // The plain website is renumbered around the name the protected field
    // holds, so the save never emits the same key twice.
    expect(
      saved,
      contains(
        const VaultCustomField(
          key: 'KP2A_URL_2',
          value: 'https://plain.example',
        ),
      ),
    );
    expect(
      saved.map((field) => field.key.toLowerCase()).toSet(),
      hasLength(saved.length),
    );
  });
}
