# 018 — Desktop vault navigation and entry actions

**Status**: Implemented 2026-08-29 (manual QA pending) · **Kind**: Fix / Vault navigation
**Created**: 2026-08-28
**Depends on**: 002 (navigation shell), 004 (entry editor / detail surfaces)
**Coordinates with**: 005 (health, sync destinations), 017 (password history opens from the detail surface)
**Design source**: `docs/design_handoff_custode_restyle/03 Vault - modelli di navigazione.dc.html`
(option **1a**, the adopted model), `specs/_design/HANDOFF.md` §Structure and
navigation, `specs/_design/PIXEL_SPEC.md` §1 (Tablet columns) and §2 (Selected row)

**Input**: User description: "crea una spec per fixare la navigazione e la gestione delle azioni di edit, delete ecc su desktop in vista lista/dettaglio perché è buggata, crea inconsistenze e non funziona. fare attenzione che le fix non vadano a rompere la navigazione mobile che ora sembra funzionare"

## Summary

On desktop and other wide windows the vault's list/detail view behaves
inconsistently: which detail surface appears depends on the window width and on
where the user clicked, the selected row is not always highlighted, and the
per-record actions (edit, move, attachments, delete) sometimes do nothing,
sometimes act on a stale copy of the record, and sometimes leave the detail
area showing a record that no longer exists.

This spec fixes desktop navigation and record actions so that one record
selection drives one detail surface at every width, and every record action
applies to the record the user is looking at. Mobile navigation is currently
correct and must be preserved byte-for-byte in behaviour: the mobile flow is
part of the acceptance criteria, not collateral.

### Observed defects (the "why")

The vault has two independent ways to show a record's detail on a wide window,
and they are chosen by two different width rules that do not agree:

- **D1 — Two competing detail surfaces.** The records list can render its own
  inline list/detail split when *its own column* is wide enough, while the
  vault shell separately reserves a detail area of its own for whatever
  surface the navigation router publishes. Depending on window width the user
  gets one, the other, or the same record shown in an unexpected place.
- **D2 — Three disagreeing definitions of "wide".** The navigation router, the
  shell layout and the records list each decide "is this wide?" from a
  different measurement (whole window vs. shell column vs. the list's own
  constraints) and against different thresholds. Around the boundaries this
  produces layouts that no single rule describes.
- **D3 — Selection is not visible in the true desktop layout.** In the widest
  layout, where list and detail are side by side, no row is highlighted as
  selected, so the user cannot tell which record the detail area belongs to.
- **D4 — Actions applied to a stale record.** A record action started from the
  detail surface can operate on the copy of the record captured when the
  detail was opened, so a second edit made right after a first one silently
  reverts the first one's changes.
  - *Correction, found during implementation (2026-08-29):* this path was
    **unreachable in practice**. It lived only in the records list's inline
    split, and that split required the card itself to be ≥ 600 px wide. The
    card only ever received `width − 109`, and above the three-column
    threshold it was capped at the list column's width — so the condition was
    never met at any window size. D4 is therefore a latent defect, not an
    observed one. The fix still lands (an id re-read at confirmation time is
    correct by construction and removes the trap), but no user-visible
    stale-write bug is being claimed.
- **D5 — Actions that silently do nothing.** Record actions are guarded on the
  liveness of the records list rather than the surface the action was started
  from, and dispatch through the list's own context.
  - *Sharpened during implementation (2026-08-29):* a mere rebuild is not
    enough to trigger it — the list must be **unmounted**. That is exactly
    what happens in the single-pane band, where the router pane *replaces*
    the vault pane rather than sitting beside it. Confirming Delete or Move
    there completes the dialog and then discards the result: no write, no
    error, no message. Mobile never hits it because a pushed route stacks on
    top of the list instead of replacing it — which is precisely why the
    defect reads as "desktop is broken, mobile is fine".
  - This is the most severe defect in the spec: it silently discards a
    destructive action the user explicitly confirmed. It is covered by a
    regression test verified failing against the pre-fix code.
- **D6 — Deleted record leaves a dead detail.** When the displayed record is
  deleted (from this window, from a sync, or from the recycle bin), the detail
  area is dismissed through a mechanism that only exists for the mobile
  presentation. On desktop the detail area is left showing an empty or stale
  surface that the user cannot close except by selecting another record.
