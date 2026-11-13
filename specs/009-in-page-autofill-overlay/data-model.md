# 009 — Data model and contracts

## Rules

- JSON objects use exact allowlisted keys and types. Reject unknown keys,
  oversized strings/arrays, non-finite numbers, and unsupported versions.
- Request body origin is a claim used only for mismatch detection. Background
  derives authoritative frame origin from `sender.url`.
- Metadata and persistence never contain password.
- Fill/generation secret responses are one-shot and local-scope only.
- All examples are logical contracts; final names may change once while tests are
  written, then become versioned compatibility surface.

## Canonical origin

Conceptual value:

```text
BrowserOrigin {
  scheme: "http" | "https"
  asciiHost: lower-case URL-parser host without trailing dot
  effectivePort: 1..65535 (80 for implicit http, 443 for implicit https)
  serialized: scheme://host[:non-default-port]
}
```

Normalization algorithm in JS and Dart:

1. Parse absolute URL with platform URL/URI parser.
2. Reject non-HTTP(S), opaque origin, empty host, credentials, or invalid port.
3. Lowercase scheme; use parser-normalized ASCII/IDNA host and remove terminal
   dot consistently.
   Preserve all hostname labels: never strip `www.`, `m.`, or `mobile.`.
4. Convert missing/default port to effective 80/443 for comparison.
5. Serialize default port without `:80`/`:443`; retain non-default port.
6. Ignore path/query/fragment because they are not part of origin.

Equality is all three tuple fields. Never compare only `hostname`, registrable
domain, suffix, or display string.

Current `DesktopBrowserAutofillMetadataMapper.normalizedHost/normalizedOrigin`
uses `_cleanHost`, which strips common host prefixes. Keep that behavior for
possible-match ranking only. Exact-origin authorization needs a separate helper
used consistently by JS background, native host, and app reveal bridge.

Examples:

| Input | Canonical | Equal to first? |
| --- | --- | --- |
| `https://EXAMPLE.com/login` | `https://example.com` | yes |
| `https://example.com:443/a` | `https://example.com` | yes |
| `https://example.com:8443/a` | `https://example.com:8443` | no |
| `http://example.com` | `http://example.com` | no |
| `https://example.com.evil.test` | `https://example.com.evil.test` | no |

### Shared canonicalization fixture

Single source of truth:

`desktop/browser_extension/test/fixtures/origin_canonicalization_v1.json`

Node tests and Dart tests both parse this exact file. Neither suite may duplicate
expected values in source. Fixture schema:

```json
{
  "version": 1,
  "cases": [
    {
      "id": "https-default-port",
      "input": "https://example.com:443/login",
      "valid": true,
      "canonicalOrigin": "https://example.com",
      "effectivePort": 443,
      "permissionPattern": "https://example.com/*",
      "error": null
    }
  ]
}
```

Required case inventory; fixture may add cases but may not remove/rename these:

| ID | Input class | Expected |
| --- | --- | --- |
| `https-mixed-case` | `https://EXAMPLE.com/login` | valid → `https://example.com` |
| `https-default-port` | `https://example.com:443/a` | valid → `https://example.com`, port 443 |
| `https-nondefault-port` | `https://example.com:8443/a` | valid → `https://example.com:8443`, port 8443 |
| `http-default-port` | `http://example.com:80/a` | valid → `http://example.com`, port 80 |
| `http-nondefault-port` | `http://example.com:8080/a` | valid → `http://example.com:8080`, port 8080 |
| `idna-unicode` | `https://bücher.example/a` | valid → `https://xn--bcher-kva.example` |
| `idna-ascii` | `https://xn--bcher-kva.example/a` | same canonical origin as Unicode form |
| `ipv6-default-port` | `https://[2001:db8::1]:443/a` | valid → `https://[2001:db8::1]` |
| `ipv6-expanded` | expanded `2001:0db8:0:0:0:0:0:1` | valid → compressed canonical IPv6 origin |
| `ipv6-nondefault-port` | `https://[2001:db8::1]:8443/a` | valid, port retained |
| `trailing-dot` | `https://example.com./a` | valid → `https://example.com` |
| `userinfo-name` | `https://alice@example.com/a` | invalid `userinfo_forbidden` |
| `userinfo-password` | `https://alice:secret@example.com/a` | invalid `userinfo_forbidden` |
| `ipv4-canonical` | `https://127.0.0.1/a` | valid → `https://127.0.0.1` |
| `ipv4-shorthand` | `https://127.1/a` | invalid `noncanonical_ipv4` |
| `ipv4-leading-zero` | `https://127.000.000.001/a` | invalid `noncanonical_ipv4` |
| `ipv4-octal` | `https://0177.0.0.1/a` | invalid `noncanonical_ipv4` |
| `ipv4-hex` | `https://0x7f.0.0.1/a` | invalid `noncanonical_ipv4` |
| `ipv4-dword` | `https://2130706433/a` | invalid `noncanonical_ipv4` |
| `scheme-ftp` | `ftp://example.com/a` | invalid `scheme_forbidden` |
| `scheme-file` | `file:///tmp/a` | invalid `scheme_forbidden` |
| `scheme-data` | `data:text/plain,hello` | invalid `scheme_forbidden` |
| `scheme-javascript` | `javascript:alert(1)` | invalid `scheme_forbidden` |
| `scheme-extension` | `chrome-extension://id/page.html` | invalid `scheme_forbidden` |

