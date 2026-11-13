# Implementation Plan: Desktop vault navigation and entry actions

**Branch**: `fix/desktop-vault-navigation` (worktree `password-manager-018-desktop-nav`)
**Date**: 2026-08-28
**Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/018-desktop-vault-navigation/spec.md`

## Summary

Spec 018 fixes the defects D1-D9 in the vault's wide-window navigation and its
record actions. The root cause is singular and structural: **two independent
detail mechanisms exist** - `_EntriesCardState`'s private inline split and
`VaultShellRouter`'s pane - selected by three disagreeing width rules.
Everything else (no selection highlight, stale writes, silently dropped
actions, dead panes after delete, the editor blanking the record) follows from
that split ownership.

The approach is therefore **deletion, not addition**: remove the records list's
private detail rendering and its `_selectedEntryId` state, promote the selected
record to shell-owned state, and route every record-detail presentation through
the existing `VaultShellRouter`. The router already handles push/sheet/pane
presentation, nested-surface stacks, discard guards and dismissal - the fix
makes the list and the shell agree with it rather than adding a fourth
mechanism.

Layout constants are replaced by three derived widths (704 / 941 / 995) from
the 2026-08-28 design decision, and the undocumented `708` in
`vault_shell.part.dart` is removed.

## Technical Context

**Language/Version**: Dart 3.x / Flutter **3.47.1** (pinned in `.fvmrc`)

**Primary Dependencies**: `flutter_bloc`, `get_it`, `equatable` - all already
present. **No new dependency is introduced by this plan.**

**Storage**: N/A - presentation-layer only. No KDBX write path, no
`DatabasePathMutex`, no safe-writer, no sync metadata is touched.

**Testing**: `flutter_test`; widget tests under
`test/features/password_manager/presentation/`, goldens under `test/goldens/`
with the deterministic harness in `vault_shell_test.dart` (fixed physical size,
DPR 1, explicit font loading, `resetVaultShellTestDi` teardown)

**Target Platform**: all six - the change is width-driven, not
platform-driven. Desktop and tablets exercise the wide bands; phones stay on
the narrow band.

**Project Type**: Cross-platform Flutter application

**Performance Goals**: no new per-frame work. The selected record moves from
`setState` in one card to shell state; rebuild scope must not widen - the
records list must not rebuild on every detail-pane change.

**Constraints**: mobile behaviour byte-identical (US5/FR-012); no 390x844
golden added, removed or re-recorded (VR-003); no new BLoC (Constitution II);
`flutter analyze` clean and `flutter test` green before commit (Constitution IX)

**Scale/Scope**: ~6 files in `presentation/`, one of them
(`vault_entries.part.dart`) losing code rather than gaining it.

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1.*

| # | Principle | Verdict | Note |
|---|---|---|---|
| I | Secrets never leak into the shell | **PASS** | The shell-owned selection holds an entry **id**, never an entry or a secret. `RevealController` and its biometric gate stay inside `_EntryDetailPanel`, unchanged. No new value enters `props`/`toString`. |
| II | Clean architecture layering holds | **PASS** | Presentation-only. No new BLoC - the selected record is shell widget state, not vault state, because it is a view concern with no persistence. No new coordinator: this is not a multi-step workflow. |
| III | Design tokens are the only source | **PASS** | Column widths and the selected-row treatment come from `PIXEL_SPEC`; the row treatment maps to `CustodeColors` accent roles. New numbers are layout metrics with a stated derivation, not colours. |
| IV | Pixel fidelity is testable | **PASS** | VR-001 names three new golden pairs at 1024x768 light and dark; VR-002 names the widget assertions replacing pixels and states the omitted axes. |
| V | Accessibility floor | **PASS** | FR-004a keeps a non-colour selection cue; FR-002e forbids dimming the records list. Focus ring and 44px targets unchanged. |
| VI | Existing behaviour and copy preserved | **PASS** | FR-013 freezes navigation and action strings. No user-facing string is added or altered. |
| VII | Destructive operations ask first | **PASS** | Delete keeps `_showDeleteConfirm`. FR-006 makes the action more reliable, never skips the prompt. |
| VIII | Ship the smallest thing | **PASS** | Net-negative in code. `VaultLayoutClass` is a value the shell computes and passes, not an interface. The rail folder-switcher is explicitly deferred. |
| IX | Verification is local, before the push | **PASS** | Gate 6 runs `flutter analyze`, the full `flutter test`, and the golden suite under a randomised seed per the repo's ordering rule. |

**No violations. Complexity Tracking table omitted.**

## Project Structure

### Documentation (this feature)

```text
specs/018-desktop-vault-navigation/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- vault_navigation_contract.md
|-- checklists/requirements.md
`-- tasks.md              # /speckit-tasks output - NOT created here
```

