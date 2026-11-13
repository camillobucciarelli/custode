# Manual QA checklist

One executable list for every manual verification this repository still owes.
It replaces the prose scattered across `specs/008-per-field-conflict-resolution/`,
`specs/009-in-page-autofill-overlay/` and `specs/011-master-password-session-scope/`.

**How to use this file.** Pick the session that matches the hardware you have in
front of you, run its items top to bottom, and write the outcome into the status
table below. Every item states its preconditions, numbered steps, the expected
observation, and what counts as a failure. Nothing here requires you to go read a
spec first.

**Rules of evidence, inherited from spec 008 and spec 011 and non-negotiable:**

- Host evidence never qualifies another platform. Running an item on macOS does
  not fill in the Linux row.
- `not-run` is a legitimate result and must be recorded as such. It is never
  upgraded to `passed` by reasoning.
- A `failed` item blocks whatever it gates. It is not "mostly fine".

## Status

Every item is `passed`, `failed` or `not-run`. `not-run` means nobody has ever
executed it on that platform. A session whose items disagree is reported as a
count, never rounded to the more flattering of the two.

| Session | Platform / hardware needed | Items | Status | Last run | Notes |
| --- | --- | --- | --- | --- | --- |
| S1 | Android phone or emulator | 7 | 1 `passed`, 6 `not-run` | 2026-08-25 | S1-7 passed (T111 Android artifact, Android 16 / API 36 emulator, arm64, 8/8 cases). S1-1..S1-6 UI/manual items remain `not-run` |
| S2 | iPhone or iPad (physical) | 6 | 1 `passed`, 5 `not-run` | 2026-08-24 | S2-1 automated keystore inspection passed on physical iPhone / iOS 26.6; S2-2 lifecycle and all UI items remain `not-run` — see evidence below |
| S3 | macOS machine (also covers Chrome/Edge + native host) | 13 | 3 `passed`, 10 `not-run` | 2026-08-25 | S3-7 passed (v1 → v2 upgrade, Chrome 151); S3-10 passed (keyboard-only, Chrome 151, same session that found and fixed #132); S3-12 passed (file:// iframe reachability, same session); S3-13 stays `not-run`: partially executed 2026-08-25 under a documented harness substitution (real Chrome, real `en.wikipedia.org` + `github.com/login`) that injected the **top frame only** and skipped the dynamic `allFrames: true` registration — the frame-coverage dimension this row exists for is unmeasured, see S3-13 below. S3-6 was re-attempted for real on this machine on 2026-08-25 and stays `not-run`: blocked by this sandbox's own missing macOS Accessibility/Screen-Recording permissions, not by a product finding — see S3-6 below. T111 macOS host artifact also passed, but is outside these 13 UI/manual items and qualifies macOS only |
| S4 | Windows machine | 3 | `not-run` | — | Shrunk by the `test-windows` and `t111-platform-artifact` CI jobs, see "Removed" |
| S5 | Linux machine | 3 | `not-run` | — | Shrunk by the `t111-platform-artifact` CI job, see "Removed" |

Total: **32 items** — **5 `passed`** (S1-7, S2-1, S3-7, S3-10, S3-12), 27 `not-run`.

### Earlier hardware QA evidence — 2026-08-24

Retried from clean commit `ea004699a541767d2ec70f48a7c9a667296d5d2b`
with pinned Flutter 3.44.8 on a physical iPhone running iOS 26.6 over USB. A
same-day T111 follow-up then passed. Combined requested-command count: **3
`passed`, 1 `not-run`, 1 `failed`**. The failed command is a probe-fixture
lifecycle failure before AC-2 was exercised, not evidence that the product
retained a secret.

| Evidence | Platform / mode | Result | Observation |
| --- | --- | --- | --- |
| Keystore `ac2_unlock` | physical iPhone; automated integration test | `passed` | Vault created and manually unlocked with biometrics off. Keystore readable; legacy and per-database entries absent; total keys 0. Positive control became present with total keys 1, then cleanup restored absence and total keys 0. Phase completed. |
| Keystore `ac2_relaunch` | physical iPhone; automated integration test | `failed` | Test body started but found 0 probe-vault records where 1 from the prior phase was required (`Expected: <1>`, `Actual: <0>` at `master_password_keystore_qa_test.dart:340`). No post-kill keystore or stored-credential assertion ran. S2-2 therefore remains `not-run`, not product-failed. |
| Keystore `ac6_seed` | physical iPhone; automated integration test | `passed` as seed only | A fresh probe vault was created, confirming prior registry state was unavailable. Keystore readable; planted legacy entry present; total keys 1. The original transcript exposed a probe-reporting defect: own-entry value `2` incorrectly used `indeterminate` as not-applicable. The scoped AC-6 result remained deterministic; the probe now supplies the retained vault id and verifies that entry separately. |
| Keystore `ac6_upgrade` | physical iPhone; automated integration test | `not-run` | Build completed, but Flutter could not start the app after 707 seconds; no phase output was emitted. Read-only device check then reported `passcodeRequired: true`. Execution stopped as required, so deletion and vault opening were not tested. |
| T111 iOS | physical iPhone 16 Pro, iOS 26.6, APFS; automated device harness | `passed` | Schema v1; 8/8 exact required cases passed. `atomicReplaceOverExisting=true`, `backupNoOverwrite=true`, `flushSupported=true`, `directorySyncSupported=false`. Directory sync remains best-effort. Artifact and transcript remain gitignored. |
| T111 macOS | macOS 26.6.1 host, APFS; automated host harness from prior run | `passed` | Exit 0; schema-valid artifact; 8/8 cases passed. `atomicReplaceOverExisting=true`, `backupNoOverwrite=true`, `flushSupported=true`, `directorySyncSupported=false`. Host evidence qualifies macOS only. |

A follow-up run with the corrected runner completed all four probe processes:
`ac2_unlock`, `ac2_relaunch`, `ac6_seed`, and `ac6_upgrade`. AC-1, AC-2,
and the automated AC-6 migration property passed. The `ac6_seed` transcript
exposed only the reporting ambiguity described above; secure-store reads and
the AC-6 result were deterministic.

All probe output remained bool/int only; no secret value was printed or
reported, and the census bound only key names and counts.
S2-1 is passed by the automated negative check plus positive control. The
follow-up automated run also qualified the AC-2 storage/behavioural property
and the AC-6 migration property. It does not replace S2-2's optional visible-UI
check or prove that a real pre-`027641d` build created the legacy entry for
S2-5. Spec 011 T020 therefore stays open.

The retry exposed a harness precondition gap: separate default `flutter test`
phase invocations did not preserve the probe vault registry on this iPhone.
Flutter 3.44.8 stops and then uninstalls the integration-test app after each
run. iOS retained Keychain entries but deleted the app container, fixture and
registry. The corrected runner now uses `--no-uninstall` and checks a
non-secret cross-process marker; its physical-device rerun completed all four
probe processes successfully.

Windows and Linux T111 artifacts remain verified from PR #127, Actions run
`32713786823`; macOS and iOS are also passed. As of this date T111 was still
open, Android being the only platform without an artifact; it closed the next
day — see the Android row of
`specs/008-per-field-conflict-resolution/feasibility-report.md` and S1-7 below.
Generated outputs remain ignored or attached to GitHub Actions; none is
committed.

**Changed on 2026-08-24 by the T111 automation.** Two items left this list for
good (S4-4 and S5-4): on Linux and Windows the GitHub-hosted runner *is* the
target platform, so the new `t111-platform-artifact` job produces real platform
evidence on every PR instead of waiting for someone to find a machine. Three
more items (S1-7, and the inspection halves of S2-1/S2-2) stopped being
**blocked** without leaving the list — they need hardware CI does not have.
Read the honest version in "What the automation did and did not remove" at the
end of this file: the count went down by two, and the time did not go down
much, because the items that left were ones nobody could execute anyway.

Sessions are grouped by *what you must physically have*, not by spec. If you are
holding an Android phone, S1 is everything you can do; you never need to jump
between three documents.

### Time estimate

Honest, assuming the preconditions are already met (builds installed, extension
loaded, native host installed) and that nothing fails. A failure adds triage
time that is not budgeted here.

| Session | Setup | Execution | Total |
| --- | --- | --- | --- |
| S1 Android | 30 min | 60 min | **~1 h 30 min** |
| S2 iOS | 30 min | 50 min | **~1 h 20 min** |
| S3 macOS + browsers | 35 min | 2 h 45 min | **~3 h 20 min** |
| S4 Windows | 40 min | 30 min | **~1 h 10 min** |
| S5 Linux | 40 min | 30 min | **~1 h 10 min** |

**Total: ~8 h 30 min**, spread across five machines. No session is longer than
one sitting; S3 is the only one worth splitting in two.

**Why that is only ten minutes better than the previous ~8 h 40 min, with two
items gone.** The arithmetic is not flattering and is left visible on purpose:

- S4 and S5 each lost a T111 item, but those items were **blocked** and
  therefore cost zero execution time. Removing them shrinks the list without
  shrinking the clock. What actually changed is that Linux and Windows now
  have evidence they never had.
- S3 setup drops 10 minutes because `desktop/browser_extension/serve_harness.sh`
  replaces recovering the harness port and path out of `capture_runner.mjs`.
- S2 goes **up** 10 minutes, which is the correct direction: S2-1 and S2-2 were
  blocked with no method at all, and now there is something to run.
- S1 is unchanged in total: S1-7 went from blocked (0 min) to a ~5 min command,
  absorbed by rounding.

A checklist that got shorter *and* much faster would mean the removed items
had been costing real time. They had not. They had been costing coverage.

### State of the code these items verify

- **Spec 011** — slices 1–3 are **merged on main** (`027641d`, `29e4164`). The
  per-database keystore key (`MASTER_PASSWORD.<databaseId>`) and the legacy-entry
  deletion exist in `secure_data_source.dart`. The AC items below are therefore
  runnable **now**. The items are tracked as tasks T019–T024 in
  `specs/011-master-password-session-scope/tasks.md`; tick a box there only once
  the corresponding row in the status table above is filled in.
- **Spec 009** — Slice A and Slice B are implemented; Slice C replaced the
  per-origin opt-in with a single global toggle (PR #113). A040 and A046 remain
  open manual debt.
- **Spec 008** — the merge feature itself is **off** (`commit` returns
  `platformDisabled`, no UI before Phase 6), so nothing below tests merging. What
  *is* live and on the path of every single save is the **safe vault file
  writer**, and that is what T111 and the sandbox items verify.

---

## S1 — Android phone or emulator

**Session preconditions**

- A debug or profile build installed: `flutter run -d <device> --dart-define-from-file=.env.dart.define.json`.
- `adb` on `PATH` and `adb devices` listing exactly one target.
- Application id: `dev.camillobucciarelli.kdbxKeyVault`.
- Two `.kdbx` test vaults with known master passwords, called A and B below.
- Device enrolled with a fingerprint/face so biometric unlock is offerable.

**The keystore inspection command, in full.** `flutter_secure_storage` 10.3.1 on
Android stores values in a `SharedPreferences` XML file named
`FlutterSecureStorage`, with every key prefixed by
`VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg`. Values are encrypted;
you are checking for **presence or absence of the entry**, not for readable
plaintext.

```bash
# Debug build on an emulator or a rooted device — direct read.
adb shell run-as dev.camillobucciarelli.kdbxKeyVault \
  cat /data/data/dev.camillobucciarelli.kdbxKeyVault/shared_prefs/FlutterSecureStorage.xml
```

```bash
# Any build, including a non-debuggable one, on an emulator or rooted device.
adb root
adb shell cat /data/data/dev.camillobucciarelli.kdbxKeyVault/shared_prefs/FlutterSecureStorage.xml
```

`run-as` only works when the installed build is debuggable. On a stock
non-rooted retail phone with a release build **neither command works, and there
is no supported alternative** — record the item `not-run` on that hardware and
repeat it on an emulator rather than inventing evidence.

Read the result with these two greps:

```bash
# Legacy global entry (spec 011 FR-6). Must be ABSENT after any launch of a
# post-slice-3 build.
... | grep -o 'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg[A-Za-z0-9+/=_.-]*'
```

Each printed name is `<prefix><key>`. The keys that matter are the literal
`MASTER_PASSWORD` (legacy, must never be present) and
`MASTER_PASSWORD.<databaseId>` (per-database, present only with biometrics on).

---

### S1-1 · Keystore is untouched when biometrics are off (spec 011 AC-1)

**Preconditions.** App installed and launched at least once. Vault A registered
with biometric protection **off**.

**Steps**

1. Force-stop the app: `adb shell am force-stop dev.camillobucciarelli.kdbxKeyVault`.
2. Launch the app, select vault A, unlock it by typing the master password.
3. Leave the vault open. Do not lock it.
4. Run the keystore dump command above and list the entry names.

**Expected observation.** No entry named `MASTER_PASSWORD` and no entry named
`MASTER_PASSWORD.<id of A>`. The file may not exist at all — that is a pass.

**Fails if.** Either name is present while the vault is unlocked and biometric
protection is off.

---

### S1-2 · Nothing survives a process kill (spec 011 AC-2)

**Preconditions.** S1-1 passed. Vault A unlocked, biometrics still off.

**Steps**

1. With the vault open, kill the process without locking:
   `adb shell am force-stop dev.camillobucciarelli.kdbxKeyVault`.
2. Run the keystore dump command.
3. Relaunch the app and open vault A.

**Expected observation.** No `MASTER_PASSWORD*` entry after the kill, and the app
asks for the master password again at step 3.

**Fails if.** An entry is present after the kill, or the vault opens without
asking for the password.

---

### S1-3 · Biometric unlock still works (spec 011 AC-3)

**Preconditions.** Vault A with biometric protection **on**, enrolled by
unlocking once with the master password after enabling it.

**Steps**

1. Confirm `MASTER_PASSWORD.<id of A>` exists in the dump.
2. Force-stop the app.
3. Relaunch, select vault A, choose biometric unlock, present the enrolled
   fingerprint/face.

**Expected observation.** The vault opens. Entries are listed and readable.

**Fails if.** Biometric unlock is not offered, is rejected, or falls through to
an error instead of the master-password fallback. (The fallback being
unreachable was a real defect once — issue #71 — so check it explicitly: cancel
the biometric prompt and confirm the password field is reachable.)

---

### S1-4 · Two databases, biometrics on only one (spec 011 AC-5)

**Preconditions.** Vault A with biometrics **on** and enrolled. Vault B
registered with biometrics **off**.

**Steps**

1. Launch, unlock vault B **manually** with its master password.
2. Lock, or switch database back to A.
3. Biometric-unlock vault A.
4. Run the keystore dump.

**Expected observation.** A opens with biometrics. Exactly one entry exists,
`MASTER_PASSWORD.<id of A>`. There is **no** entry for B, and no bare
`MASTER_PASSWORD`.

**Fails if.** An entry for B appears after step 1, or A's biometric unlock is
attempted with B's password (visible as a wrong-password error on a vault whose
biometrics are correctly enrolled).

---

### S1-5 · Upgrade from a pre-011 build (spec 011 AC-6)

**Preconditions.** A build from **before** commit `027641d` — build it from a
checkout of a parent commit, or keep a previously archived APK. Plus the current
build.

**Steps**

1. Install the old build. Unlock vault A once with the master password.
2. Dump the keystore. Confirm the legacy global `MASTER_PASSWORD` entry **is**
   present — this establishes the precondition. If it is not, the old build is
   not old enough and the item proves nothing.
3. Install the current build **over** it (`adb install -r`, no uninstall — an
   uninstall clears the store and voids the test).
4. Launch the app once. Let it reach the database selection screen.
5. Dump the keystore again.
6. Unlock vault A with its master password.

**Expected observation.** After step 5 the bare `MASTER_PASSWORD` entry is gone.
After step 6 the vault opens normally.

**Fails if.** The legacy entry survives the first launch, or the vault no longer
opens with a password that worked before the upgrade.

**Cheaper alternative, and what it does NOT cover.** The
`tool/run_ios_keystore_qa.sh -d <device-id> -s ac6` pair in the S2 preconditions
asserts the same deletion-and-still-opens property without needing an archived
APK, and the seed phase fails loudly if the legacy entry could not be planted —
the "old build is not old enough" trap above, made machine-checked.

What it deliberately does not do is prove that a **real pre-`027641d` build**
wrote that key: it writes the key itself. If you have the archived APK, the
steps above are still stronger evidence. If you do not, the probe is the
difference between weak evidence and none.

---

### S1-6 · Safe-writer fallback under Android SAF (spec 008, "not verifiable on host")

**Why manual.** Under Android SAF the grant authorizes the **chosen document**,
not its parent directory, so creating a sibling temp file can be refused where a
direct write succeeds. `safe_vault_file_writer.dart:415` degrades to a
non-atomic in-place write for exactly this case. On the host this is only
simulated by a fault seam (`_FaultyIo(_Fault.tempPermissionDenied)`); whether the
real refusal has the shape the code expects has **never** been observed on a
device.

**Preconditions.** A vault opened through the system document picker from a
location the app does not own — Downloads, or a Drive/SD provider.

**Steps**

1. Start `adb logcat` filtered to the app.
2. Open the SAF-provided vault, edit any entry, save.
3. Search the log for the safe writer's degradation warning (it names the
   operation that degraded).
