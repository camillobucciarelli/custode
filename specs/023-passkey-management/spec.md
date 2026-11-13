# 023 — Passkey management

**Status**: Planned (slices 1–2) · **Kind**: Feature / Credentials
**Created**: 2026-08-29
**Depends on**: 004 (entry editor), 006 (security & autofill extension), 008 (per-field conflict resolution — merge of the new fields)
**Coordinates with**: 016 (Android autofill; passkeys were declared out of scope there), 005 (CSV import must not be able to inject passkey fields; attachment and backup export must not leak them), 017 (password history must not record passkey material), 019 (vault navigation model 1a — the entry detail surface the passkey section lands on), 020–022 (pixel passes; a new entry-detail section must be added in the restyled tokens, not ahead of them)

**Input**: User description: "Gestione delle passkey (WebAuthn/FIDO2) nel vault KDBX: storage interoperabile con KeePassXC nei campi custom protetti, visualizzazione e gestione delle passkey nell'entry editor, registrazione e autenticazione tramite l'estensione Apple AutoFill (iOS/macOS), con Android Credential Manager e browser desktop come fasi successive."

## Summary

A passkey is a per-site key pair that replaces the password: the site keeps the
public key, the credential holder keeps the private key and proves possession by
signing a challenge. Sites increasingly offer, and some now require, passkeys —
a password manager that cannot hold one forces the user to keep a second
credential store.

Custode stores credentials in a `.kdbx` file, and that format already carries
passkeys in practice: KeePassXC writes them as a small set of named fields on an
ordinary entry. This spec makes Custode a first-class holder of those
credentials, in three independently shippable slices:

1. **Hold them** — read, display, protect, sync and delete passkeys that already
   exist in the vault (typically created by KeePassXC on the desktop), without
   ever exposing the private key to the UI, the logs, an export or the
   plaintext caches.
2. **Use them** — sign in with a stored passkey on every supported platform:
   iOS and macOS through the existing AutoFill credential provider extension,
   Android through a Credential Manager provider, Windows and Linux through the
   desktop browser extension and native host.
3. **Create them** — register a brand-new passkey from the Apple extension, so a
   site's "create a passkey" flow can choose Custode.

Slice 1 alone delivers value (a KeePassXC user's vault stops being partially
unreadable and unsafely handled in Custode); slice 2 turns Custode into a
usable authenticator; slice 3 removes the dependency on KeePassXC for creating
passkeys.

**Beta scope**: slices 1 and 2. Slice 3 is specified here but not scheduled for
the current beta.

### Why the private key needs new plumbing

Custom fields today are written unprotected — every custom field value goes into
the KDBX as a plain value, and the entry editor shows and copies it like any
other text. A passkey private key cannot travel that path: it must be a
protected value in the file, must never be rendered, copied or exported, and
must never appear in a diagnostic string. Principle I of the constitution
(*Secrets never leak into the shell*) is therefore the governing constraint of
this feature, not a checklist item at the end.

## Clarifications

### Session 2026-08-29

- Q: Is user presence required on every assertion, or may a recent unlock satisfy it? → A: Every assertion — biometrics or device passcode each time; do not reuse the password autofill recent-unlock window.
- Q: Where does passkey private key material live when the app is not running? → A: In the same sealed, device-local cache already used for passwords (excluded from backups), wiped when the database is locked or removed.
- Q: Does Android's Credential Manager belong in this spec or its own? → A: Its own spec — 023 stops at Apple. *(Superseded on 2026-09-09, see below.)*
- Q: Where is the key pair generated at registration? → A: In the credential provider extension using the platform cryptography APIs; this spec adds no Dart cryptography dependency. *(Superseded by T708's decision: the key is generated in the app, by `PasskeyGenerator`, because only the app can write the vault the key must land in — see User Story 3's note. The app therefore does carry a Dart cryptography dependency for this, `pointycastle`, which it already used elsewhere.)*

### Session 2026-09-09

