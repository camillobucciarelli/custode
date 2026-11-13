# 023 — Implementation plan

**Scope of this plan**: slices 1 and 2 of `spec.md` (hold + sign-in on iOS,
macOS, Android, Windows, Linux). Slice 3 (registration) is not planned here.

## Technical context

| | |
|---|---|
| **Language / runtime** | Dart 3, Flutter 3.47.1 (`.fvmrc`); Swift (Apple extension); Kotlin (Android); JS (browser extension) |
| **Vault format** | KDBX via `kdbx: ^2.5.0`; `ProtectedValue` is accepted by `KdbxEntry.setString` for any key |
| **Storage contract** | KeePassXC `KPEX_PASSKEY_*` fields — see `research.md` R1/R9 (verified against KeePassXC source on 2026-09-09) |
| **Layer entry point** | `data/services/vault_kdbx_service.dart` — the only semantic reader/writer of entry fields |
| **State** | `VaultBloc` only; no new BLoC |
| **Sequencing** | New `PasskeyCoordinator` (delete with backup; duplicate merge already has `VaultDuplicateService.previewMerge` + the merge path in `vault_duplicates.part.dart`) |
| **Apple** | `ios/CredentialProviderExtension`, `macos/CredentialProviderExtension` (already receive `ASPasskeyCredentialRequestParameters`); `SharedAutofillStore` sealed cache; CryptoKit / Security for signing |
| **Android** | New `CredentialProviderService` (androidx.credentials, API 34+); reuses `AndroidAutofillStore` sealed cache; JCA `Signature` for signing |
| **Desktop** | `desktop/browser_extension` (MV3, `scripting.registerContentScripts`), `tool/native_host.dart` protocol v2, app-side reveal bridge HTTP server; `pointycastle: ^4.0.0` (already a direct dependency) for ES256/RS256 in the app |
| **Unknowns** | None blocking. Two verified-by-task items remain (R9): the exact base64url variant of `KPEX_PASSKEY_USER_HANDLE` on a real KeePassXC vault, and Ed25519 support for desktop signing (pointycastle has none — EdDSA passkeys are *unusable* on desktop, FR-012, unless a later task finds a no-new-dependency path). |

## Constitution check

| Principle | How this plan satisfies it |
|---|---|
| **I — secrets never leak** | `VaultCustomField` gains `isProtected`; protected fields are excluded from the ordinary custom-field list surfaced to UI, editor, merge preview, history revisions, CSV import, duplicate preview text and the desktop metadata cache. `VaultPasskey` redacts `privateKeyPem` in `props`/`toString`. The private key travels only: `.kdbx` (protected) → sealed platform cache (Apple/Android) or in-process signer (desktop). The browser extension never receives it (FR-013a). |
| **II — layering** | presentation → `PasskeyCoordinator` → `VaultKdbxService`; platform adapters behind the existing channel clients and bridge service. No UI import of `data/`. |
| **III — tokens** | New badge, section and dialogs read `AppColors`/`AppTextStyles`/`AppSpacing`/`AppRadii`/`AppMotion`. |
| **IV — pixel fidelity** | Golden inventory below at 390×844 and 1024×768, light and dark. |
| **V — accessibility** | Badge has a semantic label ("Passkey"), never colour only; section rows ≥ 44 dp; focus ring on the delete action; contrast asserted. |
| **VI — existing copy** | No existing string changes. All passkey strings are new. |
| **VII — destructive ops** | Delete passkey and merge-duplicates-with-passkey both confirm, state what is lost, and write `datedBackupPath` before the write (D2). |
| **VIII — smallest thing** | One coordinator, one domain model, one service extension. No passkey repository abstraction: the platform bridges already exist and gain fields, not new ports. The Android provider service is new because the platform requires a separate service class, not by choice. |
| **IX — local verification** | `flutter analyze` + `flutter test` before every commit; platform flows in the named manual harness (`quickstart.md`, and `device-evidence.md` for hardware rows). |