### Source code touched

```text
lib/core/responsive/
`-- breakpoints.dart                      # + derived vault layout widths

lib/features/password_manager/presentation/
|-- navigation/
|   `-- vault_shell_router.dart           # presentationFor takes the layout class
`-- screens/vault/
    |-- vault_shell.part.dart             # owns selection + layout class; 708 removed
    |-- vault_entries.part.dart           # LOSES its inline split and _selectedEntryId
    |-- vault_entry_detail.part.dart      # dismissal via the operation scope
    |-- vault_entries_details.part.dart   # selected-row treatment
    `-- vault_entry_editor.part.dart      # generator column vs sheet at 995
```

**Structure Decision**: no new directories. The change lives entirely in the
existing `presentation/navigation/` and `presentation/screens/vault/` trees,
respecting the repo rule that vault UI goes in the owning `*.part.dart` file
and never in `vault_screen.dart`.

## Approach

### The single structural change

Today:

```text
_EntriesCardState._selectedEntryId  --> its own Row(list | _EntryDetailPanel)
VaultShellRouter._sessions          --> _activePane --> shell's detail slot
```

Two owners, two width rules, no shared state. After:

```text
_VaultViewState._selectedEntryId --(id)--> _router.open(EntrySurface)
                                                  |
                                 layout class ----+
                                                  v
                            push (narrow) | pane (wide) - one detail widget
```

The records list becomes a pure reporter: it renders rows, marks one selected
from a value passed in, and calls back with an id. It renders no detail.

### Why the router wins over the inline split

The router already owns nested-surface stacks, parent/child cancellation
(`_finish` cancels children), discard guards, and the push/sheet/pane switch.
The inline split has none of these - which is precisely why D6 (dead pane after
delete) and D8 (back desyncs selection) exist only on the wide path. Keeping
the split would mean reimplementing all four in a second place.

### Defect to fix map

| Defect | Fix | Requirement |
|---|---|---|
| D1 two detail surfaces | delete the inline split from `vault_entries.part.dart` | FR-001, FR-001a |
| D2 three width rules | one `VaultLayoutClass` computed by the shell; `presentationFor` takes it instead of its own `MediaQuery` lookup | FR-002, FR-002a |
| D3 no highlight | selection passed into the list; row uses the `PIXEL_SPEC` treatment plus a non-colour cue | FR-004, FR-004a |
| D4 stale entry | actions re-read the entry from `VaultBloc` by id **at confirmation time**, never from a captured snapshot | FR-005 |
| D5 dropped actions | guard on the surface's own context, not `_EntriesCardState.mounted`; capture the bloc before the await | FR-006 |
| D6 dead pane after delete | `_EntryDetailsPage` completes its `VaultOperationScope` instead of calling `Navigator.pop` | FR-007, FR-008 |
| D7 editor blanks the record | editor keeps the record title in its header and the selection alive; completion restores the detail | FR-009, FR-009a |
| D8 back desyncs | one selection owner; pane cancellation clears it through the same setter | FR-003, FR-008 |
| D9 origin-dependent UI | every origin calls `_openEntryDetailsSurface` | FR-010 |
| stale `708` | replaced by derived 704 / 941 / 995 with the arithmetic beside them | FR-002a, FR-002d |

### Deliberately NOT done

