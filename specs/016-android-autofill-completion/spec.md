# 016 — Android autofill completion

**Status**: Draft (clarified) · **Kind**: Platform / Security
**Depends on**: 006 (autofill journeys), 011 (master-password session scope — session gate semantics)
**Coordinates with**: 009 (in-page overlay, desktop), 014 (managed storage — cache location)

**Input**: User description: "autofill on android"

## Summary

Android already fills usernames and passwords through a native
`AutofillService`, but three things a user expects from a password manager on
Android are missing: the credential picker hands out a decrypted password with
no authentication of the person holding the phone, suggestions never appear on
the keyboard row, and a password typed by hand in an app is never offered for
saving into the vault. Mobile browsers are also unserved, because the service
declares no compatibility packages, so a login form in Chrome or Firefox on
Android gets no autofill at all.

This spec completes the Android side to parity with what the Apple and desktop
paths already promise: authenticated release of secrets, inline suggestions,
save/update capture, and browser coverage.

## Problem and current state

Verified against `android/app/src/main/kotlin/dev/camillobucciarelli/kdbxKeyVault/autofill/`
and `android/app/src/main/res/xml/keyvault_autofill_service.xml`.

- **Secrets are released without authenticating the user.**
  `AutofillPickerActivity.selectCredential` (`AutofillPickerActivity.kt:157`)
  calls `store.readCredentialSecret(...)` and returns a filled `Dataset`
  immediately. There is no biometric prompt, no device-credential confirmation
  and no check against the app's own unlock session. Anyone holding an unlocked
  handset can open any app's login form and read out every published credential
  one field at a time. The encryption at rest (`AndroidAutofillStore`, Android
  Keystore AES-GCM) protects the file, not the release.
- **No inline suggestions.** `KeyVaultAutofillService.onFillRequest`
  (`KeyVaultAutofillService.kt:76-84`) builds a single authenticated `Dataset`
  with a `RemoteViews` presentation only. No inline presentation is attached,
  so nothing is offered on the IME suggestion strip; the user must open the
  "Autofill" dropdown on the field. Every fill therefore costs an extra tap plus
  a full-screen picker.
- **Nothing is ever saved from autofill.** `onSaveRequest`
  (`KeyVaultAutofillService.kt:91-94`) returns success without doing anything,
  and the fill response sets no `SaveInfo`, so Android never even shows the
  "Save to Custode?" bar. A credential created or rotated inside a native app
  has to be re-typed into the vault by hand.
- **Mobile browsers get no autofill.** `keyvault_autofill_service.xml` declares
  only a summary. Without compatibility-package declarations, Android's
  compatibility mode is off and browsers that render their forms in a WebView or
  their own compositor expose no fillable structure. `AssistStructureCredentialParser`
  already reads `webDomain`, and `AndroidAutofillNormalizer` already normalizes
  domain identifiers, so the matching half is in place and unused.
- **The picker is a bare `Activity` with hand-built views.** It uses
  `LinearLayout`/`ListView`/`android.R.layout.simple_list_item_1` with hard-coded
  pixel padding and no theme tokens, no focus ring and no stated tap-target
  size — outside the accessibility floor the constitution sets for user-facing
  surfaces.

What already works and is not re-litigated here: publication over the
`apple_autofill_v2` method channel, the encrypted metadata/secret split,
normalization of app packages and web domains, strong/possible matching, pending
associations written back into the vault.

## User Scenarios & Testing

### User Story 1 — Secrets are released only to the vault owner (Priority: P1)

A person picks a credential in the autofill picker. Before any password leaves
the encrypted cache, the device asks them to prove they are the vault owner
(biometric, or device PIN/pattern/password as fallback). Cancelling returns to
the form with nothing filled.

**Why this priority**: Today a stolen-but-unlocked phone yields the entire
credential set. This is the only gap in scope that makes the current state worse
than not shipping autofill at all.

**Independent Test**: Publish credentials, invoke autofill from any app, confirm
a prompt appears and that cancelling fills nothing; confirm the password never
appears in a `Dataset` handed back before a successful authentication.

**Acceptance Scenarios**:

1. **Given** published credentials and a device with biometrics enrolled,
   **When** the user taps an entry in the picker, **Then** an authentication
   prompt is shown and the field is filled only after it succeeds.
2. **Given** the same, **When** the user dismisses the prompt, **Then** no value
   is written to any field and the picker closes with no result.
3. **Given** a device with no biometric enrolled but a device lock set,
   **When** the user taps an entry, **Then** the device-credential prompt is
   used instead and success fills the fields.
4. **Given** a device with no device lock at all, **When** the user taps an
   entry, **Then** nothing is filled and the user is told that a device lock is
   required before Custode will release a password.
