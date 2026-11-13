# Implementation Plan: Entry detail — one home for attachments

**Branch**: `feat/020-attachments-section` | **Date**: 2026-08-31 | **Spec**: `spec.md`

## Summary

Turn the conditional `More` block of the entry detail into a permanent
`Attachments` section (count, `Manage`), drop the `Attachments` item from the
detail header overflow, amend spec 018 FR-011 in writing, update the tests that
pinned the old menu, re-record the five entry-detail goldens.

## Technical Context

Flutter 3.47.1 (`.fvmrc`), Dart. UI only — no BLoC, use case, repository or
KDBX change. `Manage` dispatches the existing `_EntryAction.attachments`, which
`vault_entries.part.dart` already routes to `_showAttachmentsDialog`. Tests:
`flutter_test` widget tests + goldens.

Superseded 2026-11-13: the `Manage` chip, `_EntryAction.attachments` and
`_showAttachmentsDialog` are retired. The detail lists the attachments with an
Export action per row; the editor adds and removes them with the save.

## Constitution Check

| Principle | Status |
|---|---|
| I secrets | untouched |
| II layering | untouched — presentation only |
| III tokens | section uses `AppTextStyles.labelUpper`, `KeyVaultColors`, existing pill; no hex |
| IV pixel fidelity | goldens named in SC-003; 1024 dark for entry detail was never recorded — pre-existing gap, not widened |
| V a11y | `Manage` reuses an existing ≥ 44 px pill; count is text, not colour |
| VI copy | changes named in FR-007 |
| VIII smallest thing | no new widget file; reuse `_MoreChip` (rename to `_ManagePill` only if it helps) or an existing pill |
| IX verify locally | tasks T008 |

No violations → no Complexity Tracking. No research.md / data-model.md /
contracts: no unknowns, no entities, no external interface.

## Project Structure

```text
lib/features/password_manager/presentation/screens/vault/
└── vault_entry_detail.part.dart        # section + header overflow (only prod file)

specs/018-desktop-vault-navigation/spec.md   # FR-011 amendment text (FR-006)
specs/_design/CONFORMANCE_AUDIT.md           # C-04-04 → resolved

test/features/password_manager/presentation/screens/vault/
├── vault_navigation_mobile_characterisation_test.dart   # 'record-action menu offers …'
├── vault_detail_dismissal_test.dart                     # FR-011 parity at 650/1024
├── vault_operation_context_test.dart                    # 'Attachments closes at …' via Manage
├── vault_action_inventory_test.dart                     # string inventory (+ `Manage`)
└── vault_entry_detail_actions_test.dart                 # new: count 0/n, Manage opens dialog
test/goldens/                                            # 5 entry_detail_* pngs re-recorded
```

**Structure Decision**: single part file changes; tests mirror it.

## Design

- Section = label row `ATTACHMENTS` (`labelUpper`, `textSecondary`) with the
  count beside it, then a `Manage` pill → `onSelectedAction(_EntryAction.attachments)`.
  Replaces the `if (entry.attachments.isNotEmpty) … 'More' … _MoreChip` block.
- Header overflow: delete the `_EntryAction.attachments` item and the spec-019
  comment above it. Enum value stays (list-row menu still uses it).
- FR-011 test edits follow the amended inventory: overflow = `Move`, `Delete`
  (+ `Duplicate`, `Record info`); section = `Attachments` + `Manage`.
