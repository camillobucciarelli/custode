# 023 — Validation quickstart

How to prove slices 1 and 2 work. Sections A–C run on any desktop build;
D–F need the named platform and are recorded in `device-evidence.md`.
Sections H–J prove slice 4 (creating on Android and macOS, Ed25519 sign-in on
Windows and Linux); they need the named platform too and have their own rows.

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
   Since slice 4 this step holds as written on iOS only. On macOS it holds
   with Custode closed or the vault locked; with Custode open and unlocked the
   registration goes through, and section I covers it.

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

## H — Android create (US4), API 34+

Device A1, with Custode set as a passkey provider (E.1), a screen lock and a
biometric enrolled, and a copy of `passkeys-qa.kdbx` opened in Custode. Use a
username that the vault has never seen for each step that says "new username",
and write the usernames down: step 10 looks for them.

The rules every step checks: creating needs Custode running and unlocked; the
biometric or device credential is asked every time; the site reports success
only after the vault file holds the passkey; nobody is asked which record to
use.

1. Custode open and unlocked, then sent to the background. Chrome →
   https://webauthn.io, new username `qa-h1`, "Register". **Expect**: Android's
   sheet offers Custode as a place to save the passkey; choosing it opens a
   Custode screen naming `webauthn.io` and `qa-h1`, with no replacement
   warning; the biometric or device credential is asked; only then does the
   site report success.
2. Open Custode. **Expect**: a new record titled with the site, with
   `webauthn.io` as its website and `qa-h1` as its username, carrying the
   passkey badge; its passkey section says ES256 and today's date; a dated
   backup of the vault from before the write is on the device.
3. In Custode add a record with website `https://webauthn.io`, username
   `qa-h3`, a password and no passkey. Send Custode to the background and
   register `qa-h3` on webauthn.io. **Expect**: success after the biometric;
   the passkey is on the record just added, which keeps its password; no new
   record was created.
4. App closed: swipe Custode out of the recent apps. Register a new username
   `qa-h4`. **Expect**: the Custode screen says Custode must be open and
   unlocked and offers "Open Custode"; the site is still waiting and has
   reported nothing. Tap "Open Custode", unlock the vault, go back to the
   registration screen. **Expect**: it continues by itself with the
   confirmation and the biometric; the site reports success; the vault holds
   a record for `qa-h4`.
5. Vault locked: with Custode running, lock the vault. Register a new username
   `qa-h5`. **Expect**: the screen says the vault is locked and offers "Open
   Custode"; after unlocking and going back, the same outcome as step 4.
6. Repeat step 5 with a new username `qa-h6`, but dismiss the screen instead
   of opening Custode. **Expect**: the site reports no success; after
   unlocking, no record and no passkey for `qa-h6`, and no new backup.
7. Replacement: Custode open and unlocked. Register `qa-h1` again, so the site
   sends the same account. If webauthn.io refuses a second registration for
   one username, use a site that allows it and record which one. **Expect**:
   before the biometric, a warning that the record already holds a passkey for
   this site and account and that the old one cannot be recovered; after
   confirming and authenticating, the site reports success; the record of
   step 2 still holds exactly one passkey for the site, with the new date, and
   no second record was created.
8. Cancel, twice. Register a new username `qa-h8` and cancel the biometric
   prompt. **Expect**: the site shows a cancellation, not an error; no record
   for `qa-h8`, no new backup. Then register `qa-h1` once more and cancel at
   the replacement warning. **Expect**: a cancellation again, and the passkey
   of step 7 is untouched (step 9 proves it still works).
9. Sign in: webauthn.io → "Authenticate" with `qa-h1`, then with `qa-h3` and
   `qa-h4`. **Expect**: Custode is offered each time, the biometric or device
   credential is asked each time, and the site reports success for all three.
10. Copy the `.kdbx` to a desktop and open it in KeePassXC. **Expect**: the
    records for `qa-h1`, `qa-h3`, `qa-h4` and `qa-h5` each show a passkey
    (Database → Passkeys lists them); their `KPEX_PASSKEY_*` attributes are
    present and the secret ones are protected; nothing exists for `qa-h6` or
    `qa-h8`; KeePassXC signs in on webauthn.io as `qa-h1`.
11. On a site that asks for a key type other than ES256 only (webauthn.io
    with ES256 turned off in its advanced settings, when it offers that),
    choose "Register". **Expect**: Custode is not offered as a place to save
    the passkey, and the vault is unchanged.

