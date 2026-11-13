// Classic (non-module) MV3 worker: order matters, overlay_lifecycle.js and
// overlay_routes.js read the security API off globalThis at load time.
importScripts("overlay_security.js", "overlay_lifecycle.js", "overlay_routes.js");

const overlayLifecycle = new globalThis.CustodeOverlayLifecycle.OverlayLifecycle({
  browser: chrome,
});

const HOST_NAME = "dev.camillobucciarelli.keyvault_native_host";
const PROTOCOL_VERSION = 2;
const NATIVE_TIMEOUT_MS = 3000;

// spec 023 T503 — a passkey assertion waits on a person.
//
// Every other native call answers from memory in milliseconds, so 3 s is a
// generous ceiling for them. `/passkey-assert` shows a confirmation in the
// desktop app and waits for the user to answer it (FR-015); three seconds
// would time out every real sign-in. The site is already waiting on
// `navigator.credentials.get`, which has no timeout of its own, and a
// stalled app still ends in a refusal rather than a hang.
const PASSKEY_NATIVE_TIMEOUT_MS = 95000;

function createRequestId() {
  if (globalThis.crypto?.randomUUID) {
    return globalThis.crypto.randomUUID();
  }
  const random = new Uint32Array(4);
  globalThis.crypto.getRandomValues(random);
  return Array.from(random, (part) => part.toString(16).padStart(8, "0")).join(
    "-"
  );
}

/**
 * A026 needs `timeout` and `no_host` to be distinguishable, and a bare `Error`
 * is not. The tag rides on `transportCode`, NOT on `code`, so the legacy popup
 * error envelope built in `overlay_routes.js` is unchanged.
 */
function transportError(message, transportCode) {
  const error = new Error(message);
  error.transportCode = transportCode;
  return error;
}

function withTimeout(promise, timeoutMs) {
  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      reject(transportError("Native host response timed out.", "timeout"));
    }, timeoutMs);
  });

  return Promise.race([promise, timeout]).finally(() => clearTimeout(timeoutId));
}

async function sendNativeV2(type, payload = {}) {
  const timeoutMs =
    type === "passkeyAssert" ? PASSKEY_NATIVE_TIMEOUT_MS : NATIVE_TIMEOUT_MS;
  const request = {
    version: PROTOCOL_VERSION,
    id: createRequestId(),
    type,
    payload,
  };

  const nativeCall = new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST_NAME, request, (response) => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        reject(transportError(lastError.message, "no_host"));
        return;
      }
      if (!response) {
        reject(transportError("Native host returned an empty response.", "no_host"));
        return;
      }
      resolve(response);
    });
  });

  const response = await withTimeout(nativeCall, timeoutMs);
  if (response.version !== PROTOCOL_VERSION) {
    return {
      version: PROTOCOL_VERSION,
      type,
      ok: false,
      error: {
        code: "unsupported_version",
        message: "Native host returned an unsupported protocol version.",
      },
    };
  }
  if (response.id && response.id !== request.id) {
    return {
      version: PROTOCOL_VERSION,
      type,
      ok: false,
      error: {
        code: "invalid_response",
        message: "Native host response did not match the request.",
      },
    };
  }
  return response;
}

/**
 * A026 — the overlay's view of native I/O never throws and never carries a
 * native message. Transport failures become the two stable transport codes the
 * router maps; anything else is already a protocol response.
 */
async function sendOverlayNative(type, payload) {
  try {
    return await sendNativeV2(type, payload);
  } catch (error) {
    return {
      ok: false,
      error: { code: error?.transportCode === "timeout" ? "timeout" : "no_host" },
    };
  }
}

