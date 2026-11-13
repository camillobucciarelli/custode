# Custode Chrome/Edge extension (Native Messaging v2)

MV3 extension for Chrome and Chromium-based Edge. Current scope: safe metadata
search, pending-association requests, explicit popup-triggered fill for exact
strong matches, and an in-page overlay the user turns on with a single switch.
The extension and native host do **not** read `.kdbx`, request the master
password, cache plaintext passwords, or fill pages silently.

Firefox is not supported: this is an MV3 service-worker extension and a
separate Firefox implementation would be required before advertising support.

## Permissions and store justification

Declared in `manifest.json`, intentionally minimal:

| Permission | Why |
|---|---|
| `nativeMessaging` | Talk to the locally registered Custode native host. All credential flow goes through it; the extension holds no vault data. |
| `activeTab` | Let the popup read the current tab's origin and title after an explicit toolbar click. No `tabs` permission, no background tab access. |
| `scripting` | Register the overlay content script while the overlay is on, and inject the one-shot fill function only after an explicit user action. |
| `storage` | Persist the overlay's on/off switch and the toolbar badge state (host reachable / app unlocked / per-tab match *count*). Never credential data. Survives MV3 worker termination. |
| `optional_host_permissions` (`http://*/*`, `https://*/*`) | Requested **once**, under a user gesture, when the user turns the overlay on. Nothing is granted at install time, and this is the only host access the extension can ever hold. |

Not present, by design: `host_permissions`, static `content_scripts`,
`tabs`, `webNavigation`, `clipboardRead`, `clipboardWrite`, `<all_urls>`.
The test suite asserts their absence.

### Store justification for the broad host permission

This is the permission reviewers and users should scrutinise, so it is worth
being exact about what it does and does not buy.

**Why it is needed.** The overlay is a content script: to place a suggestion
box next to a login field it has to be injected into the page. Chromium offers
no "ask the user the first time they visit each site" injection mode, and a
site-by-site prompt was tried and abandoned — it required the user to find the
toolbar popup and click *Turn on* before the overlay would ever appear on a
given site, which in practice meant it never appeared. One informed grant
replaces an unusable stream of prompts.

**What it does not mean.**

- The extension does **not** read, collect, transmit or analyse page content.
  The content script attaches to login-shaped fields, renders a closed-shadow
  overlay, and talks to nothing but this extension's own service worker.
- Holding the permission is **not** the same as the feature being on. The
  durable opt-in is a separate stored value and is the authorization source of
  truth; a granted permission with the switch off does nothing at all.
- Broad **injection** did not widen **disclosure**. The overlay lists only
  entries already in the user's vault whose stored site matches the frame's
  exact origin — scheme, host and port — and the app reveals a password only
  after an explicit click on such a match.
- No page data, browsing history or origin list is persisted. The stored config
  is `{version, revision, enabled}`; it does not know which sites exist.

**Turning it off** revokes the host permission, unregisters the content script
and tears down every live overlay. See below.

## Passkey sign-in (spec 023)

On granted sites the extension can answer a site's passkey sign-in request
with a passkey stored in the open Custode database. It rides the same single
switch as the overlay: turning the overlay off unregisters the passkey scripts
too.

**What changes on this update.** Two more scripts are registered on the same
`http://*/*`, `https://*/*` patterns you already granted. One of them,
`passkey_page.js`, runs in the **page's own world** — the only world where
`navigator.credentials.get` can be wrapped so the site sees it. No new
permission is requested.

**What the page world does and does not get.**

- The private key never leaves the Custode app. The extension and the native
  host carry a challenge one way and a signature the other; neither ever holds
  a key. The page world holds neither.
- The page cannot ask for another site's passkey. The origin the app checks
  comes from the browser's own `sender.url`, not from the page's claim, so a
  page that forges a message to the extension gains nothing it could not get
  by calling `navigator.credentials.get` honestly.
- **The app asks you before every signature**, naming the site, the record and
  the account. There is no session, no remembered approval and no silent path.
- A refusal tells the page nothing. Whether the vault is locked, holds no
  passkey for that site, or you declined, the answer is the same: the page
  falls through to the browser's own authenticator, so a security key or a
  platform passkey keeps working exactly as before.

**Known limit.** The resolved credential is a plain object with the WebAuthn
fields on it, not a real `PublicKeyCredential` — that constructor is not
reachable from a content script. Sites that read the fields work; a site that
checks `instanceof PublicKeyCredential` falls back to the browser.

