# 016 — Implementation plan

**Spec**: [spec.md](spec.md) · **Branch**: `docs/spec-016-android-autofill` (planning)
· **Date**: 2026-08-28

## Delivery strategy

Four independent slices, shipped in priority order. Each is a working build on its
own, so the cut can stop after any of them:

1. **Auth gate (P1)** — closes an active security hole. It is the only slice that
   makes the shipped app *worse* if delayed, so it lands first and alone.
2. **Inline suggestions (P2)** — pure UX, depends on the auth gate only because it
   reuses the same authentication entry point.
3. **Save capture (P2)** — the only slice that writes to the `.kdbx`; it inherits
   the backup and single-writer rules and therefore carries the most test weight.
4. **Browser compatibility (P3)** — a manifest/resource change plus verification;
   no new Dart or matching code, because domain normalization already exists.

Slices 2 and 4 are behaviourally additive: on a device or IME that does not
support them the existing dropdown-and-picker path stays exactly as it is today.

**Owner agent**: `senior-android-dev` (Kotlin: service, picker, store, resources).
`senior-flutter-dev` owns the Dart side of slice 3 (save coordinator, entry write)
and the token mirror test. `senior-tester` owns the Phase 0 device gate and the
Phase 8 verification gate.

This plan changes no KDBX write path, no sync decision, no checksum and no
published-cache format except the two additive fields named in plan decision D2
below. Existing
user-facing copy is untouched; new strings are new.

## Constitution Check

Checked against `.specify/memory/constitution.md` v1.1.2. No gate is violated; no
complexity waiver is needed.

| Principle | Verdict | Evidence |
| --- | --- | --- |
| I — Secrets never leak into the shell | PASS | The captured credential in slice 3 never enters an `Intent` extra, a log line or a file: it is held in an in-process holder keyed by an opaque token (D5), and cleared on accept, decline, timeout and process death. `AndroidAutofillCredentialSecret.toString()` already redacts; the new capture model does the same, asserted by T502 with the log sweep in T802. Inline presentations carry title/username only (FR-005). |
| II — Clean architecture layering holds | PASS | The native side stays behind the existing method channel; Dart gains one coordinator (`AndroidAutofillSaveCoordinator`) and one port method, not a BLoC. The save writes through the existing vault repository, not a new writer. |
| III — Design tokens | PASS | The picker's Android theme is a generated mirror of `AppColors`/`AppSpacing`/`AppRadii`, checked by T703 rather than hand-copied hex left to rot. No new hard-coded colour or metric. |
| IV — Pixel fidelity is testable | PASS | The picker is native Android, so Flutter goldens cannot cover it; per Constitution IV the spec names the replacement — instrumented assertions on tap-target size, contrast pairs and focus indication (T702, T704), plus the Phase 0/8 manual evidence. No Flutter surface changes, so the existing golden inventory is untouched. |
| V — Accessibility floor | PASS | T702 and T704 assert ≥ 44×44 targets, a 2 dp focus ring, ≥ 4.5:1 for every text/background pairing in light and dark, and TalkBack labels on every row and on the authentication prompt. |
| VI — Copy preserved | PASS | Existing strings in `strings.xml` keep their values. New keys only: authentication prompt, no-device-lock refusal, save/update prompt, "Search Custode" inline entry. |
| VII — Destructive operations ask first and back up | PASS | The save in slice 3 asks before writing, states whether it creates or updates, preserves the previous password in entry history on update, and goes through the existing backup-before-write and `DatabasePathMutex` path (T506). |
| VIII — Ship the smallest thing | PASS | Two AndroidX libraries replace hand-rolled equivalents (D1, D3); no new BLoC, no pending-capture store (D4), no provider abstraction, no new plugin. Slice 4 is four lines of XML plus tests. |
| IX — Verification is local | PASS | T801 runs `dart format`, `flutter analyze`, the full `flutter test` and the Kotlin unit tests before commit. `pubspec.yaml: version:` untouched. |

### Phase 0 research and design artifacts

- `research.md` — **generated**. The API-level choices (inline suggestion support
  at minSdk 29, the biometric-with-device-credential matrix, compatibility mode)
  are decisions with real alternatives and are recorded there.
- `data-model.md` — **not generated**. The constitution requires it only for specs
  008 and 009. This spec adds no vault entity; the two new native structures are
  in `contracts/`.
- `contracts/android_autofill_channel.md` — **generated**. The method channel is
  the trust boundary between the Kotlin service and Dart; the additive methods and
  fields are specified there.
- `quickstart.md` — **generated**. Device validation is the only way to prove
  slices 2 and 4, so the runnable procedure is an artifact, not folklore.

## Technical context

**Language/Version**: Kotlin (Android app module, `minSdk = 29`,
`compileSdk`/`targetSdk` from the Flutter plugin), Dart 3 / Flutter 3.47.1.

**Primary dependencies (new)**: `androidx.biometric:biometric` (authentication
with device-credential fallback across API 29–34+), `androidx.autofill:autofill`
(inline suggestion Slice builders). Neither is present today — the app module
declares only `junit` — so both are added explicitly, with pinned versions, in
`android/app/build.gradle.kts` (T101, T102).