// ---------------------------------------------------------------------------
// T14 — badge state machine (plan.md "Badge state machine" / ICONS.md §1).
//
// MV3 kills this service worker aggressively and unpredictably (plan.md
// risk: "MV3 worker restart loses badge state"). Nothing here is trusted
// from a module-level JS variable across an event: every derivation reads
// chrome.storage.local first, then does a fresh native-host ping. There is
// no persistent connection to the native host (sendNativeMessage is
// one-shot), so "host connect/disconnect" and "app lock/unlock" are not
// pushed events — they are inferred by re-pinging on every wake, exactly
// as plan.md's mitigation describes ("re-derive from storage + a fresh
// host ping on every wake").
// ---------------------------------------------------------------------------

const BADGE_STATE_KEY = "kv_badge_state_v1";

// Copied verbatim from desktop/browser_extension/tokens.css (which is
// itself generated from specs/_design/tokens.css) — chrome.action's badge
// APIs need literal colour strings, not CSS custom properties, so these
// three constants are the one place colour hex values are duplicated
// outside CSS. Keep them in sync with tokens.css by hand if the tokens
// ever change; nothing enforces that automatically here.
const BADGE_COLOR_HOST_MISSING = "#f6a06b"; // --color-accent-400
const BADGE_COLOR_APP_LOCKED = "#a19786"; // --color-neutral-500
const BADGE_COLOR_MATCHES = "#aebf92"; // --color-accent-2-400
const BADGE_TEXT_COLOR_MATCHES = "#272e1b"; // --color-accent-2-900
const ICON_SIZES = [16, 32, 48];

async function loadBadgeState() {
  const stored = await chrome.storage.local.get(BADGE_STATE_KEY);
  return (
    stored[BADGE_STATE_KEY] || {
      hostReachable: false,
      appUnlocked: false,
      tabMatchCounts: {},
    }
  );
}

async function saveBadgeState(state) {
  await chrome.storage.local.set({ [BADGE_STATE_KEY]: state });
}

async function pingHostForBadge() {
  try {
    const response = await sendNativeV2("status");
    return {
      hostReachable: response?.ok === true,
      appUnlocked: response?.ok === true && response.data?.vault?.connected === true,
    };
  } catch (_) {
    return { hostReachable: false, appUnlocked: false };
  }
}

/**
 * `refreshBadgeForTab` awaits a native-host ping BEFORE it paints, so by the
 * time the chrome.action calls run the tab may already be closed. Chrome then
 * rejects with "No tab with id: N." and the console shows an unchecked
 * lastError — observed live during the spec 007 smoke.
 *
 * A tab that no longer exists is not an application error: there is simply
 * nothing left to paint. This helper swallows EXACTLY that rejection and
 * rethrows everything else, so a real chrome.action failure (bad colour, bad
 * imageData, missing permission) stays visible instead of being hidden behind
 * a blanket catch.
 *
 * WHY A MESSAGE MATCH AND NOT A `chrome.tabs.get` PRE-CHECK
 * ---------------------------------------------------------
 * A pre-check cannot replace this catch: the tab can still die between the
 * `get` resolving and the `setBadgeText` landing, so the catch is required
 * either way — and the pre-check would add one extra async round trip per
 * painted tab for a race it does not close. It is strictly more code that
 * fixes strictly less.
 *
 * The message match is safe here because extension-API error strings are
 * emitted by Chrome's C++ bindings as fixed English literals (the tab-not-
 * found error is built from a `"No tab with id: *."` template) — they are not
 * routed through the browser's UI localization, so they do not change with the
 * user's locale. The regex is deliberately anchored on that invariant
 * substring only, ignoring the id and the trailing punctuation.
 *
 * WHY A THUNK AND NOT AN ALREADY-EVALUATED PROMISE
 * ------------------------------------------------
 * Taking `Promise` would mean the call has already run by the time this
 * function is entered, so a SYNCHRONOUS throw from `chrome.action.*` would
 * never reach the catch. Chrome does not currently throw synchronously for a
 * dead tab — the tab id is resolved browser-side, so the failure always
 * arrives as a rejection, and `test/fake_browser.js` models exactly that. The
 * thunk is therefore defence in depth against an unobserved binding
 * behaviour, not a workaround for something measured: it costs one arrow
 * function per call site and makes the guard total over both failure modes.
 */