**Creating a passkey** works the same way, with two extra rules. Custode
creates ES256 credentials only, so a site that will not accept ES256 goes
straight to the browser and you never see a prompt for a registration Custode
could not have served. And a new passkey is always attached to a record that
already exists with that site as its website: the app will not invent a record
while the site is waiting, so if there is no matching record it says so and the
browser handles the registration instead.

## One global switch, and revoke

- The overlay is **off by default**. The user turns it on from the popup, which
  requests both optional host patterns in the same user gesture.
- Turning it off commits the durable `enabled: false` first, then tears down:
  live documents are told to remove themselves, the content script is
  unregistered, and the host permission is handed back. The commit precedes
  every side effect, so a browser crash mid-teardown can never leave the
  feature authorized.
- The *off* switch is reachable from any page, including `chrome://` pages —
  a permission the user cannot withdraw from where they are standing is one
  they effectively cannot withdraw.
- Revoking the permission from `chrome://extensions` (outside the popup) is
  also honored: the worker reconciles on cold start, popup open, permission
  removal and disable, and durably disables the overlay. Losing *either* of
  the two patterns counts as a revocation.

### Upgrading from the per-origin build

Earlier builds stored a list of individually enabled origins under
`overlayConfigV1`. That value is not readable by this build and is never
interpreted: the overlay comes up **off** after the upgrade regardless of how
many origins were enabled before, because consent to three named sites is not
consent to all sites. The upgrade also revokes every leftover per-origin host
permission and unregisters every per-origin content script, so no orphan grant
survives it. The user is asked once, explicitly, or the feature stays off.

### Port granularity

Chromium host-permission patterns have no port component, and the granted
patterns now cover every host anyway. **Authorization does not widen with
them**: each frame is bound to its own canonical origin *including the port*,
the native query is made with that exact origin, and a frame claiming a
different one is refused. `https://example.com` and `https://example.com:8443`
remain two different sites to the vault.

## Dynamic injection and teardown

No static content scripts. `content_overlay.js` is registered via
`scripting.registerContentScripts` as a **single** isolated-world registration
over `http://*/*` and `https://*/*` (`document_idle`, `allFrames: true`) while
the switch is on, and unregistered on disable/revoke. The in-page overlay is
a closed-shadow host that renders **metadata only** (title + display service),
and tears down on Escape, focus loss, navigation, page hide, visibility
change, timeout, disable, permission removal, and stale config revision —
removing the host, aborting listeners/observers/timers, and restoring ARIA.

## Frame and restricted-page limits

- Supported: the top frame and same-origin child frames.
- Cross-origin child frames are supported and are bound to the **child's** own
  origin, never the top document's — an authorized top page cannot make the
  app answer on behalf of an embedded third-party frame.
- A child frame whose **top document** has no canonicalizable origin (an
  http(s) iframe inside a `file://`, `view-source:`, `data:` or PDF-viewer tab)
  is classified unsupported and never queries or fills. The broad grant makes
  this case more common, not less: such frames used to go uninjected.
- Restricted pages (`chrome://`, the Web Store, other extensions' pages,
  `file://` without explicit permission) cannot be injected. Where a limit is
  detectable the overlay shows an unsupported state directing the user to copy
  manually from the Custode app. The extension has **no clipboard path**.

## Worker cold-start recovery

MV3 terminates the service worker at will. All durable state (the overlay
switch, badge state) lives in `chrome.storage`; on cold start the worker
reconciles registered content scripts and granted permissions against committed
config, sweeps orphans, and rebuilds the badge. A worker restart costs a re-read and
redraw, never a lost authorization and never a widened one.

## Native host capability (exact origin)

The native messaging host manifest lists exactly **one**
`chrome-extension://<id>/` entry in `allowed_origins`. The v2 protocol
(metadata search, pending association, explicit reveal-for-fill) requires no
broader registration. Reinstall/re-register the host only when the host binary
path or the extension ID changes; a Chrome restart picks up manifest changes.

## Secret policy

- Overlay and popup DOM, attributes, datasets, logs, globals, and storage are
  metadata-only. No username or password appears anywhere in them.
- Plaintext is revealed only on an explicit fill action: the native host
  re-validates the strong match and asks the running unlocked app over a
  loopback token bridge; the injected function writes the values into the page
  inputs, dispatches `input`/`change`, never submits, then drops every
  reference.
- Never via clipboard. Never persisted. Never logged.
- Do not put vault passwords, key file paths, database paths, or other secrets
  in extension files, console output, DOM nodes, or browser storage.

