// 009 Slice A2 — behavioural tests for `content_overlay.js`.
//
// This is the one extension file that executes inside a page the user does not
// control. Until now it was covered only by `node --check` and by four
// allowlist assertions that matched its *file name*, which proves it is
// packaged and parses, and nothing whatsoever about what it does.
//
// Everything below drives the shipped file through `test/fake_page.js`, which
// evaluates it in a fresh isolated-world global exactly as Chromium would.
// The three properties under test are the three the file actually owns:
//
//   1. the idempotence guard  — one bootstrap per document, ever;
//   2. the exact-origin gate  — a document Chromium injected but the config
//      never authorized attaches nothing;
//   3. approval ordering      — no listener exists before an explicit `ok`.
//
// Several tests answer `bootstrap` with a real `OverlayLifecycle` rather than a
// canned reply, because the port case is only meaningful end to end: a
// Chromium match pattern cannot express a port, so `https://example.com:8443`
// IS injected whenever `https://example.com` is enabled, and the whole of its
// inertness lives in these two files agreeing.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { FakePage } = require("./fake_page.js");
const { FakeBrowser } = require("./fake_browser.js");
const security = require("../overlay_security.js");
const { OverlayLifecycle } = require("../overlay_lifecycle.js");
const {
  item,
  matchesResult,
  fillResult,
  errorResult,
  loginPage,
  statusText,
  optionRows,
  listboxEl,
  overlayCount,
  lightListboxEl,
} = require("./session_helpers.js");

const RUNTIME_ID = "abcdefghijklmnopabcdefghijklmnop";

const HTTPS_EXAMPLE = "https://example.com";
const HTTPS_EXAMPLE_8443 = "https://example.com:8443";
const HTTP_EXAMPLE = "http://example.com";

// Mirrors the real `bootstrapResult` the worker sends, including the SR-7
// `frameSupport` field A023 added: an approval is not an approval unless the
// frame is one the policy actually supports.
const APPROVED = Object.freeze({
  ok: true,
  type: "bootstrapResult",
  enabled: true,
  frameSupport: "top",
  revision: 3,
});

function teardownMessage(revision = 4) {
  return {
    channel: security.CHANNEL,
    version: security.MESSAGE_VERSION,
    type: "teardown",
    revision,
  };
}

/**
 * A world whose background is the real lifecycle worker, with the global
 * switch already on (or off, via `{ enabled: false }`). `sender` is synthesised
 * from the page URL the way Chromium stamps it, so
 * `validateContentScriptRequest` sees a genuine sender.
 */
async function pageBackedByWorker(url, { enabled = true } = {}) {
  const browser = new FakeBrowser({ tabs: [{ id: 1 }] });
  const worker = new OverlayLifecycle({ browser });
  if (enabled) {
    await browser.permissions.request({
      origins: [...security.GLOBAL_PERMISSION_PATTERNS],
    });
    await worker.enable({ tabId: 1 });
  }

  const page = new FakePage({ url });
  page.respond = (message) =>
    worker.authorizeBootstrap({
      message,
      sender: {
        id: RUNTIME_ID,
        url: page.url,
        frameId: 0,
        tab: { id: 1, url: page.url },
      },
      runtimeId: RUNTIME_ID,
    });
  return { page, worker, browser };
}

// ---------------------------------------------------------------------------
// Idempotence guard.
// ---------------------------------------------------------------------------

// Assembled at runtime, neutral name: GitGuardian flags credential-shaped
// literals and inline joins next to a pwInput key (see overlay_session.test.js).
const FILL_VALUE_G = ["canary", "a039"].join("-");

test("content_overlay: a double injection bootstraps exactly once", async () => {
  const page = new FakePage({ url: "https://example.com/login", respond: async () => APPROVED });

  // The registered content script and the explicit `executeScript` the enable
  // path fires both hit the same document. This is the normal case, not an
  // edge case.
  await page.inject();
  await page.inject();

  assert.equal(page.sentOfType("bootstrap").length, 1);
  assert.equal(page.listenerCount, 1);
  assert.equal(page.guarded, true);
});

