# 023 — Validation quickstart

How to prove slices 1 and 2 work. Sections A–C run on any desktop build;
D–F need the named platform and are recorded in `device-evidence.md`.

## Prerequisites

- KeePassXC ≥ 2.7.7 with the browser integration enabled.
- A vault `passkeys-qa.kdbx` created in KeePassXC holding:
  - `E1`: a passkey registered on https://webauthn.io (ES256), no password;
  - `E2`: a password entry for https://webauthn.io with the same username as E1;
  - `E3`: an entry with a passkey **and** a password (register on
    https://passkeys.io, then add a password);
  - `E4`: a copy of E1 whose `KPEX_PASSKEY_PRIVATE_KEY_PEM` was truncated by
    hand in KeePassXC (the "unusable" case).
- `flutter analyze` clean and `flutter test` green on the branch.

```bash
fvm flutter run --dart-define-from-file=.env.dart.define.json -d macos
```

## A — Hold (US1, storage)

1. Open `passkeys-qa.kdbx`. **Expect**: E1, E3, E4 carry the passkey badge in
   the list; E2 does not.
2. Open E1. **Expect**: a passkey section naming `webauthn.io` and the
   username, the algorithm, the creation date, the fixed note on vault
   security; no PEM, no copy action on any passkey value; the custom-field
   list shows no `KPEX_` key.
3. Open E4. **Expect**: shown as a passkey that cannot be used for sign-in,
   with the reason.
4. Edit E1's title only, save, reopen in KeePassXC. **Expect**: KeePassXC still
   lists the passkey and signs in with it on webauthn.io; the seven `KPEX_`
   attributes are byte-identical and the three secret ones still protected
   (inspect in KeePassXC's entry attributes with "Protect" state visible).
5. Open E1's history after step 4. **Expect**: one revision, "passkey" not
   among the changed fields, no PEM anywhere in the history screen.

## A2 — Secret custom fields (US1b)

1. In KeePassXC add to E2 a custom attribute `Recovery` with "Protect"
   enabled. Open E2 in Custode. **Expect**: the field is masked with a reveal
   control; the editor shows its "Secret" toggle on.
2. Edit E2's title only, save, reopen in KeePassXC. **Expect**: `Recovery` is
   still protected (SC-008).
3. In Custode add a custom field `PIN`, toggle Secret on, save. **Expect**:
   KeePassXC shows it protected.
4. Reveal and copy `PIN` in the detail. **Expect**: the same gate as the
   password on a biometric-protected database, the same auto-hide, the same
   clipboard clearing toast.
5. Turn Secret off on `Recovery`, save. **Expect**: a confirmation saying the
   field will no longer be protected; afterwards KeePassXC shows it plain.

## B — Delete (US1, destructive path)

1. Delete E3's passkey. **Expect**: a confirmation stating it cannot be
   recovered; a dated backup on disk after confirming; E3 keeps its password
   and other fields; KeePassXC opens the file and shows no passkey on E3.
2. Lock the vault from another window, retry a delete. **Expect**: refused,
   reason stated, no backup written.

## C — Duplicates (FR-011a)

1. Open Vault health → duplicates. **Expect**: E1 + E2 offered as "same
   account, one holds the passkey, one the password".
2. Merge, keeping E2 as primary. **Expect**: confirmation names the passkey
   that moves; backup written; E2 now shows the badge and section; E1 is in
   the recycle bin; sign-in from KeePassXC with the merged entry still works.
3. Import a CSV whose header includes `KPEX_PASSKEY_PRIVATE_KEY_PEM`.
   **Expect**: the column is rejected with a warning, nothing imported under
   that key.

## D — Apple sign-in (US2)

iOS and macOS, each recorded separately.

1. Unlock the vault in Custode, then background it. In Safari open
   https://webauthn.io, type the username, choose "Authenticate".
   **Expect**: Custode listed; selecting it asks Face ID / Touch ID / passcode
   **every time**, then the site reports success. Under 15 s (SC-003).
2. Cancel the biometric prompt. **Expect**: the site shows a cancellation, not
   a "credential not found".
3. On https://passkeys.io, where only E3 matches. **Expect**: only E3 offered.
4. Lock the database in Custode, retry step 1. **Expect**: Custode offers
   nothing for the site (cache wiped, FR-023).
5. On https://webauthn.io choose "Register" and pick Custode as the place to
   save the passkey (spec 023 T708). **Expect**: a screen saying the passkey is
   created in the Custode app, naming the site and the account; dismissing it
   leaves the site reporting a **failed** registration, never a successful one,
   and the vault unchanged — check that no new passkey appears on any record.
   **Must not**: a blank sheet, a hang, or the site reporting success.

## E — Android sign-in (US2)

1. API 34+ device: Settings → Passwords & accounts → set Custode as a
   passkey provider. Chrome → https://webauthn.io → Authenticate.
   **Expect**: Custode's entry appears; biometric or device credential is
   asked every time; success.
2. API 29–33 device: open Custode settings. **Expect**: the passkey row says
   it is not available on this device; the provider does not appear in system
   settings.
3. Repeat D.2 and D.4 on Android.

## F — Desktop sign-in (US2), Windows and Linux

1. Extension installed, host permission granted for webauthn.io, app unlocked.
   https://webauthn.io → Authenticate. **Expect**: the app raises a
   confirmation naming the site and username; after confirming the site
   reports success.
2. Decline the confirmation. **Expect**: the site sees a cancellation.
3. Lock the app, retry. **Expect**: the browser's own passkey dialog appears
   (the wrapper fell through), no Custode prompt.
4. A site with no matching passkey. **Expect**: browser's own dialog only.
5. Run with the previous native host build. **Expect**: same as 3 — the old
   host answers `unsupported_type` and nothing is offered.

## G — Redaction sweep (SC-002)

```bash
fvm flutter test test/features/password_manager/domain/models/vault_passkey_test.dart
grep -rn "BEGIN PRIVATE KEY" lib desktop tool android/app/src ios/CredentialProviderExtension macos/CredentialProviderExtension
```

The grep must hit only `passkey_generator.dart`'s PEM header constant — the one
place the app writes a header, and the only production use of the phrase. A hit
in a test fixture is a finding, not noise: it is also what the secret scanners
flag, so fixtures carry a non-PEM marker instead. Then run each
platform flow with verbose logging on and search the captured logs for
`PRIVATE KEY`: zero hits.

---

# Passkeys on every platform (draft spec 024)

Sections H–L and Web prove creation outside the desktop browser, adoption into
the vault, Ed25519 sign-in on Windows and Linux, and every failure-mode row of
`specs/DRAFT-passkeys-all-platforms.md`. Each step is recorded in
`device-evidence.md` under the section of the same letter.

On a build that carries these sections, D.5 (the registration refusal) no
longer describes the expected behaviour on Apple platforms: run I and J
instead and leave D.5 to builds without creation.

## Prerequisites for H–L

- Everything under "Prerequisites" above, plus:
  - `E5`: an **Ed25519** passkey written by KeePassXC (register on a relying
    party with only EdDSA offered; Custode's passkey section on E5 must name
    the algorithm as Ed25519). Used by K.
  - A second vault `passkeys-qa-b.kdbx` with no passkeys. Used by L.3 and L.4.
- **Android device builds**: `android/key.properties` pointing at a keystore
  is required to package an APK. Both the debug and the release build type
  sign with the `upload` config in `android/app/build.gradle.kts`, so without
  that file neither `fvm flutter build apk` nor `fvm flutter run` produces an
  installable package.
- A release-configuration build on the phones (T028, T030). L.6 and L.10 need
  access to the queue files and therefore a debuggable Android build
  (`adb shell run-as dev.camillobucciarelli.kdbxKeyVault`), the Mac's
  `~/Library/Group Containers/group.dev.camillobucciarelli.kdbxKeyVault/`, or
  on iOS a development build with Xcode's Devices window (download and replace
  container). State in the row which build was used.
- Relying parties: https://webauthn.io, https://passkeys.io,
  https://webauthn.me. Use a **fresh username per step** (for example
  `qa-h2-<date>`) unless the step says otherwise: reusing E1's username on
  webauthn.io turns a plain creation into the clash of L.7.