- Q: Which slices ship in the current beta, and on which targets? → A: Slices 1 and 2 (hold + sign-in) on every target: iOS and macOS via the credential provider extension, Android via a Credential Manager provider (API 34+, with a plain "not available on this device" state below it), Windows and Linux via the browser extension intercepting the site's WebAuthn sign-in call and the native host signing. Slice 3 (registration) stays in the spec but is not part of the beta.
- Q: Does deleting a passkey ask first and back up, like the other destructive operations? → A: Yes — explicit confirmation stating the passkey cannot be recovered, and a dated local copy of the `.kdbx` written before the save, on the same path "empty bin" and merge use.
- Q: Does cached passkey material have its own expiry? → A: No — same lifetime as the cached passwords; it is removed only when the database is locked or removed (FR-023). No separate "cache expired" state.
- Q: How are passkey entries made findable, and what happens when a passkey-only entry and a password entry exist for the same site? → A: A passkey badge on the entry in the list and in the detail; no dedicated filter or search term. A passkey is an attribute of the ordinary entry (same record as user and password). When two existing entries for the same site split the two, Vault health's duplicate detection offers to merge them into one entry; the merge runs only on the user's confirmation, with a backup, never automatically on open.
- Q: Where is the user told that a passkey's security is the vault's, not hardware isolation? → A: A fixed note in the passkey section of the entry detail; no one-time dialog and no persisted "already shown" state.
- Q: Is field protection only passkey plumbing, or a user choice? → A: A user choice on every custom field. In insert and edit the user marks a custom field as secret; a secret field is stored protected in the file and treated like the password in view: masked, revealed through the same gate, copied through the same clipboard guard, never in logs. Fields that arrive protected from another client show as secret. Today's writer silently downgrades every protected custom field to plain on save; that is fixed in the same change.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Hold passkeys safely in the vault (Priority: P1)

A user who already created passkeys in KeePassXC opens the same `.kdbx` in
Custode. Entries carrying a passkey are recognisable as such, the user can see
which site and account the passkey belongs to and when it was added, and can
delete it. The private key is never displayed, never copied to the clipboard,
never written to an export or an autofill cache, and survives sync and merge
untouched.

**Why this priority**: It is the correctness and safety floor. Without it,
Custode silently mishandles credentials that are already in the user's file —
showing a private key as ordinary copyable text is worse than not supporting
passkeys at all. It is also a precondition for every later slice.

**Independent Test**: Open a `.kdbx` containing a KeePassXC-created passkey,
confirm the entry is marked as holding a passkey with the correct site and
account shown, confirm no view or export path yields the private key, delete the
passkey and confirm the entry keeps its other fields and the file reopens
cleanly in KeePassXC.

**Acceptance Scenarios**:

1. **Given** a vault entry carrying a passkey created by KeePassXC, **When** the
   user opens the entry, **Then** the entry shows a passkey section naming the
   relying party and the passkey username, and shows no private key value.
2. **Given** that entry, **When** the user attempts any copy, reveal, export or
   share action available on the entry, **Then** no action yields the private
   key or the credential seed.
3. **Given** that entry, **When** the user deletes the passkey, **Then** the
   app first asks for confirmation stating the passkey cannot be recovered and
   writes a dated local copy of the vault; after the save the passkey fields are
   removed, all other fields are unchanged, and KeePassXC opens the resulting
   file without error or warning.
4. **Given** two devices syncing the same vault where one added a passkey,
   **When** the vaults merge, **Then** the passkey arrives intact and the merge
   preview describes it as a passkey rather than listing its raw field values.
5. **Given** a passkey entry, **When** any diagnostic or log line is produced for
   it, **Then** the private key is absent from that output.

---

### User Story 1b - Secret custom fields (Priority: P1)

A user adds a custom field to an entry (a recovery code, a PIN, a security
answer) and marks it as secret. From then on the field behaves like the
password: stored protected in the file, masked in the entry detail, revealed
through the same gate as the password, copied through the same clipboard
guard, and never shown in a log or diagnostic. A custom field that another
client already stored protected is shown as secret without the user doing
anything.

**Why this priority**: The passkey private key is a protected custom field, so
the plumbing is shared; and today Custode silently strips the protection from
any protected custom field on save, which is a data-safety bug with or without
passkeys.

**Independent Test**: Create a custom field marked secret, save, reopen in
KeePassXC and confirm the attribute is protected; edit the entry's title in
Custode, save, confirm the attribute is still protected; open the entry in
Custode and confirm the value is masked until revealed.

**Acceptance Scenarios**:

