# 009 — Tasks

Order is mandatory: tests/security contract, native authorization, lifecycle,
behavior, accessibility, visuals. Slice B remains blocked until its app contracts
land.

## Slice A0 — baseline and automated security harness

- [x] **A001** Record current baseline from
      `desktop/browser_extension/manifest.json`, `background.js`, `popup.js`,
      `tool/native_host_protocol.dart`, and reveal bridge. Confirm current protocol
      has no overlay/generation capability and current generator settings are
      dialog-local.
      Evidence: `spec.md` §Current baseline records all five artefacts verbatim,
      including "It does not support password generation" and the dialog-local
      generator note.
- [x] **A002** Add `desktop/browser_extension/overlay_security.js` with pure,
      production-used canonical HTTP(S) origin, strict object-shape, and sender
      classification helpers. No dependency.
      Evidence: `canonicalizeOrigin`, `validateExactShape`, `classifySenderRoute`;
      the file has no `require`/`import` and is loaded by the worker via
      `importScripts`, by the popup via `<script>`, and by the harness via
      `require`. Mutations A0-M1, A0-M2, A0-M3, A0-M8.
- [x] **A003** Add Node built-in test harness under
      `desktop/browser_extension/test/`. Test extension-page sender path separately
      from content sender path; reject sender-path confusion, wrong runtime id,
      extension URL mismatch, missing tab/frame/sender URL, unknown keys, wrong
      types, and oversize values.
      Evidence: `test/sender_trust.test.js` (`node:test`), one named case per
      rejection above. Mutations A0-M4, A0-M9.
- [x] **A004** Create shared
      `desktop/browser_extension/test/fixtures/origin_canonicalization_v1.json`
      with required IDs from `data-model.md`: IDNA Unicode/punycode, IPv6 compact/
      expanded, userinfo, trailing dot, default/non-default ports, canonical and
      odd/noncanonical IPv4, invalid schemes, and phishing suffix. Node tests load
      every fixture case, verify version/count/unique required IDs, and verify body
      origin equals normalized `sender.url`, not `sender.tab.url` or host.
      Evidence: fixture is version 1 with 32 cases covering every required id;
      `test/origin_canonicalization.test.js`. Mutation A0-M6.
- [x] **A005** Test top-frame, same-origin child, permitted cross-origin child,
      disabled child origin, missing injection, sandboxed/opaque sender, and top
      URL/frame URL disagreement behavior.
      Evidence: `test/frame_context.test.js`, one named case per row.
      Mutation A0-M10.
- [x] **A006** Test focus nonce/token bind, allowed entry id, sender tab/frame/
      document/origin, 30-second maximum expiry, one-shot consumption, permission
      revision, database id, cache generation, bridge generation, bounded eviction,
      worker-reset loss, and stale response after focus/navigation/disable. Test
      vault A → B with identical entry UUID + origin: A token and delayed A response
      return `stale_session` and cannot reveal B secret.
      Evidence: `test/focus_grant.test.js`, including
      `REGRESSION vault A -> B: same entry UUID and same exact origin stay stale`.
      Mutations A0-M5, A0-M7.
- [x] **A007** Add shape assertions proving persisted config and all metadata
      messages reject `password`, `secret`, native payload dumps, username, and
      unknown fields. Tests must execute production validators, not copies.
      Evidence: `test/message_shape.test.js` reads the schema catalogue back out of
      `overlay_security.js`; `test/helpers.js` builds inputs only and holds no
      second copy of any validator.

**Gate A0**: `node --test desktop/browser_extension/test/*.test.js` passes before
overlay markup/CSS begins.

Enforced by CI, not by memory: the `extension-tests` job in
`.github/workflows/pr.yml` runs this command on every pull request to `main`, so
the gate holds across all later slices without anyone re-running it by hand. The
same job carries the `node --check` syntax gate for the extension sources that
exist today (`overlay_security.js`, `background.js`, `popup.js`). Any new runtime
JS file must be added to that job when it is created — the task that creates it
owns that obligation (see A028).

## Slice A1 — native exact-origin contract

- [x] **A008** In `tool/native_host_protocol.dart`, define/advertise
      `overlayExactOriginV1` capability and strict overlay query policy (or a new
      request type if old-peer fail-closed behavior cannot be guaranteed). Add
      explicit non-secret `cacheGeneration` per metadata publish and
      `bridgeGeneration` per reveal-bridge start alongside database id.
      Evidence: `overlayExactOriginCapability` / `overlayMatchPolicy` in
      `lib/.../services/browser_exact_origin.dart`, advertised through
      `nativeHostCapabilities`; both generations are emitted per publish/start by
      `_overlaySessionBinding`. Test
      `hello advertises the exact-origin capability and types`.
- [x] **A009** Add Dart tests first: exact URL origin matches; implicit/default
      port matches; scheme/non-default port/phishing suffix differs; domain-only
      identifier is possible metadata and cannot reveal. Include `www.`, `m.`,
      and `mobile.` label differences so current host-normalization prefix removal
      cannot become fill authorization. Dart tests consume same
      `origin_canonicalization_v1.json` and assert every case; no duplicated Dart
      expected-value table.
      Evidence: `test/.../browser_exact_origin_test.dart` reads the same fixture
      path; case `www./m./mobile. label stripping cannot become fill
      authorization`. Mutation A1-M1.
- [x] **A010** Harden `queryCredentials` overlay mode to return bounded metadata
      only (`entryId`, `title`, `displayService`, exact/possible classification,
      fill eligibility) plus current database/cache/bridge binding. No username/
      password. Echo canonical target and strict policy so background can reject
      old-host downgrade. Snapshot tuple, then re-read/compare immediately before
      response; concurrent republish returns `stale_session`.
      Evidence: `_overlayQueryCredentialsResponse` snapshots the binding, then
      re-reads through `_overlayBindingIsStillCurrent` before answering. Test
      `a republish during the query returns stale_session`.
- [x] **A011** Harden `revealForFill` origin-bound path in
      `tool/native_host_protocol.dart`: remove domain/host fallback, require exact
      normalized URL origin, exact entry/database/cacheGeneration/
      bridgeGeneration/policy, and current bridge. Add dedicated exact-origin
      helper; do not reuse current prefix-stripping host matcher. Any binding
      mismatch returns `stale_session` before app request.
      Evidence: `isExactOriginAuthorized` is a dedicated helper, documented as
      deliberately distinct from the prefix-stripping
      `DesktopBrowserAutofillMetadataMapper.isRevealAuthorizedOrigin`. Tests
      `a domain-only entry can never reveal` and
      `${mismatch} mismatch is stale_session before the app`.
      Mutations A1-M1, A1-M2.
