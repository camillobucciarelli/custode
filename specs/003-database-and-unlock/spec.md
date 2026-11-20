# 003 — Database selection & unlock (journeys 01–02)

**Status**: Hardened draft · **Kind**: Restyle · **Depends on**: 001, 002
**Design source**: `01-02 Database & Unlock.dc.html`,
`specs/_design/PIXEL_SPEC.md` §4, `specs/_design/HANDOFF.md` §Screens `01-02`.

## Why

Database selection and unlock sit outside the vault shell. Current selection
state exposes only paths; current unlock collapses missing files, corrupt KDBX
data, missing key files and invalid credentials into strings. Restyling safely
requires typed metadata/failures and explicit workflow ownership first.

## Scope

**In**: welcome/recent/create/Drive/invalid/duplicate selection states; unlock,
biometric, key-file and decrypting states; typed metadata/errors; minimal BLoC
and coordinator changes needed by those states; exact copy and golden contracts.

**Out**: vault-shell destinations, CSV import, dedup algorithm changes, KDBX
format changes, fake decrypt percentages, persisted decrypted item counts.

## Required contracts

### C-1 · Selection metadata

Replace `List<String> recentDatabasePaths` in coordinator results and
`DatabaseSelectionState` with `List<DatabaseSelectionItem>`:

```dart
class DatabaseSelectionItem {
  final String databaseId;
  final String canonicalPath;
  final String displayName;
  final DatabaseSourceType sourceType;
  final String? sourceRef;
  final bool isActive;
  final bool isMissing;
  final bool biometricProtectionEnabled;
  final bool keyFileConfigured;
  final DateTime? lastOpenedAt;
  final DateTime? lastSyncAt;
  final String? lastSyncError;
}
```

`DatabaseSessionCoordinator` builds each item through domain use cases/repository
ports from `DatabaseRecord`, `DatabaseSecurityProfile`, `DatabaseSyncMapping` and
file existence. It never imports `data/` or concrete data services. The BLoC
never reads repositories directly. `canonicalPath` remains available to overflow
actions and semantics but is not rendered as subtitle.

Item count is intentionally absent: reading it before unlock would require
decrypting the vault or persisting new decrypted metadata. Local subtitle is
`On this device · biometrics on/off`; Drive subtitle is
`Google Drive · synced <relative time>` or existing error status. Add item count
only under a later security-reviewed metadata spec.

### C-2 · Drive picker/account

Coordinator returns one `DrivePickerData` containing `List<DriveRemoteFile>` and
`DriveAccountSummary { displayLabel, email? }`. Add
`DatabaseSyncRepository.getConnectedAccount()`; implementation obtains mobile
email from current `GoogleSignInAccount`. Existing desktop Drive-only OAuth does
not guarantee identity. Without expanding OAuth scopes, desktop returns
`displayLabel: 'Google Drive account'`, `email: null`; UI names an available email
and otherwise uses that exact fallback. Empty state still offers create+upload
and switch account.

### C-3 · Typed file/unlock failures

Add sealed `DatabaseAccessFailure` values and map at service/use-case boundaries:

| Failure | Source mapping | UI |
| --- | --- | --- |
| `DatabaseFileMissingFailure` | database path absent | recent missing/Locate or unlock field error |
| `InvalidDatabaseFileFailure` | selection lacks valid KDBX structure/unsupported file | invalid-file sheet naming file |
| `CorruptDatabaseFailure` | `KdbxCorruptedFileException` / `KdbxInvalidFileStructure` after valid selection | corrupt-file sheet/error; never call it wrong password |
| `KeyFileMissingFailure` | configured/selected key path absent | explicit key-file message and manager action |
| `InvalidCredentialsFailure` | `KdbxInvalidKeyException` | existing generic credential message under field |

Raw package exceptions and file paths are not rendered via `e.toString()` and
are not logged with secret values. `DatabaseSelectionBloc` and
`DatabaseUnlockBloc` may add typed state fields/events required to expose these
failures; multi-step decisions remain in `DatabaseSessionCoordinator`.

### C-4 · Unlock phase and progress

`DatabaseUnlockState` gains `UnlockPhase { initializing, biometricGate, ready,
decrypting, unlocked, failure }`, `DatabaseAccessFailure? failure` and
`double? progress`. `isLoading` is replaced by phase-derived getters.