- **D7 — Editing hides the record being edited.** On a wide window the editor
  claims the same detail area as the record's own detail. Starting an edit
  replaces the record's detail with the editor, and finishing the edit returns
  to the empty state instead of the record just saved, losing the user's place.
- **D8 — Back leaves selection and detail out of sync.** Dismissing the detail
  area with the back affordance clears the detail but not the list's idea of
  what is selected (and vice versa), so the highlighted row and the visible
  detail can disagree.
- **D9 — Same record, two different detail UIs.** Opening a record from the
  records list and opening the same record from the Health destination produce
  visually different detail presentations at the same window width.

## Clarifications

### Session 2026-08-28

- Q: Which mechanism becomes the single canonical way to present a record's detail? → A: The navigation shell's routed detail area. The records list no longer renders a detail of its own; it reports the selection and the shell decides the presentation (pushed screen when narrow, side detail area when wide).

- Q: Where does the record editor appear on a wide window? → A: In the same routed detail area, with the record's title in the editor header and the record still highlighted in the list; saving or cancelling returns that record's detail to the area. No new presentation type is introduced.

- Q: Which measurement decides the layout class, and at which thresholds? → A: One window-level width, classified once by the shell and passed down; no descendant re-measures its own constraints to pick a presentation. *(The threshold half of this answer was superseded on the same day — see the final clarification below: the breaks are `Breakpoints.mobile` plus the derived 704 / 941 / 995, and `Breakpoints.tablet` does not gate the folder column.)*

- Q: How should the vault behave between 600 px and the width where the design's columns first fit? → A: As narrow — the icon rail is shown, the records list fills the remaining width, and opening a record pushes its detail as a full screen with a back affordance. The threshold is derived from the design's column minimums, never written as a bare constant. *(The arithmetic was superseded: the corrected rail width of 72 makes it `72 + 330 + 300 + 2 = 704`, not 708.)*

- Q: Which visual-regression evidence does spec 018 require? → A: Three new golden pairs at 1024×768 in light and dark — wide layout with a record selected, wide layout empty detail, and the editor hosted in the detail pane. The fit-width boundary, threshold resizes and deleted-record dismissal are covered by named widget assertions with the omitted axes stated. Every existing 390×844 golden stays frozen.

- Q: Which artboard's column widths are normative for the vault at 1024? → A: Referred back to the design source and answered: **model 1a is normative, with the folder column made explicitly conditional on width**. Every column takes a single value — rail **72**, folders **236**, list **330**, detail/editor flex with min **300**, generator **290** — and the 76/352 figures are corrected as drift, not variants. Three width bands result (see FR-002d); the spec 018 threshold is **704**.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — One selection, one detail, at every width (Priority: P1)

As a desktop user, when I click a record in the list I see that record's
detail in the detail area, with its row visibly selected, and the same thing
happens no matter how wide my window is or which list I opened the record from.

**Why this priority**: It is the base defect. Every other action bug is harder
to see or reproduce until selection and detail agree. Fixing this alone makes
the desktop vault usable.

**Independent Test**: Resize the window across the full supported range and
click records in the list; verify exactly one detail surface is visible, that
it shows the clicked record, and that the clicked row is highlighted.

**Acceptance Scenarios**:

1. **Given** a desktop window at any width at or above the wide threshold,
   **When** the user clicks a record in the list, **Then** exactly one detail
   surface is shown, it shows that record, and that record's row is the only
   highlighted row.
2. **Given** a record is selected and its detail is visible, **When** the user
   resizes the window across the wide/narrow threshold and back, **Then** the
   same record stays selected, its detail stays visible in the layout
   appropriate to the new width, and no second detail surface appears.
3. **Given** a record shown from the Health destination, **When** compared with
   the same record opened from the records list at the same window width,
   **Then** both present the same detail surface with the same actions.
4. **Given** a wide window with no record selected, **When** the vault is
   opened, **Then** the detail area shows the empty state and no row is
   highlighted.

---

### User Story 2 — Record actions always apply, and apply to the current record (Priority: P1)

