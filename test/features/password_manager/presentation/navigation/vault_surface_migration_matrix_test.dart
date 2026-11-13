// spec-002 T12: exact named 19-row FR-7 migration matrix.
//
// Each case asserts the sealed presentation kind at 390/1024 for the surface
// type actually used at that call site, the typed result contract, and that
// the frozen title/action copy (and listed BLoC event / coordinator
// callback) from the T1 fixture still exists in the vault presentation
// sources. Must pass before the AC-8 `showDialog` sweep.
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/navigation/vault_shell_router.dart';

const _fixturePath = 'test/fixtures/vault_dialogs_002_before.txt';
const _vaultSourceDirs = [
  'lib/features/password_manager/presentation/screens/vault',
  // spec-005: CSV import preview/outcome (row 16) moved to a public,
  // independently-testable widget file outside the part-family (see
  // csv_import_screens.dart's doc comment — FilePicker has no test
  // platform-channel handler, so the screen needed to be pumpable without
  // going through _startCsvImportFlow).
  'lib/features/password_manager/presentation/widgets/csv',
  // 2026-08-31: row 14's security-confirm copy moved with the master-password
  // flow into ChangeMasterPasswordScreen (the combined dialog was retired).
  'lib/features/password_manager/presentation/screens',
];

Widget _noop(BuildContext context) => const SizedBox.shrink();

class _FixtureRow {
  const _FixtureRow({
    required this.index,
    required this.function,
    required this.title,
    required this.body,
    required this.action,
    required this.resultType,
    required this.mobile,
    required this.rail,
  });

  final String index;
  final String function;
  final String title;
  final String body;
  final String action;
  final String resultType;
  final String mobile;
  final String rail;
}

List<_FixtureRow> _loadFixture() {
  final lines = File(_fixturePath)
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty && !line.startsWith('#'))
      .toList(growable: false);
  return [
    for (final line in lines)
      () {
        final parts = line.split('|');
        return _FixtureRow(
          index: parts[0],
          function: parts[1],
          title: parts[2],
          body: parts[3],
          action: parts[4],
          resultType: parts[5],
          mobile: parts[6],
          rail: parts[7],
        );
      }(),
  ];
}

Matcher _presentationMatcher(String kind) => switch (kind) {
  'route' => isA<VaultRoutePresentation>(),
  'sheet' => isA<VaultSheetPresentation>(),
  'pane' => isA<VaultPanePresentation>(),
  // Amended 2026-08-30: group edit and move target are bare dialogs on wide
  // layouts (vault_navigation_contract.md §presentations).
  'dialog' => isA<VaultDialogPresentation>(),
  _ => throw ArgumentError('Unknown presentation kind: $kind'),
};

/// The concrete VaultSurface subtype used at each of the 19 real call sites
/// (verified against lib/…/vault/*.part.dart). Presentation kind depends
/// only on the surface's runtime type, so a lightweight instance with a
/// no-op builder is sufficient to exercise the real FR-6 dispatch.
final Map<String, VaultSurface<VaultDone>> _surfaceByRow = {
  '01': PasswordGeneratorSurface<VaultDone>(builder: _noop),
  '02': EntrySurface<VaultDone>(builder: _noop),
  '03': OtpScannerSurface<VaultDone>(builder: _noop),
  '04': GroupEditSurface<VaultDone>(builder: _noop),
  '05': ConfirmationSurface<VaultDone>(builder: _noop),
  '06': MoveTargetSurface<VaultDone>(builder: _noop),
  // Row 07 retired 2026-11-13 — see the fixture's supersession note.
  '08': SyncLinkSurface<VaultDone>(builder: _noop),
  '09': SyncConflictSurface<VaultDone>(builder: _noop),
  '10': DuplicatesSurface<VaultDone>(builder: _noop),
  // spec-005 FR-5: merge preview is a bottom sheet (spec.md screen 11),
  // not spec-002's provisional DuplicatesSurface/route guess.
  '11': MergePreviewSurface<VaultDone>(builder: _noop),
  '12': EntrySurface<VaultDone>(builder: _noop),
  // Row 13 retired 2026-08-31 — see the fixture's supersession note.
  '14': ConfirmationSurface<VaultDone>(builder: _noop),
  '15': RecycleBinSurface<VaultDone>(builder: _noop),
  '16': DatabaseSettingsSurface<VaultDone>(builder: _noop),
  '17': ConfirmationSurface<VaultDone>(builder: _noop),
  '18': ConfirmationSurface<VaultDone>(builder: _noop),
  '19': ConfirmationSurface<VaultDone>(builder: _noop),
};

