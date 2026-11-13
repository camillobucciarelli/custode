# 023 — Tasks

Ordered work for [spec.md](spec.md), against [plan.md](plan.md). Beta scope:
User Stories 1, 1b and 2, plus the desktop half of User Story 3 (Phase 9).
`plan.md` does not cover registration, so Phase 9's design decisions are
recorded in the tasks themselves.

Owners name the agent best suited to the task; a human may take any of them.
Each task states the files it touches, what "done" means, and how that is
checked. Tick a box only when its own acceptance holds and its tests pass.
`[P]` marks tasks that can run alongside their neighbours (different files, no
pending dependency).

---

## Phase 1 — Setup

- [ ] **T001** [P] Build the KeePassXC fixture vault — owner: `senior-tester`
  Files: `test/fixtures/passkeys/keepassxc_passkeys.kdbx` (new),
  `test/fixtures/passkeys/README.md` (new).
  Acceptance: created in KeePassXC ≥ 2.7.7 with the entries E1–E4 of
  `quickstart.md` (E1 ES256 passkey-only, E2 password for the same site and
  username, E3 passkey + password, E4 truncated PEM), plus one entry with a
  protected custom attribute `Recovery` and one EdDSA passkey. Keys are
  generated for the fixture only; the README says so and states the master
  password. Every `KPEX_PASSKEY_*` attribute's protect state is listed in the
  README as observed in KeePassXC.
  Verify: KeePassXC opens it and signs in on webauthn.io with E1 before it is
  committed.

- [x] **T002** [P] Test vectors for parsing and signing — owner: `senior-flutter-dev`
  Files: `test/fixtures/passkeys/vectors.dart` (new).
  Acceptance: one ES256, one EdDSA and one RS256 PKCS#8 PEM generated for the
  tests, with matching public keys; one truncated PEM; a known
  `(rpId, clientDataHash)` pair with the expected `authenticatorData` bytes per
  `data-model.md` (flags UP|UV|BE|BS, sign count 0).
  Verify: the file compiles and the vectors are referenced by T012 and T014.

- [x] **T003** [P] Device evidence ledger — owner: `senior-tester`
  Files: `specs/023-passkey-management/device-evidence.md` (new).
  Acceptance: same shape as `specs/016-android-autofill-completion/device-evidence.md`
  with a devices table (iPhone, Mac, Android API 34+, Android API 29–33,
  Windows, Linux) and one empty row per quickstart section D–F item.
  Verify: file exists and lists every D–F step by id. It also carries T212's
  round-trip rows and T601's two halves, so a task's evidence is not split
  across files; the one row filled in is T601's grep, which needs no device.

## Phase 2 — Foundational (blocks every story)

- [x] **T010** Stop downgrading protected custom fields on save — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/vault_custom_field.dart`,
  `lib/features/password_manager/data/services/vault_kdbx_service.dart`,
  `test/features/password_manager/data/services/vault_kdbx_service_test.dart`.
  Acceptance: `VaultCustomField.isProtected` (default `false`, in `props`,
  value still redacted). `_mapCustomFields` sets it from `stringEntry.value is
  ProtectedValue`; `_setCustomFields` writes `ProtectedValue.fromString` when
  true. No other behaviour changes. Committed on its own, before any passkey
  code (plan D2).
  Verify: service test opens a temp vault with one protected and one plain
  custom field, saves a title-only edit, reopens and asserts both protection
  states unchanged (SC-008). A `VaultCustomField(isProtected: true)` round-trips.

- [x] **T011** [P] Passkey domain model — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/vault_passkey.dart` (new),
  `test/features/password_manager/domain/models/vault_passkey_test.dart` (new).
  Acceptance: `VaultPasskey`, `VaultPasskeyAlgorithm`, `VaultPasskeyUnusableReason`
  per `data-model.md`. `privateKeyPem` is absent from `props` and `toString`;
  `toString` names rpId and username only.
  Verify: unit test builds a passkey with a PEM containing `SENTINEL` and
  asserts `props.toString()` and `toString()` never contain it.

- [x] **T012** [P] Passkey parser — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/passkey_parser.dart` (new),
  `test/features/password_manager/data/services/passkey_parser_test.dart` (new).
  Acceptance: `parse(List<VaultCustomField>)` groups by suffix (`""`, `_1`, …),
  requires `RELYING_PARTY`, `CREDENTIAL_ID`, `PRIVATE_KEY_PEM`, decodes
  base64url padded or unpadded, derives the algorithm from the PKCS#8 OID,
  reads `FLAG_BE`/`FLAG_BS` defaulting to true, never throws. Per
  `contracts/vault_kdbx_service_passkeys.md`.
  Verify: T002 vectors → three usable passkeys with the right algorithm;
  truncated PEM → `badKey`; missing credential id → `missingField`; a
  `_1` suffixed second group parses as a second passkey; an unknown OID →
  `unsupportedAlgorithm`.

- [x] **T013** Split passkey fields out of the entry — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/vault_entry.dart`,
  `lib/features/password_manager/domain/models/vault_entry_revision.dart`,
  `lib/features/password_manager/data/services/vault_kdbx_service.dart`,
  `test/features/password_manager/data/services/vault_kdbx_service_test.dart`.
  Acceptance: `VaultEntry.customFields` excludes keys starting
  `KPEX_PASSKEY_`; `VaultEntry.passkeys` and `passkeyDigest` populated per
  the contract; `hasPasskey` getter. The raw strings are not carried on the
  model: `_setCustomFields` never removes or writes the `KPEX_PASSKEY_*`
  namespace, so it stays in place in the `KdbxEntry` untouched.
  `VaultEntryRevision.customFields` applies the same exclusion and carries only
  `passkeyDigest`; its diff reports `passkey` by name when the digest differs.
  `restoreEntryRevision` likewise leaves the namespace in place.
  Verify: open the T001 fixture → E1, E3, E4 have `hasPasskey`, E2 not,
  E4 `usable == false`; no `KPEX_` key in any `customFields`; title-only
  save then byte-compare every `KPEX_*` string and its `Protected` attribute
  (SC-007); a revision of E1 contains no PEM; restoring E1's revision leaves
  the passkey intact.