Raw-authority validation must detect userinfo and noncanonical IPv4 before URL
parser normalization can erase evidence. Both test suites assert fixture version,
unique ids, required-id set, total case count, validity, canonical origin,
effective port, permission pattern, and error code.

## Extension persistence — Slice C (supersedes the Slice A block below)

> The Slice A block that follows describes the per-origin model as built and
> shipped in slices A0–A3. It is kept because the crash-consistency,
> reconciliation and registration rules in it are still normative word for
> word; only the SHAPE of the durable value and the meaning of "desired
> permissions/registrations" changed. Where the two disagree, this section
> wins.

Only `chrome.storage.local`:

```json
{
  "overlayConfigV2": {
    "version": 2,
    "revision": 17,
    "enabled": false
  },
  "overlayRevisionFloorV1": 17
}
```

Constraints:

- exactly these three keys, exact types; `enabled` must be a real boolean, and
  a truthy non-boolean is corruption, not a yes;
- `revision` increments on enable, disable, reconciliation correction, and
  permission removal;
- no origins are persisted at all — the durable value cannot leak which sites
  the user visits, because it never knows;
- no credential ids, match results, usernames, titles, focus tokens, pending
  ids, page titles, paths, queries, fragments, passwords, or native responses;
- no persisted dismissed/session state;
- permission patterns and the registration id are derived from a constant, not
  persisted.

Derived browser state while `enabled` is true:

```text
optional host permissions : ["http://*/*", "https://*/*"]   (both, or none)
content-script registration: one, matches ["http://*/*", "https://*/*"],
                             ISOLATED world, document_idle, allFrames
```

The permission is all-or-nothing. Losing either pattern is a revocation, not a
smaller grant: a half-injected overlay is not a state the user consented to.

### Migration from `overlayConfigV1`

The key is renamed, not reused, and the v1 shape is refused by the strict
parser (`version` is pinned to 2 and `enabledOrigins` is an unknown key). A v1
value therefore takes the normal fail-closed corruption path and produces
`enabled: false`. This is required, not incidental:

```text
v1 { enabledOrigins: [a, b, c] }  ->  v2 { enabled: false }     ALWAYS
```

Reconciliation additionally removes every granted pattern the new config does
not justify (which is all of them while disabled), unregisters every
`kv-overlay-` registration whose id is not the global one, and deletes the
stale `overlayConfigV1` key. The registration-id encoding is injective, which
is what guarantees a per-origin id can never be mistaken for the global one.

`overlayRevisionFloorV1` keeps its name across the version bump on purpose:
revision monotonicity must hold across the boundary, or a focus grant minted at
a v1 revision could compare as current against a v2 counter that restarted.

### Crash-consistent disable transaction — Slice C phases

Order and rules unchanged; targets updated:

```text
D1 durable commit: enabled = false; revision += 1
D2 clear all worker focus grants
D3 broadcast teardown to all injected frames (revision only, no origin)
D4 unregister the content script
D5 remove both optional host permissions
```

