// 009 Slice A2 — durable opt-in, dynamic registration, crash-consistent revoke.
//
// This file is PRODUCTION code. `background.js` loads it with
// `importScripts("overlay_security.js", "overlay_lifecycle.js")` and the Node
// harness under `test/` loads the very same file through `require()` against a
// fake browser. There is one implementation of every rule below.
//
// Every validation rule this file needs already exists in `overlay_security.js`
// (SR-2 canonical origin, the broad permission set, `overlayConfigV2` shape,
// focus-grant store). Nothing is re-implemented here: this file owns
// only the *lifecycle* — when the durable value is written, in which order the
// revocation side effects run, and how a cold worker reconciles browser state
// back to the committed config.
//
// No `chrome.*` global is referenced. The browser API arrives as one injected
// object so the crash-injection harness can drive it deterministically.

"use strict";

// MV3 `importScripts` shares one global scope across worker files: every
// top-level binding lives inside this IIFE so it cannot collide with
// `overlay_security.js` / `overlay_routes.js` (`require()` in the Node harness
// would never show the collision). See `test/worker_global_scope.test.js`.
(() => {

const securityModule =
  typeof require === "function" &&
  typeof module !== "undefined" &&
  typeof module.exports === "object"
    ? require("./overlay_security.js")
    : globalThis.CustodeOverlaySecurity;

// ---------------------------------------------------------------------------
// Registration identity.
//
// data-model.md: "Registration ids are derived from a stable hash/encoding of
// permission pattern; do not persist duplicate registration truth in storage."
// Hex encoding is used rather than a hash because it is injective: two distinct
// patterns can never collide onto one registration id, and a collision here
// would silently unregister a still-authorized site.
// ---------------------------------------------------------------------------

const REGISTRATION_PREFIX = "kv-overlay-";

function registrationIdForPattern(pattern) {
  let hex = "";
  for (let index = 0; index < pattern.length; index += 1) {
    hex += pattern.charCodeAt(index).toString(16).padStart(4, "0");
  }
  return REGISTRATION_PREFIX + hex;
}

function isOverlayRegistrationId(id) {
  return typeof id === "string" && id.startsWith(REGISTRATION_PREFIX);
}

/**
 * The browser permission patterns the committed config justifies.
 *
 * Derived, never persisted (data-model.md). Slice C reduces this to a single
 * all-or-nothing answer: the global switch justifies BOTH broad patterns, and
 * an off switch justifies none. A pattern the browser holds that is not in
 * this set is an orphan — which is exactly how every residual Slice A2
 * per-origin grant gets revoked on the first reconcile after the upgrade.
 */
function desiredPatterns(config) {
  return config.enabled === true
    ? new Set(securityModule.GLOBAL_PERMISSION_PATTERNS)
    : new Set();
}

// Registration and injection both target the isolated world at document_idle,
// in every frame the browser is willing to inject. `overlay_security.js` is
// listed first so the content script can reuse the shipped canonicalization
// instead of carrying a second copy of the SR-2 rule.
const CONTENT_SCRIPT_FILES = Object.freeze([
  "overlay_security.js",
  "content_overlay.js",
]);

/**
 * SLICE C — the ONE registration.
 *
 * Its id is derived from the joined broad patterns through the same injective
 * hex encoding Slice A2 used per origin. That is not cosmetic: because the
 * encoding is injective, this id can never equal any per-origin id a Slice A2
 * install left registered, so those registrations are classified as orphans
 * and unregistered on the first reconcile instead of lingering alongside it.
 */
const GLOBAL_REGISTRATION_PATTERN_KEY =
  securityModule.GLOBAL_PERMISSION_PATTERNS.join(",");

const GLOBAL_REGISTRATION_ID = registrationIdForPattern(
  GLOBAL_REGISTRATION_PATTERN_KEY
);

/**
 * spec 023 T503 — the passkey wrapper's own pair of registrations.
 *
 * Separate from the overlay's registration for two reasons that are not
 * stylistic. First, `navigator.credentials.get` must be wrapped BEFORE the
 * page can call it, so these run at `document_start` while the overlay runs
 * at `document_idle`. Second, the wrapper has to live in the page's own
 * world to be visible to the site at all, and a registration names one world.
 */
const PASSKEY_PAGE_REGISTRATION_ID = registrationIdForPattern(
  `${GLOBAL_REGISTRATION_PATTERN_KEY}#passkey-main`
);
const PASSKEY_BRIDGE_REGISTRATION_ID = registrationIdForPattern(
  `${GLOBAL_REGISTRATION_PATTERN_KEY}#passkey-isolated`
);

function globalRegistration() {
  return {
    id: GLOBAL_REGISTRATION_ID,
    matches: [...securityModule.GLOBAL_PERMISSION_PATTERNS],
    js: [...CONTENT_SCRIPT_FILES],
    runAt: "document_idle",
    allFrames: true,
    world: "ISOLATED",
    persistAcrossSessions: true,
  };
}

function passkeyRegistrations() {
  const matches = [...securityModule.GLOBAL_PERMISSION_PATTERNS];
  return [
    {
      id: PASSKEY_PAGE_REGISTRATION_ID,
      matches,
      js: ["passkey_page.js"],
      runAt: "document_start",
      allFrames: true,
      world: "MAIN",
      persistAcrossSessions: true,
    },
    {
      id: PASSKEY_BRIDGE_REGISTRATION_ID,
      matches,
      js: ["passkey_bridge.js"],
      runAt: "document_start",
      allFrames: true,
      world: "ISOLATED",
      persistAcrossSessions: true,
    },
  ];
}

// ---------------------------------------------------------------------------
// A017 — popup control state.
//
// Pure so the popup renders a state it did not compute itself. `denied` is not
// derivable from durable state: it is the transient answer to one declined
// `permissions.request`, so the popup passes it in.
//
// SLICE C — the switch is GLOBAL, so the state is derived from the config, not
// from the tab. `tabUrl` survives for exactly one purpose: when the switch is
// OFF and the current page is not an http(s) page, "unsupported" is the honest
// answer (turning the overlay on would visibly do nothing here).
//
// ORDER MATTERS AND IS A SAFETY PROPERTY: `enabled` is reported BEFORE the
// `unsupported` check, so a user sitting on a `chrome://` page is still shown
// the switch in its on state with a working "Turn off". A UI that hid the off
// switch on non-http(s) pages would be a permission the user cannot withdraw
// from where they are standing.
//
// WHY `reconciling` IS KEPT, and its exact reachability today.
//
// REACHABILITY: this branch is currently reachable ONLY from tests. The single
// production caller, `siteState`, awaits `ready()` and then calls this without
// passing `ready`, so the default `true` always wins. `test/
// overlay_lifecycle.test.js` is the only site that passes `ready: false`.
// Stated here so nobody deletes it believing it dead, and nobody reads it as
// evidence that the popup renders this state today. It does not.
//
// WHY IT STAYS ANYWAY: it is the correct answer for a window that genuinely
// exists, and the alternative is not "no state" but a WRONG state. Without it
// a popup opened while reconciliation is in flight would fall through to
// `disabled` and render "Off / Turn on". A user clicking that would fire
// `permissions.request` while a reconcile is still running — reopening exactly
// the grant/sweep race A2-M15 pins, this time from the UI side, where the
// worker's `prunePermissions: false` deferral cannot help because the reconcile
// is already in flight and never saw the grant.
//
// So the branch is retained deliberately: the moment `siteState` (or any future
// caller) reports readiness honestly instead of awaiting it, this is the state
// that must be rendered, and the popup already handles it as a no-action row.
// ---------------------------------------------------------------------------

function computeGlobalControlState({
  tabUrl = null,
  config,
  ready = true,
  lastRequestDenied = false,
}) {
  const pageOrigin = securityModule.canonicalOriginOrNull(tabUrl);
  if (!ready) return { state: "reconciling", pageOrigin };
  if (config.enabled === true) return { state: "enabled", pageOrigin };
  if (lastRequestDenied) return { state: "denied", pageOrigin };
  // `unsupported` is a claim about a page we were actually told about. A caller
  // that supplied no tab at all (the `setSiteState` echo, for instance) gets
  // the plain global answer instead of a guess about a page it never named.
  const tabWasSupplied = tabUrl !== null && tabUrl !== undefined;
  if (tabWasSupplied && pageOrigin === null) {
    return { state: "unsupported", pageOrigin: null };
  }
  return { state: "disabled", pageOrigin };
}

// ---------------------------------------------------------------------------

const DISABLE_PHASES = Object.freeze(["D1", "D2", "D3", "D4", "D5"]);

/**
 * Canonical JSON with object keys sorted recursively. Array order is
 * preserved: a reordered array IS a different value and must still mismatch.
 *
 * Exists because real Chrome (measured on 151) returns
 * `chrome.storage.local.get` objects with keys in ALPHABETICAL order, not
 * insertion order: `set {version, revision, enabled}` reads back as
 * `{enabled, revision, version}`. A readback compared through plain
 * `JSON.stringify` therefore mismatches on EVERY commit in production while
 * comparing equal in any harness that preserves insertion order. The readback
 * guard's intent is value identity, not byte identity of one serialization.
 */
function canonicalJson(value) {
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJson).join(",") + "]";
  }
  if (value !== null && typeof value === "object") {
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((key) => JSON.stringify(key) + ":" + canonicalJson(value[key]))
        .join(",") +
      "}"
    );
  }
  // `undefined` serializes as undefined, which can never equal an object's
  // canonical string — a missing readback still mismatches.
  return JSON.stringify(value);
}

