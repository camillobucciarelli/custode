# 002 — Navigation shell (model 1a)

**Status**: Hardened draft · **Kind**: Restyle foundation · **Depends on**: 001
**Design source**: `03 Vault - modelli di navigazione.dc.html` (option 1a),
`specs/_design/HANDOFF.md` (§Structure and navigation),
`specs/_design/PIXEL_SPEC.md` (§1).

## Why

Vault UI is one screen assembled from large `part` files and many dialogs. This
spec adds four first-class destinations and one typed presentation contract.
Content is moved, not redesigned; specs 004–006 style it later.

## Scope

**In**: Vault/Health/Sync/Settings destinations, mobile tab bar, adaptive rail
and vault columns, typed route/result handling, vault-only dialog migration,
cohesive part-file split, resize/back rules and placeholder roots.

**Out**: database-selection/unlock dialogs (003), destination redesigns
(004–006), privacy overlay (006), per-field conflict flow (008), deep links and
desktop shortcuts.

## Functional requirements

### FR-1 · Destinations and placeholders

Destinations are `Vault`, `Health`, `Sync`, `Settings`, with `folder`,
`shieldCheck`, `cloud`, `settings` Lucide glyphs. Shell widget state owns selected
destination; no new BLoC. Selection survives rebuild and resize, and starts at
Vault for every newly constructed/unlocked shell.

Vault renders current content. Until later specs replace roots, Health, Sync and
Settings each render a stable placeholder containing destination title,
destination icon, semantic heading and links/actions for migrated existing
sub-surfaces. Placeholder roots must be navigable, keyboard-focusable and golden
testable; they must not show an empty pane or throw an unimplemented error.

### FR-2 · Mobile shell (< 600 logical px)

Tab bar is 82 high including 10 top and 22 bottom-safe padding, `surface`
background, four equal items, icon 23, gap 3, label 10.5, active `linkText`,
inactive `textSecondary`. No indicator, elevation or border. Each item has a
44×44 minimum target and selected semantics.

Mobile presentation is selected by the exhaustive FR-6 switch: some surfaces use
`MaterialPageRoute`, others use a root-navigator modal sheet. There is no blanket
"mobile means route" rule. System/app back closes the active route or sheet with
a null typed result. At destination root, back preserves existing app-level
Navigator behaviour. Dirty-form discard policy remains owned by that form and
uses `confirm`, never implicit data loss.

### FR-3 · Rail and valid column widths (≥ 600)

Rail is 72 wide, or 76 in Vault, with mark 38/radius 13, 36 icon buttons, 14 gap
and Settings pinned bottom. Columns use 1 px `divider`, never shadows.

Vault layout uses minimum-width arithmetic rather than forcing impossible panes:

| Width/mode | Visible content |
| --- | --- |
| `< 600` | mobile body + tab bar |
| `600–707` | 76 rail + one content pane; list or selected detail, never both |
| `708–1023` | 76 rail + 330–352 list + 1 divider + remaining detail (min 300) |
| `≥ 1024` | 76 rail + 236 folder + 330–352 list + remaining detail (min 300) |

The 708 transition is derived from 76 rail + 1 divider + 330 list + 1 divider +
300 detail; it is not a new global `Breakpoints` token. At exactly 600 the rail
layout applies. At exactly 1024 the folder column appears. When only one content
pane fits, selecting an item replaces the list with detail and back returns to
the list.

Non-Vault placeholder destinations use rail + one flexible content pane and do
not reserve empty folder/list columns.

### FR-4 · Typed route and result contract

`vault_shell_router.dart` defines one library containing:

```dart
sealed class VaultRouteResult {
  const VaultRouteResult();
}

sealed class VaultSurface<R extends VaultRouteResult> {
  const VaultSurface();
}

final class VaultShellRouter {
  VaultShellRouter(/* concrete shell collaborators */);
}
```

Concrete method bodies expose these signatures: `Future<R?> open<R>(...)`,
`Future<ConfirmDecision?> confirm(...)`,
`void complete<R>(VaultOperationId, R)` and
`void cancel(VaultOperationId)`, with `R extends VaultRouteResult`.

`VaultShellRouter` is the single concrete production router, not an interface
with one implementation. BLoCs/widgets receive that concrete instance. Tests use
the same class with a widget harness, fake `VaultSurface` values, a test
`Navigator`, and injected function/state collaborators for route/sheet/pane
hosting and operation-ID generation; no `VaultShellRouterContract`, mock subclass
or second implementation is introduced.

Each `open`/`confirm` creates a never-reused `VaultOperationId` and a session-local
completer. Route/sheet/pane content receives that ID through
`VaultOperationScope`. Mobile pop, tablet pane close and explicit completion may
resolve only their captured ID, exactly once. Nested confirmation gets its own ID
and may not replace its parent session. `null` means cancel/back only; successful
values are never encoded as null, `dynamic`, raw maps or overloaded booleans.

