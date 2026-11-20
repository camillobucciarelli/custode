// spec-003 T1/T21: copy preservation comparison helper.
//
// Parses `strings_003_before.txt` (grouped by originating source file) and
// asserts every literal snapshot line still appears, byte-identical, in the
// current source of the file(s) that now render that surface — even if the
// literal moved to a new widget/file during the restyle. Only failures are
// reported so a human can confirm each is on the approved-additions list
// (or a genuine regression to fix).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Maps each snapshot section (source file name as it existed pre-spec-003)
/// to the current file(s) whose concatenated source must still contain
/// every literal from that section.
const _sectionToCurrentFiles = <String, List<String>>{
  'database_selection_screen.dart': [
    'lib/features/password_manager/presentation/screens/database_selection_screen.dart',
    'lib/features/password_manager/presentation/screens/welcome_screen.dart',
    'lib/features/password_manager/presentation/widgets/database/database_selection_sheets.dart',
    // Spec 025 S2: the Drive sheet became the shared remote file list and the
    // source and conflict sheets.
    'lib/features/password_manager/presentation/widgets/sync/remote_file_picker.dart',
    'lib/features/password_manager/presentation/widgets/sync/remote_file_list.dart',
    'lib/features/password_manager/presentation/widgets/database/database_source_sheet.dart',
    'lib/features/password_manager/presentation/widgets/database/database_conflict_sheet.dart',
    'lib/features/password_manager/presentation/widgets/database/database_grouped_list.dart',
  ],
  'create_database_dialog.dart': [
    'lib/features/password_manager/presentation/screens/create_database_screen.dart',
  ],
  'database_unlock_screen.dart': [
    'lib/features/password_manager/presentation/screens/database_unlock_screen.dart',
    'lib/features/password_manager/presentation/screens/database_unlock_widgets.part.dart',
    // Spec 025: the key-file slot and the biometric offer moved out of the
    // unlock screen into shared widgets.
    'lib/features/password_manager/presentation/widgets/key_file_picker.dart',
    'lib/features/password_manager/presentation/widgets/database/biometric_offer_sheet.dart',
  ],
  'database_unlock_widgets.part.dart': [
    'lib/features/password_manager/presentation/screens/database_unlock_widgets.part.dart',
    'lib/features/password_manager/presentation/widgets/key_file_picker.dart',
  ],
  'internal_key_file_manager_dialog.dart': [
    // Spec 025 T404: the sheet is the only key manager; settings reaches it
    // through `pickKeyFile` and the dialog is gone.
    'lib/features/password_manager/presentation/widgets/internal_key_file_manager_sheet.dart',
    // Its delete confirmation (and that dialog's `Cancel`) is the shared one.
    'lib/core/widgets/kv_confirm_dialog.dart',
  ],
  'recent_databases_section.dart': [
    'lib/features/password_manager/presentation/widgets/database/database_grouped_list.dart',
  ],
  'database_item_tile.dart': [
    'lib/features/password_manager/presentation/widgets/database/database_item_tile.dart',
  ],
  'database_action_menu.dart': [
    'lib/features/password_manager/presentation/widgets/database/database_action_menu.dart',
  ],
};

