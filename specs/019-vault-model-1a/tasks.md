---

description: "Task list for spec 019 — vault journey 03 to navigation model 1a"
---

# Tasks: Vault journey 03 to navigation model 1a

**Input**: Design documents from `specs/019-vault-model-1a/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED. Constitution IV and V make pixel fidelity and the
accessibility floor part of the definition of done, and US3 is a pure
non-regression story. Test tasks are first-class here.

**Organization**: grouped by user story. Phase 2 is deliberately heavy. It
holds the characterisation that pins what must not change **and** the four
things every story sits on: the folder filter in the BLoC, the persisted
expansion state, the one tree widget, and `Manage folders`.

`Manage folders` is in Phase 2 rather than in US3 because US1 and US2 both build
its entry point. Leaving the surface in US3 put the entry point in one phase and
the destination in another, and made the MVP checkpoint a state where US1 had
deleted the folder tree's `•••` and nothing had replaced it. Infrastructure that
three stories consume belongs where the tree widget already is.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: the user story the task serves (US1…US4)

## Path conventions

Flutter app. Production code under `lib/`, tests mirror it under `test/`,
goldens in `test/goldens/`. All paths are repo-relative to the worktree
`password-manager-018-desktop-nav`.

---

## Phase 1: Setup

**Purpose**: confirm the toolchain and capture the baseline the golden-churn
prediction is checked against.

- [x] T001 Verify the pinned toolchain in the worktree: `fvm flutter --version` is 3.47.1 per `.fvmrc`, then `fvm flutter pub get`
- [x] T002 Record the pre-change baseline outside `specs/` (that directory is tracked and feeds the Projects #2 sync): `fvm flutter analyze`, `fvm flutter test`, the passing count, and `ls test/goldens/*.png | sort`, so the plan's churn prediction is checked by diff rather than by memory

---

## Phase 2: Foundational

**Purpose**: pin today's behaviour before any production file moves, then build
the four things US1, US2 and US3 all consume.

**⚠️ BLOCKING**: no user-story phase starts until T003–T021 are done.

### Characterisation — must pass against unchanged code first

- [x] T003 [P] Write `test/features/password_manager/presentation/screens/vault/vault_action_inventory_test.dart`: enumerate mechanically — not from memory — every action reachable from the vault at `HEAD` (every `PopupMenuItem` label, `IconButton` tooltip and pill label under `lib/features/password_manager/presentation/screens/vault/`), assert each is present with its exact string. Run it against `HEAD` and confirm green; this is the US3 guarantee and FR-021's enforcement
- [x] T004 [P] Extend `test/features/password_manager/presentation/screens/vault/vault_surface_presentation_baseline_test.dart` for FR-019: assert contract S1 — every pre-existing row of `presentationFor` unchanged at the spec-018 boundary widths 599/600/703/704/940/941/994/995 — and record that `test/core/responsive/vault_layout_class_test.dart` must stay green **without edits** (contract S2)
- [x] T005 [P] For FR-011 and FR-019, confirm spec 018's two suites are green unchanged: `vault_navigation_mobile_characterisation_test.dart` (VR-003) and `vault_selection_test.dart` (the single selection owner). Both must stay green **without edits** — an edit to either is a regression, not a test that needed updating. T026 rewrites the very widget 018 removed from the selection-owner role, so this is the tripwire for taking it back by accident
- [x] T006 [P] Pin the readers of the collections whose meaning changes: assert in `test/features/password_manager/presentation/bloc/vault/vault_visible_entries_readers_test.dart` that `allEntries` still feeds the duplicate service, the health report and the autofill publisher unchanged, so the `visibleEntries` change cannot leak into them (research R1)

### The BLoC learns about folders

- [x] T007 Add the derived folder aggregates to `lib/features/password_manager/presentation/bloc/vault/vault_bloc.dart`: one post-order walk of `groups` over `allEntries` producing `folderCounts` (inclusive of descendants), `totalCount` excluding the recycle bin, and `descendantIds(groupId)` — computed once per state change, never per row (plan Performance Goals)
- [x] T008 Surface those aggregates on `lib/features/password_manager/presentation/bloc/vault/vault_state.dart` per `data-model.md`, keeping `VaultState` equatable and its `props` free of any entry value
- [x] T009 Add `SelectVaultFolder(String groupId)` to `lib/features/password_manager/presentation/bloc/vault/vault_event.dart` and its handler to `vault_bloc.dart`. Per FR-002a the payload is **never null**: `All items` is the root group id. Sets `currentGroupId`, recomputes `visibleEntries`, and MUST NOT touch expansion (FR-006f)
- [x] T010 Teach `_computeVisibleEntries` in `vault_bloc.dart` the folder filter, applied before search and sort, using `descendantIds` so a selected folder shows its subtree (FR-006h)
- [x] T011 [P] Write `test/features/password_manager/presentation/bloc/vault/vault_folder_filter_test.dart` (T-FILTER): subtree filtering; counts inclusive of subfolders; `All items` equals the whole vault minus the bin; folder + search + sort composing in every order; and **FR-002a's tripwire — with `All items` selected, `CreateVaultEntry` still reaches the vault**, because a null current group makes `_onCreateVaultEntry` return early without a message (`vault_bloc.dart:389`)
- [x] T012 Add `SetVaultFolderExpanded(String groupId, bool expanded)` to `vault_event.dart` and `vault_bloc.dart`, persisting the set through the already-registered `SharedPreferences` under one key per database, and restoring it at unlock (FR-006g, research R3)
- [x] T013 [P] Write `test/features/password_manager/presentation/bloc/vault/vault_folder_expansion_test.dart`: expansion survives a lock/unlock cycle, is per-database, and never changes `visibleEntries`

### The one tree widget

- [x] T014 Create `lib/core/widgets/kv_folder_tree.dart` implementing every guarantee in `contracts/folder-tree.md` — `filter` and `manage` modes, chevron only on nodes with children and only calling `onToggleExpanded`, one selected-row style, one `•••` recipe, one indentation level per depth (FR-006c, FR-006k)
- [x] T015 [P] Write `test/core/widgets/kv_folder_tree_test.dart` (T-ONE-TREE) asserting G1–G8 by name, including G1 (no action affordance in `filter` mode, FR-006c) and G7 (chevron and row both ≥ 44 × 44 with hit areas that do not overlap — research R5, Constitution V)
- [x] T016 [P] Create `lib/core/widgets/kv_filter_chip.dart` for the phone chip row, with the 2 px focus ring, a ≥ 44 px target and a `Semantics` selected state (Constitution V)

### `Manage folders` — the destination US1 and US2 build the entry point for

- [x] T017 Add `ManageFoldersSurface` and `VaultDialogPresentation` to `lib/features/password_manager/presentation/navigation/vault_shell_router.dart`, with `presentationFor` returning the dialog when `layout.hasDetailPane` and the pushed route otherwise (contract `vault-surfaces.md`, research R4)
- [x] T018 Host the dialog presentation in the router beside the existing route and sheet hosts, so `ManageFoldersSurface` participates in sessions, cancellation and results like every other surface (contract S3)
- [x] T019 Create `lib/features/password_manager/presentation/screens/vault/vault_manage_folders.part.dart`: `KvFolderTree` in `manage` mode — always fully expanded, no subtitles — `New folder` in the header, and the per-row `•••` with `Rename · Move… · Delete` (FR-006, FR-006b)
- [x] T020 Wire the three row actions to the events the folder tree rows dispatch today, reusing their existing confirmations and strings verbatim (FR-006d, Constitution VI and VII)

### The glyph the phone header needs

- [x] T021 Vendor Lucide `arrow-up-down` into `assets/icons/lucide/`: download it from the pinned commit URL recorded in `assets/icons/lucide/UPSTREAM.md` — do **not** hand-author the path — apply the set's `stroke-width="2"` → `2.75` change, add both its upstream and delivered SHA-256 to the two tables in `UPSTREAM.md`, and add the `AppGlyph` value in `lib/core/theme/app_glyph.dart` (DQ-8). The `ICONS.md` rows for `lock` and `arrow-up-down` are already written

**Checkpoint**: the BLoC answers "which records are visible", one tree widget
exists, folder management has a home to move into, and the phone header has its
glyph. The UI phases now only
compose.

---

## Phase 3: User Story 1 — The desktop vault reads as three columns (P1) 🎯 MVP

**Goal**: the 1024 × 768 vault is the folder column, the records list and the
detail pane the artboard draws.

**Independent test**: open a vault at 1024 × 768 and describe the three columns
from the artboard alone.

- [x] T022 [US1] Create `lib/features/password_manager/presentation/screens/vault/vault_folders.part.dart` and register the part in `lib/features/password_manager/presentation/screens/vault_screen.dart`
- [x] T023 [US1] Build the desktop folder column in `vault_folders.part.dart`: database file name as the title (FR-001), `All items` as the first and default row carrying the total, selected through the root group id (FR-002, FR-002a), `KvFolderTree` in `filter` mode with per-folder inclusive counts (FR-003), and `Manage` in the header as the single entry point to T019's surface (FR-006a)
- [x] T024 [US1] Add the hygiene shortcuts `Recycle bin` and `Duplicates` at the foot of the column with their counts from `recycleBinEntries.length` and `duplicateGroups.length`, opening the surfaces they open today (FR-004)
- [x] T025 [US1] Replace `_VaultFolderPane` in `lib/features/password_manager/presentation/screens/vault/vault_shell.part.dart` with the new column, deleting the literal `'Folders'` title and the raw `ListTile`s (C-03-07, C-03-11)
- [x] T026 [US1] Strip the tree out of `lib/features/password_manager/presentation/screens/vault/vault_entries.part.dart`: delete `_EntryTreeNode`, the grouping walk, the per-folder rows and the folder actions. The card renders `state.visibleEntries` as rows and nothing else (FR-007, C-03-03). It must not acquire selection state — T005 is the tripwire (FR-011)
- [x] T027 [US1] Add the count line above the list in `vault_entries.part.dart`: `<n> items`, and `<n> items · incl. subfolders` when a folder with descendants is selected (FR-006i)
- [x] T028 [US1] Add the sort control to the right of the count line, dispatching the existing `SetVaultSort` with the existing three `VaultEntrySort` values and marking the active one. No new ordering (FR-009, research R2)
- [x] T029 [US1] Give the search field the count-bearing placeholder `Search <n> items` (FR-008, C-03-05), keeping the existing search event and behaviour
- [x] T030 [US1] Add `· in <folder>` to the subtitle of a record shown because it lives in a subfolder of the selection (FR-006j)
- [x] T031 [US1] Remove `_VaultSyncStatusStrip` from the vault pane composition in `vault_shell.part.dart` so no database status card appears inside the records list at any width (FR-013, C-03-12). Its actions are rehomed in US3 — do not delete them here
- [x] T032 [P] [US1] Write `test/features/password_manager/presentation/screens/vault/vault_folder_surface_test.dart`: the column's structure, `All items` default, inclusive counts, hygiene shortcuts, subtree filtering end to end, and that folders stay reachable in the 704–940 band (plan Risks)
- [x] T033 [P] [US1] Write `test/features/password_manager/presentation/screens/vault/vault_records_list_test.dart`: the list contains no folder row at any width; the count line reads correctly with and without a subtree; the placeholder carries the count; the sort control offers exactly three orders and marks the active one, and the choice survives a folder change and a search (FR-009); and **FR-012 — the record actions available today are still offered from a list row at both 1024 and 650**, which the 018 suites do not cover because they open the menu from the detail
- [x] T034 [US1] Add `vault_1a_wide_1024x768_light.png`, `vault_1a_wide_1024x768_dark.png` `vault_1a_wide_folder_selected_1024x768_light.png` and `vault_1a_sort_menu_1024x768_light.png` to `test/goldens/vault_shell_test.dart` with an exact-inventory assertion (SC-002, SC-005)

**Checkpoint**: US1 is independently demonstrable at 1024 × 768, and folder
management is reachable from the column's `Manage` — nothing was lost when the
tree went.

---

## Phase 4: User Story 2 — The phone vault is a list, not a file browser (P1)

**Goal**: the 390 × 844 vault is the header, the search, the chips and the rows.

**Independent test**: copy a password at 390 × 844 without opening the record.

- [x] T035 [US2] Build the phone screen header in `vault_shell.part.dart`: `Vault`, `<n> items · <database>.kdbx`, the sort affordance using T021's `arrow-up-down` glyph, and the add affordance — in that order from the right, each with a 44 px target (FR-014, C-03-01, DQ-8)
- [x] T036 [US2] Build the chip row in `vault_folders.part.dart` using `KvFilterChip`: `Folders` first, then `All`, then first-level folders only — deep nesting must never lengthen the row (FR-005)
- [x] T037 [US2] Build the `Folders` sheet in `vault_folders.part.dart`: the same `KvFolderTree` in `filter` mode, the same expansion state as the desktop column, `Manage` at its head opening T019's surface; choosing a folder filters, closes and becomes the active chip (FR-005a, FR-006a)
- [x] T038 [US2] Build the phone `Sort` sheet: one radio group over `Title A→Z`, `Title Z→A` and `Username A→Z`, the active one marked, dispatching the same `SetVaultSort` as the desktop control; choosing applies immediately and dismisses. Nothing else goes in the sheet — no health filter, no folder filter, no advanced search (FR-009a, FR-014a, FR-014b)
- [x] T039 [US2] Add the one-tap password copy to the record row in `lib/features/password_manager/presentation/screens/vault/vault_entries_details.part.dart`, reusing the existing copy path and its existing confirmation string verbatim — the row keeps its health dot (FR-010, C-03-04, Constitution I)
- [x] T040 [P] [US2] Extend `vault_records_list_test.dart`: the copy affordance copies **in one interaction from the vault screen** without navigating (SC-003), the confirmation string is the existing one byte for byte, and the health state is announced in words as well as colour (Constitution V)
- [x] T041 [P] [US2] Extend `vault_folder_surface_test.dart`: the chip row carries first-level folders only for a deeply nested vault; **no chip carries any action** (FR-006c); the sheet and the column share one expansion state; and a deleted selected folder falls back to `All items` (spec edge case)
- [x] T042 [P] [US2] Extend `vault_records_list_test.dart` for FR-009a: the header sort button opens the `Sort` sheet, the sheet offers exactly the three orders and marks the same active one as the desktop control, and choosing dispatches the same event and dismisses. Assert the sheet contains no filter of any kind (FR-014b)
- [x] T043 [US2] Add `vault_1a_phone_390x844_light.png`, `vault_1a_phone_390x844_dark.png`, `vault_1a_phone_folders_sheet_390x844_light.png` and `vault_1a_phone_sort_sheet_390x844_light.png` to the golden inventory (SC-002, SC-005)

**Checkpoint**: US1 and US2 both demonstrable; the vault looks like model 1a.

---

## Phase 5: User Story 3 — Every action that exists today still has a home (P1)

**Goal**: nothing reachable before this spec is unreachable after it.

**Independent test**: walk the inventory in `quickstart.md` before and after.

- [x] T044 [US3] Rehome the actions displaced from the status card — sync now, lock, change database, database settings, recycle bin, duplicates — so each is reachable in no more interactions than today with byte-identical wording (FR-015)
- [x] T045 [US3] Point the add affordance at record creation in the currently selected folder, absorbing today's `Add record` row action, and delete that row action. With `All items` selected the target is the root group, not a null group (FR-002a) — T011 is the tripwire (spec §Behaviour this spec deliberately changes)
- [x] T046 [US3] Delete `_FolderAction.addSubfolder` and its call sites; the path becomes `New folder` then `Move…` (FR-006e, spec §Behaviour this spec deliberately changes)
- [x] T047 [US3] Remove `ToggleVaultGroupExpanded` from `vault_event.dart` and `vault_bloc.dart` now that every caller uses `SetVaultFolderExpanded`, so one thing has one event (`data-model.md`)
- [x] T048 [P] [US3] Write `test/features/password_manager/presentation/screens/vault/vault_manage_folders_test.dart`: the same surface at both widths, **exactly one entry point per width** (contract S4, SC-000), the tree always fully expanded, the `•••` recipe identical in both containers (FR-006k), and **`Move…` the only way to change a parent** (FR-006e) — no other affordance reparents a folder
- [x] T049 [US3] Re-run `vault_action_inventory_test.dart` from T003 and make it green by rehoming, never by relaxing an assertion (SC-004). The two spec-marked changes are the only permitted edits, and each carries a comment naming the spec section that authorises it
- [x] T050 [US3] Add `manage_folders_dialog_1024x768_light.png`, `manage_folders_dialog_1024x768_dark.png`, `manage_folders_screen_390x844_light.png` and `manage_folders_row_menu_390x844_light.png` in `test/goldens/vault_folders_test.dart` (SC-002, SC-005)

**Checkpoint**: the restyle has cost the user nothing.

---

## Phase 6: User Story 4 — The rail and tab bar say what they are (P2)

**Goal**: the chrome matches `ICONS.md`.

**Independent test**: compare the rail against the artboard and `ICONS.md`.

- [x] T051 [P] [US4] Replace the rail's `AppGlyph.key` tile child in `vault_shell.part.dart` with the Custode mark artwork at 38 × 38 / r13, adding the asset to `pubspec.yaml` if it is not already declared (FR-016, C-SH-03)
- [x] T052 [P] [US4] Correct `VaultDestination.glyph` in `vault_shell.part.dart`: Vault → `lock`, Sync → `refresh-cw`; Health and Settings are already right (FR-017, C-03-13, DQ-4)
- [x] T053 [US4] Give the selected destination a filled tile in both `_VaultRail` and `_VaultTabBar`, keeping the existing `Semantics(selected:)` — the fill is in addition to it, never instead of it (FR-018, C-03-14, Constitution V)
- [x] T054 [P] [US4] Write `test/features/password_manager/presentation/screens/vault/vault_chrome_test.dart`: the glyph asset name per destination (FR-017), the mark present in the rail (FR-016), the selected fill (FR-018), and the selected state still announced

---

## Phase 8: Polish & cross-cutting

- [x] T055 Re-record the goldens the change legitimately moves, then diff the actual churn against the plan's prediction. Any file from the "must not move" families that moved is investigated as a regression before the diff is accepted (SC-005)
- [x] T056 [P] Verify the accessibility floor across the new surfaces: every text/background pairing ≥ 4.5:1, every focusable has its 2 px ring, every target ≥ 44 × 44, no state signalled by colour alone (Constitution V, SC-007)
- [x] T057 [P] Confirm no hard-coded hex, font family, radius or duration entered the new files, and that every metric traces to `PIXEL_SPEC` through a token (Constitution III). FR-020's "no new capability" is checked here too, by reviewing the diff for any event, service call or field the vault did not already have
- [x] T058 Close the audit ledger: mark `C-SH-03` and `C-03-01`…`C-03-14` resolved in `specs/_design/CONFORMANCE_AUDIT.md`, each naming the task that closed it, and re-record any finding that turned out to be wrong rather than quietly dropping it (SC-001)
- [x] T059 Run `fvm flutter analyze` and `fvm flutter test`, then `fvm flutter test test/goldens --test-randomize-ordering-seed=$RANDOM`, and report the counts against the T002 baseline (Constitution IX, SC-006)
- [x] T060 Walk `quickstart.md` manually on macOS at ≥ 941, in the 704–940 band and at phone width, including the action-inventory walk. This walk is the **only** verification of the interaction-count half of SC-003 and SC-004 — the tests pin the labels and the behaviour, not how many taps a path takes. Walked by hand on the running desktop build and closed 2026-08-31 (PR #179 merged)
- [x] T061 Tick every box in this file in the change that lands the work and run `PROJECT_NUMBER=2 tool/sync_spec_project.sh`, reporting the board state

---

## Dependencies

```
Phase 1  Setup
   ↓
Phase 2  Foundational  ← BLOCKING for every story
         characterisation · BLoC filter · tree widget · Manage folders
   ↓
   ├─ Phase 3  US1 (P1)  ─┐  builds the column, whose header opens T019
   ├─ Phase 4  US2 (P1)  ─┤  builds the chips and sheet; T037 also opens T019
   ├─ Phase 5  US3 (P1)  ─┤  rehoming only; needs US1 and US2 to exist
   └─ Phase 6  US4 (P2)  ─┘  fully independent of US1–US3
   ↓
Phase 8  Polish
```

There is no US5. DQ-8 made the sort control part of both P1 surfaces — the phone
header's button *is* the control — so it lands with US1 and US2 rather than as a
later increment that would have left a dead affordance in the header.

The entry-point/destination dependency runs one way now: Phase 2 builds the
destination, Phase 3 and Phase 4 build entry points into it. US3 no longer sits
between them.

US4 depends on nothing in this spec and can be done at any point after Phase 1.
Nothing else in this spec is separable: after DQ-8 every remaining task belongs
to a P1 surface.

## Parallel opportunities

- **Phase 2 characterisation**: T003, T004, T005, T006 — four different test
  files, no production code touched.
- **Phase 2 widgets**: T015 and T016 once T014 exists.
- **Phase 3**: T032 and T033 while the golden task T034 is written.
- **Phase 4**: T041 and T042 are two different requirements in one file and
  must not be written in parallel with each other.
- **Phase 6**: T051, T052 and T054 are separate concerns; T053 must follow T052
  so the fill is asserted against the right glyph.
- **Phase 8**: T056 and T057 are independent audits.

## Implementation strategy

**MVP**: Phase 1 + Phase 2 + Phase 3. A desktop vault that matches the artboard,
with folder management reachable from the column's `Manage` — because Phase 2
built that surface before Phase 3 deleted the tree that used to hold it.

**The one ordering rule that matters**: T003 must be written and green
**against unchanged code** before T026 deletes anything. Spec 018's most
expensive lesson was a test suite that passed against the unfixed code; a
characterisation test written after the change characterises the change.

**Incremental delivery**: US1 → US2 → US3 are each demonstrable on their own.
US4 can land first if a quick visible win is wanted; it touches one file plus
one vendored glyph.