class OverlayLifecycle {
  /**
   * @param {object} options
   * @param {object} options.browser   `chrome`-shaped API (promise flavour).
   * @param {object} [options.grants]  Focus-grant store; anything with clear().
   * @param {Function} [options.onFault] Crash injection hook (A021). Called
   *        with each completed disable phase; throwing simulates the worker
   *        dying at that exact point.
   */
  constructor({ browser, grants, onFault } = {}) {
    this._browser = browser;
    this._grants = grants ?? new securityModule.FocusGrantStore();
    this._onFault = onFault ?? null;
    // Serializes every config mutation inside one worker instance, so two
    // concurrent enable/disable calls cannot interleave read-modify-write.
    this._queue = Promise.resolve();
    this._reconciled = null;
  }

  get grants() {
    return this._grants;
  }

  // -------------------------------------------------------------------------
  // Durable config.
  // -------------------------------------------------------------------------

  /**
   * A023 — the durable monotonic revision floor.
   *
   * The floor key is INTENTIONALLY not versioned alongside the config: Slice C
   * renamed `overlayConfigV1` to `overlayConfigV2`, and if the floor had been
   * renamed with it the v2 config would have restarted at revision 1 while
   * focus grants minted at a higher v1 revision were still in flight.
   *
   * CLOSES the "KNOWN GAP" Slice A2 left here. In A2 a total corruption of
   * the config (an unreadable revision, `null`, a missing key, a
   * negative revision) salvaged 0 and the next commit restarted the counter at
   * revision 1. That was harmless while nothing was authorized. In A3 it is
   * not: a focus grant carries `configRevision`, and `FocusGrantStore.consume`
   * accepts a grant only when that number equals the committed one. A rewound
   * counter that climbs back to an already-used revision would make a stale
   * grant compare as current.
   *
   * Two independent mechanisms, because each covers the other's blind spot:
   *
   *   PREVENTION — this floor. Written in the SAME `storage.local.set` as the
   *   config (one operation, so D1 stays a single atomic commit) but under its
   *   own key, so corruption of `overlayConfigV2` does not destroy it. Every
   *   commit raises it, every read raises the recovered revision to it, and a
   *   config whose revision is BELOW it is treated as corrupt — that is what a
   *   rollback to an older-but-well-formed value looks like.
   *
   *   CONTAINMENT — `_readConfig` clears every in-memory grant the moment it
   *   observes an invalid config, and the authorization paths refuse to serve
   *   until reconciliation has rebuilt a valid value. This holds even if the
   *   floor key itself is unreadable, which prevention alone cannot cover.
   */
  async _readConfig() {
    const key = securityModule.OVERLAY_CONFIG_KEY;
    const floorKey = securityModule.OVERLAY_REVISION_FLOOR_KEY;
    let stored;
    try {
      stored = await this._browser.storage.local.get([key, floorKey]);
    } catch (_) {
      // A failed read is not evidence that anything is authorized.
      this._grants.clear();
      return { ...securityModule.emptyOverlayConfig(0), __invalid: true };
    }
    const raw = stored?.[key];
    const floor = securityModule.revisionFloorOrZero(stored?.[floorKey]);
    const valid = securityModule.validateOverlayConfig(raw).ok;

    // A well-formed value whose revision sits below the floor is a rollback,
    // not a valid config: it would re-authorize origins from a revision that
    // has already been superseded.
    if (!valid || raw.revision < floor) {
      const plausible =
        Number.isInteger(raw?.revision) && raw.revision >= 0 ? raw.revision : 0;
      // Containment: no grant minted against the pre-corruption revision may
      // outlive the moment corruption is observed.
      this._grants.clear();
      return {
        ...securityModule.emptyOverlayConfig(Math.max(floor, plausible)),
        __invalid: true,
      };
    }
    return { version: 2, revision: raw.revision, enabled: raw.enabled };
  }