As a desktop user, when I choose Edit, Move, Attachments or Delete for the
record I am looking at, the action is applied to that record as it is right
now, and it is either applied or reported — never silently dropped.

**Why this priority**: Silent no-ops and stale writes are data-integrity
problems, not cosmetic ones: D4 makes a confirmed edit revert an earlier one.

**Independent Test**: With a record's detail open, trigger a background change
to the vault (a search, a sync, a change from another surface), then run each
of the four actions and confirm each takes effect on the current record.

**Acceptance Scenarios**:

1. **Given** a record's detail is open on a wide window, **When** the user
   edits it, saves, then immediately edits it again and saves, **Then** both
   edits are present in the record and neither reverts the other.
2. **Given** a record's detail is open, **When** the records list rebuilds
   underneath (search, sync, or a change made elsewhere) and the user then
   confirms Edit, Move, Attachments or Delete, **Then** the action is applied
   to the record; it is never accepted in the dialog and then dropped.
3. **Given** the user cancels a record action dialog, **When** the dialog
   closes, **Then** the vault is unchanged and the record's detail is still
   shown with the same record selected.
4. **Given** a record action fails, **When** the failure occurs, **Then** the
   user is told; no action ends with neither a change nor a message.

---

### User Story 3 — Editing keeps the user's place (Priority: P2)

As a desktop user, when I edit the record I am viewing, I can still tell which
record I am editing, and when I save or cancel I am returned to that record's
detail — not to an empty pane.

**Why this priority**: D7 is a constant annoyance in the main editing loop but,
unlike US1 and US2, it costs the user navigation rather than correctness.

**Independent Test**: On a wide window, open a record, edit it, save; then
repeat and cancel. Confirm the record's detail is shown in both cases.

**Acceptance Scenarios**:

1. **Given** a record's detail is open on a wide window, **When** the user
   starts an edit, **Then** the user can still identify the record being edited
   and the record stays selected in the list.
2. **Given** an edit is in progress on a wide window, **When** the user saves,
   **Then** the record's detail is shown again with the saved values and the
   record still selected.
3. **Given** an edit is in progress, **When** the user cancels, **Then** the
   record's detail is shown again unchanged, with the record still selected.

---

### User Story 4 — A deleted record never leaves a dead detail (Priority: P2)

As a desktop user, when the record I am viewing is deleted — by me, by a sync,
or by emptying the recycle bin — the detail area returns to the empty state
and nothing is left selected.

**Why this priority**: D6 leaves the user stuck in a state with no visible way
out, but it needs a deletion to occur, so it is less frequent than US1/US2.

**Independent Test**: Open a record's detail on a wide window, delete the
record, and confirm the detail area returns to the empty state with no
highlighted row and no dismissable-but-dead surface.

**Acceptance Scenarios**:

1. **Given** a record's detail is open on a wide window, **When** that record
   is deleted from the detail's own Delete action, **Then** the detail area
   returns to the empty state and no row remains highlighted.
2. **Given** a record's detail is open, **When** that record disappears because
   of a sync or because the recycle bin was emptied, **Then** the detail area
   returns to the empty state without an error dialog.
3. **Given** a record's detail is open and a nested surface (attachments, move
   target, confirmation) is on top of it, **When** the record disappears,
   **Then** the nested surface is dismissed too and the detail area returns to
   the empty state.

---

### User Story 5 — Mobile navigation is unchanged (Priority: P1)

As a mobile user, my navigation keeps working exactly as it does today:
tapping a record pushes its detail, back returns to the list, record actions
work from the pushed detail, and the tab bar behaves as before.

**Why this priority**: The user's explicit constraint. Mobile is the currently
correct path and a regression there is worse than the desktop bugs being fixed.

**Independent Test**: Run the existing mobile navigation and entry-action tests
and goldens unchanged; add coverage where a behaviour is currently only
verified by manual use.

**Acceptance Scenarios**:

1. **Given** a mobile-width window, **When** the user taps a record, **Then**
   its detail is pushed as a full screen with a working back affordance, as
   today.
2. **Given** a pushed record detail on mobile, **When** the user runs Edit,
   Move, Attachments or Delete, **Then** each behaves as it does today.
