# 023 — Device evidence

Hardware observations for the tasks that cannot be proven any other way. Fill a
row in, state `pass` or `fail` explicitly, and record the versions: a verdict
without the OS and browser version is not evidence.

The owner-acceptance marker `accepted by owner 2026-11-15, not tested` (see the section below) is not a verdict: it records that the owner accepted a row without a run, and it is never `pass`.

Nothing here is filled in by an agent. Every line is something someone watched
happen on a device. The rows below are the empty ledger; the tasks that consume
it are T212 (KeePassXC round trip), T601 (redaction sweep) and T603 (the full
quickstart run).

## Owner acceptance, 2026-11-15

By owner decision on 2026-11-15, the repository owner accepted the device and manual tasks of spec 024 (issue #253) listed below WITHOUT their device or manual test having been executed. No result in this file was observed on a device. Every row marked `accepted by owner 2026-11-15, not tested` is accepted, not tested. A row keeps the marker until someone runs that step on the named device and overwrites it with the device, versions, date, observation and a `pass` or `fail` verdict.

Spec 024 tasks covered, and the rows each one accounts for:

- T007 (T212): the four rows of the T212 table.
- T018, T019 (Apple create and pending sign-in): sections I and J.
- T022, T023 (Android create and pending sign-in): section H.
- T025 (Web): the three rows of the Web table.
- T028 (iPhone): the iOS rows of sections D and L, and all of section I.
- T029 (Mac): the macOS rows of sections D and L, and all of section J.
- T030 (Android): sections E and H, and the Android rows of section L.
- T031 (Windows and Linux): sections F and K.
- T032 (cross-client check): no rows of its own; its steps are the sign-in and KeePassXC steps in sections H, I and J.
- T033 (redaction sweep): the second row of the T601 table.
- T002, T003, T034: no rows of their own in this ledger.
- T005: no rows of its own. It is accepted without the KeePassXC fixture vault (`test/fixtures/passkeys/keepassxc_passkeys.kdbx`) having been created; no fixture file is added.

T035 is not covered by this acceptance. The markers are not `pass`, so they do not satisfy the T034 criterion that every ledger row is `pass` or linked to an issue.

## Devices used

| Label | Model | OS | Browser | Screen lock | Biometric enrolled |
|-------|-------|----|---------|-------------|--------------------|
| I1    | *(iPhone still needed)* | | Safari | | |
| M1    | *(Mac still needed)* | | Safari | | |
| A1    | *(Android API 34+ still needed)* | | Chrome | | |
| A2    | *(Android API 29–33 still needed)* | | Chrome | | |
| W1    | *(Windows machine still needed)* | | Chrome/Edge | n/a | n/a |
| L1    | *(Linux machine still needed)* | | Chrome | n/a | n/a |

## D — Apple sign-in (US2), and T708's registration refusal

iOS and macOS are recorded separately: the same code path, two systems.

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| D.1 sign-in on webauthn.io, user presence every time, under 15 s (SC-003) | I1 | | | | accepted by owner 2026-11-15, not tested |
| D.1 | M1 | | | | accepted by owner 2026-11-15, not tested |
| D.2 cancelling the biometric shows a cancellation, not "credential not found" | I1 | | | | accepted by owner 2026-11-15, not tested |
| D.2 | M1 | | | | accepted by owner 2026-11-15, not tested |
| D.3 passkeys.io offers only E3 | I1 | | | | accepted by owner 2026-11-15, not tested |
| D.3 | M1 | | | | accepted by owner 2026-11-15, not tested |
| D.4 a locked database offers nothing (FR-023) | I1 | | | | accepted by owner 2026-11-15, not tested |
| D.4 | M1 | | | | accepted by owner 2026-11-15, not tested |
| D.5 registration shows the refusal, the site reports a failure and the vault is unchanged (T708) | I1 | | | | accepted by owner 2026-11-15, not tested |
| D.5 | M1 | | | | accepted by owner 2026-11-15, not tested |

## E — Android sign-in (US2)

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| E.1 provider set, sign-in on webauthn.io with user presence every time | A1 | | | | accepted by owner 2026-11-15, not tested |
| E.2 the settings row says not available on this device, and no provider appears | A2 | | | | accepted by owner 2026-11-15, not tested |
| E.3 D.2 repeated (cancellation) | A1 | | | | accepted by owner 2026-11-15, not tested |
| E.3 D.4 repeated (locked database) | A1 | | | | accepted by owner 2026-11-15, not tested |

## F — Desktop sign-in (US2), Windows and Linux

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| F.1 confirmation names site and username, then the site succeeds | W1 | | | | accepted by owner 2026-11-15, not tested |
| F.1 | L1 | | | | accepted by owner 2026-11-15, not tested |
| F.2 declining shows the site a cancellation | W1 | | | | accepted by owner 2026-11-15, not tested |
| F.2 | L1 | | | | accepted by owner 2026-11-15, not tested |
| F.3 a locked app falls through to the browser's own dialog | W1 | | | | accepted by owner 2026-11-15, not tested |
| F.3 | L1 | | | | accepted by owner 2026-11-15, not tested |
| F.4 a site with no matching passkey gets the browser's dialog only | W1 | | | | accepted by owner 2026-11-15, not tested |
| F.4 | L1 | | | | accepted by owner 2026-11-15, not tested |
| F.5 the previous native host build answers `unsupported_type` | W1 | | | | accepted by owner 2026-11-15, not tested |
| F.5 | L1 | | | | accepted by owner 2026-11-15, not tested |

## T212 — KeePassXC round trip (SC-001)

Quickstart A.4, B.1 and C.2 on a desktop build against a copy of the T001
fixture, then the same file opened in KeePassXC and E1 used to sign in on
webauthn.io.

| Step | Device | Date | KeePassXC version | Observed | Verdict |
|------|--------|------|-------------------|----------|---------|
| A.4 | | | | | accepted by owner 2026-11-15, not tested |
| B.1 | | | | | accepted by owner 2026-11-15, not tested |
| C.2 | | | | | accepted by owner 2026-11-15, not tested |
| E1 signs in on webauthn.io from KeePassXC | | | | | accepted by owner 2026-11-15, not tested |

## T601 — redaction sweep (SC-002)

The grep half needs no device and is recorded here so the task's two halves stay
together.

| Half | Date | Observed | Verdict |
|------|------|----------|---------|
| `grep -rn "BEGIN PRIVATE KEY" lib desktop tool android/app/src ios/CredentialProviderExtension macos/CredentialProviderExtension` | 2026-09-26 | one hit: `lib/features/password_manager/data/services/passkey_generator.dart:224`, the PEM header the generator itself writes. No fixture hits. | `pass` |
| verbose logs from one run of A, D, E and F contain no `PRIVATE KEY` | | | accepted by owner 2026-11-15, not tested |

Record the log sizes with the verdict: "zero hits" in an empty log is not
evidence.

---

# Passkeys on every platform (draft spec 024)

Rows for quickstart sections H to L and Web, consumed by T025 and T028 to
T032 of `specs/DRAFT-passkeys-all-platforms.md`. Same rule as above: filled
only from an observation on the named device, with versions.

## H — Android create (US3, US4, US5), API 34+

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| H.1 settings row text, Custode enabled as a system provider | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.2 create in Chrome on webauthn.io: confirm dialog, device prompt every time, saved-on-this-device notice, site reports success | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.3 cancelling the dialog or the device prompt shows the site a cancellation, nothing waiting | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.4 Chrome sign-in with E1 and E3 verifies at the relying party (clientDataHash fix) | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.5 sign-in from the queue before opening Custode (US5, SC-1) | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.6 waiting notice, then adoption message naming site and account, backup on disk | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.7 sign-in after adoption (SC-1) | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.8 vault opens in KeePassXC and the passkey signs in there (SC-2) | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.9 steps 2 and 5 to 8 on passkeys.io | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.10 steps 2 and 5 to 8 on webauthn.me | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.11 create and sign in from a native app, before and after adoption | A1 | | | | accepted by owner 2026-11-15, not tested |
| H.12 a request without ES256 is refused before any prompt (FR-4) | A1 | | | | accepted by owner 2026-11-15, not tested |

## I — iOS create (US1, US4, US5)

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| I.1 AutoFill enabled, settings row text | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.2 create in Safari on webauthn.io: sheet names site and account, device prompt every time, saved-on-this-device text, site reports success | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.3 cancelling the sheet or Face ID shows the site a cancellation, nothing waiting | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.4 sign-in from the queue before opening Custode (US5, SC-1) | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.5 waiting notice, then adoption message naming site and account, backup on disk | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.6 sign-in after adoption (SC-1) | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.7 vault opens in KeePassXC and the passkey signs in there (SC-2) | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.8 steps 2 and 4 to 7 on passkeys.io | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.9 steps 2 and 4 to 7 on webauthn.me | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.10 create and sign in from an app, before and after adoption | I1 | | | | accepted by owner 2026-11-15, not tested |
| I.11 a request without ES256 is refused with the reason, no prompt (FR-4) | I1 | | | | accepted by owner 2026-11-15, not tested |

## J — macOS create (US2, US4, US5)

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| J.1 AutoFill enabled, settings row text | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.2 create in Safari on webauthn.io with Custode running | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.3 create in Safari on webauthn.io with Custode not running; the app is not started | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.4 cancelling the sheet or Touch ID shows the site a cancellation | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.5 sign-in from the queue before opening Custode (US5, SC-1) | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.6 adoption messages and backups for both passkeys | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.7 sign-in after adoption, Custode in the background and quit (SC-1) | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.8 vault opens in KeePassXC and both passkeys sign in there (SC-2) | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.9 steps 2 and 5 to 8 on passkeys.io | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.10 steps 2 and 5 to 8 on webauthn.me | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.11 create and sign in from an app, before and after adoption | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.12 a request without ES256 is refused with the reason, no prompt (FR-4) | M1 | | | | accepted by owner 2026-11-15, not tested |
| J.13 regression: creation through the browser extension lands in the vault at once (T029) | M1 | | | | accepted by owner 2026-11-15, not tested |

## K — Ed25519 sign-in through the browser extension (US9, US10), Windows and Linux

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| K.1 settings row states extension-only and the reason | W1 | | | | accepted by owner 2026-11-15, not tested |
| K.1 | L1 | | | | accepted by owner 2026-11-15, not tested |
| K.2 E5 shown as Ed25519 and usable for sign-in | W1 | | | | accepted by owner 2026-11-15, not tested |
| K.2 | L1 | | | | accepted by owner 2026-11-15, not tested |
| K.3 Ed25519 sign-in verifies at the relying party | W1 | | | | accepted by owner 2026-11-15, not tested |
| K.3 | L1 | | | | accepted by owner 2026-11-15, not tested |
| K.4 declining the confirmation shows the site a cancellation | W1 | | | | accepted by owner 2026-11-15, not tested |
| K.4 | L1 | | | | accepted by owner 2026-11-15, not tested |
| K.5 regression: creation through the extension is ES256, signs in, opens in KeePassXC (T031) | W1 | | | | accepted by owner 2026-11-15, not tested |
| K.5 | L1 | | | | accepted by owner 2026-11-15, not tested |

## L — Failure modes (US4 to US8, SC-3)

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| L.1 app never opened: sign-in from the queue twice, waiting notice on next launch, then adopted | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.1 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.1 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.2 vault locked at creation: refusal, site reports a failure, nothing generated | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.2 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.2 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.3 different vault open: told so, decide later keeps it, move only on confirmation with backup | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.3 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.3 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.4 different vault open: discard only on confirmation, no vault touched | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.4 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.4 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.5 vault changed by sync before adoption: adopted on the fresh vault, nothing extra | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.5 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.5 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.6 duplicate `(rpId, credentialId)`: record resolved, no write, no backup, no message | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.6 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.6 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.7 clash, replace: dialog names site, account and backup; old passkey removed after backup | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.7 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.7 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.8 clash, keep both: new record, old passkey untouched; decide later writes nothing | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.8 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.8 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.9 vault write fails: record and backup kept, error shown, adopted on the next unlock | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.9 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.9 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.10 unreadable record: skipped, counted, never deleted automatically, not offered for sign-in | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.10 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.10 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.11 lock wipes the cache, queue file survives, waiting notice, then adopted | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.11 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.11 | A1 | | | | accepted by owner 2026-11-15, not tested |
| L.12 device-only warning stated in the sheet, the notice and settings | I1 | | | | accepted by owner 2026-11-15, not tested |
| L.12 | M1 | | | | accepted by owner 2026-11-15, not tested |
| L.12 | A1 | | | | accepted by owner 2026-11-15, not tested |

## Web (T025)

Device is any desktop with Chrome: name it and the browser version in the row.

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| Web.1 a vault with passkeys shows the badge and the passkey section | | | | | accepted by owner 2026-11-15, not tested |
| Web.2 deleting a passkey works and writes the dated backup | | | | | accepted by owner 2026-11-15, not tested |
| Web.3 settings row says not available and why | | | | | accepted by owner 2026-11-15, not tested |
