# 023 — Device evidence

Hardware observations for the tasks that cannot be proven any other way. Fill a
row in, state `pass` or `fail` explicitly, and record the versions: a verdict
without the OS and browser version is not evidence.

Nothing here is filled in by an agent. Every line is something someone watched
happen on a device. The rows below are the empty ledger; the tasks that consume
it are T212 (KeePassXC round trip), T601 (redaction sweep), T603 (the full
quickstart run) and T808 (the device run of sections H, I and J).

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
| D.1 sign-in on webauthn.io, user presence every time, under 15 s (SC-003) | I1 | | | | |
| D.1 | M1 | | | | |
| D.2 cancelling the biometric shows a cancellation, not "credential not found" | I1 | | | | |
| D.2 | M1 | | | | |
| D.3 passkeys.io offers only E3 | I1 | | | | |
| D.3 | M1 | | | | |
| D.4 a locked database offers nothing (FR-023) | I1 | | | | |
| D.4 | M1 | | | | |
| D.5 registration shows the refusal, the site reports a failure and the vault is unchanged (T708) | I1 | | | | |
| D.5 | M1 | | | | |

## E — Android sign-in (US2)

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| E.1 provider set, sign-in on webauthn.io with user presence every time | A1 | | | | |
| E.2 the settings row says not available on this device, and no provider appears | A2 | | | | |
| E.3 D.2 repeated (cancellation) | A1 | | | | |
| E.3 D.4 repeated (locked database) | A1 | | | | |

## F — Desktop sign-in (US2), Windows and Linux

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| F.1 confirmation names site and username, then the site succeeds | W1 | | | | |
| F.1 | L1 | | | | |
| F.2 declining shows the site a cancellation | W1 | | | | |
| F.2 | L1 | | | | |
| F.3 a locked app falls through to the browser's own dialog | W1 | | | | |
| F.3 | L1 | | | | |
| F.4 a site with no matching passkey gets the browser's dialog only | W1 | | | | |
| F.4 | L1 | | | | |
| F.5 the previous native host build answers `unsupported_type` | W1 | | | | |
| F.5 | L1 | | | | |

## H — Android create (US4), API 34+

For H.10 the versions include the KeePassXC version and the desktop it ran on.

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| H.1 Custode open and unlocked: confirmation names site and account, user presence asked, the site succeeds only afterwards | A1 | | | | |
| H.2 a new record titled with the site holds the passkey, and a dated backup precedes the write | A1 | | | | |
| H.3 the single record for the site and username receives the passkey, no new record | A1 | | | | |
| H.4 app closed: the screen says so and offers "Open Custode"; continues on return and the site succeeds | A1 | | | | |
| H.5 vault locked: the screen says so and offers "Open Custode"; continues on return and the site succeeds | A1 | | | | |
| H.6 dismissed while locked: no success on the site, vault unchanged | A1 | | | | |
| H.7 replacement warning before the write, then exactly one passkey for the site on the same record | A1 | | | | |
| H.8 cancelling the biometric is a cancellation, vault unchanged | A1 | | | | |
| H.8 cancelling at the replacement warning leaves the old passkey in place | A1 | | | | |
| H.9 sign-in with the new passkeys, user presence every time | A1 | | | | |
| H.10 KeePassXC shows the new passkeys with protected secrets and signs in | A1 | | | | |
| H.11 a request without ES256 gets no Custode entry | A1 | | | | |

## I — macOS create (US4), and iOS still refusing

For I.9 the versions include the KeePassXC version.

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| I.1 Custode open and unlocked: confirmation names site and account, device owner authentication asked, the site succeeds only afterwards | M1 | | | | |
| I.2 a new record titled with the site holds the passkey, and a dated backup precedes the write | M1 | | | | |
| I.3 the single record for the site and username receives the passkey, no new record | M1 | | | | |
| I.4 app closed: refusal says Custode must be open and unlocked, the site reports a failure, vault unchanged; the retry with the app open succeeds | M1 | | | | |
| I.5 vault locked: the same refusal and failure, vault unchanged | M1 | | | | |
| I.6 replacement warning before the write, then exactly one passkey for the site on the same record | M1 | | | | |
| I.7 cancelling the authentication is a cancellation, vault unchanged | M1 | | | | |
| I.7 cancelling at the replacement warning leaves the old passkey in place | M1 | | | | |
| I.8 sign-in with the new passkeys, user presence every time | M1 | | | | |
| I.9 KeePassXC shows the new passkeys with protected secrets and signs in | M1 | | | | |
| I.10 iOS still refuses: refusal screen, failed registration, vault unchanged | I1 | | | | |

## J — Ed25519 sign-in (US4), Windows and Linux

Record the site used for E5 and the client that created its key in "Observed"
of J.1.

| Step | Device | Date | Versions | Observed | Verdict |
|------|--------|------|----------|----------|---------|
| J.1 E5 shows key type EdDSA (Ed25519) and is not marked unusable | W1 | | | | |
| J.1 | L1 | | | | |
| J.2 confirmation names site and username, then the site succeeds with the Ed25519 passkey | W1 | | | | |
| J.2 | L1 | | | | |
| J.3 declining shows the site a cancellation | W1 | | | | |
| J.3 | L1 | | | | |
| J.4 a locked app falls through to the browser's own dialog | W1 | | | | |
| J.4 | L1 | | | | |
| J.5 the ES256 passkey E1 still signs in | W1 | | | | |
| J.5 | L1 | | | | |
| J.6 the verbose log of J.2 contains no `PRIVATE KEY` (record the log size) | W1 | | | | |
| J.6 | L1 | | | | |

## T212 — KeePassXC round trip (SC-001)

Quickstart A.4, B.1 and C.2 on a desktop build against a copy of the T001
fixture, then the same file opened in KeePassXC and E1 used to sign in on
webauthn.io.

| Step | Device | Date | KeePassXC version | Observed | Verdict |
|------|--------|------|-------------------|----------|---------|
| A.4 | | | | | |
| B.1 | | | | | |
| C.2 | | | | | |
| E1 signs in on webauthn.io from KeePassXC | | | | | |

## T601 — redaction sweep (SC-002)

The grep half needs no device and is recorded here so the task's two halves stay
together.

| Half | Date | Observed | Verdict |
|------|------|----------|---------|
| `grep -rn "BEGIN PRIVATE KEY" lib desktop tool android/app/src ios/CredentialProviderExtension macos/CredentialProviderExtension` | 2026-09-26 | one hit: `lib/features/password_manager/data/services/passkey_generator.dart:224`, the PEM header the generator itself writes. No fixture hits. | `pass` |
| verbose logs from one run of A, D, E and F contain no `PRIVATE KEY` | | | |

Record the log sizes with the verdict: "zero hits" in an empty log is not
evidence.