- "The vault is published" below means: Custode unlocked on `passkeys-qa.kdbx`
  and not locked since, then sent to the background. Creation and sign-in are
  only available in that window (FR-6, FR-10).
- The queue lives at `passkey_pending_v1/<recordId>.sealed.json`: on Android
  under the app's `files/autofill_v2/`, on Apple in the App Group container.
- Capture verbose logs during every run (`adb logcat`, Console.app): section G
  and SC-4 search them for `PRIVATE KEY` afterwards.

## H — Android create (US3, US4, US5), API 34+

Device A1. Vault published before every step unless stated.

1. Custode → Settings. **Expect**: the "Passkeys" row reads "Sign in and
   create passkeys through Android's system credential provider: turn Custode
   on in Android's passkey settings. A passkey created outside the app is kept
   on this device and added to the vault when Custode is next opened and
   unlocked; until then it exists only on this device." Then turn Custode on in
   Android Settings → Passwords, passkeys & accounts. **Expect**: Custode is
   listed as a provider and stays enabled.
2. Chrome → https://webauthn.io → fresh username → "Register". **Expect**:
   Custode is offered in the system "create passkey" sheet; choosing it shows
   "Create a passkey?" with "Save a passkey for <username> on webauthn.io in
   Custode." and the buttons Create / Cancel; Create raises the device prompt
   (biometric or device credential) with the subtitle "Custode is about to
   create a new passkey."; then "Passkey saved on this device" with "The
   passkey is saved on this device and will be added to your vault when you
   open Custode. Until then it exists only on this device."; after OK the site
   reports a successful registration. Repeat once with another username.
   **Expect**: the device prompt is asked again, no reuse window (SR-3).
