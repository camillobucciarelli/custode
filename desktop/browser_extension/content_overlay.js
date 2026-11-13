// 009 Slice A4/A5 — content-script bootstrap + metadata overlay + explicit fill.
//
// Slice A2 shipped the guarded bootstrap handshake below; Slice A4 (A028–A034)
// added everything that runs AFTER approval: eligible-field detection, the
// closed-shadow metadata overlay, its states, and the explicit fill path.
// Slice A5 (A035–A039) adds the frame policy surface (unsupported-frame
// states that direct manual copy from the app — never a clipboard API),
// listbox/combobox ARIA with live fallback, the keyboard contract, the
// click-vs-blur pending-action protocol, and real anchor geometry
// (flip above / viewport clamp / scroll + resize tracking).
//
// This file is registered together with `overlay_security.js`
// (see CONTENT_SCRIPT_FILES in overlay_lifecycle.js) so the SR-2 canonical
// origin rule is the shipped one, not a second copy living in the page world.
//
// SHARED-SCOPE RULE (PR #54): both files are injected into ONE isolated-world
// global scope. Every binding in this file lives inside the IIFE; the only
// global this file touches is the non-secret bootstrap guard.
//
// SR-6 / A034 — what the closed shadow root does and does not do:
// `host.shadowRoot === null` for page code is STYLE/COLLISION ISOLATION ONLY.
// The page can still observe the host's insertion/removal, its layout, the
// filled input values, and the bubbling `input`/`change` events we dispatch.
// None of that is claimed to be hidden. Security rests on sender validation,
// exact origin, the one-shot fill token, app unlock, and explicit user action.

"use strict";