  /**
   * Committed authorization state. Anything invalid or missing — including a
   * surviving Slice A2 `overlayConfigV1` value, which this build cannot parse
   * — reads as DISABLED. This method never writes, so a read path can never
   * grant.
   */
  async readCommittedConfig() {
    return this._readConfig();
  }

  /**
   * D1. One `storage.local.set` carrying the config and the raised floor, then
   * a readback that must match exactly. A rejected write or a mismatched
   * readback throws, and the caller is contractually forbidden from running any
   * later phase.
   *
   * Both keys travel in ONE `set` on purpose: SR-8 requires the durable
   * authorization commit to be a single operation, and a floor written in a
   * second call could be lost while the config it protects survives.
   */
  async _commitConfig(next) {
    const key = securityModule.OVERLAY_CONFIG_KEY;
    const floorKey = securityModule.OVERLAY_REVISION_FLOOR_KEY;
    const shape = securityModule.validateOverlayConfig(next);
    if (!shape.ok) {
      throw new Error(`overlay_config_invalid:${shape.error}`);
    }
    // The floor is a HIGH-WATER MARK: a commit may raise it, nothing may lower
    // it. `next.revision` alone is not that value. The revision being committed
    // is derived from whatever `_readConfig` managed to see, and `_readConfig`
    // reports revision 0 when the read itself FAILED — a transient
    // `storage.local.get` error is not evidence that the floor is low, only
    // that it is unknown. Writing `next.revision` unconditionally would take a
    // floor of 9 down to 1 on the next commit, silently disarming the
    // prevention half of A023 and leaving containment as the only surviving
    // defence of two that are documented as independent.
    //
    // Read separately from `_readConfig` on purpose: that call may have failed,
    // and its salvaged revision is not a floor. If THIS read throws the commit
    // aborts, which is the correct answer when the floor cannot be established.
    const priorFloor = securityModule.revisionFloorOrZero(
      (await this._browser.storage.local.get([floorKey]))?.[floorKey]
    );
    const floor = Math.max(priorFloor, next.revision);

    // Still ONE `set` carrying both keys: SR-8/D1 requires the durable
    // authorization commit to be a single operation. The read above is a read.
    await this._browser.storage.local.set({ [key]: next, [floorKey]: floor });
    const stored = await this._browser.storage.local.get([key, floorKey]);
    const readback = stored?.[key];
    // Key-order-insensitive on purpose: Chrome's `get` returns keys sorted
    // alphabetically (see `canonicalJson`). Any truncated, altered, extra or
    // reordered-array value still throws.
    if (canonicalJson(readback) !== canonicalJson(next)) {
      throw new Error("overlay_config_readback_mismatch");
    }
    if (securityModule.revisionFloorOrZero(stored?.[floorKey]) < floor) {
      throw new Error("overlay_revision_floor_readback_mismatch");
    }
    return next;
  }

