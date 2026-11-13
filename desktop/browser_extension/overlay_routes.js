// 009 Slice A3 — background trust paths and focus grants.
//
// This file is PRODUCTION code. `background.js` loads it with
// `importScripts(...)` and the Node harness under `test/` loads the very same
// file through `require()` against fakes. There is one implementation of every
// rule below; the tests never re-implement one.
//
// WHY THIS IS A SEPARATE FILE FROM background.js
// ----------------------------------------------
// `background.js` touches `chrome.*` at load time, so it cannot be `require`d
// by the Node harness. Slice A2 already established the pattern used here
// (`overlay_lifecycle.js`): the policy lives in an injectable module with no
// browser global, and `background.js` shrinks to wiring. Gate A3 demands the
// JS harness cover sender validation, message shape, stale responses and frame
// behaviour — that is only possible if the dispatcher itself is loadable.
//
// A022: the two route tables below are the entire admissible surface of the
// worker. A sender, a type, or a shape that is not named here fails with a
// stable code and never reaches a handler, native I/O, or the lifecycle.

"use strict";

// MV3 `importScripts` shares one global scope across worker files: every
// top-level binding lives inside this IIFE so it cannot collide with
// `overlay_security.js` / `overlay_lifecycle.js` (`require()` in the Node
// harness would never show the collision). See
// `test/worker_global_scope.test.js`.
(() => {

const securityModule =
  typeof require === "function" &&
  typeof module !== "undefined" &&
  typeof module.exports === "object"
    ? require("./overlay_security.js")
    : globalThis.CustodeOverlaySecurity;

// Mirrors `overlayMatchPolicy` / `overlayExactOriginCapability` in
// `lib/features/password_manager/data/services/browser_exact_origin.dart`.
// The native host refuses an overlay request that does not declare the policy,
// which is what stops a host predating Slice A1 from answering under the
// lenient popup rule.
const MATCH_POLICY = "exactOrigin";

// ---------------------------------------------------------------------------
// A026 — stable, non-sensitive error codes.
//
// Exactly the set `data-model.md` allows for an overlay error response. Every
// internal reason collapses into one of these before it leaves the worker, so
// a page can never learn WHICH sender field failed, whether an entry exists in
// the vault, or anything the native host said.
// ---------------------------------------------------------------------------

const PUBLIC_ERROR_CODES = Object.freeze([
  "disabled",
  "unsupported_frame",
  "unsupported_capability",
  "locked",
  "no_host",
  "timeout",
  "invalid_request",
  "forbidden",
  "stale_session",
  "internal_error",
]);

const PUBLIC_ERROR_CODE_SET = new Set(PUBLIC_ERROR_CODES);

// One public sentence per code. Deliberately generic: no origin beyond the
// canonical one the caller already knows, no entry id, no native detail.
const PUBLIC_ERROR_MESSAGES = Object.freeze({
  disabled: "The Custode overlay is turned off.",
  unsupported_frame: "The overlay is not available in this frame.",
  unsupported_capability: "Update the Custode native host to use the overlay.",
  locked: "Open and unlock Custode.",
  no_host: "Custode native host is unavailable.",
  timeout: "Custode did not respond in time.",
  invalid_request: "Overlay request is invalid.",
  forbidden: "Overlay request is not authorized.",
  stale_session: "Custode session changed. Query the site again.",
  internal_error: "Overlay request failed.",
});

// Validator/sender/shape reasons -> public code. Anything absent falls through
// to `internal_error`, which is the fail-closed default rather than a leak of
// the raw reason.
const VALIDATION_ERROR_CODES = Object.freeze({
  // Already-public codes produced by the grant store and the lifecycle. They
  // are listed explicitly rather than passed through, so the mapping stays a
  // closed allowlist and a future internal code cannot escape by accident.
  stale_session: "stale_session",
  forbidden: "forbidden",
  unsupported_frame: "unsupported_frame",
  // Authorization state.
  disabled: "disabled",
  permission_missing: "disabled",
  // SLICE C: `unsupported_origin` and `too_many_origins` are gone from this
  // table because the lifecycle can no longer produce them — there is no
  // per-origin enable to reject and no origin list to overflow. An unmapped
  // code still falls through to `internal_error`, so removing them cannot leak
  // anything; it only stops the allowlist advertising refusals that no longer
  // exist.
  // Sender trust failures. All of them are "you are not allowed", never a hint
  // about which field of the sender record was wrong.
  invalid_sender: "forbidden",
  invalid_runtime_id: "forbidden",
  wrong_runtime_id: "forbidden",
  unexpected_tab: "forbidden",
  unexpected_frame: "forbidden",
  missing_sender_url: "forbidden",
  extension_url_mismatch: "forbidden",
  extension_origin_mismatch: "forbidden",
  missing_tab: "forbidden",
  missing_tab_id: "forbidden",
  missing_frame_id: "forbidden",
  invalid_sender_origin: "forbidden",
  opaque_sender_origin: "forbidden",
  sender_origin_mismatch: "forbidden",
  missing_top_origin: "forbidden",
  top_frame_origin_mismatch: "forbidden",
  invalid_document_id: "forbidden",
  // A body claiming an origin the sender does not have is an attack, not a
  // typo, so it answers like any other authorization failure.
  origin_mismatch: "forbidden",
  wrong_route: "forbidden",
  // Shape failures.
  not_an_object: "invalid_request",
  unknown_message_type: "invalid_request",
  unknown_key: "invalid_request",
  missing_key: "invalid_request",
  invalid_type: "invalid_request",
  forbidden_key: "invalid_request",
  duplicate_origin: "invalid_request",
  too_deep: "invalid_request",
});

// Native host codes -> public code.
const NATIVE_ERROR_CODES = Object.freeze({
  // Transport, attached by the adapter in background.js.
  timeout: "timeout",
  no_host: "no_host",
  // The cache or the reveal bridge is absent: the app is closed or locked.
  app_bridge_unavailable: "locked",
  app_bridge_timeout: "timeout",
  unauthorized: "locked",
  // Binding moved under the request.
  stale_session: "stale_session",
  database_mismatch: "stale_session",
  // A host predating Slice A1 has no `overlayQueryCredentials` type at all and
  // answers `unsupported_type`. That is the structural downgrade refusal.
  unsupported_type: "unsupported_capability",
  unsupported_version: "unsupported_capability",
  not_found: "unsupported_capability",
  // B007: the app behind the host does not declare `/generate-pending`.
  unsupported_capability: "unsupported_capability",
  // Refusals.
  forbidden: "forbidden",
  strong_match_required: "forbidden",
  invalid_request: "invalid_request",
  legacy_fields_rejected: "invalid_request",
  credential_unavailable: "internal_error",
  app_bridge_invalid_response: "internal_error",
});

function publicCode(table, rawCode) {
  const mapped =
    typeof rawCode === "string" &&
    Object.prototype.hasOwnProperty.call(table, rawCode)
      ? table[rawCode]
      : "internal_error";
  return PUBLIC_ERROR_CODE_SET.has(mapped) ? mapped : "internal_error";
}

function validationErrorCode(rawCode) {
  return publicCode(VALIDATION_ERROR_CODES, rawCode);
}

/**
 * A026: the native response is read for its error CODE and nothing else. Its
 * message is never copied out, never logged, and never forwarded.
 */
function nativeErrorCode(response) {
  return publicCode(NATIVE_ERROR_CODES, response?.error?.code);
}

function overlayError(type, code, focusNonce) {
  const safe = PUBLIC_ERROR_CODE_SET.has(code) ? code : "internal_error";
  const result = {
    ok: false,
    type,
    error: { code: safe, message: PUBLIC_ERROR_MESSAGES[safe] },
  };
  if (typeof focusNonce === "string") result.focusNonce = focusNonce;
  return result;
}

// ---------------------------------------------------------------------------
// A022 — the two route allowlists.
//
// SR-1 is structural here, not a runtime comparison: a type that lives in one
// table is simply absent from the other, and the dispatcher only ever consults
// the table belonging to the sender's classified route. There is no code path
// that can reach a content handler from an extension-page sender or the
// reverse, so the separation cannot be lost by getting a boolean backwards.
//
// Both tables are `Map`s rather than object literals so a message type of
// `"constructor"` or `"__proto__"` resolves to nothing instead of inheriting
// a function off `Object.prototype`.
// ---------------------------------------------------------------------------

/** Fields shared by every legacy popup message. */
const LEGACY_TYPE = { type: { type: "string", maxLength: 64 } };

/**
 * The Slice A2 popup routes, preserved verbatim in behaviour and moved under
 * the SR-1 extension-page sender validator.
 *
 * They keep their original `KEYVAULT_V2_*` names, their original native
 * payloads, and their original response envelopes — the popup is not touched
 * by this slice. What changes is the gate in front of them: they used to run
 * behind `sender.id === chrome.runtime.id && !sender.tab`, and now run behind
 * `validateExtensionPageSender`, which additionally proves the sender URL is
 * this extension's own `chrome-extension://<id>/` origin and that no
 * tab/frame context is attached. That is strictly stronger, never weaker.
 *
 * `shape` is new and also strictly stronger: previously any extra key was
 * silently forwarded to the native host.
 */
const LEGACY_ROUTES = new Map([
  [
    "KEYVAULT_V2_STATUS",
    {
      shape: { ...LEGACY_TYPE },
      native: () => ["status", {}],
      responseType: "status",
    },
  ],
  [
    "KEYVAULT_V2_QUERY_CREDENTIALS",
    {
      shape: {
        ...LEGACY_TYPE,
        url: { type: "string", maxLength: 4096, nullable: true },
        title: {
          type: "string",
          maxLength: 512,
          allowEmpty: true,
          optional: true,
          nullable: true,
        },
        limit: { type: "int", min: 1, max: 100, optional: true },
      },
      native: (message) => [
        "queryCredentials",
        {
          url: message.url,
          title: message.title,
          limit: Number.isInteger(message.limit) ? message.limit : 5,
        },
      ],
      responseType: "queryCredentials",
    },
  ],
  [
    "KEYVAULT_V2_SEARCH_CREDENTIALS",
    {
      shape: {
        ...LEGACY_TYPE,
        query: {
          type: "string",
          maxLength: 512,
          allowEmpty: true,
          optional: true,
          nullable: true,
        },
        url: { type: "string", maxLength: 4096, optional: true, nullable: true },
        limit: { type: "int", min: 1, max: 100, optional: true },
      },
      native: (message) => [
        "searchCredentials",
        {
          query: typeof message.query === "string" ? message.query : "",
          url: message.url,
          limit: Number.isInteger(message.limit) ? message.limit : 25,
        },
      ],
      responseType: "searchCredentials",
    },
  ],
  [
    "KEYVAULT_V2_CREATE_PENDING_ASSOCIATION",
    {
      shape: {
        ...LEGACY_TYPE,
        entryId: { type: "string", maxLength: 256 },
        url: { type: "string", maxLength: 4096 },
      },
      native: (message) => [
        "createPendingAssociation",
        { entryId: message.entryId, url: message.url },
      ],
      responseType: "createPendingAssociation",
    },
  ],
  [
    "KEYVAULT_V2_REVEAL_FOR_FILL",
    {
      shape: {
        ...LEGACY_TYPE,
        entryId: { type: "string", maxLength: 256 },
        origin: { type: "string", maxLength: 4096 },
      },
      native: (message) => [
        "revealForFill",
        { entryId: message.entryId, origin: message.origin },
      ],
      responseType: "revealForFill",
    },
  ],
]);

/** Extension-page types that are handled in the worker, without native I/O. */
const EXTENSION_PAGE_LOCAL_ROUTES = new Set([
  "getSiteState",
  "setSiteState",
  "KEYVAULT_V2_REPORT_MATCH_COUNT",
  "KEYVAULT_V2_REFRESH_BADGE",
]);

const REPORT_MATCH_COUNT_SHAPE = Object.freeze({
  ...LEGACY_TYPE,
  tabId: { type: "int", min: 0 },
  count: { type: "int", min: 0, max: 10000 },
});

const REFRESH_BADGE_SHAPE = Object.freeze({
  ...LEGACY_TYPE,
  tabId: { type: "int", min: 0 },
});

/** The complete content-script allowlist. Four types, no others, ever. */
const CONTENT_ROUTES = new Set(["bootstrap", "requestMatches", "fill", "generate"]);

/** The complete extension-page allowlist. */
const EXTENSION_PAGE_ROUTES = new Set([
  ...EXTENSION_PAGE_LOCAL_ROUTES,
  ...LEGACY_ROUTES.keys(),
]);

/** A string from an untrusted message, or null. */
function boundedRequestString(value, maxLength) {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength
    ? value
    : null;
}

function routeTableFor(route) {
  if (route === securityModule.EXTENSION_PAGE_ROUTE) return EXTENSION_PAGE_ROUTES;
  if (route === securityModule.CONTENT_SCRIPT_ROUTE) return CONTENT_ROUTES;
  return null;
}

// ---------------------------------------------------------------------------

class OverlayRouter {
  /**
   * @param {object}   options
   * @param {object}   options.lifecycle  `OverlayLifecycle` instance.
   * @param {string}   options.runtimeId  `chrome.runtime.id`.
   * @param {Function} options.native     `(type, payload) => Promise<response>`.
   *        Must RESOLVE with a protocol response and never throw; transport
   *        failures resolve as `{ok:false, error:{code:'timeout'|'no_host'}}`.
   * @param {Function} [options.legacyNative] Raw v2 sender for the popup routes,
   *        preserving their existing throw-and-normalize behaviour.
   * @param {Function} [options.reportMatchCount] `(tabId, count) => Promise`.
   * @param {Function} [options.refreshBadge] `(tabId) => Promise`.
   * @param {Function} [options.now] Injected clock, epoch ms.
   */
  constructor({
    lifecycle,
    runtimeId,
    native,
    legacyNative,
    reportMatchCount,
    refreshBadge,
    now = () => Date.now(),
  } = {}) {
    this._lifecycle = lifecycle;
    this._runtimeId = runtimeId;
    this._native = native;
    this._legacyNative = legacyNative ?? native;
    this._reportMatchCount = reportMatchCount ?? (async () => {});
    this._refreshBadge = refreshBadge ?? (async () => {});
    this._now = now;
  }

  get grants() {
    return this._lifecycle.grants;
  }

  /**
   * The single entry point. Classification happens FIRST and picks exactly one
   * route table; the chosen table's validator then performs the full check.
   *
   * `classifySenderRoute` only looks at whether `sender.tab` exists, so it can
   * never admit anything on its own — a sender that lies about having no tab
   * still has to satisfy `validateExtensionPageSender`, which requires a
   * `chrome-extension://<runtime-id>/` sender URL a page cannot forge.
   */
  async dispatch(message, sender) {
    const route = securityModule.classifySenderRoute(sender);
    const table = routeTableFor(route);
    if (table === null) return overlayError("error", "forbidden");

    if (!securityModule.isPlainObject(message)) {
      return overlayError("error", "invalid_request");
    }
    const type = message.type;

    // spec 023 T503 — `passkeyGet` is deliberately outside CONTENT_ROUTES.
    //
    // That set is the overlay's four types and its exact-shape envelope, and
    // it is frozen ("four types, no others, ever"). A passkey request has a
    // different shape and a different origin story: it carries no `origin`
    // claim at all, because it comes from the page's own world where such a
    // claim would be worth nothing. Its authorization is the same authority,
    // established the same way — `sender.url` — just checked here.
    if (type === "passkeyGet" || type === "passkeyCreate") {
      if (route !== securityModule.CONTENT_SCRIPT_ROUTE) {
        return { ok: false };
      }
      return type === "passkeyGet"
        ? this._passkeyGet(message, sender)
        : this._passkeyCreate(message, sender);
    }

    if (typeof type !== "string" || !table.has(type)) {
      // Includes the SR-1 confusion case: a content type arriving from an
      // extension page (or the reverse) is simply not in this table.
      return overlayError("error", "forbidden");
    }

    if (route === securityModule.CONTENT_SCRIPT_ROUTE) {
      return this._dispatchContent(type, message, sender);
    }
    return this._dispatchExtensionPage(type, message, sender);
  }

  /**
   * spec 023 T503 — ask the app to sign a WebAuthn assertion for this frame.
   *
   * The answer is deliberately thin: either an assertion or `{ok:false}`.
   * The page world falls back to the browser's own authenticator on anything
   * that is not a signature, so there is nothing for a refusal reason to do
   * there except tell a hostile page whether this vault holds a passkey for
   * the site — which is exactly what it must not learn.
   */
  async _passkeyGet(message, sender) {
    const senderResult = securityModule.validateContentScriptSender(
      sender,
      this._runtimeId
    );
    if (!senderResult.ok) return { ok: false };

    const rpId = boundedRequestString(message.rpId, 253);
    const challenge = boundedRequestString(message.challenge, 2048);
    if (!rpId || !challenge) return { ok: false };
    const allowCredentials = Array.isArray(message.allowCredentials)
      ? message.allowCredentials
          .slice(0, 32)
          .map((value) => boundedRequestString(value, 512))
          .filter((value) => value !== null)
      : [];

    // The same gate the overlay passes: the global switch must be on and the
    // broad host permission still held. A wrapper left running in a page
    // after the user turned Custode off must not be able to sign.
    const auth = await this._lifecycle.authorizePasskeyRequest({
      sender,
      runtimeId: this._runtimeId,
    });
    if (!auth.ok) return { ok: false };

    // The origin travels from `sender.url`, never from the message: the page
    // owns the world the request came from and could claim any site.
    const response = await this._native("passkeyAssert", {
      origin: auth.sender.origin,
      rpId,
      challenge,
      allowCredentials,
    });
    if (response?.ok !== true) return { ok: false };

    const data = response.data;
    const credentialId = boundedRequestString(data?.credentialId, 1024);
    const authenticatorData = boundedRequestString(data?.authenticatorData, 4096);
    const signature = boundedRequestString(data?.signature, 4096);
    const clientDataJSON = boundedRequestString(data?.clientDataJSON, 8192);
    if (!credentialId || !authenticatorData || !signature || !clientDataJSON) {
      // Includes every refusal the app sends as `{reason}` rather than an
      // assertion, which is why no reason ever reaches the page.
      return { ok: false };
    }

    return {
      ok: true,
      credentialId,
      authenticatorData,
      signature,
      clientDataJSON,
      userHandle: boundedRequestString(data?.userHandle, 1024),
    };
  }

  /**
   * spec 023 US3 — ask the app to create a passkey for this frame and write it
   * to the vault.
   *
   * The answer is thin for the same reason `_passkeyGet`'s is: the page world
   * falls back to the browser on anything that is not a credential, so a
   * refusal reason would only tell a hostile page what this vault contains.
   */
  async _passkeyCreate(message, sender) {
    const senderResult = securityModule.validateContentScriptSender(
      sender,
      this._runtimeId
    );
    if (!senderResult.ok) return { ok: false };

    const rpId = boundedRequestString(message.rpId, 253);
    const challenge = boundedRequestString(message.challenge, 2048);
    if (!rpId || !challenge) return { ok: false };
    // An empty username is legitimate: some relying parties register a
    // credential with no display name at all.
    const username = boundedRequestString(message.username, 512) ?? "";
    // The relying party's account identifier, forwarded as given. An
    // authenticator that substitutes its own leaves the site unable to resolve
    // a discoverable sign-in back to an account.
    const userHandle = boundedRequestString(message.userHandle, 88) ?? "";

    const auth = await this._lifecycle.authorizePasskeyRequest({
      sender,
      runtimeId: this._runtimeId,
    });
    if (!auth.ok) return { ok: false };

    const response = await this._native("passkeyCreate", {
      origin: auth.sender.origin,
      rpId,
      challenge,
      username,
      userHandle,
    });
    if (response?.ok !== true) return { ok: false };

    const data = response.data;
    const credentialId = boundedRequestString(data?.credentialId, 1024);
    const attestationObject = boundedRequestString(
      data?.attestationObject,
      16384
    );
    const clientDataJSON = boundedRequestString(data?.clientDataJSON, 8192);
    if (!credentialId || !attestationObject || !clientDataJSON) {
      // Includes every `{reason}` refusal the app sends, which is why no
      // reason ever reaches the page.
      return { ok: false };
    }

    return {
      ok: true,
      credentialId,
      attestationObject,
      clientDataJSON,
      publicKeyCose: boundedRequestString(data?.publicKeyCose, 4096),
    };
  }

  // -------------------------------------------------------------------------
  // Extension-page path.
  // -------------------------------------------------------------------------

  async _dispatchExtensionPage(type, message, sender) {
    const senderResult = securityModule.validateExtensionPageSender(
      sender,
      this._runtimeId
    );
    if (!senderResult.ok) {
      return overlayError("error", validationErrorCode(senderResult.error));
    }

    if (LEGACY_ROUTES.has(type)) {
      return this._handleLegacy(LEGACY_ROUTES.get(type), message);
    }
    if (type === "KEYVAULT_V2_REPORT_MATCH_COUNT") {
      const shape = securityModule.validateExactShape(
        message,
        REPORT_MATCH_COUNT_SHAPE
      );
      if (!shape.ok) return { ok: false };
      try {
        await this._reportMatchCount(message.tabId, message.count);
        return { ok: true };
      } catch (_) {
        return { ok: false };
      }
    }
    if (type === "KEYVAULT_V2_REFRESH_BADGE") {
      const shape = securityModule.validateExactShape(message, REFRESH_BADGE_SHAPE);
      if (!shape.ok) return { ok: false };
      try {
        await this._refreshBadge(message.tabId);
        return { ok: true };
      } catch (_) {
        return { ok: false };
      }
    }

    // Channel-tagged overlay routes: full envelope + exact shape for THIS route.
    const shape = securityModule.validateMessageForRoute(
      message,
      securityModule.EXTENSION_PAGE_ROUTE
    );
    if (!shape.ok) return overlayError("error", validationErrorCode(shape.error));

    if (type === "getSiteState") {
      const state = await this._lifecycle.siteState({ tabUrl: message.tabUrl });
      return { ok: true, type: "siteState", ...state };
    }
    // setSiteState. SLICE C: one global switch, so the message names no origin.
    // The permission grant itself happens in the popup, under the user gesture;
    // enable refuses to persist unless the browser confirms the BROAD grant is
    // actually held.
    //
    // `message.enabled === true` rather than a truthy test: the shape validator
    // already pinned this to a boolean, and an exact comparison keeps the two
    // from drifting if the schema is ever loosened.
    const result =
      message.enabled === true
        ? await this._lifecycle.enable({ tabId: message.tabId })
        : await this._lifecycle.disable();
    if (!result.ok) {
      return overlayError("error", validationErrorCode(result.error));
    }
    const state = await this._lifecycle.siteState();
    return { ok: true, type: "siteState", ...state };
  }

  /**
   * Legacy popup passthrough. The response envelope is byte-identical to the
   * Slice A2 behaviour, including `normalizeError`'s shape, because the popup
   * reads it and this slice does not touch the popup.
   */
  async _handleLegacy(route, message) {
    const shape = securityModule.validateExactShape(message, route.shape);
    if (!shape.ok) {
      return {
        version: 2,
        type: route.responseType,
        ok: false,
        error: { code: "invalid_request", message: "Request is invalid." },
      };
    }
    const [nativeType, payload] = route.native(message);
    try {
      return await this._legacyNative(nativeType, payload);
    } catch (error) {
      return {
        version: 2,
        type: route.responseType,
        ok: false,
        error: {
          code: error?.code || "native_error",
          message: error?.message || "Native host request failed.",
        },
      };
    }
  }

  // -------------------------------------------------------------------------
  // Content-script path (A023/A024/A025).
  // -------------------------------------------------------------------------

  async _dispatchContent(type, message, sender) {
    const focusNonce =
      typeof message.focusNonce === "string" &&
      message.focusNonce.length <= securityModule.LIMITS.TOKEN
        ? message.focusNonce
        : undefined;
    const responseType =
      type === "bootstrap"
        ? "bootstrapResult"
        : type === "requestMatches"
          ? "matchesResult"
          : type === "generate"
            ? "generateResult"
            : "fillResult";

    // A023 — every content request is authorized before any native I/O, and
    // the authoritative frame origin is established there from `sender.url`.
    const auth = await this._lifecycle.authorizeContentRequest({
      message,
      sender,
      runtimeId: this._runtimeId,
    });
    if (!auth.ok) {
      return overlayError(responseType, validationErrorCode(auth.error), focusNonce);
    }

    if (type === "bootstrap") {
      return this._lifecycle.authorizeBootstrap({
        message,
        sender,
        runtimeId: this._runtimeId,
      });
    }

    // SR-7: a frame the policy cannot support never reaches the native host.
    if (auth.frameSupport === "unsupported") {
      return overlayError(responseType, "unsupported_frame", focusNonce);
    }

    if (type === "requestMatches") return this._requestMatches(message, auth);
    if (type === "generate") return this._generate(message, auth);
    return this._fill(message, auth);
  }

  /**
   * A024 — mint a fill token, and only after an exact-origin metadata query
   * has actually succeeded.
   *
   * The query target is `auth.sender.origin`, derived from `sender.url`. The
   * body's `origin` was already proven equal to it by
   * `validateContentScriptRequest`, and is still not the value forwarded: the
   * authority travels, not the claim.
   */
  async _requestMatches(message, auth) {
    const focusNonce = message.focusNonce;
    const origin = auth.sender.origin;

    // B010 — capability discovery rides the SAME query that renders the rows:
    // `hello` advertises `generatePendingEntryV1` only while the current app
    // bridge descriptor lists it, so learning it here (not at bootstrap) keeps
    // the Generate row's state as fresh as the matches it renders next to. A
    // failed hello is simply "no capability" — never an error for the query.
    const [helloResponse, response] = await Promise.all([
      this._native("hello", {}),
      this._native("overlayQueryCredentials", {
        matchPolicy: MATCH_POLICY,
        url: origin,
        limit: securityModule.LIMITS.ITEMS,
      }),
    ]);
    const helloCapabilities =
      helloResponse?.ok === true && Array.isArray(helloResponse.data?.capabilities)
        ? helloResponse.data.capabilities
        : [];
    const generateAvailable = helloCapabilities.includes(
      securityModule.GENERATE_CAPABILITY
    );
    if (response?.ok !== true) {
      return overlayError("matchesResult", nativeErrorCode(response), focusNonce);
    }

    const data = response.data;
    if (
      !securityModule.isPlainObject(data) ||
      data.metadataOnly !== true ||
      data.matchPolicy !== MATCH_POLICY ||
      data.target !== origin
    ) {
      // A host that did not echo the exact policy and target is not proven to
      // have applied them. Fail closed rather than trust the items.
      return overlayError("matchesResult", "unsupported_capability", focusNonce);
    }

    const binding = data.sessionBinding;
    if (!securityModule.validateSessionBinding(binding).ok) {
      // No cache/bridge binding means nothing is fillable in this session. Any
      // grant still held is bound to a binding that is no longer current.
      this.grants.clear();
      return overlayError("matchesResult", "locked", focusNonce);
    }

    // SR-4/A027 — eager invalidation. A newer query advertising a different
    // tuple kills every grant carrying an older one, without waiting for the
    // worker to observe the republish some other way.
    this.grants.invalidateOtherBindings(binding);

    // Not truncated to the limit here on purpose. A host answering with more
    // items than the contract allows has violated the contract, and silently
    // keeping the first ten would hide that. The bound is enforced once, by
    // `validateMatchesResult` below, so there is a single authority for it.
    const items = Array.isArray(data.items) ? data.items : [];
    const safeItems = [];
    for (const item of items) {
      if (!securityModule.validateMatchItem(item).ok) {
        return overlayError("matchesResult", "internal_error", focusNonce);
      }
      // Rebuilt field by field so nothing the native host added can ride along.
      safeItems.push({
        entryId: item.entryId,
        title: item.title,
        displayService: item.displayService,
        matchType: item.matchType,
        fillEligible: item.fillEligible === true,
      });
    }

    const result = {
      ok: true,
      type: "matchesResult",
      origin,
      focusNonce,
      revision: auth.config.revision,
      sessionBinding: {
        databaseId: binding.databaseId,
        cacheGeneration: binding.cacheGeneration,
        bridgeGeneration: binding.bridgeGeneration,
      },
      items: safeItems,
      generateAvailable,
    };

    // B010 — a one-shot, sender-bound generate token, minted only while the
    // capability is advertised and under the same session tuple as the query.
    if (generateAvailable) {
      const generateIssued = this.grants.issue({
        purpose: "generate",
        tabId: auth.sender.tabId,
        frameId: auth.sender.frameId,
        documentId: auth.sender.documentId,
        origin,
        focusNonce,
        sessionBinding: result.sessionBinding,
        configRevision: auth.config.revision,
        nowMs: this._now(),
      });
      if (generateIssued !== null) result.generateToken = generateIssued.token;
    }

    const entryIds = safeItems
      .filter((item) => item.fillEligible === true)
      .map((item) => item.entryId);
    if (entryIds.length > 0) {
      const issued = this.grants.issue({
        tabId: auth.sender.tabId,
        frameId: auth.sender.frameId,
        documentId: auth.sender.documentId,
        origin,
        focusNonce,
        entryIds,
        sessionBinding: result.sessionBinding,
        configRevision: auth.config.revision,
        nowMs: this._now(),
      });
      if (issued !== null) {
        result.fillToken = issued.token;
        result.expiresAtEpochMs = issued.expiresAtEpochMs;
      }
    }

    // A007/SR-5 — the outbound message is validated by the shipped validator
    // before it leaves the worker. A password, a username, or any unknown key
    // is a hard failure here, not a redaction.
    if (!securityModule.validateMatchesResult(result).ok) {
      // The validator stays the SOLE gate — classifying the cause here rather
      // than checking the bound earlier keeps it that way, so a mutation that
      // deletes this call still lets an over-limit message escape and still
      // dies. Only the reported code depends on the cause: a host that returned
      // more items than the contract allows broke the contract, which is the
      // same class as the policy and target echoes above, while
      // `internal_error` means THIS worker built something invalid.
      const hostBrokeContract = safeItems.length > securityModule.LIMITS.ITEMS;
      return overlayError(
        "matchesResult",
        hostBrokeContract ? "unsupported_capability" : "internal_error",
        focusNonce
      );
    }
    return result;
  }

  /**
   * B010/B011 — explicit generate.
   *
   * Same one-shot ordering as `_fill`: the grant is consumed BEFORE the native
   * request, so a replay loses by construction, and a failure after
   * consumption never puts the token back — the worker never retries and the
   * app-owned pending record is never re-requested from here.
   *
   * The native payload carries the session tuple and the origin, NOTHING
   * else: no settings of any kind exist in the request schema or here, so the
   * app's committed generator settings are the only possible source (B006).
   * The response's `pendingGenerationId`, `settingsRevision` and expiry are
   * deliberately never read into the result and never stored: the app owns
   * the pending record; the extension keeps neither password nor pending id.
   */
  async _generate(message, auth) {
    const focusNonce = message.focusNonce;
    const origin = auth.sender.origin;

    const consumed = this.grants.consume({
      purpose: "generate",
      token: message.generateToken,
      tabId: auth.sender.tabId,
      frameId: auth.sender.frameId,
      documentId: auth.sender.documentId,
      origin,
      focusNonce,
      sessionBinding: message.sessionBinding,
      configRevision: auth.config.revision,
      nowMs: this._now(),
    });
    if (!consumed.ok) {
      return overlayError(
        "generateResult",
        validationErrorCode(consumed.error),
        focusNonce
      );
    }
    const grant = consumed.grant;

    const response = await this._native("generatePendingEntry", {
      origin,
      expectedDatabaseId: grant.sessionBinding.databaseId,
      expectedCacheGeneration: grant.sessionBinding.cacheGeneration,
      expectedBridgeGeneration: grant.sessionBinding.bridgeGeneration,
    });
    if (response?.ok !== true) {
      return overlayError("generateResult", nativeErrorCode(response), focusNonce);
    }

    const data = response.data;
    if (!securityModule.isPlainObject(data) || data.origin !== origin) {
      return overlayError("generateResult", "stale_session", focusNonce);
    }

    // SR-4 — validate the echoed binding BEFORE the secret is forwarded.
    const bindingError = securityModule.validateResponseBinding({
      echoed: data.sessionBinding,
      expected: grant.sessionBinding,
    });
    if (bindingError !== null) {
      return overlayError("generateResult", bindingError, focusNonce);
    }

    if (typeof data.password !== "string" || data.password.length === 0) {
      return overlayError("generateResult", "internal_error", focusNonce);
    }

    // Built field by field from locals; the native response object itself is
    // never forwarded. Only the password crosses — no pending id, no expiry,
    // no settings revision.
    return {
      ok: true,
      type: "generateResult",
      origin,
      focusNonce,
      sessionBinding: { ...grant.sessionBinding },
      data: { password: data.password },
    };
  }

  /**
   * A025 — explicit fill.
   *
   * Order is the security property: the grant is consumed BEFORE the native
   * request is issued, so a replay of the same token loses the race by
   * construction rather than by timing. A failure after consumption does not
   * put the token back.
   */
  async _fill(message, auth) {
    const focusNonce = message.focusNonce;
    const origin = auth.sender.origin;

    const consumed = this.grants.consume({
      token: message.fillToken,
      tabId: auth.sender.tabId,
      frameId: auth.sender.frameId,
      documentId: auth.sender.documentId,
      origin,
      focusNonce,
      entryId: message.entryId,
      sessionBinding: message.sessionBinding,
      configRevision: auth.config.revision,
      nowMs: this._now(),
    });
    if (!consumed.ok) {
      return overlayError("fillResult", validationErrorCode(consumed.error), focusNonce);
    }
    const grant = consumed.grant;

    // The expected binding comes from the GRANT, not from the message. The two
    // were proven equal by `consume`, and using the grant means a future change
    // to the message schema cannot turn the caller into the authority.
    const response = await this._native("overlayRevealForFill", {
      matchPolicy: MATCH_POLICY,
      entryId: message.entryId,
      origin,
      expectedDatabaseId: grant.sessionBinding.databaseId,
      expectedCacheGeneration: grant.sessionBinding.cacheGeneration,
      expectedBridgeGeneration: grant.sessionBinding.bridgeGeneration,
    });
    if (response?.ok !== true) {
      return overlayError("fillResult", nativeErrorCode(response), focusNonce);
    }

    const data = response.data;
    if (
      !securityModule.isPlainObject(data) ||
      data.matchPolicy !== MATCH_POLICY ||
      data.origin !== origin ||
      data.entryId !== message.entryId
    ) {
      return overlayError("fillResult", "stale_session", focusNonce);
    }

    // SR-4 — validate the echoed binding BEFORE the secret is forwarded.
    const bindingError = securityModule.validateResponseBinding({
      echoed: data.sessionBinding,
      expected: grant.sessionBinding,
    });
    if (bindingError !== null) {
      return overlayError("fillResult", bindingError, focusNonce);
    }

    if (typeof data.username !== "string" || typeof data.password !== "string") {
      return overlayError("fillResult", "internal_error", focusNonce);
    }

    // The only message in this feature that carries a secret. Built field by
    // field from locals; the native response object itself is never forwarded.
    return {
      ok: true,
      type: "fillResult",
      origin,
      focusNonce,
      entryId: message.entryId,
      sessionBinding: { ...grant.sessionBinding },
      data: { username: data.username, password: data.password },
    };
  }
}

const API = {
  OverlayRouter,
  MATCH_POLICY,
  PUBLIC_ERROR_CODES,
  PUBLIC_ERROR_MESSAGES,
  VALIDATION_ERROR_CODES,
  NATIVE_ERROR_CODES,
  CONTENT_ROUTES,
  EXTENSION_PAGE_ROUTES,
  LEGACY_ROUTES,
  validationErrorCode,
  nativeErrorCode,
  overlayError,
};

if (typeof module !== "undefined" && typeof module.exports === "object") {
  module.exports = API;
} else {
  globalThis.CustodeOverlayRoutes = API;
}

})();