3. Start a registration as in 2 and press Cancel on "Create a passkey?"; start
   another and cancel the device prompt. **Expect**: both times the site shows
   a cancellation, not a generic failure and never a success; opening Custode
   afterwards shows no passkey waiting for those usernames.
4. Sign-in after the clientDataHash fix. Chrome → https://webauthn.io → E1's
   username → "Authenticate" → Custode's entry → device prompt. **Expect**: the
   site reports a **verified** sign-in. Chrome supplies its own
   `clientDataHash`; a site message about an invalid signature or failed
   verification is a `fail` of this step even though Custode showed no error.
   Repeat on https://passkeys.io with E3.
5. Sign in before opening Custode (US5, SC-1). Do not open Custode after
   step 2. Chrome → https://webauthn.io → the username of step 2 →
   "Authenticate". **Expect**: Custode offers the passkey created in step 2,
   asks the device prompt, and the site reports a verified sign-in.
6. Open Custode; if it shows the unlock screen, unlock. **Expect**: on the
   unlock screen, a notice "N passkeys are waiting" ("1 passkey is waiting"
   for one) with "Created on this device and not yet in your vault. Unlock to
   add them. Until then they exist only on this device."; after unlock, with
   no action from the user, one message per passkey "Passkey for webauthn.io
   (<username>) was added to your vault. A backup was saved as <file>."; the
   named backup file exists and is dated before the vault's modification time;
   a record for webauthn.io carries the passkey badge and section; Settings no
   longer shows the "Passkeys waiting" row. If Custode was still unlocked the
   notice is skipped and adoption runs on resume: record which case was seen.
7. Background Custode, repeat step 5. **Expect**: verified sign-in, now from
   the vault copy (SC-1, after adoption).
8. Copy the vault file to a desktop, open it in KeePassXC and sign in on
   https://webauthn.io with the username of step 2 through KeePassXC's browser
   integration. **Expect**: KeePassXC lists the passkey and the site reports a
   verified sign-in (SC-2).
