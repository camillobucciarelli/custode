# 009 — In-page autofill overlay

**Status**: Implemented on `main` · **manual accessibility and browser-matrix
verification outstanding**, see [`tasks.md`](tasks.md) A040/A046 and the shared
ledger [`docs/manual-qa.md`](../../docs/manual-qa.md)  
**Kind**: New feature · **Depends on**: 006

Technical baseline: desktop browser autofill protocol v2 in
`tool/native_host_protocol.dart`. This baseline does not replace dependency 006.

## Goal

Reduce popup round-trips without turning Custode into an always-on page agent.
Delivery is split because current code supports metadata queries and explicit
credential reveal, but does not support app-owned password generation or a
pending new-entry secret.

## Current baseline

- `desktop/browser_extension/manifest.json` is MV3 and currently grants
  `activeTab`, `nativeMessaging`, `scripting`, and `storage` — `storage` has
  been granted since spec 006, so A015 does not need to add it. It has no host
  permissions, no optional host permissions, and no content scripts.
- `desktop/browser_extension/background.js` accepts extension-page senders only
  (`sender.id === chrome.runtime.id && !sender.tab`) and forwards protocol v2
  requests with a 3-second timeout.
- `desktop/browser_extension/popup.js` performs one-shot explicit fill through
  `queryCredentials` and `revealForFill`.
- `tool/native_host_protocol.dart` supports `hello`, `status`,
  `queryCredentials`, `searchCredentials`, `createPendingAssociation`, and
  `revealForFill`. It does not support password generation.
- `lib/features/password_manager/data/services/desktop_browser_autofill_reveal_bridge_service.dart`
  exposes only `/status` and `/reveal` while the vault is unlocked.
- `lib/features/password_manager/domain/services/password_generator_service.dart`
  can generate a password, but
  `vault_dialog_password.part.dart` keeps generator options local to one dialog
  and resets them to defaults each time. No app-wide “current settings” contract
  exists.
- `DesktopBrowserAutofillPendingAssociation` in
  `desktop_browser_autofill_cache.dart` links an existing `entryId` to a site. It
  cannot own a generated password or represent a pending new entry.

These facts are requirements, not implementation assumptions to hide.

## Staged scope

### Slice A — opt-in metadata overlay and explicit fill

Slice A may ship independently.

1. User opens popup and enables **Show the overlay on this site**.
2. Extension requests optional permission for that HTTP(S) site and stores only
   exact normalized enabled origins.
3. Dynamically registered/injected isolated-world code observes eligible focused
   fields only on documents where browser permission and injection both exist.
4. Overlay requests metadata for sender document's exact origin. Match responses
   contain no password and, for minimum disclosure, no username. Rows show title
   and display service.
5. User explicitly chooses one exact-origin match. Only then may username and
   password cross native bridge and content-script boundary for immediate fill.
6. Extension never submits form and never silently fills.

Slice A extends/hardens existing v2 query/reveal path. It must not treat host-only
metadata as authorization for an origin-bound fill. Existing `domain` identifiers
may remain useful for possible-match UI, but fill requires an exact normalized
`url` origin match at native host and app reveal bridge.

### Slice B — generate new password

Slice B is blocked until app and protocol contracts below exist and pass tests.
Current protocol/settings do **not** support it.

Required contracts:

- app-owned global non-secret generator settings persisted through a versioned
  app repository backed by existing `SharedPreferences` infrastructure;
- app-side generated-secret operation available only while vault is unlocked;
- app-owned pending new-entry record, distinct from existing pending association;
- expiry, consume/reject, app-lock/database-change/app-exit cleanup;
- native protocol and loopback bridge request/response schemas for generation;
- no generated secret persisted by extension or native-host cache.

Until every contract exists, Slice A omits or disables Generate with text such as
“Open Custode to generate a password.” It must not silently use
`PasswordGeneratorOptions.defaults()` and must not claim user settings are shared.
Slice B work starts only after Slice A is complete and B0 settings/pending contracts
pass. Extension never stores generator settings.

## Required manifest changes

Slice A explicitly permits these additions to
`desktop/browser_extension/manifest.json`:

```json
{
  "permissions": ["activeTab", "nativeMessaging", "scripting", "storage"],
  "optional_host_permissions": ["http://*/*", "https://*/*"]
}
```

Constraints:

