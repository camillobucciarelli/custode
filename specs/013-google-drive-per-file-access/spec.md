# 013 — Google Drive per-file access and Picker

**Status**: Planned · **Kind**: Security / release blocker  
**Depends on**: 005 · **Coordinates with**: 010 (provider abstraction), 006 (browser extension listing)

## Summary

Replace the restricted `https://www.googleapis.com/auth/drive` scope with the
narrow `https://www.googleapis.com/auth/drive.file` scope, and replace the
in-app global Drive file list with the official Google Picker one-pick flow.
The app keeps working device-to-Google with no backend.

This is a release blocker. A public, unverified app requesting a restricted
scope makes Google show the "app isn't verified" interstitial to every user who
is not an owner of the Cloud project, which is not acceptable for the next
public release.

Spec 013 is the **normative source for Google OAuth scope and for how a remote
file is chosen**. Spec 010 remains the owner of the provider-neutral storage
architecture. Where the two overlap, 013 defines *what Google authorization and
file selection must be*, and 010 defines *which layer it lives behind*.

## Problem and current state

- `DriveAuthService` and the desktop PKCE path request the restricted full-Drive
  scope, which grants access to every file in the user's Drive.
- Remote file selection is an in-app list built from `files.list`, which only
  works because of that restricted scope.
- The desktop OAuth client ships a client secret at runtime, which for an
  installed application is not a secret and is an unnecessary liability.
- Google verification for a restricted scope requires a security assessment the
  project does not intend to undertake for a single-developer app.

## Goals

1. Request exactly one Google scope: `drive.file`.
2. Make the Google Picker the only way a user selects an existing `.kdbx`.
3. Keep creating a new remote vault possible under `drive.file`.
4. Remove the desktop client secret from the runtime; use a public client with
   PKCE.
5. Migrate every existing mapping off the full-Drive grant, fail-closed, with
   explicit user consent and without ever touching vault bytes.
6. Ship on Android, iOS, macOS, Windows and Linux in one atomic release.
7. Publish the branding and privacy prerequisites Google requires so the consent
   screen is clean for external accounts.

## Non-goals

- No backend, proxy or server-side token storage.
- No Shared Drives support.
- No identity scopes (`openid`, `email`, `profile`) and no account email in the
  UI.
- No second cloud provider; that stays with 010 and 012.
- No change to the sync algorithm, conflict policy, checksums or safe-writer
  invariants.
- No change to KDBX parsing or vault file format.

## Authorization model — normative

1. **Scope.** The authorization request contains exactly
   `https://www.googleapis.com/auth/drive.file` and nothing else. No broader
   Drive scope. No identity scope. Account email is never requested, received,
   logged or displayed.
2. **PKCE.** Every platform uses the authorization-code flow with PKCE `S256`
   and a cryptographically random `state`, validated on callback.
3. **Public client.** The desktop OAuth client is a public installed-app client.
   No client secret is compiled into, shipped with, or read at runtime by any
   build.
4. **System browser.** Consent always happens in the system browser or an
   OS-provided in-app browser tab. An embedded WebView is forbidden.
5. **Consent prompt.** `prompt=consent` is used so the user sees exactly what is
   being granted, and so the one-pick trigger is honoured.
6. **Grant semantics.** `drive.file` grants access per file, keyed by file ID,
   for files the user picked or the app created. The app must never assume it
   can read a file it did not obtain through the Picker or create itself.

## User experience — normative

The Drive connection surface exposes exactly two actions:

| Action | Behaviour |
| --- | --- |
| **Choose an existing file** | Opens the Google Picker. Returns exactly one `.kdbx`. |
| **Upload this vault as a new file** | Creates a new remote object from the current local vault. |

Rules:

1. The global remote file list backed by `files.list` is **removed**. There is no
   in-app browsing of Drive contents. `files.list` is not used to discover
   candidate vaults.
2. The Picker returns exactly one file. A multi-selection result is a failure:
   no mapping is created.
3. **New remote file name** defaults to the local file name and is editable
   before upload.
