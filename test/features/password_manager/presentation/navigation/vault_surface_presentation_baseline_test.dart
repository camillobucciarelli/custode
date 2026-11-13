// spec-018 T005: a snapshot of `presentationFor`'s answer for every surface
// at every width that spec-018 cares about.
//
// Written BEFORE the production change and first run against unmodified
// code, then updated once — deliberately — for the two answer changes
// spec-018 mandates:
//
//   1. FR-002d: the pane break moved from 600 to the derived 704. A pane
//      needs 72 + 330 + 300 + 2 px of room, and the old code handed one out
//      at 600, in a band where the design's own columns do not fit.
//   2. FR-002e: PasswordGeneratorSurface becomes a column at >= 995.
//
// Nothing at or below 599 changed — asserted explicitly below, because that
// is the width US5 protects.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/navigation/vault_shell_router.dart';

/// The widths spec-018 names: the mobile break, the derived pushed-detail
/// threshold (704), the folder-collapse point (941), the generator-column
/// point (995), and the design's tablet baseline — each probed on both sides.
const _widths = <double>[390, 599, 600, 703, 704, 940, 941, 994, 995, 1024];

String _label(VaultSurfacePresentation presentation) => switch (presentation) {
  VaultRoutePresentation() => 'route',
  VaultSheetPresentation() => 'sheet',
  VaultPanePresentation() => 'pane',
  VaultDialogPresentation() => 'dialog',
};

Widget _noop(BuildContext context) => const SizedBox.shrink();