  _nextConfig(config, enabled) {
    return { version: 2, revision: config.revision + 1, enabled: enabled === true };
  }

  async _fault(phase) {
    if (this._onFault !== null) await this._onFault(phase);
  }

  _withLock(work) {
    const run = this._queue.then(work, work);
    // Keep the chain alive after a rejection so one failed transaction does not
    // wedge every later one.
    this._queue = run.then(
      () => undefined,
      () => undefined
    );
    return run;
  }

  // -------------------------------------------------------------------------
  // Browser state derivation.
  // -------------------------------------------------------------------------

  async _grantedPatterns() {
    try {
      const granted = await this._browser.permissions.getAll();
      return Array.isArray(granted?.origins) ? granted.origins : [];
    } catch (_) {
      return [];
    }
  }

  /**
   * Does the browser still hold the BROAD grant?
   *
   * One `permissions.contains` over the whole set, so a partial grant answers
   * false. A throw answers false too: the reconciler must never read "I could
   * not ask" as "yes".
   */
  async _hasGlobalGrant() {
    try {
      return (
        (await this._browser.permissions.contains({
          origins: [...securityModule.GLOBAL_PERMISSION_PATTERNS],
        })) === true
      );
    } catch (_) {
      return false;
    }
  }

  async _registeredOverlayScripts() {
    try {
      const registered = await this._browser.scripting.getRegisteredContentScripts();
      return (Array.isArray(registered) ? registered : []).filter((script) =>
        isOverlayRegistrationId(script?.id)
      );
    } catch (_) {
      return [];
    }
  }