- [x] **A012** Apply same exact-origin authorization in
      `desktop_browser_autofill_reveal_bridge_service.dart`; host check and app
      bridge check must both pass for expected database/cache/bridge binding. App
      checks under one session epoch before lookup and response, then echoes binding.
      Native host re-reads cache/descriptor after bridge response and verifies it.
      Add tests for host-only denial and stale binding before secret response.
      Evidence: `/overlay-reveal` reads the whole session under one `_sessionEpoch`
      taken at entry and re-checks it before responding; the host re-verifies via
      `_overlayBindingIsStillCurrent` after the bridge answers. Mutation A1-M3.
- [x] **A013** Preserve current framing limits, response id/version checks,
      2/3-second bridge/background timeouts, direct loopback, bearer auth, redacted
      errors, and clear-on-lock/database-change behavior. Add fake delayed bridge
      regression for vault A → B using same UUID/origin; old request/response must
      be `stale_session`. Add no secret logging.
      Evidence: `_revealBridgeTimeout` is still 2 s and `NATIVE_TIMEOUT_MS` still
      3000; loopback + bearer + redacted error table unchanged. Tests
      `a bridge restart invalidates an older grant`,
      `a vault republish after the app answered is stale_session`,
      `the native host persists and logs nothing`.
- [x] **A014** Update current popup fill result eligibility/labels if stricter
      origin semantics would otherwise present domain-only entries as fillable.
      Evidence: `popup.js` derives `__fillable = fillAvailable &&
      r.fillEligible !== false` and drops the Fill button on a strong row the
      reveal policy refuses. Test
      `a host-level strong match the reveal policy would refuse is not fillable`.

**Gate A1**: targeted native/reveal tests pass. Old host lacking capability must
produce `unsupported_capability`, never host-only fallback.

## Slice A2 — manifest, opt-in, registration, revocation

- [x] **A015** Update `desktop/browser_extension/manifest.json` only as follows:
      add `storage`; add
      `"optional_host_permissions": ["http://*/*", "https://*/*"]`. Keep MV3,
      `activeTab`, `nativeMessaging`, `scripting`. Add no `host_permissions`,
      static `content_scripts`, `<all_urls>`, `tabs`, `webNavigation`, clipboard,
      or remote code.
      Evidence: manifest terminal state matches exactly; test
      `A015: manifest declares optional HTTP(S) hosts and nothing broader`.
      Deviation of record: `storage` was already granted since spec 006 (see
      `spec.md` §Current baseline), so the only net manifest change this task made
      was `optional_host_permissions`.
- [x] **A016** Implement `overlayConfigV1` from `data-model.md`: sorted unique
      exact origins + revision only. Off by default. Enforce limits and migrate
      invalid/missing state to disabled.
      Evidence: `validateOverlayConfig` / `loadOverlayConfigOrEmpty` in
      `overlay_security.js`; six `A016:` cases in `overlay_lifecycle.test.js`.
      Mutation A2-M13.
- [x] **A017** Add popup **Show the overlay on this site** control. Compute exact
      active-tab HTTP(S) origin; request one derived optional host pattern only
      from explicit popup user gesture; persist only after grant. Show unsupported,
      denied, enabled, disabled, and reconciliation states.
      Evidence: `popup.js` §"009 A017" plus `computeSiteControlState`; three
      `A017:` cases. The gesture-bound pending-intent continuation that makes the
      first grant survive a popup teardown landed later in #77 and is pinned by
      `test/overlay_enable_intent.test.js` (mutations A2-M17, A2-M18, A2-M19).
- [x] **A018** Register `content_overlay.js` dynamically in isolated world at
      `document_idle`, including frames where browser allows. Registration match
      is browser permission pattern; bootstrap exact-origin check keeps other
      ports inert. Registration affects future documents, so after grant also
      inject current tab with `chrome.scripting.executeScript({allFrames: true})`;
      make startup idempotent and attach listeners only after bootstrap approval.
      Evidence: `registrationForPattern` emits `runAt: document_idle`,
      `allFrames: true`, `world: ISOLATED`; enable also calls
      `scripting.executeScript`. Eight `A018:` cases. Mutations A2-M4, A2-M14
      (A2-M14 is a declared equivalent mutant, expectedKills 0).
- [x] **A019** Implement crash-consistent disable exactly: first atomically replace
      durable `overlayConfigV1` with target origin removed and revision incremented;
      await successful write/readback. Only afterward clear grants, broadcast
      teardown, unregister unused dynamic script, then remove unused optional
      permission. No cleanup side effect starts if durable commit fails. Derive
      sharing from committed origins; test two ports sharing one pattern.
      Evidence: `DISABLE_PHASES` D1–D5 with the durable commit as D1 and a
      readback before any cleanup; nine `A019:` cases including
      `disabling one port keeps the pattern the other port still needs`.
      Mutations A2-M1, A2-M5, A2-M6, A2-M9, A2-M16.
- [x] **A020** Implement fail-closed reconciliation before serving messages on
      every worker cold start, plus install/startup, popup open, and permission
      changes: validate durable config (invalid/missing = zero enabled), start with
      no grants, then reconcile permissions, registrations, and live teardown.
      Already-injected instance remains inert until approved bootstrap.
      Evidence: nine `A020:` cases — eight in `overlay_lifecycle.test.js`, one in
      `test/overlay_permission_race.test.js`.
      Mutations A2-M3, A2-M7, A2-M8, A2-M10, A2-M12, A2-M15.
- [x] **A021** Add deterministic crash injection after each disable phase: durable
      commit, grant invalidation, active-frame teardown, script unregister, and
      permission removal. Restart worker after each fault and assert identical
      disabled terminal state. Also test shared-pattern retention and unreachable
      injected script: JS cannot be unloaded, but durable revision denies every
      request immediately and reconciliation completes cleanup.
      Evidence: `test/overlay_crash_consistency.test.js`, eight `A021:` cases
      covering a fault after each of D1–D5, shared-pattern retention, and the
      unreachable injected document. Mutation A2-M11 is a declared equivalent
      mutant (expectedKills 0).

**Gate A2**: fresh install grants/injects nothing; grant and revoke behavior is
automated where possible and manually checked in Chrome.

## Slice A3 — background trust paths and focus grants