5. **Given** a successful authentication a moment ago, **When** the user fills a
   second field or a second form inside the reuse window, **Then** no second
   prompt is shown.

---

### User Story 2 — Suggestions appear on the keyboard (Priority: P2)

Focusing a username or password field shows matching entries directly on the
keyboard suggestion strip, labelled with title and username. Tapping one goes
straight to the authentication prompt and then fills, without the full-screen
picker.

**Why this priority**: This is the difference between autofill people use and
autofill people turn off. It depends on P1 for the authentication step.

**Independent Test**: On a device with an inline-capable IME, focus a login
field in a sample app and confirm suggestions render inline and fill correctly;
on an IME without inline support confirm the existing dropdown path still works.

**Acceptance Scenarios**:

1. **Given** two entries matching the focused app, **When** the user focuses the
   username field, **Then** both appear as inline suggestions with title and
   username, and no password text is displayed.
2. **Given** an IME that does not support inline suggestions, **When** the field
   is focused, **Then** the existing dropdown + picker path is offered unchanged.
3. **Given** more matches than the IME's advertised inline slot count,
   **When** suggestions render, **Then** the highest-ranked matches fill the
   available slots and a final "Search Custode" suggestion opens the picker.

---

### User Story 3 — Credentials typed in apps can be saved (Priority: P2)

After signing in or changing a password inside another app, Android offers to
save the credential to Custode. Accepting creates a new entry, or updates the
existing one when the same username already exists for that app or site, and the
user is told which of the two happened before it is written.

**Why this priority**: Capture is the other half of a password manager. It is
scoped after P1 because it writes to the vault and therefore inherits the
unlocked-vault and backup rules.

**Independent Test**: Type new credentials in a sample app, submit, accept the
save bar, and confirm the entry exists in the vault with the correct site
association.

**Acceptance Scenarios**:

1. **Given** the user submits a login form with a username and password not in
   the vault, **When** they accept the save prompt, **Then** a new entry is
   created with the app package (or web domain) as its association.
2. **Given** the same username already exists for that association with a
   different password, **When** the user accepts, **Then** they are shown that
   this is an update to an existing entry and the old password is preserved in
   history rather than discarded.
3. **Given** the vault is locked when the save prompt is accepted, **Then**
   Custode opens its unlock screen, and on a successful unlock the captured
   credential is written and the user is returned to where they were; on a
   cancelled unlock nothing is written and the user is told the credential was
   not saved.
4. **Given** the user declines the save prompt, **Then** nothing is written and
   they are not prompted again for the same submission.

---

### User Story 4 — Autofill works in mobile browsers (Priority: P3)

Signing in to a website in Chrome or Firefox on Android offers the same
suggestions as a native app, matched on the site's domain rather than the
browser's package name.

**Why this priority**: A large share of mobile logins are in a browser, but it
is last because it is the only story that depends on per-browser compatibility
behaviour outside the app's control.

**Independent Test**: Open a login page in each supported browser and confirm the
suggested entries are the ones associated with the page's domain, never entries
associated with the browser package.

**Acceptance Scenarios**:

1. **Given** an entry for `example.com`, **When** the user focuses the password
   field of a login form on `example.com` in a supported browser, **Then** that
   entry is suggested.
2. **Given** the same entry, **When** the user is on a different domain in the
   same browser, **Then** it is not offered as a strong match.
3. **Given** a browser whose form exposes no readable domain, **Then** no
   credential is suggested as a strong match and the picker opens in its
   existing global-search mode.

---

### Edge Cases

- Authentication prompt is invoked while the screen rotates or the source app is
  backgrounded — the pending fill is abandoned, never auto-completed later.
- The published cache is empty or stale (vault re-locked, entries deleted) at the
  moment the user authenticates — the picker reports it plainly and fills nothing.
- The focused structure has a password field but no username field (change-password
  screens) — the password alone is fillable and save capture must not require a
  username.
- Multiple password fields on one screen (new password + confirm) — filling and
  save capture must not treat "new" and "confirm" as two distinct credentials.
- A save prompt arrives for a domain the user has already declined once.
- The device has no secure lock configured at all.
- Autofill is invoked while a different Custode database is open than the one
  that published the cache.

## Requirements

### Functional Requirements

- **FR-001**: The system MUST require the user to authenticate on the device
  (biometric, with device PIN/pattern/password as fallback) before any password
  is decrypted for release into another app.
- **FR-002**: A cancelled, failed, timed-out or interrupted authentication MUST
  result in no value being written to any field, and MUST leave no decrypted
  secret in memory or in any cache.
- **FR-003**: A successful authentication MUST be reusable for a bounded window
  that follows the master-password session scope defined by spec 011; once that
  window closes or the vault session ends, the next release MUST prompt again.
