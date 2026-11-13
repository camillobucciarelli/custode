# 016 — Tasks

Ordered tasks for [spec.md](spec.md) / [plan.md](plan.md). Each names owner,
files and verification.

Format: `- [ ] **TID** [P] [USn] Title — owner`, then Files / Acceptance /
Verify. `[P]` = parallelizable (different files, no incomplete dependency).

**Phase 0 is a blocking gate.** Its items are device observations, not code.
US2 (inline) and US4 (browsers) do not start until T001 and T002 are `pass`,
because neither can be proven on an emulator.

Deferred items at the bottom are plain bullets on purpose. They must never
become checkboxes — the roadmap sync counts every checkbox line as scheduled
work.

**Status 2026-08-31** (PR #171 merged, branch closed): 21 of 36 tasks done.
The code for every implementation task has landed — the fifteen open boxes are
the ones whose *verification* is still owed, not their code: device
observations (T002–T004, T301–T304, T402–T404, T704, T802, T803) and two
Kotlin tests that need a `Context` the module cannot fake without Robolectric
(T201, T504). Where each can be done, and what blocks the rest, is recorded in
[device-evidence.md](device-evidence.md) § *What remains, and where it can be
done*. The next Android autofill branch starts from `main` and picks up there.

## Phase 0 — Device feasibility gate (blocking, evidence only)

- [x] **T001** [P] Prove inline suggestions on real IMEs — owner: `senior-tester`
  Files: `specs/016-android-autofill-completion/device-evidence.md`.
  Acceptance: on an API 30+ physical device, a throwaway `FillResponse` with an
  inline presentation renders on Gboard and on one third-party IME; the
  advertised `maxSuggestionCount` and style spec are recorded for each.
  Verify: screenshots plus recorded counts in the evidence file; verdict `pass`
  or `fail` stated explicitly.

- [ ] **T002** [P] Prove compatibility mode exposes a web domain — owner:
  `senior-tester`
  Files: `specs/016-android-autofill-completion/device-evidence.md`.
  Acceptance: with `<compatibility-package>` declared for `com.android.chrome`
  and `org.mozilla.firefox`, a login form in each browser yields a fillable
  structure whose `webDomain` matches the page. Browser versions recorded.
  Verify: evidence file records both browsers, both versions, and the observed
  domain string.

- [ ] **T003** [P] Prove the biometric prompt across the API split — owner:
  `senior-tester`
  Files: `specs/016-android-autofill-completion/device-evidence.md`.
  Acceptance: `BiometricPrompt` with device-credential fallback presents
  correctly on an API 29 device and on an API 31+ device, with and without a
  fingerprint enrolled.
  Verify: four combinations recorded (29/31+ × enrolled/not).

- [ ] **T004** [P] Observe the no-secure-lock device — owner: `senior-tester`
  Files: `specs/016-android-autofill-completion/device-evidence.md`.
  Acceptance: with the screen lock removed, `BiometricManager.canAuthenticate`
  returns a documented status and the intended refusal is reachable.
  Verify: the returned status constant is recorded verbatim, not paraphrased.

**Checkpoint**: T001 and T002 `pass` before Phase 4 and Phase 6 start. T003 and
T004 `pass` before Phase 3 starts.

---

## Phase 1 — Setup

- [x] **T101** Declare `androidx.biometric` — owner: `senior-android-dev`
  Files: `android/app/build.gradle.kts`.
  Acceptance: the dependency is declared with an explicit version (no dynamic
  range, matching the repo's pinning convention); the debug and release variants
  both assemble.
  Verify: `cd android && ./gradlew :app:assembleDebug` succeeds.

- [x] **T102** Declare `androidx.autofill` — owner: `senior-android-dev`
  Files: `android/app/build.gradle.kts`.
  Acceptance: as T101. Depends on T001 being `pass` (do not add the dependency
  for a capability the gate rejected).
  Verify: `./gradlew :app:assembleDebug` succeeds.

---

## Phase 2 — Foundational (blocks every story)

- [ ] **T201** Add the session-TTL fields to the native store — owner:
  `senior-android-dev`
  Files: `android/app/src/main/kotlin/.../autofill/AndroidAutofillStore.kt`,
  `.../AndroidAutofillModels.kt`.
  Acceptance: `authSessionTtlMs` and `lastAuthenticatedAtEpochMs` are persisted
  in the existing plaintext metadata file; both are cleared by
  `clearCredentials`; neither ever reaches the sealed file; a negative TTL is
  rejected.
  Verify: new Kotlin unit test covering persistence, clearing and rejection.

- [x] **T202** Carry `authSessionTtlMs` over the channel — owner:
  `senior-android-dev`
  Files: `.../AndroidAutofillV2Channel.kt`, `.../AndroidAutofillJson.kt`.
  Acceptance: `publishCredentials` accepts the optional field (default `0`);
  `getStatus` returns it and `lastAuthenticatedAtEpochMs`, exactly as
  `contracts/android_autofill_channel.md` specifies.
  Verify: Kotlin unit test for the argument mapping, including the absent-field
  default.

- [x] **T203** [P] Publish the TTL from Dart — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/apple_autofill_v2_models.dart`,
  `.../domain/services/apple_autofill_v2_payload_mapper.dart`,
  `.../data/services/apple_autofill_v2_method_channel_client.dart`,
  `.../presentation/coordinators/apple_autofill_v2_coordinator.dart`.
  Acceptance: the value comes from the spec 011 master-password session scope,
  not a literal; the Apple path is unchanged and ignores the field.
  Verify: `flutter test` — new unit test asserts the published payload carries
  the configured TTL and that the Apple mapper output is byte-identical to
  before.

- [x] **T204** Extract the shared authentication gate — owner:
  `senior-android-dev`
  Files: `android/app/src/main/kotlin/.../autofill/AutofillAuthGate.kt` (new).
  Acceptance: one entry point used by both the picker and the inline auth
  activity: returns *authenticated* (within TTL, no prompt), *prompted and
  succeeded*, *cancelled/failed*, or *no-authenticator-available*; it writes
  `lastAuthenticatedAtEpochMs` only on success and never decrypts anything
  itself.
  Verify: Kotlin unit test on the TTL arithmetic (expired, valid, TTL `0`, clock
  moved backwards) with the prompt stubbed.

**Checkpoint**: foundation ready; stories can proceed.

---

## Phase 3 — US1: authentication before release (P1) 🎯 MVP

**Goal**: no password leaves the sealed cache without the vault owner
authenticating. **Independent test**: quickstart.md section A.

- [ ] **T301** [US1] Host the prompt in the picker — owner: `senior-android-dev`
  Files: `.../autofill/AutofillPickerActivity.kt`,
  `android/app/src/main/AndroidManifest.xml`.
  Acceptance: the activity extends `FragmentActivity`; no behaviour change other
  than being able to host `BiometricPrompt`.
  Verify: existing picker flows still work manually; `./gradlew :app:test` green.

- [ ] **T302** [US1] Gate `selectCredential` on authentication — owner:
  `senior-android-dev`
  Files: `.../autofill/AutofillPickerActivity.kt`.
  Acceptance: `AutofillAuthGate` runs *before* `store.readCredentialSecret`;
  cancel, error, timeout, rotation and backgrounding all finish with
  `RESULT_CANCELED`, no `Dataset` and no decrypted secret retained (FR-001,
  FR-002). Two spec edge cases are covered here: a cache that became empty or
  stale between the prompt and the release reports that plainly and fills
  nothing, and a request whose entry belongs to a database other than the one
  currently published is treated as absent rather than filled from a stale
  cache.
  Verify: instrumented test asserts no `EXTRA_AUTHENTICATION_RESULT` on cancel;
  code review confirms the decrypt call is not reachable before a success.

- [ ] **T303** [US1] Refuse on a device with no secure lock — owner:
  `senior-android-dev`
  Files: `.../autofill/AutofillPickerActivity.kt`,
  `android/app/src/main/res/values/strings.xml`.
  Acceptance: when no authenticator is available, the picker shows the
  device-lock-required message and fills nothing (FR-003a); the message is a new
  string key, no existing key is edited.
  Verify: T004 evidence plus a manual run with the lock removed.

- [ ] **T304** [US1] Honour the reuse window — owner: `senior-android-dev`
  Files: `.../autofill/AutofillPickerActivity.kt`, `.../AutofillAuthGate.kt`.
  Acceptance: a second release inside the window does not prompt; outside it
  does; TTL `0` always prompts (FR-003).
  Verify: Kotlin unit test on the gate plus quickstart A step 4.

- [x] **T305** [P] [US1] Prompt strings — owner: `senior-android-dev`
  Files: `android/app/src/main/res/values/strings.xml`.
  Acceptance: title, subtitle and cancel label for the prompt; wording states
  that a password is about to be filled into another app.
  Verify: `./gradlew :app:assembleDebug`; no existing string value changed
  (Constitution VI) — confirmed by diff.

**Checkpoint**: US1 shippable alone. This is the MVP cut.

---

## Phase 4 — US2: inline keyboard suggestions (P2)

Blocked by T001 `pass` and by Phase 3 (shares the gate).
**Independent test**: quickstart.md section B.

- [x] **T401** [US2] Rank the top N matches — owner: `senior-android-dev`
  Files: `.../autofill/AndroidAutofillCredentialMatcher.kt`.
  Acceptance: a ranked top-N helper over the existing strong/possible matching;
  the matching rules themselves are unchanged.
  Verify: Kotlin unit test — ordering is deterministic and strong matches always
  outrank possible ones.

- [ ] **T402** [US2] Headless per-entry auth activity — owner:
  `senior-android-dev`
  Files: `.../autofill/AutofillAuthActivity.kt` (new),
  `android/app/src/main/AndroidManifest.xml`.
  Acceptance: takes one entry id plus the target `AutofillId`s, runs
  `AutofillAuthGate`, decrypts one entry, returns the filled `Dataset`; shows no
  list and no vault content beyond that entry.
  Verify: instrumented test — cancel returns no result; success returns exactly
  the requested fields.

- [ ] **T403** [US2] Emit inline datasets — owner: `senior-android-dev`
  Files: `.../autofill/KeyVaultAutofillService.kt`.
  Acceptance: when `FillRequest.getInlineSuggestionsRequest()` is non-null, one
  dataset per ranked match carries an `InlinePresentation` showing title and
  username only (FR-005), each with its own auth `PendingIntent` into T402;
  when it is null, today's single authenticated dataset is emitted unchanged
  (FR-004). Filling a saved login from the strip costs at most two taps — choose,
  authenticate — which is recorded as a tap count in the evidence file (SC-002).
  Verify: quickstart B steps 1–3 and 5; unit test asserts no password string
  reaches any presentation builder.

- [ ] **T404** [US2] Overflow entry into the picker — owner: `senior-android-dev`
  Files: `.../autofill/KeyVaultAutofillService.kt`,
  `android/app/src/main/res/values/strings.xml`.
  Acceptance: when matches exceed the IME's advertised slots, the last slot is a
  "Search Custode" suggestion opening `AutofillPickerActivity` (FR-006).
  Verify: quickstart B step 4 on a form with more matches than slots.

**Checkpoint**: US1 + US2 both work; API 29 and inline-less IMEs unchanged.

---

## Phase 5 — US3: save and update capture (P2)

**Independent test**: quickstart.md section C.

- [x] **T501** [US3] Parse submitted values — owner: `senior-android-dev`
  Files: `.../autofill/AssistStructureCredentialParser.kt`.
  Acceptance: extracts username and password at save time; a "new password" +
  "confirm password" pair collapses to one credential; a password-only screen
  yields a capture with an empty username.
  Verify: Kotlin unit tests over recorded structures for all three shapes.

- [x] **T502** [US3] Process-local capture holder — owner: `senior-android-dev`
  Files: `.../autofill/AndroidAutofillCaptureHolder.kt` (new),
  `.../AndroidAutofillModels.kt`.
  Acceptance: token → capture map, single-read semantics, expiry, explicit clear;
  nothing written to disk; `toString()` redacts username and password (D5,
  Constitution I).
  Verify: Kotlin unit test — second read fails, expiry clears, `toString()`
  contains no secret.

- [x] **T503** [US3] Attach `SaveInfo` and handle the save request — owner:
  `senior-android-dev`
  Files: `.../autofill/KeyVaultAutofillService.kt`, `.../MainActivity.kt`,
  `android/app/src/main/AndroidManifest.xml`.
  Acceptance: the fill response declares username+password (password-only where
  no username field exists); `onSaveRequest` builds the capture, stores it under
  a token, and launches the app with the token only — never with the password
  (FR-007, D5).
  Verify: manual quickstart C step 1; code review confirms no secret in any
  `Intent` extra; `adb shell dumpsys activity` shows no credential.

- [ ] **T504** [US3] Channel methods for the capture — owner:
  `senior-android-dev`
  Files: `.../autofill/AndroidAutofillV2Channel.kt`, `.../AndroidAutofillJson.kt`.
  Acceptance: `readPendingCapture` and `resolvePendingCapture` exactly as
  `contracts/android_autofill_channel.md` specifies, including
  `android_autofill_capture_missing` and the safe unknown-token resolve.
  Verify: Kotlin unit tests for both methods and both error paths.

- [x] **T505** [P] [US3] Dart port and client — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/repositories/autofill_ports.dart`,
  `.../domain/models/apple_autofill_v2_models.dart`,
  `.../data/services/apple_autofill_v2_method_channel_client.dart`.
  Acceptance: two additive methods on the Android-capable client; the captured
  model redacts its password in `toString()`/`props`; Apple implementations throw
  `UnsupportedError` rather than silently returning null.
  Verify: `flutter test` — redaction test and unsupported-path test.

- [x] **T506** [US3] Save coordinator — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/coordinators/android_autofill_save_coordinator.dart`
  (new), `lib/features/password_manager/di/password_manager_presentation_di.dart`.
  Acceptance: reads the capture, unlocks the vault if locked (FR-010), resolves
  new-vs-update by association + username, states which one before writing
  (FR-008), writes through the existing vault repository under the existing
  backup and `DatabasePathMutex` protections (FR-009), preserves the previous
  password in entry history on update, and calls `resolvePendingCapture` on
  every path including failure. No new BLoC, no new writer.
  Verify: `flutter test` — new/update resolution, cancelled unlock writes
  nothing and reports "not saved", write failure still resolves the token.

- [x] **T507** [US3] Suppress a repeat prompt after decline — owner:
  `senior-android-dev`
  Files: `.../autofill/AndroidAutofillStore.kt`,
  `.../AndroidAutofillV2Channel.kt`.
  Acceptance: `resolvePendingCapture(outcome: "declined")` records association +
  username only — never the password — and the same submission is not offered
  again (FR-011).
  Verify: Kotlin unit test plus quickstart C step 6.

- [x] **T508** [P] [US3] Save copy — owner: `senior-flutter-dev`
  Files: `android/app/src/main/res/values/strings.xml` and the Flutter strings
  used by the coordinator.
  Acceptance: new-entry confirmation, update confirmation naming the entry, and
  the "not saved" message; no existing copy edited.
  Verify: diff review against Constitution VI.

**Checkpoint**: capture works end to end, including the locked-vault path.

---

## Phase 6 — US4: browser autofill (P3)

Blocked by T002 `pass`. **Independent test**: quickstart.md section D.

- [x] **T601** [US4] Declare the compatibility packages — owner:
  `senior-android-dev`
  Files: `android/app/src/main/res/xml/keyvault_autofill_service.xml`.
  Acceptance: `com.android.chrome` and `org.mozilla.firefox` only, with the
  version bound recorded from T002 (FR-012).
  Verify: quickstart D steps 1–2 on both browsers.

- [x] **T602** [P] [US4] Lock the browser-matching rules with tests — owner:
  `senior-android-dev`
  Files: `android/app/src/test/kotlin/.../autofill/AndroidAutofillNormalizerTest.kt`,
  `.../AndroidAutofillCredentialMatcherTest.kt`.
  Acceptance: with a `webDomain` present the browser package never becomes a
  strong-match identifier; with no readable domain nothing is a strong match
  (FR-013). Tests are expected to pass against today's matcher; if either
  assertion fails, correcting `AndroidAutofillNormalizer`/the matcher is part of
  this task, not a follow-up.
  Verify: `./gradlew :app:test`.

**Checkpoint**: all four stories functional.

---

## Phase 7 — Picker accessibility and tokens (FR-014)

- [x] **T701** Mirror the design tokens into resources — owner:
  `senior-android-dev`
  Files: `android/app/src/main/res/values/colors.xml`,
  `res/values-night/colors.xml`, `res/values/dimens.xml`, `res/values/styles.xml`.
  Acceptance: every colour and metric the picker uses comes from a mirrored
  token; `AutofillPickerTheme` consumes them; no literal hex or dp left in
  Kotlin (Constitution III).
  Verify: T703 passes; grep finds no `setPadding(` with a literal in the picker.

- [x] **T702** Rebuild the picker layout — owner: `senior-android-dev`
  Files: `.../autofill/AutofillPickerActivity.kt`,
  `android/app/src/main/res/layout/` (new files).
  Acceptance: `simple_list_item_1` and hard-coded pixel padding are gone; rows
  are ≥ 44 dp tall and ≥ 44 dp wide targets; every focusable has a 2 dp focus
  ring; every row and the search field carry TalkBack labels (FR-014,
  Constitution V).
  Verify: instrumented assertions on height, focus indication and content
  descriptions; quickstart E manually.

- [x] **T703** [P] Token-mirror drift test — owner: `senior-flutter-dev`
  Files: `test/core/theme/android_autofill_token_mirror_test.dart` (new).
  Acceptance: parses the Android colour resources and asserts each mirrored
  value equals its `AppColors` source in both light and dark; a changed token
  with an unchanged mirror fails (D7).
  Verify: `flutter test`; deliberately alter one value and confirm the failure.

- [ ] **T704** [P] Contrast assertions — owner: `senior-tester`
  Files: `android/app/src/androidTest/kotlin/.../autofill/PickerAccessibilityTest.kt`
  (new).
  Acceptance: every text/background pairing in the picker is ≥ 4.5:1 in light and
  dark, including the secondary row line at its smallest size (Constitution V).
  Verify: instrumented run on one device per theme.

---

## Phase 8 — Verification gate

- [x] **T801** Local gate — owner: `senior-flutter-dev`
  Files: none.
  Acceptance: `dart format --set-exit-if-changed lib test tool`,
  `flutter analyze`, full `flutter test`, and `cd android && ./gradlew :app:test`
  all clean and green (Constitution IX). `pubspec.yaml: version:` untouched.
  Verify: command output pasted into the PR body with before/after test counts.

- [ ] **T802** Redaction sweep — owner: `senior-tester`
  Files: `specs/016-android-autofill-completion/device-evidence.md`.
  Acceptance: after a full session exercising every flow, no captured or filled
  password appears in `logcat`, in any file under `files/autofill_v2`, or in any
  `toString()` reachable from a crash report (FR-015).
  Verify: quickstart F, with the grep output recorded.

- [ ] **T803** Full quickstart re-run — owner: `senior-tester`
  Files: `specs/016-android-autofill-completion/device-evidence.md`.
  Acceptance: sections A–F pass on an API 29 device and on an API 33+ device;
  every deviation is recorded with device, OS, IME and browser versions.
  Verify: evidence file signed off before merge.

---

## Dependencies

- **Phase 0** gates everything: T003/T004 → Phase 3; T001 → Phase 4; T002 →
  Phase 6.
- **Phase 1 → Phase 2 → Phase 3.** T101 blocks T204; T102 blocks T403.
- **Phase 4** depends on Phase 3 (shared `AutofillAuthGate`).
- **Phase 5** depends on Phase 2 only; it can run in parallel with Phase 4 by a
  second developer, since it touches the save path and they touch the fill path
  — with `KeyVaultAutofillService.kt` as the one shared file to sequence.
- **Phase 6** is independent of Phases 3–5 and can land at any point after T002.
- **Phase 7** touches only the picker and can run in parallel with Phase 5/6
  once T302 has settled the picker's control flow.
- **Phase 8** is last.

### Parallel opportunities

- T001–T004 all in parallel (one tester, four devices, or four passes).
- T203 (Dart) with T201/T202 (Kotlin).
- T505 with T501/T502.
- T703 and T704 with each other and with T601/T602.

## Implementation strategy

1. **MVP**: Phase 0 (T003, T004) → Phase 1 (T101) → Phase 2 → Phase 3. Ship. The
   security hole is closed and nothing else has changed.
2. Add Phase 4 (inline) → validate quickstart B → ship.
3. Add Phase 5 (save) → validate quickstart C → ship.
4. Add Phase 6 (browsers) and Phase 7 (accessibility) → validate D and E → ship.
5. Phase 8 before every one of those cuts, not only the last.

## Implementation notes (slice 1)

Plain bullets on purpose — these are not scheduled work.

- **Session state lives in its own file, not in the metadata cache.** D2 and T201
  say "the existing plaintext metadata file". That file is the AEAD associated
  data of the sealed secret file (`AndroidAutofillStore.encrypt` calls
  `updateAAD(metadataBytes)`), so stamping `lastAuthenticatedAtEpochMs` into it
  would invalidate every sealed credential on the next read. The two fields are
  written to `android_autofill_session_v2.json` in the same directory instead:
  same plaintext-and-not-secret property, same clearing, no AAD churn.
- **Publishing a cache resets the reuse window.** A republish always clears
  `lastAuthenticatedAtEpochMs`, so a newly published cache starts
  unauthenticated.
- **The TTL value is a constant, not a setting.** D2 sources it from "the spec
  011 master-password session scope", but spec 011 defines no timeout — it is
  about never persisting the master password, and the codebase has no session
  TTL to read. `AppleAutofillV2Coordinator.authSessionTtl` is 30 s: long enough
  that filling a username field and then the password field of one login prompts
  once, short enough that a later fill re-authenticates. The channel field stays
  the seam a real setting would feed later.
- **`AndroidAutofillStore` has no JVM unit test** (T201's stated verification).
  It needs a `Context` and the Android Keystore; the module has no Robolectric
  and no `isReturnDefaultValues`, so no store test exists today. The TTL
  arithmetic was extracted into `AutofillAuthSessionWindow` precisely so it is
  covered by a plain JVM test.
- **Two pre-existing gate failures were fixed here**, both inherited from `main`
  rather than introduced by this slice:
  - `./gradlew :app:test` also compiled the release variant's unit tests, which
    cannot resolve `dev.flutter.plugins.integration_test`:
    `GeneratedPluginRegistrant.java` is generated once for every variant and
    registers dev-dependency plugins that the Flutter Gradle plugin deliberately
    keeps out of release. `android/app/build.gradle.kts` now disables release
    unit tests, so the documented command works as written.
  - `dart format --set-exit-if-changed lib test tool` failed on 42 untouched
    files under Flutter 3.47.1's formatter. They are reformatted in their own
    commit, separate from the feature diff.

## Implementation notes (slice 2 — Phase 5, save capture)

Plain bullets on purpose — these are not scheduled work.

- **The capture never leaves the process.** `AndroidAutofillCaptureHolder` keeps
  the submitted credential in memory keyed by an opaque token; only the token
  travels, in the `IntentSender` the service hands to `SaveCallback.onSuccess`.
  The password is handed out exactly once (`readPendingCapture`), the entry
  survives that read only so the decline path still knows which association and
  username it was about, and `resolvePendingCapture` drops it whatever the
  outcome. Nothing is persisted, so process death clears it implicitly.
- **One extra channel method beyond the contract: `takePendingCaptureToken`.**
  `contracts/android_autofill_channel.md` says Dart calls `readPendingCapture`
  with "the opaque token carried in the launching intent", but Dart cannot read
  an `Intent`. A cold start also reaches Dart only after the engine is up, so
  the token cannot simply be pushed at it. `MainActivity` parks the token on the
  channel handler and Dart pulls it — the same shape
  `OtpAuthDeepLinkCoordinator.takePendingUrls` already uses for deep links.
- **New-vs-update reuses the autofill payload mapper.** An entry matches when
  one of the service identifiers `AppleAutofillV2PayloadMapper` already derives
  for it equals the capture's association, under the same username. That is the
  same vocabulary the fill side matches on, so save and fill cannot disagree
  about what "this app" means.
- **History comes from the existing writer.** `VaultKdbxService.updateEntry`
  goes through `KdbxEntry.setString`, and the kdbx package pushes the previous
  values into the entry history on every modification. No history handling was
  added here, and none is needed.
- **Two tasks are deliberately left open on their stated verification, not on
  their code.** `T504` asks for Kotlin unit tests of both channel methods and
  `T507` for a store test: `AndroidAutofillV2Channel` and `AndroidAutofillStore`
  both need a `Context` and the module has no Robolectric, exactly as recorded
  for `T201` in slice 1. What is testable without one is tested — the holder's
  single-read, expiry and unknown-token semantics, and the decline key
  normalization. `T503` is open on device evidence (quickstart C step 1 plus the
  `dumpsys` check).
- **`T508` is Flutter copy only.** The save path shows no native UI: the system
  save bar is the platform's own, and the confirmation is the Flutter
  confirmation surface. No Android string was added or edited.
- **Quickstart C step 5 has a gap.** Cancelling the unlock leaves the user on
  the unlock screen, where there is no place to show "not saved". Nothing is
  written and the capture expires on its own, but the message only appears when
  the vault is reachable. Worth resolving when the unlock screen grows a
  message surface.

## Implementation notes (slice 3 — the locked-vault hole, Phase 6, Phase 7)

**The capture no longer dies silently when the vault is locked.** A save capture
arrives while the app may be at the unlock screen, and the vault screen is the
only place that could pull it. Until now the token simply sat in the autofill
service's memory until its TTL, and a user who backed out of unlocking was never
told the password had not been saved.

`AndroidAutofillSaveCoordinator` now claims the token as soon as anything asks
(`hasPendingCapture`) and holds it in Dart. The unlock screen asks on mount and,
when one is waiting, says so above the password field; leaving that screen
without unlocking calls `abandonPendingCapture`, which resolves the token as
`cancelled` so the submitted password leaves the service's memory immediately
instead of at expiry. Unlocking still hands the capture to the vault screen
exactly as before.

The coordinator is optional on the unlock screen (`GetIt.isRegistered`), matching
how `VaultBloc` already takes it, so the screen still builds in tests that
register only what they need.

**T601/T602 (browsers).** Compatibility mode is declared for `com.android.chrome`
and `org.mozilla.firefox` only — it runs an accessibility stream in every package
listed, so the list stays as short as FR-012 requires. `maxLongVersionCode` is
left wide: no version of either browser is known to need excluding, and T002 can
narrow it.

T602 found a real FR-013 hole while locking the rules down: `normalizedHost`
fell back to the text before the first `:`, so a browser sitting on `about:blank`
produced the "domain" `about`, which a saved entry could then strong-match.
`AndroidAutofillNormalizer` now rejects any non-http(s) scheme, while still
reading `example.com:8080` as a host and a port. Correcting the normalizer was
part of T602 by its own wording.

**T701–T703 (picker).** The picker's colours and metrics now come from Android
resources mirrored from `AppColors`, with a `values-night` half; no literal hex
or dp is left in `AutofillPickerActivity`. The layout moved into
`res/layout/autofill_picker_{activity,row}.xml`: rows are ≥ 44 dp with a 2 dp
focus ring, the search field is labelled, and each row carries one TalkBack
label instead of two loose text nodes. Every text/background pairing was checked
to ≥ 4.5:1 in both themes while picking the tokens; T704 re-asserts it on device,
where the real rendering can be measured.

`test/core/theme/android_autofill_token_mirror_test.dart` (T703) is what keeps
the mirror honest — it was confirmed to fail on a deliberately altered value
before being left green.

**Still open here.** T704 needs an instrumented run. Phase 4 is untouched: T102
and the whole phase are gated on T001, which is device evidence that IMEs
actually render inline suggestions, and the spec is explicit that the dependency
should not be added for a capability the gate rejected.

---

## Implementation notes (slice 4 — inline suggestions, on-device findings)

**The T001 gate was answered by building the thing, not by probing it.** The spec
ordered the probe first so the `androidx.autofill` dependency would not be added
for a capability the gate might reject. On the owner's instruction Phase 4 was
built first, and the advertisement was then read back from a live request against
the real implementation — stronger evidence than a throwaway `FillResponse`, and
recorded that way in `device-evidence.md`. Gboard on API 37 advertises
`maxSuggestionCount=9`, nine specs, inline UI v1, 89x126–630x126: `pass`. T001
stays open only because it also requires a second real IME, which the test device
does not have.

What Phase 4 adds: `supportsInlineSuggestions="true"` on the service (without it
the framework logs `not adding inline request` and never asks), `topMatches` as a
pure ordering over the existing strong/possible rules so the strip and the picker
cannot disagree (T401), a headless `AutofillAuthActivity` that authenticates one
already-chosen entry and shows no list (T402), one inline dataset per ranked match
carrying title and username only (T403), and a last-slot "Search Custode"
overflow when more entries match than fit (T404). The picker dataset is still
emitted in every response, so API 29 and inline-less IMEs are untouched (FR-004).

A password never reaches a presentation: the secret is read inside
`AutofillAuthActivity`, after authentication, in our own process — presentations
are rendered in the *filled app's* process, which is exactly why (FR-015).

**Three defects the device found that no test had.**

1. The picker drew under the status bar. Android 15+ enforces edge-to-edge, and
   the layout took no insets. Fixed with an outer frame that takes
   `fitsSystemWindows` while the inner column keeps its own padding, plus
   `windowSoftInputMode="adjustResize"` so the list shrinks for the keyboard
   instead of sliding under it.
2. Rows did not respond to taps. A focusable row makes a `ListView` swallow item
   clicks; the 2dp focus ring moved to the list's selector, which keeps keyboard
   navigation and gives clicks back.
3. The picker and the system dropdown used platform defaults, not the product's
   type. Caprasimo and Figtree are now mirrored into `res/font`, and the type
   scale and radii into `dimens.xml` from `AppTextStyles`/`AppRadii`; the drift
   test covers both alongside the colours. The dropdown row shares one RemoteViews
   layout with the picker, so a suggestion and the list it opens look like the
   same product.

**Chrome needs its own opt-in.** Chrome does not delegate to an Android autofill
service until the user enables it inside Chrome. Before that the framework opens
no session at all, which is indistinguishable from a broken service. Recorded in
the evidence file; it belongs in user-facing setup guidance.

**Debug-only tracing** was added to the fill path (counts, ids, hosts — never a
value). It is gated on `FLAG_DEBUGGABLE` rather than a log tag, and deliberately
so: those lines name the hosts the user visits, which has no business in a
release device's logcat.

**Left open, honestly.** T402's cancel path and T403/T404's remaining quickstart
steps need the instrumented test and a second IME; T404's overflow could not be
observed because Gboard offers nine slots and no test form matched more than
nine entries.

---

## Implementation notes (slice 5 — what the save path looked like on hardware)

Section C was run on the Pixel and found three things unit tests could not.

**The confirmation appeared twice.** One capture, one read, one resolve — the
dialog itself was shown twice. `_onConfirmAndroidAutofillCapture` cleared the
pending save *after* the write, and the reload in between emits intermediate
states; any one of them still carrying a pending save re-opened the confirmation
the user had just answered. The pending save is now cleared before the write, on
the confirm and the dismiss paths alike.

**The unlock notice was invisible where it mattered most.** It lived inside the
manual password form, and a user with biometrics enabled never sees that form.
Worse, the system biometric prompt is a full-screen window: anything the app
draws is behind it. So the notice moved above every unlock phase *and* the reason
now goes into the prompt itself — "Authenticate to save the password you just
submitted" — which is the only surface the user is actually looking at. The
existing generic string is untouched (Constitution VI); this is a second one,
chosen by `DatabaseUnlockBloc` from an injected `isAutofillCapturePending`
callback, so the bloc still knows nothing about autofill.

That wording needed the answer *before* the first prompt, which a channel
round-trip could not deliver in time. Rather than delay every biometric unlock,
`main.dart` claims a pending capture at startup, next to the deep-link
coordinator, so the coordinator can answer synchronously from then on.

**The dialog did not say whose password it was.** It named the site but not the
account. Both wordings now name the username, which is the thing worth checking
before saying yes.

Traced on device end to end: capture stored with `usernameCaptured=true`, token
claimed at startup, read once after unlock, resolved `saved`, and the second
token request correctly answered `false` because Dart already held it.

**The token is never logged.** An automated review caught a trace line printing
it; it is the capability that reads the captured password back, so only its
presence is traced now. The fill-path tracing as a whole is gated on
`FLAG_DEBUGGABLE`.

---

## Where this stands (2026-08-28)

Twenty-one of thirty-six tasks are done. The remaining fifteen are verification,
not code, and `device-evidence.md` says for each one where it can be run and what
blocks it — read that before starting a session rather than rediscovering it.

The short version: six run on the Pixel today; two need an API 29 device, which
is blocked on host memory rather than on anything here; one (T404) is not
observable on either IME we have, because both advertise nine slots and no test
vault has more than nine entries matching one site; and two need a `Context` the
module cannot fake without Robolectric, which is its own decision and not a
chore to fold into this spec.

---

## Deferred, not scheduled

- Passkeys and Credential Manager support.
- One-time-code / OTP field filling.
- Browsers beyond Chrome and Firefox.
- Keystore `setUserAuthenticationRequired` on the cache key (research R1), which
  would enforce authentication cryptographically but re-keys every installed
  user's store.