9. Repeat steps 2 and 5 to 8 on https://passkeys.io. **Expect**: as each step.
10. Repeat steps 2 and 5 to 8 on https://webauthn.me. **Expect**: as each step.
11. Native app. In an installed app that registers passkeys through Credential
    Manager (not a browser, not a WebView; none of the three relying parties
    ships one, so name the app and its version in the row), create a passkey
    with Custode, sign in with it before opening Custode, then repeat steps 6
    and 7 in that app. **Expect**: the same dialogs as step 2 naming the app's
    relying party; the app reports success both before and after adoption.
12. https://webauthn.io → Advanced Settings → leave only a non-ES256 algorithm
    ticked → "Register" → Custode. **Expect**: no "Create a passkey?" dialog
    and no device prompt; the request fails or falls to another provider;
    nothing is waiting in Custode afterwards (FR-4). If the page offers no
    such option, say so in the row instead of a verdict.

## I — iOS create (US1, US4, US5)

Device I1. Vault published before every step unless stated. The extension's
exact wording is not fixed here: where a step says "see extension UI", compare
against the strings in `ios/CredentialProviderExtension/CredentialListView.swift`
and copy what was shown into the row.

1. iOS Settings → General → AutoFill & Passwords: enable Custode. Custode →
   Settings. **Expect**: the "Passkeys" row reads "Sign in and create passkeys
   through AutoFill. A passkey created outside the app is kept on this device
   and added to the vault when Custode is next opened and unlocked; until then
   it exists only on this device."
2. Safari → https://webauthn.io → fresh username → "Register" → choose
   Custode. **Expect**: a sheet naming the site and the account (see extension
   UI); Face ID, Touch ID or passcode is asked; the sheet then says the passkey
   is saved on this device and will be added to the vault when Custode is
   opened (see extension UI); the site reports a successful registration.
   Repeat once with another username. **Expect**: the device prompt is asked
   again.
3. Start a registration and cancel the sheet; start another and cancel Face
   ID. **Expect**: both times the site shows a cancellation, never a success;
   nothing is waiting in Custode for those usernames.
4. Sign in before opening Custode (US5, SC-1). Safari → https://webauthn.io →
   the username of step 2 → "Authenticate". **Expect**: Custode offers the
   passkey of step 2, asks Face ID, Touch ID or passcode, and the site reports
   a verified sign-in.
5. Open Custode; if it shows the unlock screen, unlock. **Expect**: as H.6
   (waiting notice before unlock, message naming webauthn.io and the username
   with the backup file name after unlock, backup on disk, badge and section
   on the record, no "Passkeys waiting" row left).
6. Background Custode, repeat step 4. **Expect**: verified sign-in after
   adoption.
7. Copy the vault to a desktop, open it in KeePassXC and sign in on
   https://webauthn.io with the username of step 2. **Expect**: verified
   sign-in from KeePassXC (SC-2).
8. Repeat steps 2 and 4 to 7 on https://passkeys.io. **Expect**: as each step.
9. Repeat steps 2 and 4 to 7 on https://webauthn.me. **Expect**: as each step.
10. From an app. In an installed app that registers passkeys natively (not
    Safari, not an in-app browser; name the app and its version in the row),
    create a passkey with Custode, sign in with it before opening Custode,
    then repeat steps 5 and 6 in that app. **Expect**: the same sheet naming
    the app's relying party; the app reports success before and after
    adoption.
11. https://webauthn.io → Advanced Settings → leave only a non-ES256 algorithm
    ticked → "Register" → Custode. **Expect**: a refusal with the reason (see
    extension UI), no Face ID prompt, the site reports a failure, nothing is
    waiting afterwards (FR-4). If the page offers no such option, say so in
    the row instead of a verdict.

## J — macOS create (US2, US4, US5)

Device M1, Safari. Same "see extension UI" rule as section I, against
`macos/CredentialProviderExtension/CredentialListView.swift`.

1. System Settings → General → AutoFill & Passwords: enable Custode. Custode →
   Settings. **Expect**: the same "Passkeys" row text as I.1.