(() => {
  const security = globalThis.CustodeOverlaySecurity;
  if (!security) return;

  // Idempotent startup: the browser can run the registered script and an
  // explicit `executeScript` injection against the same document (that is the
  // normal case right after a grant). The guard lives in the isolated world
  // and is non-secret.
  //
  // WHERE IT IS RELEASED, exactly — this extension registers and injects its
  // content script dynamically and ships no `content_scripts` manifest block,
  // so a guard left set is the difference between a tab a new worker can
  // re-serve and a tab that is dead until the user reloads:
  //   * an origin that cannot be canonicalized, and every bootstrap that is
  //     not an explicit approval (including a dead worker) — released below;
  //   * a revalidation that comes back unapproved — released;
  //   * an instance evaluated into an ALREADY-orphaned world — released:
  //     nothing was built and nothing was shown;
  //   * the orphan exit (goInert) — released ONLY when it left no tombstone.
  //     A tombstone on screen has told the user to reload, so a second overlay
  //     must not mount beside it and contradict the notice.
  // It is NOT released by ordinary session teardown, which ends a focus
  // session and leaves this instance live and serving.
  const GUARD = "__keyVaultOverlayBootstrapV1";
  if (globalThis[GUARD] === true) return;
  globalThis[GUARD] = true;

  const clearGuard = () => {
    globalThis[GUARD] = false;
  };

  /**
   * MV3 ORPHANED INSTANCE detection (009 QA, measured live via CDP).
   *
   * When the extension is reloaded, updated, or disabled while a page stays
   * open, the content-script instance already injected into that page is
   * ORPHANED: Chrome tears the API bridge out from under it. `chrome.runtime`
   * reads back `undefined` (and any handle that does survive has no `id`), so
   * EVERY `chrome.runtime.*` access from an orphan throws
   * `TypeError: Cannot read properties of undefined (reading 'sendMessage')`.
   *
   * This is why the `chrome.runtime.lastError` branch inside each response
   * callback is not enough on its own: it lives INSIDE a callback that an
   * orphan can never reach, because the `sendMessage` access that would
   * schedule it throws first. The QA trace was exactly that — Enter on the
   * Generate row, an unhandled TypeError, and an overlay that died in silence.
   *
   * `chrome.runtime?.id == null` is the canonical probe and is true for both
   * observed shapes (`runtime` undefined, `runtime.id` undefined). `chrome`
   * itself is also probed: it always exists in a live isolated world, so this
   * only costs a `typeof` and removes the last way in.
   *
   * ALL 14 `chrome.*` call sites in this file are behind this probe — the six
   * `sendMessage`/`lastError` pairs (matches, fill, generate), the bootstrap
   * pair, the revalidation pair, three `onMessage` (un)registrations, and the
   * best-effort `removeListener` in goInert, which additionally tests
   * callability because the probe and "the API still works" are not the same
   * question in the `id`-undefined shape. Add a 15th and it needs a guard too;
   * the count is stated so that omission is visible in review.
   */
  const extensionContextLost = () =>
    typeof chrome === "undefined" || chrome.runtime?.id == null;

  // Canonicalize THIS frame's own exact origin.
  //
  // SLICE C did not weaken this and could not: the global switch decides only
  // WHERE the script is injected. What the overlay is allowed to SHOW is still
  // decided per exact origin — the worker re-derives the authoritative origin
  // from `sender.url`, the native query matches on it exactly, and the reveal
  // is bound to it. This value is the frame's claim, checked against the
  // sender-derived one by `validateContentScriptRequest`; a mismatch is
  // refused rather than reconciled.
  //
  // A frame whose origin cannot be canonicalized (`about:blank`, a sandboxed
  // document, a non-http(s) scheme the browser injected anyway) stops here and
  // clears the guard. That path is REACHABLE under the broad grant and stays.
  const origin = security.canonicalOriginOrNull(location.href);
  if (origin === null) {
    clearGuard();
    return;
  }

  const bootstrap = {
    channel: security.CHANNEL,
    version: security.MESSAGE_VERSION,
    type: "bootstrap",
    origin,
  };

  // SR-7: the three frame kinds the policy supports. `unsupported` is a real
  // answer even with the switch on and the broad grant held — the live case
  // is a child frame whose TOP document cannot be canonicalized (an http(s)
  // iframe inside a `file://`, `view-source:`, `data:` or PDF-viewer tab).
  // The broad grant makes that MORE common, not less: such a child used to go
  // uninjected, and now it is injected and must classify honestly.
  //
  // A035: such an instance is not silently inert — it renders the honest
  // unsupported-frame state on eligible focus (directing manual copy from the
  // app) and NEVER queries or fills; the worker refuses
  // `requestMatches`/`fill` for it anyway (defence in depth,
  // `overlay_routes.js` SR-7 gate).
  const SUPPORTED_FRAMES = ["top", "same-origin", "permitted-cross-origin"];

  const approved = (response) =>
    response?.ok === true &&
    response.enabled === true &&
    SUPPORTED_FRAMES.includes(response.frameSupport);

  /** Enabled origin, but a frame the policy cannot serve (A035). */
  const approvedUnsupportedFrame = (response) =>
    response?.ok === true &&
    response.enabled === true &&
    response.frameSupport === "unsupported";

  // =========================================================================
  // A4 — overlay session engine. Nothing below runs before approval.
  // =========================================================================

  // SR-3: the focus session can never outlive the token TTL ceiling.
  const SESSION_TTL_MS = security.LIMITS.TOKEN_TTL_MS;
  const WATCHDOG_MS = 1000;

  // A030 — one honest sentence per state. Error TEXT is a fixed local map
  // keyed by the stable code; the worker's `error.message` is deliberately
  // never rendered, so no upstream component can inject copy into the page.
  const STATE_TEXT = Object.freeze({
    loading: "Loading Custode suggestions…",
    "no-fillable": "Matches exist but cannot be filled here. Open Custode.",
    "no-matches": "No Custode entries for this site.",
    locked: "Open and unlock Custode.",
    no_host: "Custode native host is unavailable.",
    timeout: "Custode did not respond in time.",
    unsupported_frame:
      "The overlay is not available in this frame. Copy your login from the Custode app.",
    // Neutral on purpose: the missing capability can be an old native host OR
    // an old app (B007 advertises generation only when the app declares it).
    unsupported_capability: "Update Custode to use this feature.",
    stale_session: "Custode session changed.",
    // MV3 orphan (see extensionContextLost). Deliberately cause-neutral: a
    // reload, an update and a disable/enable cycle all produce it, and this
    // world cannot tell which. It promises NO automatic retry, because there
    // is none — an orphan has no way back to the worker — and names the one
    // action that actually fixes it.
    extension_lost:
      "This page lost its connection to Custode. Reload the page to use autofill.",
  });

  // B010/B013 — honest copy for both Generate states. The row is ACTIVE only
  // when the worker's matchesResult affirmatively advertises the
  // `generatePendingEntryV1` capability AND carries a one-shot generate
  // token; an old host/app peer keeps the disabled text, which directs the
  // user to the app and never promises in-page generation. The active copy
  // says who owns the save: Custode, after the user confirms there — the
  // extension neither saves nor remembers the generated password.
  const GENERATE_TEXT = "Open Custode to generate a password.";
  const GENERATE_ACTIVE_TEXT =
    "Generate a password — confirm the save in Custode.";

  // Codes that render an A030 state. Anything else — disabled, forbidden,
  // invalid_request, internal_error, an unknown code — is an authorization or
  // contract failure and tears the session down instead of rendering.
  //
  // `extension_lost` is deliberately ABSENT: it is a locally-derived state,
  // never a worker verdict. Listing it here would let a compromised or
  // confused peer push "reload the page" copy into the page at will.
  const RENDERABLE_ERRORS = new Set([
    "locked",
    "no_host",
    "timeout",
    "unsupported_frame",
    "unsupported_capability",
    "stale_session",
  ]);

  /** The single live focus session for this frame, or null. */
  let session = null;
  /** Owns the document/window listeners attached at approval. */
  let instanceAbort = null;
  /**
   * A035 — what the worker said this frame is: "supported" frames run the
   * full query/fill session; "unsupported" frames (enabled origin, refused
   * classification) run display-only sessions that render the unsupported
   * state and never send `requestMatches`/`fill`.
   */
  let instanceMode = "supported";

  // -------------------------------------------------------------------------
  // A028 — eligible field detection.
  // -------------------------------------------------------------------------

  const isVisible = (el) =>
    typeof el.getClientRects === "function" && el.getClientRects().length > 0;

  const isWritablePasswordInput = (el) =>
    el != null &&
    el.tagName === "INPUT" &&
    el.type === "password" &&
    el.disabled !== true &&
    el.readOnly !== true &&
    isVisible(el);

  const hasUsernameAutocomplete = (el) => {
    const tokens = String(el.getAttribute("autocomplete") ?? "")
      .toLowerCase()
      .split(/\s+/);
    return tokens.includes("username") || tokens.includes("email");
  };

  const isUsernameInput = (el) =>
    el != null &&
    el.tagName === "INPUT" &&
    (el.type === "text" || el.type === "email") &&
    el.disabled !== true &&
    el.readOnly !== true &&
    isVisible(el) &&
    hasUsernameAutocomplete(el);

  const formInputs = (el) => {
    const form = el.form;
    if (!form || !form.elements) return [];
    return Array.from(form.elements);
  };

  /**
   * @returns {{fieldKind: "password"|"username", passwordEl, usernameEl}|null}
   *
   * A password field is eligible on its own. A username/email-autocomplete
   * field is eligible ONLY when its form also contains an eligible password
   * field (A028) — a lone email field is not a credential form.
   */
  const classifyField = (el) => {
    if (el == null || typeof el.tagName !== "string") return null;
    if (isWritablePasswordInput(el)) {
      const usernameEl = formInputs(el).find(isUsernameInput) ?? null;
      return { fieldKind: "password", passwordEl: el, usernameEl };
    }
    if (isUsernameInput(el)) {
      const passwordEl = formInputs(el).find(isWritablePasswordInput) ?? null;
      if (passwordEl === null) return null;
      return { fieldKind: "username", passwordEl, usernameEl: el };
    }
    return null;
  };

  /**
   * A035/SR-7 — "where the top frame can detect iframe focus, show an
   * unsupported state directing manual copy from the app". Focus entering an
   * iframe is detected via window `blur` + `document.activeElement` (M7 —
   * the parent never receives `focusin` for a child browsing context). This
   * predicate classifies the active iframe ELEMENT. A frame
   * whose `src` canonicalizes to THIS document's own origin is skipped: a
   * same-origin child carries its own injected instance and renders its own
   * overlay. Everything else — cross-origin, sandboxed, `data:`, srcdoc,
   * unparseable — gets the honest hint only. KNOWN LIMIT (documented, not
   * hidden): this document cannot know whether a cross-origin child's own
   * origin is separately enabled, so a separately-enabled child renders its
   * real overlay inside the frame while this hint also shows; cosmetic only,
   * no authorization is derived from it.
   */
  const isFrameHintTarget = (el) => {
    if (el == null || el.tagName !== "IFRAME") return false;
    const raw = el.getAttribute("src");
    // No src (or blank) is an about:blank frame: no registered script ever
    // runs there, so the honest answer is the hint.
    if (typeof raw !== "string" || raw.trim().length === 0) return true;
    // Resolve like the browser does: a RELATIVE src ("/login", "widget.html",
    // "//host/x") resolves against this document's URL. Canonicalizing the
    // raw attribute instead would read every relative same-origin src as
    // "not my origin" and paint the hint over a frame that already carries
    // its own real overlay.
    let resolved = raw;
    try {
      resolved = new URL(raw, location.href).href;
    } catch (_) {
      // Unresolvable exotic value: keep the raw attribute; the
      // canonicalization below fails it closed into the hint.
    }
    return security.canonicalOriginOrNull(resolved) !== origin;
  };

  // -------------------------------------------------------------------------
  // A033 — teardown. One function, called from every trigger.
  // -------------------------------------------------------------------------

  /**
   * Removes the overlay host, aborts every session listener, stops the
   * watchdog timer, restores the anchor's pre-existing ARIA, and nulls every
   * local reference. Best-effort by design (SR-5): JS strings are immutable,
   * so "clear" means removing reachability, never claiming memory erasure.
   *
   * This session uses no MutationObserver and no requestAnimationFrame; the
   * abortables are exactly: the AbortController-owned listeners and the one
   * watchdog interval. Anchor disconnect and timeout are detected by the
   * watchdog rather than an observer — one timer covers both.
   */
  const teardownSession = ({ keepHost = false } = {}) => {
    if (session === null) return;
    const s = session;
    session = null;
    try {
      s.teardownController.abort();
    } catch (_) {
      // An abort listener throwing must not stop the teardown.
    }
    clearInterval(s.watchdogId);
    if (s.blurTimerId !== 0) clearTimeout(s.blurTimerId);
    s.blurTimerId = 0;
    // M13 — a pending live-region announcement dies with the session.
    if (s.statusTimerId !== 0) clearTimeout(s.statusTimerId);
    s.statusTimerId = 0;
    const anchor = s.anchorEl;
    if (anchor != null) {
      // A036 — restore EVERY ARIA attribute this session touched to exactly
      // its pre-session value (absent stays absent).
      for (const [name, original] of s.savedAria) {
        if (original === null) anchor.removeAttribute(name);
        else anchor.setAttribute(name, original);
      }
    }
    // `keepHost` is used by ONE caller — the MV3 orphan exit (goInert) — which
    // leaves the already-rendered status node on screen as an inert tombstone.
    // Everything that can act is still dropped here; only the node survives.
    if (s.overlayHost != null && !keepHost) s.overlayHost.remove();
    // A040 — the light-DOM fallback listbox dies with the session too. It goes
    // even for a tombstone: an empty listbox whose rows no longer activate is
    // worse for AT than no listbox at all.
    if (s.lightListboxEl != null) s.lightListboxEl.remove();
    s.lightListboxEl = null;
    s.anchorEl = null;
    s.usernameEl = null;
    s.passwordEl = null;
    s.overlayHost = null;
    s.shadowRoot = null;
    s.statusEl = null;
    s.listEl = null;
    s.retryEl = null;
    s.generateEl = null;
    s.items = null;
    s.fillToken = null;
    s.generateToken = null;
    s.sessionBinding = null;
    s.savedAria = null;
  };

  /** Record-once, then set: the FIRST value seen is the one restored. */
  const setAnchorAria = (name, value) => {
    const anchor = session.anchorEl;
    if (!session.savedAria.has(name)) {
      session.savedAria.set(name, anchor.getAttribute(name));
    }
    anchor.setAttribute(name, value);
  };

  /** Record-once, then remove: same restore contract as setAnchorAria. */
  const removeAnchorAria = (name) => {
    const anchor = session.anchorEl;
    if (!session.savedAria.has(name)) {
      session.savedAria.set(name, anchor.getAttribute(name));
    }
    anchor.removeAttribute(name);
  };

  /**
   * A040 — true when `node` lives inside this session's overlay surface: the
   * shadow host (a composed focusin from inside the closed shadow retargets
   * to the host; the fake and some AT paths hand the inner element itself)
   * or the light-DOM fallback listbox. Walks parentNode and, at a shadow
   * root, its `host`.
   */
  const isOverlayNode = (node) => {
    if (session === null || node == null) return false;
    let cur = node;
    while (cur != null) {
      if (cur === session.overlayHost || cur === session.lightListboxEl) {
        return true;
      }
      cur = cur.parentNode ?? cur.host ?? null;
    }
    return false;
  };

  // -------------------------------------------------------------------------
  // A029/A030 — closed-shadow metadata overlay and its states.
  // -------------------------------------------------------------------------

  const clearChildren = (el) => {
    while (el.firstChild) el.firstChild.remove();
  };

  /**
   * M13 — VoiceOver/WebKit only announce a `role=status` live region whose
   * EMPTY element existed in the accessibility tree BEFORE its first content
   * mutation. The region is therefore created empty at overlay mount
   * (buildOverlay) and every text update lands one macrotask later, so AT
   * registers the region first and then observes a content change it will
   * announce. Definitive verification is manual (VoiceOver); this create-
   * empty-then-mutate-later timing pattern is the documented WebKit/VO fix.
   * One timer per session, cancelled by the next write and by teardown.
   */
  const setStatusText = (text) => {
    if (session === null || session.statusEl === null) return;
    const s = session;
    if (s.statusTimerId !== 0) clearTimeout(s.statusTimerId);
    s.statusTimerId = setTimeout(() => {
      s.statusTimerId = 0;
      if (session !== s || s.statusEl === null) return;
      s.statusEl.textContent = text;
    }, 0);
  };

  // A039 — the visual contract, static and local. Light is the base; dark,
  // forced-colors (system colors only, no authored contrast), and reduced
  // motion (no transition) are media-query overrides, so the browser — never
  // this script — decides which applies. Sized to the geometry fallback below.
  //
  // 009 polish — aligned to the app design system (lib/core/theme). Every
  // value below is a verbatim copy of an app token, never a computed one:
  //   surfaces   CustodeColors.light/dark ground  #f9f4ed / #2e2b25
  //   text       AppColors.text #201e1d / neutral100 #f9f4ed (62% secondary)
  //   divider    AppColors.divider rgba(32,30,29,0.16) / 22% neutral100
  //   selection  attentionTint accent-200 #ffe1d0 (+ selectionBorder
  //              accent-400 #f6a06b inset bar); dark accent-800 #643312 with
  //              attentionText accent-200 and accent-300 #ffc6a5 bar
  //   action     KvPillButton: actionFill accent-300 #ffc6a5, actionText
  //              accent-900 #402310, AppRadii.pill 999
  //   link       linkText accent-800 #643312 / accent-300 #ffc6a5 (the
  //              Generate row is an ACTION, visually distinct from matches)
  //   radius     AppRadii.rowNested 16
  //   type       AppTextStyles rowTitle 15/600 · body 13.5/1.45 ·
  //              secondary 12.5/1.4 — system font stack only: no webfont,
  //              no external asset, zero network (CSP).
  //   shadow     tokens.css --shadow-md 0 3px 10px 16% neutral-900
  const OVERLAY_CSS = [
    ".kv-overlay{box-sizing:border-box;width:320px;max-height:240px;overflow-y:auto;",
    "font:400 13.5px/1.45 system-ui,sans-serif;background:#f9f4ed;color:#201e1d;",
    "border:1px solid rgba(32,30,29,0.16);border-radius:16px;",
    "box-shadow:0 3px 10px rgba(46,43,37,0.16);padding:4px 0;",
    "transition:opacity 120ms ease;}",
    ".kv-overlay #kv-status{padding:8px 14px 4px;font-size:12.5px;line-height:1.4;color:#665f53;}",
    ".kv-overlay button{display:block;width:100%;text-align:left;background:inherit;",
    "color:inherit;border:0;font:inherit;padding:7px 14px;cursor:pointer;}",
    ".kv-overlay button:disabled{cursor:default;}",
    '.kv-overlay [role="option"] span{display:block;}',
    '.kv-overlay [role="option"] span:first-child{font-size:15px;font-weight:600;line-height:1.25;}',
    '.kv-overlay [role="option"] span:last-child{font-size:12.5px;line-height:1.4;color:#665f53;}',
    '.kv-overlay [role="option"][aria-selected="true"]{background:#ffe1d0;',
    "box-shadow:inset 2px 0 0 #f6a06b;}",
    ".kv-overlay #kv-retry{display:inline-block;width:auto;margin:6px 14px 10px;padding:6px 14px;",
    "background:#ffc6a5;color:#402310;border-radius:999px;font-size:12.5px;font-weight:600;}",
    ".kv-overlay #kv-generate{border-top:1px solid rgba(32,30,29,0.16);margin-top:4px;",
    "padding:9px 14px 10px;color:#643312;font-weight:600;}",
    '.kv-overlay #kv-generate[aria-selected="true"]{background:#ffe1d0;box-shadow:inset 2px 0 0 #f6a06b;}',
    ".kv-overlay #kv-generate:disabled{color:#665f53;font-weight:400;}",
    "@media (prefers-color-scheme: dark){.kv-overlay{background:#2e2b25;color:#f9f4ed;",
    "border-color:rgba(249,244,237,0.22);}",
    ".kv-overlay #kv-status{color:rgba(249,244,237,0.62);}",
    '.kv-overlay [role="option"] span:last-child{color:rgba(249,244,237,0.62);}',
    '.kv-overlay [role="option"][aria-selected="true"]{background:#643312;color:#ffe1d0;',
    "box-shadow:inset 2px 0 0 #ffc6a5;}",
    ".kv-overlay #kv-generate{border-top-color:rgba(249,244,237,0.22);color:#ffc6a5;}",
    '.kv-overlay #kv-generate[aria-selected="true"]{background:#643312;color:#ffe1d0;box-shadow:inset 2px 0 0 #ffc6a5;}',
    ".kv-overlay #kv-generate:disabled{color:rgba(249,244,237,0.62);}}",
    "@media (forced-colors: active){.kv-overlay{background:Canvas;color:CanvasText;",
    "border-color:CanvasText;box-shadow:none;}",
    '.kv-overlay #kv-status,.kv-overlay [role="option"] span:last-child{color:CanvasText;}',
    '.kv-overlay [role="option"][aria-selected="true"]{background:Highlight;color:HighlightText;box-shadow:none;}',
    ".kv-overlay #kv-retry{background:ButtonFace;color:ButtonText;border:1px solid ButtonText;}",
    ".kv-overlay #kv-generate{color:LinkText;border-top-color:CanvasText;}",
    '.kv-overlay #kv-generate[aria-selected="true"]{background:Highlight;color:HighlightText;box-shadow:none;}',
    ".kv-overlay #kv-generate:disabled{color:GrayText;}}",
    "@media (prefers-reduced-motion: reduce){.kv-overlay{transition:none;}}",
  ].join("");

  // A039 — geometry. `getBoundingClientRect` is viewport-relative, so the
  // host is positioned `fixed` and re-anchored on scroll/resize. When the
  // host cannot be measured yet, the CSS sizes above are the estimate.
  const OVERLAY_FALLBACK_SIZE = Object.freeze({ width: 320, height: 240 });

  const overlaySize = () => {
    const host = session.overlayHost;
    const rect =
      typeof host.getBoundingClientRect === "function"
        ? host.getBoundingClientRect()
        : null;
    return {
      width: rect && rect.width > 0 ? rect.width : OVERLAY_FALLBACK_SIZE.width,
      height: rect && rect.height > 0 ? rect.height : OVERLAY_FALLBACK_SIZE.height,
    };
  };

  /**
   * Anchor below; flip above when the space below is short AND the space
   * above fits; clamp the final box to the viewport either way. Zoom needs no
   * special case: Chrome scales CSS pixels, and both the rects and
   * `innerWidth`/`innerHeight` are already in CSS pixels.
   */
  const updatePosition = () => {
    if (session === null || session.overlayHost === null) return;
    const anchor = session.anchorEl;
    if (anchor == null || typeof anchor.getBoundingClientRect !== "function") return;
    const rect = anchor.getBoundingClientRect();
    if (!rect) return;
    const { width, height } = overlaySize();
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;

    let top = rect.bottom;
    if (rect.bottom + height > viewportHeight && rect.top - height >= 0) {
      top = rect.top - height; // flip above
    }
    top = Math.min(Math.max(top, 0), Math.max(viewportHeight - height, 0));
    const left = Math.min(Math.max(rect.left, 0), Math.max(viewportWidth - width, 0));

    const host = session.overlayHost;
    host.style.position = "fixed";
    host.style.top = `${top}px`;
    host.style.left = `${left}px`;
  };

  /**
   * A038 — a pointer press inside the overlay: keep the anchor focused
   * (prevent the mousedown default) and mark the action pending so a
   * deferred outside blur cannot remove the row before the click lands.
   */
  const markPendingAction = (event) => {
    event.preventDefault();
    if (session === null) return;
    session.pendingAction = true;
    if (session.blurTimerId !== 0) {
      clearTimeout(session.blurTimerId);
      session.blurTimerId = 0;
    }
  };

  const settlePendingAction = () => {
    if (session === null) return;
    session.pendingAction = false;
    if (session.blurTimerId !== 0) {
      clearTimeout(session.blurTimerId);
      session.blurTimerId = 0;
    }
  };

  // A040 — the light-DOM fallback listbox is visually sr-only via the clip
  // pattern: zero rendered pixels (1px box, clipped), still exposed to AT.
  // Never `display:none`/`visibility:hidden` (those hide it from AT too).
  const LIGHT_LISTBOX_STYLE = [
    "position:fixed",
    "top:0",
    "left:0",
    "width:1px",
    "height:1px",
    "margin:-1px",
    "padding:0",
    "border:0",
    "overflow:hidden",
    "clip:rect(0 0 0 0)",
    "clip-path:inset(50%)",
    "white-space:nowrap",
  ].join(";");

  /**
   * A040 — activate the option at `index` from the light fallback listbox
   * (or from a direct AT press on the shadow row of the same index). Routes
   * through the EXACT same one-shot paths as a pointer click on the shadow
   * row: attemptFill / attemptGenerate, token + nonce + teardown identical.
   */
  const activateLightOption = (index) => {
    if (session === null) return;
    const itemCount = session.items === null ? 0 : session.items.length;
    if (session.generateToken !== null && index === itemCount) {
      session.selectedIndex = index;
      updateSelection({ announce: false });
      attemptGenerate();
      return;
    }
    const entry = session.items?.[index];
    if (entry == null || entry.fillEligible !== true) return;
    session.selectedIndex = index;
    updateSelection({ announce: false });
    attemptFill(entry.entryId);
  };

  /** A press delivered to an option element: Enter/Space, click semantics. */
  const isPressKey = (event) => event.key === "Enter" || event.key === " ";

  /**
   * A040 — (re)build the GENERIC light-DOM options. SECURITY INVARIANT: the
   * text and attributes written here are static labels and indices ONLY —
   * never the entry title, displayService, username, or entryId. The light
   * listbox lives in the page DOM, so anything written here is readable by
   * the page; the A032 light-DOM scan enforces this.
   */
  const renderLightOptions = () => {
    if (session === null || session.lightListboxEl === null) return;
    const signal = session.teardownController.signal;
    const listEl = session.lightListboxEl;
    clearChildren(listEl);
    const items = session.items ?? [];
    const count = items.length;
    const addOption = (index, label, enabled, activate) => {
      const opt = document.createElement("button");
      opt.id = `kv-light-option-${index}`;
      opt.setAttribute("type", "button");
      opt.setAttribute("role", "option");
      opt.setAttribute("aria-selected", "false");
      opt.setAttribute("tabindex", "-1");
      opt.textContent = label;
      if (enabled) {
        // A040 SECURITY — the light options live in the PAGE DOM, so page
        // code can getElementById + dispatchEvent a synthetic click at them.
        // Only user-agent-generated events (isTrusted) may activate: a fill
        // without a real user gesture is credential exfiltration. The guard
        // sits on the EVENT HANDLER, the most upstream point — never inside
        // attemptFill/attemptGenerate, which have legitimate internal
        // callers (the anchor keyboard path).
        opt.addEventListener(
          "click",
          (event) => {
            if (event.isTrusted !== true) return;
            activate();
          },
          { signal }
        );
        opt.addEventListener(
          "keydown",
          (event) => {
            if (event.isTrusted !== true) return;
            if (!isPressKey(event)) return;
            event.preventDefault();
            event.stopPropagation();
            activate();
          },
          { signal }
        );
      } else {
        opt.disabled = true;
        opt.setAttribute("disabled", "");
        opt.setAttribute("aria-disabled", "true");
      }
      listEl.appendChild(opt);
    };
    items.forEach((entry, index) => {
      addOption(
        index,
        `Suggestion ${index + 1} of ${count}`,
        entry.fillEligible === true,
        () => activateLightOption(index)
      );
    });
    if (session.generateToken !== null) {
      addOption(count, "Generate a password", true, () =>
        activateLightOption(count)
      );
    }
  };

  const buildOverlay = () => {
    const signal = session.teardownController.signal;
    const host = document.createElement("div");
    // WCAG 3.1.2 — every fixed string this file renders (STATE_TEXT,
    // GENERATE_TEXT, "Try again", "Suggestion N of M", …) is English UI
    // copy, never page content. The host's `lang` inherits into the whole
    // shadow tree (language, like other CSS-inherited properties, is
    // resolved over the FLATTENED tree, so it crosses the shadow boundary):
    // one attribute here covers the live region and every shadow row without
    // needing a second one inside. A host on an Italian-language page would
    // otherwise announce this English text in the page's voice/accent
    // mid-utterance.
    host.setAttribute("lang", "en");
    // SR-6/A034: closed mode. `host.shadowRoot` reads null from page code;
    // that is a collision/style boundary, not invisibility — see file header.
    const shadow = host.attachShadow({ mode: "closed" });

    const styleEl = document.createElement("style");
    styleEl.textContent = OVERLAY_CSS;

    const sectionEl = document.createElement("section");
    sectionEl.setAttribute("class", "kv-overlay");
    sectionEl.setAttribute("aria-label", "Custode suggestions");
    // A038 — pending-action protocol; see markPendingAction. The controls are
    // all `type=button` inside this shadow section, OUTSIDE every page form,
    // so no pointer or keyboard action can ever become a submit.
    sectionEl.addEventListener("mousedown", markPendingAction, { signal });
    sectionEl.addEventListener(
      "click",
      () => {
        settlePendingAction();
      },
      { signal }
    );

    const statusEl = document.createElement("div");
    statusEl.id = "kv-status";
    statusEl.setAttribute("role", "status");
    statusEl.setAttribute("aria-live", "polite");

    const listEl = document.createElement("div");
    listEl.id = "kv-list";
    listEl.setAttribute("role", "listbox");

    const generateEl = document.createElement("button");
    generateEl.id = "kv-generate";
    generateEl.setAttribute("type", "button");
    generateEl.disabled = true;
    generateEl.setAttribute("disabled", "");
    generateEl.setAttribute("aria-disabled", "true");
    generateEl.textContent = GENERATE_TEXT;
    // Inert until a matchesResult advertises the capability with a token;
    // attemptGenerate refuses while `session.generateToken` is null, so a
    // click delivered to the disabled control cannot do anything either.
    // A040 SECURITY — isTrusted guard on every activation handler (see
    // renderLightOptions): only user-agent events may generate.
    generateEl.addEventListener(
      "click",
      (event) => {
        if (event.isTrusted !== true) return;
        attemptGenerate();
      },
      { signal }
    );
    // A040 — direct AT press (keydown form) on the Generate row.
    generateEl.addEventListener(
      "keydown",
      (event) => {
        if (event.isTrusted !== true) return;
        if (!isPressKey(event)) return;
        event.preventDefault();
        event.stopPropagation();
        attemptGenerate();
      },
      { signal }
    );

    sectionEl.appendChild(statusEl);
    sectionEl.appendChild(listEl);
    sectionEl.appendChild(generateEl);
    shadow.appendChild(styleEl);
    shadow.appendChild(sectionEl);

    const parent = document.body ?? document.documentElement;
    parent.appendChild(host);

    if (session.kind === "fill") {
      // A040 — the light-DOM fallback listbox, sibling of the host. VoiceOver
      // cannot reach or actuate the closed-shadow rows through
      // aria-activedescendant (an IDREF never crosses a shadow boundary), so
      // this GENERIC listbox is the AT-activatable surface: indices and
      // static labels only — zero entry metadata in the page DOM.
      const lightListbox = document.createElement("div");
      lightListbox.id = "kv-light-listbox";
      lightListbox.setAttribute("role", "listbox");
      lightListbox.setAttribute("aria-label", "Custode suggestions");
      // WCAG 3.1.2 — this listbox is a SIBLING of the host, not a shadow
      // descendant, so it does NOT inherit `lang` from it; it inherits from
      // the host PAGE instead, which may be any language. Its rows are fixed
      // English strings ("Suggestion N of M", "Generate a password"), so it
      // needs its own explicit lang.
      lightListbox.setAttribute("lang", "en");
      lightListbox.setAttribute("style", LIGHT_LISTBOX_STYLE);
      // Same pending-action protocol as the shadow section (A038): a pointer
      // press here keeps the anchor focused and holds the deferred blur off.
      lightListbox.addEventListener("mousedown", markPendingAction, { signal });
      lightListbox.addEventListener(
        "click",
        () => {
          settlePendingAction();
        },
        { signal }
      );
      parent.appendChild(lightListbox);
      session.lightListboxEl = lightListbox;
      // Same-root IDREFs now exist: point the anchor at the light listbox.
      setAnchorAria("aria-controls", "kv-light-listbox");
    }

    session.overlayHost = host;
    session.shadowRoot = shadow;
    session.statusEl = statusEl;
    session.listEl = listEl;
    session.generateEl = generateEl;

    updatePosition();
    // Re-anchor while the session lives. Scroll is capture-phase so inner
    // scrollable containers reposition too, not only the root scroller.
    document.addEventListener("scroll", updatePosition, { capture: true, signal });
    window.addEventListener("resize", updatePosition, { signal });
    // A drag that starts inside the overlay but ends elsewhere must not leave
    // the pending flag armed forever; mouseup is composed and reaches here.
    document.addEventListener(
      "mouseup",
      () => {
        if (session !== null) session.pendingAction = false;
      },
      { signal }
    );
  };

  /** Status text + optional retry control. Rows are rendered separately. */
  const renderState = (code) => {
    if (session === null) return;
    setStatusText(STATE_TEXT[code] ?? STATE_TEXT.stale_session);
    if (code !== "matches") {
      clearChildren(session.listEl);
      // A036 — the rows this IDREF pointed at are gone. Leaving
      // `aria-activedescendant` behind hands AT a dangling reference to
      // `kv-option-0`, which no longer exists.
      session.listEl.removeAttribute("aria-activedescendant");
      // A040 — the light fallback never offers options the shadow list does
      // not; handleMatches re-adds the generate-only option when applicable.
      if (session.lightListboxEl !== null) clearChildren(session.lightListboxEl);
    }

    // The orphan notice is ONE sentence, and that is a contract, not a
    // description. `generateEl` is a SIBLING of the list inside the section,
    // not a child of it, so clearing the rows above does not touch it: without
    // this it survives into the notice still reading "Generate a password —
    // confirm the save in Custode.", still `aria-selected`, still enabled. A
    // control that looks live and does nothing is the precise micro-failure
    // this state exists to abolish, so it must not appear inside the warning
    // about it. Removed rather than disabled: a disabled control still
    // occupies the notice and still reads as an offer.
    if (code === "extension_lost" && session.generateEl !== null) {
      session.generateEl.remove();
      session.generateEl = null;
    }

    const wantRetry = code === "stale_session";
    if (wantRetry && session.retryEl === null) {
      const retryEl = document.createElement("button");
      retryEl.id = "kv-retry";
      retryEl.setAttribute("type", "button");
      retryEl.textContent = "Try again";
      retryEl.addEventListener(
        "click",
        () => {
          if (session === null) return;
          renderState("loading");
          requestMatches();
        },
        { signal: session.teardownController.signal }
      );
      session.statusEl.parentNode.appendChild(retryEl);
      session.retryEl = retryEl;
    } else if (!wantRetry && session.retryEl !== null) {
      session.retryEl.remove();
      session.retryEl = null;
    }
  };

  /**
   * A036 — selection state. `aria-selected` and `aria-activedescendant`
   * always agree on `kv-option-<selectedIndex>`, an id that exists in the
   * list by construction. Closed-shadow IDREF support varies across AT
   * stacks, so the polite live region additionally announces the selected
   * label and position ("Example, 1 of 2") — the mandatory fallback.
   */
  const updateSelection = ({ announce } = { announce: true }) => {
    if (session === null || session.listEl === null) return;
    const rows = session.listEl.childNodes;
    const itemCount = session.items === null ? 0 : session.items.length;
    const index = session.selectedIndex;
    // B010 — the active Generate row is the virtual last option, reachable
    // only by explicit arrow navigation (never auto-selected), so Enter can
    // never generate without the user having moved onto the row first.
    const onGenerate = session.generateToken !== null && index === itemCount;
    for (let at = 0; at < rows.length; at += 1) {
      rows[at].setAttribute(
        "aria-selected",
        !onGenerate && at === index ? "true" : "false"
      );
    }
    if (session.generateEl !== null && session.generateToken !== null) {
      session.generateEl.setAttribute("aria-selected", onGenerate ? "true" : "false");
    }
    // A040 — mirror the selection onto the GENERIC light options and point
    // the anchor's aria-activedescendant at the light id (same DOM root, so
    // the IDREF resolves — unlike the closed-shadow ids). The Generate row is
    // the light option at index === itemCount by construction.
    const lightRows =
      session.lightListboxEl === null ? [] : session.lightListboxEl.childNodes;
    for (let at = 0; at < lightRows.length; at += 1) {
      lightRows[at].setAttribute(
        "aria-selected",
        at === index ? "true" : "false"
      );
    }
    if (index >= 0 && index < lightRows.length) {
      setAnchorAria("aria-activedescendant", `kv-light-option-${index}`);
    } else if (session.savedAria.has("aria-activedescendant")) {
      removeAnchorAria("aria-activedescendant");
    }
    if (onGenerate) {
      session.listEl.removeAttribute("aria-activedescendant");
      if (announce) {
        setStatusText(`${GENERATE_ACTIVE_TEXT}, ${index + 1} of ${itemCount + 1}`);
      }
      return;
    }
    if (itemCount === 0 || rows.length === 0 || index < 0) {
      session.listEl.removeAttribute("aria-activedescendant");
      return;
    }
    session.listEl.setAttribute("aria-activedescendant", `kv-option-${index}`);
    if (announce) {
      const entry = session.items[index];
      setStatusText(`${entry.title}, ${index + 1} of ${itemCount}`);
    }
  };

  /**
   * A029 — rows expose title + displayService ONLY. The row carries no
   * dataset entry, no attribute, and no text derived from anything else in
   * the match item; the entry id lives in the click closure, not the DOM.
   */
  const renderItems = () => {
    const listEl = session.listEl;
    clearChildren(listEl);
    session.items.forEach((entry, index) => {
      const row = document.createElement("button");
      row.id = `kv-option-${index}`;
      row.setAttribute("type", "button");
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", "false");
      const titleEl = document.createElement("span");
      titleEl.textContent = entry.title;
      const serviceEl = document.createElement("span");
      serviceEl.textContent = entry.displayService;
      row.appendChild(titleEl);
      row.appendChild(serviceEl);
      if (entry.fillEligible === true) {
        // A040 SECURITY — isTrusted guard on every activation handler.
        // Page code cannot reach these closed-shadow rows, but the guard is
        // defence in depth and keeps one uniform rule: only user-agent
        // events activate a fill.
        row.addEventListener(
          "click",
          (event) => {
            if (event.isTrusted !== true) return;
            attemptFill(entry.entryId);
          },
          { signal: session.teardownController.signal }
        );
        // A040 — direct AT press on the row: an AXPress can arrive as a
        // keydown on the (focusable) row instead of a synthetic click. Only
        // the press that activates is consumed (A037 stays intact: this
        // listener lives on the row, never on the page).
        row.addEventListener(
          "keydown",
          (event) => {
            if (event.isTrusted !== true) return;
            if (!isPressKey(event)) return;
            event.preventDefault();
            event.stopPropagation();
            attemptFill(entry.entryId);
          },
          { signal: session.teardownController.signal }
        );
      } else {
        row.disabled = true;
        row.setAttribute("disabled", "");
        row.setAttribute("aria-disabled", "true");
      }
      listEl.appendChild(row);
    });
    renderLightOptions();
    session.selectedIndex = 0;
    updateSelection({ announce: false });
    updatePosition();
  };

  // -------------------------------------------------------------------------
  // Metadata query.
  // -------------------------------------------------------------------------

  const requestMatches = () => {
    // Orphan guard. Reachable from startSession and from the stale_session
    // "Try again" button — a retry is exactly when an orphan is most likely,
    // and the access below would throw before any callback could run.
    if (extensionContextLost()) {
      goInert();
      return;
    }
    const nonce = session.focusNonce;
    chrome.runtime.sendMessage(
      {
        channel: security.CHANNEL,
        version: security.MESSAGE_VERSION,
        type: "requestMatches",
        origin: session.origin,
        focusNonce: nonce,
        fieldKind: session.fieldKind,
      },
      (response) => {
        // Orphaned BETWEEN the send and the callback: reading `lastError` is
        // itself a `chrome.runtime` access and would throw here.
        if (extensionContextLost()) {
          goInert();
          return;
        }
        if (chrome.runtime.lastError) {
          // Dead worker: nothing can be authorized, so nothing may render.
          teardownSession();
          return;
        }
        // SR-3: a response whose nonce is no longer current is ignored — it
        // can neither render nor fill, even if it arrives well-formed.
        if (session === null || session.focusNonce !== nonce) return;
        handleMatches(response);
      }
    );
  };

  /** B010 — flip the Generate row between its two honest states. */
  const setGenerateState = (active) => {
    const el = session?.generateEl;
    if (el == null) return;
    if (active) {
      el.disabled = false;
      el.removeAttribute("disabled");
      el.setAttribute("aria-disabled", "false");
      el.textContent = GENERATE_ACTIVE_TEXT;
    } else {
      el.disabled = true;
      el.setAttribute("disabled", "");
      el.setAttribute("aria-disabled", "true");
      el.textContent = GENERATE_TEXT;
    }
  };

  const handleMatches = (response) => {
    if (response?.ok !== true) {
      const code = response?.error?.code;
      if (RENDERABLE_ERRORS.has(code)) renderState(code);
      else teardownSession();
      return;
    }
    // The worker already validated the outbound message, but this world only
    // trusts what it re-checks: exact shape, metadata-only items, no
    // forbidden key anywhere (A029/SR-5), and this session's own origin.
    if (
      !security.validateMatchesResult(response).ok ||
      response.origin !== session.origin
    ) {
      teardownSession();
      return;
    }

    session.items = response.items.map((entry) => ({
      entryId: entry.entryId,
      title: entry.title,
      displayService: entry.displayService,
      matchType: entry.matchType,
      fillEligible: entry.fillEligible === true,
    }));
    session.sessionBinding = {
      databaseId: response.sessionBinding.databaseId,
      cacheGeneration: response.sessionBinding.cacheGeneration,
      bridgeGeneration: response.sessionBinding.bridgeGeneration,
    };
    session.fillToken =
      typeof response.fillToken === "string" ? response.fillToken : null;
    // B010 — the row is active ONLY on an affirmative capability plus its
    // one-shot token. Absent, false, or token-less: disabled with the copy
    // that directs the user to the app.
    session.generateToken =
      response.generateAvailable === true &&
      typeof response.generateToken === "string"
        ? response.generateToken
        : null;
    setGenerateState(session.generateToken !== null);
    if (
      Number.isInteger(response.expiresAtEpochMs) &&
      response.expiresAtEpochMs < session.expiresAtEpochMs
    ) {
      session.expiresAtEpochMs = response.expiresAtEpochMs;
    }

    if (session.items.length === 0) {
      // Nothing auto-selected: Enter stays with the page until the user
      // explicitly arrows onto the Generate row (when it is active).
      session.selectedIndex = -1;
      renderState("no-matches");
      // A040 — an active Generate capability is still AT-reachable through
      // the light fallback even with zero matches.
      renderLightOptions();
      updateSelection({ announce: false });
      return;
    }
    if (session.fillToken === null) {
      renderState("no-fillable");
      renderItems();
      return;
    }
    renderState("matches");
    setStatusText(`${session.items.length} Custode suggestions`);
    renderItems();
  };

  // -------------------------------------------------------------------------
  // A031 — explicit fill.
  // -------------------------------------------------------------------------

  /**
   * A039 — set through the PROTOTYPE `value` setter when one exists. A
   * framework-controlled input shadows `value` with an instance accessor to
   * observe writes; going through the native prototype setter updates the
   * real value storage and lets the framework learn about the change from the
   * bubbling `input` event — the same technique every autofill uses. Plain
   * inputs take the same path (the prototype setter IS the normal setter).
   */
  const setNativeValue = (el, value) => {
    let proto = Object.getPrototypeOf(el);
    let descriptor;
    while (proto != null) {
      descriptor = Object.getOwnPropertyDescriptor(proto, "value");
      if (descriptor !== undefined) break;
      proto = Object.getPrototypeOf(proto);
    }
    if (descriptor && typeof descriptor.set === "function") {
      descriptor.set.call(el, value);
    } else {
      el.value = value;
    }
  };

  const dispatchFieldValue = (el, value) => {
    setNativeValue(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };

  const attemptFill = (entryId) => {
    // Orphan guard, BEFORE the one-shot token is spent. The user just pressed
    // Enter (or clicked a row): failing here without a state is the silent
    // death the QA session reported.
    if (extensionContextLost()) {
      goInert();
      return;
    }
    if (session === null || session.filling === true) return;
    if (typeof session.fillToken !== "string") return;
    const item = session.items.find(
      (entry) => entry.entryId === entryId && entry.fillEligible === true
    );
    if (!item) return;

    session.filling = true;
    const nonce = session.focusNonce;
    const request = {
      channel: security.CHANNEL,
      version: security.MESSAGE_VERSION,
      type: "fill",
      origin: session.origin,
      focusNonce: nonce,
      fillToken: session.fillToken,
      entryId,
      sessionBinding: { ...session.sessionBinding },
    };
    // One-shot on this side too: the token cannot be reused from a second
    // click even before the worker answers.
    session.fillToken = null;

    chrome.runtime.sendMessage(request, (response) => {
      if (extensionContextLost()) {
        goInert();
        return;
      }
      if (chrome.runtime.lastError) {
        teardownSession();
        return;
      }
      if (session === null || session.focusNonce !== nonce) return;
      handleFill(response, entryId);
    });
  };

  const handleFill = (response, entryId) => {
    if (response?.ok !== true) {
      session.filling = false;
      const code = response?.error?.code;
      if (RENDERABLE_ERRORS.has(code)) renderState(code);
      else teardownSession();
      return;
    }
    // A031 — verify the response against the CURRENT session before any
    // secret is used: type, origin, entry, nonce-checked already, binding.
    if (
      response.type !== "fillResult" ||
      response.origin !== session.origin ||
      response.entryId !== entryId ||
      !security.sessionBindingsEqual(response.sessionBinding, session.sessionBinding)
    ) {
      teardownSession();
      return;
    }
    // The anchor must still be live, and focus must still sit on the anchor
    // OR on the overlay surface the user just pressed (A040: an AT press can
    // move DOM focus onto the row/light option that triggered this fill).
    // Anything else fills an input the user is not looking at.
    const anchor = session.anchorEl;
    if (
      anchor == null ||
      anchor.isConnected !== true ||
      (document.activeElement !== anchor &&
        !isOverlayNode(document.activeElement))
    ) {
      teardownSession();
      return;
    }
    // A039 — the page can have made the field read-only, disabled, or hidden
    // between the query and the reveal. Never write into a field that would
    // no longer be eligible; fail closed instead.
    if (!isWritablePasswordInput(session.passwordEl)) {
      teardownSession();
      return;
    }
    const data = response.data;
    if (
      !security.isPlainObject(data) ||
      typeof data.username !== "string" ||
      typeof data.password !== "string"
    ) {
      teardownSession();
      return;
    }

    // SR-5 — the secret lives in these two locals and the input values only.
    let username = data.username;
    let password = data.password;
    try {
      // Best-effort blank of the mutable response fields. The response object
      // is this world's structured clone, so this cannot fail for shared
      // ownership reasons; a frozen object simply keeps its copy (best-effort
      // is the contract, not erasure).
      data.username = "";
      data.password = "";
      response.data = null;
    } catch (_) {
      // Frozen/exotic clone: the references still die with this scope.
    }

    if (
      session.usernameEl != null &&
      username.length > 0 &&
      isUsernameInput(session.usernameEl)
    ) {
      dispatchFieldValue(session.usernameEl, username);
    }
    dispatchFieldValue(session.passwordEl, password);
    // A031: never submit — no submit() call, no submit event, ever.

    username = null;
    password = null;
    teardownSession();
  };

  // -------------------------------------------------------------------------
  // B010/B011 — explicit generate.
  // -------------------------------------------------------------------------

  /**
   * Runs only from an explicit click on the active Generate row or an Enter
   * while it is the arrow-selected option. One-shot on this side: the token
   * dies before the worker answers, so a second activation sends nothing.
   */
  const attemptGenerate = () => {
    // Orphan guard. THIS is the path the 009 QA trace died on: Enter on the
    // arrow-selected Generate row, `chrome.runtime` undefined, unhandled
    // TypeError, overlay gone with no message. Guard before the token is spent
    // and before the row is flipped to its busy state.
    if (extensionContextLost()) {
      goInert();
      return;
    }
    if (session === null || session.filling === true || session.generating === true) {
      return;
    }
    if (typeof session.generateToken !== "string") return;
    if (session.sessionBinding === null) return;

    session.generating = true;
    const nonce = session.focusNonce;
    const request = {
      channel: security.CHANNEL,
      version: security.MESSAGE_VERSION,
      type: "generate",
      origin: session.origin,
      focusNonce: nonce,
      generateToken: session.generateToken,
      sessionBinding: { ...session.sessionBinding },
    };
    session.generateToken = null;
    // Busy: not activatable while the request is in flight. The copy is not
    // reset to the disabled sentence — this is "working", not "old peer".
    const el = session.generateEl;
    if (el != null) {
      el.disabled = true;
      el.setAttribute("disabled", "");
      el.setAttribute("aria-disabled", "true");
    }

    chrome.runtime.sendMessage(request, (response) => {
      if (extensionContextLost()) {
        goInert();
        return;
      }
      if (chrome.runtime.lastError) {
        teardownSession();
        return;
      }
      // SR-3: a response whose nonce is no longer current can neither render
      // nor fill — a late/stale generate answer for a previous session dies
      // here, even if it arrives well-formed.
      if (session === null || session.focusNonce !== nonce) return;
      handleGenerate(response);
    });
  };

  const handleGenerate = (response) => {
    session.generating = false;
    if (response?.ok !== true) {
      const code = response?.error?.code;
      if (RENDERABLE_ERRORS.has(code)) renderState(code);
      else teardownSession();
      return;
    }
    // B011 — verify against the CURRENT session before the secret is used:
    // type, origin, nonce-checked already, binding.
    if (
      response.type !== "generateResult" ||
      response.origin !== session.origin ||
      !security.sessionBindingsEqual(response.sessionBinding, session.sessionBinding)
    ) {
      teardownSession();
      return;
    }
    // The anchor must still be live, and focus must still sit on the anchor
    // OR on the overlay surface the user just pressed (A040).
    const anchor = session.anchorEl;
    if (
      anchor == null ||
      anchor.isConnected !== true ||
      (document.activeElement !== anchor &&
        !isOverlayNode(document.activeElement))
    ) {
      teardownSession();
      return;
    }
    if (!isWritablePasswordInput(session.passwordEl)) {
      teardownSession();
      return;
    }
    const data = response.data;
    if (
      !security.isPlainObject(data) ||
      typeof data.password !== "string" ||
      data.password.length === 0
    ) {
      teardownSession();
      return;
    }

    // SR-5 — the generated secret lives in this local and the password input
    // value only. Never the DOM (attributes/dataset/title), storage, logs, or
    // any durable binding; the response carries no pending id to keep.
    let generated = data.password;
    try {
      data.password = "";
      response.data = null;
    } catch (_) {
      // Frozen/exotic clone: the references still die with this scope.
    }

    dispatchFieldValue(session.passwordEl, generated);
    // B011: never submit — the app owns the save; the user confirms it there.

    generated = null;
    teardownSession();
  };

  // -------------------------------------------------------------------------
  // A028 — focus session lifecycle.
  // -------------------------------------------------------------------------

  /**
   * A037 — the keyboard contract, attached at document capture for the
   * session's lifetime only (the session AbortController owns it), but scoped
   * to events targeting the anchor. Capture is required: page/framework code
   * can stop propagation at the input before a later target listener runs,
   * while the browser still performs Enter's implicit form submit. A closed
   * overlay has NO keydown listener at all. Only the Enter that actually fills
   * prevents its default and stops propagation; every other key passes through.
   */
  const onSessionKeyDown = (event) => {
    // A040 SECURITY — the anchor is a PAGE element: page code can dispatch
    // synthetic keydowns at it (ArrowDown + Enter would be a no-gesture
    // fill). Only user-agent-generated keys drive the session; a real
    // VO/user key press is always trusted, so the AT path is unaffected.
    if (event.isTrusted !== true) return;
    if (session === null) return;
    if (event.target !== session.anchorEl) return;
    if (event.key === "Escape") {
      // Dismisses the current focus session. Not prevented: only the fill
      // action may swallow a key.
      teardownSession();
      return;
    }
    if (event.key === "Tab") {
      // Teardown AND pass-through: the browser keeps the focus move.
      teardownSession();
      return;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      const itemCount = session.items === null ? 0 : session.items.length;
      // B010 — the active Generate row is one extra, LAST option.
      const maxIndex =
        session.generateToken !== null ? itemCount : itemCount - 1;
      if (maxIndex < 0) return;
      const delta = event.key === "ArrowDown" ? 1 : -1;
      const next = Math.min(Math.max(session.selectedIndex + delta, 0), maxIndex);
      if (next !== session.selectedIndex) {
        session.selectedIndex = next;
        updateSelection();
      }
      return;
    }
    if (event.key === "Enter") {
      const itemCount = session.items === null ? 0 : session.items.length;
      if (
        session.generateToken !== null &&
        session.selectedIndex === itemCount
      ) {
        // B011 — explicit Enter on the arrow-selected Generate row.
        event.preventDefault();
        event.stopPropagation();
        attemptGenerate();
        return;
      }
      const entry = session.items?.[session.selectedIndex];
      if (
        entry == null ||
        entry.fillEligible !== true ||
        typeof session.fillToken !== "string"
      ) {
        // Not a fill action: the page keeps its Enter (and its submit, if it
        // has one — the overlay never swallows a key it did not use).
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      attemptFill(entry.entryId);
    }
  };

  /**
   * @param {"fill"|"hint"} kind  `fill` is the normal query/fill session.
   *        `hint` renders the unsupported-frame state only (A035): sessions
   *        started for an unsupported frame classification, or anchored to a
   *        detectable non-same-origin iframe in a supported document. A hint
   *        session sends NO `requestMatches`, mints no fill path, and sets no
   *        combobox ARIA on its anchor (an iframe is not a combobox).
   */
  const startSession = (anchorEl, fieldInfo, kind = "fill") => {
    session = {
      origin,
      kind,
      // SR-3: cryptographically random, one per eligible focus.
      focusNonce: security.randomToken(),
      fieldKind: fieldInfo === null ? null : fieldInfo.fieldKind,
      anchorEl,
      usernameEl: fieldInfo === null ? null : fieldInfo.usernameEl,
      passwordEl: fieldInfo === null ? null : fieldInfo.passwordEl,
      overlayHost: null,
      lightListboxEl: null,
      shadowRoot: null,
      statusEl: null,
      listEl: null,
      retryEl: null,
      generateEl: null,
      items: [],
      selectedIndex: 0,
      fillToken: null,
      generateToken: null,
      sessionBinding: null,
      filling: false,
      generating: false,
      pendingAction: false,
      blurTimerId: 0,
      statusTimerId: 0,
      savedAria: new Map(),
      expiresAtEpochMs: Date.now() + SESSION_TTL_MS,
      watchdogId: 0,
      teardownController: new AbortController(),
    };
    if (kind === "fill") {
      // A036 — the anchor exposes the combobox expanded state while open;
      // originals are recorded by setAnchorAria and restored on teardown.
      setAnchorAria("aria-expanded", "true");
      setAnchorAria("aria-haspopup", "listbox");
    }
    // A033: anchor disconnect and timeout share one watchdog timer.
    session.watchdogId = setInterval(() => {
      if (session === null) return;
      if (
        session.anchorEl.isConnected !== true ||
        Date.now() >= session.expiresAtEpochMs
      ) {
        teardownSession();
        return;
      }
      // M7 — the hint's anchor is an iframe, and the parent gets no event at
      // all for focus moving between two child browsing contexts (see
      // recheckFrameHint). Piggy-backing on the watchdog the session already
      // owns keeps that case correct without adding a timer that could
      // outlive the teardown: this interval is cleared in teardownSession().
      if (session.kind === "hint") recheckFrameHint();
    }, WATCHDOG_MS);
    document.addEventListener("keydown", onSessionKeyDown, {
      capture: true,
      signal: session.teardownController.signal,
    });
    buildOverlay();
    if (kind === "hint" || instanceMode === "unsupported") {
      // A035 — fail closed with an honest state: no query, no fill, manual
      // copy from the app. No clipboard path exists in the extension.
      renderState("unsupported_frame");
      return;
    }
    renderState("loading");
    requestMatches();
  };

  const onFocusIn = (event) => {
    const target = event.target;
    if (
      session !== null &&
      (session.anchorEl === target || isOverlayNode(target))
    ) {
      // Focus returned to the anchor — or entered the overlay itself (A040:
      // an AT press can move DOM focus onto a row or a light option; that is
      // NOT an outside departure) — so a scheduled outside-blur teardown is
      // obsolete.
      if (session.blurTimerId !== 0) {
        clearTimeout(session.blurTimerId);
        session.blurTimerId = 0;
      }
      return;
    }
    // A028: a new focus always tears down the previous session first.
    teardownSession();
    const fieldInfo = classifyField(target);
    if (fieldInfo !== null) {
      startSession(target, fieldInfo, "fill");
    }
    // NOTE (M7): no iframe branch here. Focus entering a child browsing
    // context does NOT fire `focusin` in the parent document in real Chrome
    // (measured live — 6th fake/real divergence); the cross-origin hint is
    // driven by the window `blur` path below instead.
  };

  /**
   * M7 — cross-origin iframe hint. When focus enters a child browsing
   * context, this document receives NO `focusin`; the only parent-side
   * signals are a window `blur` with `document.activeElement` already (or
   * shortly after) reading the iframe ELEMENT. On window blur, check the
   * active element synchronously and once more one macrotask later (some
   * engines settle activeElement after the blur dispatch); if it is a
   * detectable non-same-origin iframe, render the display-only hint session
   * (A035 semantics unchanged: no query, no fill, manual copy from the app).
   * The hint tears down through the normal paths when focus returns to the
   * top document (focusin), the page hides, or the TTL watchdog fires — and
   * re-anchors on an iframe→iframe move through `recheckFrameHint`.
   */
  const maybeStartFrameHint = () => {
    if (instanceMode !== "supported") return false;
    const active = document.activeElement;
    if (active == null) return false;
    if (session !== null && session.anchorEl === active) return true;
    if (!isFrameHintTarget(active)) return false;
    teardownSession();
    startSession(active, null, "hint");
    return true;
  };

  /**
   * M7 — re-anchor or drop a live hint whose iframe is no longer the active
   * element. Focus moving DIRECTLY from one child browsing context to another
   * fires no second top-window blur (the top window is already blurred), and
   * whether the parent even sees a `focusout` on the outgoing iframe element
   * is engine detail we do not want to depend on. So the check is driven by
   * state, not by an event: compare `document.activeElement` against the
   * iframe the hint was rendered for, and rebuild from whatever is actually
   * focused now.
   *
   * `maybeStartFrameHint` already tears the old session down before starting
   * the new one, so the only extra case is "active element is not a hint
   * target any more" — the hint must go away rather than linger over a frame
   * nobody is in.
   *
   * SECURITY: unchanged. The hint renders the frozen `unsupported_frame`
   * string and nothing else; re-anchoring reads the new iframe only for
   * geometry, exactly as the first render did, and still discloses nothing
   * about the child's origin. No query is sent, no fill path is minted.
   */
  const recheckFrameHint = () => {
    if (session === null || session.kind !== "hint") return;
    if (document.activeElement === session.anchorEl) return;
    if (!maybeStartFrameHint()) teardownSession();
  };

  /** One-shot post-blur re-check; owned by the instance, not the session. */
  let hintPollTimerId = 0;

  const clearHintPoll = () => {
    if (hintPollTimerId !== 0) {
      clearTimeout(hintPollTimerId);
      hintPollTimerId = 0;
    }
  };

  const onWindowBlur = () => {
    if (maybeStartFrameHint()) return;
    clearHintPoll();
    hintPollTimerId = setTimeout(() => {
      hintPollTimerId = 0;
      maybeStartFrameHint();
    }, 0);
  };

  const onFocusOut = (event) => {
    // Outside blur. A press inside the overlay never gets here (mousedown
    // default is prevented), so this is a REAL departure — but a page can
    // also blur programmatically mid-pointer-sequence. A038: defer the
    // teardown past the current pointer task; a pending overlay action
    // cancels it, anything else lets it run.
    if (session === null) return;
    // A040 — focus leaving the overlay surface itself (a focused row or
    // light option) is a departure too; focus HOPPING between anchor and
    // overlay is rescued by the focusin handler cancelling this timer.
    if (event.target !== session.anchorEl && !isOverlayNode(event.target)) {
      return;
    }
    if (session.pendingAction === true) return;
    if (session.blurTimerId !== 0) return;
    const s = session;
    s.blurTimerId = setTimeout(() => {
      if (session === s) {
        s.blurTimerId = 0;
        const wasHint = s.kind === "hint";
        teardownSession();
        // M7 — when the engine DOES report the outgoing iframe's focusout,
        // re-anchor here instead of waiting up to one watchdog tick, so an
        // iframe→iframe move never blanks the hint in between. Same guard as
        // everywhere else: only a real hint target gets a hint.
        if (wasHint) maybeStartFrameHint();
      }
    }, 0);
  };

  const onVisibilityChange = () => {
    if (document.visibilityState === "hidden") teardownSession();
  };

  const onPageHide = () => {
    teardownSession();
  };

  const activate = () => {
    if (instanceAbort !== null) return;
    instanceAbort = new AbortController();
    const signal = instanceAbort.signal;
    document.addEventListener("focusin", onFocusIn, { signal });
    document.addEventListener("focusout", onFocusOut, { signal });
    document.addEventListener("visibilitychange", onVisibilityChange, { signal });
    window.addEventListener("pagehide", onPageHide, { signal });
    // M7 — the only reliable parent-side signal for focus entering a child
    // browsing context (see maybeStartFrameHint).
    window.addEventListener("blur", onWindowBlur, { signal });
  };

  const deactivate = ({ keepHost = false } = {}) => {
    teardownSession({ keepHost });
    clearHintPoll();
    if (instanceAbort !== null) {
      instanceAbort.abort();
      instanceAbort = null;
    }
  };

  /** Latched by goInert. An orphan never speaks, renders or rebuilds again. */
  let inert = false;
  /** The registered `chrome.runtime.onMessage` handler, for best-effort removal. */
  let workerListener = null;

  /**
   * The single exit path for an ORPHANED instance (see extensionContextLost).
   *
   * Honest first, then inert. When the user is looking at an open overlay —
   * which is the whole reported bug: Enter on a row, then nothing — the state
   * machine renders `extension_lost` into it, and the status node is LEFT in
   * the page as a tombstone. Ripping the overlay off screen instead would
   * reproduce the exact silent death this guard exists to prevent ("nessuno
   * stato d'errore, nessun messaggio, poi smontato").
   *
   * The tombstone is inert by construction, not by promise: the session's
   * AbortController has fired (no row, anchor, scroll, resize or retry
   * listener left), the watchdog interval and both deferred timers are
   * cleared, the light listbox is gone, the anchor's ARIA is restored, and
   * every token, item and binding is dropped. It holds one frozen English
   * sentence and no entry metadata, and it dies with the page reload its own
   * copy asks for.
   *
   * The bootstrap GUARD is released EXACTLY when no tombstone was left.
   *
   * This extension ships no `content_scripts` manifest block: every instance
   * arrives through `scripting.registerContentScripts` / `executeScript`, so a
   * held guard is the difference between a tab that a new worker can re-serve
   * and a tab that is dead until the user reloads it. Holding it
   * unconditionally regressed the no-session case into exactly the silent,
   * unrecoverable death this whole path exists to abolish: inert, no notice,
   * and re-injection refused.
   *
   * The guard's only job is to stop a second overlay mounting NEXT TO a
   * tombstone that just told the user to reload. With no tombstone there is
   * nothing to contradict, so it goes. With one, it stays — the notice on
   * screen is the promise being kept.
   */
  const goInert = () => {
    if (inert) return;
    inert = true;
    const tombstone = session !== null && session.statusEl !== null;
    if (tombstone) {
      // Clears the rows and the light options, and swaps in the honest text.
      renderState("extension_lost");
      // M13 defers every status write by a macrotask; the teardown on the next
      // line would cancel that timer and leave the tombstone blank. This is
      // the one place the text is painted synchronously — the live region has
      // long since been registered by AT, so the M13 ordering it protects has
      // already happened.
      if (session.statusTimerId !== 0) {
        clearTimeout(session.statusTimerId);
        session.statusTimerId = 0;
      }
      session.statusEl.textContent = STATE_TEXT.extension_lost;
    }
    deactivate({ keepHost: tombstone });
    // Nothing was shown, so nothing was promised: let a new worker re-inject
    // and serve this tab rather than stranding it.
    if (!tombstone) clearGuard();

    // Best effort, and honest about why. The runtime listener can only be
    // unregistered while the API that registered it still exists — in the
    // "runtime undefined" shape it does not, and `removeListener` would throw
    // exactly like the call that got us here. It does not matter: the same
    // bridge teardown that removed the API removed every path the worker had
    // to deliver on, and the handler is orphan-guarded at its own entrance, so
    // it is unreachable and inert either way.
    // The condition is "is `removeListener` still callable", NOT "is the
    // context alive": in the `id`-only shape the context is gone by the
    // canonical probe while the API is still perfectly callable, and that is
    // precisely the case where the listener CAN and therefore MUST be dropped.
    if (
      workerListener !== null &&
      typeof chrome !== "undefined" &&
      typeof chrome.runtime?.onMessage?.removeListener === "function"
    ) {
      try {
        chrome.runtime.onMessage.removeListener(workerListener);
      } catch (_) {
        // A binding that refuses the removal changes nothing above.
      }
    }
    workerListener = null;
  };

  // =========================================================================
  // Bootstrap handshake (Slice A2, unchanged in substance).
  // =========================================================================

  // Orphan guard at the very entrance. An instance evaluated into a world
  // whose bridge is already gone must not speak and must not build: no
  // handshake, no listeners, no overlay. Unlike goInert this DOES clear the
  // guard — nothing has been rendered, so a later valid injection into this
  // world is free to bootstrap properly.
  if (extensionContextLost()) {
    clearGuard();
    return;
  }

  chrome.runtime.sendMessage(bootstrap, (response) => {
    // Reading lastError is what suppresses the "unchecked runtime.lastError"
    // console noise when the worker is gone.
    if (extensionContextLost()) {
      clearGuard();
      return;
    }
    if (chrome.runtime.lastError) {
      clearGuard();
      return;
    }
    if (approved(response)) {
      instanceMode = "supported";
    } else if (approvedUnsupportedFrame(response)) {
      // A035 — enabled origin, unsupported frame: activate in display-only
      // mode so the honest unsupported state can render on eligible focus.
      // Nothing in this mode ever sends `requestMatches` or `fill`.
      instanceMode = "unsupported";
    } else {
      clearGuard();
      return;
    }

    // Approved. Listeners are attached only here, never before.
    activate();

    const onMessage = (message) => {
      // An orphan cannot legitimately be delivered anything, but the handler
      // below reaches for `chrome.runtime` twice; guard the entrance rather
      // than reason about whether the delivery is possible.
      if (extensionContextLost()) {
        goInert();
        return;
      }
      if (message?.channel !== security.CHANNEL || message.type !== "teardown") return;

      // A033: any teardown broadcast — disable, permission removal, stale
      // revision — drops the live session immediately, before revalidation.
      // Rendering must never outlive the revision that authorized it.
      teardownSession();

      // The broadcast deliberately does NOT name the disabled origin. It is
      // delivered to every injected document, so naming it would tell a
      // document on enabled origin A which origin B the user just turned off —
      // a free cross-origin disclosure. The message is only a "revalidate now"
      // nudge; this document re-derives authorization for its OWN exact origin
      // from the background, which is the single authority anyway. Anything
      // other than an explicit approval — including a dead worker — tears this
      // instance down.
      chrome.runtime.sendMessage(bootstrap, (revalidation) => {
        // Orphaned mid-revalidation: `lastError` and `removeListener` below
        // are both `chrome.runtime` accesses and would throw. goInert drops
        // the instance listeners; the orphaned onMessage handle dies with the
        // world it was registered in, and is inert either way.
        if (extensionContextLost()) {
          goInert();
          return;
        }
        if (chrome.runtime.lastError) {
          deactivate();
          chrome.runtime.onMessage.removeListener(onMessage);
          clearGuard();
          return;
        }
        if (approved(revalidation)) {
          instanceMode = "supported";
        } else if (approvedUnsupportedFrame(revalidation)) {
          instanceMode = "unsupported";
        } else {
          deactivate();
          chrome.runtime.onMessage.removeListener(onMessage);
          clearGuard();
        }
      });
    };
    workerListener = onMessage;
    chrome.runtime.onMessage.addListener(onMessage);
  });
})();