- [x] **A022** Refactor `background.js` into explicit extension-page and content
      route allowlists. Preserve current popup routes under extension-page sender
      validator. Unknown sender/type/shape fails deterministically.
      Refactor of record: the two allowlists no longer live *in* `background.js`.
      A028+ split the worker into `overlay_routes.js`, and the property now lives
      there as `CONTENT_ROUTES` / `EXTENSION_PAGE_ROUTES` (with the preserved popup
      routes in `LEGACY_ROUTES`), driven by the `OverlayRouter` class;
      `background.js` only constructs it and hands `onMessage` straight to it.
      Evidence: seven `A022:` cases in `test/overlay_routes.test.js`.
      Mutations A3-M1, A3-M14.
- [x] **A023** For content bootstrap/matches/fill, derive authoritative frame
      origin from `sender.url`; validate tab id, frame id, optional document id,
      top context, exact stored origin, permission, and revision before native I/O.
      Evidence: `A023:` and `A023/SR-7:` cases in `test/overlay_routes.test.js`,
      including the durable revision floor added with A3-M9/A3-M16.
      Mutations A3-M2, A3-M9, A3-M10, A3-M15, A3-M16.
- [x] **A024** Issue random short-lived fill token only after exact-origin metadata
      query succeeds. Bind per `data-model.md`; include fill-eligible entry ids
      and exact database/cache/bridge generation only; bound/evict worker map;
      never persist token or binding.
      Evidence: eleven `A024:` cases, including
      `the token is never written to durable storage` and
      `the token map is bounded and evicts the oldest grant`.
      Mutations A3-M4, A3-M8.
- [x] **A025** Consume token on explicit fill before accepting replay. Revalidate
      sender, capability, and message/grant binding, then forward sender-derived
      exact origin plus expected database/cache/bridge values to native host.
      Validate echoed success binding before forwarding secret. Never forward body
      URL as origin authority.
      Evidence: nine `A025:` cases, including
      `a success whose echoed binding drifted does not forward the secret` and
      `vault A -> B rejects the old token without revealing the B secret`.
      Mutations A3-M3, A3-M5, A3-M6.
- [x] **A026** Map timeout, no host, app locked, unsupported capability, disabled,
      unsupported frame, invalid request, forbidden, and stale session to stable
      non-sensitive error codes. Do not log messages/native responses.
      Evidence: `PUBLIC_ERROR_CODES` in `overlay_routes.js` carries all nine plus
      an `internal_error` fail-closed default; six `A026:` cases, including
      `the worker logs neither the message nor the native response`.
      Mutations A3-M11, A3-M12, A3-M13.
- [x] **A027** Confirm MV3 worker restart invalidates grants and next request
      recovers through fresh metadata query; no reconnect loop or durable token.
      New status/query tuple eagerly clears older grants; vault/cache/bridge
      mismatch still fails natively if worker has not observed republish.
      Evidence: seven `A027:` cases, including
      `an MV3 worker restart invalidates every grant` and
      `a binding the worker never observed still fails at the native host`.
      Mutation A3-M7.

**Gate A3**: JS harness covers sender validation, message shape, stale response,
teardown, origin/port/scheme, and frame behavior before visual UI work.

## Slice A4 — metadata overlay and explicit fill

- [x] **A028** Implement eligible field detection in `content_overlay.js`: visible,
      enabled, writable password input; username/email autocomplete input only
      with associated eligible password field. New focus tears down old session
      and creates cryptographic nonce.
      Because this task creates the file, it must also register it in the two
      places that enumerate runtime files explicitly, in the same commit:
      1. add `node --check desktop/browser_extension/content_overlay.js` to the
         `Syntax check extension sources` step of the `extension-tests` job in
         `.github/workflows/pr.yml`, where it is currently omitted on purpose
         because the file does not exist yet;
      2. add it to the `zip` allowlist in
         `desktop/browser_extension/package_extension.sh` (see A042).
      Neither is a glob, so neither fails on its own if this is forgotten.
- [x] **A029** Render closed-shadow metadata overlay only after successful
      bootstrap/matches response for current nonce. Rows expose title + display
      service only. No username/password in text, attributes, dataset, comments,
      globals, style, accessible names, or state object.
- [x] **A030** Implement states: loading, exact matches, possible/no fillable
      matches, no matches, locked, native host unavailable/timeout, unsupported
      frame, stale/retry. Slice A Generate is absent/disabled with honest app text.
- [x] **A031** Implement explicit fill. Verify current focus/nonce/token/origin/
      entry response; use local username/password only; best-effort blank mutable
      response fields; set native input values; dispatch bubbling `input` and
      `change`; never submit; clear references and teardown.
- [x] **A032** Add executable secret-lifetime tests: match shapes and overlay DOM/
      attributes/storage/log capture/globals contain no password; fill input does;
      no test claims GC, heap erasure, performance-timeline invisibility, or
      inaccessible page value.
- [x] **A033** Teardown on Escape, focus replacement/outside blur, pagehide,
      visibility hidden, navigation/unload, anchor disconnect, timeout, disable,
      permission removal, and stale revision. Abort listeners/observers/timers/
      animation frames, remove host, restore ARIA, null local references.
- [x] **A034** Document/test Shadow DOM honestly: `host.shadowRoot === null` is
      style/collision isolation evidence only. Page observation of host layout,
      value, and events remains expected.

## Slice A5 — iframe, accessibility, behavior, visuals

- [x] **A035** Implement frame policy exactly: top and injected same-origin frames
      supported; cross-origin frame only with child origin separately enabled,
      permitted, injected, and sender-validated; otherwise fail closed. Where
      detectable show unsupported state directing manual copy from Custode app.
      Add no extension clipboard path.
- [x] **A036** Add `role=listbox`, `role=option`, `aria-selected`, stable option
      ids, `aria-activedescendant`, anchor combobox expanded state, and
      `role=status aria-live=polite` fallback. Restore original anchor ARIA on
      teardown.
- [x] **A037** Keyboard: arrows move selection; Enter fills current eligible row
      and prevents only that action's default/propagation; Escape dismisses current
      focus session; Tab tears down and passes through. Closed overlay captures no
      page keys.
- [x] **A038** Resolve click-vs-blur race: pointer-down inside overlay preserves
      anchor focus and marks pending action; deferred outside blur cannot remove
      row before click. Controls are `type=button`, outside page forms, and produce
      zero submit events.
- [x] **A039** Test plain and framework-controlled input event delivery, no submit,
      no hidden/read-only fill, anchor removal, scroll/resize, viewport flip/clamp,
      zoom, forced colors, reduced motion, and light/dark mode. Required named DOM
      assertions: `renders every state with metadata-only DOM`, `anchors below,
      flips above, and clamps viewport`, `applies light/dark/forced-colors
      contract`, `exposes listbox/options/live state and restores ARIA`, and
      `teardown removes host/listeners and never submits`.