test("content_overlay: the guard blocks the second run before it sends anything", async () => {
  const page = new FakePage({ url: "https://example.com/login", respond: async () => APPROVED });

  await page.inject();
  const sentAfterFirst = page.sent.length;
  for (let run = 0; run < 5; run += 1) await page.inject();

  assert.equal(page.sent.length, sentAfterFirst);
  assert.equal(page.listenerCount, 1);
});

test("content_overlay: a released guard lets a later valid enable bootstrap again", async () => {
  const page = new FakePage({ url: "https://example.com/login", respond: async () => APPROVED });
  await page.inject();
  assert.equal(page.listenerCount, 1);

  // Disable: the background now refuses, so the teardown revalidation drops
  // the listener and releases the guard.
  page.respond = async () => ({ ok: false, error: { code: "disabled" } });
  await page.deliver(teardownMessage());
  assert.equal(page.listenerCount, 0);
  assert.equal(page.guarded, false);

  // Re-enable and re-inject: the document must be able to come back.
  page.respond = async () => APPROVED;
  await page.inject();
  assert.equal(page.listenerCount, 1);
  assert.equal(page.guarded, true);
});

// ---------------------------------------------------------------------------
// Exact-origin gate.
// ---------------------------------------------------------------------------

// SLICE C SUBSTITUTION for "an injected non-enabled port attaches no listener"
// and "the enabled port on the same host does attach". Both encoded the Slice
// A2 asymmetry: Chromium injects `https://example.com:8443` whenever
// `https://example.com` is enabled, and only the exact-origin check kept the
// sibling port inert. The global switch enables both, so the asymmetry is gone
// BY DESIGN and asserting it would now be asserting the old product decision.
//
// What must not be lost is the other half: each document still claims and is
// bound to its OWN exact origin, so the sibling port is a separate identity
// even though both now attach. "the bootstrap claims this document's own exact
// origin" below is that property, and it is unchanged.
test("content_overlay: every http(s) document attaches once the switch is on", async () => {
  for (const url of [
    "https://example.com/login",
    "https://example.com:8443/login",
    "http://example.com/login",
    "https://example.com.evil.test/login",
  ]) {
    const { page } = await pageBackedByWorker(url);
    await page.inject();
    assert.equal(page.listenerCount, 1, url);
    assert.equal(page.guarded, true, url);
    // Bound to itself, never to a neighbour.
    assert.deepEqual(
      page.sentOfType("bootstrap").map((m) => m.origin),
      [security.canonicalOriginOrNull(url)],
      url
    );
  }
});

test("content_overlay: with the switch off, no document attaches", async () => {
  // The inverse, and the one that actually protects the user: turning the
  // overlay off must silence every page, not just the one they were on.
  for (const url of [
    "https://example.com/login",
    "https://example.com:8443/login",
    "http://example.com/login",
  ]) {
    const { page } = await pageBackedByWorker(url, { enabled: false });
    await page.inject();
    assert.equal(page.listenerCount, 0, url);
    assert.equal(page.guarded, false, url);
  }
});

test("content_overlay: an enabled origin in an unsupported frame is display-only — no query, no fill, honest state", async () => {
  // SR-7/A035. The origin IS opted in, so `enabled` is true; the frame is one
  // the policy cannot support. Until Slice A5 this instance stayed fully
  // inert, which meant the unsupported state could never render anywhere; the
  // A035 contract is DISPLAY-ONLY activation: on eligible focus it shows the
  // honest unsupported-frame state directing manual copy from the app, and it
  // structurally never sends `requestMatches` or `fill`.
  const { page, password: pwInput } = await loginPage({
    bootstrap: { ...APPROVED, frameSupport: "unsupported" },
  });

  assert.equal(page.sentOfType("bootstrap").length, 1);
  await page.focus(pwInput);

  assert.equal(overlayCount(page), 1, "the unsupported state must render");
  assert.equal(
    statusText(page),
    "The overlay is not available in this frame. Copy your login from the Custode app."
  );
  // Fail closed: not one credential message may leave this frame, ever.
  assert.equal(page.sentOfType("requestMatches").length, 0);
  assert.equal(page.sentOfType("fill").length, 0);

  // Enter cannot fill (there is nothing to fill) and Escape dismisses.
  const enter = await page.pressKey("Enter");
  assert.equal(enter.defaultPrevented, false);
  assert.equal(page.sentOfType("fill").length, 0);
  await page.pressKey("Escape");
  assert.equal(overlayCount(page), 0);
});