## Extension persistence — Slice A

Only `chrome.storage.local`:

```json
{
  "overlayConfigV1": {
    "version": 1,
    "revision": 17,
    "enabledOrigins": [
      "https://example.com",
      "https://example.com:8443"
    ]
  }
}
```

Constraints:

- sorted, unique canonical origins; practical maximum 500;
- `revision` increments on enable, disable, reconciliation correction, and
  permission removal;
- no credential ids, match results, usernames, titles, focus tokens, pending ids,
  page titles, paths, queries, fragments, passwords, or native responses;
- no persisted dismissed/session state;
- permission pattern/refcount is derived from enabled origins, not persisted.

Chromium permission pattern derivation:

```text
https://example.com:8443 -> https://example.com/*
https://example.com      -> https://example.com/*
http://example.com       -> http://example.com/*
```

Port disappears because Chromium host permission patterns do not represent it.
Runtime exact-origin checks remain mandatory. Removing one enabled port must not
remove shared permission while another enabled origin maps to same pattern.

Dynamic content-script registrations are browser-owned state queried through
`chrome.scripting.getRegisteredContentScripts()`. Registration ids are derived
from a stable hash/encoding of permission pattern; do not persist duplicate
registration truth in storage.

Registration handles later documents only. Enable flow also programmatically
injects current tab/all permitted frames. A non-secret isolated-world guard makes
startup idempotent; teardown removes listeners/state and clears guard so a later
valid enable can bootstrap again.

### Crash-consistent disable transaction

`overlayConfigV1` is one storage key so removal and revision increment commit in
one `chrome.storage.local.set({overlayConfigV1: nextConfig})` operation. Serialize
config mutations in worker. Await API completion and read back exact value before
starting cleanup; on error/mismatch perform no later phase and report disable not
committed.

Phases, each idempotent:

```text
D1 durable commit: enabledOrigins -= origin; revision += 1
D2 clear all worker focus grants bound to origin/older revision
D3 broadcast teardown to matching tabs/all injected frames
D4 unregister dynamic script if committed origins no longer need pattern
D5 remove optional host permission if committed origins no longer need pattern
```

After D1, every bootstrap/matches/fill authorization reload/check uses committed
config revision before worker grant state. Script/permission residue cannot regain
authorization. D2–D5 may be retried in any later worker instance.

Cold-start reconciliation sequence is always fail-closed:

1. read and strictly validate `overlayConfigV1` before serving messages;
2. invalid/missing state becomes zero enabled origins and a new valid revisioned
   config before any registration/injection;
3. initialize focus-grant map empty;
4. derive desired registrations and optional permissions from committed origins;
5. teardown scripts and remove registrations/permissions absent from desired set;
6. only then accept bootstrap/matches/fill.

Crash fixture/harness terminates worker after D1, D2, D3, D4, and D5 separately,
starts a fresh worker, runs reconciliation, and asserts same terminal state:
origin absent, higher revision durable, no grant, active frames inert/removed,
unused registration absent, unused permission absent. Shared-pattern cases retain
registration/permission needed by another committed origin while target origin
remains unauthorized.

## Vault session binding — Slice A

```text
VaultSessionBinding {
  databaseId: opaque current database id
  cacheGeneration: opaque random 128-bit id created per metadata publish
  bridgeGeneration: opaque random 128-bit id created per reveal-bridge start
}
```

All fields are non-secret, bounded, and compared exactly. Metadata cache owns
`databaseId` + `cacheGeneration`; bridge descriptor and running app bridge own
same `databaseId` + `cacheGeneration` + `bridgeGeneration`. Extension stores none
of them durably.

Republishing same vault creates new `cacheGeneration`. Starting/restarting bridge
creates new `bridgeGeneration`. Switching vault necessarily changes database id
and both generations. Reusing same entry UUID/origin across vaults cannot reuse a
grant because session binding differs.

## Runtime state — Slice A

### Content-script focus session

