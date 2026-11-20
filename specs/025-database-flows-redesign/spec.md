# 025 — Database flows redesign

**Status**: Implemented, unmerged (slices S1 to S4 and the tester findings of D10 to D15); S5 validation and manual QA pending · **Kind**: UX redesign / cleanup
**Depends on**: 001, 002, 011, 014, 015
**Coordinates with**: 010 (provider-neutral port), 013 (Google Picker replaces the in-app Drive list)
**Supersedes**: parts of 003 and 015 (see "What this supersedes")
**Design source**: approved static mockups `Main`, `Source`, `DriveFiles`,
`Conflict`, `CreateName`, `CreateCredentials`, `Unlock`, `UnlockKeyFile`,
`UnlockMissing`, `BiometricOffer`, `Databases`, `AddSheet` (`*.dc.html`, canvas
"Custode · Flussi database"). One correction to the mockups: the Source sheet
("Where is your database?") belongs to the Open path only. Create goes straight
to the wizard and chooses the source in step 1.

## Summary

Rebuild every flow that happens before the vault opens (welcome, add/open,
Google Drive, create, unlock, databases list) around one data hierarchy that is
the same on every screen: **source/account, then database file, then
credentials**. Three entry actions become two (Create, Open). One conflict sheet
replaces the name-collision dialog and the duplicate sheet. One biometric offer
replaces three inconsistent ones. Creation enters the vault directly. Every
platform runs the same flow and the same widget tree; a missing capability is a
disabled option decided in one place. All code, tests and goldens the old flows
needed are deleted.

## Problem and current state

Verified against `origin/main` at `90a91aa`:

- **Three entry actions, three add surfaces.** `WelcomeScreen` has three pills;
  `DatabaseSelectionScreen._AddSection` repeats them as rows;
  `widgets/database/database_action_tile.dart` is a third variant with no
  caller (dead code).
- **Drive rows are hand-rolled twice.** `widgets/database/drive_picker_sheet.dart`
  draws its own rows while the vault link picker
  (`screens/vault/vault_sync.part.dart`, `_RemoteFilePickerScreen`) uses
  `widgets/sync/remote_file_row.dart`.
- **"Switch account" is fake.** `database_selection_screen.dart:62-73` shows a
  snackbar. `DatabaseSyncRepository.disconnect()` is only reachable through
  `VaultBloc` (`DisconnectGoogleDrive`).
- **"Create & upload" is fake.** `DrivePickerSheetResult.createAndUpload` just
  opens the local create wizard (`database_selection_screen.dart:75-78`).
- **Two overwrite checks, two sources of truth.** Local open asks
  `MobileFileStorage.fileExistsInAppDirectory` (`:221`), Drive open asks
  `coordinator.hasManagedDatabaseNamed` (`:87`). Since spec 014 on-disk names
  are opaque, so only the registry answer is meaningful.
- **A dismissed duplicate sheet leaks the staged import.**
  `_handleDuplicateDecisionPrompt` returns on `decision == null` without
  dispatching anything, contradicting 003 FR-4 "Cancel/null/back: discard".
- **The create wizard is off the design system.** Stock `TextFormField` +
  `InputDecoration`, `RadioListTile`, `SwitchListTile.adaptive` and legacy
  `AppIcons` instead of `kvFieldDecoration`, `KvSwitch`, `KvIcon(AppGlyph)`.
- **Retyping the password after create.** `createNewDatabase` already seeds
  `SessionSecretHolder` with the password, then the UI routes to the unlock
  screen anyway.
- **Key-file picking differs three ways**: create (`FilePicker` directly),
  unlock (`authorizeManagedKeyPickerAccess` + `internal_key_file_manager_sheet`),
  settings (`internal_key_file_manager_dialog`).
- **Biometric offer is inconsistent.** Create has a switch; a Drive import shows
  a pre-unlock dialog (`biometric_prompt_sheet.dart`, wired through
  `promptBiometricSetup`) that cannot store the credential because nothing is
  unlocked yet (`updateBiometricProtection` writes nothing on enable); a local
  import is never offered at all.
- **Selection actions blank the screen.** Every event emits
  `DatabaseSelectionLoading` and the builder returns a bare
  `CircularProgressIndicator`.
- **Missing file is a dead end on unlock.** `DatabaseFileMissingFailure` maps to
  `UnlockPhase.failure` with only "Back to database list".
- **Capability checks are scattered.** `kIsWeb` is read in the selection,
  create, unlock screens and the unlock part file, plus the
  `debugWebMode` test override on `CreateDatabaseScreen`.
- `docs/database_flows_refactor.md` is an older partial plan. Its still-valid
  ideas (single import pipeline, source picker sheet, conflict resolver with
  replace/keep both/cancel, reusable unlock panel) are absorbed here; the file
  is deleted in S4.

## Goals

1. One hierarchy on every screen: source/account, database file, credentials.
2. Two entry actions: **Create new database**, **Open a database**.
3. One conflict sheet, one biometric offer, one key-file picker, one remote file
   list, one source option widget.
4. Create really creates on Google Drive when asked, and opens the vault
   directly.
5. Unlock shows every error inline and can recover a missing file.
6. Identical flow and widget tree on every platform.
7. No superseded code, test or golden left behind.

## Non-goals

- No change to the KDBX format, safe writer, `DatabasePathMutex`, checksum,
  conflict, convergence, mapping or timeout semantics.