test("content_overlay: an approval missing frameSupport is not an approval", async () => {
  // A worker that predates A023 — or a forged response — cannot approve by
  // omission.
  const page = new FakePage({
    url: "https://example.com/login",
    respond: async () => ({ ok: true, type: "bootstrapResult", enabled: true, revision: 3 }),
  });

  await page.inject();

  assert.equal(page.listenerCount, 0);
  assert.equal(page.guarded, false);
});

// SLICE C RETIREMENT. "a sibling scheme and a suffix lookalike both stay
// inert" asserted that `http://example.com` and `https://example.com.evil.test`
// attached nothing while only `https://example.com` was enabled. Under the
// global switch they attach like any other http(s) page. The danger the test
// was really about — a look-alike host being served `example.com`'s
// credentials — is not addressed by inertness at all but by exact-origin
// binding, which "the bootstrap claims this document's own exact origin" and
// the router's exact-origin query both still pin.

test("content_overlay: the bootstrap claims this document's own exact origin", async () => {
  for (const [url, expected] of [
    ["https://example.com/login?a=b#c", HTTPS_EXAMPLE],
    ["https://example.com:8443/login", HTTPS_EXAMPLE_8443],
    ["http://example.com/login", HTTP_EXAMPLE],
    ["https://EXAMPLE.com:443/login", HTTPS_EXAMPLE],
  ]) {
    const page = new FakePage({ url, respond: async () => APPROVED });
    await page.inject();
    assert.equal(page.sent[0].origin, expected, url);
    assert.equal(page.sent[0].channel, security.CHANNEL, url);
    assert.equal(page.sent[0].version, security.MESSAGE_VERSION, url);
    assert.equal(page.sent[0].type, "bootstrap", url);
  }
});

test("content_overlay: a non-canonicalizable document never speaks at all", async () => {
  for (const url of [
    "about:blank",
    "file:///tmp/local.html",
    "data:text/html,<p>x",
    "chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html",
    "https://alice@example.com/login",
  ]) {
    const page = new FakePage({ url, respond: async () => APPROVED });
    await page.inject();

    assert.deepEqual(page.sent, [], url);
    assert.equal(page.listenerCount, 0, url);
    // The guard is released, so the document is not permanently poisoned.
    assert.equal(page.guarded, false, url);
  }
});

test("content_overlay: without the security module the bootstrap does not run", async () => {
  const page = new FakePage({
    url: "https://example.com/login",
    respond: async () => APPROVED,
    loadSecurity: false,
  });

  await page.inject();

  assert.deepEqual(page.sent, []);
  assert.equal(page.listenerCount, 0);
  // Nothing was claimed, so a correctly ordered later injection still works.
  assert.equal(page.guarded, false);
});

// ---------------------------------------------------------------------------
// Approval ordering.
// ---------------------------------------------------------------------------

test("content_overlay: a refused bootstrap attaches nothing and releases the guard", async () => {
  for (const response of [
    { ok: false, error: { code: "disabled" } },
    { ok: false, error: { code: "permission_missing" } },
    { ok: true, enabled: false, revision: 2 },
    { ok: true, revision: 2 },
    undefined,
    null,
    {},
    "yes",
  ]) {
    const page = new FakePage({
      url: "https://example.com/login",
      respond: async () => response,
    });
    await page.inject();

    const label = JSON.stringify(response) ?? "undefined";
    assert.equal(page.listenerCount, 0, label);
    assert.equal(page.guarded, false, label);
  }
});

test("content_overlay: a dead worker attaches nothing", async () => {
  const page = new FakePage({
    url: "https://example.com/login",
    respond: async () => {
      throw new Error("Could not establish connection.");
    },
  });

  await page.inject();

  assert.equal(page.listenerCount, 0);
  assert.equal(page.guarded, false);
});