4. Re-open the vault and confirm the edit persisted.
5. Confirm no `.tmp`-suffixed leftover next to the vault, where the picker
   location lets you list it.

**Expected observation.** The save succeeds. Either the atomic path ran with no
warning, or the fallback ran and logged the degradation naming the operation.
Data is intact either way.

**Fails if.** The save fails outright, the log shows a permission error that is
not caught by the fallback, the vault is truncated, or a temp file is left
behind.

---

### S1-7 · T111 Android platform artifact (spec 008 Gate 1)

**No longer blocked.** The harness runner exists now
(`tool/run_safety_harness.sh`), so this item went from "cannot start" to one
command. It stays manual only because it needs an Android device or emulator,
which CI does not have.

**Preconditions.** A device or emulator listed by `flutter devices`.

**Steps**

1. Run the harness, recording the device model and Android version:
   ```bash
   tool/run_safety_harness.sh -d <device-id> -p android
   ```
2. Read the summary it prints. It writes
   `build/safety-evidence/android/safe-vault-writer.json` plus the transcript
   next to it, and validates the artifact against the Gate 0 schema before
   filing it — a schema-invalid artifact is refused and nothing is written.
3. Update the Android row of
   `specs/008-per-field-conflict-resolution/feasibility-report.md` with the
   result and the artifact metadata.