Terminal handling first removes the matching session from the live map, then
completes its future, then clears surface/build callbacks, result and any
secret-bearing references in `finally`. Success, back, explicit cancel,
destination-change cancellation, route/sheet removal, build failure and router
dispose are all terminal paths. A completion for an absent/terminal ID is a
no-op; it can never fall through to the current/latest operation. Closing a
parent terminally cancels any child operation. Operation IDs and results are
never logged.

Current complex returns become public typed DTOs in this file before call sites
migrate:

| Current surface/result | Typed result |
| --- | --- |
| Entry editor `_EntryDialogPayload` | `EntryEditResult` with title, username, password, URL, notes, OTP URI, custom fields, attachments |
| Password generator `String` | `GeneratedPasswordResult` |
| QR scan `String` | `OtpScanResult` |
| Group create/rename `String` | `GroupEditResult` |
| Move target `String` | `MoveTargetResult` |
| Drive `_LinkDatabaseChoice` | sealed `DriveLinkResult.existing/newFile` |
| Sync conflict enum | `SyncConflictRouteResult` wrapping `SyncConflictResolution` |
| Confirmation booleans | `ConfirmDecision.confirm/cancel` |
| Void detail/attachments/recycle/duplicates | `VaultDone` when explicitly completed; null on back |

Typed DTOs containing secrets preserve current redacted `props`/`toString`
behaviour and are never logged by the router.

### FR-5 · Presentation, resize and result lifetime

- `presentationFor(surface, width)` is one exhaustive sealed switch returning
  `VaultRoutePresentation`, `VaultSheetPresentation` or
  `VaultPanePresentation`. FR-6 is authoritative; no caller chooses a widget or
  presentation kind.
- Route cases use `MaterialPageRoute`, allowing `AppTheme` to choose Zoom on
  Android, Cupertino on iOS/macOS and FadeUpwards on Linux/Windows. Do not use
  `AppNavigation.pushFade` or a custom `PageRouteBuilder`.
- Sheet cases use `showModalBottomSheet` on root navigator: bottom-aligned on
  mobile; width-constrained and centred at rail widths, 30% backdrop for
  confirmations.
- Pane cases select shell content and do not push a route.
- Presentation mode is latched for an active operation. A mobile-pushed route
  remains a route after window growth until it closes. A pane opened at desktop
  remains shell-owned after shrink and renders as the one full-width content pane
  with an app-back affordance. Draft state and pending future are not remounted or
  completed by resize. The next `open` uses current width.
- Destination change cancels any open sub-surface only after its existing discard
  confirmation accepts; otherwise destination remains unchanged.

### FR-6 · Authoritative dispatch mapping

| Surface family | Mobile `<600` | Rail `≥600` |
| --- | --- | --- |
| Entry detail/editor | route | pane |
| OTP QR scanner | route | pane |
| Password generator | sheet | pane |
| Group create/rename | sheet | pane |
| Move target | sheet | pane |
| Attachments | route | pane |
| Recycle bin | route under Vault | pane |
| Duplicates/merge preview | route under Health | pane |
| Sync link/remote picker | route under Sync | pane |
| Sync conflict | sheet | pane; 008 replaces later |
| Database settings/CSV import | route under Settings | pane |
| Key-file manager | sheet | sheet |
| Confirmations | sheet | sheet over root window |

No dialog may stack on another dialog. A confirmation from any pane covers the
whole window.

### FR-7 · Current 19-surface migration matrix

Before the `showDialog` sweep, one named parameterized test case exists for every
current call below. Each case asserts sealed presentation kind at 390 and 1024,
typed result/null semantics, preserved title/body/action copy from the T1 fixture,
and listed event/callback when applicable.