1. **Given** the entry editor, **When** the user adds a custom field, **Then**
   a per-field "secret" toggle is available, off by default.
2. **Given** a custom field marked secret, **When** the entry is saved,
   **Then** the field is stored protected in the file and another KeePass
   client shows it as protected.
3. **Given** an entry with a protected custom field written by another client,
   **When** the user opens it in Custode, **Then** the field is shown as
   secret and masked; **When** the user edits any other field and saves,
   **Then** the field is still protected in the file.
4. **Given** a secret custom field in the entry detail, **When** the user
   reveals or copies it, **Then** the same reveal gate and clipboard guard as
   the password apply, including auto-hide and clipboard clearing.
5. **Given** a secret custom field, **When** the user turns the toggle off in
   the editor and saves, **Then** the field is stored plain, after a
   confirmation that says it will no longer be protected.

---

### User Story 2 - Sign in with a stored passkey on every platform (Priority: P2)

A user visits a site or app that asks for a passkey. Custode is offered as the
passkey source for that platform; the user picks the Custode passkey for that
site, confirms with biometrics or device passcode, and is signed in without
typing anything.

The platform paths are:

- **iOS and macOS**: the existing AutoFill credential provider extension.
- **Android**: a Credential Manager provider, available on API 34 and later. On
  an older device the app states plainly that passkey sign-in is not available
  there; passkeys stay visible and manageable (Story 1).
- **Windows and Linux**: the desktop browser extension intercepts the site's
  passkey sign-in request in the page and the native host signs with the vault
  credential. Only sites open in a browser with the extension installed are
  served; native desktop apps are not.

**Why this priority**: It is the payoff of holding the credential. Apple reuses
the extension that already serves passwords; Android and desktop reuse the
autofill integrations of specs 016 and 009 for their plumbing.

**Independent Test**: With a passkey for a test relying party in the vault,
trigger a passkey sign-in on each platform and confirm the sign-in completes
using Custode, and that a passkey for a *different* relying party is never
offered or usable for that site. On an Android device below API 34, confirm the
"not available" state is shown and no provider is registered.

**Acceptance Scenarios**:

1. **Given** the vault holds a passkey for a site, **When** the site requests a
   passkey sign-in, **Then** Custode appears as an available provider and lists
   only passkeys whose relying party matches that site.
2. **Given** an Android device below API 34, **When** the user looks for passkey
   sign-in, **Then** the app says it is not available on this device and no
   Credential Manager provider is registered.
3. **Given** a site open in a desktop browser with the extension installed,
   **When** the site requests a passkey sign-in, **Then** the extension offers
   the matching Custode passkeys and the response is signed by the native host,
   with the private key never sent to the extension.
4. **Given** the user selects a Custode passkey, **When** the user confirms with
   biometrics or device passcode, **Then** the sign-in succeeds.
5. **Given** the user cancels or fails the confirmation, **When** the flow ends,
   **Then** no assertion is produced and the site receives a cancellation, not an
   error implying the credential is missing.
6. **Given** the vault holds no passkey for the requesting site, **When** the
   request arrives, **Then** Custode offers nothing for that request and does
   not present a misleading empty list.
7. **Given** a passkey sign-in has completed, **When** the flow ends, **Then** no
   private key remains outside its protected storage.

---

### User Story 3 - Create a new passkey from Custode on iOS and macOS (Priority: P3)

A user on a site's "create a passkey" flow chooses Custode as the destination.
Custode creates the credential, stores it on a new or existing entry for that
site, and the site completes registration. The new passkey is immediately
visible in the vault (Story 1) and usable for sign-in (Story 2).

**Why this priority**: It removes the dependency on KeePassXC for creating
passkeys, but the user still gets real value from Stories 1 and 2 without it.

**Where this story shipped, and why not on Apple (T708).** The story is served on
Windows and Linux, through the browser extension and the running app, and not on
iOS or macOS. FR-020 is the reason: a registration may only be reported once the
credential is durably in the vault, and only the app can write the vault — the
Apple credential provider extension has no master password. On desktop the app is
open and unlocked when the request arrives, so the write completes before the site
is answered. On Apple the extension would have to answer the site itself, so it
refuses the ceremony instead and says where creating a passkey works. Registration
always goes through the app; the extension implements no step of it the app does
not perform. Staging a credential for the app to adopt later was considered and
rejected: a WebAuthn challenge cannot be answered after its ceremony ends, so
staging would give the site nothing while costing the user the account the moment
the extension claimed success. Completing it on macOS needs an app-group XPC
transport (T709); on iOS no supported extension-to-app channel exists, so it
cannot be completed there by any design.