- no static `content_scripts` entry;
- no always-on `host_permissions`;
- no `<all_urls>` grant;
- request one site pattern only after popup user action;
- persist an exact-origin opt-in separately because Chromium match patterns do
  not isolate ports;
- do not add `tabs`, `webNavigation`, clipboard, or remote-code permissions for
  this feature.

`optional_host_permissions` declares what may be requested; it grants nothing at
install time. Default install behavior remains popup-only.

## Security requirements

### SR-1 — separate sender trust paths

Background must dispatch through two separate validators.

**Extension-page messages** (popup or another packaged extension page):

- `sender.id` equals `chrome.runtime.id`;
- `sender.tab` is absent;
- `sender.url` has exact `chrome-extension://<runtime-id>/` origin;
- message type is in extension-page allowlist and object shape is exact.

**Content-script messages**:

- `sender.id` equals `chrome.runtime.id`;
- `sender.tab.id`, integer `sender.frameId`, and `sender.url` are present;
- sender document URL is HTTP(S);
- body origin equals normalized `sender.url` origin exactly;
- stored exact origin is enabled and corresponding optional permission still
  exists;
- message type is in content-script allowlist and object shape is exact.

Never pass a content-script message through current extension-page validator.
Never trust body origin, `sender.tab.url`, title, or host alone as frame origin.
`sender.tab.url` supplies top-level context; `sender.url` supplies sender frame
context. Reject missing/opaque/mismatched values.

### SR-2 — exact normalized origin

Origin equality compares `(scheme, ASCII host, effective port)`:

- only `http` and `https`;
- lowercase scheme and URL-parser-normalized host;
- `http` default port 80 and `https` default port 443;
- explicit non-default ports remain distinct;
- no credentials, path, query, or fragment.

Examples that must differ: `http://example.com` vs `https://example.com`,
`https://example.com` vs `https://example.com:8443`, and `example.com` vs
`example.com.evil.test`.

For origin-bound query/fill, native host and app bridge must use same exact-origin
rule. Remove host-only fallback from this authorization path. A domain-only entry
may be displayed as possible metadata; it cannot reveal a credential.

Do not reuse current host-match canonicalization blindly:
`DesktopBrowserAutofillMetadataMapper.normalizedHost/normalizedOrigin` routes
through `_cleanHost`, which removes `www.`, `m.`, or `mobile.` prefixes. That is
useful only for possible host matching and is invalid for exact-origin security.
Add one shared semantic exact-origin helper that preserves every hostname label
and normalizes default ports consistently with browser URL parsing.

### SR-3 — focus-session nonce and fill capability

Each eligible `focusin` creates a cryptographically random focus nonce. Successful
metadata response returns a cryptographically random, short-lived fill token
bound in worker memory to:

- tab id, frame id, and `sender.documentId` when available;
- exact sender origin;
- focus nonce;
- currently fillable entry ids;
- database id, cache generation, and reveal-bridge generation returned by current
  metadata query;
- permission revision;
- expiry (maximum 30 seconds).

Fill requires matching nonce + token + entry id from same sender context. New
focus, blur, Escape, navigation, `pagehide`, tab hide, disable, permission change,
timeout, or teardown invalidates session. Content script ignores every response
whose nonce is no longer current.

MV3 worker restart loses in-memory tokens by design. Next fill returns
`stale_session`; content script requests fresh metadata. Tokens are never stored.

### SR-4 — vault/cache/bridge generation binding

Every metadata response used to mint a fill grant carries this non-secret session
binding:

```text
(databaseId, cacheGeneration, bridgeGeneration)
```

`cacheGeneration` is a new opaque random generation created on every metadata
cache publish/republish. `bridgeGeneration` is a new opaque random generation
created on every reveal-bridge start/restart. Neither is a secret. Both are stored
with their owning cache/descriptor and echoed through validated protocol data;
extension never persists them.

Fill grant, content fill request, native `revealForFill` request, app bridge
`/reveal` request, and every success response bind/echo all three values. Native
host validates expected database/cache/bridge values against current cache and
descriptor before contacting app. App bridge validates them against current
unlocked runtime under one session epoch before credential lookup and again before
response. Native host re-reads cache/descriptor after bridge response before
returning. Metadata query likewise verifies its captured binding is still current
immediately before response. Background validates echoed values before forwarding
secret. Any missing/mismatched/changed value returns `stale_session` without
credential data.

Vault switch, cache republish, or bridge restart invalidates every older token
logically at comparison boundary, even if worker has not observed event. Worker
also eagerly removes grants when a later status/query advertises a different
binding. A delayed response from old binding is discarded.