- **No new BLoC or coordinator.** The selection is view state with no
  persistence and no multi-step workflow (Constitution II and VIII).
- **No rail folder-switcher.** New UI, not a navigation fix; the list's folder
  rows already keep every folder reachable in the 704-940 band. Deferred per
  the spec's scope note.
- **No `PIXEL_SPEC.md` rewrite.** It still carries `72 (76 in the vault
  variant)` and `330-352` in both repo copies. Correcting it is owed, but it is
  a design-source change - recorded in the spec's follow-up section, to land as
  its own `docs:` change.
- **No redesign of the detail or editor content.** Only where they are hosted,
  who owns the selection, and when actions fire.

## Gates

Ordered; each gate must be green before the next starts.

- **Gate 0 - Characterise before changing.** Add widget tests pinning *today's*
  mobile behaviour (tap -> push, back -> list, all four actions from the pushed
  detail) and today's router presentation matrix. These must pass **before** any
  production edit, so US5 regressions are caught by a test that predates the
  change rather than one written to match it.

- **Gate 1 - One width authority.** Add the derived widths to
  `breakpoints.dart` with their arithmetic as comments. Introduce the layout
  class in the shell and thread it into `presentationFor`. Delete the `708`
  literal and the `Breakpoints.tablet` folder gate. Rail 76 -> 72, list clamp ->
  fixed 330.

- **Gate 2 - One selection owner.** Move `_selectedEntryId` to
  `_VaultViewState`. Pass selection + `onSelect` into the entries card. Delete
  `_EntriesCardState`'s `_selectedEntryId`, its `_selectedEntry` getter, its
  `didUpdateWidget` clearing logic and its inline `Row(list | detail)` branch.

- **Gate 3 - Actions that always fire, on the current record.** Rework
  `_handleEntryAction`: take the entry **id**, re-read from the bloc at
  confirmation time, capture the bloc before the first `await`, guard on the
  surface context. This is the gate that fixes the data-integrity bug (D4) and
  is independent of every layout decision.

- **Gate 4 - Presentation-neutral dismissal.** Replace the `Navigator.pop` in
  `_EntryDetailsPage` with completion through `VaultOperationScope`. Clear the
  shell selection when the detail session finishes, whatever dismissed it.

- **Gate 5 - Editor and generator placement.** Editor header carries the record
  title; completion restores the record's detail. Generator becomes a 290
  column at >= 995 and stays a sheet below it. The records list is not dimmed.

- **Gate 6 - Evidence.** New goldens, re-recorded goldens, widget assertions,
  then `flutter analyze` + full `flutter test` + `flutter test test/goldens
  --test-randomize-ordering-seed=$RANDOM`.

## Golden impact - stated up front

The wide layout's metrics change (rail 76 -> 72, list 330-352 -> 330), so some
existing 1024-width goldens must be re-recorded. Auditing `test/goldens/`:

**Must be re-recorded (all 1024 - permitted by VR-003):**

| Golden | Why it moves |
|---|---|
| `vault_shell_1024x768_light.png` | rail 76->72, list width fixed at 330 |
| `vault_shell_1024x768_dark.png` | same |
| `entry_detail_hidden_1024x768_light.png` | detail pane width shifts with the columns |
| `editor_new_item_1024x768_light.png` | editor hosted in the corrected pane |
| `editor_generator_sheet_1024x768_light.png` | **semantic change** - 1024 >= 995, so the generator is now a *column*, not a sheet. The name becomes wrong; rename the case and capture a sheet case below 995. |

**Unaffected, and must stay byte-identical:** every `390x844` golden (VR-003),
and the non-vault 1024 goldens - `health_`, `settings_`, `sync_success_`,
`browser_setup_`, `db_recent_`, `unlock_password_`,
`organic_theme_gallery_`, `host_not_found_diagnostic_`. The rail is already 72
outside the vault destination (`railWidth = selectedDestination == vault ? 76 :
72`), so correcting the vault rail does not touch them. **Verify by diffing the
golden file list before and after - do not assume it.**