| # | Current function / copy anchor | Mobile / rail | Typed result | Existing effect to preserve |
| --- | --- | --- | --- | --- |
| 01 | `_showPasswordGeneratorDialog` / password-generator title/actions | sheet / pane | `GeneratedPasswordResult?` | feeds editor; no BLoC event |
| 02 | `_showEntryDialog` / Create-or-edit record copy | route / pane | `EntryEditResult?` | `CreateVaultEntry` or `UpdateVaultEntry` |
| 03 | `_scanOtpUriFromQr` / `Scan OTP QR` | route / pane | `OtpScanResult?` | feeds editor; no BLoC event |
| 04 | `_showGroupDialog` / create/rename folder copy | sheet / pane | `GroupEditResult?` | `CreateVaultGroup` or `RenameVaultGroup` |
| 05 | `_showDeleteConfirm` / `Confirm delete` | sheet / sheet | `ConfirmDecision?` | caller's existing `DeleteVaultEntry`, `DeleteVaultGroup`, `DeleteVaultEntryPermanently`, `DeleteVaultGroupPermanently`, `DeleteDuplicateEntry`, `EmptyRecycleBin` or `RemoveVaultAttachment` |
| 06 | `_showMoveTargetDialog` / `Move to folder` | sheet / pane | `MoveTargetResult?` | `MoveVaultEntry` or `MoveVaultGroup` |
| 07 | `_showAttachmentsDialog` / `Attachments` (retired 2026-11-13: the detail lists and exports attachments, the editor adds and removes them with the save) | route / pane | `VaultDone?` | `ExportVaultAttachment` / `RemoveVaultAttachment` |
| 08 | `_showLinkDatabaseDialog` / `Link database to Drive` | route / pane | `DriveLinkResult?` | `LoadDriveRemoteFiles`; then `LinkCurrentDatabaseToDrive` |
| 09 | `_showSyncConflictDialog` / `Sync conflict detected` | sheet / pane | `SyncConflictRouteResult?` | `ClearVaultSyncFeedback`; accepted choice dispatches `SyncCurrentDatabaseNow` |
| 10 | `_showDuplicatesDialog` / `Manage duplicates` | route / pane | `VaultDone?` | `LoadDuplicates` |
| 11 | `_showMergeReviewDialog` / review/compare copy | route / pane | `ConfirmDecision?` | accepted merge dispatches `MergeDuplicateEntries` |
| 12 | `_showRecordMetadataDialog` / `Record info` | route / pane | `VaultDone?` | read-only; no BLoC event |
| 13 | outer `_showDatabaseSettings` / database settings title | route / pane | `DatabaseSettingsResult?` | existing `VaultSessionCoordinator` apply workflow |
| 14 | inner security confirmation / `Confirm security changes` | sheet / sheet | `ConfirmDecision?` | gates same settings coordinator workflow |
| 15 | `_showRecycleBinDialog` / recycle-bin title | route / pane | `VaultDone?` | `LoadRecycleBinEntries`; existing restore/delete/empty events remain |
| 16 | `_startCsvImportFlow` / `Import CSV` | route / pane | `CsvImportResult?` | `ImportVaultEntriesFromCsv` |
| 17 | `_handleOtpAuthEvent` / `Add OTP account?` | sheet / sheet | `ConfirmDecision?` | accepted review continues to `CreateVaultEntry` |
| 18 | `_closeCurrentDatabaseAndSelectAnother` / `Close database` | sheet / sheet | `ConfirmDecision?` | `VaultSessionCoordinator.changeDatabase` then existing navigation |
| 19 | `_showAppleAutofillAssociationDialog` / `Link AutoFill credential?` | sheet / sheet | `ConfirmDecision?` | `ConfirmAppleAutofillPendingAssociation` or `RejectAppleAutofillPendingAssociation` |

No matrix row may be merged away merely because two rows share a result type.

### FR-8 · Cohesive file restructuring

`vault_screen.dart` remains assembler. Split existing files only where moved code
has a destination owner:

- settings/database settings/master-password code from
  `vault_navigation.part.dart` → `vault_settings.part.dart`;
- Drive/sync code from `vault_dialogs.part.dart` → `vault_sync.part.dart`;
- confirmation builders from `vault_dialogs.part.dart` →
  `vault_confirmations.part.dart`;
- shared helpers with callers in multiple destination parts stay in
  `vault_navigation_support.part.dart`.

No arbitrary byte-size gate. Do not split cohesive code solely to reach a number.

## Exact golden inventory — 4 files

| File | Surface | Theme |
| --- | --- | --- |
| `vault_shell_390x844_light.png` | Vault mobile shell | light |
| `vault_shell_390x844_dark.png` | Vault mobile shell | dark |
| `vault_shell_1024x768_light.png` | Vault four-column shell | light |
| `vault_shell_1024x768_dark.png` | Vault four-column shell | dark |

Placeholder roots and breakpoint boundaries are widget-tested, not extra
goldens, because their composition is intentionally temporary.

## Acceptance criteria

1. Four named shell goldens match with spec-001 deterministic harness.
2. Geometry tests cover widths 599, 600, 707, 708, 1023 and 1024; no overflow
   exception occurs and visible panes match FR-3.
3. Typed tests cover success, app/system back, explicit cancel and exactly-once
   completion for every result class in FR-4, plus stale IDs, nested operations,
   every terminal path and secret-reference cleanup.
4. Mobile entry detail pushes; tablet entry detail leaves
   `Navigator.canPop == false`. Resize follows FR-5 without completing result or
   losing draft state.
5. Confirmation from a pane covers root window and returns `ConfirmDecision`.
6. Health/Sync/Settings placeholders are reachable at mobile and rail widths.
7. Named 19-row FR-7 migration matrix passes before the sweep; count is asserted
   as exactly 19 and each row verifies presentation, result, copy and effect.
8. Vault-only sweep
   `rg -n 'showDialog(?:<[^>]+>)?\s*\(' lib/features/password_manager/presentation/screens/vault --glob '*.dart'`
   is empty. 003 owns database-selection/unlock/widget dialog removal.
9. Extracted parts compile and preserve existing behaviour/copy; no file-size
   threshold is asserted.

## Open product assumptions

- Browser back/deep-link history for destination tabs remains out of scope. Tabs
  are shell state, not URL routes.
- Live resize deliberately latches active presentation mode to preserve drafts.
  Cross-mode morphing can be added only with a tested state-restoration contract.