```js
{
  origin: "https://example.com:8443",
  focusNonce: "base64url-random-128-bit",
  anchorEl,                 // local DOM reference
  usernameEl,               // optional local DOM reference
  overlayHost,
  shadowRoot,               // retained only inside content closure
  items: [/* metadata only */],
  activeIndex: 0,
  fillToken: null,
  sessionBinding: null,       // non-secret; set by current matches response
  tokenExpiresAtEpochMs: null,
  configRevision: 17,
  dismissed: false,
  pointerActionPending: false,
  teardownController: AbortController
}
```

One session per frame. New eligible focus always tears down prior session first.
No password field exists in this object. `AbortController` owns listeners where
supported; teardown also clears timers/animation frames and restores anchor ARIA
attributes.

### Service-worker focus grant

```js
{
  tokenHash: "in-memory-only",
  tabId: 42,
  frameId: 3,
  documentId: "optional-message-sender-document-id",
  origin: "https://example.com:8443",
  focusNonce: "base64url-random-128-bit",
  entryIds: ["entry-1"],
  databaseId: "db-a",
  cacheGeneration: "cache-generation-a",
  bridgeGeneration: "bridge-generation-a",
  configRevision: 17,
  expiresAtEpochMs: 1720000000000
}
```

Worker map is bounded (for example 100 grants, oldest/expired evicted) and never
persisted. Store token digest rather than raw token if implementation already has
a small digest helper; otherwise raw cryptographically random token in worker
memory is acceptable. Worker restart empties map and causes `stale_session`.

Grant invalidation triggers: focus replacement request for same frame, explicit
teardown, disable, permission/config revision change, tab removal/navigation,
expiry, successful fill, worker restart, vault switch, metadata cache republish,
or bridge restart. A worker may learn republish lazily; old grant is still
logically invalid because native/app comparisons use current binding. Any newer
status/query binding eagerly removes grants carrying older tuple.

## Sender trust model

| Route | Required sender | Authoritative origin | Allowed purpose |
| --- | --- | --- | --- |
| extension page | runtime id, no tab, exact extension URL | extension origin | popup status/query/search and overlay enable/disable/state |
| content script | runtime id, tab id, frame id, HTTP(S) sender URL | normalized `sender.url` | bootstrap, metadata matches, explicit fill |
| background → content | known tab/frame, current revision | target validated at dispatch | teardown/reconcile notice only |

`sender.tab.url` is normalized separately as top origin. It must equal frame origin
when `frameId === 0`. For child frames it is context only and never replaces
`sender.url`. `sender.origin`, if available, must agree with normalized
`sender.url`; disagreement fails closed. `sender.documentId`, if available, is
bound into grant.

## Extension messages — Slice A

Every message has `channel: "keyvault-overlay-v1"`, `version: 1`, and exact keys
shown. Existing popup `KEYVAULT_V2_*` routes remain extension-page-only.

### Extension page → background

#### Get current site state

```json
{
  "channel": "keyvault-overlay-v1",
  "version": 1,
  "type": "getSiteState",
  "tabId": 42,
  "origin": "https://example.com:8443"
}
```

Background independently verifies active/current tab id and URL before returning:

```json
{
  "ok": true,
  "type": "siteState",
  "origin": "https://example.com:8443",
  "enabled": false,
  "permissionGranted": false,
  "revision": 17
}
```

#### Set current site state

```json
{
  "channel": "keyvault-overlay-v1",
  "version": 1,
  "type": "setSiteState",
  "tabId": 42,
  "origin": "https://example.com:8443",
  "enabled": true
}
```

Permission request itself must execute from popup user gesture where Chromium
requires it. Background may perform reconciliation/registration after popup
returns granted result. Failed/denied permission does not write enabled origin.

### Content script → background

#### Bootstrap

```json
{
  "channel": "keyvault-overlay-v1",
  "version": 1,
  "type": "bootstrap",
  "origin": "https://example.com:8443"
}
```

Response contains no credential metadata:

```json
{
  "ok": true,
  "type": "bootstrapResult",
  "enabled": true,
  "origin": "https://example.com:8443",
  "topOrigin": "https://top.example",
  "frameId": 3,
  "frameSupport": "permitted-cross-origin",
  "revision": 17
}
```

`frameSupport` enum: `top`, `same-origin`, `permitted-cross-origin`, or
`unsupported`. Script remains inert and tears down unless `enabled` and support is
one of first three.