**Added (VR-001):** `vault_wide_record_selected_1024x768_{light,dark}`,
`vault_wide_empty_detail_1024x768_{light,dark}`,
`vault_wide_editor_in_pane_1024x768_{light,dark}`.

## Risks

| Risk | Mitigation |
|---|---|
| A mobile golden shifts because a shared widget changed | Gate 0 pins mobile first; Gate 6 diffs the golden file list. VR-003 makes any 390 change a failure, not a re-record. |
| Rebuild scope widens when selection moves to the shell | Keep the existing `buildWhen` discipline (`_entriesCardBuildWhen`); assert the records list does not rebuild when only the pane changes. |
| `presentationFor` is used by tests as a pure function | It stays pure - the layout class becomes a parameter, replacing the implicit `MediaQuery` read. `vault_surface_migration_matrix_test.dart` needs its call sites updated, not its expectations. |
| The 704-940 band has no artboard | Its metrics are fully derived from FR-002b; only the folder-collapse *styling* is undrawn, and this plan ships no new styling there. |
| Generator column is scope creep | Limited to the slot and the 995 fallback rule (FR-002e). Its contents stay untouched. |

## Implementation outcome (2026-08-29)

Ran to completion on `fix/desktop-vault-navigation`. `flutter analyze` clean;
`flutter test` **1587 passing / 2 skipped**, up from the 1501 baseline
recorded in T002. Golden suite also green under a randomised ordering seed.

**The golden churn matched this plan's prediction exactly** — 5 re-recorded
(all 1024), 6 added, and **zero 390x844 goldens touched**, so VR-003 and US5
hold. `editor_generator_sheet_1024x768_light.png` was renamed to
`..._column_...` as planned, because at 1024 the generator is now a column.

Three things the plan did not foresee, all recorded rather than smoothed over:

1. **D4 was unreachable.** The stale-snapshot path lived only in the records
   list's inline split, which required the card itself to be >= 600px wide.
   The card only ever got `width - 109`, and above the three-column threshold
   it was capped at the list column. The condition was never met at any window
   size, so D4 is a latent defect, not an observed one. The id-based re-read
   still landed (it is correct by construction and removes the trap), but no
   user-visible stale write is being claimed.
2. **D5 is worse than described, and is the real bug.** A rebuild is not
   enough — the records card must be *unmounted*, which is exactly what
   happens in the single-pane band where the router pane replaces the vault
   pane. Confirming Delete or Move there wrote nothing and said nothing.
   Mobile never hit it because a pushed route stacks rather than replaces —
   which is precisely why the report was "desktop broken, mobile fine". The
   regression test for it was verified failing against the pre-fix code.
3. **A fourth width authority existed.** The editor rendered its own generator
   column off `Breakpoints.tablet`, independent of the shell, the list and the
   router. At 1024 with the folder column present this squeezed the editor to
   roughly 200px, below its own 300 minimum. It now uses the shared derived
   995, and the folder column yields to the generator per FR-002e.

Also removed: `_VaultLayoutSpec`'s `isMobile` / `isCompact` / `isTablet` — three
further width comparisons that nothing read. A spare notion of "is this wide?"
lying around is how the components drifted apart to begin with.

**Not done, deliberately:** T051, the manual walkthrough of `quickstart.md` on
a real resizable window, and the `PIXEL_SPEC.md` correction plus the four
artboard edits recorded in the spec's follow-up section.

## Phase 0 - research

See [research.md](./research.md). No `NEEDS CLARIFICATION` remained in the
Technical Context: the spec's clarify pass and the 2026-08-28 design decision
resolved every open question, and the code facts were read directly.

## Phase 1 - design artifacts

- [data-model.md](./data-model.md) - view-state entities, invariants, transitions
- [contracts/vault_navigation_contract.md](./contracts/vault_navigation_contract.md)
  - layout class to presentation, selection lifecycle, action outcome guarantees
- [quickstart.md](./quickstart.md) - how to run and validate each gate

**Post-design Constitution re-check: PASS**, unchanged. The design introduces
one value type and one callback, adds no dependency, no BLoC, no coordinator,
and removes more code than it adds.