Required regression: query vault A, then switch/publish vault B containing same
entry UUID and exact origin. Old token/request and delayed A response must return/
resolve as `stale_session`; B username/password must never be revealed through A
grant.

### SR-5 — plaintext lifetime

Accepted unavoidable lifetime: after explicit action, username/password exist in
native response serialization, background response, one content callback/local
scope, and target input values. Page can read filled values and observe dispatched
events; this is inherent to in-page fill.

Testable invariants:

- password absent from match/metadata messages;
- password absent from overlay DOM/text/attributes, extension storage, logs,
  globals, fill tokens, and persisted pending metadata;
- secret response handled only in local scope, then fields overwritten where
  mutable and references set to `null`/allowed to leave scope best-effort;
- no secret included in errors, telemetry, screenshots, test snapshots, or debug
  output.

No acceptance test may claim to prove garbage collection, memory erasure, DevTools
heap invisibility, or performance-timeline absence. JavaScript cannot verify those
claims.

### SR-6 — Shadow DOM is style isolation, not a security boundary

Use an isolated-world content script and closed shadow root to reduce CSS/DOM name
collisions. Closed mode only makes `host.shadowRoot` return `null` to ordinary page
code. Page can still observe host insertion/removal, position, layout effects,
focus/value changes, input/change events, and ultimately any filled value. Hostile
pages may interfere with or imitate UI. Security therefore relies on sender
validation, exact origin, capability token, app unlock, and explicit user action.

### SR-7 — iframe behavior

- Top frame: supported when exact origin is enabled and script is injected.
- Same-origin frame: supported only when browser actually injects registered
  script into that frame.
- Cross-origin frame: supported only if that frame's own exact origin was
  separately enabled, browser granted matching permission, and script was
  injected there. Query/fill binds to frame origin, not top origin.
- Otherwise no in-frame fill. Where top frame can detect iframe focus, show an
  unsupported state; detection is not guaranteed across origins. Popup directs
  user to open Custode and copy manually. Slice A adds no clipboard permission
  and no cross-origin reveal shortcut.

Never claim universal iframe support. Sandboxed, credentialless, fenced, browser
internal, extension-store, PDF, and restricted frames/pages may reject injection.

### SR-8 — teardown, revocation, and worker reconciliation

Disable is a crash-consistent transaction. Durable config is authorization source
of truth, so its security commit happens before every fallible cleanup side effect:

1. atomically replace single `overlayConfigV1` storage value with target origin
   removed and revision incremented; await successful durable write/readback;
2. invalidate worker focus grants for old revision/origin;
3. send teardown to matching already-injected documents;
4. unregister matching dynamic scripts when no enabled origin still needs site
   pattern;
5. remove optional host permission when no enabled origin shares its browser
   permission pattern.

No grant invalidation, teardown, unregister, or permission removal starts before
step 1 succeeds. After step 1, every authorization check sees disabled state even
if worker crashes before cleanup. Steps 2–5 are idempotent reconciliation work.
Crash-injection tests terminate/restart worker after each step and require cold
start to finish cleanup fail-closed.

Injected JavaScript cannot be forcibly unloaded. Teardown must remove listeners,
timers, observers, ARIA mutations, overlay host, and references immediately. If a
document cannot receive teardown, background authorization is already revoked and
all later requests fail closed.

On every service-worker cold start, install/startup, permission add/remove, and
popup open, first load/validate durable config, clear all in-memory grants, then
reconcile actual optional permissions, dynamic content-script registrations, and
open tabs to config. Invalid/missing config means no enabled origins. Missing
permission durably removes affected origin in one revisioned write. Permission or
registration not justified by config is orphan cleanup. Already-injected scripts
must bootstrap against durable config before attaching focus listeners/rendering.

### SR-9 — app state

Locked/changed/closed app cannot reveal or generate. Existing bridge descriptor
and credential maps are cleared through current coordinator/bridge stop path.
Overlay shows locked/unavailable state and never triggers unlock from page.

## Interaction and accessibility

- Eligible fields: visible, enabled, writable password input; username/email input
  only when associated form contains eligible password input.
- Input retains focus. Overlay never changes form ownership.
- Metadata list uses `role="listbox"`; rows use `role="option"` and
  `aria-selected`. Stable option ids drive `aria-activedescendant`.
