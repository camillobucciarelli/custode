# 023 — Research

**Status**: Draft · **Created**: 2026-08-29
**Purpose**: resolve the technical unknowns behind `spec.md` so the spec can be
sharpened and `plan.md` written. Every claim about this repository is cited to a
file; every claim about an external format or platform is cited to its source.
Nothing here is a decision — decisions land in `spec.md` and `plan.md`.

## R1 — Storage format: the KeePassXC layout is the interoperability target

A passkey in a `.kdbx` is an ordinary entry carrying a set of custom string
fields named `KPEX_PASSKEY_*`. KeePassXC introduced them and KeePassDX adopted
the same nomenclature, verbatim: *"The custom fields used follow the KeePassXC
nomenclature with names beginning with `KPEX_PASSKEY_`"*
([KeePassDX wiki](https://github.com/Kunzisoft/KeePassDX/wiki/Passkeys)).

Field set in circulation:

| Field | Contents |
|-------|----------|
| `KPEX_PASSKEY_RELYING_PARTY` | RP id, e.g. `github.com` |
| `KPEX_PASSKEY_CREDENTIAL_ID` | credential id, base64url |
| `KPEX_PASSKEY_USER_HANDLE` | user handle, base64url |
| `KPEX_PASSKEY_USERNAME` | username captured at registration |
| `KPEX_PASSKEY_PRIVATE_KEY_PEM` | PKCS#8 private key, PEM — **the secret** |
| `KPEX_PASSKEY_GENERATED_USER_ID` | generated user id |
| `KPEX_PASSKEY_FLAG_BE` / `KPEX_PASSKEY_FLAG_BS` | backup eligibility / backup state, `1`/`0` |

Two properties matter for the plan:

- **The algorithm is not a separate field** — it is carried in the PKCS#8 OID.
  ES256 (P-256), EdDSA (Ed25519) and RS256 (RSA-2048) all appear in the wild, so
  a reader must not assume P-256 even if the writer only ever mints ES256.
- **KeePassDX adds fields of its own** (`AndroidApp`, `AndroidApp Signature`,
  and `_1` suffixed repeats) and KeePassXC has since added `KPEX_PASSKEY_PRF`.
  This is a live, growing namespace. It is the concrete justification for
  FR-003: preserve unrecognised `KPEX_PASSKEY_*` fields byte-for-byte instead of
  normalising the entry to a fixed field list.

**Open item for the spec**: the exact protection flag KeePassXC sets on
`KPEX_PASSKEY_PRIVATE_KEY_PEM`, the tag it applies to a passkey entry (if any),
and whether it writes the fields on a new entry or an existing one, must be
confirmed against a real KeePassXC-created vault before `plan.md` fixes the
reader/writer contract. Reading it off the source or a sample file is a task,
not a guess.

## R2 — The repository cannot store a protected custom field today

`VaultKdbxService` writes every custom field unprotected:

    entry.setString(KdbxKey(normalizedKey), PlainValue(field.value));

— `lib/features/password_manager/data/services/vault_kdbx_service.dart:1193`

Only the password field is protected (`ProtectedValue.fromString`, lines 236,
342, 452, 1012). `VaultCustomField`
(`lib/features/password_manager/domain/models/vault_custom_field.dart`) is a bare
`{key, value}` pair with no protection concept, though it already redacts its
value in `props`/`toString`.

So the smallest correct enabling change is: a protection flag on
`VaultCustomField`, honoured by the write path, and a read path that keeps
protected fields out of the ordinary custom-field list. `kdbx: ^2.5.0` needs no
change — `setString` accepts a `ProtectedValue` for any `KdbxKey`.

## R3 — Where secrets could leak, corrected against the code

`spec.md` FR-006 names "CSV export". **There is no CSV export in this app** —
`vault_csv_import_service.dart` is import-only, and the only export paths are
attachment export (`vault_bloc.dart:1451`) and whole-database backup export
(`database_selection_screen.dart:174`), the latter being the encrypted `.kdbx`
itself. FR-006 should be restated against the surfaces that actually exist:

| Surface | Risk | Where |
|---|---|---|
| Entry detail / editor custom-field list | renders and copies every custom field | `presentation/screens/vault/vault_entries_details.part.dart` and the editor |
| Merge preview / per-field conflict UI (spec 008) | lists changed field values | `domain/models/merge_field_display.dart`, `data/services/kdbx_merge_adapter.dart` |
| Password history (spec 017) | records field values over time | spec 017 surfaces |
| CSV **import** | could inject a `KPEX_PASSKEY_*` field set | `vault_csv_import_service.dart` |
| Desktop browser bridge | publishes entry metadata to the extension | `desktop_browser_autofill_cache.dart`, `..._reveal_bridge_service.dart` |
| Apple autofill metadata cache | `AutofillCredentialMetadata` is deliberately secret-free | `ios/CredentialProviderExtension/SharedAutofillStore.swift:63` |
| Duplicate detection | compares field sets | `vault_duplicate_service.dart` |

`RedactedValue` in `VaultEntry.props`/`toString` already covers the logging leg;
the display, copy, merge-preview and bridge legs do not exist yet for a
protected field, because no protected custom field exists yet (R2).

## R4 — Apple platforms: the ground is already prepared

Verified in this repository:

- **Deployment targets clear the bar.** iOS 18.0
  (`ios/Runner.xcodeproj/project.pbxproj`) and macOS 14.0
  (`macos/Runner.xcodeproj/project.pbxproj`). Passkey support in a credential
  provider needs iOS 17 / macOS 14, so no minimum-version bump is required and
  no availability fallback path is needed.
- **The extension already receives passkey requests.** Both controllers
  implement the iOS 17 overload
  `prepareCredentialList(for:requestParameters: ASPasskeyCredentialRequestParameters)`
  (`ios/CredentialProviderExtension/CredentialProviderViewController.swift:38`,
  `macos/.../MacCredentialProviderViewController.swift:37`) — today they route it
  to the password list.
- **The extension declares only passwords.**
  `ASCredentialProviderExtensionCapabilities` contains `ProvidesPasswords` alone
  (`ios/CredentialProviderExtension/Info.plist`); a passkey slice adds the
  passkey capability key and the registration entry point.
- **Entitlements need nothing new.**
  `com.apple.developer.authentication-services.autofill-credential-provider`,
  the App Group `group.dev.camillobucciarelli.kdbxKeyVault` and the shared
  keychain group are already granted
  (`ios/CredentialProviderExtension/CredentialProviderExtension.entitlements`).
- **Non-password requests are currently rejected on purpose.** The generic
  `provideCredentialWithoutUserInteraction(for: any ASCredentialRequest)` fails
  anything that is not an `ASPasswordCredentialRequest`, and the password path
  itself returns `.userInteractionRequired` with the stated reason that the
  extension *"has no reliable recent vault/user-presence context in this
  callback"*. That refusal is a deliberate milestone decision, not an oversight —
  it is exactly the ground on which FR-015 must be decided.

**Consequence for the plan**: the signature must be produced inside the
extension process, in Swift/CryptoKit. The Flutter app is not running when the
system asks, so no Dart signing path can serve an Apple request. Dart-side
crypto is only needed for key generation if registration is routed through the
app, and for any non-Apple slice.

## R5 — The encrypted shared cache already holds secrets of this class

`SharedAutofillStore` keeps two artefacts in the App Group container:

- `AutofillCredentialMetadata` — routing/display only, *"intentionally excludes
  passwords"* (`SharedAutofillStore.swift:63`).
- `autofill_cache_v2.sealed.json` — `AES.GCM.256` sealed
  (`SharedAutofillStore.swift:538,546,720`), holding `AutofillCredentialSecret`.
  The symmetric key lives in the shared keychain as a generic password with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (`:1046`), i.e. readable only on
  this device while it is unlocked, and never in a backup.

This is decisive for FR-022: **passwords already live outside a vault session in
exactly this envelope**. A passkey private key is the same class of secret under
the same protection, so option A of the FR-022 question is not a new concession —
it is the pattern the app already ships. What *is* new is that a passkey secret
is long-lived and non-rotatable by the user in the way a password is, which is an
argument for a shorter cache lifetime, not for a different mechanism.

## R6 — Recommendations on the three open questions

**All accepted in the 2026-08-29 clarification session**; the decisions now live
in `spec.md` (FR-015, FR-022, FR-023, Deferred scope, Assumptions). Kept here for
the reasoning behind them.

**FR-015 (user presence per assertion)** — recommend **A: biometrics or device
passcode on every assertion**. The WebAuthn user-presence/user-verification
contract is per-assertion, the extension already refuses to act without an
explicit interactive selection, and reusing the password path's recent-unlock
window would weaken a guarantee relying parties are entitled to assume. The cost
is one confirmation the user already expects from every other passkey provider.

**FR-022 (key availability when the app is not running)** — recommend **A, the
sealed cache**, on the evidence in R5, with two conditions worth writing into the
spec: passkey secrets sit in the same sealed envelope as passwords and never in
the plaintext metadata cache; and the entry's presence in the cache is revocable
from the app (locking or removing the database wipes it), so the user has a way
back to "not on this device".

**Android in or out (deferred scope)** — original recommendation, kept for
record: **out**. *Superseded on
2026-09-09: the beta ships sign-in on every target, so Android (Credential
Manager, API 34+) and the desktop browser bridge (R7) are now in scope for
slice 2; the constraints below still hold and become plan inputs.* A provider must
implement `CredentialProviderService` from the Jetpack Credential Manager, a
different integration from the `AutofillService` completed in spec 016, which
excluded passkeys explicitly (`specs/016-android-autofill-completion/spec.md:291`).
It also has a floor problem this repo must handle: `minSdk = 29`
(`android/app/build.gradle.kts:36`) while a Credential Manager *provider* needs
API 34, so the feature is unavailable on a large part of the supported range and
needs its own graceful-absence story. That is a spec, not a user story.

## R7 — Notes for the deferred specs

- **Android**: KeePassDX ships as a Credential Manager passkey provider using
  this same field layout, so the format work in 023 is directly reusable and the
  Android spec is integration-only.
- **Desktop browsers**: serving a passkey to a page means intercepting
  `navigator.credentials.create/get` from a content script in the page's own
  world and proxying to the native host. The extension currently holds only
  `activeTab`, `nativeMessaging`, `scripting`, `storage` and *optional* host
  permissions (`desktop/browser_extension/manifest.json`), so this is a
  permissions change users must re-approve, on top of the per-site compatibility
  risk of replacing a browser API.

## R8 — Open items before `plan.md`

1. ~~Confirm the KeePassXC field contract: protection flag, entry tag,
   base64url variant (R1).~~ Done 2026-09-09 from source — see R9. The
   real-vault fixture is a task in `tasks.md`.
2. ~~Decide the three clarification questions (R6).~~ Done 2026-08-29.
3. ~~Choose the conformance relying parties (three independent sites).~~ Done
   2026-09-09 — R10: webauthn.io, passkeys.io, webauthn.me.
4. ~~Decide where registration key generation happens.~~ Done 2026-08-29: in the
   extension, in CryptoKit — no Dart ECDSA/CBOR dependency in this spec.
5. Name the manual QA harness for the Apple flows, following the precedent of
   the spec 008 and spec 011 harnesses, since neither slice can run in
   `flutter test`.
6. ~~(Added 2026-09-09) Android and desktop surfaces.~~ Resolved in R11 and
   R12 the same day; kept for the record: Android: confirm the Credential Manager provider API
   surface (`CredentialProviderService`, API 34 floor) and how the sealed
   secret cache of spec 016 can hold the private key. Desktop: confirm the
   extension permission change needed to intercept `navigator.credentials.get`
   in the page world on Chrome and Firefox, and the native host message shape
   (metadata in, signed assertion out — never the key). Windows system-level
   third-party passkey providers are out of scope; do not research them here.

## R9 — KeePassXC field contract, verified against source (2026-09-09)

Read from `src/browser/BrowserService.cpp` and `BrowserPasskeys.cpp` on the
`develop` branch:

- `addPasskeyToEntry` writes `KPEX_PASSKEY_USERNAME`, `_RELYING_PARTY`,
  `_FLAG_BE = "1"`, `_FLAG_BS = "1"` **unprotected**, and
  `_CREDENTIAL_ID`, `_PRIVATE_KEY_PEM`, `_USER_HANDLE` **protected**
  (`set(key, value, true)`).
- The entry gets `addTag(tr("Passkey"))` — a *translated* tag. Detection must
  not depend on it (plan D1).
- Credential id is base64url without padding
  (`QByteArray::Base64UrlEncoding | OmitTrailingEquals` on decode). User handle
  is passed through as received from the RP, which is base64url in WebAuthn
  JSON; the parser accepts both padded and unpadded input.
- Supported algorithms: COSE -7 ES256 (secp256r1), -8 EdDSA (Ed25519),
  -257 RS256. Sign count is not persisted (always 0).

**Decision**: parse the three required fields, treat the rest as optional,
preserve everything, and accept both base64url variants.
**Alternatives**: Custode-specific layout — rejected (interop is the point).
**Still to confirm on a real file** (fixture task): that `kdbx` 2.5.0 reads the
`Protected="True"` attribute of these strings as `ProtectedValue` (expected —
it does for `Password`).

## R10 — Signing per platform, no new dependency

| Platform | Signer | ES256 | EdDSA | RS256 |
|---|---|---|---|---|
| iOS/macOS | CryptoKit `P256.Signing.PrivateKey(pemRepresentation:)`, `Curve25519.Signing.PrivateKey` (raw seed from PKCS#8), `SecKeyCreateWithData` + `SecKeyCreateSignature` | yes | yes | yes |
| Android | JCA `KeyFactory("EC"/"Ed25519"/"RSA")` + `Signature("SHA256withECDSA"/"Ed25519"/"SHA256withRSA")` — Ed25519 in JCA from API 33 | yes | yes (API 33+) | yes |
| Desktop (Dart, in app) | `pointycastle` 4.0.0 (already direct): `ECDSASigner` secp256r1, `RSASigner` SHA-256 | yes | **no** — pointycastle exports no Ed25519 | yes |

**Decision**: EdDSA passkeys are `unusableReason: unsupportedOnPlatform` on
Windows/Linux. Adding a Dart Ed25519 dependency is out of this spec's stated
no-new-crypto constraint; revisit only if a KeePassXC user reports EdDSA
passkeys in practice (KeePassXC defaults to ES256).
**Alternatives**: `cryptography` package (adds a dependency, has Ed25519) —
rejected for now on the constraint above.

Conformance relying parties for SC-004 (slice 3, not planned yet) and for
slice 2 sign-in checks: `webauthn.io`, `passkeys.io` (Hanko demo),
`webauthn.me` (Auth0 debugger). All three accept sign count 0 and no
attestation. A KeePassXC-created passkey on each is the slice 2 test input.

## R11 — Android provider surface

`androidx.credentials` `CredentialProviderService` (API 34 platform class
`android.service.credentials.CredentialProviderService`) with
`onBeginGetCredentialRequest` → `BeginGetCredentialResponse` of
`PublicKeyCredentialEntry` items, each backed by a `PendingIntent`; the
activity completes with `PendingIntentHandler.setGetCredentialResponse`
carrying a `PublicKeyCredential(authenticationResponseJson)`. The JSON is the
WebAuthn `PublicKeyCredential` JSON serialization (id, rawId, response
{clientDataJSON, authenticatorData, signature, userHandle}, type). The
`clientDataJSON` is built by the provider from `clientDataHash` semantics:
Android supplies `PublicKeyCredentialRequestOptions` plus `callingAppInfo`;
the provider constructs client data with origin from the calling app (web
origin when `callingAppInfo.origin` is present, else `android:apk-key-hash:`).
This is the same shape KeePassDX implements. The exact library version is
pinned in the task that adds it, after checking the current stable on Maven.

## R12 — Desktop interception surface

`overlay_lifecycle.js` already registers content scripts with
`scripting.registerContentScripts` in the `ISOLATED` world, on the optional
host permissions the user granted. A `MAIN`-world script (MV3 supports `world:
"MAIN"` in `registerContentScripts` on Chrome 111+ and Firefox 128+) can wrap
`navigator.credentials.get` and post the `publicKey` options to the isolated
script via `window.postMessage` with a per-page nonce. The response must be a
`PublicKeyCredential`-compatible object: `id`, `rawId` (ArrayBuffer),
`type: "public-key"`, `response` `{clientDataJSON, authenticatorData,
signature, userHandle}` as ArrayBuffers, `getClientExtensionResults()`,
`authenticatorAttachment: "cross-platform"`, and — since sites increasingly
call it — `toJSON()`. The wrapper calls the original function when the vault
has no matching credential, so the browser's own UI still appears.

`clientDataJSON` on desktop is built by the app: `{type: "webauthn.get",
challenge, origin, crossOrigin: false}` with `origin` taken from the tab URL
the native host reports, and `rpId` checked to be the origin's effective
domain or a registrable suffix of it.

## Sources

- [KeePassDX — Passkeys wiki](https://github.com/Kunzisoft/KeePassDX/wiki/Passkeys)
- [KeePassXC PR #8825 — Add basic support for WebAuthn (Passkeys)](https://github.com/keepassxreboot/keepassxc/pull/8825)
- [KeePassXC PR #10874 — Passkeys: fix incorrect username fill](https://github.com/keepassxreboot/keepassxc/pull/10874)