- [x] **A040** Manual accessibility checks: keyboard-only; Chrome + NVDA on
      Windows; Chrome + VoiceOver on macOS where available. Record closed-shadow
      active-descendant limitation and verify live announcement fallback.

      **Accepted 2026-09-01 without Chrome+NVDA on Windows — product decision,
      no Windows machine available.** Keyboard-only is executed and passed, and
      one VoiceOver/macOS session was executed and found the two defects fixed in
      #81 — that fix has not itself been re-confirmed on the device (below).
      Chrome+NVDA/Windows remains permanent declared debt, not silently dropped:
      re-open this row if a Windows machine becomes available and a regression is
      suspected in the AT path.

      Done — one real VoiceOver session on macOS, with the user driving:
      - The live region announces (`"N suggestions"`) after the M13 fix.
      - Two real defects were found, and they were not cosmetic. Arrow keys moved
        the VoiceOver cursor rather than the overlay selection, and activation was
        outright impossible: `aria-activedescendant` does not cross a **closed**
        shadow root, so the anchor pointed at an id AT could not resolve, and
        Enter fell through to the page as an implicit submit.
      - Fix merged in #81: a generic light-DOM listbox mirroring the shadow rows,
        AT `press` handled on the rows themselves, and an `isTrusted` guard on
        every activation handler so the new light surface cannot be driven by
        page-synthetic events. Pinned by `test/overlay_at_activation.test.js`
        (16 cases) and mutations A6-M1–A6-M4.

      Done — **keyboard-only executed by hand**, 2026-08-25, Chrome 151/macOS,
      real keys through a live CDP trace (not synthetic dispatch): click the
      password field, Enter with no arrow fills the exact-origin suggestion
      (`pw:4 usr:3`, overlay closed, no `SUBMIT!` anywhere in the trace);
      Escape closes with no side effect; Tab closes and advances focus.
      This same session first reproduced a real regression by hand — Enter
      was implicitly submitting the empty form instead of filling — root-caused
      and fixed in #132 (the session listener moved to `document` capture so a
      page/framework listener earlier on the anchor could no longer win the
      `stopImmediatePropagation()` race against the overlay's own
      `preventDefault()`), then this row was re-run clean against the fix.
      The six-case `A037:` automated coverage had already been shown
      insufficient for this row by #121 above; this manual pass sits on top of
      that coverage, not in place of it.

      Also found in this same session, not by the suite, and root-caused as a
      fixture property rather than a defect: Enter on the arrow-selected
      **second** suggestion silently did nothing — no fill, no error. That
      entry is `matchType: "possible"` (a domain-only match, no exact
      scheme/port), so `fillEligible: false` is the correct SR-2 behaviour — a
      domain-only match must never be fillable. Confirmed against the real
      `overlayQueryCredentials` native round trip (the legacy popup channel
      returns a different, non-representative classification for the same
      entries and would have been misleading here). No code change; the test
      vault simply has one exact match and one domain-only match.

      Not done:
      - The #81 fix has **not** been re-confirmed with VoiceOver on the device.
        The behaviour is pinned by the harness, which is not the same evidence as
        a screen reader actually announcing and activating it.
      - Chrome + NVDA on Windows has **never** been run — no Windows machine is
        available. This is a permanent declared debt of this feature, accepted
        as such on 2026-09-01, and it must not be reported as covered.
- [x] **A041** Only after Gates A0–A3 and tasks A028–A040 pass, capture real
      unpacked-extension browser screenshots because Flutter goldens/widget tests
      do not render this DOM.
      Canonical acceptance uses one Linux x86_64 OCI digest and exact Chrome for
      Testing build pinned by `visual_environment_v1.json`, including browser/
      archive hashes, locale/timezone, OS/font hashes, color/rendering flags.
      Commit approved PNGs under `screenshots/expected/` and hashes in
      `visual_baselines_v1.sha256`; deterministic recapture writes `actual/` and
      compares decoded pixels + approved hashes. Add inventory test asserting 18
      exact basenames only as supplemental check. Reject mutable/mismatched env and
      unapproved baseline updates. Noncanonical Edge/Windows/macOS rely on A039 DOM/
      geometry assertions plus A040/manual smoke. Security wins over pixel parity.
      Precondition partially unmet, stated honestly: this task is gated on
      "A028–A040 pass" and **A040 is checked only as accepted debt** — its
      Chrome+NVDA/Windows leg was never run. It stays checked because the
      artefact it owns exists and re-verifies independently of A040 — 18 approved
      baselines, hash- and pixel-compared in the pinned canonical container
      (A045: exit 0, 18/18) and inventoried by the three `A041:` cases. What A040
      would add is screen-reader and keyboard evidence, which no screenshot can
      carry either way, so its outcome cannot invalidate these baselines.

## Slice A6 — packaging, README, release checks

- [x] **A042** Update `desktop/browser_extension/package_extension.sh` explicit
      allowlist with `overlay_security.js` and `content_overlay.js` (plus any other
      actual runtime file). Keep `test/`, origin fixture, screenshots, debug hooks,
      visual environment/hash manifests, source maps, and secrets out of ZIP.
      Package listing test rejects them.
      The script lists every packaged file by name in the `zip` invocation; it is
      an allowlist, not a glob. A runtime file that is never added is silently
      left out of the ZIP — `zip` exits 0, the build is green, and the omission
      surfaces only at runtime in the installed extension as a missing script.
      Standing rule for the rest of this feature and after it: any task that adds
      a runtime file to `desktop/browser_extension/` updates this allowlist in the
      same commit. The packaging assertion below must therefore also assert that
      each expected runtime file is *present*, not only that excluded paths are
      absent.
- [x] **A043** Update `desktop/browser_extension/README.md`: permissions and store
      justification; exact-origin opt-in/revoke; port-granularity caveat; dynamic
      injection/teardown; frame/restricted-page limits; worker cold-start recovery;
      exact-origin native capability; secret policy; Chrome/Edge native host setup;
      automated/manual commands; canonical visual environment/baseline verification
      and approval; package contents.
- [x] **A044** Confirm native host templates/installers still contain one exact
      `chrome-extension://<id>/` in `allowed_origins`. Protocol capability does not
      require broader native host registration. Reinstall/restart only when host
      binary/extension id changed.