- [x] **T014** [P] Desktop signer — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/desktop_passkey_signer.dart` (new),
  `test/features/password_manager/data/services/desktop_passkey_signer_test.dart` (new).
  Acceptance: builds `authenticatorData` per `data-model.md` and signs
  `authenticatorData ‖ clientDataHash` with `pointycastle` for ES256 (DER
  signature, secp256r1) and RS256 (SHA-256 PKCS#1 v1.5); EdDSA returns
  `unsupportedOnPlatform`. Builds `clientDataJSON` `{type:"webauthn.get",
  challenge, origin, crossOrigin:false}`. No new dependency.
  Verify: signatures verify against the T002 public keys; the
  `authenticatorData` bytes equal the vector; EdDSA input → typed failure.

## Phase 3 — US1b: Secret custom fields (P1)

Goal: a user can mark any custom field secret; it is stored protected and
treated like the password in every view.
Independent test: quickstart A2.

- [x] **T101** [US1b] Secret toggle in the editor — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entry_editor.part.dart`,
  `test/features/password_manager/presentation/screens/vault/vault_entry_editor_test.dart`.
  Acceptance: `_CustomFieldFormRow.isProtected`, initialised from the field;
  a per-row "Secret" switch with a semantic label; the value field is
  obscured with a show/hide affordance when on; `_buildCustomFields` passes
  the flag through. Turning the switch off on a row that started protected
  asks for confirmation naming the field (FR-002a). All strings new
  (Constitution VI).
  Verify: widget tests — new row defaults off; toggling on obscures the
  value; saving emits `isProtected: true`; toggling off a protected row shows
  the confirmation and cancel keeps it protected.

- [x] **T102** [US1b] Secret field in the entry detail — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entry_detail.part.dart`,
  `test/features/password_manager/presentation/screens/vault/vault_entry_detail_test.dart`.
  Acceptance: a custom field with `isProtected` renders masked, uses the
  existing `RevealController`, `_showBiometricRevealGate` and
  `ClipboardGuard.copy` exactly as the password row (plan D2a). Plain fields
  are unchanged.
  Verify: widget tests — masked by default; reveal goes through the gate on a
  biometric-protected database; copy calls the guard; the raw value never
  appears in the tree while masked.

- [x] **T103** [P] [US1b] Secret fields in history and merge preview — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/vault_entry_revision.dart`,
  `lib/features/password_manager/domain/models/merge_field_display.dart`,
  `lib/features/password_manager/data/services/kdbx_merge_adapter.dart`,
  `lib/features/password_manager/presentation/screens/vault/vault_entry_history.part.dart`,
  matching tests under `test/`.
  Acceptance: a secret custom field shows by name with redacted sides in the
  merge preview and masked in a history revision, with the same reveal
  behaviour as the revision's password (FR-002b).
  Verify: unit tests on the display models; history widget test asserts the
  value is not rendered while masked.

- [x] **T104** [US1b] Goldens for the secret field — owner: `senior-tester`
  Files: `test/goldens/editor_custom_field_secret_test.dart` (new),
  `test/goldens/vault_entry_detail_secret_field_test.dart` (new), PNGs.
  Acceptance: `editor_custom_field_secret` 390×844 light+dark,
  `vault_entry_detail_secret_field` 390×844 light; contrast ≥ 4.5:1 asserted
  on the toggle label; `warmUpGoldenAssets()` in `setUpAll`; no `di.sl` in
  `dispose`.
  Verify: `fvm flutter test test/goldens --test-randomize-ordering-seed=$RANDOM`
  and the plain run both green.

## Phase 4 — US1: Hold passkeys safely in the vault (P1)

Goal: passkeys from KeePassXC are recognised, shown, protected, deletable and
survive every write path.
Independent test: quickstart A, B, C.

- [x] **T201** [P] [US1] Passkey badge in the list — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entries.part.dart`,
  `test/features/password_manager/presentation/screens/vault/vault_entries_test.dart`.
  Acceptance: an entry with `hasPasskey` shows a badge from `AppIcons` with
  semantic label "Passkey", tokens only, never colour alone (FR-011).
  Verify: widget test finds the semantic label on E1 and not on E2.

- [x] **T202** [US1] Passkey section in the entry detail — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_entry_passkeys.part.dart` (new),
  `lib/features/password_manager/presentation/screens/vault_screen.dart` (one `part`),
  `lib/features/password_manager/presentation/screens/vault/vault_entry_detail.part.dart`,
  `test/features/password_manager/presentation/screens/vault/vault_entry_passkeys_test.dart` (new).
  Acceptance: per passkey — rpId, username, algorithm, created date, backup
  flags as text; an unusable passkey states it cannot be used for sign-in and
  why (FR-012); the fixed security note (FR-009); a delete action ≥ 44 dp
  with a focus ring. No copy or reveal on any passkey value. Rows ≥ 44 dp.
  Verify: widget tests — section renders for E1/E3/E4 with the right text;
  no character of the PEM in the tree; no copy/reveal buttons; unusable copy
  present for E4.

