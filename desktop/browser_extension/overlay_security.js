// 009 Slice A0 — pure security helpers for the in-page autofill overlay.
//
// This file is PRODUCTION code. `background.js` loads it with
// `importScripts("overlay_security.js")` (classic MV3 service worker) and the
// Node harness under `test/` loads the very same file through `require()`.
// There is exactly one implementation of every rule below; the tests never
// re-implement one.
//
// Everything here is pure and synchronous except the focus-grant store, which
// owns only in-memory state. No `chrome.*` API is touched, so the file is
// loadable in Node without any shim.

"use strict";

// MV3 `importScripts` runs every worker file in ONE shared global scope, so a
// top-level `const` here collides with an identically named one in any other
// worker file (`require()` never shows this — each module gets its own scope).
// The IIFE keeps every binding file-local; only the `CustodeOverlaySecurity`
// global escapes. `test/worker_global_scope.test.js` loads the files the way
// the worker does and fails on any regression.
(() => {

// ---------------------------------------------------------------------------
// Bounds. Every string/array crossing a trust boundary is length-checked.
// ---------------------------------------------------------------------------

const LIMITS = Object.freeze({
  URL: 4096,
  ORIGIN: 512,
  HOST: 253,
  TOKEN: 128,
  ENTRY_ID: 256,
  TEXT: 512,
  ITEMS: 10,
  GRANTS: 100,
  TOKEN_TTL_MS: 30000, // SR-3: 30 seconds is the hard ceiling, never a default.
});

const CHANNEL = "keyvault-overlay-v1";
const MESSAGE_VERSION = 1;

// ---------------------------------------------------------------------------
// 009 Slice C — the ONE broad optional host permission the overlay asks for.
//
// These two patterns are the literal value of `optional_host_permissions` in
// `manifest.json`. They are OPTIONAL, never required: A015 is unchanged, the
// manifest still declares no `host_permissions`, and the browser only ever
// holds these after the user accepts one prompt raised under a popup gesture.
// What Slice C changes is the SHAPE of that prompt (one global ask instead of
// one ask per site), not whether the permission is mandatory.
//
// `test/overlay_lifecycle.test.js` asserts this array equals the manifest's
// `optional_host_permissions` exactly, so the two can never drift: a constant
// that asked for more than the manifest offers would make every enable fail
// closed, and one that asked for less would leave frames uninjected.
const GLOBAL_PERMISSION_PATTERNS = Object.freeze(["http://*/*", "https://*/*"]);

/**
 * True only when the browser reports BOTH broad patterns as held.
 *
 * Deliberately ALL, not some: a half grant (http only) would inject on http
 * pages while https pages stayed silent, which reads to the user as "the
 * overlay is broken" rather than "the overlay is off". Fail closed on the
 * whole set instead.
 */
function coversGlobalPermission(patterns) {
  if (!Array.isArray(patterns)) return false;
  return GLOBAL_PERMISSION_PATTERNS.every((pattern) => patterns.includes(pattern));
}

// 009 Slice B2 — the capability the native host advertises via `hello` only
// when the running app's bridge descriptor lists it (B007). Mirrors
// `desktopBrowserGeneratePendingCapability` in
// `lib/features/password_manager/data/services/desktop_browser_autofill_cache.dart`.
const GENERATE_CAPABILITY = "generatePendingEntryV1";

// SR-5 / A007: keys that may never appear in persisted config or in any
// metadata message, at any nesting depth. Unknown keys are rejected anyway by
// the exact-shape check; this list exists so the *reason* is explicit and so a
// future schema edit cannot quietly allowlist a secret.
const FORBIDDEN_KEYS = Object.freeze([
  "password",
  "passwords",
  "secret",
  "secrets",
  "credential",
  "credentials",
  "username",
  "usernames",
  "user",
  "login",
  "payload",
  "nativePayload",
  "nativeResponse",
  "response",
  "data",
]);

const FORBIDDEN_KEY_SET = new Set(FORBIDDEN_KEYS);

// ---------------------------------------------------------------------------
// SR-2 — canonical HTTP(S) origin.
//
// Deliberately NOT the Dart `DesktopBrowserAutofillMetadataMapper` rule: that
// one routes through `_cleanHost`, which strips `www.`/`m.`/`mobile.` and so
// makes `https://www.example.com` and `https://example.com` compare equal.
// Useful for "possible match" ranking, invalid for authorization. Here every
// hostname label is preserved.
// ---------------------------------------------------------------------------

const DEFAULT_PORTS = Object.freeze({ "http:": 80, "https:": 443 });
const SCHEME_RE = /^([a-zA-Z][a-zA-Z0-9+.\-]*):/;
const AUTHORITY_RE = /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/([^/?#]*)/;
const DOTTED_QUAD_RE = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/;
// A host is "IPv4-shaped" if every label is made of characters an IPv4 parser
// accepts (decimal, octal, hex). `127.1`, `0177.0.0.1`, `0x7f.0.0.1` and the
// bare dword `2130706433` all qualify; `example.com` does not.
const IPV4_SHAPED_RE = /^(?:0[xX][0-9a-fA-F]+|\d+)(?:\.(?:0[xX][0-9a-fA-F]+|\d+))*\.?$/;

function canonicalizationError(code) {
  return Object.freeze({ ok: false, error: code, origin: null });
}

function stripTrailingDot(host) {
  // WHATWG URL preserves a terminal dot (`example.com.`). data-model.md
  // requires it removed "consistently". Bracketed IPv6 literals never carry
  // one, so this only touches DNS names.
  if (host.startsWith("[")) return host;
  let out = host;
  while (out.endsWith(".")) out = out.slice(0, -1);
  return out;
}

function splitRawHost(authority) {
  // Returns the host portion of a raw authority, port removed, userinfo NOT
  // removed (the caller rejects userinfo before calling this).
  if (authority.startsWith("[")) {
    const close = authority.indexOf("]");
    if (close === -1) return authority;
    return authority.slice(0, close + 1);
  }
  const colon = authority.lastIndexOf(":");
  return colon === -1 ? authority : authority.slice(0, colon);
}

/**
 * Canonicalize an absolute HTTP(S) URL into a comparable origin.
 *
 * Equality is the full tuple `(scheme, asciiHost, effectivePort)`. Callers must
 * compare `serialized` (or the tuple), never `asciiHost` alone.
 *
 * @param {unknown} rawValue
 * @returns {{ok: true, origin: object, permissionPattern: string} |
 *           {ok: false, error: string, origin: null}}
 */
function canonicalizeOrigin(rawValue) {
  if (typeof rawValue !== "string") return canonicalizationError("not_a_string");
  const raw = rawValue.trim();
  if (raw.length === 0) return canonicalizationError("empty_value");
  if (raw.length > LIMITS.URL) return canonicalizationError("oversize_value");

  // Scheme is checked on the raw text so that `javascript:`, `data:` and
  // `chrome-extension:` are rejected by name rather than by side effect.
  const schemeMatch = SCHEME_RE.exec(raw);
  if (!schemeMatch) return canonicalizationError("scheme_forbidden");
  const rawScheme = schemeMatch[1].toLowerCase();
  if (rawScheme !== "http" && rawScheme !== "https") {
    return canonicalizationError("scheme_forbidden");
  }

  // Raw-authority inspection happens BEFORE parsing: the URL parser rewrites
  // `0177.0.0.1` to `127.0.0.1` and moves `alice:secret@` into separate
  // fields, erasing the evidence we need to reject on.
  const authorityMatch = AUTHORITY_RE.exec(raw);
  if (!authorityMatch) return canonicalizationError("invalid_url");
  const rawAuthority = authorityMatch[1];
  if (rawAuthority.length === 0) return canonicalizationError("empty_host");
  if (rawAuthority.includes("@")) {
    return canonicalizationError("userinfo_forbidden");
  }

  let parsed;
  try {
    parsed = new URL(raw);
  } catch (_) {
    return canonicalizationError("invalid_url");
  }

  // Defence in depth: the parser's own view of userinfo must also be empty.
  if (parsed.username !== "" || parsed.password !== "") {
    return canonicalizationError("userinfo_forbidden");
  }

  const scheme = parsed.protocol.slice(0, -1).toLowerCase();
  if (scheme !== "http" && scheme !== "https") {
    return canonicalizationError("scheme_forbidden");
  }

  const parsedHost = parsed.hostname.toLowerCase();
  if (parsedHost.length === 0) return canonicalizationError("empty_host");

  const rawHost = stripTrailingDot(splitRawHost(rawAuthority).toLowerCase());
  const normalizedParsedHost = stripTrailingDot(parsedHost);

  // Non-canonical IPv4: the parser normalized an IPv4-shaped authority into a
  // dotted quad that is not what the user typed. `127.1`, `127.000.000.001`,
  // `0177.0.0.1`, `0x7f.0.0.1` and `2130706433` all land here; a literal
  // `127.0.0.1` does not, because raw and parsed agree.
  if (DOTTED_QUAD_RE.test(normalizedParsedHost) && rawHost !== normalizedParsedHost) {
    return canonicalizationError("noncanonical_ipv4");
  }
  // An IPv4-shaped authority that the parser did NOT resolve to a dotted quad
  // is rejected too, rather than being treated as a DNS name.
  if (
    !DOTTED_QUAD_RE.test(normalizedParsedHost) &&
    !normalizedParsedHost.startsWith("[") &&
    IPV4_SHAPED_RE.test(rawHost)
  ) {
    return canonicalizationError("noncanonical_ipv4");
  }

  const asciiHost = normalizedParsedHost;
  if (asciiHost.length === 0) return canonicalizationError("empty_host");
  if (asciiHost.length > LIMITS.HOST) return canonicalizationError("oversize_host");

  const defaultPort = DEFAULT_PORTS[parsed.protocol];
  const effectivePort = parsed.port === "" ? defaultPort : Number(parsed.port);
  if (!Number.isInteger(effectivePort) || effectivePort < 1 || effectivePort > 65535) {
    return canonicalizationError("invalid_port");
  }

  const serialized =
    effectivePort === defaultPort
      ? `${scheme}://${asciiHost}`
      : `${scheme}://${asciiHost}:${effectivePort}`;
  if (serialized.length > LIMITS.ORIGIN) {
    return canonicalizationError("oversize_value");
  }

  return Object.freeze({
    ok: true,
    origin: Object.freeze({ scheme, asciiHost, effectivePort, serialized }),
    // Chromium host permission patterns cannot express a port, so two enabled
    // origins differing only by port share one pattern. Runtime exact-origin
    // checks stay mandatory.
    permissionPattern: `${scheme}://${asciiHost}/*`,
  });
}

/** Canonical serialized origin, or `null` when the input is not acceptable. */
function canonicalOriginOrNull(rawValue) {
  const result = canonicalizeOrigin(rawValue);
  return result.ok ? result.origin.serialized : null;
}

/**
 * Exact origin equality over the full `(scheme, host, effective port)` tuple.
 *
 * Deliberately compares the SERIALIZED form rather than the three fields
 * separately: every authorization site in the extension compares serialized
 * origins as strings, and a second, structurally different comparison here
 * would let the two drift apart without any test noticing.
 */
function originsEqual(a, b) {
  const left = canonicalOriginOrNull(a);
  const right = canonicalOriginOrNull(b);
  return left !== null && left === right;
}

/** Chromium optional-host-permission pattern for an already-canonical origin. */
function permissionPatternForOrigin(canonicalOrigin) {
  const result = canonicalizeOrigin(canonicalOrigin);
  return result.ok ? result.permissionPattern : null;
}

// ---------------------------------------------------------------------------
// Strict object shape.
// ---------------------------------------------------------------------------

function shapeError(code, key) {
  return Object.freeze({ ok: false, error: code, key: key ?? null });
}

const SHAPE_OK = Object.freeze({ ok: true, error: null, key: null });

function isPlainObject(value) {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype ||
      Object.getPrototypeOf(value) === null)
  );
}

/**
 * Reject `password`, `secret`, `username`, native payload dumps and friends at
 * any depth. Used by the persisted-config validator and by every metadata
 * message validator (A007).
 */
function assertNoForbiddenKeys(value, depth = 0) {
  if (depth > 6) return shapeError("too_deep");
  if (Array.isArray(value)) {
    for (const item of value) {
      const nested = assertNoForbiddenKeys(item, depth + 1);
      if (!nested.ok) return nested;
    }
    return SHAPE_OK;
  }
  if (!isPlainObject(value)) return SHAPE_OK;
  for (const key of Object.keys(value)) {
    if (FORBIDDEN_KEY_SET.has(key)) return shapeError("forbidden_key", key);
    const nested = assertNoForbiddenKeys(value[key], depth + 1);
    if (!nested.ok) return nested;
  }
  return SHAPE_OK;
}

function checkField(spec, value) {
  // `nullable` exists for the legacy popup routes only (A022): the popup really
  // does send `url: null` when there is no active-tab origin. It is opt-in per
  // field, so no overlay schema is loosened by its existence.
  if (spec.nullable === true && value === null) return true;
  switch (spec.type) {
    case "int":
      return Number.isInteger(value) &&
        (spec.min === undefined || value >= spec.min) &&
        (spec.max === undefined || value <= spec.max);
    case "bool":
      return typeof value === "boolean";
    case "string":
      return (
        typeof value === "string" &&
        (value.length > 0 || spec.allowEmpty === true) &&
        value.length <= (spec.maxLength ?? LIMITS.TEXT)
      );
    case "origin":
      return typeof value === "string" && canonicalOriginOrNull(value) === value;
    case "enum":
      return typeof value === "string" && spec.values.includes(value);
    case "array":
      return Array.isArray(value) && value.length <= (spec.maxLength ?? 1000);
    case "sessionBinding":
      return validateSessionBinding(value).ok;
    default:
      return false;
  }
}

/**
 * Exact-shape check: every required key present with the right type, no extra
 * key, no forbidden key.
 */
function validateExactShape(value, fields) {
  if (!isPlainObject(value)) return shapeError("not_an_object");
  const allowed = new Set(Object.keys(fields));
  for (const key of Object.keys(value)) {
    if (FORBIDDEN_KEY_SET.has(key)) return shapeError("forbidden_key", key);
    if (!allowed.has(key)) return shapeError("unknown_key", key);
  }
  for (const [key, spec] of Object.entries(fields)) {
    if (!(key in value)) {
      if (spec.optional) continue;
      return shapeError("missing_key", key);
    }
    if (!checkField(spec, value[key])) return shapeError("invalid_type", key);
  }
  return SHAPE_OK;
}

// ---------------------------------------------------------------------------
// SR-4 — vault/cache/bridge session binding.
// ---------------------------------------------------------------------------

const SESSION_BINDING_FIELDS = Object.freeze({
  databaseId: { type: "string", maxLength: LIMITS.ENTRY_ID },
  cacheGeneration: { type: "string", maxLength: LIMITS.ENTRY_ID },
  bridgeGeneration: { type: "string", maxLength: LIMITS.ENTRY_ID },
});

function validateSessionBinding(value) {
  return validateExactShape(value, SESSION_BINDING_FIELDS);
}

/** All three fields compared exactly; a missing/extra field is never equal. */
function sessionBindingsEqual(a, b) {
  if (!validateSessionBinding(a).ok || !validateSessionBinding(b).ok) return false;
  return (
    a.databaseId === b.databaseId &&
    a.cacheGeneration === b.cacheGeneration &&
    a.bridgeGeneration === b.bridgeGeneration
  );
}

// ---------------------------------------------------------------------------
// Message catalogue. `route` is what enforces SR-1: a message type belongs to
// exactly one sender path and the two validators never consult the other's
// half of this table.
// ---------------------------------------------------------------------------

const EXTENSION_PAGE_ROUTE = "extension-page";
const CONTENT_SCRIPT_ROUTE = "content-script";

const MESSAGE_SCHEMAS = Object.freeze({
  // SLICE C — both popup routes address the ONE global switch, so neither
  // carries an origin any more.
  //
  // `tabId` is nullable because the popup can be open on a page that has no
  // injectable tab context at all (a `chrome://` page, the extensions page).
  // The toggle still has to work there — above all TURNING OFF has to work
  // there — so the tab is optional context for the courtesy injection, never
  // a precondition for the state change.
  getSiteState: {
    route: EXTENSION_PAGE_ROUTE,
    fields: {
      tabId: { type: "int", min: 0, nullable: true },
      tabUrl: { type: "string", maxLength: LIMITS.URL, nullable: true },
    },
  },
  setSiteState: {
    route: EXTENSION_PAGE_ROUTE,
    fields: {
      tabId: { type: "int", min: 0, nullable: true },
      enabled: { type: "bool" },
    },
  },
  bootstrap: {
    route: CONTENT_SCRIPT_ROUTE,
    fields: { origin: { type: "origin" } },
  },
  requestMatches: {
    route: CONTENT_SCRIPT_ROUTE,
    fields: {
      origin: { type: "origin" },
      focusNonce: { type: "string", maxLength: LIMITS.TOKEN },
      fieldKind: { type: "enum", values: ["password", "username"] },
    },
  },
  fill: {
    route: CONTENT_SCRIPT_ROUTE,
    fields: {
      origin: { type: "origin" },
      focusNonce: { type: "string", maxLength: LIMITS.TOKEN },
      fillToken: { type: "string", maxLength: LIMITS.TOKEN },
      entryId: { type: "string", maxLength: LIMITS.ENTRY_ID },
      sessionBinding: { type: "sessionBinding" },
    },
  },
  // B010 — explicit generate. DELIBERATELY no settings field of any kind:
  // the app owns generator settings and the worker has no key to carry them
  // (an extra key of any name fails the exact-shape check).
  generate: {
    route: CONTENT_SCRIPT_ROUTE,
    fields: {
      origin: { type: "origin" },
      focusNonce: { type: "string", maxLength: LIMITS.TOKEN },
      generateToken: { type: "string", maxLength: LIMITS.TOKEN },
      sessionBinding: { type: "sessionBinding" },
    },
  },
});

const ENVELOPE_FIELDS = Object.freeze({
  channel: { type: "enum", values: [CHANNEL] },
  version: { type: "int", min: MESSAGE_VERSION, max: MESSAGE_VERSION },
  type: { type: "string", maxLength: 64 },
});

function messageTypesForRoute(route) {
  return Object.keys(MESSAGE_SCHEMAS).filter(
    (type) => MESSAGE_SCHEMAS[type].route === route
  );
}

function validateMessageForRoute(message, route) {
  if (!isPlainObject(message)) return shapeError("not_an_object");
  if (message.channel !== CHANNEL) return shapeError("unknown_channel", "channel");
  if (message.version !== MESSAGE_VERSION) {
    return shapeError("unsupported_version", "version");
  }
  const type = message.type;
  if (typeof type !== "string") return shapeError("invalid_type", "type");
  const schema = Object.prototype.hasOwnProperty.call(MESSAGE_SCHEMAS, type)
    ? MESSAGE_SCHEMAS[type]
    : null;
  if (schema === null) return shapeError("unknown_message_type", "type");
  // SR-1: a content-script type reaching the extension-page validator (or the
  // reverse) is a routing failure, not a shape failure. It must be named.
  if (schema.route !== route) return shapeError("wrong_route", "type");
  return validateExactShape(message, { ...ENVELOPE_FIELDS, ...schema.fields });
}

// ---------------------------------------------------------------------------
// SR-1 — two separate sender validators.
// ---------------------------------------------------------------------------

function senderReject(code) {
  return Object.freeze({ ok: false, error: code, route: null, origin: null });
}

/**
 * Extension-page path (popup and other packaged extension pages).
 *
 * Deliberately has no access to tab/frame context: if `sender.tab` exists at
 * all this is not an extension page.
 */
function validateExtensionPageSender(sender, runtimeId) {
  if (!isPlainObject(sender)) return senderReject("invalid_sender");
  if (typeof runtimeId !== "string" || runtimeId.length === 0) {
    return senderReject("invalid_runtime_id");
  }
  if (sender.id !== runtimeId) return senderReject("wrong_runtime_id");
  if (sender.tab !== undefined && sender.tab !== null) {
    return senderReject("unexpected_tab");
  }
  if (sender.frameId !== undefined && sender.frameId !== null) {
    return senderReject("unexpected_frame");
  }
  if (typeof sender.url !== "string" || sender.url.length > LIMITS.URL) {
    return senderReject("missing_sender_url");
  }
  const expectedPrefix = `chrome-extension://${runtimeId}/`;
  if (!sender.url.startsWith(expectedPrefix)) {
    return senderReject("extension_url_mismatch");
  }
  if (
    sender.origin !== undefined &&
    sender.origin !== `chrome-extension://${runtimeId}`
  ) {
    return senderReject("extension_origin_mismatch");
  }
  return Object.freeze({
    ok: true,
    error: null,
    route: EXTENSION_PAGE_ROUTE,
    origin: `chrome-extension://${runtimeId}`,
  });
}

/**
 * Content-script path.
 *
 * The authoritative frame origin is derived from `sender.url` only.
 * `sender.tab.url` is top-level context: for `frameId === 0` it must agree, and
 * for child frames it is never allowed to substitute for the frame origin.
 */
function validateContentScriptSender(sender, runtimeId) {
  if (!isPlainObject(sender)) return senderReject("invalid_sender");
  if (typeof runtimeId !== "string" || runtimeId.length === 0) {
    return senderReject("invalid_runtime_id");
  }
  if (sender.id !== runtimeId) return senderReject("wrong_runtime_id");
  if (!isPlainObject(sender.tab)) return senderReject("missing_tab");
  if (!Number.isInteger(sender.tab.id) || sender.tab.id < 0) {
    return senderReject("missing_tab_id");
  }
  if (!Number.isInteger(sender.frameId) || sender.frameId < 0) {
    return senderReject("missing_frame_id");
  }
  if (typeof sender.url !== "string") return senderReject("missing_sender_url");

  const frame = canonicalizeOrigin(sender.url);
  if (!frame.ok) return senderReject("invalid_sender_origin");

  // `sender.origin` is "null" for sandboxed/opaque documents; a disagreement
  // with `sender.url` fails closed rather than picking a winner.
  if (sender.origin !== undefined && sender.origin !== null) {
    if (typeof sender.origin !== "string") return senderReject("invalid_sender_origin");
    if (sender.origin === "null") return senderReject("opaque_sender_origin");
    if (canonicalOriginOrNull(sender.origin) !== frame.origin.serialized) {
      return senderReject("sender_origin_mismatch");
    }
  }

  let topOrigin = null;
  if (typeof sender.tab.url === "string" && sender.tab.url.length > 0) {
    topOrigin = canonicalOriginOrNull(sender.tab.url);
  }
  if (sender.frameId === 0) {
    // Top frame: the tab URL is the frame URL. Disagreement means the sender
    // record is inconsistent and is rejected instead of reconciled.
    if (topOrigin === null) return senderReject("missing_top_origin");
    if (topOrigin !== frame.origin.serialized) {
      return senderReject("top_frame_origin_mismatch");
    }
  }

  let documentId = null;
  if (sender.documentId !== undefined && sender.documentId !== null) {
    if (
      typeof sender.documentId !== "string" ||
      sender.documentId.length === 0 ||
      sender.documentId.length > LIMITS.ENTRY_ID
    ) {
      return senderReject("invalid_document_id");
    }
    documentId = sender.documentId;
  }

  return Object.freeze({
    ok: true,
    error: null,
    route: CONTENT_SCRIPT_ROUTE,
    origin: frame.origin.serialized,
    topOrigin,
    tabId: sender.tab.id,
    frameId: sender.frameId,
    documentId,
  });
}

/**
 * Classify a sender WITHOUT validating it. Used only to pick which validator
 * runs; the chosen validator still performs the full check.
 */
function classifySenderRoute(sender) {
  if (!isPlainObject(sender)) return null;
  return sender.tab === undefined || sender.tab === null
    ? EXTENSION_PAGE_ROUTE
    : CONTENT_SCRIPT_ROUTE;
}

function requestReject(code, key) {
  return Object.freeze({ ok: false, error: code, key: key ?? null, sender: null });
}

/** Full extension-page admission: sender, then message shape for that route. */
function validateExtensionPageRequest(message, sender, runtimeId) {
  const senderResult = validateExtensionPageSender(sender, runtimeId);
  if (!senderResult.ok) return requestReject(senderResult.error);
  const shape = validateMessageForRoute(message, EXTENSION_PAGE_ROUTE);
  if (!shape.ok) return requestReject(shape.error, shape.key);
  return Object.freeze({ ok: true, error: null, key: null, sender: senderResult });
}

/**
 * Full content-script admission.
 *
 * `context` supplies the authorization facts the caller owns:
 *   `enabled`             committed `overlayConfigV2.enabled`
 *   `revision`            committed `overlayConfigV2.revision`
 *   `grantedPatterns`     optional host permissions the browser reports
 */
function validateContentScriptRequest(message, sender, runtimeId, context = {}) {
  const senderResult = validateContentScriptSender(sender, runtimeId);
  if (!senderResult.ok) return requestReject(senderResult.error);

  const shape = validateMessageForRoute(message, CONTENT_SCRIPT_ROUTE);
  if (!shape.ok) return requestReject(shape.error, shape.key);

  // The body origin is a claim. It is only ever used to detect a mismatch
  // against the sender-derived origin; it never becomes the authority.
  if (message.origin !== senderResult.origin) {
    return requestReject("origin_mismatch", "origin");
  }

  // SLICE C: the durable opt-in is one global boolean. Anything that is not
  // literally `true` is off — an absent, undefined or truthy-but-not-boolean
  // context is a caller bug and must not authorize.
  if (context.enabled !== true) {
    return requestReject("disabled");
  }

  // The broad grant must still be HELD, not merely configured. This is the
  // check that makes an externally revoked permission fail closed on the very
  // next request, before reconciliation has had a chance to run.
  if (Array.isArray(context.grantedPatterns)) {
    if (!coversGlobalPermission(context.grantedPatterns)) {
      return requestReject("permission_missing");
    }
  }

  return Object.freeze({ ok: true, error: null, key: null, sender: senderResult });
}

// ---------------------------------------------------------------------------
// SR-7 — frame support classification.
// ---------------------------------------------------------------------------

/**
 * @returns {"top"|"same-origin"|"permitted-cross-origin"|"unsupported"}
 */
function computeFrameSupport({ frameId, frameOrigin, topOrigin, enabled }) {
  const canonicalFrame = canonicalOriginOrNull(frameOrigin);
  if (canonicalFrame === null) return "unsupported";
  // Authorization always follows the frame, never the top document. Under the
  // global model that is one boolean rather than a membership test, but the
  // direction is unchanged: a frame is never authorized by its parent.
  if (enabled !== true) return "unsupported";
  if (frameId === 0) return "top";
  // A035, STILL REACHABLE UNDER THE BROAD GRANT. The top document's origin is
  // derived from `sender.tab.url`, which is empty or non-http(s) whenever the
  // TAB itself is something the extension cannot canonicalize — a `file://`
  // page, a `view-source:` page, the PDF viewer, a `data:` document — while
  // the http(s) CHILD frame inside it still matches `http(s)://*/*` and is
  // still injected. The broad grant makes this case MORE common, not less:
  // before Slice C such a child was usually not injected at all.
  const canonicalTop = canonicalOriginOrNull(topOrigin);
  if (canonicalTop === null) return "unsupported";
  return canonicalTop === canonicalFrame ? "same-origin" : "permitted-cross-origin";
}

// ---------------------------------------------------------------------------
// A007 — persisted `overlayConfigV2`.
//
// SLICE C MODEL CHANGE. Slice A2 persisted `overlayConfigV1`
// `{version, revision, enabledOrigins[]}`: one durable opt-in per exact
// origin. Slice C replaces that with ONE global boolean, because the
// per-origin control was unusable in practice — the user had to find the
// popup and click "Turn on" on every single site before the overlay would
// ever appear.
//
// The key is RENAMED rather than reused. A v1 value left on disk therefore
// fails to parse under the v2 key (it is simply absent), the fail-closed
// default applies, and the overlay comes up DISABLED. That is the required
// migration outcome and it is deliberate: a user who had enabled three sites
// under v1 never consented to "all sites", so v1 state must never be read as
// `enabled: true`. `OverlayLifecycle.reconcile()` also revokes every residual
// per-origin grant and deletes the stale key, so no orphan permission and no
// orphan storage value survives the upgrade.
//
// The REVISION FLOOR key is deliberately NOT renamed (see
// `OVERLAY_REVISION_FLOOR_KEY`): revision monotonicity has to hold ACROSS the
// v1→v2 boundary, or a focus grant minted at v1 revision 9 could compare as
// current against a v2 config that restarted at 1.
// ---------------------------------------------------------------------------

const OVERLAY_CONFIG_KEY = "overlayConfigV2";

/** Slice A2's key. Read for nothing; deleted on sight so nothing can revive it. */
const OVERLAY_LEGACY_CONFIG_KEY = "overlayConfigV1";

// ---------------------------------------------------------------------------
// Pending enable intent (macOS grant race).
//
// On macOS the OS-level permission prompt CLOSES the popup, killing the
// continuation that would send `setSiteState enable` — so the first Allow
// left the site Off. The popup writes this one-shot intent to
// `chrome.storage.session` UNDER THE USER GESTURE, before
// `permissions.request`; the worker's `permissions.onAdded` listener consumes
// it and finishes the enable through the same `enableOrigin` path.
//
// `storage.session` on purpose: it dies with the browser, and its default
// access level (TRUSTED_CONTEXTS) already covers exactly the two writers we
// want — extension pages (popup) and the service worker — while content
// scripts never see it. No `setAccessLevel` call is needed or wanted.
//
// SECURITY: the ORIGIN in this intent is the only source of the origin the
// worker enables. It is never derived from the granted permission pattern,
// because the pattern loses the port (`https://a.com:8443` and
// `https://a.com` share `https://a.com/*`).
// ---------------------------------------------------------------------------

const OVERLAY_ENABLE_INTENT_KEY = "overlayEnableIntentV1";
const ENABLE_INTENT_TTL_MS = 60000;

/**
 * Strict fail-closed shape check for the stored intent: exactly the two
 * expected keys, integer tabId and createdAt. Anything else is garbage the
 * reader must delete and ignore.
 *
 * SLICE C: the `origin` field is GONE. Under the global model the intent no
 * longer selects WHICH site to enable — there is one switch — so carrying an
 * origin here would be a value nothing reads. `tabId` survives because the
 * enable still injects into the tab the user was looking at, and `createdAt`
 * survives because the TTL is what stops a stale intent riding an unrelated
 * later grant.
 */
function validateEnableIntent(value) {
  const shape = validateExactShape(value, {
    // Nullable: the popup can be open on a page with no injectable tab. The
    // enable itself still has to complete there, so a missing tab is context
    // the consumer skips, never a reason to drop the user's intent.
    tabId: { type: "int", min: 0, nullable: true },
    createdAt: { type: "int", min: 0 },
  });
  if (!shape.ok) return shape;
  return assertNoForbiddenKeys(value);
}

// A023 — durable monotonic revision floor.
//
// Deliberately a SEPARATE storage key from `overlayConfigV1`, because the
// failure it defends against is corruption of `overlayConfigV1` itself: a
// floor stored inside the value it protects is destroyed by the same event.
// Both keys are written in one `storage.local.set`, so the crash-consistent
// single-commit property of SR-8/D1 is unchanged.
const OVERLAY_REVISION_FLOOR_KEY = "overlayRevisionFloorV1";

/** A stored floor is trustworthy only as a non-negative integer. */
function revisionFloorOrZero(value) {
  return Number.isInteger(value) && value >= 0 ? value : 0;
}

/** The fail-closed default: a valid, revisioned, DISABLED config. */
function emptyOverlayConfig(revision = 1) {
  return { version: 2, revision, enabled: false };
}

/**
 * Strict validation of the single durable storage value. Anything invalid is a
 * fail-closed "disabled" state, never a partial acceptance.
 *
 * `validateExactShape` rejects UNKNOWN KEYS, which is what makes this the
 * migration gate as well as the corruption gate: a surviving Slice A2 value
 * carries `enabledOrigins` and is refused here, so it can only ever become the
 * disabled default. `version` is pinned to exactly 2 for the same reason —
 * a v1 value is not a downgrade to tolerate, it is a value this build must not
 * act on.
 */
function validateOverlayConfig(value) {
  const shape = validateExactShape(value, {
    version: { type: "int", min: 2, max: 2 },
    revision: { type: "int", min: 0 },
    enabled: { type: "bool" },
  });
  if (!shape.ok) return shape;
  return assertNoForbiddenKeys(value);
}

/** Config or the fail-closed empty config. Never throws, never half-accepts. */
function loadOverlayConfigOrEmpty(value) {
  return validateOverlayConfig(value).ok ? value : emptyOverlayConfig();
}

// ---------------------------------------------------------------------------
// A007 — outbound metadata messages carry metadata only.
// ---------------------------------------------------------------------------

const MATCH_TYPES = Object.freeze(["exact-origin", "possible"]);

function validateMatchItem(item) {
  const shape = validateExactShape(item, {
    entryId: { type: "string", maxLength: LIMITS.ENTRY_ID },
    title: { type: "string", maxLength: LIMITS.TEXT },
    displayService: { type: "string", maxLength: LIMITS.TEXT },
    matchType: { type: "enum", values: MATCH_TYPES },
    fillEligible: { type: "bool" },
  });
  if (!shape.ok) return shape;
  return assertNoForbiddenKeys(item);
}

/**
 * Validate a `matchesResult` before it is sent to a content script. A password
 * or username anywhere in the payload is a hard failure, not a redaction.
 */
function validateMatchesResult(result) {
  if (!isPlainObject(result)) return shapeError("not_an_object");
  const forbidden = assertNoForbiddenKeys(result);
  if (!forbidden.ok) return forbidden;

  const shape = validateExactShape(result, {
    ok: { type: "bool" },
    type: { type: "enum", values: ["matchesResult"] },
    origin: { type: "origin" },
    focusNonce: { type: "string", maxLength: LIMITS.TOKEN },
    revision: { type: "int", min: 0 },
    sessionBinding: { type: "sessionBinding" },
    items: { type: "array", maxLength: LIMITS.ITEMS },
    fillToken: { type: "string", maxLength: LIMITS.TOKEN, optional: true },
    expiresAtEpochMs: { type: "int", min: 0, optional: true },
    // B010 — capability + one-shot generate token. Optional so pre-B2 shapes
    // stay valid; the shipped worker always sets `generateAvailable`.
    generateAvailable: { type: "bool", optional: true },
    generateToken: { type: "string", maxLength: LIMITS.TOKEN, optional: true },
  });
  if (!shape.ok) return shape;

  // A generate token may only exist when the capability is affirmatively
  // advertised — a token on an old-peer result is a contract violation.
  if (
    typeof result.generateToken === "string" &&
    result.generateAvailable !== true
  ) {
    return shapeError("token_without_capability", "generateToken");
  }

  for (const item of result.items) {
    const itemShape = validateMatchItem(item);
    if (!itemShape.ok) return itemShape;
  }

  // A token may only exist when at least one item is actually fillable.
  const hasFillable = result.items.some((item) => item.fillEligible === true);
  if (typeof result.fillToken === "string" && !hasFillable) {
    return shapeError("token_without_fillable_item", "fillToken");
  }
  return SHAPE_OK;
}

// ---------------------------------------------------------------------------
// SR-3 — focus grants. In-memory only; a worker restart empties the map and
// the next fill legitimately answers `stale_session`.
// ---------------------------------------------------------------------------

function randomToken(byteLength = 16) {
  const bytes = new Uint8Array(byteLength);
  globalThis.crypto.getRandomValues(bytes);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  // base64url, no padding.
  const base64 =
    typeof btoa === "function"
      ? btoa(binary)
      : Buffer.from(bytes).toString("base64");
  return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

class FocusGrantStore {
  constructor({ maxGrants = LIMITS.GRANTS, maxTtlMs = LIMITS.TOKEN_TTL_MS } = {}) {
    this._grants = new Map();
    this._maxGrants = maxGrants;
    this._maxTtlMs = maxTtlMs;
  }

  get size() {
    return this._grants.size;
  }

  /**
   * Mint a fill grant after a successful exact-origin metadata query.
   * Requested TTL is clamped to the 30-second ceiling; it is never extended.
   */
  issue({
    tabId,
    frameId,
    documentId = null,
    origin,
    focusNonce,
    entryIds,
    sessionBinding,
    configRevision,
    nowMs,
    ttlMs = LIMITS.TOKEN_TTL_MS,
    // B010 — a grant is minted for exactly one purpose. A fill grant can
    // never authorize a generate and the reverse; `consume` enforces it.
    purpose = "fill",
  }) {
    if (purpose !== "fill" && purpose !== "generate") return null;
    if (canonicalOriginOrNull(origin) !== origin) return null;
    if (!Number.isInteger(tabId) || !Number.isInteger(frameId)) return null;
    if (typeof focusNonce !== "string" || focusNonce.length === 0) return null;
    // A generate grant names no entries; a fill grant must name at least one.
    if (purpose === "fill" && (!Array.isArray(entryIds) || entryIds.length === 0)) {
      return null;
    }
    if (!validateSessionBinding(sessionBinding).ok) return null;
    if (!Number.isInteger(configRevision) || !Number.isInteger(nowMs)) return null;

    this._pruneExpired(nowMs);
    // One live grant per (tab, frame, document, purpose): a new eligible focus
    // replaces the previous session's grant of the SAME purpose — a fill and a
    // generate grant for one session coexist by design.
    for (const [token, grant] of this._grants) {
      if (
        grant.tabId === tabId &&
        grant.frameId === frameId &&
        grant.documentId === documentId &&
        grant.purpose === purpose
      ) {
        this._grants.delete(token);
      }
    }
    while (this._grants.size >= this._maxGrants) {
      // Map preserves insertion order, so the first key is the oldest grant.
      this._grants.delete(this._grants.keys().next().value);
    }

    const token = randomToken();
    const expiresAtEpochMs = nowMs + Math.min(ttlMs, this._maxTtlMs);
    this._grants.set(token, {
      purpose,
      tabId,
      frameId,
      documentId,
      origin,
      focusNonce,
      entryIds: purpose === "fill" ? [...entryIds] : [],
      sessionBinding: { ...sessionBinding },
      configRevision,
      expiresAtEpochMs,
    });
    return { token, expiresAtEpochMs };
  }

  peek(token) {
    return this._grants.get(token) ?? null;
  }

  /**
   * One-shot consumption. The grant is removed before any result is returned,
   * so a replay of the same token can never succeed — including when the first
   * attempt failed a later check.
   *
   * WHAT THIS DELIBERATELY DOES NOT CHECK: whether the grant still matches the
   * live session binding — "the world as it is NOW". That check is owned by the
   * native host, on purpose, and the worker must not pretend to duplicate it.
   *
   * The worker has no independent view of "now". The only two ways it could
   * produce one are both worse than the host's:
   *
   *   - Re-query the host before every fill. That is an extra round trip whose
   *     answer is already stale by the time `overlayRevealForFill` runs, so it
   *     replaces an atomic check with a TOCTOU window.
   *   - Reuse the binding observed by the last `requestMatches`. That is
   *     tautological: `invalidateOtherBindings` already deleted every grant
   *     that disagrees with it, so the comparison can never fail. A check that
   *     provably cannot fire is not a defence, it is a decoration that the next
   *     reader will mistakenly rely on.
   *
   * The host resolves the binding from the live cache and bridge descriptor and
   * compares all three fields (`native_host_protocol.dart`) before the
   * credential store is touched, which is both atomic and authoritative. A027
   * accepts the consequence explicitly: a fill "still fails natively if the
   * worker has not observed the republish".
   *
   * Two live worker-side mechanisms remain, and both are real: `configRevision`
   * equality above, and eager `invalidateOtherBindings` on every query.
   */
  consume({
    token,
    tabId,
    frameId,
    documentId = null,
    origin,
    focusNonce,
    entryId,
    sessionBinding,
    configRevision,
    nowMs,
    purpose = "fill",
  }) {
    if (typeof token !== "string" || token.length === 0) {
      return { ok: false, error: "stale_session" };
    }
    const grant = this._grants.get(token);
    if (!grant) return { ok: false, error: "stale_session" };
    this._grants.delete(token);

    if (!Number.isInteger(nowMs) || nowMs >= grant.expiresAtEpochMs) {
      return { ok: false, error: "stale_session" };
    }
    // Purpose mismatch is checked AFTER one-shot deletion, so presenting a
    // fill token on the generate path burns it — replay dies either way.
    if (grant.purpose !== purpose) {
      return { ok: false, error: "forbidden" };
    }
    if (grant.tabId !== tabId || grant.frameId !== frameId) {
      return { ok: false, error: "forbidden" };
    }
    if (grant.documentId !== (documentId ?? null)) {
      return { ok: false, error: "forbidden" };
    }
    if (grant.origin !== origin) return { ok: false, error: "forbidden" };
    if (grant.focusNonce !== focusNonce) return { ok: false, error: "stale_session" };
    if (grant.configRevision !== configRevision) {
      return { ok: false, error: "stale_session" };
    }
    if (purpose === "fill" && !grant.entryIds.includes(entryId)) {
      return { ok: false, error: "forbidden" };
    }
    if (!sessionBindingsEqual(grant.sessionBinding, sessionBinding)) {
      return { ok: false, error: "stale_session" };
    }
    return { ok: true, error: null, grant };
  }

  _pruneExpired(nowMs) {
    if (!Number.isInteger(nowMs)) return;
    for (const [token, grant] of this._grants) {
      if (nowMs >= grant.expiresAtEpochMs) this._grants.delete(token);
    }
  }

  invalidateOrigin(origin) {
    for (const [token, grant] of this._grants) {
      if (grant.origin === origin) this._grants.delete(token);
    }
  }

  invalidateBelowRevision(revision) {
    for (const [token, grant] of this._grants) {
      if (grant.configRevision < revision) this._grants.delete(token);
    }
  }

  /** Eager cleanup when a newer status/query advertises a different binding. */
  invalidateOtherBindings(currentBinding) {
    for (const [token, grant] of this._grants) {
      if (!sessionBindingsEqual(grant.sessionBinding, currentBinding)) {
        this._grants.delete(token);
      }
    }
  }

  clear() {
    this._grants.clear();
  }
}

/**
 * SR-4 guard for a delayed native/app response: the binding echoed back must
 * still equal both the grant binding and the current one.
 */
/**
 * SR-4 — the binding a reveal response echoes must equal the binding the grant
 * was issued against, checked BEFORE the secret is forwarded.
 *
 * Like `FocusGrantStore.consume`, this deliberately takes no "current" binding.
 * The worker cannot observe the live session independently, and the native host
 * has already compared the request's three `expected*` fields against the live
 * cache and bridge descriptor before answering at all — so a response that
 * reaches this function has been checked against "now" by the only component
 * that can see "now" atomically. See the note on `consume`.
 */
function validateResponseBinding({ echoed, expected }) {
  if (!sessionBindingsEqual(echoed, expected)) return "stale_session";
  return null;
}

// ---------------------------------------------------------------------------

const API = {
  LIMITS,
  CHANNEL,
  MESSAGE_VERSION,
  GENERATE_CAPABILITY,
  FORBIDDEN_KEYS,
  OVERLAY_CONFIG_KEY,
  OVERLAY_LEGACY_CONFIG_KEY,
  GLOBAL_PERMISSION_PATTERNS,
  coversGlobalPermission,
  OVERLAY_REVISION_FLOOR_KEY,
  OVERLAY_ENABLE_INTENT_KEY,
  ENABLE_INTENT_TTL_MS,
  validateEnableIntent,
  revisionFloorOrZero,
  EXTENSION_PAGE_ROUTE,
  CONTENT_SCRIPT_ROUTE,
  MATCH_TYPES,
  canonicalizeOrigin,
  canonicalOriginOrNull,
  originsEqual,
  permissionPatternForOrigin,
  isPlainObject,
  assertNoForbiddenKeys,
  validateExactShape,
  validateSessionBinding,
  sessionBindingsEqual,
  messageTypesForRoute,
  validateMessageForRoute,
  classifySenderRoute,
  validateExtensionPageSender,
  validateContentScriptSender,
  validateExtensionPageRequest,
  validateContentScriptRequest,
  computeFrameSupport,
  emptyOverlayConfig,
  validateOverlayConfig,
  loadOverlayConfigOrEmpty,
  validateMatchItem,
  validateMatchesResult,
  randomToken,
  FocusGrantStore,
  validateResponseBinding,
};

// Dual load: CommonJS for the Node harness, global for the MV3 service worker
// (`importScripts("overlay_security.js")`). Same file, same code path.
if (typeof module !== "undefined" && typeof module.exports === "object") {
  module.exports = API;
} else {
  globalThis.CustodeOverlaySecurity = API;
}

})();