## I — macOS create (US4), and iOS still refusing

Device M1, with Custode enabled as a passkey provider in System Settings and
`passkeys-qa.kdbx` open in Custode. Safari throughout. The rules are those of
section H, with one difference: on macOS nothing offers to open Custode and
continue. With the app closed or the vault locked the attempt is refused and
is started again by hand.

1. Custode open and unlocked. Safari → https://webauthn.io, new username
   `qa-i1`, "Register", choose Custode. **Expect**: a confirmation naming
   `webauthn.io` and `qa-i1`, with no replacement warning; Touch ID or the
   account password is asked; only then does the site report success.
2. Look at Custode. **Expect**: a new record titled with the site, website
   `webauthn.io`, username `qa-i1`, passkey badge, section saying ES256 and
   today's date; a dated backup from before the write is on disk.
3. Add a record with website `https://webauthn.io`, username `qa-i3`, a
   password and no passkey, then register `qa-i3`. **Expect**: success after
   the authentication; the passkey is on that record, which keeps its
   password; no new record.
4. App closed: quit Custode. Register a new username `qa-i4`. **Expect**: the
   refusal screen, saying that Custode must be open and unlocked; the site
   reports a failed registration, never a success. Open Custode, unlock:
   **expect** no record for `qa-i4`. Register `qa-i4` again. **Expect**: it
   now goes through as in step 1.
5. Vault locked: lock the vault and leave Custode running. Register a new
   username `qa-i5`. **Expect**: the same refusal and the same failure on the
   site; after unlocking, no record for `qa-i5` and no new backup.
6. Replacement: Custode open and unlocked, register `qa-i1` again (same note
   as H.7 on a site that allows it). **Expect**: the confirmation carries the
   warning that the existing passkey for this site and account is replaced
   and cannot be recovered, before the authentication; afterwards the site
   reports success, the record of step 2 holds exactly one passkey for the
   site with the new date, and no second record exists.
7. Cancel, twice. Register a new username `qa-i7` and cancel Touch ID.
   **Expect**: the site shows a cancellation; no record for `qa-i7`, no new
   backup. Then register `qa-i1` once more and cancel at the replacement
   warning. **Expect**: a cancellation, and the passkey of step 6 untouched.
8. Sign in: "Authenticate" as `qa-i1`, `qa-i3` and `qa-i4`. **Expect**:
   Custode offered, Touch ID or the password asked every time, success for
   all three.
9. Open the `.kdbx` in KeePassXC. **Expect**: `qa-i1`, `qa-i3` and `qa-i4`
   each show a passkey with protected secret attributes; nothing exists for
   `qa-i5` or `qa-i7`; KeePassXC signs in on webauthn.io as `qa-i1`.
10. iOS, device I1, Custode open and unlocked: Safari → webauthn.io, new
    username `qa-i10`, "Register", choose Custode. **Expect**: exactly D.5:
    the refusal screen, a failed registration on the site, and no record or
    passkey for `qa-i10` in the vault.

## J — Ed25519 sign-in (US4), Windows and Linux

Each system recorded separately. Extension installed, host permission granted
for the site, app unlocked, as in section F.

Custode creates ES256 passkeys only, so the Ed25519 one comes from another
client. Add to `passkeys-qa.kdbx` an entry `E5`: a passkey registered from
KeePassXC (or another client that makes Ed25519 keys) on a site that accepts
EdDSA, for example https://webauthn.io with EdDSA as the only algorithm
selected at registration. Step 1 checks that the key really is Ed25519; if it
is not, the rest of the section proves nothing.

1. Open the vault and open E5. **Expect**: the passkey section says key type
   "EdDSA (Ed25519)", with no "Unusable" tag and no line saying it cannot be
   used on this platform.
2. Browser → the site of E5 → "Authenticate" with E5's username. **Expect**:
   the app raises the confirmation naming the site and the username; after
   confirming, the site reports success.
3. Repeat step 2 and decline the confirmation. **Expect**: the site sees a
   cancellation, and no sign-in.
4. Lock the app and retry. **Expect**: the browser's own passkey dialog, no
   Custode prompt.
5. Unlock and sign in on webauthn.io with E1 (ES256). **Expect**: success as
   in F.1: the Ed25519 path took nothing from the ES256 one.
6. Run step 2 once with verbose logging and search the log for `PRIVATE KEY`.
   **Expect**: zero hits in a log that is not empty.