void main() {
  final surfaces = <String, VaultSurface<VaultDone>>{
    'EntrySurface': EntrySurface<VaultDone>(builder: _noop),
    'OtpScannerSurface': OtpScannerSurface<VaultDone>(builder: _noop),
    'PasswordGeneratorSurface': PasswordGeneratorSurface<VaultDone>(
      builder: _noop,
    ),
    'GroupEditSurface': GroupEditSurface<VaultDone>(builder: _noop),
    'MoveTargetSurface': MoveTargetSurface<VaultDone>(builder: _noop),
    'RecycleBinSurface': RecycleBinSurface<VaultDone>(builder: _noop),
    'DuplicatesSurface': DuplicatesSurface<VaultDone>(builder: _noop),
    'HealthCategorySurface': HealthCategorySurface<VaultDone>(builder: _noop),
    'SyncLinkSurface': SyncLinkSurface<VaultDone>(builder: _noop),
    'SyncConflictSurface': SyncConflictSurface<VaultDone>(builder: _noop),
    'MergePreviewSurface': MergePreviewSurface<VaultDone>(builder: _noop),
    'SyncMergeSurface': SyncMergeSurface<VaultDone>(builder: _noop),
    'DatabaseSettingsSurface': DatabaseSettingsSurface<VaultDone>(
      builder: _noop,
    ),
    'KeyFileManagerSurface': KeyFileManagerSurface<VaultDone>(builder: _noop),
    'ConfirmationSurface': ConfirmationSurface<VaultDone>(builder: _noop),
  };

  // spec-018 FR-002d: "narrow" is now BELOW 704, not below 600. A pane needs
  // 72 + 330 + 300 + 2 = 704 px of room, so the 600-703 band keeps the pushed
  // presentation and only swaps the tab bar for the icon rail. Recorded as
  // data so a diff on this map is a diff on behaviour.
  const expected = <String, ({String narrow, String wide})>{
    'EntrySurface': (narrow: 'route', wide: 'pane'),
    'OtpScannerSurface': (narrow: 'route', wide: 'pane'),
    // Overridden below 995 by its own rule; the table's "wide" value is what
    // holds from 995 up, which covers every probed width >= 995.
    'PasswordGeneratorSurface': (narrow: 'sheet', wide: 'pane'),
    // Amended 2026-08-30 with the Manage dialog walk: pane-hosting rendered
    // these behind an open dialog. On wide they are bare dialogs now; the
    // contract table was amended in the same change.
    'GroupEditSurface': (narrow: 'sheet', wide: 'dialog'),
    'MoveTargetSurface': (narrow: 'sheet', wide: 'dialog'),
    // 2026-08-31 (user-directed): hygiene destinations and the merge
    // preview are full-screen pushed routes at every width.
    'RecycleBinSurface': (narrow: 'route', wide: 'route'),
    'DuplicatesSurface': (narrow: 'route', wide: 'route'),
    'HealthCategorySurface': (narrow: 'route', wide: 'pane'),
    'SyncLinkSurface': (narrow: 'route', wide: 'pane'),
    'SyncConflictSurface': (narrow: 'sheet', wide: 'pane'),
    'MergePreviewSurface': (narrow: 'route', wide: 'route'),
    // spec-008 T601: the per-field merge review lays out its own panes.
    'SyncMergeSurface': (narrow: 'route', wide: 'route'),
    'DatabaseSettingsSurface': (narrow: 'route', wide: 'pane'),
    'KeyFileManagerSurface': (narrow: 'sheet', wide: 'sheet'),
    // 2026-09-05 (user-directed): yes/no confirmations are dialogs at every
    // width.
    'ConfirmationSurface': (narrow: 'dialog', wide: 'dialog'),
  };

  group('presentationFor baseline', () {
    for (final entry in surfaces.entries) {
      test('${entry.key} across every spec-018 width', () {
        final want = expected[entry.key]!;
        for (final width in _widths) {
          if (entry.key == 'PasswordGeneratorSurface' &&
              width >= 704 &&
              width < 995) {
            // Covered by its own dedicated test: inside the wide band but
            // below the generator-column threshold it is still a sheet.
            continue;
          }
          final got = _label(presentationFor(entry.value, width));
          final wanted = width < 704 ? want.narrow : want.wide;
          expect(
            got,
            wanted,
            reason: '${entry.key} at ${width}px expected $wanted, got $got',
          );
        }
      });
    }

    test('the pane break is exactly 704, exclusive', () {
      final surface = EntrySurface<VaultDone>(builder: _noop);
      expect(_label(presentationFor(surface, 703)), 'route');
      expect(_label(presentationFor(surface, 704)), 'pane');
    });

    // US5's load-bearing assertion: nothing about the phone width moved.
    test('390 and 599 are unchanged from before spec-018', () {
      for (final entry in surfaces.entries) {
        final want = expected[entry.key]!.narrow;
        expect(_label(presentationFor(entry.value, 390)), want);
        expect(_label(presentationFor(entry.value, 599)), want);
      }
    });

    // FR-002e: the generator is the only surface that changes answer inside
    // a single layout class.
    test('the generator becomes a column at exactly 995', () {
      final generator = PasswordGeneratorSurface<VaultDone>(builder: _noop);
      expect(_label(presentationFor(generator, 994)), 'sheet');
      expect(_label(presentationFor(generator, 995)), 'pane');
    });

    // G2.1: the icon rail replaces the tab bar at 600, but that is chrome.
    // The presentation of a surface must NOT change there for anything the
    // user pushes — this is what keeps mobile behaviour intact when the
    // layout class is introduced.
    test('600 and 703 agree with each other', () {
      for (final entry in surfaces.entries) {
        expect(
          _label(presentationFor(entry.value, 600)),
          _label(presentationFor(entry.value, 703)),
          reason: '${entry.key} must not change between 600 and 703',
        );
      }
    });
    // ─────────────────────────────────────────────────────────────────────
    // spec-019 T004 / FR-019 — contract S1.
    //
    // Spec 019 adds one presentation (`VaultDialogPresentation`); its
    // `ManageFoldersSurface` was later retired (2026-08-30) in favour of row
    // actions on the tree itself. Adding a row to `presentationFor` must not
    // move any row that was already there. The table below is a literal
    // snapshot taken from the code at spec-019 HEAD, one string per surface
    // holding its answer at each of the eight boundary widths in order:
    //
    //     599 600 703 704 940 941 994 995
    //
    // It is written out rather than derived so that a behaviour change shows
    // up as a diff on a string, not as a change in the rule that produced it.
    // If you are adding a surface and this fails, you changed an existing
    // one's answer — that is FR-019's whole subject.
    //
    // Contract S2, which has no assertion here because it is a statement
    // about another file: `test/core/responsive/vault_layout_class_test.dart`
    // must stay green WITHOUT edits for the whole of spec 019. The width
    // thresholds are spec 018's and spec 019 does not touch them; an edit to
    // that file during this spec is a regression, not a test being updated.
    group('spec-019 FR-019: pre-existing rows are frozen', () {
      const boundaries = <double>[599, 600, 703, 704, 940, 941, 994, 995];
      const frozen = <String, String>{
        'EntrySurface': 'route route route pane pane pane pane pane',
        'OtpScannerSurface': 'route route route pane pane pane pane pane',
        'PasswordGeneratorSurface':
            'sheet sheet sheet sheet sheet sheet sheet pane',
        'GroupEditSurface':
            'sheet sheet sheet dialog dialog dialog dialog dialog',
        'MoveTargetSurface':
            'sheet sheet sheet dialog dialog dialog dialog dialog',
        // 2026-11-13 (user-directed): `AttachmentsSurface` is retired. The
        // detail lists a record's attachments and the editor adds and
        // removes them, so the separate surface has no caller left.
        // 2026-08-31 (user-directed): full-screen routes at every width.
        'RecycleBinSurface': 'route route route route route route route route',
        'DuplicatesSurface': 'route route route route route route route route',
        'HealthCategorySurface': 'route route route pane pane pane pane pane',
        'SyncLinkSurface': 'route route route pane pane pane pane pane',
        'SyncConflictSurface': 'sheet sheet sheet pane pane pane pane pane',
        // 2026-08-31 (user-directed): full-screen route at every width.
        'MergePreviewSurface':
            'route route route route route route route route',
        // spec-008 T601 (added after 019, frozen from its first commit).
        'SyncMergeSurface': 'route route route route route route route route',
        'DatabaseSettingsSurface': 'route route route pane pane pane pane pane',
        'KeyFileManagerSurface':
            'sheet sheet sheet sheet sheet sheet sheet sheet',
        // 2026-09-05 (user-directed): dialog at every width.
        'ConfirmationSurface':
            'dialog dialog dialog dialog dialog dialog dialog dialog',
      };

      test('every surface that existed before spec 019 is still listed', () {
        expect(frozen.keys.toSet(), surfaces.keys.toSet());
      });

      for (final entry in surfaces.entries) {
        test('${entry.key} answers exactly as it did before spec 019', () {
          final got = boundaries
              .map((w) => _label(presentationFor(entry.value, w)))
              .join(' ');
          expect(
            got,
            frozen[entry.key],
            reason:
                '${entry.key} changed its presentation at one of '
                '599/600/703/704/940/941/994/995. Spec 019 adds surfaces; '
                'it does not move existing ones (FR-019).',
          );
        });
      }
    });
  });
}