- No weakening of spec 011: keystore writes stay gated by
  `biometricProtectionEnabled` per database id.
- No Google Picker, no OAuth scope change (spec 013 owns both).
- No provider registry, provider picker or second provider (spec 010/012).
- No new BLoC, no new top-level feature, no pass-through use case.
- No redesign of the biometric gate or the decrypting view (see FR-U7).
- No localisation; copy stays English.

## User stories

### US1 — Unlock (slice S1)

As a user reopening a database I see where it lives, its name, the password
field and the key-file slot in that order, I get every error next to the field
it concerns, and if the file went missing I can fix it without leaving the
screen. After my first successful unlock I am asked once whether to use
biometrics, whatever the source.

### US2 — Open (slice S2)

As a user with an existing `.kdbx` I tap **Open a database**, choose where it is
(this device or Google Drive, with the connected account visible and really
switchable), pick the file, resolve at most one conflict question, and land on
Unlock.

### US3 — Create (slice S3)

As a new user I tap **Create new database**, choose where it lives and its name,
protect it, and I am in the vault. Choosing Google Drive creates the file on
Drive. I never retype the password I just chose.

### US4 — Databases list (slice S4)

As a user with several databases I see them grouped by source and account, with
their credentials and sync state at a glance, one "+" to add another, and a
missing file is a row I can repair in place.

## Functional requirements

### Cross-cutting

**FR-X1 — Hierarchy.** Every surface orders its content source/account, then
database, then credentials. The source is rendered by one widget, `SourceChip`
(icon + label), fed by one label function
`databaseSourceLabel({required bool remote, StorageAccountSummary? account})`
returning `This device`, `Google Drive · <email>` or `Google Drive`.

**FR-X2 — One capability decision point.** Platform capability is read only
through getters added to the existing
`presentation/utils/platform_utils.dart`:

| Getter | Today's truth | Used by |
| --- | --- | --- |
| `supportsRemoteSource` | `!kIsWeb` | Source sheet, create step 1, Drive actions |
| `supportsBiometricUnlock` | `!kIsWeb` (device availability still comes from `BiometricDataSource.isBiometricAvailable()`) | create switch, unlock link, offer |
| `persistsDatabases` | `!kIsWeb` | create step 2 outcome (vault vs download) |
| `isManagedStoragePlatform` | existing, `!kIsWeb` (mobile **and** desktop are managed since spec 014) | key-file picker |

One `@visibleForTesting` override (`debugPlatformCapabilities`) replaces
`CreateDatabaseScreen.debugWebMode`. After S4, `kIsWeb` appears in none of
`welcome_screen.dart`, `database_selection_screen.dart`,
`create_database_screen.dart`, `database_unlock_screen.dart`,
`database_unlock_widgets.part.dart` or the new widgets. This is plain getters in
an existing file: no capability abstraction, no registry (architecture skill,
"forbidden patterns"). The one type that exists, `PlatformCapabilities`, is the
value the test override takes (three `bool`s, no behaviour, no subclass, no
production constructor call); production code reads the getters and never the
type.

**FR-X3 — One widget tree.** A capability that is absent never removes or swaps
a widget. The option stays in place, disabled, with a one-line reason as its
subtitle (copy contract). Managed versus bytes-only key-file storage is hidden
inside `pickKeyFile` (FR-X5); callers do not branch.

**FR-X4 — Provider neutrality.** Presentation and coordinators keep importing
only domain types (`RemoteFile`, `StorageAccountSummary`,
`RemoteFileSelectionData`, `CloudStorageErrorCode`). The literal `Google Drive`
is display copy produced by `databaseSourceLabel`; grouping and linking are
keyed by the mapping's `providerId`, never by label or by
`DatabaseSourceType.drive` alone (a vault linked later from Sync is also remote).

**FR-X5 — One key-file picker.** `pickKeyFile(context, {String? current})` in
`presentation/widgets/key_file_picker.dart` is the only entry point for choosing
a key file. On managed platforms it runs `authorizeManagedKeyPickerAccess`
(spec 015 FR-12, unchanged) then `showInternalKeyFileManagerSheet`; on web it
reads bytes with `FilePicker.pickFiles(withData: true)`. One row widget,
`KeyFileRow`, renders the empty slot and the selected state for create, unlock
and settings.

**FR-X6 — Labelled, non-destructive busy state.** `DatabaseSelectionLoading`
carries an optional `label`. The screen keeps its current content mounted and
shows `KvSpinner` with that label over it; the bare full-screen
`CircularProgressIndicator` remains only for the very first load
(`DatabaseSelectionInitial`).

**FR-X7 — Architecture.** `DatabaseSelectionBloc`, `DatabaseUnlockBloc` stay
event/state translation. New sequencing (switch account, create on remote,
re-download, immediate biometric store) lives in `DatabaseSessionCoordinator`.
`database_session_coordinator_imports_test.dart` (003 C-7) keeps passing
unchanged. No new use case unless it carries policy; the conflict detection
extension lives in the existing `ResolveDatabaseDuplicateUseCase`.

### Open path (S2)

**FR-O1 — Entry.** Welcome and the Add sheet expose **Open a database**, which
opens the Source sheet.

**FR-O2 — Source sheet.** Two `SourceOptionCard`s: `This device` (opens the
system file picker for `.kdbx`) and `Google Drive`. The Drive card shows
`Not connected` with a trailing `Connect` action, or the connected account label
with a chevron. With `supportsRemoteSource == false` the Drive card is disabled
with its reason. Footer: the privacy line from the copy contract.