**Storage**: unchanged — `android/.../autofill_v2/` (plaintext metadata,
Keystore-sealed secrets, pending associations). Two additive fields only (D2).

**Testing**: existing Kotlin unit tests under
`android/app/src/test/kotlin/.../autofill/`, plus new instrumented tests for the
picker; `flutter test` for the Dart coordinator; the manual device gate in
`quickstart.md`.

**Target platform**: Android 10 (API 29) and up. Inline suggestions are API 30+.

**Constraints**: no regression on the existing dropdown path; no plaintext secret
outside the Keystore-sealed file and short-lived process memory.

## Design decisions

- **D1 — `androidx.biometric.BiometricPrompt` for the auth gate.** It handles the
  API 29 vs 30+ split between `setDeviceCredentialAllowed` and
  `setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)` in one call.
  Rejected: `KeyguardManager.createConfirmDeviceCredentialIntent` (no dependency,
  but PIN-only — it never offers the fingerprint the user expects), and the
  framework `BiometricPrompt` (the version split becomes our code). Requires
  `AutofillPickerActivity` to become a `FragmentActivity`; `MainActivity` already
  is one.
- **D2 — Session reuse is a timestamp, not a session object.** A successful
  authentication writes `lastAuthenticatedAtEpochMs` into the existing plaintext
  metadata file, and the reuse window `authSessionTtlMs` is published by Dart at
  `publishCredentials` time from the spec 011 session scope. TTL `0` means
  "authenticate every time". No new file, no new secret at rest. Clearing the
  cache (vault lock, database change) clears the timestamp with it.
- **D3 — Inline via `androidx.autofill` `InlineSuggestionUi`.** Building the
  `Slice` by hand against the platform API is possible and unreadable. Inline
  datasets are per-entry and each carries its own authentication `PendingIntent`
  into a new headless `AutofillAuthActivity`, so tapping a suggestion goes prompt
  → fill without the full-screen picker. The last available slot is always a
  "Search Custode" suggestion pointing at the existing `AutofillPickerActivity`.
- **D4 — No pending-capture store.** Spec decision SD2: a save
  arriving while the vault is locked opens the Custode unlock screen. An
  encrypted queue would create a second at-rest secret surface for a case the
  unlock screen already covers (Constitution VIII).
- **D5 — The captured credential never leaves process memory.** `onSaveRequest`
  and the activity that handles it run in the same process, so the capture is put
  in a process-local holder under an opaque token and only the token travels in
  the `Intent`. Nothing is written to disk, and the holder is cleared on every
  exit path including `onDestroy`.
- **D6 — Compatibility mode is declarative.** `keyvault_autofill_service.xml`
  gains `<compatibility-package>` entries for `com.android.chrome` and
  `org.mozilla.firefox`. Domain extraction and normalization already exist
  (`AssistStructureCredentialParser`, `AndroidAutofillNormalizer`); slice 4 adds
  verification, not matching logic.
- **D7 — Android theme mirrors the Flutter tokens, and a test proves it.** The
  picker cannot read `AppColors`; the values are mirrored into
  `res/values/colors.xml` + `res/values-night/colors.xml`, and a Dart test
  (T703) parses those files and asserts every mirrored value equals its
  `AppColors` source. Drift fails the suite instead of shipping.

## Phases and files

### Phase 0 — Device feasibility gate (blocking, evidence only)

No production code. `senior-tester` records observations in
`device-evidence.md`:

- T001 Inline suggestions render on Gboard and on at least one third-party IME
  (API 30+ device); note the advertised `maxSuggestionCount`.
- T002 Compatibility mode exposes a fillable structure with a readable
  `webDomain` on Chrome and Firefox current releases; record versions.
- T003 `BiometricPrompt` with device-credential fallback shows correctly on an
  API 29 device and on API 31+.
- T004 Behaviour on a device with no secure lock is observed, not assumed.

Slices 2 and 4 do not start until T001/T002 are `pass`.

### Phases 1–3 — Setup, foundational, auth gate (US1, FR-001 … FR-003a)

Tasks T101, T201–T204, T301–T305.

- `android/app/build.gradle.kts` — add `androidx.biometric`.
- `AutofillPickerActivity.kt` — `Activity` → `FragmentActivity`; authenticate in
  `selectCredential` *before* `readCredentialSecret`; refuse with an explicit
  message when `BiometricManager.canAuthenticate` reports no enrolled
  authenticator; abandon the request on cancel, error, rotation and backgrounding.
- `AndroidAutofillStore.kt` — read/write `lastAuthenticatedAtEpochMs` and
  `authSessionTtlMs`; clear both with the cache.
- `AndroidAutofillV2Channel.kt` / `AndroidAutofillJson.kt` — accept
  `authSessionTtlMs` in `publishCredentials`, expose it in `getStatus`.
- Dart: `apple_autofill_v2_models.dart`, `apple_autofill_v2_payload_mapper.dart`,
  `apple_autofill_v2_method_channel_client.dart`,
  `apple_autofill_v2_coordinator.dart` — publish the TTL from the spec 011
  session scope. Apple path ignores the field.