## Password generation (Slice B)

The overlay's **Generate** row is active only when the running Custode app
advertises the `generatePendingEntryV1` capability through the native host
(`hello`). With an older host or app the row stays disabled and reads "Open
Custode to generate a password." — it directs the user to the app and never
promises in-page generation; there is **no fallback** generation in the
extension or native host, and no default settings.

How a generation actually works, and who owns what:

- **The app generates and the app saves.** An explicit click (or Enter on the
  arrow-selected row) asks the running unlocked app — via the native host —
  to generate a password with the app's own committed generator settings. The
  extension cannot send, override, or even express settings: the request
  schema has no field for them.
- The app creates an **app-owned pending entry** for the exact origin. The
  user completes the save **inside the Custode app** through the normal
  new-entry confirmation; the page and the extension cannot auto-save
  anything into the vault.
- The pending entry **expires after at most 5 minutes** (or on lock, vault
  switch, vault close, or app exit). If it expires, generate again.
- The extension fills the generated password into the focused password field
  **once**, never submits the form, then tears the overlay down. It does
  **not save and does not remember** the generated password, and it never
  receives or stores the pending-entry id. A worker/page reload cannot replay
  a generation: the one-shot token is consumed before the native request is
  issued.

## Production setup

1. Install Custode from Chrome Web Store. Published extension ID:
   `ogjmlkogmogijgpflnjifiobdmnmommh`.
2. Open **Desktop browser extension** in the Custode app.
3. On Windows/Linux, click **Configure Chrome**. On macOS, download and run
   the signed **Custode Chrome Support** package offered by the app.
4. Restart the browser, unlock the vault, then open the extension popup.

Users never need to copy the ID, enable Developer mode, install Dart, or run
terminal commands.

### macOS signing/TCC notes

- The host is a Dart AOT binary. The Apple hardened runtime blocks Dart AOT's
  snapshot mapping, so signing with `--options runtime` requires the
  `com.apple.security.cs.allow-unsigned-executable-memory` entitlement — a
  hardened-runtime-signed host without it dies on launch (SIGKILL) and the
  extension only sees "host unavailable". The packaging script
  (`tool/package_native_host_macos.sh`) keeps the hardened runtime (required
  for notarization) and signs with `tool/native_host_macos.entitlements`.