4. **Destination folder** is chosen through the Picker with folder selection
   enabled (`allow_folder_selection=true` on web/desktop,
   `PICKER_ALLOW_FOLDER_SELECTION` on Android, requiring
   `play-services-auth >= 21.6.0`).
   Google does **not** document that a folder grant enables `files.create` with
   that folder as `parents` under `drive.file`. This is an assumption and must be
   proven in Gate 0. **Approved fallback**: create the file in the root of "My
   Drive" and tell the user they may move it afterwards, because the `drive.file`
   grant follows the file ID, not its location.
5. **Read-only remote file.** If the picked file cannot be modified by this
   account, it is imported as a local copy with sync disabled, and the reason is
   shown. No mapping claiming write access is created.
6. **Account identity in the UI** is the generic string `Google Drive connected`.
   No email, no avatar, no account identifier.
7. **Shared Drives** are out of scope. A file that resolves to a Shared Drive is
   refused with a safe message; no mapping is created.

### Golden inventory

Constitution principle IV. Replacing the in-app list with two actions removes
three goldens and adds one:

| Golden | Status |
| --- | --- |
| `db_drive_empty_390x844_light.png` | deleted with the list |
| `db_drive_loading_390x844_light.png` | deleted with the list |
| `sync_picker_390x844_light.png` | deleted with the list |
| `db_drive_actions_390x844_light.png` | new — the two-action connection surface |

Following the convention already in `test/goldens`, the new surface is a state
variant and is captured at one representative size and theme. **Omitted axes:**
1024×768, and dark theme. Both are covered by widget assertions instead, together
with the states that have no golden at all: the read-only-file local-copy notice,
the Shared Drive refusal, the editable new-file name with its destination
outcome, and the generic `Google Drive connected` label.

The Picker and the consent screen are OS-owned UI. They get no golden by
definition; they are covered by an assertion on the trigger plus the manual
five-platform release gate.

## Architecture

```text
widgets/BLoCs                (events + state only)
    -> coordinators          (sequencing, rollback, consent order)
        -> use cases + repository port
            -> data layer
                 OAuth/PKCE service, Picker bridge, Drive API
                 platform channels (Kotlin / Swift / desktop loopback)
```

Rules:

1. OAuth and Picker live in the **data layer**, behind the existing repository
   port. Presentation never sees a token, an authorization code, a `picked_file_ids`
   value or a provider SDK type.
2. Multi-step sequencing — suspend sync, revoke, re-consent, re-pick, validate,
   resume — lives in a **coordinator**, not in a BLoC and not in a use case.
3. BLoCs translate events to coordinator calls and emit state. Nothing else.
4. When 010 has landed, the Picker and OAuth work sits inside the Google adapter
   behind `CloudStorageProvider`; the port gains a "select one remote object"
   capability instead of "list remote objects". If 013 lands first, the same
   boundary is respected against the current `DatabaseSyncRepository`.
5. No `.kdbx` write path is added. Every remote-to-local write continues to route
   through the existing shared `DatabasePathMutex`, backup and safe-writer
   invariants owned by spec 008.

## Platform strategy

No maintained Flutter plugin covers the one-pick authorization flow on both
Android and iOS. Each platform therefore uses the minimum bridge over an SDK the
project already depends on.

| Platform | Approach |
| --- | --- |
| **Android** | Minimal Kotlin bridge: `AuthorizationRequest` with `PICKER_OAUTH_TRIGGER`, `setOptOutIncludingGrantedScopes(true)`, `Prompt.CONSENT`, reading `getTokenResponseParams()["picked_file_ids"]`. Requires `play-services-auth >= 21.6.0`. |
| **iOS** | Minimal Swift bridge over AppAuth, already present transitively. No new Flutter plugin. Refresh token stored in the Keychain and never exposed to Dart. |
| **macOS / Windows / Linux** | Reuse the existing PKCE loopback service, extended with `trigger_onepick=true` and parsing of `picked_file_ids`. |

Constraints:

- Do **not** fork `google_sign_in`.
- Do **not** raise `play-services-auth` to `22.0.0`.
- Do not add a new Flutter plugin dependency for the Picker.

## Migration and revocation — hard cut, fail-closed

Google aggregates consent per (user, Cloud project). Creating new OAuth clients
inside the **same** Cloud project does **not** drop an existing full-Drive grant:
a returning user would silently keep the broad access. Therefore revocation must
happen first.

### Sequence, per vault

1. Suspend sync for that mapping.
2. Show an explicit confirmation stating that revoking will disconnect sync on
   **all** devices for this account.