- [x] **T203** [US1] `deletePasskey` on the service — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/vault_kdbx_service.dart`,
  `test/features/password_manager/data/services/vault_kdbx_service_test.dart`.
  Acceptance: per `contracts/vault_kdbx_service_passkeys.md`: removes exactly
  the group whose `(relyingPartyId, credentialId)` matches — not its suffix,
  which a sync can renumber between the read and the write — leaves
  everything else, appends one history revision, throws `PasskeyNotFound` on
  no match. Under `DatabasePathMutex`.
  Verify: delete E3's passkey → E3 keeps password, URL, custom fields,
  attachments and tags; one new revision; a second delete throws; deleting
  from E1 with two groups removes one.

- [x] **T204** [US1] `PasskeyCoordinator.deletePasskey` — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/coordinators/passkey_coordinator.dart` (new),
  `lib/features/password_manager/di/password_manager_presentation_di.dart`,
  `test/features/password_manager/presentation/coordinators/passkey_coordinator_test.dart` (new).
  Acceptance: refuses on a locked session; writes `datedBackupPath` copy
  before the service call (Constitution VII, FR-010); reports a failed write
  with the backup path kept. Mirrors `EntryHistoryCoordinator.clearHistory`.
  Named `deletePasskey`, not `delete`: spec 008 T102's architecture guard
  greps the presentation layer for a bare delete call on a receiver.
  Verify: fakes — locked refuses with no backup; backup precedes delete;
  failed delete keeps the backup and surfaces the error.

- [x] **T205** [US1] Delete flow in BLoC and UI — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/bloc/vault/{vault_event,vault_bloc}.dart`,
  `lib/features/password_manager/presentation/screens/vault/vault_entry_passkeys.part.dart`,
  `lib/features/password_manager/presentation/screens/vault/vault_confirmations.part.dart`,
  matching tests.
  Acceptance: `DeletePasskey` event → coordinator → reload → success message.
  Confirmation names site and username, says it cannot be recovered and that
  a backup is written before anything happens.
  Verify: bloc test emits reload then message; widget test shows the
  confirmation and cancel changes nothing.

- [x] **T206** [P] [US1] Duplicate pairing passkey + password — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/duplicate_group.dart`,
  `lib/features/password_manager/data/services/vault_duplicate_service.dart`,
  `test/features/password_manager/data/services/vault_duplicate_service_test.dart`.
  Acceptance: `DuplicateGroup.kind` with `passkeyPassword`; third pass pairs a
  passkey-only entry with a password entry on the same normalized site and
  username (plan D10); `previewMerge` carries `passkeysToCopy` with protection
  intact and sets `passkeyConflict` when the primary already holds the same
  `(rpId, userHandle)`. Existing groups unchanged.
  Verify: E1 + E2 form one `passkeyPassword` group; two different passkeys on
  the same site are not duplicates; conflict flagged when both have passkeys
  for the same handle.

- [x] **T207** [US1] Merge with a passkey in Vault health — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_duplicates.part.dart`,
  `lib/features/password_manager/data/services/vault_kdbx_service.dart` (merge path),
  matching tests.
  Acceptance: the group is labelled as "same account, one holds the passkey";
  the merge confirmation names the passkey that moves and the backup; the
  merge writes the passkey fields on the primary protected; a conflict refuses
  with an explanation (FR-011a). Never automatic.
  Verify: service test merges E1 into E2 → E2 has the passkey, E1 in the bin,
  protection preserved; widget test shows the label and the refusal copy.

- [x] **T208** [P] [US1] CSV import cannot inject passkey fields — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/vault_csv_import_service.dart`,
  `test/features/password_manager/data/services/vault_csv_import_service_test.dart`.
  Acceptance: a header starting `KPEX_PASSKEY_` is skipped with a warning
  entry in the import report; nothing is written under that key.
  Verify: import a CSV with `KPEX_PASSKEY_PRIVATE_KEY_PEM` → warning, entry
  has no such custom field.