- `strings.xml` — prompt title/subtitle, cancel, no-device-lock refusal.

### Phase 4 — Inline suggestions (US2, FR-004 … FR-006)

Tasks T102, T401–T404.

- `android/app/build.gradle.kts` — add `androidx.autofill`.
- `KeyVaultAutofillService.kt` — read `FillRequest.inlineSuggestionsRequest`
  (API 30+), rank matches with the existing matcher, emit one dataset per match
  with an inline presentation plus a trailing "Search Custode" dataset; keep the
  current single authenticated dataset as the fallback when no inline request is
  present.
- `AutofillAuthActivity.kt` *(new)* — headless: authenticate (shared gate from
  Phase 2), decrypt one entry, return the filled `Dataset`.
- `AndroidAutofillCredentialMatcher.kt` — expose a ranked top-N helper; no change
  to the matching rules themselves.
- `AndroidManifest.xml` — register `AutofillAuthActivity`.

### Phase 5 — Save capture (US3, FR-007 … FR-011)

Tasks T501–T508.

- `KeyVaultAutofillService.kt` — attach `SaveInfo` for username+password (and
  password-only on change-password screens) to the fill response; implement
  `onSaveRequest` to build the capture and launch the handler.
- `AssistStructureCredentialParser.kt` — extract submitted values; collapse
  "new password" + "confirm password" into one credential.
- `AndroidAutofillCaptureHolder.kt` *(new)* — process-local token → capture map
  with explicit clearing (D5).
- `AndroidAutofillV2Channel.kt` — `readPendingCapture(token)` and
  `resolvePendingCapture(token, outcome)`.
- `MainActivity.kt` — route the save intent into the Flutter engine.
- Dart *(new)*: `presentation/coordinators/android_autofill_save_coordinator.dart`
  — unlock if needed, resolve new-vs-update by association + username, confirm
  with the user, write through the existing vault repository (backup +
  `DatabasePathMutex` unchanged), report the outcome back over the channel.
- Dart: `autofill_ports.dart` + client/mapper — the two additive methods.
- `strings.xml` / Flutter copy — save prompt, update-vs-new confirmation,
  "not saved" message on a cancelled unlock.

### Phase 6 — Browser compatibility (US4, FR-012, FR-013)

Tasks T601–T602.

- `res/xml/keyvault_autofill_service.xml` — `<compatibility-package>` for
  `com.android.chrome` and `org.mozilla.firefox`.
- `AndroidAutofillNormalizer.kt` — assert (test, not code) that a browser package
  never becomes a strong-match identifier when a `webDomain` is present, and that
  a missing domain yields no strong match.

### Phase 7 — Picker accessibility and tokens (FR-014)

Tasks T701–T704.

- `res/values/colors.xml`, `res/values-night/colors.xml`, `res/values/dimens.xml`,
  `AutofillPickerTheme` in `styles.xml` — mirrored tokens, ≥ 44 dp rows, focus ring.
- `AutofillPickerActivity.kt` — replace `simple_list_item_1` and hard-coded pixel
  padding with a themed layout; TalkBack content descriptions.
- `test/core/theme/android_autofill_token_mirror_test.dart` *(new)* — D7 drift test.

### Phase 8 — Verification gate

Tasks T801–T803.

- T801 `dart format`, `flutter analyze`, full `flutter test`, `./gradlew :app:test`.
- T802 redaction sweep: no captured password in any `toString`, log or file.
- T803 manual re-run of `quickstart.md` on API 29 and API 33+ devices; evidence
  appended to `device-evidence.md`.

## Test strategy

| Layer | Covers |
| --- | --- |
| Kotlin unit (`app/src/test`) | matcher ranking and top-N, save-capture parsing incl. new/confirm collapse, session-TTL expiry arithmetic, capture-holder clearing, redaction |
| Kotlin instrumented (`app/src/androidTest`, new) | auth gate blocks release on cancel; picker tap targets, contrast pairs, focus, TalkBack labels |
| Flutter unit | save coordinator: new vs update, locked-vault unlock path, cancelled unlock writes nothing, TTL publication |
| Manual (`quickstart.md`) | inline rendering per IME, browser compatibility mode, no-secure-lock refusal |

## Risks

- **Inline suggestion support varies by IME.** Mitigated by the Phase 0 gate and
  by keeping the dropdown path as an unconditional fallback.
- **Compatibility mode is browser-version dependent.** Mitigated by recording the
  tested versions in `device-evidence.md` and by FR-013, which makes "no readable
  domain" a defined, safe outcome rather than a bug.
- **Save capture touching the vault.** Mitigated by reusing the existing writer
  and its backup/mutex invariants; no new write path is introduced (Phase 5 adds
  a coordinator, not a writer).
- **Token mirror drift between Flutter and Android resources.** Mitigated by D7's
  failing test rather than by review discipline.

## Out of scope

Passkeys and Credential Manager, OTP/one-time-code field filling, browsers beyond
Chrome and Firefox, any change to the Apple or desktop autofill paths, and any
change to the published-cache encryption scheme.