3. Revoke the old grant.
4. Obtain new consent for `drive.file` only.
5. Re-select the file through the Picker.
6. Validate the selection against the existing mapping.
7. Resume sync, **preserving the existing checksum and timestamp baselines**. Do
   not recreate the mapping with null baselines — that would re-run a first-sync
   as if the vault had never synced.

### Rules

- Migration is **per vault**, triggered on open or on sync. Multiple mappings
  migrate independently.
- **Different file ID.** If the re-picked file has a different `fileId` than the
  mapping, require an explicit user confirmation, then create the new mapping.
  No implicit overwrite. Content comparison and the safe writer are mandatory.
- **Failed or unverifiable revocation.** Sync stays suspended. The user may retry
  or revoke manually from their Google Account page. The old token is never
  reused, under any circumstance.
- **Cancel, error, offline.** The local vault stays fully usable, sync stays
  suspended, and the mapping and vault bytes are untouched.
- **Android refresh persistence.** Without a backend there is no guaranteed
  persistent refresh token on the device. Reconnection may be required and must
  only ever be requested in the foreground. Background sync never shows UI; it
  fails safe and marks the mapping as needing reconnection.
- **Legacy clients.** The legacy OAuth clients are deleted or disabled before the
  release. Old builds lose Drive access; their local vaults remain fully usable.
- **Rollback after release.** Disable Drive temporarily. Never restore the full
  Drive scope and never re-enable a legacy client.

## Branding and public prerequisites

These are prerequisites of Gate 0-B (a clean consent screen for an external
account) and of the release. Gate 0-B is therefore verified after they are in
place, not before.

| Item | Value |
| --- | --- |
| OAuth app name | `Custode Password Manager` |
| Logo | existing coloured logo, exported square and compliant |
| Domain | `keyvault.camillobucciarelli.dev` |
| Homepage | `/` |
| Privacy policy | `/privacy` |
| Language | English |
| Support email | `camillo@bucciarelli.dev` |
| Audience | External, In production |

- Static site content lives in `website/` in this repository. DNS and deployment
  are the user's responsibility.
- The browser extension privacy policy moves under the same domain. The Chrome
  Web Store listing is updated to the new URL.
- The `keyvault-privacy` repository stays online until the new URL is live **and**
  the store listing is approved, then it is **archived**. It is never deleted
  during the transition.
- The domain must be verified in Google Search Console for the Cloud Console
  branding to be publishable.

## Gate 0 — feasibility spike

Gate 0 runs on a **separate branch** with code that is explicitly **not**
production code. Its purpose is to prove the flow works before any production
change is designed against it.

Gate 0 is verified as two checkpoints, because criterion 11 depends on the
branding prerequisites while criteria 1 to 10 do not:

| Checkpoint | Criteria | Runs | Blocks |
| --- | --- | --- | --- |
| **Gate 0-A** | 1 to 10 | Before the branding prerequisites; needs no site, domain or branding | Everything after it, including the branding work and all production phases |
| **Gate 0-B** | 11 | After the site is live, the domain is verified and the branding is published | Every production phase from the OAuth least-privilege work onwards |

The split is one of ordering only. Every criterion stays mandatory and
fail-closed, none is downgraded to a nice-to-have, and **no `not-run` waiver
exists for any Gate 0 item in either checkpoint**. Criterion 11 not yet having
been recorded means Gate 0-B has not run, which blocks the production phases; it
never reads as a pass.

Targets: a **physical Android device**, a **physical iPhone**, and **real
macOS**. Windows and Linux GUI runs remain a mandatory pre-release gate; they are
not a Gate 0 target only because the flow there reuses the existing desktop PKCE
path. **No `not-run` waiver exists for any Gate 0 item.**

Environment: two dedicated Google accounts, empty vaults, a publicly known test
password. Never a real account, never a real vault.

### Gate 0-A acceptance criteria — all mandatory, fail-closed

1. The authorization request contains exactly `drive.file`, PKCE `S256`, a
   validated `state`, `prompt=consent` and `trigger_onepick=true`, and opens in
   the system browser — never an embedded WebView.
2. The Picker returns exactly one file.
3. The chosen file is accessible; a decoy file that was **not** chosen is
   inaccessible and does not appear in any `files.list` result.