- Enter `decrypting` immediately before awaiting KDBX read; disable submit,
  credential edits and back to prevent duplicate operations.
- `progress == null` means indeterminate. Current `kdbx` API exposes no Argon2
  progress callback, so 003 always renders an indeterminate indicator and no
  percentage/ETA. A value is legal only in `[0,1]` and only from real backend
  callbacks added later.
- KDBX read is not cancellable; UI must not promise cancellation.
- Reduced motion freezes indicator to a static accessible busy state.

### C-5 · Create-flow ownership

`DatabaseSessionCoordinator` remains owner of step transition policy, key-file
preparation, KDBX creation, registry/security writes and rollback. BLoC events
request next/back/submit and emit non-secret `CreateDatabaseStep` state. Screen
owns ephemeral `TextEditingController`s, including password; password never
enters BLoC state or coordinator fields. Advance requests pass validation facts
(non-empty, confirmation matches, strength category), not plaintext. Final
`CreateNewDatabase` event carries password transiently with existing redacted
props and calls coordinator once.

Cancel/back before submit discards only ephemeral draft. Submit failure leaves
step/draft visible and does not leave a partial `.kdbx`; coordinator rollback
rules remain authoritative.

### C-6 · Typed screen/sheet results outside vault

Create screen is pushed as `MaterialPageRoute<CreateDatabaseCredentials>` and
returns the existing typed payload or null. Selection/unlock sheets use generic
`KvBottomSheet.show<T>` extracted from 002 confirmation styling on this second
real use. They do not use `VaultShellRouter`: these screens are outside vault.
`InternalKeyFileManagerResult` remains typed and byte-for-byte equivalent.

### C-7 · Coordinator architecture boundary

`database_session_coordinator.dart` imports only core-safe value utilities,
domain entities/models/errors, domain repository interfaces/use cases and
presentation coordinator contracts. Shared operation enums currently declared in
BLoC event files move to domain models before coordinator use. It
must not import `data/`, `MobileFileStorage`, `FilePicker`, Flutter platform
flags, `dart:io`, `crypto` or `kdbx`.

`DatabaseSessionCoordinator` becomes one concrete final coordinator; the existing
single-implementation `DatabaseSessionCoordinatorContract` is removed. BLoCs use
the concrete coordinator, while tests control behaviour through fake domain
ports/use cases. Domain ports remain valid under constitution VIII because they
enforce the data trust boundary.

Existing direct dependencies move behind minimum domain ports/use cases:

- `DatabaseFileRepository`: stage/open/commit/rollback/discard/imported-file
  operations, managed-file existence/list/delete/hash and key-file persistence;
  existing `DatabaseImportService` implements this port in data.
- `DatabaseSessionRepository`: cached active/key path and stored master-password
  operations; data implementation composes existing local/secure data sources.
- `CreateDatabaseUseCase`: KDBX/key generation and partial-output rollback using
  those ports.

The coordinator sequences these operations; repositories/use cases perform I/O.
No UI or BLoC imports data to compensate.

Architecture enforcement is executable, not grep-only. Named test
`database_session_coordinator_imports_test.dart` parses the coordinator with the
Dart analyzer and inspects every `ImportDirective` URI. It resolves relative and
`package:password_manager/...` forms to project paths and fails when any URI:

- contains a path segment exactly equal to `data`;
- is `dart:io`;
- imports Flutter or a picker, crypto, KDBX or platform package;
- resolves to `mobile_file_storage.dart`, another platform utility, or any
  internal path outside `lib/features/password_manager/domain/` and
  `lib/features/password_manager/presentation/coordinators/`. Core imports use an
  exact `approvedCoreUris` set, initially empty, rather than a broad prefix.

External package imports use an explicit allowlist (`loggy`, `path`); Dart SDK
imports use an explicit non-platform allowlist (`dart:async`, `dart:math`,
`dart:typed_data`). Any new import requires test review. The test prints rejected
raw and resolved URIs.

## Screens and behaviour

### FR-1 · Welcome / recent databases

Welcome: mark 88/radius 26; `heroHeadline` 38; three stacked primary pills gap
10; centred block and bottom padding 34.