3. **Given** the existing mobile navigation tests and goldens, **When** this
   change is applied, **Then** they pass without being modified or re-recorded.

---

### Edge Cases

- Window resized across the wide/narrow threshold while a record action dialog
  or the editor is open: the in-progress action must not be lost, duplicated,
  or left orphaned in a layout that no longer hosts it.
- Window resized while a nested surface stack is open (record detail →
  attachments → confirmation): the stack must survive the presentation change
  or be dismissed as a unit, never partially.
- A record selected in the list is filtered out by a new search query: the
  detail must follow one stated rule (clear the selection) rather than showing
  a record absent from the visible list.
- The last record in the vault is deleted while its detail is open.
- A record is opened from Health or from the duplicates view while a different
  record is already selected in the records list.
- Two actions started in quick succession (e.g. Delete confirmed while an Edit
  dialog is still closing).
- The 941 folder-collapse point and the 995 generator point: the detail or
  editor must keep its 300 px minimum on both sides of each, and the folder
  column must appear and disappear without disturbing the selection.
- Crossing the fit width while a record is selected: the selection survives and
  the detail changes presentation — pushed screen below, side pane above — with
  no duplicate detail and no lost record.
- Keyboard-only navigation: the selected row must be reachable and its
  selection visible without a pointer.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: There MUST be exactly one record-detail surface visible at any
  time and at any window width. Two detail presentations of the same or of
  different records MUST NOT be visible simultaneously. (D1)
- **FR-001a**: The navigation shell's routed detail area MUST be the sole
  owner of record-detail presentation. The records list MUST NOT render a
  record detail of its own; it reports which record is selected and the shell
  presents it — as a pushed full screen when narrow, in the side detail area
  when wide — using the same detail content in both cases. (D1, D9)
- **FR-002**: The decision of which layout to present MUST come from one shared
  definition of the available width and one set of named thresholds, used by
  the navigation shell, the records list and the surface presentation rules
  alike. No surface may derive its own competing notion of "wide". (D2)
- **FR-002a**: The width MUST be the window width, classified once by the
  navigation shell and passed down; no descendant may re-measure its own
  constraints to choose a presentation. Every threshold MUST be either
  `Breakpoints.mobile` (600, which selects tab bar vs icon rail) or one of the
  three widths derived from the FR-002b column values — 704, 941 and 995 —
  each written in code as its derivation, not as a bare number. No other
  layout constant may exist. In particular `Breakpoints.tablet` (1024) MUST
  NOT gate the folder column: the folder column is governed by the derived
  941, and the two differ. (D2)
- **FR-002b**: The wide layout MUST use the design's normative column
  inventory, one value per column and no ranges:

  | Column | Width | Notes |
  | --- | --- | --- |
  | Icon rail | **72** | fixed |
  | Folder column | **236** | fixed, conditional on width (FR-002d) |
  | Records list | **330** | fixed |
  | Detail / editor | *flex*, **min 300** | never fixed |
  | Generator | **290** | fixed, conditional (FR-002e), divider on its **left** |

  Every fixed column carries a 1 px divider on its right, except the generator
  which carries it on its left. Separation is a divider, never a shadow. The
  `76` rail and `352` list figures that appear in some artboards are corrected
  drift, not variants, and MUST NOT be implemented.
- **FR-002c**: The detail pane MUST be persistent at wide widths — always
  present, showing the empty state when no record is selected — rather than a
  pane that appears only once a surface is opened. (D1, D3)
- **FR-002d**: The vault MUST present exactly three width bands, each derived
  from the FR-002b column widths rather than written as a bare constant:

  | Width | Strip |
  | --- | --- |
  | ≥ **941** | rail 72 \| folders 236 \| list 330 \| detail *flex* (min 300) |
  | **704 – 940** | rail 72 \| list 330 \| detail *flex* (min 300) — the folder column is not shown |
  | < **704** | **pushed detail** — the list fills the width and the detail pushes over it |

  Derivations, which MUST appear in the code beside the constants:

  ```
  folder-collapse point    72 + 236 + 330 + 300 + 3 dividers = 941
  pushed-detail threshold  72 +       330 + 300 + 2 dividers = 704
  ```

  Below `Breakpoints.mobile` the bottom tab bar is shown; from
  `Breakpoints.mobile` to 704 the icon rail replaces it and the detail still
  pushes. No layout may squeeze the list below 330 or the detail below 300 in
  order to keep a column. In the 704–940 band every folder MUST stay reachable
  through the records list's own folder rows. (D1, D2)