const TAB_GONE_MESSAGE = /No tab with id/i;

async function ignoreTabGone(call) {
  try {
    // Invoked INSIDE the try: a synchronous throw and a rejection take the
    // same path, and both are filtered by the same narrow match.
    await call();
  } catch (error) {
    if (TAB_GONE_MESSAGE.test(error?.message ?? "")) return;
    throw error;
  }
}

// `reason` is null for the normal icon, or "locked"/"nohost" to select the
// matching pre-rendered dim state PNG from icons/state/ (assets/logo/
// app_icon_family/state/ext-<size>-<reason>.png, copied in verbatim).
function iconPathForState(reason) {
  const path = {};
  for (const size of ICON_SIZES) {
    path[size] = reason
      ? `icons/state/icon-${size}-${reason}.png`
      : `icons/icon-${size}.png`;
  }
  return path;
}

async function applyIconForTab(tabId, reason) {
  await ignoreTabGone(() =>
    chrome.action.setIcon({ tabId, path: iconPathForState(reason) })
  );
}

async function applyBadgeForTab(tabId, { text, color, textColor }) {
  await ignoreTabGone(() => chrome.action.setBadgeText({ tabId, text: text || "" }));
  if (text) {
    await ignoreTabGone(() =>
      chrome.action.setBadgeBackgroundColor({ tabId, color })
    );
    // setBadgeTextColor is Chrome 110+; feature-detect, never required.
    if (textColor && typeof chrome.action.setBadgeTextColor === "function") {
      await ignoreTabGone(() =>
        chrome.action.setBadgeTextColor({ tabId, color: textColor })
      );
    }
  }
}

// derive(state) from: hostReachable, appUnlocked, matchCount(activeTab)
//   !hostReachable → icons/state/icon-*-nohost.png, badge solid accent-400
//   !appUnlocked   → icons/state/icon-*-locked.png, badge solid neutral-500
//   matchCount > 0 → normal icon, badge accent-2-400 with the count
//   otherwise      → normal icon, no badge
async function refreshBadgeForTab(tabId) {
  if (typeof tabId !== "number") return;

  const ping = await pingHostForBadge();
  const state = await loadBadgeState();
  state.hostReachable = ping.hostReachable;
  state.appUnlocked = ping.appUnlocked;
  await saveBadgeState(state);

  if (!state.hostReachable) {
    await applyIconForTab(tabId, "nohost");
    await applyBadgeForTab(tabId, { text: " ", color: BADGE_COLOR_HOST_MISSING });
    return;
  }
  if (!state.appUnlocked) {
    await applyIconForTab(tabId, "locked");
    await applyBadgeForTab(tabId, { text: " ", color: BADGE_COLOR_APP_LOCKED });
    return;
  }

  const matchCount = state.tabMatchCounts?.[tabId];
  if (typeof matchCount === "number" && matchCount > 0) {
    await applyIconForTab(tabId, null);
    await applyBadgeForTab(tabId, {
      text: String(Math.min(matchCount, 99)),
      color: BADGE_COLOR_MATCHES,
      textColor: BADGE_TEXT_COLOR_MATCHES,
    });
    return;
  }

  await applyIconForTab(tabId, null);
  await applyBadgeForTab(tabId, { text: "" });
}

async function setTabMatchCount(tabId, count) {
  if (typeof tabId !== "number") return;
  const state = await loadBadgeState();
  state.tabMatchCounts = state.tabMatchCounts || {};
  state.tabMatchCounts[tabId] = count;
  await saveBadgeState(state);
  await refreshBadgeForTab(tabId);
}

async function clearTabMatchCount(tabId) {
  const state = await loadBadgeState();
  if (state.tabMatchCounts) delete state.tabMatchCounts[tabId];
  await saveBadgeState(state);
}