**Independent Test**: Run a passkey registration on a test relying party
choosing Custode, then confirm the credential appears in the vault with the
correct site and account, and that signing in with it afterwards succeeds.

**Acceptance Scenarios**:

1. **Given** a site requests passkey creation, **When** the user chooses Custode
   and confirms, **Then** a passkey is stored in the vault and the site reports
   successful registration.
2. **Given** the vault already has an entry for that site and account, **When**
   the passkey is created, **Then** the user can attach it to that existing entry
   instead of creating a duplicate.
3. **Given** the vault already holds a passkey for the same relying party and
   user handle, **When** a new one is created for that same pair, **Then** the
   user is told what will be replaced before anything is overwritten, and the
   previous credential is not silently lost.
4. **Given** creation is interrupted (cancelled, vault locked, write failure),
   **When** the flow ends, **Then** the vault contains either the complete
   passkey or none of it — never a partial credential.

---

### Edge Cases

- **Vault locked at request time.** A passkey request can arrive when the vault
  has not been unlocked. Per FR-022 the credential is still servable from the
  sealed cache, so this must produce a working sign-in behind the per-assertion
  confirmation — not a prompt to go and open the app. Where the credential is
  genuinely unavailable (cache wiped, database removed), the user must be told
  plainly, never left with a silent failure that looks to the site like "no
  credential".
- **Malformed or foreign passkey fields.** An entry carrying an incomplete,
  truncated or unrecognised passkey field set must be shown as an unusable
  passkey and left byte-identical on save; Custode must not "repair" or drop
  fields it does not understand.
- **Same relying party, several accounts.** Multiple passkeys for one site must
  be distinguishable by account at selection time.
- **Passkey and password on the same entry.** An entry may hold both; each must
  be offered to the matching kind of request and neither may shadow the other.
- **Deleting an entry that holds a passkey.** The recycle bin path must treat the
  passkey as a credential to be restored intact, not as loose text fields.
- **Field-level merge conflicts on passkey fields.** A conflict-resolution UI
  that displays field values must not display passkey secret values, and must not
  let a merge produce a credential assembled from two different passkeys.
- **Import paths.** CSV import must not be able to inject a passkey field set,
  and the duplicate detector must not treat two different passkeys as duplicates
  because their surrounding fields match. It may, however, pair a passkey-only
  entry with a password entry for the same site and account and offer the merge
  of FR-011a.
- **Read-only or failed save.** If the vault cannot be written, a registration
  must fail before the site is told it succeeded.

## Requirements *(mandatory)*

### Functional Requirements

**Storage and interoperability**

- **FR-001**: The system MUST store a passkey on an ordinary vault entry using a
  field layout that KeePassXC reads as a passkey, and MUST read passkeys written
  by KeePassXC without conversion or migration.
- **FR-002**: The system MUST store the passkey's private key material as a
  protected value in the vault file.
- **FR-002a**: Every custom field MUST carry a user-visible "secret" state.
  The system MUST read that state from the file's protection attribute, MUST
  write it back as read (never downgrading a protected field to plain on an
  unrelated save), and MUST let the user set or clear it per field in the
  entry editor. Clearing it MUST ask for confirmation.
- **FR-002b**: A secret custom field MUST be handled like the password in
  every view: masked by default, revealed through the same gate, copied through
  the same clipboard guard, absent from logs and diagnostics, and represented
  by name only in merge previews and history diffs.
- **FR-003**: The system MUST preserve any passkey-related field it does not
  recognise, byte-for-byte, across open, edit and save of the entry.
- **FR-004**: The system MUST keep an entry's passkey intact across sync, merge,
  recycle-bin deletion and restore.

**Confidentiality**

- **FR-005**: The system MUST NOT display, copy to the clipboard, reveal, or
  otherwise render the passkey private key or credential seed in any user
  interface.