#### Request matches

```json
{
  "channel": "keyvault-overlay-v1",
  "version": 1,
  "type": "requestMatches",
  "origin": "https://example.com:8443",
  "focusNonce": "nonce",
  "fieldKind": "password"
}
```

`fieldKind` is `password` or `username`; it is UI metadata, not authorization.

Success:

```json
{
  "ok": true,
  "type": "matchesResult",
  "origin": "https://example.com:8443",
  "focusNonce": "nonce",
  "revision": 17,
  "sessionBinding": {
    "databaseId": "db-a",
    "cacheGeneration": "cache-generation-a",
    "bridgeGeneration": "bridge-generation-a"
  },
  "items": [
    {
      "entryId": "entry-1",
      "title": "Example",
      "displayService": "example.com",
      "matchType": "exact-origin",
      "fillEligible": true
    },
    {
      "entryId": "entry-2",
      "title": "Example legacy",
      "displayService": "example.com",
      "matchType": "possible",
      "fillEligible": false
    }
  ],
  "fillToken": "random-short-lived-token",
  "expiresAtEpochMs": 1720000000000
}
```

Limits: maximum 10 items; bounded ids/text; allowed `matchType` values only.
Username and password are intentionally absent. `fillToken` covers fill-eligible
entry ids and exact session binding only. If no item is fillable, omit/null token.

Stable non-secret error response:

```json
{
  "ok": false,
  "type": "matchesResult",
  "focusNonce": "nonce",
  "error": { "code": "locked", "message": "Open and unlock Custode." }
}
```

Allowed codes: `disabled`, `unsupported_frame`, `unsupported_capability`,
`locked`, `no_host`, `timeout`, `invalid_request`, `forbidden`, `stale_session`,
`internal_error`. Messages never echo URLs beyond canonical origin or native
payload details.

#### Explicit fill

```json
{
  "channel": "keyvault-overlay-v1",
  "version": 1,
  "type": "fill",
  "origin": "https://example.com:8443",
  "focusNonce": "nonce",
  "fillToken": "random-short-lived-token",
  "entryId": "entry-1",
  "sessionBinding": {
    "databaseId": "db-a",
    "cacheGeneration": "cache-generation-a",
    "bridgeGeneration": "bridge-generation-a"
  }
}
```

Background revalidates sender and consumes grant before/while issuing native
request so token cannot be replayed. Success is only extension message carrying
existing credential secret:

```json
{
  "ok": true,
  "type": "fillResult",
  "origin": "https://example.com:8443",
  "focusNonce": "nonce",
  "entryId": "entry-1",
  "sessionBinding": {
    "databaseId": "db-a",
    "cacheGeneration": "cache-generation-a",
    "bridgeGeneration": "bridge-generation-a"
  },
  "data": {
    "username": "alice",
    "password": "secret"
  }
}
```

Content script verifies type/origin/nonce/entry id/session binding and current
focused anchor, copies values to local variables, best-effort blanks mutable
response fields, sets inputs, dispatches bubbling `input` + `change`, clears
references, and tears down. It never serializes or forwards this response
elsewhere.

### Background → content teardown

```json
{
  "channel": "keyvault-overlay-v1",
  "version": 1,
  "type": "teardown",
  "origin": "https://example.com:8443",
  "revision": 18,
  "reason": "disabled"
}
```

Allowed reasons: `disabled`, `permission_removed`, `reconciled`, `navigation`,
`worker_reset`. Content accepts teardown only from extension runtime and always
tears down if revision is newer or origin matches; teardown carries no secret.

## Native protocol — Slice A

Current envelope remains:

```json
{
  "version": 2,
  "id": "request-id",
  "type": "queryCredentials",
  "payload": {}
}
```

Required exact-origin capability can be represented as:

```json
{
  "supportedMessages": ["queryCredentials", "revealForFill"],
  "capabilities": ["overlayExactOriginV1"]
}
```

Overlay query:

```json
{
  "version": 2,
  "id": "request-id",
  "type": "queryCredentials",
  "payload": {
    "url": "https://example.com:8443",
    "limit": 10,
    "matchPolicy": "exactOrigin"
  }
}
```