Recent header: mark 40/radius 14, title 26, add 40 circle. Rows: radius 24,
padding 14, leading 40/radius 14, metadata subtitle from C-1, active accent tint,
overflow Open/Export/Remove with existing event semantics. Path remains in
semantics/overflow, not subtitle. Tablet ≥600 uses identity/actions left and
cards right.

Missing rows use adopted proposal `Locate`. Locate is allowed only for
`isMissing` items. Coordinator validates selected `.kdbx` and compares its hash
with stored `fileHash` when present. Match updates registry canonical path and
sync mapping atomically, retains database ID/security profile, then continues to
unlock. Mismatch or invalid/corrupt selection leaves record/mapping unchanged and
instructs user to use normal Open flow instead. Locate never silently rebinds
metadata to different vault content.

### FR-2 · Create database

Three steps: name/storage note; master password/confirm/strength; optional key
file, Face ID and auto-lock. Header uses back 40 + private three-step bars;
footer uses shared pill only after its second real use in this spec. Field labels
and validation copy remain current. Desktop removes explanatory paragraphs but
does not delete/change their source strings.

### FR-3 · Drive picker and invalid file

Loading uses row-shaped skeletons, not spinner. Empty state uses C-2 account
label and offers create+upload/switch account. Invalid and corrupt sheets name
only basename, never full path. CSV import is absent because it requires an open
vault.

### FR-4 · Duplicate behaviour

Sheet returns existing `DatabaseDuplicateResolution` values:

- **Keep both**: commit staged import to unique path/new record; existing file and
  metadata unchanged.
- **Replace existing**: create dated local backup before replacement; preserve
  existing database ID/security/sync metadata; rollback backup on failure.
- **Use existing**: discard staged bytes and open existing record unchanged.
- **Cancel/null/back**: discard staged bytes and mutate nothing.

Only coordinator executes those branches. Sheet dispatches one
`ResolveDuplicateDecision`; no direct repository/file access.

### FR-5 · Unlock

Feature square 66/radius 24; title 32; password field 56; primary pill; inline
links separated by 1×14 divider. Key-file-selected state marks password optional.
Biometric gate is dark full screen with 104 circle/50 glyph. Desktop card is
centred, max width 600, with no step counter or explanatory paragraphs. Entry
animation is 280 ms scale 0.98→1 + fade and honours reduced motion.

Decrypting renders `Decrypting <basename>` and
`Deriving your encryption key with Argon2. This can take a moment.` with C-4
indeterminate semantics. Post-Drive prompt uses `Use Face ID for <basename>?`.

## Copy preservation contract

Before edits, snapshot literals from `database_selection_screen.dart`,
`create_database_dialog.dart`, `database_unlock_screen.dart`,
`database_unlock_widgets.part.dart`, `internal_key_file_manager_dialog.dart`,
`recent_databases_section.dart`, `database_item_tile.dart` and
`database_action_menu.dart`. Existing strings remain byte-identical
even when moved or conditionally hidden. Only these additions/changes are
approved:

- `Your vault, in a file you own.`
- metadata subtitles defined in C-1 and Drive-account fallback in C-2;
- `Locate` and locate mismatch guidance;
- `Step 1 of 3`, `Step 2 of 3`, `Step 3 of 3`, `Custode app storage`;
- duplicate consequence lines:
  `Save this file as another database.`,
  `Back up, then replace the existing file.`,
  `Discard this import and open the existing database.`;
- `Unlock with key file`;
- `Key file not found. Locate or select the required key file.`;
- decrypting and Face ID strings in FR-5;
- basename-only invalid/corrupt sheet titles required by C-3.
- reconnect guidance supersedes
  `Google Drive session expired or unavailable. Tap "Open from Google Drive" again and complete reconnection.`
  with
  `Google Drive session expired or unavailable. Use Reconnect below to sign in again.`;
  the Drive surface remains open and exposes a `Reconnect` CTA, so instructing
  the user to open it again is stale and contradicts the inline recovery flow.

No other copy rewrite is in scope.

Widget disposition is fixed before edits: `RecentDatabasesSection` is reused and
changed to accept `DatabaseSelectionItem`; `DatabaseItemTile` is reused as the
metadata/missing row; `DatabaseActionMenu` is reused with conditional `Locate`.
None of these three files is removed or replaced by a parallel `DatabaseRow`
implementation. Obsolete path-only parameters are removed after all callers
compile.