async function currentActiveTabId() {
  return new Promise((resolve) => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      resolve(tabs[0]?.id ?? null);
    });
  });
}

async function refreshActiveTabBadge() {
  const tabId = await currentActiveTabId();
  if (tabId !== null) await refreshBadgeForTab(tabId);
}

// ---------------------------------------------------------------------------
// Reporting at the listener boundary.
//
// A mute `.catch(() => {})` on an event listener is where an error signal
// dies. Nothing awaits these promises, so a rejection swallowed here is
// observable NOWHERE — not in the console, not in a response, not in a test.
// That is precisely why the spec 007 badge defect stayed invisible until it
// was found by hand in the smoke: `ignoreTabGone` rethrows every NON-tab-gone
// failure on purpose, so a real chrome.action bug stays visible, and then each
// listener threw that rethrow straight into a mute catch. The guard was right;
// the boundary discarded its output.
//
// Two rules hold for everything below.
//
//  1. NEVER PROPAGATE. A listener that hands back a rejected promise is noise
//     in MV3 and can surface as an unchecked-`runtime.lastError` warning, so
//     every path still ends in a catch. Report, do not rethrow.
//
//  2. NEVER LOG DATA. A026 ("nothing here logs the request or the native
//     response") extends to diagnostics. Exactly two things are written: a
//     STATIC context id fixed at the call site, and the error's own `message`,
//     sanitized. Not the error object, and not its stack — a stack adds
//     extension paths and no diagnostic value the message does not already
//     carry.
//
// Sanitizing is not decoration here, it closes a measured vector: an overlay
// registration id is `<REGISTRATION_PREFIX><hex>` where the hex is a
// char-by-char encoding of the ORIGIN PATTERN (see `registrationIdForPattern`
// in overlay_lifecycle.js). A `scripting.*` failure that echoes such an id — or
// any browser error that quotes a host — would otherwise put a trivially
// reversible piece of the user's browsing history into the console.
//
// The redaction list below is ordered most-specific-first. Two properties are
// load-bearing and both are pinned by tests:
//
//   NO ORIGIN SURVIVES. Not as a URL, not as a bare `host:port`, not as a
//   scheme-less match pattern, and not hex-encoded. A run of hex is reversible
//   whether or not it carries the registration prefix, so the prefix rule is a
//   LABEL, not the defence — rule 2 is.
//
//   THE LOG STAYS READABLE. Over-redaction is the opposite failure and just as
//   real: a report where every token is `<redacted>` teaches people to turn the
//   channel off. Tab ids, version numbers, numeric codes and source filenames
//   must survive intact, which is why the host rules demand real evidence of a
//   host (a TLD-like final label, or a `:port`) instead of matching anything
//   with a dot in it.
// ---------------------------------------------------------------------------

const REPORTED_MESSAGE_MAX_CHARS = 200;

/**
 * Derived from overlay_lifecycle.js, never re-spelled. A literal "kv-overlay-"
 * here would silently stop matching the day the prefix is renamed, and no test
 * would fail — the sanitizer would just quietly stop redacting.
 */
const REGISTRATION_PREFIX =
  globalThis.CustodeOverlayLifecycle.REGISTRATION_PREFIX;

const escapeForRegExp = (literal) =>
  literal.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * Final labels treated as a file extension rather than a TLD. Every one of
 * these is also a real TLD somewhere, so this is a deliberate readability
 * trade: `background.js` and `icon-16.png` stay legible in a report, at the
 * cost of not redacting the (nonexistent) sites `example.js` / `example.png`.
 */
const FILENAME_TAILS = new Set([
  "js", "mjs", "cjs", "json", "css", "html", "htm",
  "png", "svg", "map", "md", "txt", "log", "ts",
]);