  /**
   * D4. Registrations converge on exactly what the config justifies: the one
   * global registration when the switch is on, nothing at all when it is off.
   *
   * Every other `kv-overlay-` registration is an orphan and is removed — which
   * is how the per-origin registrations a Slice A2 install persisted across
   * sessions are cleaned up, without a single line of migration-specific code.
   */
  async _reconcileRegistrations(config) {
    const wanted = config.enabled === true;
    const registered = await this._registeredOverlayScripts();
    // spec 023 T503: the passkey pair rides the same switch as the overlay.
    // One control, one answer to "is Custode acting on my pages" — a wrapper
    // that survived the switch being turned off would be exactly the
    // permission the user thought they had withdrawn.
    const desired = wanted
      ? [globalRegistration(), ...passkeyRegistrations()]
      : [];
    const desiredIds = new Set(desired.map((script) => script.id));

    const orphans = registered
      .map((script) => script.id)
      .filter((id) => !desiredIds.has(id));
    if (orphans.length > 0) {
      await this._browser.scripting.unregisterContentScripts({ ids: orphans });
    }

    const registeredIds = new Set(registered.map((script) => script.id));
    const missing = desired.filter((script) => !registeredIds.has(script.id));
    if (missing.length > 0) {
      await this._browser.scripting.registerContentScripts(missing);
    }
  }

  /**
   * D5. Optional host permissions converge on the patterns the config
   * justifies. When the switch is off that set is EMPTY, so every granted
   * origin pattern is removed — the broad pair this build asks for and any
   * per-origin pattern a Slice A2 install left behind alike. The check reads
   * committed config, never the caller's intent.
   */
  async _reconcilePermissions(config) {
    const desired = desiredPatterns(config);
    const granted = await this._grantedPatterns();
    const orphans = granted.filter((pattern) => !desired.has(pattern));
    if (orphans.length > 0) {
      try {
        await this._browser.permissions.remove({ origins: orphans });
      } catch (_) {
        // Retried by the next reconciliation. Authorization is already revoked.
      }
    }
  }

  /**
   * D3. Teardown is advisory: authorization is already gone after D1.
   *
   * The message names NO origin. Without the `tabs` permission the worker
   * cannot read `tab.url`, so this is necessarily a broadcast to every
   * injected document; putting the disabled origin in it would tell a document
   * on still-enabled origin A which origin B the user just turned off. The
   * revision is a global counter that leaks nothing about which site changed.
   * Each receiver revalidates its own exact origin against `authorizeBootstrap`
   * and tears itself down only if that answer is no.
   */
  async _broadcastTeardown(revision) {
    let tabs = [];
    try {
      tabs = await this._browser.tabs.query({});
    } catch (_) {
      return;
    }
    const message = {
      channel: securityModule.CHANNEL,
      version: securityModule.MESSAGE_VERSION,
      type: "teardown",
      revision,
    };
    for (const tab of tabs) {
      if (typeof tab?.id !== "number") continue;
      try {
        await this._browser.tabs.sendMessage(tab.id, message);
      } catch (_) {
        // No injected receiver in that tab, or the tab is gone. Both fine.
      }
    }
  }

  // -------------------------------------------------------------------------
  // A020 — fail-closed reconciliation.
  // -------------------------------------------------------------------------

  /**
   * Runs at most once per worker instance and gates every message. Callers
   * await this before answering anything, so a cold worker can never serve a
   * request against unreconciled browser state.
   */
  async ready() {
    if (this._reconciled === null) {
      this._reconciled = this.reconcile().catch((error) => {
        // Failing closed means retrying, not caching a broken "ready".
        this._reconciled = null;
        throw error;
      });
    }
    return this._reconciled;
  }