- **FR-002e**: The generator MUST occupy a 290 px right-hand column when it
  fits, and MUST fall back to a sheet over the editor when it does not:
  - Generator-as-column threshold: `72 + 330 + 300 + 290 + 3 = 995`. Below
    995 the generator opens as a sheet — a declared fallback, not an accident.
  - When the generator column opens, **the folder column is what collapses;
    the records list never does.** The list is the screen's navigation spine
    and the folder column is recoverable from the rail.
  - Folder column and generator column therefore coexist only from
    `72 + 236 + 330 + 290 + 300 + 4 = 1232` up. At 1024 they never coexist.
  - The records list MUST stay fully legible and clickable while the editor or
    generator is open. It MUST NOT be dimmed: a dimmed interactive column
    fails contrast and misrepresents itself as inactive. (Constitution
    principle V)

  Spec 018 owns only the reserved slot and the two rules above; the
  generator's contents remain with the editor spec.
- **FR-003**: The currently selected record MUST be a single piece of state
  shared by the list and the detail surface, so the highlighted row and the
  shown detail can never disagree, including after a back action. (D3, D8)
- **FR-004**: The selected record's row MUST be visibly highlighted in every
  layout where the list and the detail are visible at the same time, using a
  cue that is not colour alone. (D3)
- **FR-004a**: The selected row MUST use the design's defined selected-row
  treatment (`PIXEL_SPEC.md` §2 "List row"): `accent-200` background,
  `accent-900` subtitle, avatar `accent-300` on `accent-900`; in dark,
  `accent-800` / `accent-200`. It MUST additionally carry a non-colour cue to
  satisfy FR-004. (D3, Constitution principles III and V)
- **FR-005**: Every record action MUST operate on the record's current stored
  values at the moment the action is confirmed, never on a copy captured when
  the detail or the action dialog was opened. (D4)
- **FR-006**: A confirmed record action MUST either be applied or reported as
  failed to the user. An action MUST NOT be discarded because the list, the
  detail or any intermediate surface has rebuilt or been replaced. (D5)
- **FR-007**: Dismissal of a detail surface MUST use the presentation-neutral
  mechanism owned by the navigation router, so the same code path works whether
  the surface is currently a pushed screen, a sheet or a side pane. (D6)
- **FR-008**: When the record shown in the detail surface no longer exists, the
  detail surface and every surface opened on top of it MUST be dismissed and
  the selection cleared, without an error dialog. (D6)
- **FR-009**: Starting an edit of the shown record MUST NOT hide that record's
  identity, and completing or cancelling the edit MUST return to that record's
  detail with the record still selected. (D7)
- **FR-009a**: On a wide window the editor MUST occupy the same routed detail
  area as the record's detail, MUST show the record's title in its own header,
  and MUST leave the record highlighted in the list while the edit is in
  progress. Saving or cancelling MUST restore that record's detail to the
  area. No additional presentation type is introduced for the editor. (D7)
- **FR-010**: Opening a record from any origin — records list, Health, the
  duplicates view, search results — MUST produce the same detail surface with
  the same set of actions at the same window width. (D9)
- **FR-011**: The set of record actions offered MUST be identical across
  layouts. A record action available on mobile MUST be available on desktop and
  vice versa.
  *Amended by spec 020 (2026-08-31): `Attachments` is no longer a record
  action in the detail header overflow at any width. It is a permanent section
  of the detail body with its count and a `Manage` action, identical across
  layouts. The record-row `•••` menu is unchanged. The layout-parity guarantee
  itself stands.*
- **FR-011a**: At wide widths no record surface may be presented as a dialog
  stacked on another dialog; per the adopted design, what is a screen on
  mobile is a pane on tablet and desktop. (Design: HANDOFF §Structure and
  navigation)
- **FR-012**: Mobile navigation behaviour MUST be unchanged: record tap pushes
  a full-screen detail, back pops it, and existing mobile navigation tests and
  goldens MUST pass without modification or re-recording. (US5)