test("content_overlay: no listener exists before the approval arrives", async () => {
  let release;
  const approved = new Promise((resolve) => {
    release = resolve;
  });
  const page = new FakePage({
    url: "https://example.com/login",
    respond: async () => {
      // Observed from inside the round trip: the guard is already taken, but
      // the document is not listening to anything yet.
      assert.equal(page.listenerCount, 0, "listener attached before approval");
      await approved;
      return APPROVED;
    },
  });

  page.evaluate("content_overlay.js");
  assert.equal(page.listenerCount, 0);
  release();
  await page.settle();

  assert.equal(page.listenerCount, 1);
});

// ---------------------------------------------------------------------------
// Teardown.
// ---------------------------------------------------------------------------

test("content_overlay: teardown for a still-authorized document keeps the listener", async () => {
  // A2/G3: the broadcast names no origin, so an enabled document must not be
  // torn down just because some other origin was disabled.
  const { page } = await pageBackedByWorker("https://example.com/login");
  await page.inject();
  assert.equal(page.listenerCount, 1);

  // A teardown broadcast arrives while the switch is still ON — exactly what a
  // reconcile-triggered broadcast looks like to a document that is still
  // authorized. The message names no origin, so the receiver has to revalidate
  // rather than assume it was the target.
  await page.deliver(teardownMessage());

  assert.equal(page.listenerCount, 1, "a broadcast tore down a still-authorized document");
  assert.equal(page.guarded, true);
});

test("content_overlay: teardown after the switch is off removes the listener", async () => {
  const { page, worker } = await pageBackedByWorker("https://example.com/login");
  await page.inject();

  await worker.disable();
  await page.deliver(teardownMessage());

  assert.equal(page.listenerCount, 0);
  assert.equal(page.guarded, false);
});

test("content_overlay: teardown revalidation fails closed when the worker is gone", async () => {
  const page = new FakePage({ url: "https://example.com/login", respond: async () => APPROVED });
  await page.inject();

  page.respond = async () => {
    throw new Error("Extension context invalidated.");
  };
  await page.deliver(teardownMessage());

  assert.equal(page.listenerCount, 0);
  assert.equal(page.guarded, false);
});

test("content_overlay: a foreign or malformed message is ignored entirely", async () => {
  const page = new FakePage({ url: "https://example.com/login", respond: async () => APPROVED });
  await page.inject();
  const sentAfterBootstrap = page.sent.length;

  for (const message of [
    undefined,
    null,
    "teardown",
    { type: "teardown" },
    { channel: "other-extension", type: "teardown", revision: 9 },
    { channel: security.CHANNEL, type: "bootstrapResult", revision: 9 },
    { channel: security.CHANNEL, type: "fill", revision: 9 },
  ]) {
    await page.deliver(message);
  }

  // Not one revalidation round trip was provoked, and nothing was torn down.
  assert.equal(page.sent.length, sentAfterBootstrap);
  assert.equal(page.listenerCount, 1);
  assert.equal(page.guarded, true);
});

test("content_overlay: teardown revalidation re-sends the same exact-origin claim", async () => {
  const page = new FakePage({ url: "https://example.com:8443/login", respond: async () => APPROVED });
  await page.inject();

  await page.deliver(teardownMessage());

  assert.equal(page.sentOfType("bootstrap").length, 2);
  for (const message of page.sentOfType("bootstrap")) {
    assert.equal(message.origin, HTTPS_EXAMPLE_8443);
    assert.equal(security.assertNoForbiddenKeys(message).ok, true);
  }
  // Still approved, so nothing changed.
  assert.equal(page.listenerCount, 1);
});

test("content_overlay: a torn-down document stops answering teardown", async () => {
  const page = new FakePage({ url: "https://example.com/login", respond: async () => APPROVED });
  await page.inject();

  page.respond = async () => ({ ok: false, error: { code: "disabled" } });
  await page.deliver(teardownMessage());
  const sentAfterTeardown = page.sent.length;

  await page.deliver(teardownMessage(5));
  assert.equal(page.sent.length, sentAfterTeardown);
  assert.equal(page.listenerCount, 0);
});