## Exact golden inventory — 22 files

| File | State |
| --- | --- |
| `db_welcome_390x844_light.png` | welcome light |
| `db_welcome_390x844_dark.png` | welcome dark |
| `db_recent_390x844_light.png` | recent mobile light |
| `db_recent_390x844_dark.png` | recent mobile dark |
| `db_recent_1024x768_light.png` | recent tablet light |
| `db_recent_1024x768_dark.png` | recent tablet dark |
| `db_create_step1_390x844_light.png` | create name |
| `db_create_step2_390x844_light.png` | create password |
| `db_create_step3_390x844_light.png` | create locks |
| `db_drive_loading_390x844_light.png` | skeleton |
| `db_drive_empty_390x844_light.png` | account empty state |
| `db_invalid_file_390x844_light.png` | invalid sheet |
| `db_duplicate_390x844_light.png` | duplicate sheet |
| `unlock_password_390x844_light.png` | password default light |
| `unlock_password_390x844_dark.png` | password default dark |
| `unlock_password_1024x768_light.png` | desktop card |
| `unlock_biometric_gate_390x844_dark.png` | biometric gate |
| `unlock_wrong_password_390x844_light.png` | invalid credentials |
| `unlock_key_selected_390x844_light.png` | key selected |
| `unlock_key_manager_390x844_light.png` | key manager sheet |
| `unlock_decrypting_390x844_light.png` | indeterminate decrypting |
| `unlock_face_id_prompt_390x844_light.png` | post-Drive prompt |

Omitted size/theme axes have these mandatory widget tests:

- **Dark roles**: pump welcome, recent, all create steps, Drive loading/empty,
  invalid/corrupt/duplicate sheets, unlock ready/wrong-password/missing-key/key-selected/
  decrypting, key manager and Face ID prompt under dark `AppTheme`; assert each
  text/fill resolves to its declared `CustodeColors` role and every used
  text/background pair is in spec-001 contrast matrix.
- **Tablet/card widths**: at 599 selection is single-column; at 600 and 1024 it is
  two-column without overflow. At 1024 unlock card width is ≤600 and centred.
- **Error placement**: invalid credentials and missing-key messages are
  descendants of the credential field group, not snackbars; missing/corrupt
  database errors occupy their specified sheet/surface.
- **Sheet geometry**: invalid, corrupt, duplicate, key-manager and Face ID sheets
  use root navigator, radius-32 top corners, documented backdrop and width
  constraints in light and dark.

Temporary state permutations do not multiply goldens beyond 22.

## Acceptance criteria

1. All 22 named goldens match using spec-001 deterministic harness.
2. Selection state exposes C-1 metadata; no UI repository access and no pre-unlock
   item-count read/persistence.
3. Drive loading/empty state carries C-2 account summary and fallback.
4. Typed tests map missing database, invalid selection, corrupt KDBX, missing key
   file and invalid credentials to distinct C-3 states/copy.
5. Decrypting is entered before KDBX await, is indeterminate, blocks duplicate
   submit/back and shows no fake percentage.
6. Create step policy is coordinator-owned; BLoC state contains no password and
   named coordinator-import architecture test proves C-7 for every parsed URI.
7. Locate and all four duplicate outcomes satisfy file/hash/backup/rollback rules
   with coordinator tests.
8. Existing copy snapshot differs only by approved list above.
9. Database surfaces use no dialog:
   `rg -n 'showDialog(?:<[^>]+>)?\s*\(' lib/features/password_manager/presentation/screens/database_selection_screen.dart lib/features/password_manager/presentation/screens/database_unlock_screen.dart lib/features/password_manager/presentation/screens/create_database_screen.dart lib/features/password_manager/presentation/widgets/internal_key_file_manager_sheet.dart`
   is empty.
10. Open/Export/Remove and duplicate actions still dispatch typed existing/new
    BLoC events; tap targets are ≥44; desktop card is ≤600.
11. All four omitted-axis widget-test groups under the golden inventory pass in
    both themes where stated.

## Open product assumptions

- Desktop OAuth identity scope expansion is not approved in this spec. Generic
  `Google Drive account` fallback is required until product/security approve
  `openid email` and migration of stored desktop credentials.
- No item-count metadata is shown before unlock. Product may request a separate,
  security-reviewed persisted count later.