- **FR-013**: Existing user-facing strings for navigation and record actions
  MUST remain byte-identical unless this spec names the change. (Constitution
  principle VI)
- **FR-014**: When the selected record leaves the visible list because of a
  search or folder change, the selection MUST be cleared and the detail area
  MUST return to the empty state.
- **FR-015**: A window resize across a layout threshold MUST NOT cancel, drop,
  duplicate or orphan an in-progress record action, editor or nested surface.
- **FR-016**: The selected row MUST be reachable and its selection perceivable
  by keyboard-only and screen-reader users, and the detail surface MUST keep a
  usable minimum width at every supported window size. (Constitution
  principle V)

### Verification requirements

- **VR-001**: Three new golden pairs MUST be added at 1024 × 768, each in light
  and dark: **wide layout with a record selected** (list and persistent detail
  pane, selected row treatment visible), **wide layout empty detail** (no
  record selected), and **editor hosted in the detail pane** (record title in
  the editor header, row still selected).
- **VR-002**: The following MUST be covered by named widget assertions rather
  than pixels, because they are behavioural rather than visual: the fit-width
  boundary immediately below and immediately above; a resize across the
  boundary with the editor and with a nested surface open; the deleted-record
  dismissal returning to the empty state; and an action confirmed after the
  records list has rebuilt. The omitted axes for these cases are the mobile
  size and the dark theme, both covered elsewhere.
- **VR-003**: No golden at 390 × 844 may be added, removed or re-recorded by
  this change. A re-recorded mobile golden is a failure of US5, not an
  acceptable side effect. (SC-006)

### Key Entities

- **Selected record**: the single identity of the record the user is currently
  looking at; owned in one place and read by both the list and the detail
  surface.
- **Detail surface**: the presentation of one record's fields and actions;
  identical in content regardless of whether it is currently shown as a pushed
  screen or a side pane.
- **Layout width class**: the named classification of the available width
  (narrow / wide, plus the folder-pane threshold) that every navigation
  decision consults.
- **Record action**: one of edit, move, attachments, delete — each with a
  confirmation step, a target record identity, and a definite applied-or-
  reported outcome.

## Design decisions *(resolved)*

Verified 2026-08-28 against the live Claude Design project
`5151eacb-bbf2-44aa-921c-6a0e2d231d12`. Every design file the repo holds is
byte-identical to the project, so this was never a sync problem — the design
specified two different column strips for the same 1024 × 768 vault:

| Artboard | Column strip at 1024 × 768 |
| --- | --- |
| `03 …` model **1a**, tablet (the adopted navigation model) | rail 76 \| folders 236 \| list 330 \| detail *flex* |
| `04-06 …` "Dettaglio nel pannello destro" | rail 72 \| list 352 \| detail *flex* — no folder column |
| `04-06 …` "Editor con generatore aperto" | rail 72 \| list 352 *(50 % opacity)* \| editor *flex* \| generator 290 |

They could not be averaged: at 1024,
`76 + 236 + 330 + 290 + 4 dividers = 936` leaves the editor 88 px, so the
folder column and the generator column cannot coexist there.

The question was referred back to the design source and answered on
2026-08-28. The decisions are now normative and are carried by FR-002b,
FR-002d and FR-002e:

- **DQ-1 — normative strip**: model **1a**, with the folder column made
  explicitly *conditional on width* rather than tied to `Breakpoints.tablet`.
  `04-06` is the editor's working context, not a competing shell: its 352
  column carries the folder name in its own header, i.e. the folder identity
  had already moved into the list. Adopting `04-06` would have deleted a
  column the app ships today, on the authority of an artboard drawn to study
  the editor.
- **DQ-2 — the generator**: a real 290 px column with a left divider, below
  995 a sheet over the editor. It collapses the folder column, never the
  records list. The 50 % dimming of the list is **not** normative — a drawing
  device only, rejected on contrast and honesty grounds.
- **DQ-3 — rail and list**: single values, `72` and `330`. The `76` and `352`
  figures are drift in one artboard each, corrected rather than promoted to
  variants.

### Follow-up owed elsewhere *(not spec 018's work)*