// ---------------------------------------------------------------------------
// A039 — behaviour + visual-DOM contract. The five test names below are
// REQUIRED VERBATIM by specs/009-in-page-autofill-overlay/tasks.md (A039) and
// are cited by spec.md as the noncanonical-platform acceptance evidence.
// ---------------------------------------------------------------------------

test("renders every state with metadata-only DOM", async () => {
  // One canary per surface that must never enter the DOM: the entry id, the
  // fill token, and the focus nonce. Titles/display services are the ONLY
  // item-derived text allowed to render.
  const states = [
    ["matches", (m) => matchesResult(m, {
      items: [item({ entryId: "entry-canary-1" })],
      fillToken: "token-canary-1",
    })],
    ["no-fillable", (m) => matchesResult(m, {
      items: [item({ entryId: "entry-canary-1", matchType: "possible", fillEligible: false })],
      fillToken: null,
    })],
    ["no-matches", (m) => matchesResult(m, { items: [] })],
    ["locked", (m) => errorResult("matchesResult", "locked", m)],
    ["no_host", (m) => errorResult("matchesResult", "no_host", m)],
    ["timeout", (m) => errorResult("matchesResult", "timeout", m)],
    ["unsupported_frame", (m) => errorResult("matchesResult", "unsupported_frame", m)],
    ["unsupported_capability", (m) => errorResult("matchesResult", "unsupported_capability", m)],
    ["stale_session", (m) => errorResult("matchesResult", "stale_session", m)],
  ];
  for (const [label, matches] of states) {
    const { page, password: pwInput, handlers } = await loginPage();
    handlers.matches = matches;
    await page.focus(pwInput);
    assert.equal(overlayCount(page), 1, `${label}: state must render`);
    assert.equal(typeof statusText(page), "string", label);
    assert.ok(statusText(page).length > 0, `${label}: status text missing`);

    const observable = page.captureObservableState();
    const nonce = page.sentOfType("requestMatches")[0].focusNonce;
    for (const canary of ["entry-canary-1", "token-canary-1", nonce]) {
      assert.ok(!observable.includes(canary), `${label}: "${canary}" leaked into the DOM`);
    }
    // Loading state, observed mid-flight, is covered by the gated A030 test;
    // here every terminal state has been proven metadata-only.
  }
});

// WCAG 3.1.2 — every fixed English string this file renders must live under
// an ancestor with an explicit `lang="en"`, regardless of what language the
// host page declares. The host carries it (and the shadow tree inherits it
// over the flattened tree); the light-DOM fallback listbox (A040) is a
// SIBLING of the host, not a descendant, so it cannot rely on that
// inheritance and needs its own explicit attribute.
test("declares lang=en on the overlay host and the light-DOM listbox for every state", async () => {
  const states = [
    ["matches", (m) => matchesResult(m, { items: [item({ title: "First" })] })],
    ["no-matches", (m) => matchesResult(m, { items: [] })],
    ["locked", (m) => errorResult("matchesResult", "locked", m)],
    ["no_host", (m) => errorResult("matchesResult", "no_host", m)],
    ["timeout", (m) => errorResult("matchesResult", "timeout", m)],
    ["unsupported_frame", (m) => errorResult("matchesResult", "unsupported_frame", m)],
    ["unsupported_capability", (m) => errorResult("matchesResult", "unsupported_capability", m)],
    ["stale_session", (m) => errorResult("matchesResult", "stale_session", m)],
  ];
  for (const [label, matches] of states) {
    const { page, password: pwInput, handlers } = await loginPage();
    handlers.matches = matches;
    await page.focus(pwInput);

    const host = page.overlayHosts()[0];
    assert.equal(host.getAttribute("lang"), "en", `${label}: host missing lang`);

    // The light listbox is a `fill`-session-only fixture (A040); it exists
    // for every state above since they all render a fill session, but stays
    // absent for a display-only "unsupported" session (asserted separately).
    const listbox = lightListboxEl(page);
    assert.ok(listbox, `${label}: expected a light listbox`);
    assert.equal(listbox.getAttribute("lang"), "en", `${label}: light listbox missing lang`);
  }
});