4. Download, update, read-back with checksum verification and creation of a new
   file all succeed.
5. Creation inside the chosen folder is verified; otherwise the root "My Drive"
   fallback is documented as the observed outcome.
6. Access still works after a process restart, with no new browser interaction.
7. A legacy full-Drive grant is ignored; an upgrade from a legacy build performs
   **no** Drive call before new consent is obtained.
8. External revocation produces a safe failure on every device, mappings and
   vaults are preserved, and reconnection succeeds.
9. Cancel, wrong `state`, incomplete callback, no network, and a file deleted
   after being picked each produce: no new mapping, no modified vault byte, no
   partially persisted token.
10. A log scan of a **release** build finds no token, authorization code,
    callback URL, `picked_file_ids` value, file ID or email.

### Gate 0-B acceptance criterion — mandatory, fail-closed

11. On an external, non-owner account, with the site live and branding published,
    the consent screen shows **no** "app isn't verified" warning.

This criterion is verified once the branding prerequisites are in place. A `fail`
blocks the production phases exactly as a Gate 0-A failure does.

### Evidence

Results are recorded in
`specs/013-google-drive-per-file-access/feasibility-report.md`. **Create that
file only when the spike actually runs** — its absence means Gate 0 has not been
performed. Gate 0-A files the report with criteria 1 to 10; Gate 0-B appends the
criterion 11 row to the same report once it runs. A report carrying no criterion
11 row is an incomplete Gate 0, not a passed one.

Every value is boolean or sanitized. The report carries, per criterion and per
platform target:

```text
| criterion | android | ios | macos |
| --------- | ------- | --- | ----- |
| 1 scope+pkce+onepick | pass|fail | pass|fail | pass|fail |
```

plus, per platform: the date (UTC), the SDK/OS version class, and for criterion
5 the observed outcome as `folder_parent_accepted` or `root_fallback`.

Forbidden in the report, without exception: access or refresh tokens,
authorization codes, client IDs, client secrets, callback URLs with parameters,
`picked_file_ids` values, Drive file IDs, folder IDs, account emails, local or
remote paths, and real vault bytes.

## Release gate

Five platforms — Android, iOS, macOS, Windows, Linux — each independently
recording `pass` or `fail` for the full flow: consent, pick, download, update,
create, restart, revoke, reconnect, migrate. **No `not-run` waiver.** One
platform's result never qualifies another. The release is atomic: it ships when
all five pass, and the legacy OAuth clients are cut at the same time.

## Risks

| Risk | Mitigation |
| --- | --- |
| The one-pick API is recent and may change | Gate 0 proves it on real devices before production design; the fallback is a documented root-create flow |
| Android SDK floor moves to May 2026 | Pin `play-services-auth >= 21.6.0`, do not raise to `22.0.0`, verify on a physical device |
| No guaranteed persistent refresh on Android without a backend | Foreground-only reconnection; background sync fails safe and never shows UI |
| Folder-grant semantics for `files.create` are undocumented | Treated as an assumption, proven or refuted in Gate 0 item 5; approved root fallback |
| Project-wide revocation disconnects every device | Explicit confirmation before revoking; per-vault migration; baselines preserved so resumption is not a first sync |
| No automated test replaces live proof | Gate 0 and the five-platform release gate are manual and mandatory |
| Human dependencies: physical Android, Windows GUI, Linux GUI, DNS, Cloud Console, Chrome listing | Tracked as explicit tasks with boolean evidence, sequenced before the release gate |
| Legacy client cut breaks old builds | Documented and intentional: local vaults stay usable; only Drive sync stops |

## Relationship to spec 010

- 010 owns the provider-neutral port, the mapping schema and the safe error
  taxonomy.
- 013 owns the Google authorization scope, the consent flow and how a remote file
  is selected.
- 010's "preserve current file-picker behaviour" assumption is superseded by this
  spec: the picker is replaced, and the port's listing operation becomes a
  select-one operation.
- 013 does not re-specify 010's architecture, and 010 does not re-specify 013's
  scope or picking. Neither spec duplicates the other's tasks.

## Open questions

None blocking. Two are answered by Gate 0 rather than by design: whether a folder
grant permits `files.create` with `parents`, and whether Android persists a
usable refresh across process restarts without a backend.