These keep the sources consistent with the decision and are recorded here so
they are not lost:

- `specs/_design/PIXEL_SPEC.md` §1 "Tablet columns" (and its identical copy in
  `docs/design_handoff_custode_restyle/`) still reads
  `72 (76 in the vault variant)` and `330–352`, and omits the generator row.
  It should be rewritten to the single values above.
- In the design project: `03` rail `76 → 72`; `04-06` list `352 → 330` in both
  artboards; remove `opacity:.5` from the list in "Editor con generatore
  aperto"; add a drawn artboard for the 704–940 folder-collapsed band, which
  this spec now cites but no artboard shows.

### Scope note — the folder switcher

The decision describes the 704–940 band as folders "collapsing into the list
header, with a folder switcher on the rail". A rail-mounted folder switcher
does not exist today and is new UI, not a navigation fix. Spec 018 therefore
implements the band using the folder navigation the records list **already**
provides (folders appear as rows in the list tree), which keeps every folder
reachable in that band. The rail switcher is deferred to a separate change;
this spec's acceptance does not depend on it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: At every window width in the supported range, selecting a record
  shows exactly one detail surface for that record — pushed below the fit
  width, in the persistent pane above it — with the row highlighted whenever
  list and detail are visible together, verified in light and dark.
- **SC-001a**: The vault presents exactly the three bands of FR-002d across
  the whole width range, and every threshold in the navigation code is one of
  `Breakpoints.mobile`, or the derived 704 / 941 / 995 values shown with their
  derivation; no other layout constant remains. In particular the undocumented
  `708` constant present today is gone — the corrected rail width makes the
  pushed-detail threshold **704**, so the existing number was near-right for
  the wrong reason.
- **SC-002**: 100% of confirmed record actions (edit, move, attachments,
  delete) result in either an applied change or a message to the user; zero
  silent no-ops in the tested scenarios, including with the list rebuilding
  underneath.
- **SC-003**: Two consecutive edits of the same record both persist; the second
  never reverts the first.
- **SC-004**: Deleting or losing the shown record returns the detail area to
  the empty state within one frame, with nothing selected and no orphaned
  surface, in 100% of the tested deletion paths.
- **SC-005**: Saving or cancelling an edit returns the user to the edited
  record's detail in 100% of attempts on wide windows, and the record's title
  is visible in the editor header for the whole edit.
- **SC-006**: The existing mobile navigation and record-action tests and
  goldens pass unmodified, and no golden file for a mobile-width layout is
  added, removed or re-recorded by this change — verified by the change's own
  file list, not only by the suite passing.
- **SC-007**: Opening the same record from the records list, from Health, and
  from the duplicates view produces indistinguishable detail surfaces at a
  given width.
- **SC-008**: Resizing across every layout threshold with an action, editor or
  nested surface open never loses the in-progress work, across all tested
  threshold crossings.

## Assumptions

- The existing navigation router's surface/presentation model is the intended
  design and is kept; the fixes make the shell, the list and the presentation
  rules agree with it rather than replacing it.
- The wide-layout target is the adopted design's model 1a: icon rail, folder
  column from the derived 941 up, records list column, persistent detail pane.
  This spec does not redesign that arrangement; it makes the code match it and
  agree with itself.
- The design specifies mobile at 390×844 and the tablet/desktop baseline at
  1024×768. The two bands below 941 are not drawn by any artboard; their
  behaviour comes from the 2026-08-28 design decision recorded above, not from
  a drawing, and the 704–940 band is the one most likely to need a drawn
  artboard before it is styled.
- Mobile behaviour today is correct as-is and is the reference for US5; where a
  mobile behaviour is currently only verified by hand, this spec adds the test
  rather than changing the behaviour.
- The thresholds themselves may be renamed and centralised, but the widths at
  which the mobile layout applies do not change, so no mobile golden shifts.
- No new BLoC is introduced; the selected-record state lives in the existing
  navigation/shell layer per constitution principle II.
- Recycle-bin, duplicates and health destinations are in scope only where they
  open a record detail or a record action; their own internal layouts are out
  of scope.
- Desktop keyboard shortcuts beyond making the existing selection reachable and
  visible are out of scope.