**Deliberate tension**: FR-015 (user presence per assertion) on Windows/Linux
has no OS biometric hook this app uses today, so "explicit in-app confirmation"
is a modal in the running app raised by the reveal bridge, reusing the overlay
reveal authorization dialog pattern. It is weaker than a biometric and the plan
says so in the section copy rather than pretending otherwise.

## Decisions

- **D1 — Detection, not tags.** An entry holds a passkey when
  `KPEX_PASSKEY_RELYING_PARTY`, `KPEX_PASSKEY_CREDENTIAL_ID` and
  `KPEX_PASSKEY_PRIVATE_KEY_PEM` are all present. KeePassXC's tag is
  `tr("Passkey")` — localized — so it is never a detection input; Custode
  neither adds nor removes tags.
- **D2 — Protection flag is data the user owns.** `VaultCustomField.isProtected`
  is read from the file (`StringValue is ProtectedValue`), shown as a per-field
  "secret" toggle in the editor, and written back exactly as held. Passkey
  secret fields are written protected (matching KeePassXC's `set(..., true)`)
  and every other `KPEX_PASSKEY_*` field keeps the flag it arrived with
  (FR-003). Fixing the writer's current downgrade-to-plain is the first task
  of Phase 0 and lands with its own regression test (SC-008), independent of
  everything passkey.
- **D2a — A secret custom field is rendered by the password's widgets.** The
  detail row reuses the masked value, `RevealController`, the biometric reveal
  gate and `ClipboardGuard.copy` exactly as the password row does; the editor
  row reuses the obscured text field. No new secret-handling code path.
- **D3 — Two views of custom fields.** `VaultEntry.customFields` keeps its
  meaning for the UI (plain, editable) and **excludes** the `KPEX_PASSKEY_*`
  namespace entirely; `VaultEntry.passkeys` carries the parsed credentials and
  `VaultEntry.passkeyDigest` a fingerprint of the raw set. The raw strings are
  not carried on the model: the writer never removes or writes the namespace,
  so it stays in place in the `KdbxEntry`. The editor never sees passkey
  fields, so it cannot render, edit or drop them.
- **D4 — Unusable passkeys** (missing field, unparseable PEM, unsupported
  algorithm on this platform) are `VaultPasskey(usable: false, reason)`. They
  are shown, never published to any platform cache, and left untouched.
- **D5 — Signing lives where the request lands.** Apple: in the extension
  (CryptoKit `P256.Signing`, `Curve25519.Signing`; RSA via `SecKey`). Android:
  in the provider service (JCA `SHA256withECDSA`, `Ed25519`, `SHA256withRSA`).
  Desktop: in the app process behind the reveal bridge (`pointycastle`
  ECDSA/RSA; EdDSA unusable). No key ever crosses to the extension or the
  native host.
- **D6 — One WebAuthn assertion builder per platform, no CBOR.** An assertion
  needs `authenticatorData` (rpIdHash ‖ flags ‖ signCount) and a signature over
  `authenticatorData ‖ clientDataHash`. Sign count is always 0 (KeePassXC does
  the same; a synced vault cannot keep a monotonic counter). Flags: UP=1, UV=1
  (the per-assertion confirmation is the verification), BE/BS from the stored
  flags. CBOR is only needed for registration and stays out of this plan.
- **D7 — Cache shape.** `AutofillCredentialSecret` (Apple) and its Android
  twin gain an optional `passkey` block `{rpId, credentialId, userHandle,
  username, privateKeyPem, algorithm, flagBe, flagBs}`. Same seal, same key,
  same lifetime (FR-022/023). The plaintext metadata caches gain only a
  boolean `hasPasskey` plus `rpId` for routing, never the secret.
- **D8 — Desktop bridge is a new message type**, `passkeyAssert`, per the
  fail-closed reasoning already written in `tool/native_host_protocol.dart`:
  an old host answers `unsupported_type` and the extension shows nothing. The
  extension gains a `MAIN`-world content script that wraps
  `navigator.credentials.get` and forwards `publicKey` options to the isolated
  world; the native host forwards to the app's `/passkey-assert` endpoint.
- **D9 — Android floor.** The provider service is declared with
  `android:enabled="@bool/passkey_provider_enabled"` evaluated at runtime
  (`Build.VERSION.SDK_INT >= 34`) via `PackageManager.setComponentEnabledSetting`
  on first launch; the settings screen shows "not available on this device"
  below 34. `minSdk` stays 29.
- **D10 — Duplicate pairing.** `VaultDuplicateService`'s site pass gains a
  third outcome (implemented inside that pass rather than after it, so a
  bucket is classified once and an entry cannot land in two groups): a
  passkey-only entry (empty password) and a password entry sharing normalized
  site and username form a group of kind `passkeyPassword`. A bucket holding
  two or more passkeys drops the holders instead — two credentials for one site
  are not copies of each other. `previewMerge` carries the secondary's passkey
  into the primary as a credential, protected flags preserved, and refuses if
  the primary already holds a passkey for the same rpId + userHandle.

## Phases

### Phase 0 — Storage and confidentiality (US1 + US1b core)

- **First**: `VaultCustomField.isProtected`; `_mapCustomFields` reads it,
  `_setCustomFields` writes `ProtectedValue` for it. Regression test: a
  protected custom field survives a title-only save (SC-008). This is a
  standalone bug fix and is committed before any passkey code.
- `VaultPasskey`, `VaultPasskeyAlgorithm` in `domain/models/`.
- `VaultKdbxService`: `_mapCustomFields` also splits out the `KPEX_PASSKEY_*`
  namespace; `_setCustomFields` leaves that namespace in place;
  `deletePasskey(entryId, credentialId)`; `passkeyParser.dart` (pure) for
  PEM → algorithm, base64url decode, usability.
- CSV import: a `secret` marker is not introduced; imported custom fields stay
  plain (no format defines one). Duplicate merge and revision restore carry
  `isProtected` through unchanged.
- History: `_mapRevision` applies the same split so a revision never carries
  the private key; `restoreEntryRevision` leaves the *current* entry's passkey
  namespace in place (a restore never touches the passkey).
- CSV import drops any `KPEX_PASSKEY_*` column with a warning row.
- Merge preview (`MergeFieldDisplay`) collapses the namespace into one
  "Passkey (rpId)" field with redacted sides.
- Desktop metadata mapper skips protected fields (it already iterates
  `customFields`; after D3 they are gone from that list — assert it).

### Phase 1 — Show, badge, delete (US1 + US1b UI)

- Editor (`vault_entry_editor.part.dart`): `_CustomFieldFormRow.isProtected`
  with a "Secret" toggle per row; obscured text field when on; confirmation
  when turning it off on a field that arrived protected (FR-002a).
- Detail (`vault_entry_detail.part.dart`): a secret custom field renders with
  the password row's masked value, reveal gate and clipboard guard (D2a).
- History diff and `MergeFieldDisplay`: a secret field appears by name with
  redacted sides, as the password does.
- `vault_entries.part.dart`: passkey badge on the list item (semantic label).
- New `vault_entry_passkeys.part.dart`: section in entry detail with rpId,
  username, created date, algorithm, usability, the fixed security note
  (FR-009), delete action.
- `PasskeyCoordinator.delete`: locked → refuse; confirm copy; backup;
  service delete; reload.
- `VaultBloc`: `DeletePasskey` event + success message; state carries nothing
  new (passkeys ride on `VaultEntry`).
- Vault health: duplicate group kind `passkeyPassword` and merge copy (D10).

### Phase 2 — Apple sign-in (US2)

- Dart: publish payload gains the passkey block from `VaultEntry.passkeys`
  (usable only); `AppleAutofillV2Coordinator` unchanged otherwise.
- Swift (shared file in both targets): `AutofillCredentialSecret.passkey`;
  `Info.plist` adds `ProvidesPasskeys`; `prepareCredentialList(for:requestParameters:)`
  filters by `relyingPartyIdentifier` and `allowedCredentials`;
  `provideCredentialWithoutUserInteraction(for: ASPasskeyCredentialRequest)`
  → `.userInteractionRequired` (FR-015); `prepareInterfaceToProvideCredential`
  → LAContext `deviceOwnerAuthentication` → `PasskeyAssertionBuilder` →
  `ASPasskeyAssertionCredential`; cancel paths map to
  `ASExtensionError.userCanceled` / `.credentialIdentityNotFound`.
- Clear on lock/remove already wipes the sealed file; assert the passkey block
  goes with it.

### Phase 3 — Android sign-in (US2)

- Gradle: `androidx.credentials:credentials:1.3.0` (verify latest stable in
  the task), `KeyVaultCredentialProviderService` (API 34), manifest entry with
  `android.permission.BIND_CREDENTIAL_PROVIDER_SERVICE`, `credential_provider`
  meta-data XML.
- `onBeginGetCredentialRequest`: read metadata cache, filter by rpId and
  allowed ids, one `PublicKeyCredentialEntry` per match, each with a
  `PendingIntent` to `PasskeyAuthActivity`.
- `PasskeyAuthActivity`: `BiometricPrompt` (DEVICE_CREDENTIAL | BIOMETRIC_STRONG)
  every time (no reuse of `AndroidAutofillAuthSession` — FR-015) → read secret
  from `AndroidAutofillStore` → `PasskeyAssertionBuilder` → `PublicKeyCredential`
  JSON → `PendingIntentHandler.setGetCredentialResponse`.
- Runtime enable/disable of the component (D9); Flutter settings row.

### Phase 4 — Desktop sign-in (US2)

- Extension: `passkey_page_bridge.js` (MAIN world, registered alongside the
  overlay script, only on hosts the user granted) wraps
  `navigator.credentials.get`; `content_overlay.js` relays via
  `runtime.sendMessage`; `background.js` sends `passkeyAssert` to the host;
  the reply is turned into a `PublicKeyCredential`-shaped object.
- Native host: `passkeyAssert` type, forwarded to `/passkey-assert`, response
  size-capped, `_sensitiveRequestKeys` extended.
- App: `DesktopBrowserAutofillRevealBridgeService._handlePasskeyAssert` →
  in-app confirmation modal (FR-015) → `DartPasskeySigner` (pointycastle) →
  response. rpId must equal the request origin's effective domain or a
  registrable suffix of it (same check WebAuthn clients make).
- Extension permission change: none new in `permissions` — the MAIN-world
  script rides on the already optional host permissions; the update note
  still explains the new behaviour (Assumptions).

### Phase 5 — Verification

Goldens, contrast, redaction sweep, KeePassXC round-trip on a real vault,
quickstart run on each platform, `device-evidence.md` rows.

## Files touched

**New**

- `lib/features/password_manager/domain/models/vault_passkey.dart`
- `lib/features/password_manager/data/services/passkey_parser.dart`
- `lib/features/password_manager/data/services/desktop_passkey_signer.dart`
- `lib/features/password_manager/presentation/coordinators/passkey_coordinator.dart`
- `lib/features/password_manager/presentation/screens/vault/vault_entry_passkeys.part.dart`
- `ios/CredentialProviderExtension/PasskeyAssertionBuilder.swift` (shared into macOS target)
- `android/.../autofill/KeyVaultCredentialProviderService.kt`, `PasskeyAuthActivity.kt`, `PasskeyAssertionBuilder.kt`
- `desktop/browser_extension/passkey_page_bridge.js`
- `specs/023-passkey-management/device-evidence.md`
- tests mirroring each of the above; `test/fixtures/passkeys/keepassxc_passkeys.kdbx` (fixture built by KeePassXC, password documented in the test — same convention as existing fixtures)

**Modified**

- `domain/models/vault_custom_field.dart`, `vault_entry.dart`, `vault_entry_revision.dart`, `duplicate_group.dart`, `merge_field_display.dart`
- `data/services/vault_kdbx_service.dart`, `vault_csv_import_service.dart`, `vault_duplicate_service.dart`, `desktop_browser_autofill_cache.dart`, `desktop_browser_autofill_reveal_bridge_service.dart`, `apple_autofill_v2_method_channel_client.dart`
- `domain/models/apple_autofill_v2_models.dart`
- `presentation/bloc/vault/{vault_event,vault_bloc}.dart`, `screens/vault_screen.dart`, `vault_entries.part.dart`, `vault_entry_detail.part.dart`, `vault_entry_editor.part.dart`, `vault_entry_history.part.dart`, `vault_duplicates.part.dart`, `vault_settings.part.dart`
- `di/password_manager_presentation_di.dart`
- `ios/CredentialProviderExtension/{Info.plist,SharedAutofillStore.swift,CredentialProviderViewController.swift,CredentialListView.swift}`, macOS twins
- `android/app/build.gradle.kts`, `AndroidManifest.xml`, `AndroidAutofillStore.kt`, `AndroidAutofillModels.kt`, `AndroidAutofillJson.kt`, `AndroidAutofillV2Channel.kt`
- `desktop/browser_extension/{manifest.json,background.js,content_overlay.js,overlay_lifecycle.js}`, `tool/native_host_protocol.dart`, `tool/native_host.dart`, `test/tool/native_host_test.dart`

## Golden inventory (Constitution IV)

| Golden | Size | Theme |
|---|---|---|
| `vault_entry_passkey_section` | 390×844 | light, dark |
| `vault_entry_passkey_section_wide` | 1024×768 | light, dark |
| `vault_entry_passkey_unusable` | 390×844 | light |
| `vault_list_passkey_badge` | 390×844 | dark |
| `vault_passkey_delete_confirm` | 390×844 | light |
| `editor_custom_field_secret` | 390×844 | light, dark |
| `vault_entry_detail_secret_field` | 390×844 | light |

Widget assertions cover the omitted axes: badge semantic label, 44 dp rows,
focus ring on delete, that the section renders no character of the PEM.

## Test strategy

- **Pure**: `passkey_parser` (PEM → algorithm, base64url with/without padding,
  every missing-field case → unusable); assertion builders (`authenticatorData`
  bytes against a known vector, signature verifies with the public key) in
  Dart, and as Swift/Kotlin unit tests where those toolchains run.
- **Service, real temp `.kdbx`**: open the KeePassXC fixture → passkeys parsed,
  `customFields` contains no `KPEX_*`; edit title and save → passkey bytes and
  protection flags identical (SC-007); delete → fields gone, others intact,
  file reopens; history revision carries no PEM; CSV import with a `KPEX_*`
  column is rejected.
- **Redaction**: `props`/`toString` of `VaultPasskey`, `VaultEntry`, the
  revision, `MergeFieldDisplay` and the publish payload's `toString` contain
  no PEM — one shared assertion helper (SC-002).
- **Coordinator, fakes**: locked refuses; backup precedes delete; failed write
  keeps the backup and reports.
- **Native host**: `passkeyAssert` round-trip, `unsupported_type` from a v2
  host without the capability, payload cap, key never echoed.
- **Manual**: `quickstart.md` per platform; hardware rows in
  `device-evidence.md`.

## Risks

| Risk | Handling |
|---|---|
| Sign count 0 rejected by a strict RP | Documented WebAuthn-permitted behaviour; KeePassXC ships it. Conformance RPs (R10) are checked for it. |
| RP expects `UV` and the desktop confirmation is not biometric | Flag set only after the modal; copy says it is an app confirmation. Accept the residual weakness on desktop, stated in the section note. |
| A KeePassDX-written vault carries `_1` suffixed duplicates | Parser groups by suffix; each group is one `VaultPasskey`; unknown suffix layouts are unusable, never dropped. |
| MAIN-world wrapper conflicts with the browser's own passkey UI | Wrapper defers to the platform when the vault has no match (FR-014, US2 scenario 6) by calling the original function. |
| Android component enable state drifts across upgrades | Re-evaluated on every app start; idempotent. |
| Fixture vault with a real-looking key in the repo | Fixture key is generated for the fixture only and labelled as such; GitGuardian false positive expected, as with the existing fixtures. |