- Anchor exposes combobox expanded state while open. Closed-shadow ARIA IDREF
  support varies, so a `role="status" aria-live="polite"` region announces count,
  selected row, locked/error, and teardown state as mandatory fallback.
- `ArrowUp`/`ArrowDown` move active option; `Enter` fills selected exact match;
  `Escape` closes for current focus session; `Tab` closes and is not swallowed.
- Enter is prevented only when it activates overlay fill. No form submit event may
  result from keyboard or pointer action.
- Overlay controls are `type="button"`. Pointer-down preserves anchor focus;
  blur teardown is deferred through pointer completion to avoid click-vs-blur
  loss. Outside blur still tears down promptly.
- Restore every pre-existing ARIA attribute changed on anchor during teardown.
- Respect zoom, forced colors, reduced motion, light/dark mode, and viewport clamp.

## Visual inventory — Slice A

Overlay is browser DOM, not Flutter widget output. Flutter goldens are inapplicable.
Visual acceptance uses approved expected PNGs, not filename count.

Canonical pixel environment is one Linux x86_64 OCI image pinned by immutable
digest. `desktop/browser_extension/test/visual_environment_v1.json` pins Chrome
for Testing exact version/revision, archive SHA-256, browser binary SHA-256, image
digest, locale `en-US`, timezone `UTC`, installed font file/package versions and
hashes, color profile, rendering flags, animation policy, and capture dimensions.
No `stable`, `latest`, mutable image tag, missing digest, or unverified local
browser may approve/verify baselines. Runner checks actual browser version/hash and
environment manifest before capture.

Approved baselines live under
`desktop/browser_extension/test/screenshots/expected/`; deterministic recapture
writes `.../actual/`. `visual_baselines_v1.sha256` records approved SHA-256 per
expected PNG. Verification requires exact decoded-pixel equality and expected hash
for every row; dimensions/color mode also match. New/changed baseline requires
human design review plus explicit expected-file/hash promotion. Inventory count is
supplemental. Viewports are CSS pixels; DPR is browser device scale factor. Exact
inventory count remains **18**.

| # | Filename | State | Browser | Viewport | DPR | Theme |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `overlay-chrome-1440x900-dpr1-light-matches.png` | exact matches | locked Chrome for Testing | 1440×900 | 1 | light |
| 2 | `overlay-chrome-1440x900-dpr1-dark-matches.png` | exact matches | locked Chrome for Testing | 1440×900 | 1 | dark |
| 3 | `overlay-chrome-1440x900-dpr1-light-possible.png` | possible/no fillable | locked Chrome for Testing | 1440×900 | 1 | light |
| 4 | `overlay-chrome-1440x900-dpr1-dark-possible.png` | possible/no fillable | locked Chrome for Testing | 1440×900 | 1 | dark |
| 5 | `overlay-chrome-1440x900-dpr1-light-no-matches.png` | no matches | locked Chrome for Testing | 1440×900 | 1 | light |
| 6 | `overlay-chrome-1440x900-dpr1-dark-no-matches.png` | no matches | locked Chrome for Testing | 1440×900 | 1 | dark |
| 7 | `overlay-chrome-1440x900-dpr1-light-locked.png` | app locked | locked Chrome for Testing | 1440×900 | 1 | light |
| 8 | `overlay-chrome-1440x900-dpr1-dark-locked.png` | app locked | locked Chrome for Testing | 1440×900 | 1 | dark |
| 9 | `overlay-chrome-1440x900-dpr1-light-no-host.png` | native host unavailable | locked Chrome for Testing | 1440×900 | 1 | light |
| 10 | `overlay-chrome-1440x900-dpr1-dark-no-host.png` | native host unavailable | locked Chrome for Testing | 1440×900 | 1 | dark |
| 11 | `overlay-chrome-1440x900-dpr1-light-unsupported-frame.png` | unsupported frame | locked Chrome for Testing | 1440×900 | 1 | light |
| 12 | `overlay-chrome-1440x900-dpr1-dark-unsupported-frame.png` | unsupported frame | locked Chrome for Testing | 1440×900 | 1 | dark |
| 13 | `overlay-chrome-390x844-dpr2-light-matches-below.png` | matches, below anchor | locked Chrome for Testing | 390×844 | 2 | light |
| 14 | `overlay-chrome-390x844-dpr2-dark-matches-below.png` | matches, below anchor | locked Chrome for Testing | 390×844 | 2 | dark |
| 15 | `overlay-chrome-1024x768-dpr1-light-matches-flipped.png` | matches, flipped above | locked Chrome for Testing | 1024×768 | 1 | light |
| 16 | `overlay-chrome-1440x900-dpr1-light-loading.png` | loading | locked Chrome for Testing | 1440×900 | 1 | light |
| 17 | `overlay-chrome-1440x900-dpr1-dark-stale-retry.png` | stale/retry | locked Chrome for Testing | 1440×900 | 1 | dark |
| 18 | `overlay-chrome-1440x900-dpr1-light-timeout.png` | native timeout | locked Chrome for Testing | 1440×900 | 1 | light |