  /**
   * @param {object} [options]
   * @param {boolean} [options.prunePermissions=true]
   *
   * `prunePermissions: false` exists for exactly one caller: the
   * `permissions.onAdded` listener in `background.js`. Chrome fires that event
   * the instant the user accepts the popup's `permissions.request`, BEFORE the
   * popup's `setSiteState` message reaches this worker — so at that moment the
   * freshly granted pattern is not yet justified by committed config and a
   * full reconcile would classify it as an orphan and revoke it, making the
   * enable fail (`enable` re-checks `permissions.contains`).
   *
   * Deferring the orphan sweep on that one trigger is safe because the
   * DURABLE CONFIG, never the browser permission alone, is the authorization
   * source of truth: bootstrap and every content route verify config +
   * revision, so a granted-but-unconfigured permission is inert. Removing
   * orphan permissions is hygiene, not revocation of authorization, and the
   * sweep still runs on every other trigger — cold start / `ready()`, popup
   * open (`siteState`), `permissions.onRemoved`, and the disable flow (D5).
   *
   * TOCTOU variant (full reconcile computes orphans, `enable` commits,
   * reconcile then removes): impossible by construction inside one worker.
   * Both `reconcile()` and `enable()` run their ENTIRE body — config
   * read, orphan computation, `permissions.remove` — inside `_withLock`, one
   * FIFO promise queue per lifecycle instance, and `background.js` constructs
   * exactly one instance per worker. So a full reconcile either finishes
   * before the enable's commit (and never saw the new pattern as granted-and-
   * unjustified past the commit) or starts after it (and sees the config that
   * justifies the pattern).
   */
  async reconcile({ prunePermissions = true } = {}) {
    return this._withLock(async () => {
      let config = await this.readCommittedConfig();

      // Invalid, missing, or Slice A2 durable state becomes DISABLED, written
      // back as one valid revisioned config, before any registration exists.
      // This is also the whole of the v1→v2 migration: a v1 value cannot parse
      // as v2, so it lands here and can only ever produce `enabled: false`.
      if (config.__invalid === true) {
        config = await this._commitConfig(
          securityModule.emptyOverlayConfig(config.revision + 1)
        );
      }

      // In-memory grants never survive a cold start, and are dropped again here
      // so a reconciliation triggered by a permission change also clears them.
      this._grants.clear();

      // A permission revoked outside the popup (chrome://extensions) durably
      // disables the overlay in one revisioned write. Under the global model
      // this is all-or-nothing: losing either half of the broad pair is a
      // revocation, because a half-injected overlay is not a state the user
      // consented to.
      if (config.enabled === true && !(await this._hasGlobalGrant())) {
        config = await this._commitConfig(this._nextConfig(config, false));
        await this._broadcastTeardown(config.revision);
      }

      await this._reconcileRegistrations(config);
      if (prunePermissions) await this._reconcilePermissions(config);
      // Hygiene, deliberately AFTER the commit and outside it: the Slice A2 key
      // is never read by this build, so deleting it authorizes nothing and a
      // failure here is harmless. Doing it inside the commit would put a
      // non-authorization write inside the single atomic D1 operation.
      await this._dropLegacyConfig();
      return config;
    });
  }

  /** Deletes the Slice A2 storage key. Best effort; never authorizes anything. */
  async _dropLegacyConfig() {
    try {
      await this._browser.storage.local.remove(
        securityModule.OVERLAY_LEGACY_CONFIG_KEY
      );
    } catch (_) {
      // Retried by the next reconciliation. The value is inert either way.
    }
  }

  // -------------------------------------------------------------------------
  // A017/A018 — enable.
  // -------------------------------------------------------------------------

  /**
   * Persists the global opt-in. The permission grant is the popup's job (it
   * needs the user gesture); this method refuses to persist unless the browser
   * confirms the BROAD grant is actually held, so a declined, partial or
   * revoked grant can never leave the overlay durably enabled.
   */
  async enable({ tabId } = {}) {
    return this._withLock(async () => {
      if (!(await this._hasGlobalGrant())) {
        return { ok: false, error: "permission_missing" };
      }

      let config = await this.readCommittedConfig();
      if (config.__invalid === true) {
        // Same salvage as `disable`: the recovered value is in-memory only and
        // is never committed on its own, so the single write below advances the
        // revision by exactly one either way.
        config = securityModule.emptyOverlayConfig(config.revision);
      }
      if (config.enabled !== true) {
        config = await this._commitConfig(this._nextConfig(config, true));
      }

      await this._reconcileRegistrations(config);
      // Registration only affects documents loaded from now on, so the tab the
      // user is looking at is injected explicitly. Failure is not fatal: a
      // reload picks the registration up.
      if (typeof tabId === "number") {
        try {
          await this._browser.scripting.executeScript({
            target: { tabId, allFrames: true },
            files: [...CONTENT_SCRIPT_FILES],
          });
        } catch (_) {
          // Restricted page or no injectable frame. Fails closed by doing
          // nothing; SR-7 forbids claiming injection happened.
        }
      }
      return { ok: true, revision: config.revision };
    });
  }