Host must echo/confirm `matchPolicy: "exactOrigin"`, canonical target origin, and
current `sessionBinding` from cache + descriptor. If old host ignores policy/
binding or capability is absent, background returns `unsupported_capability`; it
must not reinterpret host-only `strongMatches`.

Reveal:

```json
{
  "version": 2,
  "id": "request-id",
  "type": "revealForFill",
  "payload": {
    "entryId": "entry-1",
    "origin": "https://example.com:8443",
    "matchPolicy": "exactOrigin",
    "expectedDatabaseId": "db-a",
    "expectedCacheGeneration": "cache-generation-a",
    "expectedBridgeGeneration": "bridge-generation-a"
  }
}
```

Both native host metadata check and app bridge `/reveal` check require exact URL
origin identifier and exact expected session binding. Native host compares against
current metadata cache and bridge descriptor before app request. App request
repeats expected values; app compares against running unlocked bridge/cache state
under one session epoch before credential lookup and again before response. Native
host re-reads current metadata cache/descriptor after app response and before
returning; overlay query also rechecks its captured tuple immediately before
response. Existing host fallback in `_isStrongBrowserMatch` and app fallback in
`_isExactBrowserMatch` must not authorize this request. Success echoes all expected
values. Response id, version, type, policy, entry id, binding, and bounded strings
are checked before forwarding. Missing/mismatch/change at any layer returns
`stale_session` with no username/password.

Mandatory stale-vault scenario:

```text
query vault A -> grant(entry UUID X, origin O, db A, cache A1, bridge A1)
switch/publish vault B -> same UUID X and origin O, binding (db B, B1, B1)
use A grant or receive delayed A reveal response -> stale_session, no B secret
```

## Overlay DOM/accessibility model

Conceptual closed-shadow tree:

```html
<section class="kv-overlay" aria-label="Custode suggestions">
  <div id="kv-status" role="status" aria-live="polite"></div>
  <div id="kv-list" role="listbox" aria-activedescendant="kv-option-0">
    <button id="kv-option-0" type="button" role="option" aria-selected="true">
      <span>Example</span>
      <span>example.com</span>
    </button>
  </div>
</section>
```

No password/username in text, attributes, dataset, comments, style, accessible
name, or host properties. Anchor receives/restores combobox ARIA attributes.
Because closed-shadow ID references vary across accessibility stacks, live status
announces selected label and position (for example “Example, 1 of 2”).

State machine:

```text
inert -> focused/loading -> matches | no-match | locked | no-host | unsupported
focused/* -> filling -> teardown
focused/* -> stale/disabled/navigation/blur/escape/hidden -> teardown
teardown -> inert (new focus creates new nonce)
```

Pointer-down inside overlay marks action pending and prevents anchor blur. Outside
blur schedules teardown after current pointer task; valid overlay click cancels
that scheduled teardown, performs action, then tears down. Buttons remain outside
page forms and are explicitly `type="button"`.

## Iframe model

| Frame | Script present? | Exact origin enabled? | Result |
| --- | --- | --- | --- |
| top HTTP(S) | yes | yes | supported |
| same-origin child | yes | yes | supported |
| same-origin child | browser denied injection | any | unsupported/no overlay |
| cross-origin child | yes | child origin yes | supported, bound to child origin |
| cross-origin child | no or child origin no | no | no in-frame overlay; unsupported hint only where top can detect focus |
| sandboxed/opaque/restricted | any | any | reject/no fill |

Top origin never authorizes child-origin credential. `frameId` alone never proves
origin. No host-only or top-origin fallback.

## Slice B app-owned model — not current

### Generator settings

```text
GeneratorSettingsSnapshot {
  schemaVersion: 1
  revision
  length (validated app range)
  includeLowercase
  includeUppercase
  includeDigits
  includeSymbols
}
```

Approved source: global, non-secret app settings persisted by app in existing
`SharedPreferences`. Domain owner is
`PasswordGeneratorSettingsRepository`; data implementation is
`SharedPreferencesPasswordGeneratorSettingsRepository`, registered through
`password_manager_data_di.dart`. Storage key is
`password_generator_settings_v1`; one JSON object is written atomically. Settings
are global across vaults and contain no password, seed, entropy, history, vault id,
or site data.