2. **Custode running**, unlocked, in the background. Safari →
   https://webauthn.io → fresh username → "Register" → choose Custode.
   **Expect**: as I.2 with Touch ID or the account password; the site reports
   a successful registration. Do not bring Custode to the front yet.
3. **Custode not running**: unlock the vault, then quit Custode (Cmd-Q).
   Safari → https://webauthn.io → another fresh username → "Register" →
   choose Custode. **Expect**: as step 2, with Custode still not running
   afterwards (check Activity Monitor: the extension must not start the app).
   If the sheet says Custode must be opened and unlocked first, quitting wiped
   the cache: that is a `fail` of US2, record the text shown.
4. Start a registration and cancel the sheet; start another and cancel Touch
   ID. **Expect**: both times the site shows a cancellation, never a success.
5. Sign in before opening Custode (US5, SC-1), Custode still not running.
   Safari → https://webauthn.io → the username of step 3 → "Authenticate".
   **Expect**: Custode offers the passkey of step 3, asks Touch ID or the
   password, and the site reports a verified sign-in. Repeat with the username
   of step 2.
6. Launch Custode and unlock. **Expect**: as H.6, with one "was added to your
   vault" message and one backup for each of the two passkeys of steps 2 and 3.
7. Repeat step 5 once with Custode in the background and once after quitting
   it. **Expect**: verified sign-in after adoption in both cases.
8. Open the vault in KeePassXC and sign in on https://webauthn.io with the
   usernames of steps 2 and 3. **Expect**: verified sign-in from KeePassXC
   (SC-2).
9. Repeat steps 2 and 5 to 8 on https://passkeys.io. **Expect**: as each step.
10. Repeat steps 2 and 5 to 8 on https://webauthn.me. **Expect**: as each step.
11. From an app. In an installed app that registers passkeys natively (name
    the app and its version in the row), create a passkey with Custode, sign
    in before opening Custode, then repeat steps 6 and 7 in that app.
    **Expect**: success before and after adoption.
12. https://webauthn.io → Advanced Settings → leave only a non-ES256 algorithm
    ticked → "Register" → Custode. **Expect**: as I.11.
13. Regression, creation through the browser extension (T029). Chrome with the
    Custode extension, app unlocked → https://webauthn.io → fresh username →
    "Register". **Expect**: the app raises its own confirmation naming the
    site and the username; after confirming the site reports success, the
    passkey is in the vault at once (no waiting notice, no "Passkeys waiting"
    row) and a sign-in as F.1 succeeds.

## K — Ed25519 sign-in through the browser extension (US9, US10), Windows and Linux

Devices W1 and L1, each recorded separately. Extension installed, host
permission granted for the relying party of E5, app unlocked on
`passkeys-qa.kdbx`.

1. Custode → Settings. **Expect**: the "Passkeys" row reads "Passkeys work in
   browsers through the Custode extension only: there is no system-level
   passkey provider on this platform"; no "Passkeys waiting" row.
2. Open E5. **Expect**: the passkey section names the algorithm as Ed25519 and
   does **not** show it as a passkey that cannot be used for sign-in.
3. The relying party of E5 → "Authenticate" with E5's username. **Expect**:
   the app raises the confirmation naming the site and the username; after
   confirming, the site reports a **verified** sign-in (the Ed25519 signature
   verifies at the relying party). Run it on https://webauthn.io if E5 was
   registered there; otherwise name the relying party in the row.
4. Repeat step 3 and decline the confirmation. **Expect**: the site sees a
   cancellation; no signature is produced.
5. Regression, creation (T031). https://webauthn.io → fresh username →
   "Register". **Expect**: the app's confirmation naming site and username;
   after confirming the site reports success; the new passkey's section names
   ES256 (creation stays ES256); a sign-in as F.1 succeeds; the file opens in
   KeePassXC, which lists the passkey.

## L — Failure modes (US4 to US8, SC-3)