Named DOM assertions substitute axes not duplicated as screenshots:

- `content_overlay.test.js — renders every state with metadata-only DOM`;
- `content_overlay.test.js — anchors below, flips above, and clamps viewport`;
- `content_overlay.test.js — applies light/dark/forced-colors contract`;
- `content_overlay.test.js — exposes listbox/options/live state and restores ARIA`;
- `content_overlay.test.js — teardown removes host/listeners and never submits`;
- `overlay_security.test.js — Chrome/Edge sender and frame contracts stay equal`.

No Flutter widget assertion substitutes exist because no Flutter widget renders
this overlay. Windows/macOS/Edge are compatibility environments, not pixel
authorities; use named DOM/geometry/accessibility assertions and manual smoke there.
Screenshot verification must require approved expected pixels/hashes first, then
exactly these 18 basenames with no missing/extra PNGs.

## Slice A acceptance criteria

1. Fresh install adds no site access and injects nothing.
2. Manifest has `storage` and optional HTTP(S) hosts only; no static content
   script or always-on host permission.
3. Enable/disable is per exact normalized origin and reversible. Shared
   host-pattern permission is removed only after last matching enabled origin.
   Disable first commits one atomic durable origin removal + revision increment;
   crash/restart after each phase reconciles to disabled fail-closed state.
4. Automated JS tests reject extension/content sender-path confusion, malformed
   shapes, missing tab/frame URL, origin spoofing, scheme/port/host mismatch, and
   disabled permission.
5. Match messages contain metadata only and no username/password.
6. Fill works only for exact-origin URL match, explicit click/Enter, current focus
   nonce/token, unlocked app, current document/frame, and current database/cache/
   bridge generation binding.
7. Host-only/domain-only match cannot reveal for origin-bound fill at native host
   or app bridge.
8. Stale response after focus change/navigation/disable cannot render or fill.
   Vault A → B with identical entry UUID/origin rejects A token and delayed A
   response as `stale_session` without revealing B secret.
9. Teardown removes UI/listeners/state immediately; unreachable old scripts are
   denied by background.
10. Supported frame cases pass; unsupported cross-origin/restricted frames fail
    closed without claiming injection.
11. Password is absent from DOM/storage/log/globals/metadata messages. Code uses
    best-effort reference clearing without GC claims.
12. Listbox keyboard/ARIA/live behavior works with pointer blur race covered; form
    submission count remains zero.
13. Security/protocol harness passes before visual screenshots are accepted.
14. `package_extension.sh` includes runtime overlay files and excludes tests/debug
    fixtures; extension README documents permissions, opt-in, teardown, frames,
    native host setup, and targeted verification.
15. Canonical locked environment recaptures exactly 18 PNGs and each decoded image
    equals approved expected baseline/hash. Count is supplemental; named DOM/
    geometry assertions cover noncanonical OS/browser axes.

## Slice B acceptance gate

1. `hello` advertises explicit generation capability only when app contract is
   available; old host/app combinations keep Generate disabled.
2. App persists/owns global non-secret generator settings through versioned
   repository. First install defaults to length 16 with lowercase/uppercase/
   digits/symbols enabled. Migration, reset, corruption fallback, and UI apply/
   cancel semantics are tested; extension cannot store/override settings.
3. App generates while unlocked, creates app-owned pending new-entry state, and
   returns one secret once with id + expiry.
4. Pending generated secret expires within five minutes at most, is consumed or
   rejected explicitly, and clears on lock, database change, app exit, or bridge
   stop.
5. Extension stores neither generated secret nor pending id; focus teardown drops
   references and stale token cannot regenerate/replay.
6. Targeted app/native/JS tests cover expiry, ownership, lock cleanup, malformed
   settings, capability negotiation, stale response, and no extension persistence.