test("declares lang=en on the overlay host for a display-only unsupported (hint) session", async () => {
  // A035/A040 — focus on a cross-origin iframe drives the display-only
  // "hint" render path, which never creates a light listbox.
  const { page } = await loginPage();
  const iframe = page.document.createElement("iframe");
  iframe.setAttribute("src", "https://other.example/embedded-login");
  page.document.body.appendChild(iframe);
  await page.focus(iframe);

  const host = page.overlayHosts()[0];
  assert.ok(host, "the hint must still render a host");
  assert.equal(host.getAttribute("lang"), "en");
  assert.equal(lightListboxEl(page), undefined, "no light listbox for a hint");
});

test("anchors below, flips above, and clamps viewport", async () => {
  const { page, password: pwInput } = await loginPage();
  // Fallback overlay size is 320x240 (the CSS sizes; the fake reports an
  // unmeasurable host, exactly like a display:none-free but unlaid-out tree).

  // 1. Room below: anchored below the input, at its left edge.
  pwInput._rect = { top: 100, bottom: 120, left: 50, right: 250, width: 200, height: 20 };
  await page.focus(pwInput);
  let host = page.overlayHosts()[0];
  assert.equal(host.style.position, "fixed");
  assert.equal(host.style.top, "120px");
  assert.equal(host.style.left, "50px");

  // 2. No room below, room above: flipped above the input.
  pwInput._rect = { top: 700, bottom: 720, left: 50, right: 250, width: 200, height: 20 };
  await page.fireScroll(); // repositions on scroll
  assert.equal(host.style.top, `${700 - 240}px`, "must flip above");

  // 3. No room below NOR above: clamped inside the viewport.
  pwInput._rect = { top: 100, bottom: 700, left: 50, right: 250, width: 200, height: 600 };
  await page.fireScroll();
  assert.equal(host.style.top, `${768 - 240}px`, "must clamp to the viewport");

  // 4. Horizontal clamp, driven by a resize (zoom = fewer CSS pixels).
  pwInput._rect = { top: 100, bottom: 120, left: 900, right: 1000, width: 100, height: 20 };
  await page.setViewport(1024, 768);
  assert.equal(host.style.left, `${1024 - 320}px`, "must clamp horizontally");

  // 5. A shrunken viewport (zoomed page) re-clamps on resize.
  await page.setViewport(400, 300);
  assert.equal(host.style.left, `${400 - 320}px`);
  assert.equal(host.style.top, `${300 - 240}px`);
});

test("applies light/dark/forced-colors contract", async () => {
  const { page, password: pwInput } = await loginPage();
  await page.focus(pwInput);

  const styleEl = page.allElements().find((el) => el.tagName === "STYLE");
  assert.ok(styleEl, "the shadow tree must carry its own stylesheet");
  const css = styleEl.textContent;

  // The browser, not the script, picks the scheme: all four contracts are
  // declarative media sections of one static local stylesheet.
  assert.ok(css.includes("@media (prefers-color-scheme: dark)"), "dark contract missing");
  assert.ok(css.includes("@media (forced-colors: active)"), "forced-colors contract missing");
  assert.ok(css.includes("@media (prefers-reduced-motion: reduce)"), "reduced-motion contract missing");
  // Forced colors must defer to SYSTEM colors, not authored ones.
  for (const systemColor of ["Canvas", "CanvasText", "Highlight", "HighlightText"]) {
    assert.ok(css.includes(systemColor), `forced-colors must use ${systemColor}`);
  }
  // Reduced motion disables the only transition the overlay declares.
  assert.ok(/prefers-reduced-motion: reduce\)\{[^}]*\{transition:none;\}/.test(css));
  // The stylesheet is static local copy: nothing item- or origin-derived.
  assert.ok(!css.includes("example.com"));
});