**FR-O3 — Remote file list behind one seam.** Choosing Drive calls
`Future<RemoteFile?> pickRemoteFile(BuildContext context)` in
`presentation/widgets/sync/remote_file_picker.dart`. It is the **only** symbol
the open flow knows about; spec 013 later swaps its body for the Google Picker
without touching callers. Its current body shows the account header (label,
email when the provider asserts one, real `Switch account`), search, one
`RemoteFileRow` per file with modified date and size, an `Already added` tag on
files whose `(providerId, id)` matches an existing mapping, skeleton loading,
empty state and the existing reconnect/retry error surface. The list body is a
shared widget, `RemoteFileList`, also used by the vault link picker, so the
hand-rolled rows in `drive_picker_sheet.dart` are deleted.

**FR-O4 — Real switch account.**
`DatabaseSessionCoordinator.switchRemoteAccount()` calls
`databaseSyncRepository.disconnect()` then `connect()` and reloads
`RemoteFileSelectionData`. A cancelled sign-in leaves the surface in the
not-connected state with the existing typed error copy. Existing mappings are
not modified; a vault linked under the previous account surfaces the existing
reconnect-required state at its next sync.

**FR-O5 — No "Create & upload".** The empty state offers `Switch account` only.
`DrivePickerSheetResult.createAndUpload` and its call site are deleted.

**FR-O6 — Single conflict detection.** `ResolveDatabaseDuplicateUseCase` gains a
`displayName` input and `DatabaseDuplicateMatchType.name`. Precedence: source,
then hash, then name. A source match is either the registry's
`(sourceType, sourceRef)` or, for an incoming remote file, a sync mapping whose
`(providerId, remoteFileId)` is that file (D12): a database linked from Sync
keeps a local `sourceType`, so only its mapping knows. That lookup is
`DatabaseSyncMapping.pointsAt` over `getAllMappings()`, the same one behind the
picker's `Already added` tag. The registry is the only source of truth for
names;
`MobileFileStorage.fileExistsInAppDirectory`, `hasManagedDatabaseNamed`,
`_showOverwriteDatabaseSheet` and every `overwriteExisting` parameter
(`SelectExistingDatabase`, `SelectDriveDatabase`, coordinator methods) are
deleted. The overwrite branch of `_commitStagedImport` that resolved a target by
display name is replaced by the `replaceExisting` decision on the matched
record.

**FR-O7 — One conflict sheet.** `showDatabaseConflictSheet` replaces
`showDuplicateDatabaseSheet` and the overwrite confirm dialog. It names the
importing file and the existing one, each with its source, and offers:

| Option | `DatabaseDuplicateResolution` | Effect (unchanged from 003 FR-4) |
| --- | --- | --- |
| Open the existing one | `useExisting` | discard staged bytes, open existing record |
| Keep both | `keepBoth` | commit to a new record; existing untouched |
| Replace existing | `replaceExisting` | dated backup first, keep database id/security/sync metadata, rollback on failure |
| Cancel | `cancel` | discard staged bytes, mutate nothing |

`Recommended` is shown on "Open the existing one" for a source or hash match
only; a name-only match shows no recommendation. `Replace existing` is not
offered for a name-only match on a database that has a sync mapping (D11); the
coordinator decides (`DatabaseDuplicatePrompt.canReplaceExisting`) and treats a
replace it did not allow as `cancel`. **Dismissal by any means
(barrier tap, back, drag) is `cancel`**: the sheet's `null` result dispatches
`ResolveDuplicateDecision(cancel)`, so the staged import is always discarded.

**FR-O8 — Lands on Unlock.** A successful open navigates to
`DatabaseUnlockScreen`. No snackbar summarises the conflict outcome; the
`promptBiometricSetup` plumbing is removed (FR-U6 owns the offer).

### Create path (S3)

**FR-C1 — Entry.** Welcome and the Add sheet push the wizard directly. No Source
sheet.

**FR-C2 — Step 1 "Name and place".** "Where it lives": two `SourceOptionCard`s in
selectable mode, `This device` (default) and `Google Drive` (account label, or
`Not connected` with `Connect`; disabled with reason when
`supportsRemoteSource == false`). Then the database name field with the live
caption `Saved as <name>.kdbx`. Spec 015 FR-8 (invalid characters block, no
sanitisation) is unchanged.

**FR-C3 — Step 2 "Protect it".** Master password, confirm, strength; `KeyFileRow`;
`Unlock with biometrics` as `KvSwitch`. Spec 015 FR-2, FR-3, FR-5, FR-6, FR-7,
FR-9, FR-10, FR-11, FR-13 are unchanged. Spec 015 FR-4's three mutually
exclusive key modes are preserved but presented as the row plus one sheet:
tapping the empty row offers `Choose a file` and `Generate a new key file`; the
selected state shows the name (or `New key file, created with the database`)
with Change and Remove. The FR-13 backup warning stays inline under the row
while "generate" is selected.

**FR-C4 — Design system.** Fields use `kvFieldDecoration`/`kvFieldLabel`, the
switch is `KvSwitch`, icons are `KvIcon(AppGlyph)`, the strength display reuses
`widgets/entry/strength_strip.dart`, actions are `KvPillButton`. No
`RadioListTile`, `SwitchListTile`, raw `InputDecoration` or `AppIcons` remains in
`create_database_screen.dart`.