Each step runs on I1, M1 and A1 and is recorded per device. Wording quoted
below is the app's (Dart) or Android's; on Apple, sheet wording is "see
extension UI". After **every** step, check SC-3: the passkey is either in the
vault, still waiting, or was discarded on an explicit confirmation. Any other
ending is a `fail`.

1. App never opened afterwards. Create a passkey on https://webauthn.io (H.2,
   I.2 or J.3) and do not open Custode. Sign in at once, and again at least
   ten minutes later. **Expect**: both sign-ins verify, served from the queue.
   Then force-quit Custode and launch it. **Expect**: before unlock, "1
   passkey is waiting" with "Created on this device and not yet in your vault.
   Unlock to add them. Until then they exist only on this device."; after
   unlock the passkey is adopted as H.6.
2. Vault locked at creation. Lock the vault in Custode. https://webauthn.io →
   "Register" → Custode. **Expect**, Android: "Custode is locked" with "Open
   and unlock Custode, then try again." and the buttons Open Custode / Cancel;
   no device prompt. Apple: the sheet says Custode must be opened and unlocked
   first (see extension UI). On every platform the site reports a **failure**,
   never a success, and Custode shows no waiting notice afterwards (nothing
   was generated). On Android also tap "Open Custode". **Expect**: the app
   opens on its unlock screen and is not unlocked for the user.
3. A different vault is open, then move. Create a passkey on
   https://webauthn.io with `passkeys-qa.kdbx` published. In Custode close it
   and unlock `passkeys-qa-b.kdbx`. **Expect**: a dialog "A passkey for
   webauthn.io belongs to another vault" saying it "was created for a
   different vault than this one, so it was not added here", with Decide later
   / Discard / Move to this vault; nothing written so far (no new backup). The
   failure-mode row asks for the owning vault to be **named**: record whether
   the dialog names it. Choose "Decide later". **Expect**: nothing changes and
   Settings shows a "Passkeys waiting" row starting "1 on this device". Lock, unlock B again,
   choose "Move to this vault", then cancel the confirmation "Move this
   passkey to this vault?". **Expect**: still waiting. Repeat and confirm.
   **Expect**: a dated backup of B, the "was added to your vault" message,
   the passkey on a record in B, a verified sign-in on webauthn.io, and
   `passkeys-qa.kdbx` unchanged.
4. A different vault is open, then discard. Set up as step 3 with a new
   passkey. Choose "Discard", then cancel "Discard this passkey?". **Expect**:
   still waiting. Repeat and confirm with "Discard passkey". **Expect**: "The
   waiting passkey for webauthn.io was discarded."; neither vault changed, no
   backup written; with `passkeys-qa.kdbx` published again, webauthn.io →
   "Authenticate" no longer offers that passkey.
5. Vault changed by sync before adoption. With a synced vault, create a
   passkey on https://webauthn.io and do not open Custode. On a second device
   add a record to the same vault and let it sync. Open and unlock Custode on
   the first device. **Expect**: the passkey is adopted as H.6 with nothing
   extra shown, and the record added on the second device is present; after
   the next sync the second device shows the passkey too.
6. Duplicate `(rpId, credentialId)` already in the vault (replay). Create a
   passkey on https://webauthn.io. Before opening Custode, copy its
   `passkey_pending_v1/<recordId>.sealed.json` aside. Open and unlock Custode
   so the passkey is adopted, note the backup files present, lock, put the
   copied file back, unlock. **Expect**: no message, no new backup, no second
   passkey and no second record for webauthn.io; the restored file is gone
   from the queue directory; sign-in still verifies.