/// Literals whose visible surface was intentionally superseded by a
/// spec-003 layout redesign (not an accidental drop). Each entry is
/// reviewed and justified in `specs/003-database-and-unlock/spec.md`'s
/// FR-1/FR-3/FR-5 sections: the old "picker dialog"/"two-step unlock
/// narrative" UI those strings belonged to no longer exists as a surface.
const _approvedSupersededLiterals = <String>{
  // FR-3: Drive picker is now a tap-to-select sheet (skeleton loading, no
  // blocking "connecting" dialog, no separate list-then-Continue dialog,
  // no per-row modified date).
  'Connecting to Google Drive...',
  'No .kdbx files found in your Google Drive.',
  'Select Drive database',
  'Choose a .kdbx file from Google Drive.',
  'Unknown date',
  'Modified: ',
  'Continue',
  // FR-1: recent-list header/rows redesigned per spec ("Recent" label,
  // active-row accent tint instead of a "Most recent" text badge).
  'Managed databases',
  'Most recent',
  // 2026-09-05: the section lists every registered database (sorted by last
  // open), not a recency subset, so "Recent" wording was retired for
  // "Databases" across the header, search field, empty state and hint.
  'Multiple databases are available. Pick one from recent list or open another file.',
  'Search recent databases',
  'No recent database matches your search.',
  // spec 015 FR-1..FR-14: the create wizard collapsed to two steps with a
  // single credentials step — optional password, a three-way exclusive key
  // control replacing the switch-plus-button pair, and generation at
  // submit. The "Prepare generated key file" button, its picker dialogs,
  // the 'database.key' on-disk name (opaque since spec 014 FR-3) and the
  // snackbar tied to the deleted control were retired with the surface.
  'Please enter a password or choose a Key File.',
  'Key File (optional)',
  'Generate key file automatically',
  'On native platforms it will be saved in app internal storage.',
  'Choose the generated key file option to continue.',
  'Prepare generated key file',
  'Choose key file destination',
  'Generated key file will be saved in app internal storage',
  'Remove generated key file path',
  'Select Key File',
  'Select destination for generated key file',
  'Select destination folder for generated key file',
  'database.key',
  // FR-2: create wizard has per-step titles ("Step N of 3" + step-specific
  // heading) instead of one dialog title.
  'New Database Credentials',
  // FR-5: unlock is no longer a two-step "Step 1 of 2 / Step 2 of 2"
  // narrative inside one card — biometric gate, ready and decrypting are
  // now distinct phase-driven screens (C-4).
  'Unlock active vault by choosing at least one credential method.',
  'You can use the master password, a key file, or both.',
  'Step 1 of 2 - Verify identity',
  'Complete biometric verification before manual unlock.',
  'Biometric check completed.',
  'Biometric check not required for this vault.',
  'Step 2 of 2 - Provide unlock credentials',
  'Ready to unlock with: ',
  ' + ',
  'no credentials selected',
  'Select a key file or enter your master password to continue.',
  'Biometric verification is still required before unlocking.',
  // FR-5 explicitly approves new Face ID copy replacing these two exact
  // strings (spec-003 copy contract: "decrypting and Face ID strings").
  'Enable biometric protection?',
  'This database came from Google Drive. Do you want to require biometric authentication before unlock when available?',
  // FR-5 mock alignment (post-round mock delivery): the always-visible
  // "Select key file" outlined button is superseded by the "Use a key
  // file" inline link shown only when no key file is selected yet;
  // `_KeyFileSelector` is now only built once a key file exists.
  'Select key file',
  // Spec 025 FR-U1, FR-U6 (copy contract): the unlock layout drops its
  // helper line and the two button labels, the key slot is one row
  // ("Stored in Custode"), and the two biometric snackbars are retired with
  // the pre-unlock prompt.
  'Unlock vault',
  'Optional while a key file is selected.',
  'Required if no key file is selected.',
  'Stored in app internal key storage.',
  'Biometric protection enabled for this database.',
  'Biometric protection remains disabled for this database.',
  // Spec 025 S2 (copy contract, "Retired strings"): Open is one action with a
  // source sheet, the overwrite dialog and the 003 duplicate sheet are one
  // conflict sheet, and the welcome body is rewritten.
  'Open from Google Drive is currently desktop/mobile only.',
  'Replace existing database?',
  'A database named "',
  '" already exists in app storage. Do you want to replace it?',
  'Open existing database',
  'Choose a .kdbx file from your device',
  'Download a .kdbx and open a local copy',
  'Duplicate database detected',
  'Imported: ',
  'Choose how to continue.',
  'Use existing',
  'Open an existing KDBX database or create a new one to start securely storing your credentials.',
  // Spec 025 S3 (copy contract, FR-C2 to FR-C4): the wizard is rebuilt on the
  // Kv field recipe: field names follow the mockups, the storage paragraph
  // and the biometric helper line give way to source cards and the switch
  // row, and the default name no longer carries the extension.
  'Choose the database file name and security options. On native platforms, the database and generated key file are saved in app internal storage, so export manual backups regularly.',
  'Database file name',
  'Enter a database file name.',
  'Invalid characters in file name.',
  'Master Password',
  'Confirm Password',
  'Enable biometric protection',
  'If enabled, unlock requires biometric authentication when available.',
  'Remove key file',
  'new_database.kdbx',
  // OAuth env-key rename (refactor/oauth-env-key-names): dart-define keys now
  // map 1:1 to GCP OAuth client types, so the error copy references the new
  // key names (GOOGLE_WEB_CLIENT_ID / GOOGLE_IOS_CLIENT_ID).
  'Android Google Sign-In is not configured. Check GOOGLE_ANDROID_SERVER_CLIENT_ID.',
  'iOS Google Sign-In is not configured. Check GOOGLE_MOBILE_CLIENT_ID.',
  // Approved post-spec reconnect UX: the Drive surface stays open and exposes
  // an inline Reconnect CTA, so telling the user to open the surface again is
  // stale. The frozen pre-spec fixture remains unchanged as evidence.
  'Google Drive session expired or unavailable. Tap "Open from Google Drive" again and complete reconnection.',
};

void main() {
  test('every pre-spec-003 literal still appears in its surface\'s current '
      'source, or is on the reviewed approved-superseded list', () {
    final projectRoot = _findProjectRoot();
    final fixtureFile = File(
      p.join(projectRoot, 'test', 'fixtures', 'strings_003_before.txt'),
    );
    expect(fixtureFile.existsSync(), isTrue);

    final lines = fixtureFile.readAsLinesSync();
    String? currentSection;
    final missing = <String>[];
    var checked = 0;

    for (final rawLine in lines) {
      final sectionMatch = RegExp(r'^## (.+)$').firstMatch(rawLine);
      if (sectionMatch != null) {
        currentSection = sectionMatch.group(1);
        continue;
      }
      if (rawLine.startsWith('#') || rawLine.trim().isEmpty) {
        continue;
      }
      final section = currentSection;
      if (section == null) {
        continue;
      }
      final files = _sectionToCurrentFiles[section];
      if (files == null) {
        continue;
      }

      final haystack = files
          .map(
            (relative) =>
                File(p.join(projectRoot, relative)).readAsStringSync(),
          )
          .join('\n');
      checked += 1;
      if (!haystack.contains(rawLine) &&
          !_approvedSupersededLiterals.contains(rawLine)) {
        missing.add('[$section] "$rawLine"');
      }
    }

    expect(
      checked,
      greaterThan(50),
      reason: 'Sanity check: the fixture should have parsed >50 literals.',
    );

    expect(
      missing,
      isEmpty,
      reason:
          'Copy preservation violation(s) — each of these pre-spec-003 '
          'literals must still exist verbatim in its mapped file(s), '
          'unless newly approved by the spec-003 copy contract:\n'
          '${missing.join('\n')}',
    );
  });
}

String _findProjectRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate project root (pubspec.yaml).');
    }
    dir = parent;
  }
}