- **FR-003a**: On devices with no secure lock configured, the system MUST refuse
  to release any password and MUST tell the user that a device lock is required,
  rather than failing silently.
- **FR-004**: The system MUST offer matching credentials as inline keyboard
  suggestions where the keyboard supports them, and MUST fall back to the
  existing dropdown-and-picker flow where it does not.
- **FR-005**: Inline suggestions MUST show only title and username — never a
  password, and never any other secret field.
- **FR-006**: When the number of matches exceeds the slots the keyboard offers,
  the system MUST show the highest-ranked matches and one entry point into the
  full picker.
- **FR-007**: After a login or password-change form is submitted in another app,
  the system MUST offer to save the captured credential to the vault.
- **FR-008**: On accepting a save, the system MUST distinguish "new entry" from
  "update to an existing entry" using the association and username, MUST tell
  the user which one is about to happen, and MUST preserve the previous password
  in the entry's history on update.
- **FR-009**: Saving MUST obey the existing backup-before-write and
  single-writer protections for the `.kdbx` file; it MUST NOT introduce a second
  write path around them.
- **FR-010**: When the vault is not unlocked at the moment a save is accepted,
  the system MUST present the Custode unlock screen, write the credential on
  success, and report plainly that nothing was saved if the unlock is cancelled.
  The captured credential MUST NOT be persisted anywhere while the vault is
  locked, and MUST NOT be silently dropped without telling the user.
- **FR-011**: Declining a save MUST prevent a repeat prompt for the same
  submission.
- **FR-012**: The system MUST support autofill in Chrome and Firefox on Android,
  matching on the page's domain and never on the browser's own package identity.
  Other browsers are out of scope for this spec.
- **FR-013**: When a browser exposes no readable domain for the focused form,
  the system MUST NOT present any entry as a strong match.
- **FR-014**: The picker surface MUST meet the project accessibility floor:
  ≥ 44×44 tap targets, visible focus indication, ≥ 4.5:1 text contrast in light
  and dark, and design tokens rather than hard-coded values.
- **FR-015**: No password, note, OTP URI or key-file byte may be written to a log
  line, a diagnostic string, or a plaintext file at any point in these flows.

### Key Entities

- **Credential metadata**: title, username, display service and associations —
  the only data shown before authentication.
- **Credential secret**: username and password, decrypted only after a
  successful authentication and only for the duration of one fill.
- **Captured credential**: the username/password/association triple observed at
  form submission, held only until the user accepts or declines the save.
- **Save decision**: new-entry versus update-existing, derived from association
  plus username before anything is written.

## Success Criteria

- **SC-001**: 100% of password releases into another app are preceded by a
  successful user authentication on the device.
- **SC-002**: A user can fill a saved login from the keyboard suggestion strip
  in at most two taps after focusing the field (one to choose, one to
  authenticate).
- **SC-003**: A credential typed in a native app can be captured into the vault
  without the user opening the vault app manually and re-typing it.
- **SC-004**: Logins on the supported mobile browsers offer the same matching
  entries as the equivalent native app, verified across at least three sites.
- **SC-005**: No password value appears in any log output, crash report, or
  plaintext file produced by these flows, verified by inspection of the
  redaction tests.
- **SC-006**: An interrupted or cancelled autofill never leaves a partially
  filled form or a leftover decrypted secret.

## Assumptions

- The published-cache design (encrypted secrets, plaintext-safe metadata,
  publication over the existing method channel) stays as it is; this spec adds
  a gate in front of it, not a replacement for it.
- Save capture reuses the existing vault write path and its backup rules rather
  than introducing a new writer.
- Passkeys and Credential Manager are out of scope; this spec covers
  password/username autofill only.
- OTP/one-time-code field filling is out of scope for this spec.
- Android versions below the platform's inline-suggestion support continue on
  the existing dropdown path with no regression.
- Apple and desktop autofill behaviour is untouched.

## Resolved decisions

Recorded 2026-08-28, applied as defaults with the user proceeding.

- **SD1 — Authentication policy**: prompt once, then reuse for a bounded window
  tied to the spec 011 master-password session scope (FR-001, FR-003). A device
  with no secure lock configured is refused outright (FR-003a) rather than
  served with a warning, because a released password on such a device has no
  protection at all.
- **SD2 — Save while locked**: open the Custode unlock screen and write on
  success (FR-010). Rejected: an encrypted pending-capture store, which would
  create a second at-rest secret surface for a case the unlock screen already
  covers (Constitution VIII).
- **SD3 — Browser scope**: Chrome and Firefox only (FR-012). A broader
  compatibility list rots and multiplies per-browser verification; more browsers
  are a follow-up once the two are proven.
