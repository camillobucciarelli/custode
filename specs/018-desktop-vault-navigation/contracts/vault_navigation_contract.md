# Contract: vault navigation and record actions

**Phase 1** · spec 018 · 2026-08-28

The vault shell is a UI surface, not a network API, so this is a **UI
contract**: the guarantees the navigation layer makes to the rest of the app
and to the tests. Each clause is stated so a widget test can assert it.

---

## C1 - Layout classification

```dart
VaultLayoutClass VaultLayoutClass.fromWidth(double width)
```

**Pure.** No theme, platform, state or `MediaQuery` input beyond `width`.

| Given width | Returns |
|---|---|
| `599` | `narrowTabBar` |
| `600` | `narrowRail` |
| `703` | `narrowRail` |
| `704` | `wide` |
| `940` | `wide` |
| `941` | `wideWithFolders` |
| `1024` | `wideWithFolders` |

**Guarantees**

- G1.1 Total: every non-negative width maps to exactly one case.
- G1.2 Monotonic: `w1 <= w2` implies `fromWidth(w1) <= fromWidth(w2)` in the
  order above.
- G1.3 The boundary values 600 / 704 / 941 are the *first* width of their case.

**Forbidden**: any other production call site computing a presentation from a
width or from `BoxConstraints`. This is assertable by grepping the vault tree
for `Breakpoints.` and `constraints.maxWidth` in presentation-selection
positions.

---

## C2 - Surface presentation

```dart
VaultSurfacePresentation presentationFor<R>(
  VaultSurface<R> surface,
  double width,              // the WINDOW width, supplied by the shell
)
```

**Implementation note (deviation from the first draft of this contract)**: the
signature is unchanged. The draft proposed replacing `width` with
`VaultLayoutClass`, but the generator's 995 rule needs a width that is not a
class boundary, so passing the class alone would have required a second
parameter carrying the width anyway. Instead the function *derives*
`VaultLayoutClass.fromWidth(width)` internally, which delivers the same
guarantee — one definition of "wide" — with no call-site churn and no second
parameter. The rule that matters is unchanged and still testable: **the width
handed in is the window width; no caller substitutes its own
`BoxConstraints`.**

| Surface | narrow* | wide* |
|---|---|---|
| `EntrySurface`, `OtpScannerSurface`, `HealthCategorySurface`, `SyncLinkSurface`, `DatabaseSettingsSurface` | route | pane — amended 2026-11-13 (user-directed): `AttachmentsSurface` left this row and the codebase; the record detail lists attachments and the editor adds and removes them, so no separate surface opens |
| `RecycleBinSurface`, `DuplicatesSurface`, `MergePreviewSurface` | route | route — amended 2026-08-31 (user-directed): full-screen pushed routes at every width; the earlier dialog-plus-sheet stack on wide layouts was hard to read |
| `GroupEditSurface`, `MoveTargetSurface` | sheet | dialog (bare) — amended 2026-08-30: pane-hosting rendered them behind the spec-019 Manage dialog and replaced the record detail with a floating card |
| `SyncConflictSurface` | sheet | pane |
| `PasswordGeneratorSurface` | sheet | **pane iff width >= 995**, else sheet |

Note that "narrow" here means below the derived 704, not below 600: FR-002d
moved the pane break, so the 600–703 band presents as narrow.
| `KeyFileManagerSurface` | sheet | sheet |
| `ConfirmationSurface` | bare dialog | bare dialog — amended 2026-09-05 (user-directed): a yes/no confirmation is a modal dialog at every width; the builder supplies the `AlertDialog`. Supersedes the 2026-08-31 `dialogOnWide` split |

**Guarantees**

- G2.1 `narrowTabBar` and `narrowRail` produce identical presentations. The
  rail is a chrome difference only - this is what keeps mobile unchanged.
- G2.2 The mapping for every surface except `PasswordGeneratorSurface` is
  unchanged from today, so `vault_surface_migration_matrix_test.dart` keeps its
  expectations and only updates call sites.
- G2.3 `PasswordGeneratorSurface` is the sole surface whose presentation
  depends on a width beyond the class, because 995 is not a class boundary.

---

## C3 - Selection

```dart
// records list, inbound
final String? selectedEntryId;
final ValueChanged<String> onSelectEntry;
```

**Guarantees**

- G3.1 The records list renders **no** detail surface. Asserting
  `find.byType(_EntryDetailPanel)` inside the entries card finds nothing.
- G3.2 At most one row carries the selected treatment.
- G3.3 A row is selected iff `selectedEntryId == entry.id`, at every layout
  class - including `wideWithFolders`, where today none is (D3).
- G3.4 `onSelectEntry` is the list's only way to change the selection. It never
  mutates it directly.
- G3.5 Selection survives a layout-class change; the presentation does not.
- G3.6 Selection is cleared when the entry leaves `allEntries` or leaves the
  visible list.

---

## C4 - Detail dismissal

**Guarantees**

- G4.1 Detail code never calls `Navigator.pop`. Dismissal goes through
  `VaultOperationScope.complete` / `cancelOperation`.
- G4.2 Dismissal works identically under route, sheet and pane presentation.
- G4.3 Ending a detail session cancels every surface stacked on it (already
  provided by `VaultShellRouter._finish`).
- G4.4 Ending a detail session clears the selection, whatever ended it - back
  affordance, escape, entry deletion, destination change.
- G4.5 An entry vanishing produces no error dialog and no exception; the pane
  returns to `_EntryDetailEmptyState`.

---

## C5 - Record actions

```dart
Future<void> handleEntryAction(
  BuildContext surfaceContext,   // the surface the action was started from
  String entryId,                // NOT a VaultEntry
  _EntryAction action,
)
```

**Guarantees**

- G5.1 The entry is read from `VaultBloc.state.allEntries` by `entryId` **after**
  the confirmation resolves, never before.
- G5.2 The `VaultBloc` is captured before the first `await`; the dispatch does
  not depend on any widget still being mounted.
- G5.3 Liveness is checked on `surfaceContext`, never on the records list.
- G5.4 Every confirmed action ends applied or reported. There is no third
  outcome.
- G5.5 Cancelling leaves the vault unchanged and the selection intact.
- G5.6 The action set is identical at every layout class.
- G5.7 If the entry no longer exists at confirmation time, the action is
  abandoned and the user is told - it is not applied to a stale copy.

---

## C6 - Preserved behaviour (the regression contract)

**Guarantees** - these are what US5 buys:

- G6.1 At `narrowTabBar`, activating a record pushes a full-screen detail with
  a working back affordance, exactly as today.
- G6.2 All four record actions behave as today from a pushed detail.
- G6.3 Every user-facing navigation and action string is byte-identical.
- G6.4 No golden at 390x844 is added, removed or re-recorded.
- G6.5 The bottom tab bar, its four destinations and their order are unchanged.

**G6.4 is verified by diffing the golden file list, not by the suite passing.**