  /**
   * macOS grant race — consume the popup's pending enable intent.
   *
   * Called by the `permissions.onAdded` listener AFTER its
   * `reconcile({ prunePermissions: false })`. On macOS the permission prompt
   * closes the popup, so the popup's own `setSiteState enable` never arrives;
   * this path finishes the enable from the intent the popup wrote to
   * `storage.session` under the user gesture, before the request.
   *
   * Security invariants, in order:
   *   - ONE-SHOT: the intent is deleted before any use, like the focus-grant
   *     tokens. A delete that fails aborts — acting on an unburned intent is
   *     a replay.
   *   - FAIL-CLOSED SHAPE: garbage is deleted and ignored
   *     (`validateEnableIntent`, exact keys, canonical origin).
   *   - TTL: an intent older than `ENABLE_INTENT_TTL_MS` (or from the future)
   *     is only deleted, never acted on.
   *   - GRANT SUFFICIENCY: the event must carry the WHOLE broad pair. Slice A2
   *     compared the granted pattern against the origin named in the intent;
   *     under one global switch there is no origin to compare, so the check
   *     that survives is that the grant the user just accepted actually covers
   *     what this switch means. A narrower grant — including a per-origin
   *     pattern granted for some unrelated reason — enables nothing.
   *   - The enable goes through the same `enable` (permission re-check, single
   *     commit, registration) as the popup path. No new path. It is
   *     idempotent, so popup-survives platforms where both complete still
   *     produce one coherent outcome.
   *
   * No intent stored → `no_intent`, behaviour identical to before this fix.
   */
  async consumeEnableIntent({ grantedOrigins = [], now = Date.now() } = {}) {
    const key = securityModule.OVERLAY_ENABLE_INTENT_KEY;
    let raw;
    try {
      const stored = await this._browser.storage.session.get([key]);
      raw = stored?.[key];
    } catch (_) {
      return { ok: false, error: "intent_unreadable" };
    }
    if (raw === undefined) return { ok: false, error: "no_intent" };
    try {
      await this._browser.storage.session.remove(key);
    } catch (_) {
      // Cannot prove one-shot-ness — refuse rather than risk replay.
      return { ok: false, error: "intent_not_burned" };
    }
    if (!securityModule.validateEnableIntent(raw).ok) {
      return { ok: false, error: "invalid_intent" };
    }
    const age = now - raw.createdAt;
    if (!(age >= 0 && age <= securityModule.ENABLE_INTENT_TTL_MS)) {
      return { ok: false, error: "expired_intent" };
    }
    if (!securityModule.coversGlobalPermission(grantedOrigins)) {
      return { ok: false, error: "pattern_mismatch" };
    }
    return this.enable({ tabId: raw.tabId });
  }

  // -------------------------------------------------------------------------
  // A019/SR-8 — crash-consistent disable.
  // -------------------------------------------------------------------------

  /**
   * ORDER IS THE SECURITY PROPERTY, not an implementation detail.
   *
   * D1 is the durable commit. It is the only fallible step whose failure
   * aborts the transaction, and it happens before every side effect, because
   * the durable config — not the permission, not the registration, not the
   * injected script — is the authorization source of truth. After D1 every
   * authorization check sees the origin as disabled even if this worker dies
   * on the very next line. D2–D5 are idempotent cleanup that any later worker
   * finishes through `reconcile()`.
   *
   * Moving `_commitConfig` after any of D2–D5 reintroduces a window where a
   * crash leaves the browser cleaned up but the overlay still durably
   * authorized. `test/overlay_lifecycle.test.js` and
   * `test/overlay_crash_consistency.test.js` both fail if that order changes.
   *
   * SLICE C changes WHAT each phase converges on, never the order or the rule
   * that D1 comes first.
   */
  async disable() {
    return this._withLock(async () => {
      let config = await this.readCommittedConfig();
      if (config.__invalid === true) {
        config = securityModule.emptyOverlayConfig(config.revision);
      }

      // D1 — durable commit. Throws on write or readback failure; nothing below
      // this line runs in that case.
      const committed = await this._commitConfig(this._nextConfig(config, false));
      await this._fault("D1");

      // D2 — worker grants for the old revision are worthless now.
      this._grants.clear();
      await this._fault("D2");

      // D3 — advisory teardown for documents that still hold an injected script.
      await this._broadcastTeardown(committed.revision);
      await this._fault("D3");

      // D4 — drop the registration; nothing justifies it once the switch is off.
      await this._reconcileRegistrations(committed);
      await this._fault("D4");

      // D5 — hand the broad host permission back. Leaving it granted would keep
      // an "can read all sites" entry on the extension's permission list that
      // nothing in this build justifies any more.
      await this._reconcilePermissions(committed);
      await this._fault("D5");

      return { ok: true, revision: committed.revision };
    });
  }

  // -------------------------------------------------------------------------
  // A017/A018 — read paths.
  // -------------------------------------------------------------------------

  /** Popup control state for the global switch. Reconciles first, then reports. */
  async siteState({ tabUrl = null, lastRequestDenied = false } = {}) {
    await this.ready();
    const config = await this.readCommittedConfig();
    return {
      ...computeGlobalControlState({ tabUrl, config, lastRequestDenied }),
      revision: config.revision,
    };
  }