const REDACTIONS = [
  // 1. A registration id, kept labelled so a reader knows what was removed.
  [
    new RegExp(`${escapeForRegExp(REGISTRATION_PREFIX)}[0-9a-f]+`, "gi"),
    () => `${REGISTRATION_PREFIX}<redacted>`,
  ],
  // 2. ANY long bare hex run. `registrationIdForPattern` emits 4 hex digits
  //    per character, so 16 digits is already a 4-character origin fragment.
  //    This is what actually closes the encoding vector: it does not care how
  //    the id was prefixed, or whether it was prefixed at all.
  [/\b[0-9a-f]{16,}\b/gi, () => "<redacted-id>"],
  // 3. Absolute URLs (http://, https://, chrome-extension://, file://, ...).
  [/\b[a-z][a-z0-9+.-]*:\/\/\S*/gi, () => "<redacted-origin>"],
  // 4. Match patterns with a wildcard scheme, e.g. `*://*.example.com/*`.
  [/\*:\/\/\S*/g, () => "<redacted-origin>"],
  // 5. Bare `host:port` — the shape Chrome's own "Missing scheme separator"
  //    error echoes. A dot plus an explicit port is strong evidence of a host,
  //    which is what keeps `code:42` (no dot) readable.
  [/\b(?:[a-z0-9-]+\.)+[a-z0-9-]+:\d{1,5}\b/gi, () => "<redacted-origin>"],
  // 6. `localhost`, the one scheme-less host that has no dot at all.
  [/\blocalhost(?::\d{1,5})?\b/gi, () => "<redacted-origin>"],
  // 7. Bare dotted host, optional `*.` prefix and path, where the FINAL label
  //    is TLD-like (alphabetic, 2+). The alphabetic requirement is what makes
  //    `Chrome 151.0.7977.54` survive: its last label is numeric, so it is a
  //    version, not a host.
  [
    /(?:\*\.)?(?:[a-z0-9-]+\.)+([a-z]{2,})(?:\/\S*)?/gi,
    (match, tail) =>
      FILENAME_TAILS.has(tail.toLowerCase()) ? match : "<redacted-origin>",
  ],
];

function sanitizeErrorMessage(error) {
  const raw =
    typeof error?.message === "string" ? error.message : String(error ?? "");
  let redacted = raw;
  for (const [pattern, replacer] of REDACTIONS) {
    redacted = redacted.replace(pattern, replacer);
  }
  redacted = redacted.replace(/\s+/g, " ").trim();
  if (redacted === "") return "(no message)";
  return redacted.length > REPORTED_MESSAGE_MAX_CHARS
    ? `${redacted.slice(0, REPORTED_MESSAGE_MAX_CHARS)}…`
    : redacted;
}

/**
 * @param {string} context A static, caller-fixed identifier naming the
 *   listener. Never interpolated from runtime data.
 * @param {unknown} error The rejection value. Only its `message` is read.
 */
function reportListenerFailure(context, error) {
  console.error(`[custode] ${context}: ${sanitizeErrorMessage(error)}`);
}

// Re-derived on tab activation, tab navigation, extension (re)start — the
// events plan.md names. No "tabs" host permission is requested: these
// listeners fire without it (only sensitive fields like tab.url would be
// filtered, and this file never reads tab.url — it only ever uses tabId).
chrome.tabs.onActivated.addListener(({ tabId }) => {
  void refreshBadgeForTab(tabId).catch((error) =>
    reportListenerFailure("tabs.onActivated badge refresh", error)
  );
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading") {
    // Navigation invalidates any cached match count for this tab — show
    // the safe "unknown" (no-badge) state rather than a stale count.
    void clearTabMatchCount(tabId)
      .then(() => refreshBadgeForTab(tabId))
      .catch((error) =>
        reportListenerFailure("tabs.onUpdated(loading) badge refresh", error)
      );
  } else if (changeInfo.status === "complete") {
    void refreshBadgeForTab(tabId).catch((error) =>
      reportListenerFailure("tabs.onUpdated(complete) badge refresh", error)
    );
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  void clearTabMatchCount(tabId).catch((error) =>
    reportListenerFailure("tabs.onRemoved match-count cleanup", error)
  );
});

