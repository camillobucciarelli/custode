# Phase 0 — Research

Every finding below is read from the code at `HEAD` (`7362682`) and cites where.
Nothing here is assumed; the two questions that could not be answered from the
code were answered by the design source and are DQ-6/DQ-7 in the spec.

---

## R1 — Where folder filtering lives today, and why it must move

**Decision**: move folder filtering into `VaultBloc._computeVisibleEntries`,
beside the search and sort filters that are already there.

**Rationale**: `_computeVisibleEntries`
(`lib/.../bloc/vault/vault_bloc.dart:2489`) takes `entries`, `searchQuery` and
`sortBy` — and every caller passes **`state.allEntries`**
(`:253`, `:270`, `:284`, `:323`, `:354`, `:868`). `currentGroupId` is never
consulted. So the BLoC's answer to "which records are visible" is *the whole
vault*, and the folder structure is reconstructed in the widget:
`_EntriesCardState._buildEntriesList` (`vault_entries.part.dart:319`) walks
`groups` into `_EntryTreeNode`s, buckets `entries` by `groupId`, and decides
expansion.

That is the whole of finding C-03-03. FR-006h ("selecting a folder filters the
node **and its descendants**") cannot be satisfied by the widget without it
re-deriving the descendant set on every build, and it is the same kind of filter
the BLoC already owns twice.

**Risk checked**: `visibleEntries` has exactly **one** reader outside the BLoC —
`_VaultEntriesCardSection` (`vault_shell.part.dart:866`, `:869`) — so changing
its meaning cannot reach code I have not read. `allEntries` is read by the
duplicate service, the health report and the autofill publisher; none of them
is touched, because none of them reads `visibleEntries`.

**Alternatives considered**: keep the filter in the widget and pass a
descendant-id set down. Rejected: it leaves two places that decide what is
visible, which is the same class of defect spec 018 removed for selection.

---

## R2 — The sort is built and orphaned

**Decision**: expose `SetVaultSort`; change no ordering behaviour.

**Rationale**: `VaultEntrySort { titleAsc, titleDesc, usernameAsc }`
(`vault_state.dart:14`), `VaultState.sortBy` defaulting to `usernameAsc`
(`:32`) — which is exactly the `Username ↑` the artboard draws — the
`SetVaultSort` event (`vault_event.dart:60`) and its handler (`vault_bloc.dart:278`)
with the comparator at `:2543` all exist and are correct. A repo-wide search
finds **no dispatcher**. The user cannot leave the default.

FR-009 is therefore a control, not a feature. This also means the sort's three
options are fixed by what exists; adding a fourth would be new behaviour and is
out of scope.

---

## R3 — Expansion state exists in memory and must become persistent

**Decision**: keep `VaultState.expandedGroupIds` as the live value; persist it
per database through `SharedPreferences`, keyed by the database path.

**Rationale**: `expandedGroupIds` (`vault_state.dart:25`) and
`ToggleVaultGroupExpanded` (`vault_bloc.dart:364`, normalised and re-emitted at
`:380`) already exist, and `OpenGroup` normalises the set (`:321`). Nothing
writes it to disk, so it resets on every unlock. FR-006g requires it shared by
the column and the phone sheet — which it already is, both reading one state
field — and **persisted per database**, which it is not.

`SharedPreferences` is already a registered dependency
(`injection_container.dart:16`, `core/di/core_di.dart`), so persistence costs a
key and two calls, not a new mechanism (Constitution VIII).

**Alternatives considered**: persisting into the `.kdbx` itself. Rejected: it
writes the file for a UI preference, which Constitution VII's backup discipline
would then have to cover, for something that is not user data.

---

## R4 — `Manage folders` needs a presentation the router does not have

**Decision**: add `VaultDialogPresentation` and a `ManageFoldersSurface`;
`presentationFor` returns the dialog when `layout.hasDetailPane`, the pushed
route otherwise.

**Rationale**: DQ-6's own table maps width to container — pushed screen below
704, dialog at 704–940 and again at ≥ 941. `layout.hasDetailPane` is exactly
`width >= 704` (`core/responsive/breakpoints.dart`), so the rule is one
predicate and needs no new threshold.

The router's `VaultSurfacePresentation` is sealed over route, sheet and pane
(`vault_shell_router.dart:321`). The nearest existing fit, `KvBottomSheet`, is
capped at 560 px on desktop (`core/widgets/kv_bottom_sheet.dart:33`) but stays
bottom-anchored — a different surface from the one drawn, and under
Constitution IV that difference is asserted, not glossed. A pane was rejected by
DQ-6 itself: the dialog "adds no column", so the width arithmetic stays put.

**Alternatives considered**: a bare `showDialog` from the folder column,
bypassing the router. Rejected: it would be the only vault surface outside the
router's session, cancellation and result handling — exactly what spec 018 spent
its whole scope consolidating.

---

## R5 — A chevron that is a separate target inside a 62 px row

**Decision**: the row is the filter target; the chevron is a 44 × 44 target
inset at the leading edge, and the row's own hit area excludes it.

**Rationale**: FR-006f requires expanding not to change the filter, and
Constitution V requires both targets to be ≥ 44 × 44. A 62 px row can hold a
44 px chevron target and still leave the rest of the row for the filter, but
only if the two do not overlap — an overlapping pair is a target that does two
things depending on where inside it you press, which is worse than either.

**Alternatives considered**: chevron on the trailing edge. Rejected: the
artboards put it at the leading edge, before the folder glyph, where it reads as
part of the indentation.

---

## R6 — What the icon work actually costs

**Decision**: no asset work. Change three glyph mappings and the rail's mark.

**Rationale**: DQ-4 made `ICONS.md` normative for glyph identity, and the
vendored set is already the real Lucide geometry at stroke 2.75 —
`assets/icons/lucide/lock.svg` is `rect 3,11 18×11 rx2` + `M7 11V7 a5`, which is
Lucide's own path, not the artboard's redraw. `refresh-cw` and `shield-check`
likewise. So C-03-13 is `VaultDestination.glyph` (`vault_shell.part.dart:891`)
and nothing else.

C-SH-03 needs the mark as artwork: `specs/_design/custode-mark.svg` ships, and
`ICONS.md` §1 fixes it at 38 × 38 / r13 in the rail. The rail currently draws
`AppGlyph.key` in a tile of the right size, so the change is the child, not the
container.