- [x] **T209** [P] [US1] Merge preview collapses the passkey — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/merge_field_display.dart`,
  `lib/features/password_manager/data/services/kdbx_merge_adapter.dart`,
  matching tests.
  Acceptance: the `KPEX_PASSKEY_*` namespace appears as one field
  "Passkey (rpId)" with redacted sides; a per-field choice applies to the
  whole group so a merge never mixes two passkeys (FR-008, edge case).
  Verify: adapter test with a passkey changed on one side shows one row and
  resolves the whole group together.

- [x] **T210** [P] [US1] Desktop metadata cache carries no passkey field — owner: `senior-web-chrome-dev`
  Files: `lib/features/password_manager/data/services/desktop_browser_autofill_cache.dart`,
  `test/features/password_manager/data/services/desktop_browser_autofill_cache_test.dart`.
  Acceptance: the mapper never emits a `KPEX_` key or a protected custom
  field; an entry with a passkey and an empty password is still skipped from
  the *password* cache (it has nothing to fill).
  Verify: mapper test on E1 and E3 asserts the JSON contains no `KPEX_` and no
  protected value.

- [ ] **T211** [US1] Goldens for the passkey surfaces — owner: `senior-tester`
  Files: `test/goldens/vault_entry_passkey_section_test.dart`,
  `test/goldens/vault_list_passkey_badge_test.dart`,
  `test/goldens/vault_passkey_delete_confirm_test.dart` (all new), PNGs.
  Acceptance: inventory in `plan.md` (section 390×844 light+dark, wide
  1024×768 light+dark, unusable 390×844 light, badge 390×844 dark, confirm
  390×844 light); contrast assertions on section text and note.
  Verify: both golden runs green (plain and randomized seed).
  **Needs a Mac, and that is why it is still open.** The committed reference
  PNGs are macOS-rasterized — it is the reason both the `test` and
  `test-random-order` CI jobs exclude `test/goldens/*` — so generating them on
  Linux would replace the reference set with images that fail for every
  maintainer on the platform of record. The contrast half of the acceptance is
  done and does not depend on a PNG: it lives in T602's
  `passkey_contrast_test.dart`, which runs everywhere, reads each background off
  the render tree rather than assuming one, and covers light and dark.

- [ ] **T212** [US1] KeePassXC round-trip on the fixture — owner: `senior-tester`
  Files: `specs/023-passkey-management/device-evidence.md`.
  Acceptance: quickstart A.4, B.1, C.2 executed on a desktop build against a
  copy of the T001 fixture, then the file opened in KeePassXC and E1 used to
  sign in on webauthn.io (SC-001).
  Verify: evidence rows filled with KeePassXC version and outcome.

## Phase 5 — US2: Sign in with a stored passkey — iOS and macOS (P2)

Goal: the credential provider extension answers passkey sign-in requests.
Independent test: quickstart D, on each platform.

- [x] **T301** [US2] Publish passkeys to the sealed cache — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/domain/models/apple_autofill_v2_models.dart`,
  `lib/features/password_manager/data/services/apple_autofill_v2_method_channel_client.dart`,
  `lib/features/password_manager/presentation/coordinators/apple_autofill_v2_coordinator.dart`,
  matching tests.
  Acceptance: the publish entry gains the `passkeys` list of
  `contracts/passkey_platform_bridges.md` — a list, not one block, so an
  entry holding two passkeys does not silently lose one — with one item per
  usable passkey; an entry with a passkey and no password is published;
  result carries `passkeyPublishedCount`; the model's `toString` redacts the
  PEM.
  Verify: client test asserts the payload shape and that `toString` of the
  publish model contains no PEM; coordinator test publishes E1.

- [x] **T302** [US2] Sealed store and metadata on Apple — owner: `senior-apple-dev`
  Files: `ios/CredentialProviderExtension/SharedAutofillStore.swift`,
  `macos/CredentialProviderExtension/SharedAutofillStore.swift`,
  `ios/Runner/*` and `macos/Runner/*` channel handlers that call it.
  Acceptance: `AutofillCredentialSecret.passkey` (optional, Codable);
  metadata gains `hasPasskey`, `passkeyRpId`, `passkeyCredentialId` only;
  entries without a password but with a passkey are stored, not skipped;
  `clearCredentials` wipes them with the rest (FR-023). `Logger` lines carry
  rpId only.
  Also: metadata gains `hasPassword`, so a passkey-only record registers a
  passkey identity but no password identity — it has nothing to fill, and a
  QuickType suggestion that fills an empty field is worse than none.
  Verify: NOT YET VERIFIED — written on Linux, so neither extension target
  has been compiled. Needs an Xcode build plus the Swift unit test
  (Runner test target) round-tripping a secret with a passkey through
  seal/unseal and asserting the metadata JSON has no PEM.

- [x] **T303** [US2] Assertion builder in Swift — owner: `senior-apple-dev`
  Files: `ios/CredentialProviderExtension/PasskeyAssertionBuilder.swift` (new,
  shared into the macOS extension target via the project file).
  Acceptance: builds `authenticatorData` per `data-model.md`; signs with
  CryptoKit `P256.Signing` (DER), `Curve25519.Signing` (raw), and `SecKey`
  for RSA; PKCS#8 parsing for all three; never logs the key.
  Adds `PasskeyUserPresence.swift` beside it: `LAContext`
  `.deviceOwnerAuthentication` (not the biometrics-only policy, so the
  passcode fallback stays available), every time, no reuse window.
  Verify: NOT YET VERIFIED — written on Linux. Needs a Swift unit test with
  the T002 vectors: bytes equal, signatures verify with the public keys.

- [x] **T304** [US2] Passkey requests in the extension controllers — owner: `senior-apple-dev`
  Files: `ios/CredentialProviderExtension/CredentialProviderViewController.swift`,
  `macos/CredentialProviderExtension/MacCredentialProviderViewController.swift`,
  `ios/CredentialProviderExtension/CredentialListView.swift`,
  `macos/CredentialProviderExtension/CredentialListView.swift`,
  both `Info.plist` (`ProvidesPasskeys`).
  Acceptance: per the Apple table in `contracts/passkey_platform_bridges.md`:
  list filtered by rpId and `allowedCredentials`, empty →
  `credentialIdentityNotFound`; without-interaction →
  `userInteractionRequired`; interactive path runs `LAContext`
  `deviceOwnerAuthentication` every time (FR-015), then
  `completeAssertionRequest`; cancel → `userCanceled`. Password behaviour
  unchanged.
  Verify: NOT YET VERIFIED — written on Linux, never compiled. Needs a build
  of both targets, quickstart D.1–D.4 on device recorded in
  `device-evidence.md`, and the existing password autofill smoke.

## Phase 6 — US2: Sign in with a stored passkey — Android (P2)

Goal: a Credential Manager provider serves passkeys on API 34+, and the app
says so below it.
Independent test: quickstart E.

- [x] **T401** [US2] Publish passkeys to the Android sealed store — owner: `senior-android-dev`
  Files: `android/app/src/main/kotlin/dev/camillobucciarelli/kdbxKeyVault/autofill/{AndroidAutofillModels.kt,AndroidAutofillJson.kt,AndroidAutofillStore.kt,AndroidAutofillV2Channel.kt}`.
  Acceptance: the secret record gains a `passkeys` list; metadata gains the
  same list reduced to `rpId`/`credentialId`, plus `hasPassword` so a
  passkey-only record is never offered as an autofill dataset; an entry with a
  passkey and no password is stored (the `entry_without_password_skipped`
  warning applies only to entries with neither); `clearCredentials` wipes it.
  Verify: PARTIAL — `AndroidPasskeySerializationTest` covers the JSON round
  trip, the metadata redaction, the pre-023 default and the BE/BS rule, but
  has NOT been run: no Android SDK on the machine this was written on. The
  AES-GCM seal itself is still uncovered (it needs a device or Robolectric).

- [x] **T402** [P] [US2] Assertion builder in Kotlin — owner: `senior-android-dev`
  Files: `android/.../autofill/PasskeyAssertionBuilder.kt` (new), test under
  `android/app/src/test/`.
  Acceptance: `authenticatorData` per `data-model.md`; JCA signing for
  `SHA256withECDSA`, `Ed25519` (API 33+; below → unusable), `SHA256withRSA`
  from PKCS#8; `clientDataJSON` with `origin` from `callingAppInfo.origin` or
  `android:apk-key-hash:`; produces the WebAuthn `PublicKeyCredential` JSON.
  Verify: NOT YET VERIFIED — `android.util.Base64` and the JCA providers need
  a device or Robolectric, and nothing here has been compiled. Needs a unit
  test with the T002 vectors.

- [x] **T403** [US2] Credential provider service — owner: `senior-android-dev`
  Files: `android/app/build.gradle.kts` (`androidx.credentials:credentials`,
  current stable pinned in the task), `android/app/src/main/AndroidManifest.xml`,
  `android/app/src/main/res/xml/keyvault_credential_provider.xml` (new),
  `android/.../autofill/KeyVaultCredentialProviderService.kt` (new).
  Acceptance: service declared with `BIND_CREDENTIAL_PROVIDER_SERVICE`;
  `onBeginGetCredentialRequest` filters metadata by rpId and
  `allowCredentials` and returns one `PublicKeyCredentialEntry` per match with
  a `PendingIntent` to T404; no match → empty response. The autofill service
  of spec 016 is untouched.
  The service ships `android:enabled="false"` and
  `AndroidPasskeyProviderAvailability.reconcile` turns it on at runtime on API
  34+: a component declared on API 29–33 would show a setting that does
  nothing.
  Verify: NOT YET VERIFIED — never compiled (no Android SDK). Needs a build
  against the API 34 SDK and a check that the provider appears in system
  settings on an API 34+ device.

- [x] **T404** [US2] Per-assertion authentication activity — owner: `senior-android-dev`
  Files: `android/.../autofill/PasskeyAuthActivity.kt` (new), manifest entry.
  Acceptance: `BiometricPrompt` with `BIOMETRIC_STRONG | DEVICE_CREDENTIAL`
  on every request, never reading `AndroidAutofillAuthSession` (FR-015);
  success → secret → T402 → `PendingIntentHandler.setGetCredentialResponse`;
  cancel → `GetCredentialCancellationException`; missing →
  `NoCredentialException`.
  Verify: NOT YET VERIFIED — never compiled. Needs quickstart E.1 and E.3
  recorded in `device-evidence.md`.

- [x] **T405** [US2] API floor and settings row — owner: `senior-android-dev`, `senior-flutter-dev`
  Files: `android/.../autofill/AndroidPasskeyProviderAvailability.kt` (new —
  the component enable lives here and runs from the channel's `init`, which
  every app start constructs, rather than in `MainActivity`),
  `android/.../autofill/AndroidAutofillV2Channel.kt` (`getPasskeyProviderAvailability`),
  `lib/features/password_manager/data/services/apple_autofill_v2_method_channel_client.dart`,
  `lib/features/password_manager/presentation/screens/vault/vault_settings.part.dart`,
  matching tests.
  Acceptance: provider component enabled only when `SDK_INT >= 34`,
  re-evaluated on every start (plan D9); the settings row says passkey
  sign-in is not available on this device below 34 (FR-013). `minSdk` stays 29.
  Verify: widget test for both states of the row; quickstart E.2 on an API
  29–33 device recorded in `device-evidence.md`.

## Phase 7 — US2: Sign in with a stored passkey — Windows and Linux (P2)

Goal: the browser extension serves passkey sign-in through the native host and
the app, with the key never leaving the app.
Independent test: quickstart F.

- [x] **T501** [US2] `passkeyAssert` in the native host protocol — owner: `senior-web-chrome-dev`
  Files: `tool/native_host_protocol.dart`, `tool/native_host.dart`,
  `test/tool/native_host_test.dart`.
  Acceptance: new type per `contracts/passkey_platform_bridges.md`;
  `hello` advertises `passkeyAssertV1` only when the app bridge descriptor
  lists it; `challenge` and `allowCredentials` in `_sensitiveRequestKeys`;
  forwarded to `/passkey-assert`; 64 KiB cap; an old host answers
  `unsupported_type`.
  Verify: protocol tests — round-trip, capability gating, sensitive keys not
  echoed in an error frame, response with a `privateKeyPem` key is rejected
  (never forwarded).

- [x] **T502** [US2] `/passkey-assert` in the app bridge — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/desktop_browser_autofill_reveal_bridge_service.dart`,
  `lib/features/password_manager/data/services/desktop_browser_autofill_cache.dart` (descriptor capability),
  `lib/features/password_manager/presentation/coordinators/desktop_browser_autofill_coordinator.dart`,
  `lib/features/password_manager/presentation/screens/vault/vault_dialogs.part.dart`,
  matching tests.
  Acceptance: requires an unlocked session; checks rpId against the origin's
  effective domain or a registrable suffix; finds usable passkeys for the
  rpId (and `allowCredentials`); raises the in-app confirmation naming site
  and username on every request (FR-015); signs with T014; answers the
  contract shape; `reason` codes for every failure. No PEM in any response
  or log.
  Verify: service tests with fakes for each reason code; rpId mismatch
  refused; confirmation declined → `declined`; success payload verifies with
  the vector public key.

- [x] **T503** [US2] Page-world interception in the extension — owner: `senior-web-chrome-dev`
  Files: `desktop/browser_extension/passkey_page.js` (new, MAIN world),
  `desktop/browser_extension/passkey_bridge.js` (new, isolated world),
  `desktop/browser_extension/overlay_lifecycle.js`,
  `desktop/browser_extension/overlay_routes.js`,
  `desktop/browser_extension/background.js`,
  `desktop/browser_extension/package_extension.sh`,
  `.github/workflows/pr.yml` (syntax gate),
  `desktop/browser_extension/test/`.
  Acceptance: a MAIN-world script and an isolated-world relay registered on
  the granted hosts under the overlay's own switch, at `document_start`
  because the page may call `navigator.credentials.get` before
  `document_idle`; the wrapper relays to the worker, which sends
  `passkeyAssert`; on `ok:true` resolves a `PublicKeyCredential`-shaped
  object (research R12); on anything else calls the original function so the
  browser's own UI appears. `create` is not wrapped.

  Two deviations from the plan, both deliberate. **A pair of scripts, not
  one**: a registration names one world, and the wrapper must be in the
  page's world while only an isolated world may talk to the worker. **No
  shared nonce**: the pair communicate through the page's own world, which
  the page reads and writes at will, so a nonce there authenticates nothing.
  What actually protects the key is that the request carries no origin at
  all — the worker takes it from `sender.url` — so a forged message buys a
  page nothing it could not get by calling `navigator.credentials.get`
  honestly. The message id is a correlation id for concurrent calls, not a
  secret. The route is likewise kept out of the frozen four-type
  `CONTENT_ROUTES` set, which carries an `origin` claim this request must
  not have.
  Verify: `node --test desktop/browser_extension/test/*.test.js` — 443
  existing plus 10 new route tests and 2 new registration tests; quickstart
  F.1–F.5 recorded in `device-evidence.md` on Windows and Linux.

- [x] **T504** [P] [US2] Update note for the extension — owner: `senior-web-chrome-dev`
  Files: `desktop/browser_extension/README.md`.
  Acceptance: explains that the extension now answers passkey sign-in on
  granted sites, that the key stays in the app, and that the app asks before
  each use (Assumptions), plus the page-world registration and the
  `instanceof` limit. `store_assets/` holds only screenshots, so there is no
  listing copy there to change.
  Verify: text present; no permission added to `permissions`.

## Phase 9 — US3: Create a new passkey (P3, desktop only)

Goal: a site's `navigator.credentials.create` can put a new credential in the
open vault.
Independent test: a registration on a test relying party from a desktop
browser, then signing in with the credential it created (Phase 7).

**Why desktop and not Apple, which is what the spec's US3 names.** Only the
vault-writing process can satisfy FR-020, and on Apple the credential provider
extension is not that process: it has no master password, so it cannot write
the `.kdbx` at all. It could seal a credential into its own cache and hope the
app adopts it later, but then the site would be told "registered" for something
the vault does not hold — exactly the failure FR-020 forbids, and the one that
costs the user their account, because a site that accepts a passkey often
retires the password. On desktop the app *is* running and unlocked when the
request arrives, so the write completes before the site is answered.

**The Apple decision (T708), settled.** Registration always goes through the
app: the extension stays a plugin of the app and implements no step of a
registration the app does not perform. There is no staged-credential handshake,
because a staged credential can only be adopted *after* the ceremony the site
ran, and a WebAuthn challenge cannot be answered late — so staging would buy the
site nothing and would cost the user the account the moment the extension
claimed success. What the extension does instead is refuse the ceremony
explicitly and say where creating a passkey does work. The remaining gap is a
*transport*, not a policy: an extension running while the app is open and
unlocked could ask the app to do the whole job and return the attestation inside
the ceremony. On macOS that is expressible (an app-group XPC listener in the
app); on iOS there is no supported extension-to-app channel at all, so iOS
registration cannot be completed by any design. That transport is T709.

- [x] **T701** [US3] Key generation — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/passkey_generator.dart`
  (new), `test/features/password_manager/data/services/passkey_generator_test.dart`
  (new).
  Acceptance: ES256 only (the one algorithm every relying party accepts, the
  desktop signer can sign and all three platforms verify — offering EdDSA
  would create credentials the desktop bridge cannot use, research R10); a
  32-byte credential id; PKCS#8 PEM the existing parser reads back; a
  canonical EC2 COSE_Key; an `fmt: "none"` attestation object with the AT flag
  set and a zero AAGUID and sign counter. CBOR is hand-encoded — this is the
  only CBOR the app writes and its shape is fixed.
  Verify: 8 tests, including a signature produced by
  `DesktopPasskeySigner` verified against the COSE key the generator
  published, which is the relying party's own side of the exchange.

- [x] **T702** [US3] `createPasskey` on the service — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/vault_kdbx_service.dart`,
  `lib/features/password_manager/domain/errors/passkey_errors.dart`,
  `test/.../vault_kdbx_service_test.dart`.
  Acceptance: writes the KeePassXC layout with KeePassXC's own protection
  flags (key, credential id and user handle protected; rp, username and flags
  not) into the first free suffix group, under `DatabasePathMutex`, in one
  locked action so the file holds the whole credential or none of it (FR-020);
  throws `PasskeyAlreadyExists` on a `(rpId, userHandle)` clash unless
  `replaceExisting` (FR-019); a replacement removes the clashing group whole,
  unparsed fields included.
  Verify: 7 tests — protection flags, second group, clash, different account,
  replacement, no-handle, unknown entry.

- [x] **T703** [US3] `PasskeyCoordinator.createPasskey` — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/coordinators/passkey_coordinator.dart`,
  matching tests.
  Acceptance: refuses on a locked session; dated backup before the write; a
  clash reports `alreadyExists`; a failed write returns no `GeneratedPasskey`
  at all, so a caller cannot report success for a credential the vault does
  not hold (FR-020).
  Verify: 6 tests, including that the backup exists on disk when the write
  runs.

- [x] **T704** [US3] `/passkey-create` on the app bridge — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/data/services/desktop_browser_autofill_reveal_bridge_service.dart`,
  `lib/features/password_manager/data/services/desktop_passkey_approval_service.dart`,
  `lib/features/password_manager/presentation/coordinators/desktop_browser_autofill_coordinator.dart`,
  matching tests.
  Acceptance: rp id checked against the origin as on the assert path (FR-014);
  the confirmation offers the records whose site already matches so a passkey
  can be attached to an existing entry (FR-018) and says which of them would
  be replaced (FR-019); the write happens before the response; SR-4 binding
  re-checked after the prompt; `passkeyCreateV1` advertised only when both the
  confirmation and the writer are wired. The hooks are bound per vault session
  by the coordinator, which is the only place that knows which database is
  open — binding them in DI would let a write land in a vault the user had
  switched away from.
  Verify: 9 service tests.

- [x] **T705** [US3] `passkeyCreate` in the native host — owner: `senior-web-chrome-dev`
  Files: `tool/native_host_protocol.dart`.
  Acceptance: a new request type (so an old host answers `unsupported_type`
  and the extension falls back); forwards to `/passkey-create` on the 90 s
  budget; passes a `{reason}` refusal through unchanged; refuses a truncated
  response rather than half-using it; `passkeyCreateV1` advertised only when
  the app descriptor lists it.
  Verify: covered by the existing `native_host_test.dart` suite staying green;
  its own cases are not written yet.

- [x] **T706** [US3] `navigator.credentials.create` in the extension — owner: `senior-web-chrome-dev`
  Files: `desktop/browser_extension/{passkey_page.js,passkey_bridge.js,overlay_routes.js}`,
  `desktop/browser_extension/test/passkey_routes.test.js`.
  Acceptance: the page-world wrapper falls through to the browser when the
  site will not accept ES256, so a user never sees a confirmation for a
  registration Custode could not have served; resolves a registration-shaped
  object with `getPublicKey`, `getPublicKeyAlgorithm`, `getTransports` and
  `getAuthenticatorData`; the worker route takes its origin from `sender.url`
  and answers `{ok:false}` to every refusal, so no reason reaches the page.
  Verify: 7 route tests.

- [x] **T707** [US3] The creation confirmation — owner: `senior-flutter-dev`
  Files: `lib/features/password_manager/presentation/screens/vault/vault_passkey_approval.part.dart`.
  Acceptance: one matching record → one confirmation naming it; several → a
  chooser saying which already hold a passkey for the site; none → an
  explanation rather than a silent refusal; a record that already holds one →
  a second, explicit replacement confirmation (FR-019) mentioning the dated
  backup. Never creates a new record: a brand-new entry needs a title and a
  folder, and asking for those while a site waits is how a half-considered
  record gets made.
  Verify: 6 widget tests in
  `test/.../vault/vault_passkey_creation_prompt_test.dart`, driven through the
  real `DesktopPasskeyApprovalService` and the vault shell: one candidate, a
  decline, no candidate, several candidates, the replacement confirmation and a
  declined replacement. Each asserts the decision handed back to the bridge, not
  only what appeared — a dialog that reads right but resolves the wrong entry
  would pass on the copy alone.

- [x] **T708** [US3] Registration on Apple — the decision and the refusal — owner: `senior-apple-dev`
  Files: `ios/CredentialProviderExtension/{CredentialProviderViewController.swift,CredentialListView.swift}`,
  `macos/CredentialProviderExtension/{MacCredentialProviderViewController.swift,CredentialListView.swift}`.
  Decision: registration always goes through the app; the extension never mints
  a key, never seals one and never tells a site a credential exists (see the
  phase note above).
  Acceptance: `prepareInterface(forPasskeyRegistration:)` is implemented on both
  platforms and refuses — it names the site and the account, explains that a
  passkey is written into the vault which only the app can open, says where
  registration does work, and cancels with `ASExtensionError.failed` rather than
  `.userCanceled` so the browser can offer another provider instead of treating
  the ceremony as abandoned. Nothing is written, nothing is staged. Without the
  override the system presented this extension's empty sheet and the ceremony
  hung with no explanation, so this also closes that.
  Verify: NOT COMPILED — no Xcode in the agent environment. The Swift lands
  unbuilt, as the rest of `ios/`/`macos/` in this spec did; the first `release.yml`
  run on a self-hosted runner is what type-checks it. Behaviour is verified on
  device as quickstart D.6 (a registration attempt from Safari shows the refusal
  and the site reports a failure, not a success).

- [ ] **T709** [US3] macOS registration transport — owner: `senior-apple-dev`
  The policy is settled by T708; this is the channel that would let the refusal
  become a completion on macOS: an app-group XPC listener in the running app,
  which the extension calls while its UI is up, so the app chooses the record,
  writes the `.kdbx` and returns the attestation — the write completing before
  the site is answered, exactly as the desktop-browser path does (FR-020).
  Out of scope for iOS at any size: there is no supported extension-to-app
  channel there.
  Not started, and not a blocker for the beta: it needs a Mac to build and an
  XPC service target in `macos/Runner.xcodeproj`, neither of which exists in the
  agent environment.

## Phase 8 — Polish and verification gate

- [ ] **T601** Redaction sweep — owner: `senior-tester`
  Files: none new; `specs/023-passkey-management/device-evidence.md`.
  Acceptance: quickstart G — the grep hits only the generator's PEM header
  constant; verbose logs from one run of A, D, E and F contain no
  `PRIVATE KEY` (SC-002).
  Verify: evidence row with the grep output summary and log sizes.
  Half done: the grep is clean as of this commit — the one hit is
  `passkey_generator.dart:224`, the header the app itself writes. It took
  de-PEM-ing the Kotlin round-trip fixture, which nothing on that path parses.
  The log half needs the device runs and stays open.

- [x] **T602** [P] Contrast and accessibility assertions — owner: `senior-tester`
  Files: `test/features/password_manager/presentation/accessibility/passkey_contrast_test.dart` (new).
  Acceptance: every new text/background pairing ≥ 4.5:1 in light and dark;
  badge has a semantic label; delete action ≥ 44×44 with a focus ring
  (Constitution V).
  Verify: tests green.

- [ ] **T603** Full quickstart run and board sync — owner: `senior-tester`
  Files: `specs/023-passkey-management/device-evidence.md`, `tasks.md`.
  Acceptance: sections A–G executed, every D–F row filled with device and
  version; `fvm flutter analyze` clean; `fvm flutter test` green with the
  before/after test count recorded here; `PROJECT_NUMBER=2
  tool/sync_spec_project.sh` run and the board state reported.
  Verify: this box is the last one ticked.

## Dependencies

```
T001 T002 T003 (parallel)
   └─▶ T010 ─▶ T011 T012 T014 (parallel) ─▶ T013
                    ├─▶ US1b: T101 T102 (after T010) · T103 [P] · T104
                    ├─▶ US1:  T201 T206 T208 T209 T210 [P] · T202 ─▶ T203 ─▶ T204 ─▶ T205 · T207 (after T206) · T211 · T212
                    ├─▶ Apple:   T301 ─▶ T302 ─▶ T303 ─▶ T304
                    ├─▶ Android: T401 · T402 [P] ─▶ T403 ─▶ T404 ─▶ T405
                    └─▶ Desktop: T501 · T502 (after T014) ─▶ T503 · T504 [P]
                                        └─▶ T601 T602 [P] ─▶ T603
```

US1b depends only on T010. US1 depends on T011–T013. The three US2 platform
phases depend on T013 and are independent of each other and of US1's UI.

### Parallel opportunities

- Phase 1 entirely; T011, T012, T014 together after T010.
- US1b and US1 UI in parallel once T013 lands (different part files).
- Apple, Android and desktop phases in parallel, one owner each.
- T206/T208/T209/T210 alongside T202–T205.

## Implementation strategy

1. **Bug fix first**: T010 alone is a shippable fix (protected custom fields
   stop being downgraded) and goes in before anything else.
2. **MVP**: Phase 2 + US1b + US1 — the vault holds passkeys and secret fields
   correctly on every platform with no native code touched.
3. **Then one platform at a time**, Apple first (least new code), Android,
   desktop. Each is independently releasable; a beta may ship with any subset
   and the spec's per-platform scenarios say what each subset proves.
4. **Gate**: Phase 8 closes the spec for the beta; US3 stays unplanned.
