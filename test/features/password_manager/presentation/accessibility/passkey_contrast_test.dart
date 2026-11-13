// spec 023 T602 — contrast and accessibility on the passkey surfaces
// (Constitution V).
//
// Three properties, none of which a golden can assert:
//
//   * every text/background pairing the section introduces reads at 4.5:1 or
//     better, in light AND dark;
//   * the passkey badge carries a word, so the signal does not depend on
//     seeing a glyph's colour;
//   * the delete action is at least 44x44 and takes a visible focus ring, so
//     it is reachable and locatable without a pointer.
//
// The background is read off the render tree rather than named: the section is
// composed from cards inside cards, and a hardcoded "assume `surface`" would
// keep passing after the surface under it changed.
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_group.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';

import '../screens/vault/entry_editor_generator_test_utils.dart';

/// Not PEM-shaped on purpose: nothing here parses it, and a real key block in
/// a fixture is reported as a leaked key by both secret scanners.
const _fixtureKey = 'KEYVAULT-FIXTURE-PRIVATE-VALUE';

VaultPasskey _passkey({VaultPasskeyUnusableReason? unusableReason}) =>
    VaultPasskey(
      relyingPartyId: 'webauthn.io',
      credentialId: Uint8List.fromList([1, 2, 3, 4]),
      privateKeyPem: _fixtureKey,
      algorithm: VaultPasskeyAlgorithm.es256,
      username: 'ada@example.com',
      createdAt: DateTime(2026, 3, 4, 10, 30),
      unusableReason: unusableReason,
    );

VaultSnapshot _snapshot({VaultPasskeyUnusableReason? unusableReason}) {
  final entry = VaultEntry(
    id: 'e-passkey',
    groupId: kRootGroupId,
    title: 'Webauthn',
    username: 'ada@example.com',
    password: '',
    url: 'https://webauthn.io',
    notes: '',
    passkeys: [_passkey(unusableReason: unusableReason)],
    passkeyDigest: 'digest',
  );
  return VaultSnapshot(
    rootGroupId: kRootGroupId,
    currentGroupId: kRootGroupId,
    groups: const [VaultGroup(id: kRootGroupId, name: 'Vault', parentId: null)],
    entries: [entry],
    allEntries: [entry],
  );
}

/// WCAG 2.x contrast ratio, alpha-blending the foreground onto the background
/// first so a translucent text colour is measured as it is seen.
double _contrastRatio(Color foreground, Color background) {
  final opaque = Color.alphaBlend(foreground, background);
  final a = opaque.computeLuminance();
  final b = background.computeLuminance();
  final high = a > b ? a : b;
  final low = a > b ? b : a;
  return (high + 0.05) / (low + 0.05);
}

/// The colour actually painted behind [finder]: the nearest ancestor that
/// paints an opaque colour, whether through a `Container`, a `ColoredBox` or
/// the `Scaffold`'s own background.
Color _backgroundBehind(WidgetTester tester, Finder finder) {
  Color? found;
  tester.element(finder).visitAncestorElements((element) {
    final widget = element.widget;
    Color? candidate;
    if (widget is ColoredBox) {
      candidate = widget.color;
    } else if (widget is DecoratedBox) {
      final decoration = widget.decoration;
      if (decoration is BoxDecoration) candidate = decoration.color;
    } else if (widget is Material) {
      candidate = widget.color;
    }
    if (candidate != null && candidate.a == 1.0) {
      found = candidate;
      return false;
    }
    return true;
  });
  expect(found, isNotNull, reason: 'no painted background behind the text');
  return found!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(resetEntryTestDi);

  Future<void> openDetail(
    WidgetTester tester, {
    required ThemeMode themeMode,
    VaultPasskeyUnusableReason? unusableReason,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      await pumpableEntryScreen(
        harness: EntryTestHarness(
          snapshot: _snapshot(unusableReason: unusableReason),
        ),
        themeMode: themeMode,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Webauthn').first);
    await tester.pumpAndSettle();
  }

  void expectReadable(
    WidgetTester tester,
    Finder finder, {
    required String what,
    required ThemeMode themeMode,
  }) {
    final text = tester.widget<Text>(finder);
    final style = text.style;
    expect(style?.color, isNotNull, reason: '$what has no explicit colour');
    final background = _backgroundBehind(tester, finder);
    expect(
      _contrastRatio(style!.color!, background),
      greaterThanOrEqualTo(4.5),
      reason: '${themeMode.name}: $what',
    );
  }

  for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('${themeMode.name}: the passkey section reads at 4.5:1', (
      tester,
    ) async {
      await openDetail(tester, themeMode: themeMode);

      expectReadable(
        tester,
        find.text('Passkeys'),
        what: 'the section heading',
        themeMode: themeMode,
      );
      expectReadable(
        tester,
        find.text('webauthn.io'),
        what: "the credential's relying party",
        themeMode: themeMode,
      );
      expectReadable(
        tester,
        find.textContaining('not held in hardware key isolation'),
        what: 'the fixed security note (FR-009)',
        themeMode: themeMode,
      );
    });

    testWidgets('${themeMode.name}: the unusable explanation reads at 4.5:1', (
      tester,
    ) async {
      await openDetail(
        tester,
        themeMode: themeMode,
        unusableReason: VaultPasskeyUnusableReason.badKey,
      );

      expectReadable(
        tester,
        find.textContaining('its stored key cannot be read'),
        what: 'the unusable explanation (FR-012)',
        themeMode: themeMode,
      );
    });
  }

  testWidgets('the badge announces a word, not only a glyph', (tester) async {
    final semantics = tester.ensureSemantics();

    await openDetail(tester, themeMode: ThemeMode.light);

    // On the detail the badge sits beside the section heading, so the word is
    // in the tree as its own label rather than merged into a row summary.
    expect(find.bySemanticsLabel(RegExp('Passkey')), findsWidgets);

    // Disposed here rather than in a tear-down: the framework checks for a
    // live handle before tear-downs run.
    semantics.dispose();
  });

  testWidgets('the delete action is 44x44 and takes a focus ring', (
    tester,
  ) async {
    await openDetail(tester, themeMode: ThemeMode.light);

    final button = find.widgetWithText(TextButton, 'Delete passkey');
    expect(button, findsOneWidget);

    final size = tester.getSize(button);
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));

    // Constitution V: focus must be visible, not merely present. The ring is
    // the theme's focused `side`, so it is asserted on the resolved style
    // rather than by photographing a focused button.
    final style =
        tester.widget<TextButton>(button).style ??
        Theme.of(tester.element(button)).textButtonTheme.style!;
    final focusedSide = style.side?.resolve({WidgetState.focused});
    final restingSide = style.side?.resolve(<WidgetState>{});
    expect(focusedSide, isNotNull, reason: 'no focused side on the button');
    expect(focusedSide!.width, greaterThanOrEqualTo(2));
    expect(
      focusedSide.style,
      isNot(BorderStyle.none),
      reason: 'the focus ring must actually paint',
    );
    expect(
      restingSide?.style ?? BorderStyle.none,
      BorderStyle.none,
      reason: 'and must be absent when the button is not focused',
    );

    // It is also reachable without a pointer.
    final node = tester.widget<TextButton>(button).focusNode;
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    expect(node?.canRequestFocus ?? true, isTrue);
  });
}