**Expected observation.** Exit code 0 and `status: passed`, naming Android and
only Android. The four measured capability lines
(`atomicReplaceOverExisting`, `backupNoOverwrite`, `flushSupported`,
`directorySyncSupported`) are the point of running this on a device at all —
they are the facts the host tests can only assume.

**Fails if.** Exit code 2 (`status: failed` — a real finding: this platform
cannot hold the writer's contract, and the Android target must stay disabled)
or exit code 1 (the artifact could not be filed at all, which is "could not
run", not "the platform failed" — do not record a result).

**What is already automated.** The eight cases themselves run on the CI host on
every PR (`test/tool/safe_vault_writer_harness_test.dart`), so a regression in
the harness is caught there rather than here. This item contributes the one
thing CI cannot: Android hardware.

---

## S2 — iPhone or iPad (physical device)

**Session preconditions**

- A build on a real device. The simulator does **not** reproduce the
  `/var` → `/private/var` divergence and its keychain is a separate store, so it
  cannot stand in here.
- Two test vaults, A and B.
- Face ID or Touch ID enrolled.

**Keychain inspection: still no shell command, but the app can now be asked.**
There is **no supported way to dump the keychain of a third-party app from a
non-jailbroken iOS device**. `security find-generic-password` is a macOS binary
and does not reach an iOS device; Xcode offers no keychain browser. That has
not changed and no command claiming otherwise is written here.

What *has* changed is that the app can answer the question itself. Run both
scenarios, or one pair only:

```bash
tool/run_ios_keystore_qa.sh -d <device-id> -s all
tool/run_ios_keystore_qa.sh -d <device-id> -s ac2
tool/run_ios_keystore_qa.sh -d <device-id> -s ac6
```

Save all work and quit Xcode before running this command. The runner refuses to
start while Xcode is already open, so it cannot silently close a personal
session. Flutter may open Xcode for a phase; the runner asks it to quit
gracefully afterward and waits for it to close before starting the next phase
or returning. Quit failure or timeout stops the run. This follows the official
workaround for consecutive launches on Xcode 26
([flutter/flutter#144218](https://github.com/flutter/flutter/issues/144218),
[flutter/flutter#186455](https://github.com/flutter/flutter/issues/186455)). If
closure fails, close Xcode manually before starting T111; do not treat the
partial run as evidence.

Do not replace the runner with two default `flutter test` commands. Flutter's
default teardown calls `stopApp` and then `uninstallApp`: iOS keeps Keychain
entries but removes the app container, which invalidates the cross-process
fixture. The runner passes `--no-uninstall`; `stopApp` still terminates phase 1,
then phase 2 launches a new process over the retained container. Phase 1 stores
a non-secret `databaseId` + PID marker. Phase 2 requires a different PID and
the same random database identity before inspecting the Keychain or opening the
vault. Missing marker, fresh container, or equivalent newly-created vault all
fail.

The probe reports **presence or absence only**, never a value, and it lives in
`integration_test/` — which `flutter build` never compiles into an app, so
there is nothing gated to get wrong and nothing to remember to remove. Its
security properties are machine-checked by
`test/tool/keystore_probe_guard_test.dart` on every PR.

**Read this before recording a result from it.** The probe distinguishes three
answers, not two: `present`, `absent` and **`indeterminate`**. An
`indeterminate` reading fails the run loudly and states why. It must be
recorded as `not-run`, never as a pass — "the keystore refused to answer" and
"there is no entry" are opposite findings, and this item exists to prove
absence. The probe emits `indeterminate` only when secure-store enumeration
throws; optional or not-applicable report fields must never use that value.

**Verified status of the probe itself, stated plainly:**

- `ac2_unlock` passed on physical iPhone / iOS 26.6 through the real DI graph,
  unlock flow, negative census, and positive control.
- The corrected `ac2_relaunch` process retained the same random database
  identity under a new PID, found no scoped entry, refused stored-credential
  unlock, and still opened with the manual password.
- The corrected `ac6_seed` / `ac6_upgrade` pair observed the planted legacy
  entry, then its deletion on the next process and a successful manual unlock
  of the same retained vault. Its seed transcript exposed the reporting-only
  `indeterminate` ambiguity fixed here.
- macOS still hits `errSecInteractionNotAllowed` (-25308), so S3-1 keeps using
  the interactive `security` command.

### S2-1 · Keystore untouched with biometrics off, iOS (spec 011 AC-1)

Same intent as S1-1. **Passed on iOS 26.6:** the `-s ac2` runner's first phase
unlocks vault A with biometrics off and then asserts that
this database has no keystore entry. It also runs a **positive control** —
it deliberately writes an entry, confirms the probe can see it, and removes it
again — so an `absent` result cannot be a probe that is simply blind.

Do not substitute the macOS result: the spec forbids one platform qualifying
another.

---

### S2-2 · Nothing survives process kill, iOS (spec 011 AC-2)

Same intent as S1-2. The inspection half is the `-s ac2` runner's second
process: it asserts no entry survived and that the stored-credential
unlock path refuses, which is what makes the app ask for the password again.
It then unlocks with the password to prove the refusal was "no stored secret"
rather than "the vault is broken".

The **user-visible half is worth running by hand as well**, because the probe
drives the coordinator and not the UI:

**Steps**

1. Unlock vault A with biometrics off.
2. Swipe the app out of the app switcher to terminate it.
3. Relaunch and open vault A.

**Expected observation.** The app asks for the master password again.

**Fails if.** The vault opens without asking. Note this is weaker evidence than
AC-2 requires — it shows the app does not *use* a persisted secret, not that none
*exists*.

---

### S2-3 · Biometric unlock after a kill (spec 011 AC-3)

**Preconditions.** Vault A with biometric protection on, enrolled by one manual
unlock after enabling.

**Steps**

1. Terminate the app from the app switcher.
2. Relaunch, select vault A, trigger biometric unlock, authenticate.
3. Cancel the biometric prompt on a second attempt and confirm the master
   password field is reachable (regression guard for #71).

**Expected observation.** Step 2 opens the vault. Step 3 offers a working
password fallback.

**Fails if.** Biometric unlock is not offered, fails, or the cancel path dead-ends.

---

### S2-4 · Two databases, biometrics on only one (spec 011 AC-5), behavioural half

**Steps**

1. Unlock vault B manually.
2. Switch to vault A and biometric-unlock it.

**Expected observation.** A opens. No wrong-password error, which would be the
symptom of the old global key serving B's password to A.

**Fails if.** A's biometric unlock reports a wrong password, or B ever offers a
biometric unlock it was never enrolled for.

---

### S2-5 · Upgrade from a pre-011 build (spec 011 AC-6), behavioural half

**Preconditions.** A pre-`027641d` build installed and unlocked once, then the
current build installed over it **without deleting the app**.

**Steps**

1. Launch the upgraded build once, reaching database selection.
2. Unlock vault A with its master password.
3. If vault A had biometrics on before the upgrade, observe what the app now
   offers.

**Expected observation.** The vault opens with the password. Re-enrolment of
biometrics at the next manual unlock is **expected and correct** (FR-6 is a
deliberate one-time silent re-enrolment), not a defect.

**Fails if.** The vault refuses a password that worked before the upgrade, or the
app crashes on first launch after the upgrade.

---

### S2-6 · Apple autofill smoke (spec 011 FR-8)

**Preconditions.** Custode enabled under Settings → General → Autofill &
Passwords. Vault A unlocked at least once so credentials are published. A test
site with a login form in Safari.

**Steps**

1. Unlock vault A, confirm at least one entry with a URL matching the test site.
2. Background the app.
3. In Safari, focus the username field on the test site.
4. Choose Custode from the QuickType bar, authenticate.
5. Confirm the filled username and password match the vault entry.
6. Lock the vault in the app, then repeat steps 3–4.

**Expected observation.** Steps 4–5 fill the correct credentials. After step 6
the extension either offers nothing or asks to unlock — it never serves a stale
credential from a locked vault.

**Fails if.** Wrong credentials are offered, credentials for a non-matching
domain appear, or the extension still fills after the vault is locked. The last
one is a security failure, not a bug: stop and report it.

---

## S3 — macOS machine

This session is the largest because one Mac covers three separate debts: the
macOS half of spec 011, the whole browser-extension debt of spec 009, and the
signed-and-sandboxed Release check of spec 008.

**Session preconditions**

- macOS build: `flutter run -d macos --dart-define-from-file=.env.dart.define.json`.
- Chrome installed. Microsoft Edge installed (required by S3-8; without it that
  item is `not-run`, not skipped).
- Native host installed: `./desktop/native_host/install_host_macos.sh <EXTENSION_ID>`,
  and for Edge the same script with `edge`.
- Extension loaded unpacked from `desktop/browser_extension/`, or from the ZIP
  built by `./desktop/browser_extension/package_extension.sh`.
- Two test vaults, A and B.

**Keychain inspection command.** The app stores through
`flutter_secure_storage_darwin`, which writes generic-password items. The plugin
sets `kSecAttrService` only when the app passes a service, and this app passes
none, so the item may carry **no service attribute** — meaning a
`security find-generic-password -s <something>` lookup can miss an entry that is
really there. Search by account instead, and confirm with a full dump:

```bash
# Targeted: the account is the storage key.
security find-generic-password -a 'MASTER_PASSWORD' -g 2>&1 | head -20
security find-generic-password -a "MASTER_PASSWORD.<databaseId>" -g 2>&1 | head -20
# "The specified item could not be found in the keychain." == absent == pass for AC-1.
```

```bash
# Broad confirmation, because absence is the thing being proven and a missed
# lookup would fake a pass. Inspect every matching account name.
security dump-keychain ~/Library/Keychains/login.keychain-db \
  | grep -i -A2 'MASTER_PASSWORD'
```

`security dump-keychain` prompts for permission per item; approve with "Allow",
not "Always Allow". **To be discovered:** whether the sandboxed Release build
writes into `login.keychain-db` or into the data-protection keychain, which
`dump-keychain` does not read. Until that is settled, treat a clean dump from a
**Release** build as weaker evidence than the same dump from the debug build, and
say so in the status table.

---

### S3-1 · Keystore untouched with biometrics off, macOS (spec 011 AC-1)

**Steps**

1. Quit the app entirely.
2. Launch, unlock vault A (biometrics off) with the master password.
3. Run both keychain commands above.

**Expected observation.** Neither `MASTER_PASSWORD` nor
`MASTER_PASSWORD.<id of A>` is found.

**Fails if.** Either is present while biometrics are off.

---

### S3-2 · Nothing survives a process kill, macOS (spec 011 AC-2)

**Steps**

1. With vault A unlocked, kill the process:
   `pkill -9 -f kdbxKeyVault` (verify the match with `pgrep -fl kdbxKeyVault`
   first).
2. Run the keychain commands.
3. Relaunch and open vault A.

**Expected observation.** No entry after the kill; the app asks for the password.

**Fails if.** An entry survives, or the vault opens without a password.

---

### S3-3 · Two databases, biometrics on only one, macOS (spec 011 AC-5)

**Steps**

1. Enable biometric protection on vault A and enrol it with one manual unlock.
2. Quit, relaunch, unlock vault B manually.
3. Switch to vault A and unlock it with biometrics.
4. Run the keychain commands for both database ids.

**Expected observation.** Only `MASTER_PASSWORD.<id of A>` exists. B has no
entry. Bare `MASTER_PASSWORD` does not exist.

**Fails if.** B has an entry, or A's biometric unlock reports a wrong password.

---

### S3-4 · Upgrade from a pre-011 build, macOS (spec 011 AC-6)

**Steps**

1. Run a pre-`027641d` build, unlock vault A once.
2. Confirm the bare `MASTER_PASSWORD` account exists. If it does not, the
   precondition is unmet and the item proves nothing.
3. Run the current build once.
4. Re-run the keychain lookup for the bare account.
5. Unlock vault A with its master password.

**Expected observation.** The legacy account is gone after step 3; the vault
opens at step 5.

**Fails if.** The legacy account survives, or the vault stops opening.

---

### S3-5 · Desktop browser autofill smoke (spec 011 FR-8)

**Preconditions.** Native host installed, extension loaded, overlay toggle on,
vault A unlocked with an entry whose URL matches the test page.

**Steps**

1. Serve a login page locally. The visual harness page is already in the repo and
   is the closest thing to a prepared fixture:
   `desktop/browser_extension/test/visual/harness/page.html`. Serve it with
   `python3 -m http.server 8907 --directory desktop/browser_extension/test/visual/harness`
   and open `http://127.0.0.1:8907/page.html`. Port 8907 is what the visual
   runner itself uses (`capture_runner.mjs:42`), so the origin matches the
   captured baselines.
2. Focus the username field. Observe the overlay.
3. Pick the matching entry, authenticate in the app when prompted.
4. Confirm the filled values match the entry.
5. Lock the vault in the app. Focus the field again.

**Expected observation.** Step 3 fills correctly. After step 5 the overlay
reports a locked state and reveals nothing.

**Fails if.** A secret is filled while the vault is locked, or an entry appears
for an origin it is not bound to. Both are security failures — stop and report.

---

### S3-6 · Slice C: single broad prompt under a gesture (spec 009, Slice C debt)

**Why this is here.** Slice C changed the authorization surface: the popup now
asks once for the broad `http://*/*` + `https://*/*` optional grant. The failure
mode found in the earlier smoke — the popup closing and losing the gesture — was
caught by mutation A2-M15, **not** by the automated suite, so a human still has
to see the prompt.

**Status: `not-run` — re-attempted for real on this machine, 2026-08-25, and
blocked before either half could be observed.** This is a session/sandbox
limitation, not a product finding: everything this session *could* actually
observe behaved exactly as expected.

The extension was loaded unpacked for real in real Chrome 151/macOS.
`--load-extension` was refused outright by this machine's Chrome build
(`--load-extension is not allowed in Google Chrome, ignoring.`, confirmed via
`--enable-logging=stderr --v=1`; `defaults read
/Library/Managed\ Preferences/com.google.Chrome.plist` shows this Mac is under
Chrome Enterprise policy, with its own `ExtensionInstallForcelist` /
`ExtensionInstallBlocklist`). Worked around with the CDP-native
`Extensions.loadUnpacked` command, which Chrome 151 supports as the documented
remote-debugging equivalent of `--load-extension` — not a change to extension
behaviour.

From there the popup was opened as a real page target
(`chrome-extension://<id>/popup.html`) and the "Turn on" toggle was hit with a
genuinely trusted click (CDP `Input.dispatchMouseEvent`, not `element.click()`).
This reliably invoked `chrome.permissions.request()`: across several repeated
runs the popup's UI stayed on its "Off" render rather than flipping to
"denied" for 20+ seconds, exactly the behaviour expected of a promise that is
genuinely waiting on a human to answer a live prompt, not a broken call. But
the prompt itself never became observable or acceptable from this session:

- The permission bubble is native browser UI (a Views bubble), not a page.
  Exhaustive `Target`-discovery polling (every 150 ms for 6-20 s immediately
  after the click, across several runs) never found an attachable target for
  it — the only new targets were unrelated background/service-worker
  wake-ups belonging to Chrome's own component extensions.
- Accepting it therefore needs OS-level UI automation, or at least a
  screenshot to locate it. Both are unavailable in this sandbox:
  `osascript`/System Events fails immediately with `-25211 ("osascript is not
  allowed assistive access")`, and `screencapture` fails with `"could not
  create image from display"`. Both are macOS TCC-gated (Accessibility,
  Screen Recording) and neither can be granted without a human interactively
  clicking through a System Settings consent dialog — there is no scriptable
  opt-in from inside the session.
- `--headless=new` does not auto-resolve the prompt either — same pending
  state.
- There is no API back door for this extension's manifest shape: calling
  `chrome.developerPrivate.updateExtensionConfiguration({hostAccess:
  "ON_ALL_SITES"})` from the privileged `chrome://extensions` page context
  returns success but is a genuine no-op (`chrome.permissions.getAll().origins`
  stayed `[]` before and after) — this extension declares only
  `optional_host_permissions`, not a withholdable `host_permissions`, and
  Chrome's site-access toggle only manages the latter.

Net: the grant half could not be completed here, and the revoke half has no
granted state to revoke from without it, so neither half was re-verified this
session. `specs/009-in-page-autofill-overlay/tasks.md` A046 row 22 is
reconciled separately to reflect this (its own "still due" detail for the
revoke half, not the summary line that briefly contradicted it, is what this
session's evidence actually supports).

**Steps**

1. In `chrome://extensions`, remove all site access from the extension.
2. Open the popup and click the single toggle once.
3. Observe the Chrome permission prompt.
4. Accept it.
5. Reopen the popup.
6. In `chrome://extensions`, check the site-access state.
7. **The revoke half.** In `chrome://extensions`, set site access back to "on
   click". Reopen the popup.

**Expected observation.** Exactly one prompt, naming both patterns, appearing on
the first click without a second gesture. The toggle reads **on** afterwards, and
`chrome://extensions` shows access on all sites. After step 7 the toggle reads
**off** and stays off — reconciliation must treat an externally revoked grant as
a durable disable, not as a transient error.

**Fails if.** The prompt does not appear on the first click, the popup closes and
the grant is lost, or the toggle reads on while `chrome://extensions` shows no
access. Step 7 fails if the toggle still reads on after the grant was revoked,
or if it re-prompts by itself without a gesture.

Step 7 carries the revoke half of the old per-origin A046 row 2, which had no
home after Slice C; it is automated only by `A020: a permission revoked outside
the popup durably disables the overlay`.

---

### S3-7 · Slice C: real v1 → v2 upgrade with a residual broad grant (spec 009, Slice C debt)

**Why this is here.** The v1 → v2 migration is not a dedicated branch — it is the
strict-parser fail-closed path. A v1 value, *including one whose broad grant is
already held*, must migrate to DISABLED and have the residual grant revoked.

**Status: `passed` on macOS / Chrome 151, 2026-08-24.** This is the one item in
this whole file that has been executed. It is kept here rather than removed
because it is still owed on Edge (see S3-8) and must be re-run whenever the
migration path or the revision floor changes.

**Steps**

1. Install a pre-Slice-C build of the extension (a checkout before `b466ed9`).
2. Enable the overlay on at least two sites, so the v1 `enabledOrigins` array is
   non-empty.
3. In `chrome://extensions`, set site access to **On all sites** by hand.
4. Load the current extension over it, keeping the same profile and extension id.
5. Open the popup.
6. Check `chrome://extensions` site access.

**Expected observation.** The toggle is **off** after the upgrade. Site access is
back to on-click/none — the residual broad grant was revoked, not inherited.

**Fails if.** The toggle reads on without the user asking, or the broad grant
survives. A grant surviving a fail-closed migration is a security failure.

**Recorded observation — macOS, Chrome 151, 2026-08-24.** Run on a profile that
really held a v1 config with enabled origins, observed live over CDP rather than
inferred from the UI:

- `overlayConfigV1` gone from `chrome.storage.local`.
- `overlayConfigV2 === {enabled: false, revision: 3, version: 2}` — migrated to
  DISABLED, and the revision floor held across the version boundary.
- `chrome.permissions.getAll().origins === []` — the residual per-origin grants
  were **revoked, not inherited**. This is the security half of the item.
- Zero content-script registrations.

This is the first human confirmation of what `A016: a v1 config migrates to
disabled even when the broad grant is already held` and `A016: migration revokes
every residual per-origin grant and registration` assert in
`desktop/browser_extension/test/overlay_lifecycle.test.js`. It closes A046
row 21 in `specs/009-in-page-autofill-overlay/tasks.md`; A046 rows 22–24 and the
Edge subset remain due.

---

### S3-8 · Edge subset (spec 009 A046 row 16 — never run on any row)

**Preconditions.** Edge installed; native host registered for Edge
(`./desktop/native_host/install_host_macos.sh <EXTENSION_ID> edge`); extension
loaded in Edge.

**Steps**

1. Repeat S3-6 in Edge: single broad prompt under a gesture, including the
   revoke half.
2. Repeat S3-5 in Edge: overlay appears, fill works, locked vault reveals
   nothing.
3. Navigate away with the overlay open and confirm it tears down.
4. Repeat S3-7 in Edge: the v1 → v2 upgrade. Passing it on Chrome does not fill
   in this row — host evidence never qualifies another platform, and that rule
   applies across browsers here too.

**Expected observation.** Behaviourally identical to Chrome.

**Fails if.** Any step diverges from Chrome. **Pixel differences are not a
failure** — Edge is explicitly not pixel authority; only the 18 canonical Linux
baselines are.

---

### S3-9 · VoiceOver re-confirmation of the #81 fix (spec 009 A040)

**Why this is here.** The original VoiceOver session found two real defects:
arrow keys moved the VoiceOver cursor instead of the overlay selection, and
activation was impossible because `aria-activedescendant` does not cross a
**closed** shadow root, so Enter fell through as an implicit page submit. The fix
(#81 — a light-DOM listbox mirroring the shadow rows, `press` handled on the rows,
an `isTrusted` guard on every activation handler) is pinned by
`test/overlay_at_activation.test.js`. **A harness is not a screen reader.** This
item is that reconfirmation.

**Steps**

1. Serve the harness page as in S3-5.
2. Turn VoiceOver on (⌘F5).
3. Focus the username field and let the overlay open.
4. Listen for the live-region announcement.
5. Arrow down through the suggestions.
6. Activate the selected row with VoiceOver's activation (VO-Space).
7. Note whether the form submitted.

**Expected observation.** Step 4 announces the suggestion count
(e.g. *"2 suggestions"*). Step 5 moves the **overlay selection**, announcing each
row. Step 6 fills the field. Step 7: **the form does not submit.**

**Fails if.** Nothing is announced, arrows move only the VoiceOver cursor while
the overlay selection stays put, activation does nothing, or the page submits.
The last one is the #81 regression returning.

---

### S3-10 · Keyboard-only, no assistive technology (spec 009 A040, first row)

**Status: `passed` on Chrome 151/macOS, 2026-08-25.** This is the first line of
A040's own requirement. Until this date its only evidence was the six `A037:`
cases in `test/overlay_interaction.test.js`, which #121 had already shown to be
insufficient for this row: #121 was found in live QA, not by the suite, and it
presented **as a broken keyboard** — Enter on a suggestion threw in an orphaned
content-script world and the overlay vanished silently, while a CDP trace proved
arrows and Enter had been delivered and handled correctly the whole time. The six
`A037:` cases never run in an orphaned world.

**Recorded observation.** Driven through a live CDP trace with real dispatched
keys (not synthetic DOM events) against the running extension: click the
password field, Enter with no arrow selects and fills the exact-origin
suggestion (`pw:4 usr:3` in the trace, overlay closed, no implicit-submit
signal at any point); Escape closes with no side effect; Tab closes and
advances focus normally. This same pass first reproduced a real regression —
Enter was implicitly submitting the empty form — root-caused and fixed in
#132 (session listener moved to `document` capture, closing the race a
page/framework listener on the anchor could otherwise win against the
overlay's own `preventDefault()`), then re-run clean against the fix. See
`specs/009-in-page-autofill-overlay/tasks.md` A040 for the full evidence.

**Because of that history, still reload the extension before you start this
item**, and do not begin from a tab that was open across a reload — otherwise a
pass here proves nothing and a failure will be misread as a keyboard bug. If the
overlay ever disappears with no message during this item, check for the orphan
tombstone ("reload this page") first: that is #121's shape, not a keyboard
defect.

**Steps**

1. Serve the harness page. VoiceOver **off**.
2. Reach the username field using Tab alone — no mouse from here on.
3. Arrow down and up through the suggestions.
4. Press Escape.
5. Reopen the overlay, press Enter on a selection.
6. Reopen, then press Tab.

**Expected observation.** Step 3 moves a visible selection. Step 4 closes the
overlay and leaves focus in the field. Step 5 fills the field **without
submitting the form** — note this only holds for a suggestion that is an exact
scheme/port match; a domain-only ("possible") match is correctly never
fillable by design (SR-2), and Enter on one is expected to no-op rather than
fill. Step 6 closes the overlay and moves focus onward normally.

**Fails if.** Focus is trapped, the selection is invisible, Escape does not
close, or Enter submits the page. Enter silently doing nothing on a
domain-only match is **not** a failure of this item; confirm the entry's
match type before treating it as one.

---

### S3-11 · Signed, sandboxed macOS Release: does the safe-writer fallback actually fire? (spec 008, "not verifiable on host")

**Why this is here, precisely.** Under the macOS app sandbox the
`files.user-selected.read-write` entitlement authorizes the **chosen path**, not
its parent directory, so creating a sibling temp file can fail with
`Operation not permitted` where a direct write to the same path succeeds
(`safe_vault_file_writer.dart:411-423`). Every host test simulates that refusal
through a fault seam. Whether the real sandbox produces an error the code
classifies as a permission denial has **never been observed in a signed Release
build** — and if it does not, saves fail instead of degrading.

There is a second, sharper consequence to check, documented as MEDIUM-2: the
fallback covers the **temp only**. `createBackup` also creates a sibling and gets
**no** fallback, because skipping a backup is what FR-9 forbids. So a sandbox
that authorizes only the chosen path should fail a *backup-requesting* save
outright rather than silently skipping the backup.

**Preconditions.** A **signed, sandboxed Release** build —
`flutter build macos --release` plus the normal signing — launched from
`/Applications` or from the build output, **not** `flutter run`. Debug builds
loosen exactly the behaviour under test.

**Steps**

1. Open a vault from a location outside the app container, chosen through the
   system open panel: `~/Documents`, or an external volume.
2. Edit an entry and save.
3. Watch the log: `log stream --predicate 'process CONTAINS "kdbxKeyVault"' --info`.
4. Note whether the atomic path or the fallback ran, and whether the fallback
   named the operation.
5. List the vault's directory: confirm a backup exists and no `.tmp` remains.
6. Reopen the vault and confirm the edit persisted.

**Expected observation.** One of two acceptable outcomes, and you must record
**which**: either the atomic temp+rename path ran with no warning, or the
permission refusal was caught and the fallback wrote in place, logging the
degradation with the operation name. Data intact either way.

**Fails if.** The save fails with an unhandled permission error, the log shows a
refusal that the fallback did not catch, the vault is truncated, or a `.tmp` file
is left behind. A backup-requesting save that *succeeds without producing a
backup* is also a failure — that is the MEDIUM-2 asymmetry being violated.

---

### S3-12 · An `http(s)` iframe under a top document with no origin (spec 009 A046 row 23, new with Slice C)

**Status: `passed` on Chrome 151/macOS, 2026-08-25.** Slice C made this case
*more* reachable, not less: the broad grant injects the content script into
every `http(s)` frame, including one nested inside a tab whose top document has
no canonicalizable origin (`file://`, `view-source:`, a PDF). The A035 policy
says such a child is **unsupported** — the extension must not lend it an
identity it cannot derive.

Two of the three halves were already pinned: the **classifier**, by `a child
frame under a non-canonicalizable top is still unsupported` in
`test/frame_context.test.js` — a unit test over `computeFrameSupport` with
synthetic top URLs — and the **rendering**, by 2 of the 18 approved baselines
(`overlay-chrome-1440x900-dpr1-{light,dark}-unsupported-frame.png`). This item
covers the third: **reachability in a real browser**.

**Recorded observation.** A `file://` page hosting `<iframe
src="http://localhost:8000/">` was opened directly. Injection into the child
frame was confirmed (its own isolated world exists). A live `bootstrap` round
trip from that frame returned `{enabled: true, frameSupport: "unsupported",
topOrigin: null}`. On real focus of the password field inside the iframe, the
closed-shadow overlay rendered — piercing the shadow root via CDP DOM confirmed
the text — *"The overlay is not available in this frame. Copy your login from
the Custode app."*, an empty suggestion list, and a disabled Generate control.
No `requestMatches` or `fill` message was ever sent.
**Correction, made from that observation**: the step 4 expectation below
previously said no overlay appears at all — that undersold it. A hint overlay
DOES appear; the point is that its content is the fail-safe message above, with
zero fillable options, not that nothing renders. Corrected below. Separately,
the popup does not carry a distinct literal "unsupported" label for this case:
with a `file://` tab active it shows the same "Open an http(s) page…" copy any
non-http(s) top-level tab gets, since the popup only ever looks at the tab's own
URL, never a child frame's.

**Steps**

1. Turn the overlay toggle **on** (broad grant held).
2. Save a local `.html` file that embeds the S3-5 harness page in an `<iframe>`
   pointing at `http://localhost:8907/...`.
3. Open that file with a `file:///` URL — not through the local server.
4. Focus the username field **inside the iframe**.
5. Open the extension popup while that tab is focused.
6. Repeat with `view-source:` on any `http(s)` page containing a form, and with a
   PDF opened in Chrome's viewer.

**Expected observation.** A hint overlay appears at step 4 — this is correct,
not a failure — showing "The overlay is not available in this frame. Copy your
login from the Custode app.", an empty option list, and a disabled Generate
row; no suggestion is offered and nothing is fillable. The popup at step 5 shows
its ordinary no-origin copy (the same text any non-http(s) tab gets), not a
frame-specific label. The content script is injected — this is not a "nothing
happened" pass; confirm the injection actually occurred (DevTools → Sources,
isolated world) so that the unsupported classification is what you observed,
not the absence of injection.

**Fails if.** The overlay offers a real suggestion or fills inside that iframe.
**That is a security failure** — an origin the extension cannot canonicalize
would be borrowing one it can. Stop and report. It is also a failure, of a
lesser kind, if the hint text or the disabled Generate control is missing, or
if no injection happened at all, since the latter means this item did not test
what it claims.

---

### S3-13 · Universal injection: performance and CSP regression (spec 009 A046 row 24, new with Slice C)

**Why this is here.** Under the per-origin model the content script ran only on
sites the user had opted into. It now runs in **every frame of every `http(s)`
page** at `document_idle`. Nothing has measured that, and this row has **no
automated coverage of any kind** — it is the one Slice C row with no safety net
at all.

**Status: `not-run`** — partially executed under a documented substitution on
macOS / Chrome 151, 2026-08-25: **top frame only**. The `allFrames: true`
dimension this row exists for was not exercised. The evidence gathered is
recorded below in full because it is useful (strict-CSP behaviour, console
silence, top-frame cost), but it does not close the row.

**Substitution, stated plainly.** This session could not toggle the real
popup's broad-permission switch on: blocked for the same reason documented in
S3-6 (the native `chrome.permissions.request()` prompt cannot be accepted in
this sandbox). Since this row is about the cost and CSP-behaviour of the
*actually-injected runtime files*, not about the popup/permission UX, it was
executed instead with the same throwaway-harness-extension technique
`test/visual/capture_runner.mjs` already uses for A041: the unmodified
production `overlay_security.js` and `content_overlay.js` (sha256-verified
identical to the committed files at run time) plus the existing test-only
`background_stub.js`, loaded via CDP `Extensions.loadUnpacked`.

**What the harness does not reproduce, and why that matters here.** The harness
manifest is not production's injection. Production registers the same two files
at runtime through `scripting.registerContentScripts` with `allFrames: true`
and `persistAcrossSessions: true` (`desktop/browser_extension/overlay_lifecycle.js`,
`globalRegistration()`). The harness declares a *static* `content_scripts`
entry with no `all_frames` key at all — the default is `false`, so the script
ran in the **top frame only**, and the dynamic-registration path was never
exercised. `world: "ISOLATED"` is the only production field the harness omits
harmlessly: it is the default for content scripts, so the isolated-world and
CSP findings below do carry. The per-frame cost of universal injection — the
one thing this row was written to measure on a frame-rich page — was not
measured.

**Recorded observation — macOS, Chrome 151, 2026-08-25.**

- Heavy page: `https://en.wikipedia.org/wiki/World_War_II` (16,973 DOM
  nodes — heavy in nodes, but **not** frame-rich, and injected into the top
  frame only; this is not the page the Steps below ask for). Each measurement was taken on a warm HTTP cache (one throwaway load
  first, then the measured reload), so overlay-off and overlay-on are an
  apples-to-apples comparison rather than cold-vs-warm.
  - Overlay off: load 293 ms, DOMContentLoaded 279 ms, JS heap 9.37 MB.
  - Overlay on (harness injected, hard reload): load 143 ms,
    DOMContentLoaded 57 ms, JS heap 9.72 MB.
  - No regression detectable above measurement noise, and the measurement is
    **not conclusive**: overlay-on came out ~2x *faster* than overlay-off
    (143 vs 293 ms load, 57 vs 279 ms DCL), i.e. the run-to-run variance is
    larger than any effect being looked for. n=1 per condition, and no CPU,
    rendering or frame-timing metric was collected at all. The JS-heap delta
    (+0.35 MB) is consistent with one lightweight injected content script.
    Zero console/log/exception events fired on this page with the overlay on.
- Strict-CSP site: `https://github.com/login`. Header fetched directly
  (`curl -sI`, outside the page so as not to be subject to the very CSP being
  tested): `content-security-policy: default-src 'none'; ...;
  script-src github.githubassets.com; style-src 'unsafe-inline'
  github.githubassets.com; ...` — no inline scripts, no `unsafe-eval`,
  explicit allow-list only. Zero console/log/exception events during load.
  Focusing the page's real `#password` field mounted the overlay (two
  `position: fixed` host `DIV`s), and piercing the closed shadow root via CDP
  `DOM.getDocument({pierce: true})` (the same technique
  `capture_runner.mjs`'s `collectTexts` helper uses) found the real overlay
  text `"2 Custode suggestions"` and `"Open Custode to generate a
  password."` — a screenshot confirmed the suggestion list rendered directly
  under GitHub's own password field. No CSP violation of any kind was
  logged, confirming the isolated world is unaffected by the page's CSP. The
  two suggestions shown ("Personal login / example.com", "Work login /
  login.example.com") are the harness's own synthetic fixture data (the same
  `background_stub.js` A041 already uses) — no live app/vault was involved
  in this session.
- Ordinary sites with the overlay on: `https://en.wikipedia.org/` and
  `https://news.ycombinator.com/` — zero console/log/exception events on
  either. This also matches a static-source finding: `content_overlay.js`
  and `overlay_security.js` contain zero `console.*` calls in the committed
  source, so there is no logging surface to leak origin/entry/secret-shaped
  data from in the first place.

This **partially** executes A046 row 24 in
`specs/009-in-page-autofill-overlay/tasks.md`. The residue that keeps both the
row and this item open: a heavy, frame-rich page injected with
`allFrames: true` via the production dynamic registration.

**Steps**

1. Toggle the overlay **off**. Load a heavy, frame-rich page (a large news site,
   a web app with many iframes). Record load time and memory from DevTools →
   Performance/Memory.
2. Toggle **on**. Hard-reload the same page. Record the same two numbers.
3. With the overlay on, load a site sending a strict `Content-Security-Policy`
   (GitHub is a convenient one). Open the console.
4. On that strict-CSP site, focus a login field and confirm the overlay still
   works.
5. Check the console on several ordinary sites for anything the extension logs.

**Expected observation.** No user-perceptible load-time regression between steps
1 and 2. No CSP violation attributable to the extension in step 3 — the isolated
world is not governed by page CSP, so a violation naming extension code is a real
finding, not noise. Step 4 works normally. Step 5 shows **nothing**: no origins,
no entry names, no secrets, no chatter.

**Fails if.** Any secret-shaped or vault-derived value reaches the console on any
page — that is a security failure, stop and report. A visible load-time or memory
regression, a CSP violation naming extension code, or the overlay failing only on
strict-CSP sites are functional failures.

---

## S4 — Windows machine

**This session is deliberately short.** PRs #114 and #117 added a blocking
`test-windows` job on `windows-2022` to `.github/workflows/pr.yml`, and it moved
real coverage out of manual QA. See "Removed" below for exactly what left.

**Session preconditions**

- A Windows build of the app.
- The repository checked out, Flutter available.
- Two test vaults.

**Credential inspection: partially known, stated honestly.**
`flutter_secure_storage_windows` 4.1.0 writes `CRED_TYPE_GENERIC` entries through
`CredWriteW`. Generic credentials are listable with:

```powershell
cmdkey /list
```

**To be discovered before this is a reliable check:** the exact `TargetName` the
plugin composes for a key. The plugin builds it in
`flutter_secure_storage_windows_plugin.cpp`, but the composition was not read
during the writing of this checklist, so the string to grep for is **not
known**. Do not guess it. Establish it once — write a known key from a debug
build, diff `cmdkey /list` before and after — and then record the shape here.
`cmdkey` never prints secret values, so this remains a presence/absence check.

---

### S4-1 · Keystore behaviour on Windows (spec 011 AC-1 / AC-2)

**Blocked** on the target-name discovery above. Record `not-run` with that
reason. Spec 011's test plan explicitly permits this: *"Desktop secure store
inspection on macOS, Linux and Windows, or the platform is recorded as `not-run`
rather than assumed passing."*

The behavioural half is runnable now: unlock a vault with biometrics off, kill
the process from Task Manager, relaunch, and confirm the app asks for the master
password again. Fails if it does not.

---

### S4-2 · Saving a vault held open by another process

**Why manual.** CI **measured** this: `File.rename` over an open handle is
refused on Windows with `ERROR_ACCESS_DENIED` where POSIX silently succeeds. The
writer holds its contract — old vault byte-identical, error propagated, no `.tmp`
residue — and that is asserted per platform in CI. What CI cannot show is the
**product** consequence: on Windows, saving a vault another instance holds open
**fails**. This item confirms the user-facing shape of that failure.

**Steps**

1. Open vault A in the app.
2. From a second process, hold the file open — a second app instance, or a
   backup tool.
3. Edit an entry in the app and save.
4. Read the error the user actually sees.
5. Release the second handle, save again.
6. Confirm the vault is intact and the edit landed.

**Expected observation.** Step 3 fails with a message a user can act on. Step 5
succeeds. The vault is never truncated and no `.tmp` file is left behind.

**Fails if.** The error is a raw OS code or a silent no-op, the vault is
corrupted, or a `.tmp` file survives.

---

### S4-3 · A machine without Developer Mode

**Why manual, precisely.** CI **measured** that GitHub-hosted `windows-2022`
runners create symlinks without Developer Mode, so the three symlink QA suites
genuinely run there. The caveat in `AGENTS.md` therefore applies to **local
developer machines**, not CI. What no runner can reproduce is a machine where
symlink creation is actually denied.

**Steps**

1. On a Windows machine with Developer Mode **off**, in a **non-elevated** shell,
   run:
   ```
   flutter test test/features/password_manager/data/portable_path_symlink_qa_test.dart test/core/utils/mobile_file_storage_guard_qa_test.dart test/core/utils/mobile_file_storage_guard_bypass_qa_test.dart
   ```
2. Record which failures are `Link.create` permission errors.
3. Launch the app, open a vault, edit and save an entry.

**Expected observation.** Step 1 may fail — that is an **environment** result,
not a product defect, and must be recorded as such. Step 3 must work regardless:
the app itself never needs to create a symlink.

**Fails if.** The app cannot save, or a failure at step 1 is something other than
a symlink-privilege error.

---

## S5 — Linux machine

**Session preconditions**

- A Linux build of the app.
- `libsecret` tools installed (`secret-tool`) and a running keyring daemon.
- Two test vaults.

**Secret store inspection command, in full.** `flutter_secure_storage_linux`
3.0.2 stores through libsecret with a single attribute, `account`, set to
`<APPLICATION_ID>.secureStorage` (`flutter_secure_storage_linux_plugin.cc:209`).
`APPLICATION_ID` is `dev.camillobucciarelli.kdbxKeyVault`
(`linux/CMakeLists.txt:10`).

```bash
# All items this app owns. Prints attributes; secrets are shown for matches,
# so run it where nobody is watching your screen.
secret-tool search --all account dev.camillobucciarelli.kdbxKeyVault.secureStorage
```

```bash
# Or browse the same collection in a GUI.
seahorse
```

The plugin keeps all keys in **one** libsecret item as a JSON map, so this is a
check on the map's *contents*, not on a per-key item. Read the returned value and
look for the key names `MASTER_PASSWORD` and `MASTER_PASSWORD.<databaseId>`.

---

### S5-1 · Keystore untouched with biometrics off, Linux (spec 011 AC-1)

**Steps**

1. Quit the app.
2. Launch, unlock vault A (biometrics off) with the master password.
3. Run the `secret-tool` command.

**Expected observation.** No item, or an item whose map contains neither
`MASTER_PASSWORD` nor `MASTER_PASSWORD.<id of A>`.

**Fails if.** Either key is present with biometrics off.

---

### S5-2 · Nothing survives a process kill, Linux (spec 011 AC-2)

**Steps**

1. With vault A unlocked, `pkill -9 -f kdbxKeyVault` (confirm the match with
   `pgrep -fl kdbxKeyVault` first).
2. Re-run the `secret-tool` command.
3. Relaunch and open vault A.

**Expected observation.** No master-password key after the kill; the app asks for
the password.

**Fails if.** A key survives, or the vault opens without a password.

---

### S5-3 · Desktop browser autofill smoke on Linux (spec 011 FR-8)

**Preconditions.** Native host installed
(`./desktop/native_host/install_host_linux.sh <EXTENSION_ID>`, add
`--browser chromium` for Chromium), extension loaded, overlay toggle on.

**Steps**

1. Serve the harness page:
   `python3 -m http.server 8907 --directory desktop/browser_extension/test/visual/harness`.
2. Open `http://127.0.0.1:8907/page.html`, focus the username field.
3. Fill from the overlay and confirm the values.
4. Lock the vault; focus the field again.

**Expected observation.** Step 3 fills correctly; step 4 reveals nothing.

**Fails if.** A secret is served while locked, or an entry appears for an origin
it is not bound to.

---

## Removed from the manual list

Each entry names what was dropped and why. Dropping is deliberate: a list that
only grows stops being read.

### Removed because CI now covers it (PRs #114, #117 — job `test-windows`, blocking)

| Was | Now |
| --- | --- |
| "Verify `File.rename` over an open handle on Windows" | **Measured in CI** on `windows-2022`. Windows refuses with `ERROR_ACCESS_DENIED` where POSIX silently succeeds; the writer's contract (old vault byte-identical, error propagated, no `.tmp` residue) is asserted **per platform**, not with a test that accepts either outcome. Only the user-facing failure shape stayed manual, as **S4-2**. |
| "Run the three symlink QA suites on Windows" | **They really run in CI.** A probe step measured `SYMLINK_CAPABLE=true` on GitHub-hosted `windows-2022` (run 32596328624): the runners create symlinks without Developer Mode. `portable_path_symlink_qa_test.dart`, `mobile_file_storage_guard_qa_test.dart` and `mobile_file_storage_guard_bypass_qa_test.dart` all execute. Only the **no-Developer-Mode local machine** case stayed manual, as **S4-3**. |
| "Check the Windows branch of `_isPermissionDenied`" | **Asserted in CI.** It previously asserted nothing: the T110 harness encoded POSIX errno values as universal constants, so the Windows fallback never fired and the negative control (`EIO` 5) collided with `ERROR_ACCESS_DENIED`. Closed with per-platform helpers plus an anti-collapse guard that fails if the two codes coincide. |
| "Run the Flutter suite on Windows before a release" | **Runs on every PR.** `test-windows` is green and blocking (`continue-on-error` removed). *Outstanding, and not an agent action:* adding `test-windows` to the branch's **required status checks** is a repository branch-protection setting the user must apply. |

### Removed because CI now produces the artifact (job `t111-platform-artifact`)

| Was | Now |
| --- | --- |
| **S4-4**, "T111 Windows platform artifact" | **Produced in CI on every PR.** The T111 harness runner now exists (`tool/run_safety_harness.sh`, `tool/safe_vault_writer_harness.dart`) and the `t111-platform-artifact` job runs its eight cases on `windows-2022`, files a schema-valid `build/safety-evidence/windows/safe-vault-writer.json` and uploads it. This is not host evidence standing in for a target: on Windows the GitHub-hosted runner **is** the target, with a real NTFS volume, so the four capability booleans — above all `atomicReplaceOverExisting`, which is a genuine question on Windows — are measured on the platform they describe. A `failed` artifact exits 2 and fails the job. |
| **S5-4**, "T111 Linux platform artifact" | **Produced in CI on every PR**, same job on `ubuntu-latest`, same argument: the runner is the target, with a real ext4 volume. |

Deciding to **enable** the merge feature on a platform remains a human step:
the artifacts are uploaded, never committed, and the Gate 0 assertion `no
platform artifact exists yet` still fails if one is checked in without
`feasibility-report.md` being updated in the same change.

### Removed because Slice C superseded the behaviour (PR #113)

| Was (A046 rows) | Why it is gone |
| --- | --- |
| Row 2, "grant/deny per origin" | The per-site "Turn on" no longer exists. The durable opt-in is one boolean and the popup asks once for the broad optional grant. Replaced by **S3-6**. |
| Row 3, "scheme/port variants sharing one permission pattern" | This tested per-origin permission-pattern arithmetic, which has no subject left: there is one registration over `http(s)://*/*`. A sibling port is now **served as itself** — still a separate identity toward the vault, so no entry leaks — and that stronger property is pinned by the migrated mutation table. |
| Row 4's per-origin half, "cross-origin child first denied, then enabled on its own origin" | The "enable this child origin" step no longer exists: under the broad grant the child is injected as a matter of course. **Only the per-origin half is gone.** The frame **policy** survives and is more reachable than before — its manual row is **S3-12**, `passed` 2026-08-25 (see A046 row 23 in `tasks.md`). Corrected on 2026-08-24: this entry previously read "so it needs no manual row", which over-claimed; the executable test was a unit test over the `computeFrameSupport` **classifier** with synthetic top URLs, and the 2 golden baselines pinned only the **rendering** — neither pinned **reachability in a real browser**, which S3-12 has since supplied. |

### Removed because a stronger automated check replaced it

| Was | Why it is gone |
| --- | --- |
| A046 row 18, "canonical baseline comparison by a human" | The canonical environment is pinned by immutable OCI digest plus an exact Chrome for Testing build, and `run_visual_baselines.sh --verify` compares decoded pixels **and** approved SHA-256 per baseline: exit 0, 18/18 (A045). A human eye adds no evidence a hash comparison lacks, and would add a false authority. Design changes still require `--approve` behind human review — that is a design gate, not QA. |
| A046 rows 10–15 (app lock, host absent/timeout, restricted page, exact vs domain-only match, crash/restart per disable phase, stale native response) | Kept **off** the manual list on purpose. Each has real automated evidence, named in `tasks.md`, including mutation coverage (A3-M11, A1-M2, A3-M6) and the eight `A021:` crash-injection cases. They are recorded as automation-only rather than re-run by hand; re-running them manually would cost hours and produce weaker evidence than the mutants already give. |

### Recorded as permanent debt, not as a pending step

| Item | Status |
| --- | --- |
| Chrome + NVDA on Windows (spec 009 A040) | **Permanent declared debt.** No Windows machine with NVDA is available. It must never be reported as covered. If a Windows machine appears, it becomes a real S4 item; until then it is not a task waiting to be done. |

### Could not be recovered, and is therefore not written as a step

Two findings named in the debt intake could not be located in `specs/009-*`, in
the extension source, or in recorded session decisions:

- **The LOW finding on the "display-only" ARIA treatment.** Not found. What must
  be re-derived before it can be a checklist item: which element was marked
  display-only, and what the reviewer expected instead.
- **The B2 busy-state copy.** Not found. What must be re-derived: the exact
  string shown while a generate request is in flight, and what it should say.

Both are almost certainly small, but writing plausible steps for them would be
inventing procedure. They are listed here so they are not silently lost. The
generate round trip **that is** recorded — generate → fill → confirmation banner
in the app → confirm → entry present in the vault → consistent re-fill — was
already executed and passed in the A046 session (row 9), and the structural
defect it exposed (#73: B005 had zero production callers) is fixed, so it is not
re-listed as an open item.

---

## What the automation did and did not remove

Written 2026-08-24, replacing the four candidates this section used to propose.
Three of them were built. The accounting below is deliberately unflattering
where it should be: a checklist that shrinks by claiming more than was verified
is worse than one that stays long.

### Built: the T111 harness runner (was candidate 3)

**Removed 2 items: S4-4 and S5-4.** Both are now produced in CI on every PR —
see the "Removed" table above for why a runner *is* the target on those two
platforms and is not on the other three.

**Unblocked, but not removed: S1-7.** It needs Android hardware. It went from
"cannot start" to one command.

What was built:

| File | Role |
| --- | --- |
| `tool/safety_evidence_schema.dart` | The artifact schema, **moved out of the Gate 0 test** so the runner that produces artifacts and the gate that judges them cannot drift. The Gate 0 test now imports it and still pins every rejection. |
| `tool/safe_vault_writer_harness.dart` | The eight required cases. Shared by the device driver and the CI host test — the device contributes hardware, not logic. |
| `integration_test/safe_vault_writer_harness_test.dart` | The on-device driver. Emits the artifact on stdout, because that is the only retrieval path that exists identically on all five targets (there is no `adb pull` for iOS). |
| `tool/file_safety_evidence.dart` | Validates and files. **Refuses** to write anything for a schema-violating artifact or a platform mismatch. |
| `tool/run_safety_harness.sh` | Stamps provenance the device cannot know (commit, Flutter version, the command) and drives the above. `-H` runs on the host, which is what CI uses. |
| `test/tool/safe_vault_writer_harness_test.dart` | Runs the same eight cases in the ordinary suite, every PR. |

**What it measures that the existing host tests did not.** T110 asserts the
writer's control flow against a faked filesystem. The harness runs against the
real volume of the real target, so four facts become measurements instead of
assumptions: `atomicReplaceOverExisting`, `backupNoOverwrite`,
`flushSupported`, `directorySyncSupported`. The first real run already produced
a finding — on macOS `directorySyncSupported` is **false**, because opening a
directory as a file and flushing it is refused there. Production already treats
that as best-effort, so it is not a defect; it is a fact nobody had checked.

**Proof it fails when the property breaks.** Two regressions were introduced
into `safe_vault_file_writer.dart` and the harness caught both:

- exclusive-create replaced with a plain create → `backup_preexisting_name_collision`
  failed with `sentinelIntact=false wroteElsewhere=false` (a real backup
  destroyed), and the `backupNoOverwrite` capability went false, which alone
  forces `status: failed`;
- FR-9's hard stop removed so a failed backup no longer aborts the save →
  `backup_create_failure` failed with `threw=false targetIsOld=false`, i.e. the
  vault was overwritten with no backup.

A defect was also found *by building it*: `file_safety_evidence.dart` returned
its status from `main`, which the Dart VM ignores, so every refusal exited 0
and the runner would have read an unfileable run as a success. Fixed, and
pinned by five process-level tests.

### Built: the keystore probe and the AC-2 / AC-6 lifecycle (was candidates 1 and 2)

**Removed 0 items — stated plainly.** It unblocked S2-1 and S2-2 and gave S1-2
and S1-5 a cheaper route, but nothing left the list. Its first AC-2 phase later
passed on physical iOS 26.6; its corrected cross-process pair still awaits a
hardware rerun, and macOS refuses non-interactive keychain reads. Removing
remaining rows now would be exactly the shortened-by-lying outcome this file
exists to avoid.

Candidates 1 and 2 collapsed into **one** artifact,
`integration_test/master_password_keystore_qa_test.dart`, because the safest
form of candidate 1 was already candidate 2's shape.

**The security constraint, and why it is structural rather than careful.**
Candidate 1 proposed a build-flavor-gated debug screen and flagged that it must
never reach a Release build. That risk was not managed — it was **removed**, by
not putting anything in `lib/` at all:

1. The probe is a file under `integration_test/`, which `flutter build` never
   compiles into any artifact. There is no flavor to gate, no `kDebugMode`
   branch, and no production code was added.
2. The presence primitive is `DatabaseSessionCoordinator.hasStoredMasterPassword()`,
   which **already existed and already returns `bool`**. The probe adds no new
   way to read the keystore.
3. Only `sayBool` and `sayInt` exist in the file. Printing a secret is a
   **compile error**, not a review finding.
4. Every assertion is on a bool or an int, because assertion output is printed
   output and failures are the runs that get pasted into bug reports.

`test/tool/keystore_probe_guard_test.dart` enforces all four on every PR.
Introducing each mistake was checked to turn it red: adding a `String`
reporter, switching to `getMasterPassword` (which returns the plaintext), and
copying the probe into `lib/` each fail with the reason named.

**The `indeterminate` state, which is the most important part.** A keystore
that refuses to answer must never read as "no entry". The probe returns
`present` / `absent` / `indeterminate`, and an `indeterminate` fails loudly
with the diagnosis. This is not hypothetical: it is what macOS does
(`errSecInteractionNotAllowed`, -25308), and it was observed. A `catch (_) =>
false` there would have produced a confident, wrong pass on the one item whose
entire purpose is proving absence.

### Built: `serve_harness.sh` (was candidate 4)

`desktop/browser_extension/serve_harness.sh`. Removes no item, as predicted;
takes about 10 minutes off S3 setup and serves on 8907 so the origin matches
the approved visual baselines.

### Not built: Edge in the extension test matrix (was candidate 5)

Left undone deliberately. As the original entry said, it would cover the
protocol and DOM contract but **not** the permission prompt or the native-host
registration — which are the parts of S3-8 that have never been exercised. It
would shrink no row, and the risk of it being mistaken for closing the Edge row
is higher than its value. Worth doing later, on its own terms.

### Still manual, and why

Every remaining item needs something CI does not have:

- **S1 (Android), S2 (iOS)** — physical devices or emulators, biometric
  hardware, and the OS autofill surfaces.
- **S3-1 to S3-4 (macOS keychain)** — the probe cannot help here: the login
  keychain refuses a non-interactive process, so the `security` commands in
  this file remain the method.
- **S3-5 to S3-13 (browsers, VoiceOver, sandboxed Release)** — a real browser
  with a real permission prompt, a real screen reader, and a signed sandboxed
  build. A harness is not a screen reader, and a debug build loosens exactly
  the sandbox behaviour S3-11 tests.
- **S4-1 (Windows credential store)** — still blocked on the `TargetName`
  discovery, which is unrelated to anything built here.
- **S4-2, S4-3** — the user-facing shape of a Windows failure, and a machine
  where symlink creation is genuinely denied.
- **S5-1 to S5-3** — Linux secret store and a Linux browser session.