- On macOS Sequoia, group containers are covered by "App Data protection": a
  process reading one without being a member of the group triggers the
  "would like to access data from other apps" TCC prompt — and because the
  host is ephemeral (spawned per browser request, <1s lifetime) the grant
  does not attribute reliably, so the prompt reappears on every spawn
  (observed with the legacy group). Signature *membership* suppresses the
  prompt entirely, but Sequoia only honors it for group IDs prefixed with
  the signing Team ID (observed: per-spawn prompts on the non-prefixed
  `group.dev.camillobucciarelli.kdbxKeyVault`, zero prompts on the
  Team-prefixed group across repeated third-party-parented spawns of a
  Developer-ID-signed probe). The browser store therefore lives in a
  dedicated Team-ID-prefixed group container,
  `A8QUU5F9G3.dev.camillobucciarelli.kdbxKeyVault.browser`. Two groups by
  design: the legacy group stays with the app and the Apple autofill
  CredentialProviderExtension; the host declares only the browser group
  (least privilege — it cannot read the credential provider's container).
  On first bridge start the app deletes the old `browser_v2` store from the
  legacy container so no stale bearer token is left behind. The production
  package already signs with `tool/native_host_macos.entitlements`; a
  locally built host (`tool/build_native_host.sh`) is unsigned and must be
  re-signed for the promptless path to work in development:

  ```bash
  codesign --force --options runtime \
    --entitlements tool/native_host_macos.entitlements \
    --sign "Developer ID Application: <name> (<TEAM_ID>)" \
    desktop/native_host/keyvault_native_host
  ```

  Security analysis (why this does not weaken anything): pre-Sequoia the
  Group Container never protected this store from other non-sandboxed
  processes of the same user, so membership restores the pre-Sequoia status
  quo rather than widening access. The store directory and files are written
  `0700`/`0600` (same-user POSIX protection, equivalent to any user-level
  secret store). The bearer token in `bridge.json` is not sufficient to
  reveal secrets on its own: a caller also needs loopback access to the
  bridge port, the descriptor's triple binding
  (`databaseId`/`cacheGeneration`/`bridgeGeneration`) to match the live
  cache, the vault to be unlocked in the app, and a page origin the reveal
  policy authorizes. The `.kdbx` vault itself is never in this store.

## Development install

1. Open `chrome://extensions` or `edge://extensions`, enable **Developer
   mode**, click **Load unpacked**, select `desktop/browser_extension`.
2. Copy the extension ID and register the native host as described in
   `../../docs/desktop_browser_autofill.md`.

Host registration helpers from the repository root:

```powershell
.\desktop\native_host\install_host_windows.ps1 -Browser Chrome -ExtensionId <EXTENSION_ID>
```

```bash
./desktop/native_host/install_host_linux.sh <EXTENSION_ID>   # --browser chromium for Chromium
./desktop/native_host/install_host_macos.sh <EXTENSION_ID>   # pass `edge` for Microsoft Edge
```

Expected Native Messaging host name:

```text
dev.camillobucciarelli.keyvault_native_host
```

## Automated and manual checks

Automated (CI runs the first two on every PR):

```bash
node --test desktop/browser_extension/test/*.test.js   # Gate A0 harness
node --check desktop/browser_extension/<each runtime .js>
node tool/mutation_runner.mjs --check                  # mutation gate
python3 -m json.tool desktop/browser_extension/manifest.json
./desktop/browser_extension/package_extension.sh
```

Manual: keyboard-only navigation, screen reader smoke (NVDA/VoiceOver), and
the Chrome/Edge install/grant/revoke matrix (spec 009 A046).

### Visual baselines

Pixel acceptance for the overlay runs in ONE canonical environment: a Linux
x86_64 OCI image pinned by immutable digest plus an exact Chrome for Testing
build (version, archive SHA-256, and binary SHA-256), all locked in
`test/visual_environment_v1.json` together with timezone, locale, the
installed font-set hash, and the full rendering flag list. Any mismatch —
image contents, Chrome hash, fonts, timezone — fails loudly before capture;
there is no skip path and no mutable-tag fallback.

```bash
# Recapture into test/screenshots/actual/ and compare decoded pixels + the
# approved sha256 per baseline against test/screenshots/expected/. Never
# rewrites expected/. Exit 0 = all 18 baselines match.
./desktop/browser_extension/test/run_visual_baselines.sh --verify

# Regenerate expected/ + visual_baselines_v1.sha256. ONLY after human design
# review; commit both together or the inventory test and --verify reject the
# unapproved edit.
./desktop/browser_extension/test/run_visual_baselines.sh --approve
```

Requires `podman`. On Apple Silicon the amd64 image must run under a
Rosetta-enabled podman machine (qemu TCG cannot run Chrome — the run then
fails on CDP timeouts, never silently):

```bash
printf '[machine]\nprovider = "applehv"\nrosetta = true\n' > /tmp/kv-machine.conf
CONTAINERS_CONF_OVERRIDE=/tmp/kv-machine.conf podman machine init kv-visual-amd64
CONTAINERS_CONF_OVERRIDE=/tmp/kv-machine.conf podman machine start kv-visual-amd64
KEYVAULT_VISUAL_PODMAN_CONNECTION=kv-visual-amd64 \
  ./desktop/browser_extension/test/run_visual_baselines.sh --verify
```

Every run captures the 18 scenarios TWICE with fresh browser profiles and
requires the two passes to be byte-identical (determinism proof re-established
on every run). The capture drives the UNMODIFIED production
`overlay_security.js` + `content_overlay.js` loaded as an unpacked extension in
Chrome for Testing; scenario states come from a test-only background stub under
`test/visual/harness/` that is never packaged. The supplemental inventory test
(`test/visual_inventory.test.js`, runs in the normal Gate A0 suite) asserts the
exact 18 basenames and that every committed expected PNG still matches its
approved hash. Windows/macOS/Edge remain DOM/geometry/manual-smoke
environments, never pixel authorities.

## Package contents

`./desktop/browser_extension/package_extension.sh` builds
`dist/keyvault-browser-extension.zip` from an explicit allowlist:
`manifest.json`, `background.js`, `overlay_security.js`,
`overlay_lifecycle.js`, `overlay_routes.js`, `content_overlay.js`,
`popup.html`, `popup.js`, `popup.css`, `tokens.css`, this README, the four
declared icons, and the AGPL license files. Nothing under `test/` (including
the `session_helpers.js` harness), no fixtures, screenshots, source maps,
visual manifests, or environment files. The test suite asserts both the
presence of every runtime file and the absence of the excluded ones; any task
that adds a runtime file updates the allowlist in the same commit.