**FR-C5 — Create on the remote for real.** `CreateNewDatabase` carries
`createOnRemote`. After the local transactional create (015 FR-9) commits, the
coordinator calls the existing `LinkDatabaseToRemoteUseCase` with
`remoteFileId: null` and `remoteFileName: '<name>.kdbx'`, which is exactly the
vault Sync "Create a new file on Google Drive" path
(`_createNewDriveFile` -> `LinkCurrentDatabaseToDrive(remoteFileName:)`), and
stamps the record `sourceType: drive`, `sourceRef: mapping.remoteFileId`. Upload
therefore runs under the orchestrator's existing mutex/safe-writer invariants.
If the remote step fails, the local database is **kept**, the vault opens, and
the user is told to link it from Sync (same policy as the former "auto-link to
Drive failed" outcome, whose unreachable code path was removed). The remote step is never rolled
back into deleting a vault the user just created.

**FR-C6 — Straight into the vault.** On success the coordinator result carries
`openVault: true`; the screen replaces the wizard with `VaultScreen`. The
password is not retyped: `SessionSecretHolder` already holds it and the security
profile already holds the key-file path. If the vault cannot open from the
session (defensive), the flow falls back to Unlock.

**FR-C7 — Biometric switch semantics.** Unchanged from 015 FR-11. Creation marks
the biometric offer as answered (FR-U6) whether the switch was on or off, so the
user is not asked again at the next unlock.

**FR-C8 — Web.** Same two steps, same widgets. With
`persistsDatabases == false` step 2's primary action produces the downloads of
015 FR-14 (unchanged) instead of opening a vault, and the caption under it says
so.

### Unlock (S1)

**FR-U1 — Layout.** Back (`Back to databases`), `SourceChip`, database name,
master password field, `KeyFileRow` always visible, primary `Unlock`, then
`Use biometrics` as a link when biometric protection is enabled and available.
The `Use a key file` link and the two button labels (`Unlock vault`,
`Unlock with key file`) are replaced. The form keeps the 480 max width it had
before this spec (003 FR-5 says 600, which the code never used; 480 is the
shipped value and the one the goldens show) and the entry animation from 003
FR-5. `Use biometrics` never unlocks by itself: it re-enters the biometric gate
(D8), and only a passed gate reads the stored credential.

**FR-U2 — Source and name from the coordinator.** `UnlockBootstrapResult` gains
`isRemoteLinked` and `StorageAccountSummary? remoteAccount`, filled best-effort
(FR-L2 rules). The BLoC copies them into state.

**FR-U3 — Every error inline.** All errors emitted in `UnlockPhase.ready`
(typed and generic) render inside the credential group, never as a snackbar.
The ported fix from `fix/unlock-silent-errors` is the baseline. The wrong
credential message becomes the copy-contract string.

**FR-U4 — Recoverable missing file.** `DatabaseFileMissingFailure` (at
initialise or at unlock) renders the missing state instead of the dead-end
failure view: `Locate file` (reuses `locateMissingDatabase`, hash rule of 003
FR-1 unchanged), `Download again from Google Drive` (only when a mapping
exists and `supportsRemoteSource`), `Remove from list` (reuses
`removeRecentDatabase(removeOnly)` after `showKvConfirmDialog`), and
`Back to databases`. Invalid/corrupt/unreadable-metadata failures keep the
existing failure view.

**FR-U5 — Re-download.**
`DatabaseSessionCoordinator.redownloadMissingDatabase(databaseId)` downloads the
mapped remote file, stages it with `stageDriveDownload`, commits it to the
record's `canonicalPath` with `commitStagedDatabase`/`finalizeDatabaseCommit`
(rollback on failure), and updates `fileHash`. Database id, security profile
and mapping are preserved. No raw byte write outside `DatabaseFileRepository`.

**FR-U6 — One biometric offer.** After a successful **manual** unlock, and
before navigating to the vault, the unlock screen asks the coordinator
`shouldOfferBiometricUnlock(databasePath)`, true only when all hold:
`supportsBiometricUnlock`, device biometrics available, the profile has
`biometricProtectionEnabled == false`, the profile's new
`biometricOfferAnswered` flag is false, and the session secret is a non-empty
password (015 FR-11: a key-only vault has nothing to store). If true,
`showBiometricOfferSheet` is shown once. Either answer, and dismissal, sets
`biometricOfferAnswered = true`. It applies to every source and replaces
`biometric_prompt_sheet.dart` and `promptBiometricSetup`.

**FR-U7 — Enable stores immediately.** `updateBiometricProtection(enabled: true)`
now, in the same operation that persists the profile, writes the credential
with `databaseSessionRepository.saveMasterPassword(databaseId, secret)` when
`SessionSecretHolder` holds a non-empty secret. With no session secret it
behaves as today (flag only, credential written at next manual unlock). This is
spec 011 FR-3 compliant (write only with the flag true, per database id) and
needs no second authentication because the user just proved the password. The
`enabled: false` branch (011 FR-5) is untouched. The biometric gate and the
decrypting view are not redesigned.

### Databases list (S4)

**FR-L1 — Layout.** Title `Databases`, accent circular "+" (`Add database`)
opening the Add sheet (`Create new database`, `Open a database`). The inline
`_AddSection` is deleted. Tablet two-column layout from 003 FR-1 is kept, with
the "+" in the header on both.

**FR-L2 — Grouping.** `DatabaseSelectionItem` gains `remoteProviderId` (from the
sync mapping of **any** record, not only `sourceType == drive`). Items group
into `On this device` (null) and one group per provider, headed by
`databaseSourceLabel`. The account label comes from
`DatabaseSelectionSessionResult.remoteAccount`, loaded best-effort: only when
`isConnected()` is already true, never triggering an interactive connect, and a
failure yields the bare `Google Drive` header. Groups keep the existing
most-recently-opened order inside.

**FR-L3 — Rows.** `DatabaseItemTile` shows the name, a status line (`Synced
<relative>`, the existing sync error, or nothing for local), and `KvTag`s
`Biometrics` and `Key file` from the existing item flags. The former subtitles
(`On this device · biometrics on/off`, `Google Drive · synced ...`) are
replaced by group header + tags. Overflow keeps Open/Export/Remove semantics
with the tooltip `More actions for <name>`.

**FR-L4 — Missing row.** `File not found` with `Locate` (existing
`LocateMissingDatabase`). Tapping the row opens Unlock in the missing state
(FR-U4), where re-download and remove also live.

**FR-L5 — Deletion sweep.** Everything listed under "Deletions" is gone, and
`flutter analyze` reports no unused element.

## Copy contract

This list replaces the copy-preservation contracts of 003 and 015 for the
surfaces in scope. Strings not listed here and not on a redesigned surface
(typed failure messages, Drive error mapping, key manager, removal sheet,
decrypting, biometric gate, pending-capture and waiting-passkey notices, web
download step, metadata-unreadable dialog) stay byte-identical.

| Surface | Strings |
| --- | --- |
| Welcome | `Your vault, in a file you own.` · `Custode keeps your passwords in a KeePass database. Keep it on this device or in your own cloud.` · `Create new database` · `Open a database` |
| Source sheet | `Where is your database?` · `This device` / `Pick a .kdbx file` · `Google Drive` / `Not connected` / `Connect` · `Custode only reads the file you pick. Your master password never leaves this device.` |
| Drive files | `Open from Google Drive` · `Google account` · `Switch account` · `Search .kdbx files` · `Modified <relative> · <size>` · `Already added` · same privacy line |
| Conflict | `This database is already here` · `Importing` · `Existing` · `(This device)` / `(Google Drive)` · `Open the existing one` / `Nothing is imported or changed.` · `Recommended` · `Keep both` / `Add this file as a separate database.` · `Replace existing` / `Custode backs up the existing file first.` · `Cancel` |
| Create 1 | `Step 1 of 2` · `Name and place` · `Where it lives` · `This device` / `Stays in Custode's storage` · `Google Drive` / `<account label>` · `Database name` · `Saved as <name>.kdbx` · `Continue` |
| Create 2 | `Step 2 of 2` · `Protect it` · `Master password` · `Confirm password` · strength words (existing) · `Add a key file` / `Optional second factor` · `Unlock with biometrics` · `Create database` · `Opens right away, no need to type the password again.` |
| Unlock | `Back to databases` · `Master password` · `Show password` / `Hide password` · `Add a key file` / `Needed only if this database uses one` · `<key name>` / `Stored in Custode` · `Remove key file` · `Unlock` · `Use biometrics` · `Wrong password or key file. Check both and try again.` |
| Unlock missing | `<name> can't be found` · `The file is no longer where Custode last saw it.` · `Locate file` · `Download again from Google Drive` · `Remove from list` · `Back to databases` |
| Biometric offer | `Unlock <name> with biometrics?` · `Enable` · `Not now` · body `You can change this anytime in Settings.` |
| Databases | `Databases` · `Add database` · `On this device` · `Google Drive · <account>` · `Biometrics` · `Key file` · `Synced <relative>` · `File not found` · `Locate` · `More actions for <name>` |
| Add sheet | `Add a database` · `Create new database` / `Start an empty vault` · `Open a database` / `From this device or Google Drive` |

Additions not drawn in the mockups, required by this spec (final wording is
open decision D4, defaults below):

- Disabled remote option (FR-X3): `Not available in the browser`.
- Key-file sheet in create (FR-C3): `Choose a file` · `Generate a new key file` ·
  `New key file, created with the database`.
- Busy labels (FR-X6): `Opening <name>…` · `Downloading from Google Drive…` ·
  `Creating <name>…` (the wizard's primary action while it runs) ·
  `Removing <name>…`.
- Notices after a successful unlock (D10): `Biometrics could not be enabled.
  You can try again in Settings.` · `Database unlocked, but its settings could
  not be saved on this device. You may be asked for the key file again.`
- Key file picked but not remembered (D14), inline under the key row: `This key
  file will be used now, but the choice could not be saved. You may need to
  pick it again next time.`
- Stored credential unreadable (D15), inline: `Saved credentials could not be
  read. Enter your master password.`
- Locate hash mismatch: `Selected file does not match the missing database. Use
  "Open a database" instead.`
- Create on remote failed (FR-C5): `Database created on this device. It could
  not be uploaded to Google Drive. You can link it from Sync.`
- Web caption under the create action (FR-C8): `Downloads the database. The
  browser keeps nothing.`

Retired strings: `Open existing database`, `Open from Google Drive` as an entry
action (it survives as the Drive files title), `Create & upload a new database`,
`Choose "Open from Google Drive" again to switch account.`,
`Open from Google Drive is currently desktop/mobile only.`,
`Replace existing database?` and its body, `Duplicate database detected` and the
three 003 consequence lines, `Use existing`, `Use biometric unlock for
<basename>?` and its Drive-specific body, the two biometric snackbars,
`Unlock vault`, `Unlock with key file`, `Use a key file`, `Biometric unlock`,
`Incorrect master password or key file.`, `Back to database list` on the missing
state, the 003 welcome body, and the row subtitles of 003 C-1.

## Golden inventory

Naming follows the existing scheme `<surface>_<state>_<WxH>_<theme>.png` in
`test/goldens/`, harness `test/goldens/database_and_unlock_test.dart`. Result:
25 `db_*`/`unlock_*` files (21 today), not counting `sync_picker`.

| Golden | Status | Slice |
| --- | --- | --- |
| `unlock_password_390x844_light.png` | re-shot | S1 |
| `unlock_password_390x844_dark.png` | re-shot | S1 |
| `unlock_password_1024x768_light.png` | re-shot | S1 |
| `unlock_wrong_password_390x844_light.png` | re-shot (inline error with key file selected, `UnlockKeyFile` mockup) | S1 |
| `unlock_key_selected_390x844_light.png` | re-shot | S1 |
| `unlock_missing_390x844_light.png` | new | S1 |
| `unlock_biometric_offer_390x844_light.png` | new | S1 |
| `unlock_face_id_prompt_390x844_light.png` | deleted | S1 |
| `unlock_key_manager_390x844_light.png` | unchanged | - |
| `unlock_decrypting_390x844_light.png` | unchanged | - |
| `unlock_biometric_gate_390x844_dark.png` | unchanged | - |
| `db_welcome_390x844_light.png` | re-shot | S2 |
| `db_welcome_390x844_dark.png` | re-shot | S2 |
| `db_source_sheet_390x844_light.png` | new | S2 |
| `db_drive_files_390x844_light.png` | new | S2 |
| `db_drive_loading_390x844_light.png` | re-shot | S2 |
| `db_drive_empty_390x844_light.png` | re-shot | S2 |
| `db_conflict_390x844_light.png` | new | S2 |
| `db_duplicate_390x844_light.png` | deleted | S2 |
| `db_invalid_file_390x844_light.png` | unchanged | - |
| `sync_picker_390x844_light.png` | re-shot only if the shared `RemoteFileList` changes its pixels | S2 |
| `db_create_step1_390x844_light.png` | re-shot | S3 |
| `db_create_step2_390x844_light.png` | re-shot | S3 |
| `db_list_390x844_light.png` | new, replaces `db_recent_390x844_light.png` | S4 |
| `db_list_390x844_dark.png` | new, replaces `db_recent_390x844_dark.png` | S4 |
| `db_list_1024x768_light.png` | new, replaces `db_recent_1024x768_light.png` | S4 |
| `db_list_1024x768_dark.png` | new, replaces `db_recent_1024x768_dark.png` | S4 |
| `db_add_sheet_390x844_light.png` | new | S4 |

Omitted axes are covered by widget assertions, as in 003: dark roles for every
new sheet, 599/600/1024 widths for the list, unlock form <= 480 at 1024, sheet
geometry (root navigator, radius-32 top corners), the connected state of the
Source sheet, the disabled remote option, the name-only conflict without
`Recommended`, and the missing state without a mapping (no re-download action).
Goldens are order-independent per the repository rule: run
`flutter test test/goldens --test-randomize-ordering-seed=$RANDOM` as well as
the plain run, and warm `Image.asset` through `warmUpGoldenAssets()`.

## What this supersedes

**Spec 003** (`specs/003-database-and-unlock/spec.md`):

- C-1, last paragraph (row subtitle strings): replaced by FR-L2/FR-L3. The
  `DatabaseSelectionItem` contract itself stays and is extended.
- C-2, last sentence (empty state offers create+upload and switch account):
  replaced by FR-O4/FR-O5.
- C-6, first sentence (create route returns `CreateDatabaseCredentials`):
  already obsolete since 015; create now ends in the vault (FR-C6).
- FR-1 (three welcome pills, recent header, row subtitle, add rows): replaced by
  FR-O1, FR-L1 to FR-L4. Locate rules are kept.
- FR-2: already superseded by 015; now by FR-C2 to FR-C4.
- FR-3, empty-state sentence: replaced by FR-O3/FR-O5. Invalid/corrupt sheets
  are kept.
- FR-4: outcomes kept, sheet and labels replaced by FR-O7; name collisions join
  the same sheet (FR-O6).
- FR-5: layout, links and the post-Drive prompt replaced by FR-U1, FR-U6. The
  decrypting paragraph is kept.
- "Copy preservation contract" including the widget-disposition paragraph:
  replaced by this spec's copy contract and deletions list.
- "Exact golden inventory — 22 files": replaced by this spec's inventory.
- Acceptance criteria 1, 8, 10: re-based on this spec. C-3, C-4, C-5, C-7 and
  acceptance criteria 2 to 7, 9, 11 remain normative.

**Spec 015** (`specs/015-create-database-credentials/spec.md`):

- FR-1 wording of step contents: replaced by FR-C2/FR-C3 (still two steps).
- FR-4 presentation only (three-way control): replaced by FR-C3; the three
  mutually exclusive modes remain.
- FR-10, the implied continuation on the selection/unlock screen after success:
  replaced by FR-C6. The failure behaviour is kept.
- "Golden inventory" under Tests: replaced by this spec's inventory.
- FR-2, FR-3, FR-5 to FR-9, FR-11 to FR-15 and all acceptance criteria remain
  normative.

**Other**: `docs/database_flows_refactor.md` is deleted in S4.

## Deletions

Each slice deletes what it replaces; S4 sweeps the rest.

- S1: `widgets/database/biometric_prompt_sheet.dart`; `promptBiometricSetup` on
  `DatabaseUnlockScreen`, `DatabaseSelectionSuccess`,
  `DatabaseSelectionSessionResult` and its three coordinator set sites;
  `_showBiometricSetupPrompt`; `_UnlockLinkRow`'s key-file link;
  `_KeyFileSelector`; `_pickKeyFile` in the unlock screen.
- S2: `showDuplicateDatabaseSheet` and `_DuplicateSheet`;
  `_showOverwriteDatabaseSheet`; `hasManagedDatabaseNamed`;
  `overwriteExisting` everywhere; `DrivePickerSheetResult` and the hand-rolled
  rows/empty state in `drive_picker_sheet.dart` (the file is reduced to, or
  replaced by, `remote_file_picker.dart`; `driveErrorMessage` mapping moves with
  it, strings unchanged); the private list body of `_RemoteFilePickerScreen`;
  `WelcomeScreen.onOpenFromGoogleDrive`; the two "switch account" /
  "desktop/mobile only" snackbars; `MobileFileStorage.fileExistsInAppDirectory`
  if no other caller remains.
- S3: `debugWebMode`; `RadioListTile`/`SwitchListTile`/`InputDecoration`/
  `AppIcons` usage and the private `_StrengthMeter` in
  `create_database_screen.dart`; the wizard's own `_pickKeyFile`.
- S4: `widgets/database/database_action_tile.dart`; `_AddSection`;
  `widgets/database/recent_databases_section.dart` (renamed/reworked into the
  grouped list); `internal_key_file_manager_dialog.dart` if the sheet covers the
  settings caller (verify first, see risk R6); `databaseSubtitle` helpers in
  `database_item_tile.dart`; retired goldens; `docs/database_flows_refactor.md`;
  any now-unused `DatabaseSessionStatus`/state members.

## Acceptance criteria

1. Welcome and Add sheet expose exactly two actions; no third add surface exists
   in `lib/`.
2. Open from device and from Drive share one staging, one conflict detection and
   one conflict sheet; a dismissed sheet leaves no staged file (coordinator test
   asserts `discardStagedDatabase` is called).
3. `Switch account` disconnects and reconnects through the coordinator; no
   snackbar instructs the user to retry.
4. The open flow references the remote list only through `pickRemoteFile`.
5. Creating with Google Drive selected produces a mapping and a remote file via
   `LinkDatabaseToRemoteUseCase`; a remote failure keeps the local vault.
6. After create the vault is shown without the unlock screen and without
   retyping; `SessionSecretHolder` is the only carrier of the password.
7. The biometric offer is shown at most once per database, for local and remote
   sources alike, and `Enable` leaves a keystore entry for that database id
   without another authentication prompt; with the flag off no entry exists
   (spec 011 AC-1 still holds).
8. Every `UnlockPhase.ready` error is a descendant of the credential group.
9. A missing file can be located, re-downloaded (when mapped) or removed from
   the unlock screen; re-download goes through `DatabaseFileRepository`
   stage/commit only.
10. `kIsWeb` is absent from the files named in FR-X2; the same widget types are
    built with `debugPlatformCapabilities` set to web and to native.
11. The list groups by mapping provider, shows credential tags and the missing
    row; the "+" opens the Add sheet.
12. Everything under "Deletions" is gone; `flutter analyze` is clean;
    `flutter test` and the randomized golden run are green.
13. `database_session_coordinator_imports_test.dart` passes unmodified.

## Open decisions

Defaults are what the tasks assume until product says otherwise. Decisions
marked **Decided** are closed and implemented in S1.

- **D1 — Account identity vs spec 013 rule 6. Decided.** The mockups show the
  account email; 013 mandates the generic `Google Drive connected` with no
  email, and desktop OAuth has no email today (003 C-2). The label renders
  whatever the existing `StorageAccountSummary` provides: the email when
  present (`Google Drive · <email>`), otherwise the generic `Google Drive`.
  When 013 lands the adapter returns no email and no UI change is needed.
- **D2 — Remote failure during create (FR-C5).** Default: keep the local vault
  and open it with a notice. Alternative: fail the wizard and roll back
  (015 FR-9 style); rejected as default because a partially created remote file
  cannot be reliably cleaned up.
- **D3 — Biometric offer body. Decided.** The mockup's body ("Offered once
  after the first successful unlock, for every source.") reads as a designer
  annotation. The body is `You can change this anytime in Settings.`
- **D4 — Wording of the additions not drawn in the mockups** (copy contract).
- **D5 — Where the offer appears. Decided.** Over the unlock screen right
  after a successful manual unlock; vault navigation continues when the sheet
  resolves. The mockup hints at the vault behind the sheet; doing that needs
  `VaultScreen` to host onboarding UI, which is avoided. `Enable` stores the
  credential immediately from the session secret, with no second
  authentication (FR-U7).
- **D6 — "Keep both" on a name-only conflict.** Default: the new record gets a
  numeric suffix in its display name (`Personal (2)`); file names are opaque so
  nothing collides on disk.
- **D7 — Existing installs and the offer. Decided.** Profiles have no
  `biometricOfferAnswered` flag, so every existing database with biometrics off
  is offered once, including users who turned it off deliberately. Accepted
  (one sheet, once).
- **D8 — Biometric gate and "Use biometrics". Decided.** The gate screen and
  the decrypting view are kept as they are; the link re-triggers
  `RetryBiometricAuthentication`. The mockup does not draw the gate.
- **D9 — Web.** Web keeps 015 FR-14 download-only create and cannot reach "vault
  directly". Default: same widgets, different outcome caption (FR-C8).
- **D10 — Keystore failure after a successful unlock. Decided.** If storing the
  biometric credential fails (on `Enable`, or when refreshing it at a manual
  unlock with the flag on), the unlock still succeeds. The vault opens and a
  notice says `Biometrics could not be enabled. You can try again in Settings.`
  An enable that failed restores the flag to its previous value, so a profile
  never claims protection that has no keystore entry. The failure is never
  reported as an unlock failure. The same holds for every write that follows
  the decrypt in `unlockWithManualCredentials` (reading the profile, refreshing
  the credential, saving the key-file path): the vault opens and the notice is
  the settings one from the copy contract. Spec 011 is unchanged: the
  credential is written only with the flag on, and an empty secret (a
  key-file-only unlock) is never written.

- **D11 — "Replace existing" on a name-only match of a remote-linked
  database. Decided.** A name-only match is a different database. Replacing
  keeps the record and therefore its sync mapping, so the next sync would push
  the new content into the old remote file. No policy is invented for that
  case: the option is not offered (Open the existing one, Keep both, Cancel
  remain), and the coordinator treats a replace it did not allow as `cancel`.
  A source or hash match, and a name-only match on a database with no mapping,
  keep all four options.
- **D12 — A mapped remote file is a source match. Decided.** Opening a remote
  file that an existing database is already linked to (whatever that
  database's `sourceType`) asks the conflict question with "Open the existing
  one" recommended, instead of silently adding a second database on the same
  remote file. `SelectDriveDatabase` and `selectDriveDatabase` carry the
  provider id so the match is on the `(providerId, remoteFileId)` tuple.
  Unreadable sync metadata degrades to the hash and name checks.
- **D13 — The database being unlocked is the active one. Decided.**
  `VaultBloc` reads the key file from the active database's profile, and a
  missing row (FR-L4) reaches Unlock without selecting anything. Both unlock
  paths (`unlockWithManualCredentials`, `unlockWithStoredCredentials`) make the
  database active before decrypting it, ending the previous session exactly as
  choosing it from the list does. It happens before the decrypt so a registry
  failure is never a "failure after a successful decrypt" (D10).
- **D14 — A picked key file that cannot be remembered. Decided.** The key is
  validated and copied into managed storage first; if only the profile write
  fails, the key fills the slot and is used for this unlock, with an inline,
  announced notice. A key that cannot be validated or copied stays an error.
- **D15 — Stored credential unreadable. Decided.** Any failure reading the
  keystore after a passed biometric gate (at initialise, or from `Use
  biometrics`) lands on the ready form with an inline message; the manual path
  is available. It is never the failure view and never a stuck `Decrypting`.
- **D16 — "This device" glyph. Decided.** `AppGlyph.folder` on every platform
  (`databaseSourceGlyph`), not the desktop monitor: the device is a phone as
  often as a computer. No new icon asset.

## Risks

| # | Risk | Mitigation |
| --- | --- | --- |
| R1 | Immediate keystore write on enable behaves differently per platform keystore (user-presence-bound keys) | Verify with the spec 011 keystore probe (`manual-qa-harnesses` skill) on Android and one Apple platform before closing S1 |
| R2 | Switching account orphans mappings of vaults linked under the previous account | Mappings untouched; existing reconnect-required state covers it; manual QA case in S5 |
| R3 | Removing the name-based overwrite branch changes `_commitStagedImport`, a data-loss-sensitive path | Characterization tests first (S2 first task), then the change; all four outcomes re-asserted with backup/rollback |
| R4 | Direct vault entry after create assumes `VaultBloc` needs only the session secret and the profile key path | S3 verifies with a widget test through the real coordinator; fallback to Unlock is specified |
| R5 | Sharing `RemoteFileList` with the vault link picker touches spec 005 surface and its golden | Extraction is behaviour-preserving; `remote_file_picker_test.dart` and `sync_picker` golden guard it |
| R6 | `internal_key_file_manager_dialog.dart` may carry desktop-only behaviour the sheet lacks | Compare before deleting; if not equivalent, keep the dialog and only route it through `pickKeyFile` |
| R7 | Spec 013 removes `files.list`; work on the list could be thrown away | Everything list-specific sits behind `pickRemoteFile`; nothing else depends on it |
| R8 | `getConnectedAccount()` on list load could hit the network or prompt | Called only when `isConnected()` is already true, wrapped best-effort; coordinator test asserts `connect()` is never called from list loading |

## Out of scope

Google Picker and scope changes (013); second provider or provider picker
(010/012); vault Sync screen redesign; settings redesign beyond routing its
key-file choice through `pickKeyFile`; item counts before unlock (003 open
assumption); export/backup of key files; localisation; any native
platform-specific code.