/// Extra BLoC event / coordinator-callback names each row must preserve
/// (FR-7 "Existing effect to preserve" column). Checked as a literal
/// substring anywhere under the vault presentation sources.
final Map<String, List<String>> _effectByRow = {
  '02': ['CreateVaultEntry', 'UpdateVaultEntry'],
  '04': ['CreateVaultGroup', 'RenameVaultGroup'],
  '06': ['MoveVaultEntry', 'MoveVaultGroup'],
  '08': ['LoadRemoteFiles', 'LinkCurrentDatabaseToDrive'],
  '09': ['ClearVaultSyncFeedback', 'SyncCurrentDatabaseNow'],
  '10': ['LoadDuplicates'],
  '11': ['MergeDuplicateEntries'],
  '15': ['LoadRecycleBinEntries'],
  '16': ['ImportVaultEntriesFromCsv'],
  '17': ['CreateVaultEntry'],
  '18': ['changeDatabase'],
  '19': [
    'ConfirmAppleAutofillPendingAssociation',
    'RejectAppleAutofillPendingAssociation',
  ],
};

void main() {
  final rows = _loadFixture();
  late String vaultSources;

  setUpAll(() {
    final buffer = StringBuffer();
    for (final dir in _vaultSourceDirs) {
      for (final entity in Directory(dir).listSync()) {
        if (entity is File && entity.path.endsWith('.dart')) {
          buffer.write(entity.readAsStringSync());
        }
      }
    }
    vaultSources = buffer.toString();
  });

  test('fixture has exactly 17 live rows (rows 07 and 13 retired)', () {
    expect(rows.length, 17);
  });

  for (final row in rows) {
    test('${row.index} ${row.function}', () {
      final surface = _surfaceByRow[row.index];
      expect(
        surface,
        isNotNull,
        reason: 'no surface mapping for row ${row.index}',
      );

      expect(
        presentationFor(surface!, 390),
        _presentationMatcher(row.mobile),
        reason: '${row.function} mobile presentation must be ${row.mobile}',
      );
      expect(
        presentationFor(surface, 1024),
        _presentationMatcher(row.rail),
        reason: '${row.function} rail presentation must be ${row.rail}',
      );

      expect(
        vaultSources.contains(row.title),
        isTrue,
        reason: 'frozen title copy "${row.title}" missing from sources',
      );
      if (row.action != '-') {
        expect(
          vaultSources.contains(row.action),
          isTrue,
          reason: 'frozen action copy "${row.action}" missing from sources',
        );
      }
      for (final effect in _effectByRow[row.index] ?? const <String>[]) {
        expect(
          vaultSources.contains(effect),
          isTrue,
          reason: 'effect "$effect" missing from sources for ${row.function}',
        );
      }
    });
  }

  test('every row maps to a distinct surface family or a documented reuse', () {
    // 05/14/17/18/19 (confirmation sheets) and 02/12 (entry surface)
    // intentionally share a surface family per FR-6; every other row must
    // be unique. Row 13 (Database settings) was retired 2026-08-31, which
    // leaves row 16 (CSV import) as the sole DatabaseSettingsSurface user. spec-005 gave row
    // 11 (merge preview) its own `MergePreviewSurface` — it no longer
    // shares `DuplicatesSurface` with row 10 (FR-5: sheet, not route).
    final counts = <Type, int>{};
    for (final surface in _surfaceByRow.values) {
      counts[surface.runtimeType] = (counts[surface.runtimeType] ?? 0) + 1;
    }
    final shared = counts.entries.where((e) => e.value > 1).toList();
    expect(
      shared.map((e) => e.key.toString()).toSet(),
      {'ConfirmationSurface<VaultDone>', 'EntrySurface<VaultDone>'},
      reason: 'unexpected surface-family sharing; verify against FR-6 before merging rows',
    );
  });
}
