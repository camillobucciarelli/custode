// spec 023 T211: the record the passkey goldens photograph, and the helpers
// the three files share (font loading, viewport, painted background).
//
// The keys come from `test/fixtures/passkeys/vectors.dart`: generated with
// `openssl genpkey` for the tests only, never registered anywhere. No golden
// may show a character of them (Constitution I), and every case asserts it.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_entry.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_passkey.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_snapshot.dart';

import '../features/password_manager/presentation/screens/vault/entry_editor_generator_test_utils.dart';
import '../fixtures/passkeys/vectors.dart';

/// Title of the record that holds the passkey; the tests tap it in the list.
const passkeyRecordTitle = 'Webauthn';
const passkeyRecordUsername = 'ada@example.com';

/// A usable ES256 passkey for webauthn.io, backed by the fixture PEM.
VaultPasskey buildFixturePasskey() => VaultPasskey(
  relyingPartyId: webauthnIoRpId,
  credentialId: Uint8List.fromList([1, 2, 3, 4]),
  privateKeyPem: es256PrivateKeyPem,
  algorithm: VaultPasskeyAlgorithm.es256,
  username: passkeyRecordUsername,
  createdAt: DateTime(2026, 3, 4, 10, 30),
);

/// The same credential with the truncated fixture PEM: parses as PEM, fails
/// as DER, so the section shows it as unusable with the "bad key" reason.
VaultPasskey buildUnusableFixturePasskey() => VaultPasskey(
  relyingPartyId: webauthnIoRpId,
  credentialId: Uint8List.fromList([1, 2, 3, 4]),
  privateKeyPem: truncatedPrivateKeyPem,
  algorithm: VaultPasskeyAlgorithm.es256,
  username: passkeyRecordUsername,
  createdAt: DateTime(2026, 3, 4, 10, 30),
  unusableReason: VaultPasskeyUnusableReason.badKey,
);

/// The standard fixture plus one record that holds [passkey] and no password.
VaultSnapshot buildPasskeySnapshot({VaultPasskey? passkey}) {
  final base = buildFixtureSnapshot();
  final record = VaultEntry(
    id: 'e-passkey',
    groupId: kRootGroupId,
    title: passkeyRecordTitle,
    username: passkeyRecordUsername,
    password: '',
    url: 'https://webauthn.io',
    notes: '',
    passkeys: [passkey ?? buildFixturePasskey()],
    passkeyDigest: 'digest',
    createdAt: DateTime(2026, 3, 4, 10, 30),
    updatedAt: DateTime(2026, 3, 4, 10, 30),
  );
  final entries = [record, ...base.entries];
  return VaultSnapshot(
    rootGroupId: base.rootGroupId,
    currentGroupId: base.currentGroupId,
    groups: base.groups,
    entries: entries,
    allEntries: entries,
  );
}

/// The fonts every golden in this repository renders with.
Future<void> loadGoldenFonts() async {
  await (FontLoader(
    'Caprasimo',
  )..addFont(rootBundle.load('assets/fonts/Caprasimo-Regular.ttf'))).load();
  await (FontLoader('Figtree')
        ..addFont(rootBundle.load('assets/fonts/Figtree-Regular.ttf'))
        ..addFont(rootBundle.load('assets/fonts/Figtree-SemiBold.ttf'))
        ..addFont(rootBundle.load('assets/fonts/Figtree-Bold.ttf')))
      .load();
}

void setGoldenViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// No line of either fixture key is on screen, not even as part of a longer
/// string. Each base64 line is searched for on its own, so a partial render
/// is caught too.
void expectNoKeyMaterialOnScreen() {
  final lines = {
    ...es256PrivateKeyPem.split('\n'),
    ...truncatedPrivateKeyPem.split('\n'),
  }.where((line) => line.trim().isNotEmpty);
  for (final line in lines) {
    expect(
      find.textContaining(line, findRichText: true),
      findsNothing,
      reason: 'a line of the fixture private key is rendered',
    );
  }
}

/// The colours actually painted behind [finder]: those of the nearest
/// ancestor that paints an opaque fill. Read off the tree, not assumed,
/// because the section is cards inside cards. One colour for a flat fill;
/// every stop for a gradient (the wide detail pane paints one), so the caller
/// can hold the text to the worst of them.
List<Color> paintedBackgroundsBehind(WidgetTester tester, Finder finder) {
  List<Color>? found;
  tester.element(finder).visitAncestorElements((element) {
    final widget = element.widget;
    var candidates = const <Color>[];
    if (widget is ColoredBox) {
      candidates = [widget.color];
    } else if (widget is DecoratedBox) {
      final decoration = widget.decoration;
      if (decoration is BoxDecoration) {
        final color = decoration.color;
        final gradient = decoration.gradient;
        if (color != null) {
          candidates = [color];
        } else if (gradient != null) {
          candidates = gradient.colors;
        }
      }
    } else if (widget is Material) {
      final color = widget.color;
      if (color != null) candidates = [color];
    }
    if (candidates.isNotEmpty && candidates.every((c) => c.a == 1.0)) {
      found = candidates;
      return false;
    }
    return true;
  });
  expect(found, isNotNull, reason: 'no painted background behind the text');
  return found!;
}