test("exposes listbox/options/live state and restores ARIA", async () => {
  const { page, password: pwInput, handlers } = await loginPage();
  handlers.matches = (m) =>
    matchesResult(m, {
      items: [item({ title: "First" }), item({ entryId: "entry-2", title: "Second" })],
    });
  // Pre-existing anchor ARIA that the session will touch AND one it will not.
  pwInput.setAttribute("aria-expanded", "false");
  pwInput.setAttribute("aria-haspopup", "menu");
  pwInput.setAttribute("aria-label", "Password");
  await page.focus(pwInput);

  // Anchor combobox state while open.
  assert.equal(pwInput.getAttribute("aria-expanded"), "true");
  assert.equal(pwInput.getAttribute("aria-haspopup"), "listbox");

  // Listbox, options, stable ids, selection agreement.
  const list = listboxEl(page);
  assert.ok(list, "role=listbox missing");
  const rows = optionRows(page);
  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map((row) => row.id), ["kv-option-0", "kv-option-1"]);
  assert.deepEqual(rows.map((row) => row.getAttribute("aria-selected")), ["true", "false"]);
  const active = list.getAttribute("aria-activedescendant");
  assert.ok(rows.some((row) => row.id === active), "activedescendant must reference a real row");

  // Live region: polite status, count first, then selected label + position
  // on arrow move (the closed-shadow IDREF fallback the spec mandates).
  const status = page.allElements().find((el) => el.id === "kv-status");
  assert.equal(status.getAttribute("role"), "status");
  assert.equal(status.getAttribute("aria-live"), "polite");
  assert.equal(status.textContent, "2 Custode suggestions");
  await page.pressKey("ArrowDown");
  assert.equal(status.textContent, "Second, 2 of 2");
  assert.deepEqual(optionRows(page).map((row) => row.getAttribute("aria-selected")), ["false", "true"]);
  assert.equal(listboxEl(page).getAttribute("aria-activedescendant"), "kv-option-1");

  // Teardown restores EVERY touched attribute to its pre-session value and
  // leaves the untouched one alone.
  await page.pressKey("Escape");
  assert.equal(pwInput.getAttribute("aria-expanded"), "false");
  assert.equal(pwInput.getAttribute("aria-haspopup"), "menu");
  assert.equal(pwInput.getAttribute("aria-label"), "Password");

  // An anchor that HAD no ARIA gets it fully removed, not set to a default.
  const bare = await loginPage();
  await bare.page.focus(bare.password);
  assert.equal(bare.password.getAttribute("aria-expanded"), "true");
  await bare.page.pressKey("Escape");
  assert.equal(bare.password.getAttribute("aria-expanded"), null);
  assert.equal(bare.password.getAttribute("aria-haspopup"), null);
});

test("teardown removes host/listeners and never submits", async () => {
  // Via the keyboard fill — the full pointerless path — and via Escape.
  const { page, form, password: pwInput, handlers } = await loginPage();
  handlers.fill = (m) => fillResult(m, { password: FILL_VALUE_G });
  await page.focus(pwInput);
  assert.equal(overlayCount(page), 1);
  assert.ok(
    page.document.listenerTypes.includes("keydown"),
    "session capture listener missing"
  );
  const documentListenersBefore = page.document.listenerTypes.length;

  const enter = await page.pressKey("Enter");
  assert.equal(enter.defaultPrevented, true, "the fill Enter is consumed");
  assert.equal(pwInput.value, FILL_VALUE_G);

  // Fill ends with teardown: host gone, session listeners gone, instance
  // listeners (focusin/focusout/visibility) still owned by the instance.
  assert.equal(overlayCount(page), 0, "host must be removed");
  assert.ok(
    !page.document.listenerTypes.includes("keydown"),
    "session keydown must be aborted"
  );
  assert.equal(page.document.listenerTypes.length, documentListenersBefore - 3,
    "session-scoped document listeners (keydown, scroll, mouseup) must be aborted");
  assert.equal(page._intervals.size, 0, "watchdog must be stopped");
  assert.equal(page._timeouts.size, 0, "no deferred timer may survive");
  assert.equal(page.submitCount, 0, "the overlay must never submit");

  // And the page's own submit machinery was never touched on the Escape path.
  const second = await loginPage();
  let submitSeen = 0;
  second.form.addEventListener("submit", () => { submitSeen += 1; });
  await second.page.focus(second.password);
  await second.page.pressKey("Escape");
  assert.equal(overlayCount(second.page), 0);
  assert.equal(second.page.submitCount + submitSeen, 0);
  assert.ok(form !== null);
});