7. Clash on the same account, replace. Needs a relying party that keeps one
   account across two passkeys: sign in to an account on https://passkeys.io
   whose passkey is already in the vault, remove that passkey **at the site
   only** (account or profile page), then register a new passkey for the same
   account with Custode. **Expect** at creation: the warning that Custode
   already has a passkey for this account and that creating another keeps both
   (Android: "Custode already has a passkey for this account on this site.
   Creating another one keeps both."). If the site still excludes the old
   credential, **expect** instead a refusal (Android: "This account already
   has a passkey saved in Custode for passkeys.io.") and a failed registration
   at the site, then record that and stop. Open and unlock Custode.
   **Expect**: a dialog "Replace the passkey for passkeys.io?" naming the
   account and the site and stating that a dated backup is saved first, with
   Decide later / Replace old passkey / Keep both, and nothing written until a
   choice is made. Choose "Replace old passkey". **Expect**: a backup taken
   before the change; exactly one passkey for that account, the new one; the
   old one is present in the backup; sign-in on passkeys.io verifies.
8. Clash on the same account, keep both. Set up as step 7. First choose
   "Decide later". **Expect**: nothing written, still waiting, the question
   returns on the next unlock. Then choose "Keep both". **Expect**: a backup;
   the new passkey on a **new** record; the old record and its passkey
   untouched; sign-in on passkeys.io verifies with the new one.
9. Vault write fails. Create a passkey on https://webauthn.io. Make the vault
   unwritable before unlocking (macOS: `chmod a-w` on the file and its folder;
   on the phones use a vault location that can be made read-only, and state in
   the row how). Unlock. **Expect**: "Unable to add the passkey for
   webauthn.io (<username>). It is still waiting and nothing was deleted.",
   followed by "The backup <file> was kept." when a backup was written; the
   vault file is byte-identical to before; Settings still shows the passkey
   waiting; sign-in still verifies from the queue. Make the vault writable,
   lock and unlock. **Expect**: adopted as H.6 (retried on the next unlock).
10. Unreadable record. Create two passkeys on https://webauthn.io. Before
    opening Custode, edit one queue file and change the `databaseId` value in
    its plaintext envelope by one character. **Expect** at the site, before
    opening Custode: the tampered passkey is not offered for sign-in, the
    other is. Open and unlock. **Expect**: the untouched passkey is adopted;
    "1 waiting passkey could not be read."; the tampered file is **still on
    disk** after a lock and a second unlock (never deleted automatically). The
    failure-mode row also asks for a discard action behind a confirmation:
    record whether one is offered and, if so, that it deletes the file only
    after confirming.
11. Lock wipes the cache while the queue survives. Create a passkey on
    https://webauthn.io and confirm one sign-in from the queue. Lock the vault
    in Custode. webauthn.io → "Authenticate". **Expect**: Custode offers
    nothing for the site, neither vault passkeys nor the waiting one. Check
    the queue directory. **Expect**: the `.sealed.json` file is still there.
    Open Custode. **Expect**: "1 passkey is waiting" before unlock; after
    unlock it is adopted as H.6 and signs in again.
12. Device-only warning (device lost, app removed or app data cleared before
    adoption). Read the creation result sheet, the unlock-screen notice and
    the Settings "Passkeys" row. **Expect**: each states that until Custode is
    opened and unlocked the passkey exists only on this device. On A1 only,
    with a throwaway passkey on https://webauthn.io: clear Custode's app data
    before adoption. **Expect**: the passkey is gone, the site offers nothing
    from Custode, and no vault file was touched; this loss is by design
    (conflict 1) and is not a `fail`.

## Web (T025)

Any desktop with Chrome; record the browser version in the row.

```bash
fvm flutter run -d chrome --dart-define-from-file=.env.dart.define.json
```

1. Open `passkeys-qa.kdbx`. **Expect**: E1, E3 and E4 carry the passkey badge
   in the list and each shows its passkey section, as A.1 to A.3. Record
   exactly what is shown if it differs.
2. Delete E3's passkey as in B.1. **Expect**: the confirmation; the dated
   backup written before the change (record where it lands on web, or that
   none is written); E3 keeps its password; the saved or downloaded file
   opens in KeePassXC with no passkey on E3. If the delete or its backup
   fails, open an ordinary issue and link it in the row.
3. Settings. **Expect**: the "Passkeys" row reads "Not available: a web page
   cannot act as a passkey provider"; no "Passkeys waiting" row; no create or
   sign-in affordance anywhere.