chrome.runtime.onStartup.addListener(() =>
  void refreshActiveTabBadge().catch((error) =>
    reportListenerFailure("runtime.onStartup badge refresh", error)
  )
);
chrome.runtime.onInstalled.addListener(() =>
  void refreshActiveTabBadge().catch((error) =>
    reportListenerFailure("runtime.onInstalled badge refresh", error)
  )
);

// ---------------------------------------------------------------------------
// 009 Slice A2 — overlay opt-in lifecycle.
//
// A020: reconciliation runs before any overlay message is served. Every entry
// point below goes through `overlayLifecycle.ready()`, which reconciles once
// per worker instance; `reconcile()` is called directly for the events that
// must re-derive state within a live worker (permission add/remove).
// ---------------------------------------------------------------------------

chrome.runtime.onStartup.addListener(() => {
  void overlayLifecycle
    .ready()
    .catch((error) =>
      reportListenerFailure("runtime.onStartup overlay reconcile", error)
    );
});
chrome.runtime.onInstalled.addListener(() => {
  void overlayLifecycle
    .ready()
    .catch((error) =>
      reportListenerFailure("runtime.onInstalled overlay reconcile", error)
    );
});
chrome.permissions.onAdded.addListener((added) => {
  // `prunePermissions: false` — Chrome fires onAdded before the popup's
  // setSiteState arrives, so the just-granted pattern is not yet in committed
  // config; a full reconcile would revoke it as an orphan and the enable would
  // fail. Safe to defer: a permission without config is inert (config is the
  // authorization truth), and the orphan sweep still runs on cold start,
  // popup open, onRemoved and disable (D5). See reconcile()'s doc comment.
  //
  // Then consume the popup's pending enable intent (macOS: the permission
  // prompt closes the popup, so its own setSiteState never arrives). The
  // event's granted patterns must cover the WHOLE broad set before the intent
  // is honoured. See consumeEnableIntent()'s doc comment.
  void overlayLifecycle
    .reconcile({ prunePermissions: false })
    .then(() =>
      overlayLifecycle.consumeEnableIntent({
        grantedOrigins: Array.isArray(added?.origins) ? added.origins : [],
      })
    )
    .catch((error) =>
      reportListenerFailure("permissions.onAdded overlay reconcile", error)
    );
});
chrome.permissions.onRemoved.addListener(() => {
  void overlayLifecycle
    .reconcile()
    .catch((error) =>
      reportListenerFailure("permissions.onRemoved overlay reconcile", error)
    );
});

// ---------------------------------------------------------------------------
// 009 Slice A3 — one explicit route table for every message the worker serves.
//
// A022: `background.js` no longer decides anything. It owns wiring only —
// which browser APIs, which native transport, which clock — while every
// admission rule lives in `overlay_routes.js`, where the Node harness can
// execute the same code the extension runs. The Slice A2 popup routes moved
// into that table unchanged in behaviour and are now gated by the SR-1
// extension-page sender validator instead of the looser inline check that used
// to guard them.
// ---------------------------------------------------------------------------

const overlayRouter = new globalThis.CustodeOverlayRoutes.OverlayRouter({
  lifecycle: overlayLifecycle,
  runtimeId: chrome.runtime.id,
  native: sendOverlayNative,
  legacyNative: sendNativeV2,
  reportMatchCount: setTabMatchCount,
  refreshBadge: refreshBadgeForTab,
});

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  // Every message is answered. An unknown sender, type or shape resolves with
  // a stable refusal instead of falling through to an unanswered port, so the
  // failure is deterministic rather than a hang the caller has to time out.
  //
  // A026: nothing here logs the request or the native response.
  overlayRouter
    .dispatch(request, sender)
    .then(sendResponse)
    .catch(() =>
      sendResponse({
        ok: false,
        error: { code: "internal_error", message: "Overlay request failed." },
      })
    );
  return true;
});