7. Slice B starts only after Slice A acceptance and B0 settings/pending contract
   tests pass.

“Clear” means remove all reachable app references and records best-effort. Dart and
JavaScript strings are immutable; no requirement may claim deterministic memory
zeroization or garbage-collection timing.

## Slice C — one global switch replaces the per-origin opt-in

**Status**: implemented. This section AMENDS the model described above; it does
not rewrite it. Slices A0–A3 really were per-origin, their tasks really were
executed as written, and their tasks stay ticked. What follows is the change
made on top of them and the reason for it.

### The change

The durable opt-in is no longer a list of individually enabled origins. It is
one boolean:

```text
overlayConfigV1 { version: 1, revision, enabledOrigins[] }   <- slices A0–A3
overlayConfigV2 { version: 2, revision, enabled }            <- slice C
```

The popup shows a single switch. Turning it on requests both optional host
patterns (`http://*/*`, `https://*/*`) once, under the user gesture. One
content-script registration covers `http(s)://*/*` instead of one registration
per enabled pattern.

### Why

The per-origin control was unusable in practice. Before the overlay could
appear on a site, the user had to notice the site was not enabled, open the
toolbar popup, and click *Turn on* — for every site, forever. The realistic
outcome was that the overlay never appeared, which is not a safer product than
one broad informed grant; it is the same product with a feature nobody reaches.

### Relationship to "Broad always-on site access" in Out of scope

That bullet is narrowed rather than deleted, and the distinction is the whole
point of this slice. What is now in scope is broad **injection**: the overlay
script may run on any http(s) page while the switch is on. What remains out of
scope, and is unchanged, is broad **behaviour**: the extension does not read,
collect or transmit page content, does not fill or submit anything without an
explicit click, and does not widen what the app will disclose.

### What Slice C did NOT change

Asserted by the test suite and by the mutation table, not merely intended:

- **A015 / the manifest.** Byte-identical. Still no `host_permissions`, still no
  static `content_scripts`, still no `tabs`/`webNavigation`/clipboard, still
  `<all_urls>`-free. The broad pair was already declared as
  `optional_host_permissions` before this slice; only the runtime request
  changed shape.
- **Exact-origin disclosure.** The authoritative origin is still derived from
  `sender.url`, the body origin is still only a mismatch detector, the native
  metadata query is still made with the frame's exact origin including port,
  and the reveal is still bound to it. A frame is authorized to RUN, not to
  ask about a neighbour.
- **One-shot focus tokens, the TTL ceiling, and the
  `(databaseId, cacheGeneration, bridgeGeneration)` binding.**
- **`isTrusted` on every activation handler, the closed shadow root, the log
  sanitizer, and every teardown trigger.**
- **The crash-consistent disable order D1–D5.** D1 is still the durable commit
  and still precedes every side effect; only what each phase converges on
  changed.
- **The 18 visual baselines.** The in-page overlay UI is untouched and the
  baselines verify byte-identical without recapture.

### What Slice C did change, deliberately

- A sibling port, a sibling scheme and a look-alike host now all get the
  overlay injected, where before only an exactly-enabled origin did. Each is
  still a separate identity to the vault, so none of them sees another's
  entries.
- Refcounting of permissions and registrations across origins sharing one
  Chromium pattern is gone; there is nothing to share.
- `unsupported_origin` and `too_many_origins` no longer exist as refusals.

### Migration

A surviving `overlayConfigV1` value is not readable by this build and is never
interpreted. The overlay starts **disabled** after the upgrade regardless of how
many origins were enabled before — consent to three named sites is not consent
to all sites — and reconciliation revokes every residual per-origin host
permission, unregisters every per-origin content script, and deletes the stale
key. This holds even when the broad grant happens to be held already (a user
can set "On all sites" by hand from `chrome://extensions`): a browser
permission is not consent to the feature.

The revision floor key is deliberately NOT renamed alongside the config key, so
revision monotonicity holds across the v1→v2 boundary and a focus grant minted
at a v1 revision can never compare as current against a restarted counter.

## Out of scope

- Automatic fill or submit.
- TOTP fill.
- Automatic save or vault mutation from page.
- Broad always-on site *behaviour* — reading, collecting or transmitting page
  content. Broad *injection* is in scope as of Slice C; see that section for
  the distinction.
- Built-in clipboard fallback.
- Firefox/Safari support.
- Universal iframe or Shadow DOM security claims.
