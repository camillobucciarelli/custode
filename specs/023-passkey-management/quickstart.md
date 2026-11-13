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