- [x] **A045** Run the targeted checks that CI does **not** already run. The
      visual verify below became executable with A041 (canonical container run;
      on Apple Silicon use `KEYVAULT_VISUAL_PODMAN_CONNECTION` per the extension
      README) and was re-run then: exit 0, 18/18 baselines verified. The
      `extension-tests` job in `.github/workflows/pr.yml` runs Gate A0
      (`node --test desktop/browser_extension/test/*.test.js`) and `node --check`
      on every extension source — including `content_overlay.js` once A028 adds it
      — on each pull request, so repeating them here would add noise, not
      coverage. They are omitted below for that reason only.

      Not covered by any CI job:

      ```bash
      python3 -m json.tool desktop/browser_extension/manifest.json >/dev/null
      ./desktop/browser_extension/test/run_visual_baselines.sh --verify
      ./desktop/browser_extension/package_extension.sh
      unzip -l desktop/browser_extension/dist/keyvault-browser-extension.zip
      ```

      Covered only partially, so kept:

      ```bash
      # The `analyze` job runs `flutter analyze` across the whole project, which
      # includes `tool/`. Kept as the fast local form: CI reports it only after
      # a PR exists, and this narrows the output to the native host code.
      dart analyze tool

      # The `test` job runs the full suite minus goldens, so these files do
      # execute in CI. Kept because this is the targeted local form and because
      # it names the exact set a reviewer must see pass for this feature; the
      # whole-suite run does not make that set visible.
      flutter test test/tool/native_host_test.dart \
        test/features/password_manager/data/services/desktop_browser_autofill_cache_test.dart \
        test/features/password_manager/data/services/desktop_browser_autofill_reveal_bridge_service_test.dart \
        test/features/password_manager/presentation/coordinators/desktop_browser_autofill_coordinator_test.dart
      ```