  /**
   * A023 — the single authorization gate for EVERY content-script request
   * (bootstrap, requestMatches, fill). It runs before any native I/O and it is
   * the only place the frame's authoritative origin is established.
   *
   * The authoritative origin comes from `sender.url` inside
   * `validateContentScriptSender`; `message.origin` is compared against it and
   * is never promoted to authority. Tab id, frame id, optional document id and
   * the top-frame agreement rule are all enforced there too. What this method
   * adds is the state only the worker owns: the committed config, the
   * permission the browser still reports, the revision, and the frame support
   * classification.
   *
   * @returns {{ok: true, sender: object, config: object, frameSupport: string}
   *          |{ok: false, error: string}}
   */
  async authorizeContentRequest({ message, sender, runtimeId } = {}) {
    await this.ready();
    const config = await this.readCommittedConfig();
    if (config.__invalid === true) {
      // Refuse to serve until reconciliation has rebuilt a valid durable value.
      // Grants were already dropped by the read itself.
      //
      // `ready()` resolves once per worker, so corruption appearing AFTER it
      // resolved would otherwise wedge this worker into permanent refusal.
      // Dropping the memo makes the NEXT request reconcile and rebuild, while
      // this one still fails closed.
      this._reconciled = null;
      return { ok: false, error: "stale_session" };
    }
    const grantedPatterns = await this._grantedPatterns();
    const result = securityModule.validateContentScriptRequest(
      message,
      sender,
      runtimeId,
      {
        enabled: config.enabled,
        revision: config.revision,
        grantedPatterns,
      }
    );
    if (!result.ok) return { ok: false, error: result.error };

    const frameSupport = securityModule.computeFrameSupport({
      frameId: result.sender.frameId,
      frameOrigin: result.sender.origin,
      topOrigin: result.sender.topOrigin,
      enabled: config.enabled,
    });
    return { ok: true, sender: result.sender, config, frameSupport };
  }

  /**
   * spec 023 T503 — authorize one passkey signing request.
   *
   * The overlay's own gate minus the parts that do not apply: no body
   * `origin` to cross-check (the page world has no trustworthy one to give)
   * and no frame-support classification (a signature is not drawn anywhere,
   * so there is no frame it could be drawn in the wrong place of). What
   * remains is what protects the key: a real content script of this
   * extension, the global switch on, and the broad host permission still
   * held — so a wrapper still running in a page after the user turned
   * Custode off cannot sign.
   */
  async authorizePasskeyRequest({ sender, runtimeId } = {}) {
    await this.ready();
    const config = await this.readCommittedConfig();
    if (config.__invalid === true) {
      this._reconciled = null;
      return { ok: false, error: "stale_session" };
    }
    if (config.enabled !== true) return { ok: false, error: "disabled" };

    const senderResult = securityModule.validateContentScriptSender(
      sender,
      runtimeId
    );
    if (!senderResult.ok) return { ok: false, error: senderResult.error };

    const grantedPatterns = await this._grantedPatterns();
    if (!securityModule.coversGlobalPermission(grantedPatterns)) {
      return { ok: false, error: "permission_missing" };
    }
    return { ok: true, sender: senderResult, config };
  }

  /**
   * A018/A020 — an already-injected content script stays inert until this
   * approves it. Authorization is re-derived from committed config every time;
   * the script's own claim about its origin is only ever a mismatch detector.
   */
  async authorizeBootstrap({ message, sender, runtimeId } = {}) {
    const auth = await this.authorizeContentRequest({ message, sender, runtimeId });
    if (!auth.ok) {
      return { ok: false, error: { code: auth.error } };
    }
    return {
      ok: true,
      type: "bootstrapResult",
      // SR-7: reaching this line means the global switch is on AND the broad
      // grant is held — `authorizeContentRequest` refuses otherwise. An
      // unsupported frame keeps `enabled: true` and is refused by
      // `frameSupport`, so the content script can render the honest
      // "unsupported frame" state instead of a misleading "disabled" one.
      enabled: true,
      origin: auth.sender.origin,
      topOrigin: auth.sender.topOrigin,
      frameId: auth.sender.frameId,
      frameSupport: auth.frameSupport,
      revision: auth.config.revision,
    };
  }
}

const API = {
  OverlayLifecycle,
  CONTENT_SCRIPT_FILES,
  DISABLE_PHASES,
  REGISTRATION_PREFIX,
  GLOBAL_REGISTRATION_ID,
  registrationIdForPattern,
  PASSKEY_PAGE_REGISTRATION_ID,
  PASSKEY_BRIDGE_REGISTRATION_ID,
  isOverlayRegistrationId,
  globalRegistration,
  desiredPatterns,
  computeGlobalControlState,
};

if (typeof module !== "undefined" && typeof module.exports === "object") {
  module.exports = API;
} else {
  globalThis.CustodeOverlayLifecycle = API;
}

})();