- **FR-006**: The system MUST NOT include passkey secret material in logs,
  diagnostic strings, error messages, crash reports, plaintext caches, attachment
  or backup exports, or any message sent over the desktop browser bridge. (The
  app has no CSV export today — CSV is import-only; see `research.md` R3 for the
  surfaces that actually exist.)
- **FR-007**: The system MUST NOT record passkey secret material in password
  history.
- **FR-008**: Where a conflict-resolution or merge-preview surface lists changed
  fields, the system MUST represent a passkey as a single named credential and
  MUST NOT display its secret values.

**Management in the app**

- **FR-009**: Users MUST be able to see, on an entry that holds a passkey, that a
  passkey exists and which relying party and account it belongs to. The passkey
  section MUST carry a fixed note stating that the passkey is protected by the
  vault (master password, key file and sync destination), not by hardware key
  isolation.
- **FR-010**: Users MUST be able to delete a passkey from an entry without
  affecting the entry's other fields. Deletion is destructive and irreversible
  (no history is kept, FR-007): the system MUST ask for explicit confirmation
  that states the passkey cannot be recovered, and MUST write a dated local copy
  of the vault before the save, as the other destructive operations do
  (constitution VII).
- **FR-011**: The system MUST mark entries holding passkeys with a passkey badge
  in the vault list and in the entry detail, so a user can tell which of their
  credentials are passkeys. No dedicated filter or search term is added.
- **FR-011a**: A passkey is an attribute of an ordinary entry, alongside its
  username and password. When the vault holds a passkey-only entry and a
  password entry for the same site and account, Vault health's duplicate
  detection MUST offer to merge them into one entry holding both; the merge
  MUST run only on the user's confirmation and with the dated backup of
  constitution VII, and MUST NOT happen automatically on open.
- **FR-012**: The system MUST show a passkey it cannot interpret as unusable, and
  MUST explain that it cannot be used for sign-in, rather than failing silently.

**Sign-in (all platforms)**

- **FR-013**: The system MUST offer Custode as a passkey source for sign-in
  requests on iOS and macOS (credential provider extension), Android API 34+
  (Credential Manager provider), and Windows and Linux (browser extension +
  native host). On Android below API 34 the system MUST state that passkey
  sign-in is not available on the device and MUST NOT register a provider.
- **FR-013a**: On Windows and Linux the private key MUST stay in the native host
  process; the browser extension receives only the signed response and the
  metadata needed to list matching passkeys.
- **FR-014**: The system MUST offer, for a given request, only passkeys whose
  relying party matches the requesting site, and MUST NOT allow a passkey for one
  relying party to be used for another.
- **FR-015**: The system MUST require user presence — biometrics or device
  passcode, or on Windows and Linux an explicit in-app confirmation — before
  producing **each** assertion. A recent successful vault unlock MUST NOT
  satisfy this requirement, even though the password autofill path reuses such
  a window today.
- **FR-016**: The system MUST produce an assertion that the requesting site
  accepts as a valid WebAuthn response for the stored credential.
- **FR-017**: On cancellation, failed confirmation, locked vault or missing
  credential, the system MUST end the request with the outcome that matches the
  actual cause, and MUST NOT report success.

**Registration (Apple platforms)**

- **FR-018**: The system MUST support creating a passkey for a requesting site
  and storing it either on a new entry or on an existing entry chosen by the
  user.
- **FR-019**: The system MUST warn before replacing an existing passkey for the
  same relying party and user handle, and MUST NOT overwrite one silently.
- **FR-020**: A registration MUST be all-or-nothing: the vault MUST never be left
  holding a partially written credential, and the site MUST NOT be told
  registration succeeded unless the credential was durably written to the vault.
- **FR-021**: Passkey creation and use MUST respect the existing backup and safe
  write protections that govern every vault write.

**Availability of the credential to the platform**

- **FR-022**: Passkey private key material MUST be held in the same encrypted,
  sealed cache the app already uses for passwords on that platform — device-local,
  readable only while the device is unlocked, and excluded from device backups —
  so that a system passkey request can be served while the app is not running.
  It MUST NOT appear in the plaintext routing/display cache. On Windows and Linux,
  where the native host serves requests only while the app has an unlocked
  vault, no such cache is introduced.