- [x] **A046** Manual Chrome/Edge matrix: fresh install, grant/deny, scheme/port
      variants, exact/domain-only match, top/same/cross-origin frames, restricted
      page, app lock, host absent/timeout, worker termination, disable while open,
      crash/restart after every disable phase, navigation/stale native response,
      vault A → B stale token/response with same UUID/origin, keyboard/pointer/AT,
      package reload, and canonical baseline comparison. Edge smoke is not pixel
      authority.

      **Accepted as done with declared debt — see the acceptance note at the end
      of this row.** This task asks for ~16 matrix rows, and it was written against
      the **per-origin** authorization model. Slice C (PR #113) replaced that
      model with a single global switch. That did not invalidate the code, but
      it did invalidate part of the evidence recorded here: three of the nine
      rows once listed as manual passes observed a *granularity* that no longer
      exists. They are re-classified below rather than left standing as passes.

      Row numbers 1–20 are stable and are referenced from `docs/manual-qa.md`;
      Slice C adds rows 21–24. Every row sits in exactly one of the five sets
      below. **(a) is the only set that is current manual coverage.** (a-bis) is
      spent evidence, and (b), (c) and (d) are not manual passes at all.

      **(a) Executed manually, passed, and still valid under Slice C.** Rows
      1 and 5–9 come from one guided session, Chrome 151 / macOS, one machine,
      on the per-origin build; what each of them observed is model-independent,
      so the pass carries over. Row 21 was executed after Slice C landed.
      1. Fresh install — the extension holds nothing: no grant, no registration,
         no injection. Reworded for the new model: a clean profile now shows the
         switch **off** at the `overlayConfigV2` default. The observation is a
         null state, and the null state is identical under both models, so this
         needs no re-run. Automated twin: `criterion 1: fresh install grants
         nothing, registers nothing, injects nothing`.
      5. Worker termination — terminated between phases and recovered.
      6. Disable while the overlay was open. The trigger is now the global
         switch rather than `disableOrigin()`, but what was observed is the
         D1–D5 teardown of an open overlay, and C2 left that order unchanged and
         still pinned by crash injection.
      7. Navigation — teardown observed. (Only the navigation half of the
         "navigation/stale native response" row; see (b) for the other half.)
      8. Package reload from the built ZIP. Honest scope: this observed that the
         packaged ZIP loads and runs. It did **not** exercise an already-injected
         tab surviving the reload — that gap is where #121 came from, and it is
         now automated, not manually covered.
      9. Generate round trip — generate → fill → confirmation banner in the app →
         confirm → entry present in the vault → consistent re-fill.
      21. **v1 → v2 upgrade (Slice C).** Executed and verified on 2026-08-24,
         Chrome 151 / macOS, observed live over CDP on a profile that really
         held a v1 config with enabled origins. Observed: `overlayConfigV1` gone
         from storage; `overlayConfigV2 = {enabled: false, revision: 3,
         version: 2}`; `chrome.permissions.getAll().origins === []`, i.e. the
         residual per-origin grants were revoked rather than inherited; and zero
         content-script registrations. This is `S3-7` in `docs/manual-qa.md`.
         It is the **only** Slice C manual row satisfied so far; rows 22–24 are
         all still due. Automated twins, which this row is the first human
         confirmation of: `A016: a v1 config migrates to disabled even when the
         broad grant is already held` and `A016: migration revokes every
         residual per-origin grant and registration`.

      **(a-bis) Executed manually against the per-origin model, then SUPERSEDED
      by Slice C.** These are spent evidence, not current coverage, and must not
      be counted as manual passes for the shipped model.
      2. Grant/deny — recorded as "opt-in only under an explicit gesture;
         revocation from `chrome://extensions` reconciled back to disabled". The
         gesture requirement and the reconciliation both survive; the
         **granularity** does not. There is no per-site "Turn on" left to click
         and no per-site permission left to revoke, so the observation as
         recorded cannot be reproduced. Carried forward by row 22, not by a
         re-run of this row as written.
      3. Scheme/port variants — recorded as "two independent ports sharing one
         permission pattern, and `https` with a separately granted opt-in". The
         second half has no subject left at all: one grant now covers both
         schemes and there is no separate per-scheme opt-in. Superseded with
         **no** replacement manual row.
         The neighbouring *security* property did **not** expire, and this entry
         must not be read as a loss of coverage: scheme, port and host remain
         separate identities toward the vault, a sibling port is served **as
         itself**, and the permission pattern's port-blindness is precisely why
         the exact-origin check stays mandatory. It is covered automatically, by
         `scheme, port and phishing suffix are the three named inequalities` and
         `permission pattern drops the port, so exact-origin checks stay
         mandatory` in `test/origin_canonicalization.test.js`; `top frame: a tab
         URL differing only by port or scheme is still a mismatch` and `a
         different port in the same host is still a different frame origin` in
         `test/frame_context.test.js`; and `denies a port mismatch on the same
         host` and `denies the upgrade when the port differs` in
         `test/tool/native_host_test.dart`.
      4. Top / same-origin / cross-origin frames — recorded as "the cross-origin
         child first denied, then enabled on its own origin". The "enable this
         child origin" step no longer exists: under the broad grant the child is
         injected as a matter of course. The surviving half — a child binds to
         its own origin and an authorized top never lends it identity — is now
         the default path and is automated (`a cross-origin child works even
         when the top origin is NOT enabled`, `an authorized top never lends its
         identity to a cross-origin child`). Carried forward by row 23.

      **(b) Covered by automation only — never verified by hand.** These rows have
      real evidence, but none of it is a manual observation, and this task asked
      for one:
      10. App lock — `A027: losing the bridge binding clears grants and reports
          locked`; `a locked app (no cache) cannot generate` in
          `test/tool/native_host_test.dart`.
      11. Host absent / timeout — `A026: native error codes map to the stable
          public set` (`no_host`, `timeout`); mutation A3-M11.
      12. Restricted page — non-HTTP(S) schemes rejected by the `scheme-*` fixture
          cases and `content_overlay: a non-canonicalizable document never speaks
          at all`; popup `unsupported` state via `A017`.
      13. Exact vs domain-only match — `a domain-only entry can never reveal` and
          `revealForFill denies possible/manual non-exact match`; mutation A1-M2.
      14. Crash/restart after every disable phase — the eight `A021:` cases in
          `test/overlay_crash_consistency.test.js`, one fault per D1–D5.
      15. Stale native response — `A025: a success whose echoed binding drifted
          does not forward the secret`; `a vault republish after the app answered
          is stale_session`; mutation A3-M6.

      **(c) Never executed in any manual form:**
      16. Edge subset — never run, on any row. Slice C grew this row rather than
          shrinking it: Edge now also owes rows 21–24, not just the Slice A
          matrix. `S3-8` in `docs/manual-qa.md`.
      17. Vault A → B with the same entry UUID and origin — one machine, one
          vault. Automated only: `REGRESSION vault A -> B` in
          `test/focus_grant.test.js`, `A025: vault A -> B rejects the old token`,
          and the native-host regression.
      18. Canonical baseline comparison — the container verify was run under A045
          (exit 0, 18/18), which is the automated path. No human compared a
          rendered overlay against an approved baseline.
      19. Keyboard / pointer — automated only: six `A037:` and five `A038:` cases.
          No manual pass. (Same gap as the keyboard-only row of A040.)
      20. AT — deferred to A040, whose Chrome+NVDA/Windows leg is accepted debt.
          Not covered here.

      **(d) New manual rows created by Slice C — all still due.** These did not
      exist before PR #113. None has been executed; row 21 above is the only
      Slice C row that has.
      22. **Single broad prompt under a gesture, macOS.** Two halves.
          **Grant half — done**, 2026-08-25, Chrome 151/macOS: a real trusted
          click on "Turn on" (dispatched via CDP `Input.dispatchMouseEvent`, a
          genuine OS-level gesture, not a synthetic `.click()` — the popup
          silently closed under the untrusted form of this click on the first
          attempt, reproducing the #77 popup-close race live before retrying
          trusted) produced exactly one native prompt, the popup stayed open
          through it, and `chrome.permissions.getAll()` afterward showed both
          patterns granted in one grant: `origins: ["http://*/*",
          "https://*/*"]`. A single `kv-overlay-*` content-script registration
          followed, matching both patterns — not two.
          **Revoke half — still due**: setting site access back from
          `chrome://extensions` must reconcile the switch durably **off**.
          `S3-6` in `docs/manual-qa.md` covers the grant half now confirmed
          twice (smoke + this manual pass); the revoke half still has no
          manual scenario there.
          Automated only today for the revoke half: `A017: a declined prompt
          persists nothing`, `A017: siteState is global — the same answer
          whatever tab is open`, and `A020: a permission revoked outside the
          popup durably disables the overlay`.
          **Re-attempted, 2026-08-25, different machine, blocked before
          either half could be re-observed** — see `S3-6` in
          `docs/manual-qa.md` for the full account. That machine's Chrome
          build refuses `--load-extension` outright (enterprise policy;
          worked around with CDP `Extensions.loadUnpacked`), and — the actual
          blocker — its native `chrome.permissions.request()` prompt is not a
          CDP-visible target and cannot be accepted without macOS Accessibility
          or Screen Recording access, neither of which is grantable
          non-interactively in that sandbox. A real trusted click (CDP
          `Input.dispatchMouseEvent`) on "Turn on" reliably invoked
          `chrome.permissions.request()` (the popup stayed pending rather than
          flipping to "denied"), so nothing here contradicts the grant-half
          evidence above; it simply could not be re-confirmed or extended to
          the revoke half this time. The revoke half therefore remains due, as
          recorded immediately above and unchanged by this session.
      23. **An `http(s)` iframe inside a top document with no canonicalizable
          origin** (`file://`, `view-source:`, `data:`, the PDF viewer) must
          present the **unsupported** state. Slice C made this case *more*
          reachable, not less: the broad grant injects the child where the
          per-origin model never would have.

          Done — 2026-08-25, Chrome 151/macOS, the third half this row exists
          for: **reachability in a real browser**. A `file://` page hosting an
          `<iframe src="http://localhost:8000/">` was loaded directly (not
          through the local server); the extension's isolated world was
          confirmed injected into the child frame (`Runtime.evaluate` in that
          frame's own context); a real bootstrap round trip to the background
          returned `{enabled: true, frameSupport: "unsupported", topOrigin:
          null}` — the classifier correctly refused to derive an identity from
          a `file://` top; and on real focus of the password field inside that
          iframe, the closed-shadow overlay rendered the honest hint, piercing
          the shadow root via CDP DOM confirmed the exact text: *"The overlay
          is not available in this frame. Copy your login from the Custode
          app."*, an empty suggestion list, and a disabled Generate control
          ("Open Custode to generate a password."). No `requestMatches` or
          `fill` message was ever sent from that frame.
          **Correction to `docs/manual-qa.md` S3-12 made alongside this**: its
          steps say "No overlay appears in the iframe" — that undersells what
          actually renders; a hint overlay DOES appear, and its content is
          exactly the fail-safe message above, not a fillable one. The popup
          does not display a distinct literal "unsupported" label either: with
          a `file://` tab active it falls into the ordinary no-canonical-origin
          branch and shows the ordinary "Open an http(s) page…" copy, the same
          text a non-http(s) top-level tab gets — there is no frame-specific
          popup wording to look for.
      24. **Performance / CSP regression now that injection is universal.**
          Under the per-origin model the content script ran only where the user
          had opted in; it now runs in every frame of every `http(s)` page at
          `document_idle`. Nothing has measured the cost of that on heavy pages,
          and nothing has checked a strict-CSP site for console violations or a
          blocked isolated world. This row has **no** automated coverage.

          **Partially executed — not closed.** 2026-08-25, Chrome 151/macOS,
          real network sites, one documented substitution: the popup's own
          broad-permission toggle could not be driven for real on this machine
          (same blocker as row 22's re-attempt above), so this used the same
          throwaway-harness-extension technique
          `test/visual/capture_runner.mjs` already uses for A041 — the
          unmodified production `overlay_security.js` + `content_overlay.js`
          (sha256-verified against the committed files) plus the existing
          test-only `background_stub.js`. That harness declares a *static*
          `content_scripts` entry with no `all_frames` key (default `false`),
          so it injected the **top frame only** and never exercised
          production's `scripting.registerContentScripts` registration with
          `allFrames: true` / `persistAcrossSessions: true`
          (`overlay_lifecycle.js`, `globalRegistration()`). The frame-coverage
          cost this row was written to measure therefore remains unmeasured;
          the CSP and console findings do carry, since `world: "ISOLATED"` is
          the content-script default anyway. Heavy-in-nodes but not frame-rich
          page `en.wikipedia.org/wiki/World_War_II` (16,973 DOM nodes),
          warm-cache comparison: overlay off 293 ms load / 9.37 MB JS heap,
          overlay on 143 ms load / 9.72 MB JS heap — no regression detectable
          above measurement noise, and not conclusive: overlay-on measured ~2x
          faster, so run-to-run variance exceeds the effect being sought; n=1
          per condition, no CPU/rendering/frame metrics collected. Zero
          console/log/exception events. Strict-CSP site
          `github.com/login` (`content-security-policy: default-src 'none';
          ...; script-src github.githubassets.com; ...`): zero CSP violations,
          zero console/log/exception events, and focusing the page's real
          `#password` field mounted the real overlay — piercing the closed
          shadow root via CDP confirmed the live text `"2 Custode
          suggestions"` and `"Open Custode to generate a password."`,
          screenshot-verified rendered under GitHub's own field. The two
          suggestions are the harness's synthetic fixture data, not real vault
          data — no live app/vault was involved. Two ordinary sites
          (`en.wikipedia.org`, `news.ycombinator.com`) logged nothing, matching
          a static-source finding: `content_overlay.js` and
          `overlay_security.js` contain zero `console.*` calls in the
          committed source. This is `S3-13` in `docs/manual-qa.md`.

      **Accepted 2026-09-01 as done — product decision, remaining rows are
      declared debt rather than blockers.** Rows 1, 5-9, 21-23 are executed
      manual passes. Rows 2-4 are superseded by the Slice C model change with
      no replacement manual scenario possible. Rows 10-15, 17-19 have only
      automated coverage; row 16 (full Edge matrix) and row 18's human baseline
      comparison were never run; row 22's revoke-half and row 24's real
      `allFrames: true` perf measurement remain unexecuted. Row 20 (AT) tracks
      A040's own accepted Windows/NVDA gap. None of this is silently dropped —
      re-open specific rows if hardware becomes available or a regression is
      suspected in the affected area.

**Slice A — development complete.** All
automated security/protocol checks pass. Re-measured on this branch, after
Slices B and C and the #121 fix: `node --test
desktop/browser_extension/test/*.test.js` — 437 passing; `node
tool/mutation_runner.mjs --check` — exit 0 over 112 mutations, the two
zero-expectation entries (A2-M11, A2-M14) being declared equivalent mutants.
(The Slice A figures were 370 and 83; the growth is later slices, not a
re-scoping of these tasks.) A001–A039 and A041–A045 are verified against the
code and pinned by tests and/or mutations.

The permission sentence that stood here — "no broad always-on permission;
explicit exact-origin fill only" — is now only half true and is corrected rather
than deleted: Slice C **does** take a broad optional host grant, under one
explicit gesture. What did not change is the second half: fill is still bound to
the frame's own canonicalized exact origin, and a domain-only or non-exact match
can never reveal.

Still open, and deliberately not closed here:

- **A040** — keyboard-only (this task's own first row) is now done, 2026-08-25;
  see this task's body above. Still due: VoiceOver re-confirmation of the #81
  fix on the device, and Chrome + NVDA on Windows. NVDA is a permanent declared
  debt: no Windows machine.
- **A046** — set (c), i.e. the Edge subset and a manual vault A → B pass, plus
  row 22's revoke half (re-attempted 2026-08-25 on a different machine, still
  blocked — see that row's detail and `S3-6` in `docs/manual-qa.md`), plus
  row 24's frame-coverage half: a heavy **frame-rich** page injected with
  production's `allFrames: true` dynamic registration. Row 24's 2026-08-25 run
  reached the top frame only, so it counts as partially executed, not closed.
  Row 21, row 22's grant half, and row 23 are now executed. Rows 2, 3 and 4
  are spent evidence, not debt: 2 and 4 are carried forward by rows 22 and 23
  above, and 3 needs no replacement because its security half is automated.

Both are manual-verification debt over code that is otherwise implemented and
automatically pinned. Neither is a reason to reopen development, and neither may
be reported as done.

## Slice B0 — app contracts (blocked until Slice A development completed; no extension Generate yet)

- [x] **B001** After Slice A acceptance, define global non-secret
      `GeneratorSettingsSnapshot` schema v1/revision and app-owned
      `PasswordGeneratorSettingsRepository`; implement with existing
      `SharedPreferences` under `password_generator_settings_v1`, registered in
      `password_manager_data_di.dart`. First install persists length 16 and all
      four sets enabled. Extension never receives/persists settings. Reuse
      `PasswordGeneratorService`; dialog-local defaults are migration baseline only.
- [x] **B002** Implement/test repository and app UI semantics: read/save/watch;
      atomic validated Apply/Save; Cancel no-op; explicit Reset commits defaults;
      known-version migration; missing first-install; corrupt JSON/type/range/no-set
      fallback to persisted defaults with redacted code; unknown future version
      defaults in memory without overwrite until explicit reset; failed write keeps
      last snapshot/no event; global UI consumers update once; generation snapshots
      latest committed revision. Clean open UI follows updates; dirty drafts retain
      edits and stale-revision Apply is rejected until reload/reapply. Test no
      native/extension settings override.
- [x] **B003** Define separate in-memory `PendingGeneratedEntry` with app/database/
      cache/bridge generation, settings revision, exact-origin ownership, opaque
      id, created/expiry (`<= 5 minutes`), and pending/consumed/rejected/expired
      transitions. Do not reuse disk-backed `DesktopBrowserAutofillPendingAssociation`.
- [x] **B004** Add tests first for generate, consume, reject, expiry, bounded
      pending set, clear-on-lock, database switch, vault close, reveal bridge stop,
      and app exit. Assert no generated secret reaches cache, descriptor, pending
      association file, or logs. Verify reference/record removal without claiming
      deterministic zeroization or garbage-collection timing.
- [x] **B005** Connect pending record to normal app new-entry/save confirmation.
      App owns vault mutation; page/extension cannot auto-save.

**Gate B0**: Slice A development is complete — which is what unblocked B0. The
two open manual rows in the Slice A gate above (A040, A046) are verification
debt and were not treated as blocking B. Settings repository/UI and
pending-generation lifecycle are explicit and tested in app. Otherwise stop; Generate remains
unavailable. Run:

```bash
flutter test \
  test/features/password_manager/data/repositories/shared_preferences_password_generator_settings_repository_test.dart \
  test/features/password_manager/data/services/desktop_browser_pending_generation_service_test.dart \
  test/features/password_manager/presentation/screens/vault/password_generator_settings_test.dart
```

## Slice B1 — native generation capability

- [x] **B006** Add authenticated app bridge `/generate-pending` only after B0.
      Validate loopback bearer, database, unlock state, exact origin, bounds/rate,
      expected cache/bridge generation, and latest committed app settings. Return
      password + pending id + expiry + echoed binding/settings revision once.
- [x] **B007** Add native protocol `generatePendingEntry` and advertise
      `generatePendingEntryV1` only when app endpoint/contract is available. Old
      peer returns unsupported capability.
- [x] **B008** Add native tests for malformed request/response, origin scheme/port,
      locked/database mismatch, timeout, response size, capability negotiation,
      cache/bridge generation mismatch (`stale_session`), settings ownership/
      revision, expiry metadata, and no native-host persistence/logging.
- [x] **B009** Ensure coordinator lock/database/close paths stop endpoint and clear
      pending generated secrets before descriptor removal completes.

## Slice B2 — explicit Generate UI

- [x] **B010** Add Generate row only when capability exists. Request requires
      current sender-bound focus nonce/token and exact origin; no settings payload.
- [x] **B011** On explicit click/Enter, nonce-check response, fill generated secret
      once, best-effort clear extension references, store neither password nor
      pending id, never submit, teardown.
- [x] **B012** Test stale/late/replayed generation, disable/navigation during
      request, lock/expiry, no extension storage/DOM/log/global secret, and app
      pending ownership/cleanup.
- [x] **B013** Update package README/UI copy to state app ownership, expiry, and
      save confirmation. Do not claim extension saves or remembers generated
      password.

**Slice B done.** B0/B1/B2 gates pass; B001–B013 are implemented and tested. No
fallback generation in extension, native host, or default settings. B005 needed a
second pass — see the Post-QA fixes below — because the original landing wired the
pending record to no production caller.

## Post-QA fixes

Defects found by the manual sessions behind A040 and A046, after the slices they
belong to had already been merged. Recorded here because each one is evidence
that the automated gates alone did not catch it.

- **#70 + #72** — TCC on macOS Sequoia: the browser autofill store moved to a
  Team-ID-prefixed group container, and the native host now registers group
  membership through `containerURL` *before* any store I/O.
- **#61** — the native host binary was missing the hardened-runtime entitlement.
- **#71** — the master-password fallback was unreachable from the biometric gate.
- **#73** — pending-generation confirmation banner: B005 was structurally
  incomplete and had zero production callers.
- **#75** — overlay restyle, a real cross-origin iframe hint, and the live region.
- **#77** — gesture-bound pending intent so the very first Allow completes the
  enable.
- **#81** — AT activation (light listbox + row `press`) and an `isTrusted` guard
  on every activation handler.
- **#121** — an orphaned content script (extension reloaded under an
  already-injected tab) died silently on the next `chrome.*` access, which read
  to the user as a broken keyboard. Every `chrome.*` site is now behind a
  liveness probe, and the exit latches and leaves an honest tombstone instead of
  disappearing. Found in live QA, after Slice C; it is the reason A046 row 8's
  scope is stated narrowly above.

## Slice C — one global switch replaces the per-origin opt-in

Model change, not a bug fix. The per-site "Turn on" click was unusable in
practice, so the durable opt-in became a single boolean and the popup asks once
for the broad optional host permission. See the Slice C section of `spec.md` for
the reason and for the full list of what did NOT change.

The A0–A3 tasks above stay ticked: they were executed as written, against the
per-origin model that shipped. Nothing below rewrites them.

- [x] **C1** — `overlayConfigV2 {version, revision, enabled}` under a new
  storage key, with the strict fail-closed parser as the migration gate. The
  revision floor key is deliberately not renamed, so monotonicity holds across
  the version boundary. A v1 value — including one with origins enabled, and
  including one whose broad grant is already held — migrates to DISABLED, and
  reconciliation revokes the residual per-origin permissions and registrations
  and deletes the stale key.
- [x] **C2** — `enable()`/`disable()` replace `enableOrigin()`/`disableOrigin()`.
  One content-script registration over `http(s)://*/*`, isolated world,
  `allFrames`, `document_idle`. Reconcile verifies the BROAD grant as a set and
  durably disables when either pattern is missing. The D1–D5 disable order is
  unchanged and still pinned by crash injection.
- [x] **C3** — one global toggle in the popup, with copy that states the size of
  the grant, why it is needed, and what it does not imply. States: off, on,
  denied, unsupported. The off switch stays reachable from pages the overlay
  cannot run on.
- [x] **C4** — the content bootstrap authorizes on the global flag and still
  canonicalizes its own exact origin for the reveal binding. The A035 frame
  policy is KEPT: an http(s) child frame inside a tab whose top document has no
  canonicalizable origin (`file://`, `view-source:`, `data:`, PDF viewer) is
  still classified unsupported, and the broad grant makes that case more common
  rather than unreachable. Reachability was demonstrated, not assumed, and is
  now pinned by an executable test.
- [x] **C5** — mutation table migrated. Eight rows rewritten with an explicit
  verdict each (six ADAPTED, two SUBSTITUTED), seven new `C-M*` rows for the
  invariants Slice C creates, and the retired per-origin properties recorded
  with the reason they have no subject left. Every kill count re-measured.
- [x] **C6** — extension README permission table and store justification
  rewritten for the broad grant; `spec.md`, `tasks.md` and `data-model.md`
  amended with Slice C sections that supersede the per-origin model without
  rewriting the history of the slices that built it.