First-install/default value:

```json
{
  "schemaVersion": 1,
  "revision": 1,
  "length": 16,
  "includeLowercase": true,
  "includeUppercase": true,
  "includeDigits": true,
  "includeSymbols": true
}
```

Repository contract:

- `read()` validates and returns immutable snapshot;
- `save(snapshot, expectedRevision)` validates and rejects stale drafts, increments
  revision, atomically persists, then publishes update to app listeners;
- `reset()` atomically persists defaults with next revision and publishes once;
- `watch()` gives app UI/current generation one global source of truth.

Migration/corruption rules:

- missing key: first-install defaults are persisted once;
- known older schema: pure version-by-version migration, validate, atomically
  persist current schema;
- malformed JSON, wrong types, out-of-range length, no enabled set, or invalid
  known version: use/persist defaults and log only non-sensitive error code;
- unknown future schema during downgrade: use defaults in memory, do not overwrite
  future value automatically; UI exposes explicit Reset to replace it;
- failed write leaves last valid snapshot active and reports error; no partial
  listener update.

App UI semantics:

- generator dialog/settings UI initializes from repository snapshot;
- clean open UI follows repository `watch()` updates immediately; dirty draft
  keeps local edits, marks external change, and stale-revision Apply is rejected
  until user reloads/reapplies;
- edits are draft-local; **Apply/Save** validates and commits globally;
- **Cancel** discards draft and publishes nothing;
- **Reset to defaults** is explicit, commits through repository, and updates all
  open app consumers once;
- Slice B generation snapshots latest committed settings at request start;
  concurrent later UI edits affect only later requests.

Native/extension request cannot provide or override settings. Extension receives
and persists neither settings nor secret. Current dialog-local
`PasswordGeneratorOptions.defaults()` is migration baseline only, not existing
global settings contract.

### Pending generated entry

```text
PendingGeneratedEntry {
  id
  databaseId
  cacheGeneration
  bridgeGeneration
  settingsRevision
  origin: BrowserOrigin
  password: secret, unlocked app memory only
  createdAtEpochMs
  expiresAtEpochMs <= created + 5 minutes
  state: pending | consumed | rejected | expired
}
```

Ownership/lifecycle:

- created and held by running unlocked app, never extension/native-host file;
- id is opaque and scoped to database/session;
- one outstanding record per accepted request; bounded collection;
- consume creates/opens normal new-entry flow in app, then clears secret;
- reject/expiry clears secret;
- lock, database switch, vault close, reveal-bridge stop, or app exit clears all;
- existing `pending_associations.json` remains metadata-only and never stores this
  model.

Clearing removes records and all reachable references best-effort. Password is an
immutable Dart string, so lifecycle tests verify ownership/reachability and file/
log absence, not deterministic memory zeroization or GC timing.

### Generation capability/messages

Native request after capability negotiation:

```json
{
  "version": 2,
  "id": "request-id",
  "type": "generatePendingEntry",
  "payload": {
    "origin": "https://example.com:8443",
    "expectedDatabaseId": "db-a",
    "expectedCacheGeneration": "cache-generation-a",
    "expectedBridgeGeneration": "bridge-generation-a"
  }
}
```

App bridge `/generate-pending` validates bearer token, database, unlock, exact
origin, rate/bounds, expected session binding, and latest committed app settings;
generates inside app; creates pending record; returns:

```json
{
  "ok": true,
  "data": {
    "pendingGenerationId": "opaque-id",
    "expiresAtEpochMs": 1720000000000,
    "databaseId": "db-a",
    "cacheGeneration": "cache-generation-a",
    "bridgeGeneration": "bridge-generation-a",
    "settingsRevision": 4,
    "password": "generated-secret"
  }
}
```

Extension generation request also includes current focus nonce/token. Background
and native request bind current session tuple. Background does not persist binding,
settings, pending id, or password. Content uses password once, does not keep
pending id, and tears down. App remains sole owner and may surface save/reject UI.

Old host/app without `generatePendingEntryV1` returns unsupported capability;
Generate stays disabled. No fallback to extension-side generation or defaults.