- **FR-023**: The system MUST remove a database's passkey material from that
  cache when the database is locked or removed, so a user has a way to stop a
  device from being able to answer passkey requests. Cached passkey material has
  the same lifetime as cached passwords and no separate expiry.

### Key Entities *(include if data involved)*

- **Passkey credential**: The credential stored on a vault entry. Attributes:
  relying party identifier, credential identifier, account/username shown to the
  user, user handle, private key material (secret, never displayed), creation
  time. One entry holds zero or more; each belongs to exactly one relying party.
- **Vault entry**: The existing container. Gains the ability to hold passkeys
  alongside its password, custom fields and attachments, and to declare that it
  holds one.
- **Secret custom field**: An entry field whose value is stored protected in
  the vault file. User-selectable per field; masked and gated like the password
  in the app. The passkey's secret fields are secret custom fields the app
  manages itself and never lists among the editable ones. New concept — today
  every custom field is written unprotected.
- **Passkey request**: A system-originated ask from a site — either "sign in" or
  "create" — carrying the relying party and, for sign-in, the acceptable
  credential identifiers.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A vault created in KeePassXC with passkeys opens in Custode with
  100% of those passkeys recognised, and reopens in KeePassXC afterwards with no
  passkey lost, altered or reported as corrupt.
- **SC-002**: No user-reachable action in the app, and no exported or logged
  artefact, yields passkey secret material — verified by an automated check that
  fails the build if a passkey secret reaches display, clipboard, export or log
  paths.
- **SC-003**: A user can complete a passkey sign-in on each supported platform
  in under 15 seconds from the moment the site asks, without leaving the
  requesting app or browser.
- **SC-004**: A passkey created in Custode is accepted by the site at
  registration and works for a subsequent sign-in on at least three independent
  relying parties used as conformance targets.
- **SC-005**: A passkey offered for a site is never a passkey belonging to
  another site — zero cross-relying-party offers across the matching test suite.
- **SC-006**: An interrupted registration leaves zero partially written
  credentials across the interruption test matrix (cancel, lock, write failure).
- **SC-007**: Opening and saving an entry that holds a passkey that Custode does not
  fully understand changes no byte of that passkey's stored fields.
- **SC-008**: For any custom field, the protection attribute in the file after
  an unrelated save equals the attribute before it — asserted for both states.

## Assumptions

- The KeePassXC field layout for passkeys is the interoperability target;
  matching it is preferred over inventing a Custode-specific layout, so that
  vaults stay usable in both applications.
- The security model of a passkey held here is the vault's security model —
  master password, key file and the sync destination — not hardware-backed key
  isolation. This is a deliberate trade for portability and is stated to the
  user in the passkey section of the entry detail (FR-009).
- Apple platforms are reached through the credential provider extension that
  already serves passwords; no second extension is introduced.
- Android is reached through a Credential Manager provider added to the app;
  the autofill service of spec 016 is untouched.
- Windows and Linux are reached through the existing browser extension and
  native host; the extension's permission change needed to intercept the page's
  passkey request is user-visible and must be explained on update.
- Existing user-facing copy and the current password autofill behaviour are
  unchanged by this feature (constitution VI).
- The three existing BLoCs are sufficient; passkey work is expected to live in
  use cases, services and the existing coordinators (constitution II, VIII).
- Attestation of the created credential is not required by the target relying
  parties; self-attestation or none is acceptable.
- Key generation and signing both happen inside the credential provider
  extension, using the platform's own cryptography. The app is not running when
  a request arrives, so no second cryptographic implementation is introduced on
  the Dart side and this spec adds no cryptography dependency.
- Verification is local before push — `flutter analyze` clean and `flutter test`
  green — and the platform flows that cannot run in the test suite are covered by
  a named manual QA harness, as spec 008 and spec 011 already do.

## Deferred scope

Out of scope for 023, each to be its own spec if adopted:

- **Passkey registration on Android.** Slice 3 shipped on Windows and Linux,
  through the browser extension and the running app; Apple is covered by T708's
  refusal and T709's unbuilt transport, and Android's Credential Manager
  registration is untouched.
- **Windows and Linux system-level passkey providers** (serving native desktop
  apps rather than browser pages).
- **Attestation statements**, enterprise attestation and device-bound keys.
- **Passkey export/backup as a standalone artefact** outside the `.kdbx`.
