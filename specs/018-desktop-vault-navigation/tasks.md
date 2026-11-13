---

description: "Task list for spec 018 — desktop vault navigation and entry actions"
---

# Tasks: Desktop vault navigation and entry actions

**Input**: Design documents from `specs/018-desktop-vault-navigation/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED. The spec carries verification requirements VR-001…VR-003
and US5 is a pure regression story, so test tasks are first-class here, not
optional.

**Organization**: grouped by user story. Phase 2 is a characterisation phase —
it pins today's behaviour **before** any production file is edited, so a US5
regression is caught by a test that predates the change.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: the user story the task serves (US1…US5)

## Path conventions

Flutter app. Production code under `lib/`, tests mirror it under `test/`,
goldens in `test/goldens/`. All paths below are repo-relative to the worktree
`password-manager-018-desktop-nav`.

---

## Phase 1: Setup

**Purpose**: confirm the toolchain and capture the pre-change baseline that
later golden claims are checked against.

- [x] T001 Verify the pinned toolchain resolves in the worktree: run `fvm flutter --version` and confirm 3.47.1 against `.fvmrc`, then `fvm flutter pub get`
- [x] T002 Record the pre-change baseline: run `fvm flutter analyze` and `fvm flutter test`, and save the passing test count plus `ls test/goldens/*.png | sort` output to a scratch file OUTSIDE `specs/` (that directory is tracked and feeds the Projects #2 sync) so VR-003 can be verified by diff rather than by memory

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: pin existing behaviour, then install the single width authority.

**⚠️ CRITICAL**: T003–T006 must be green **before** any production file is
edited. T007–T011 must complete before any user story phase begins.

### Characterisation — pin today's behaviour first

- [x] T003 [P] Add mobile navigation characterisation tests in `test/features/password_manager/presentation/screens/vault/vault_navigation_mobile_characterisation_test.dart`: at 390×844, activating a record pushes a full-screen detail, the back affordance returns to the list, and the list is intact afterwards
- [x] T004 Add mobile record-action characterisation tests in the same file: edit, move, attachments and delete each behave as they do today from a pushed detail, asserting the dispatched `VaultBloc` events
- [x] T005 [P] Add a presentation-matrix snapshot test in `test/features/password_manager/presentation/navigation/vault_surface_presentation_baseline_test.dart` asserting `presentationFor` for every `VaultSurface` subtype at widths 390, 599, 600, 703, 704, 940, 941, 994, 995 and 1024 — capturing today's answers, so any change is deliberate
- [x] T006 Run `fvm flutter test` and confirm T003–T005 pass against unmodified production code; a failure here means the characterisation is wrong, not the code

### One width authority

- [x] T007 Add the derived vault layout widths to `lib/core/responsive/breakpoints.dart`: `vaultDetailPane = 704`, `vaultFolderPane = 941`, `vaultGeneratorColumn = 995`, each with its arithmetic as a comment per FR-002a and data-model.md E1
- [x] T008 Add the `VaultLayoutClass` enum and `VaultLayoutClass.fromWidth(double)` to `lib/core/responsive/breakpoints.dart` with the four cases `narrowTabBar` / `narrowRail` / `wide` / `wideWithFolders` per contract C1
- [x] T009 [P] Add `VaultLayoutClass` unit tests in `test/core/responsive/vault_layout_class_test.dart` covering contract C1's boundary table (599/600/703/704/940/941/1024) and guarantees G1.1–G1.3
- [x] T010 Change `presentationFor` in `lib/features/password_manager/presentation/navigation/vault_shell_router.dart` to take `VaultLayoutClass` instead of `double width`, removing its hard-coded `600`; update `VaultShellRouter.open` to resolve the class once and pass it, per contract C2
- [x] T011 Update the call sites and expectations in `test/features/password_manager/presentation/navigation/vault_shell_router_test.dart` and `vault_surface_migration_matrix_test.dart` to the new signature — expectations must not change for any surface except `PasswordGeneratorSurface` (G2.2)

**Checkpoint**: one width authority exists, presentation is unchanged, mobile is pinned.

---

## Phase 3: User Story 1 — One selection, one detail, at every width (Priority: P1) 🎯 MVP

**Goal**: one record selection drives exactly one detail surface at every
width, with the selected row visibly highlighted.

**Independent Test**: resize across the full range clicking records; exactly
one detail surface is visible, showing the clicked record, with its row
highlighted.

### Tests for User Story 1

- [x] T012 [P] [US1] Add selection-ownership tests in `test/features/password_manager/presentation/screens/vault/vault_selection_test.dart`: at 704 and 1024 exactly one detail surface exists (G3.1), exactly one row is selected (G3.2, SC-001), and the entries card renders no `_EntryDetailPanel` of its own
- [x] T013 [P] [US1] Add a resize test in the same file: with a record selected, crossing 704 and 941 in both directions keeps the same record selected and produces no second detail surface (G3.5, FR-015, SC-008)
- [x] T014 [P] [US1] Add an origin-parity test in `test/features/password_manager/presentation/screens/vault/vault_detail_origin_test.dart`: opening the same record from the records list, from Health and from duplicates yields the same detail surface with the same actions at 1024 (FR-010, SC-007)

### Implementation for User Story 1

- [x] T015 [US1] Move the selected-record state to `_VaultViewState` in `lib/features/password_manager/presentation/screens/vault/vault_shell.part.dart`: add `String? _selectedEntryId`, a setter that opens/cancels the detail session through `_router`, and compute `VaultLayoutClass` once in the shell's `LayoutBuilder`
- [x] T016 [US1] Delete the inline detail from `lib/features/password_manager/presentation/screens/vault/vault_entries.part.dart`: remove `_selectedEntryId`, the `_selectedEntry` getter, its `didUpdateWidget` clearing logic, the `showInlineDetail` `LayoutBuilder` and the `Row(list | _EntryDetailPanel)` branch (FR-001, FR-001a)
- [x] T017 [US1] Give `_EntriesCard` inbound `selectedEntryId` and `onSelectEntry` parameters and thread them from `_VaultEntriesCardSection` in `vault_shell.part.dart`, per contract C3
- [x] T018 [US1] Replace the `708` literal and the `Breakpoints.tablet` folder gate in `_VaultNavigationLayout._railBody` in `vault_shell.part.dart` with the `VaultLayoutClass` cases; set the rail to a flat 72 and the list column to a fixed 330 per FR-002b
- [x] T019 [US1] Make the detail pane persistent at `wide` and `wideWithFolders` — always present, `_EntryDetailEmptyState` when nothing is selected (FR-002c)
- [x] T020 [P] [US1] Apply the selected-row treatment in `lib/features/password_manager/presentation/screens/vault/vault_entries_details.part.dart` using the `CustodeColors` accent roles from `PIXEL_SPEC` §2, plus a non-colour cue (FR-004, FR-004a)
- [x] T021 [US1] Clear the selection when the entry leaves the visible list via search or folder change, and when the destination changes away from Vault (FR-014, data-model.md E2)
- [x] T021a [P] [US1] Add a folder-reachability test at 800 px in `test/features/password_manager/presentation/screens/vault/vault_selection_test.dart`: in the 704–940 band the folder column is absent yet every folder remains reachable through the records list's own folder rows, and opening one changes the current group (FR-002d final clause). **This test is what justifies deferring the rail folder-switcher — without it the deferral is an assumption**
- [x] T021b [P] [US1] Add accessibility assertions for the selected row in `test/features/password_manager/presentation/screens/vault/vault_selection_a11y_test.dart`: the selected row is reachable and activatable by keyboard alone, exposes its selected state to semantics, carries a non-colour cue, keeps a ≥44×44 target and a 2 px focus ring, and the detail pane holds its 300 px minimum at 704 and at 1024 (FR-016, FR-004a, Constitution V)
- [x] T021c [US1] Add an action-parity test in `test/features/password_manager/presentation/screens/vault/vault_detail_origin_test.dart`: the set of record actions offered is identical at 390, 800 and 1024 and from every origin, and at wide widths no record surface is presented as a dialog stacked on another dialog (FR-011, FR-011a, G5.6)

**Checkpoint**: US1 is independently demonstrable — selection and detail agree at every width.

---

## Phase 4: User Story 2 — Record actions always apply, to the current record (Priority: P1)

**Goal**: every confirmed record action is applied to the record as it is now,
or reported — never silently dropped, never written from a stale snapshot.

**Independent Test**: with a detail open, force a list rebuild, then run each
of the four actions and confirm each takes effect on the current record.

### Tests for User Story 2

- [x] T022 [P] [US2] Add a stale-write regression test in `test/features/password_manager/presentation/screens/vault/vault_entry_actions_test.dart`: two consecutive edits of one record both persist and the second does not revert the first (FR-005, G5.1, SC-003). Confirm it FAILS before T025
- [x] T023 [P] [US2] Add a dropped-action regression test in the same file: after the records list rebuilds (search change, bloc emit), a confirmed Edit / Move / Attachments / Delete still dispatches its event (FR-006, G5.2–G5.4, SC-002). Confirm it FAILS before T026
- [x] T024 [P] [US2] Add a cancel-and-vanish test in the same file: cancelling leaves the vault unchanged with the selection intact (G5.5), and an entry that disappears before confirmation abandons the action and reports it rather than writing (G5.7)

### Implementation for User Story 2

- [x] T025 [US2] Change `_handleEntryAction` in `lib/features/password_manager/presentation/screens/vault/vault_entries.part.dart` to take an entry **id** and re-read the entry from `VaultBloc.state.allEntries` at confirmation time, per contract C5 and data-model.md E3
- [x] T026 [US2] In the same function, capture the `VaultBloc` before the first `await` and guard liveness on the surface context instead of `_EntriesCardState.mounted`, removing the silent-drop path (FR-006)
- [x] T027 [US2] Route both origins — the records list and `_openEntryDetailsSurface` — through the single id-based handler so the two paths cannot drift again (FR-010, D9)
- [x] T028 [US2] Ensure every failure path surfaces a message through the existing `VaultBloc` error channel; no branch may end with neither a change nor a message (FR-006, G5.4)

**Checkpoint**: the two data-integrity defects (D4, D5) are fixed and covered by tests that failed first.

---

## Phase 5: User Story 4 — A deleted record never leaves a dead detail (Priority: P2)

**Goal**: when the shown record disappears, the detail returns to the empty
state and nothing stays selected — under every presentation.

**Independent Test**: open a record's detail on a wide window, delete it, and
confirm the pane returns to the empty state with no highlighted row.

*Sequenced before US3 because US3's "return to the record's detail" builds on
the dismissal path this story installs.*

### Tests for User Story 4

- [x] T029 [P] [US4] Add dismissal tests in `test/features/password_manager/presentation/screens/vault/vault_detail_dismissal_test.dart`: deleting the shown record at 1024 returns the pane to `_EntryDetailEmptyState` with no selection and no exception (FR-008, G4.4, G4.5, SC-004)
- [x] T030 [P] [US4] Add a nested-surface test in the same file: with attachments or a confirmation stacked on the detail, the record vanishing dismisses the whole stack (FR-008 scenario 3, G4.3)

### Implementation for User Story 4

- [x] T031 [US4] Replace the `Navigator.pop` fallback in `_EntryDetailsPage` in `lib/features/password_manager/presentation/screens/vault/vault_entry_detail.part.dart` with completion through `VaultOperationScope.of(context)`, so dismissal is presentation-neutral (FR-007, G4.1, G4.2)
- [x] T032 [US4] Clear `_VaultViewState._selectedEntryId` whenever a detail session finishes, whatever ended it — back, escape, deletion, destination change (FR-003, G4.4, data-model.md E2)

**Checkpoint**: no dismissal path can leave a dead pane.

---

## Phase 6: User Story 3 — Editing keeps the user's place (Priority: P2)

**Goal**: the record being edited stays identifiable and selected, and saving
or cancelling returns to that record's detail.

**Independent Test**: on a wide window open a record, edit and save; repeat and
cancel. The record's detail is shown in both cases.

### Tests for User Story 3

- [x] T033 [P] [US3] Add editor-placement tests in `test/features/password_manager/presentation/screens/vault/vault_editor_placement_test.dart`: at 1024 the editor header shows the record's title and the row stays selected during the edit (FR-009a)
- [x] T034 [P] [US3] Add a return-to-detail test in the same file: saving and cancelling both restore that record's detail to the pane (FR-009, SC-005)
- [x] T035 [P] [US3] Add a generator-placement test in the same file: at 1024 the generator is a column, at 980 it is a sheet, and the records list is never dimmed in either case (FR-002e, G2.3)

### Implementation for User Story 3

- [x] T036 [US3] Pass the edited record's title into the editor header in `lib/features/password_manager/presentation/screens/vault/vault_entry_editor.part.dart` and keep the shell selection alive for the duration of the edit (FR-009a)
- [x] T037 [US3] Restore the record's detail to the pane when the editor session completes or cancels, rather than falling back to the empty state (FR-009)
- [x] T038 [US3] Implement the generator column at ≥ 995 and the sheet fallback below it in `vault_entry_editor.part.dart`, collapsing the folder column — never the records list — when the column opens (FR-002e)
- [x] T039 [US3] Confirm no dimming is applied to the records list while the editor or generator is open; if any opacity treatment exists, remove it (FR-002e, Constitution V)

**Checkpoint**: the main editing loop keeps the user's place.

---

## Phase 7: User Story 5 — Mobile navigation is unchanged (Priority: P1)

**Goal**: prove, not assume, that mobile is untouched.

**Independent Test**: the Phase 2 characterisation tests still pass unmodified,
and no 390×844 golden has moved.

- [x] T040 [US5] Re-run the Phase 2 characterisation tests (T003–T005) unmodified and confirm they still pass; any edit needed to make them pass is a US5 regression, not a test fix (FR-012)
- [x] T041 [US5] Verify no mobile golden moved: `git status --porcelain test/goldens/ | grep 390x844` must print nothing (VR-003, SC-006, G6.4)
- [x] T041a [US5] Verify no user-facing string changed: diff the literal strings in the touched `lib/features/password_manager/presentation/screens/vault/*.dart` and `navigation/*.dart` files against their `origin/main` versions and confirm no navigation or record-action string was added, removed or reworded (FR-013, Constitution VI)
- [x] T042 [US5] Diff the golden file list against the Phase 1 baseline and confirm the only changes are the five re-recorded 1024 goldens and the six added ones named in plan.md; investigate anything else before accepting it

**Checkpoint**: mobile is provably unchanged.

---

## Phase 8: Evidence and polish

- [x] T043 [P] Add the three new golden cases to `test/goldens/vault_shell_test.dart` — `vault_wide_record_selected`, `vault_wide_empty_detail`, `vault_wide_editor_in_pane` — at 1024×768 in light and dark (VR-001)
- [x] T044 Regenerate goldens with `fvm flutter test test/goldens --update-goldens` and review every changed file against plan.md's expected list
- [x] T045 Rename `editor_generator_sheet_1024x768_light.png` to `editor_generator_column_1024x768_light.png` and add a sheet case below 995, since at 1024 the generator is now a column and the old name asserts the wrong thing
- [x] T046 [P] Add the widget assertions VR-002 requires for the cases deliberately not covered by pixels — fit-width boundary either side, resize with the editor open, deleted-record dismissal, action after a list rebuild — and state the omitted axes in the test file header
- [x] T047 Grep the vault presentation tree for leftover width logic: no `constraints.maxWidth` or `Breakpoints.` comparison may remain in a presentation-selection position outside `VaultLayoutClass` (FR-002a, contract C1 "Forbidden"). `_VaultLayoutBreakpoints.compactPhone` selects padding, not presentation, and is an allowed exception
- [x] T048 Run `fvm flutter analyze` and confirm it is clean (Constitution IX)
- [x] T049 Run the full `fvm flutter test` and confirm the count is at or above the Phase 1 baseline with no failures
- [x] T050 Run `fvm flutter test test/goldens --test-randomize-ordering-seed=$RANDOM` to confirm golden order-independence, per the repo's testing rule
- [x] T051 Walk `specs/018-desktop-vault-navigation/quickstart.md` manually on a resizable desktop window and record the result for the six reproduced defects

**T051 result — walked 2026-08-29 on macOS.** All six reproduced defects hold:
the confirmed action applies in the single-pane band, the width bands break at
704 and 941, the selection and the editor keep the user's place, deleting the
shown record returns the pane to its empty state, and resizing across the
thresholds never shows two details. The walk also found two things this spec had
not:

- **A second back button** appeared after shrinking the window with a record
  open. `allowsPop` was derived from the current width, but the presentation is
  fixed when the surface opens, so after a resize the width said "pop" while the
  pane was still mounted. Fixed in this spec — the panel now asks the tree
  (`_VaultPaneScope`) instead of the window — with a regression test verified
  failing beforehand.
- **The vault's content never moved to the adopted navigation model.** That is
  not a spec 018 defect: 018 fixed navigation and the shell reached the right
  widths, while the folder column, the records list and the phone header still
  render model 1c. It is recorded as 17 findings in
  `specs/_design/CONFORMANCE_AUDIT.md` and is the whole of spec 019.

---

## Dependencies & execution order

### Phase dependencies

- **Phase 1 Setup**: no dependencies
- **Phase 2 Foundational**: T003–T006 must be green before ANY production edit; T007–T011 block every user story
- **Phase 3 US1**: depends on Phase 2. MVP.
- **Phase 4 US2**: depends on Phase 2 only. **Independent of US1** — the action fixes are layout-agnostic and could ship alone.
- **Phase 5 US4**: depends on Phase 2; benefits from US1's selection ownership (T015)
- **Phase 6 US3**: depends on US4's dismissal path (T031, T032)
- **Phase 7 US5**: depends on all production phases being complete
- **Phase 8**: depends on everything

### Critical ordering

- T006 gates every production edit in the repo.
- T022 and T023 must be observed FAILING before T025 and T026.
- T031 before T037 — the editor's return path uses the neutral dismissal.
- T044 after T043, and both after every production change.

### Parallel opportunities

- T003 and T005 in parallel; T004 follows T003 (same file)
- T012, T013, T014 in parallel
- T022, T023, T024 in parallel
- T029, T030 in parallel
- T033, T034, T035 in parallel
- US1 (Phase 3) and US2 (Phase 4) can be worked in parallel by two people after Phase 2

---

## Implementation strategy

### MVP

Phase 1 → Phase 2 → Phase 3 (US1). That alone makes the desktop vault
coherent: one selection, one detail, a visible highlight, correct thresholds.

### Highest value first, if time is short

**Phase 4 (US2) is the one to do first if only one phase can land.** It fixes
the two data-integrity defects — a confirmed edit reverting an earlier one, and
a confirmed action silently vanishing — and it depends on nothing in Phase 3.
Every other defect is a navigation annoyance; these two lose the user's data.

### Incremental delivery

1. Phase 1 + 2 → foundation, mobile pinned
2. + Phase 4 (US2) → data integrity restored
3. + Phase 3 (US1) → coherent desktop navigation
4. + Phase 5 (US4) → no dead panes
5. + Phase 6 (US3) → editing keeps its place
6. + Phase 7 + 8 → proof

---

## Notes

- `[P]` = different files, no dependency on incomplete work
- The net diff should be **negative** in `vault_entries.part.dart` — if that
  file grows, the inline split was not actually removed
- No new BLoC, no new coordinator, no new dependency (Constitution II, VIII)
- Commit per phase; tick each box in the same change that lands its work
