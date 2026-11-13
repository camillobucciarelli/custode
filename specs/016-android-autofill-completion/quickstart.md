# 016 — Validation quickstart

How to prove Android autofill works, on hardware. Slices 2 and 4 cannot be
proven any other way: emulator IMEs and emulator browsers do not represent what
real ones advertise.

Record every run in `device-evidence.md` with device, Android version, IME and
browser versions, and a `pass` / `fail` per item.

## Prerequisites

- Two devices, or one device and one emulator image: **API 29** and **API 33+**.
- Custode installed from a debug build and selected as the autofill service:
  Settings → Passwords & accounts → Autofill service → Custode.
- A vault unlocked at least once with entries for a native app and for a website,
  so the cache is published.
- Gboard plus one third-party IME installed (API 33+ device).
- Chrome and Firefox installed, versions noted.

## Build and install

```bash
flutter run --dart-define-from-file=.env.dart.define.json -d <device-id>
```

Confirm the cache is published before testing anything else:

```bash
adb shell run-as dev.camillobucciarelli.kdbxKeyVault ls files/autofill_v2
```

Expect `android_autofill_metadata_v2.json` and
`android_autofill_cache_v2.sealed.json`.

## A — Authentication gate (P1)

1. Open any app with a login form, focus the username field, choose Custode,
   pick an entry.
   **Expect**: an authentication prompt before anything is filled.
2. Cancel the prompt.
   **Expect**: nothing filled, no toast claiming success, picker closed.
3. Authenticate successfully.
   **Expect**: username and password filled.
4. Immediately fill a second form.
   **Expect**: within the published reuse window, no second prompt; outside it,
   a prompt.
5. Remove the device lock entirely (Settings → Security → Screen lock → None) and
   retry.
   **Expect**: refusal with the "device lock required" message, nothing filled.
   Restore the lock afterwards.

## B — Inline suggestions (P2, API 30+)

1. With Gboard active, focus a username field in an app that has two matching
   entries.
   **Expect**: both entries on the suggestion strip showing title and username,
   **no password text anywhere**.
2. Tap one.
   **Expect**: authentication prompt, then fill — no full-screen picker.
3. Switch to the third-party IME and repeat step 1.
   **Expect**: either inline suggestions, or the dropdown fallback — never a
   broken or empty strip.
4. Focus a field matching more entries than the IME's slot count.
   **Expect**: top matches shown, last slot is "Search Custode" and opens the
   picker.
5. On the API 29 device, repeat step 1.
   **Expect**: the existing dropdown-and-picker path, unchanged.

## C — Save capture (P2)

1. In an app with no matching vault entry, type a new username and password and
   submit.
   **Expect**: the system save bar offering Custode.
2. Accept it with the vault unlocked.
   **Expect**: confirmation stating a **new entry** will be created; after
   confirming, the entry exists in the vault with the app's package as its
   association.
3. Change the password for that same username in the same app and submit again.
   **Expect**: confirmation stating this is an **update**; afterwards the entry
   holds the new password and the previous one is in its history.
4. Lock the vault, repeat step 1, and accept.
   **Expect**: the Custode unlock screen; after unlocking, the entry is written.
5. Repeat step 4 but cancel the unlock.
   **Expect**: the unlock screen states that a captured password is waiting and
   will be discarded if you leave; leaving discards it immediately — nothing
   written, and the captured password is not recoverable afterwards (re-check
   `files/autofill_v2` — no new file). Returning to the app must not re-offer it.
6. Decline a save prompt, then resubmit the same form.
   **Expect**: no repeat prompt for that submission.

## D — Browsers (P3)

For each of Chrome and Firefox, using **three distinct sites** with vault
entries (SC-004):

1. Open a login page on each of the three domains, focus the password field.
   **Expect**: the entry for that domain offered, on all three.
2. Open a login page on a domain with no entry.
   **Expect**: no strong match; the picker opens in global-search mode if invoked.
3. Confirm no entry is ever matched to the browser's own package name.

## E — Accessibility (FR-014)

1. Enable TalkBack, open the picker.
   **Expect**: every row announced with title and username; the search field and
   the authentication prompt labelled.
2. Connect a keyboard, tab through the picker.
   **Expect**: a visible focus indicator on every focusable.
3. Switch the system to dark theme and repeat.
   **Expect**: text remains legible; contrast pairs match the values asserted by
   the instrumented test.

## F — Redaction (FR-015)

With everything above done in one session:

```bash
adb logcat -d | grep -i -E "password|secret" | grep -v "redacted"
```

**Expect**: no line containing a real password value. Any hit fails the gate.

## Local gate before commit

```bash
dart format --set-exit-if-changed lib test tool
flutter analyze
flutter test
(cd android && ./gradlew :app:test)
```

All four must be clean and green (Constitution IX).
