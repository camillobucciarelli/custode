// 009 Slice B2 (B010–B012) — explicit Generate: capability gating, one-shot
// sender-bound token, nonce-checked single fill, and app-owned pending state.
//
// Worker half runs the SHIPPED `OverlayRouter`/`OverlayLifecycle` against a
// fake native transport that models the B007 `hello` capability advertisement
// and the B006/B007 `generatePendingEntry` contract. Content half runs the
// SHIPPED `content_overlay.js` inside the `fake_page.js` isolated world.
// No rule is re-implemented here; every assertion exercises production code.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { FakePage, FakeEvent } = require("./fake_page.js");
const { FakeBrowser } = require("./fake_browser.js");
const routes = require("../overlay_routes.js");
const { OverlayLifecycle } = require("../overlay_lifecycle.js");
const {
  security,
  RUNTIME_ID,
  contentScriptSender,
  overlayMessage,
  bindingA,
  bindingB,
} = require("./helpers.js");
const {
  ORIGIN,
  PAGE_URL,
  matchesResult,
  generateResult,
  errorResult,
  loginPage,
  statusText,
  optionRows,
  overlayCount,
} = require("./session_helpers.js");

// Runtime-assembled canaries: distinctive, grep-able, and never a
// credential-shaped literal in source (GitGuardian).
const GENERATED_SECRET = ["b2", "canary", "generated", "value"].join("-");
const PENDING_ID_CANARY = ["b2", "pending", "record", "canary"].join("-");

const GENERATE_DISABLED_TEXT = "Open Custode to generate a password.";
const GENERATE_ACTIVE_TEXT =
  "Generate a password — confirm the save in Custode.";

// ---------------------------------------------------------------------------
// Worker-side harness. Models the Slice A1/B1 native transport only.
// ---------------------------------------------------------------------------

function item(overrides = {}) {
  return {
    entryId: "entry-1",
    title: "Example",
    displayService: "example.com",
    matchType: "exact-origin",
    fillEligible: true,
    ...overrides,
  };
}

class FakeNative {
  constructor({ binding = bindingA(), items = [item()], capability = true } = {}) {
    this.binding = binding;
    this.items = items;
    this.capability = capability;
    this.helloOk = true;
    this.calls = [];
    this.errors = new Map();
    this.echoBinding = undefined;
    this.echoBindingSet = false;
  }

  failWith(type, code) {
    this.errors.set(type, { ok: false, error: { code } });
  }

  send = async (type, payload) => {
    this.calls.push({ type, payload });
    if (this.errors.has(type)) return this.errors.get(type);

    if (type === "hello") {
      if (!this.helloOk) return { ok: false, error: { code: "no_host" } };
      return {
        ok: true,
        data: {
          capabilities: this.capability
            ? [security.GENERATE_CAPABILITY]
            : ["overlayExactOrigin"],
        },
      };
    }
    if (type === "overlayQueryCredentials") {
      return {
        ok: true,
        data: {
          metadataOnly: true,
          matchPolicy: routes.MATCH_POLICY,
          target: payload.url,
          fillAvailable: true,
          databaseId: this.binding.databaseId,
          sessionBinding: { ...this.binding },
          items: this.items.map((entry) => ({ ...entry })),
        },
      };
    }
    if (type === "generatePendingEntry") {
      return {
        ok: true,
        data: {
          pendingGenerationId: PENDING_ID_CANARY,
          expiresAtEpochMs: Date.now() + 5 * 60 * 1000,
          origin: payload.origin,
          sessionBinding: this.echoBindingSet
            ? this.echoBinding
            : { ...this.binding },
          settingsRevision: 4,
          password: GENERATED_SECRET,
        },
      };
    }
    return { ok: true, data: {} };
  };

  callsOf(type) {
    return this.calls.filter((call) => call.type === type);
  }
}

class Harness {
  constructor({ native } = {}) {
    this.browser = new FakeBrowser({
      storage: {
        [security.OVERLAY_CONFIG_KEY]: {
          version: 2,
          revision: 5,
          enabled: true,
        },
        [security.OVERLAY_REVISION_FLOOR_KEY]: 5,
      },
      granted: [...security.GLOBAL_PERMISSION_PATTERNS],
      tabs: [{ id: 42 }],
    });
    this.native = native ?? new FakeNative();
    this.nowMs = 1_700_000_000_000;
    this.restart();
  }

  restart() {
    this.lifecycle = new OverlayLifecycle({ browser: this.browser });
    this.router = new routes.OverlayRouter({
      lifecycle: this.lifecycle,
      runtimeId: RUNTIME_ID,
      native: this.native.send,
      now: () => this.nowMs,
    });
    return this.router;
  }

  dispatch(message, sender) {
    return this.router.dispatch(
      message,
      sender ?? contentScriptSender({ frameUrl: PAGE_URL })
    );
  }

  matches(fields = {}) {
    return this.dispatch(
      overlayMessage("requestMatches", {
        origin: ORIGIN,
        focusNonce: "nonce-1",
        fieldKind: "password",
        ...fields,
      })
    );
  }

  generate(fields = {}) {
    return this.dispatch(
      overlayMessage("generate", {
        origin: ORIGIN,
        focusNonce: "nonce-1",
        generateToken: "no-such-token",
        sessionBinding: bindingA(),
        ...fields,
      })
    );
  }

  async mintGenerateToken(fields = {}) {
    const result = await this.matches(fields);
    assert.equal(result.ok, true, "expected a successful metadata query");
    assert.equal(result.generateAvailable, true);
    assert.equal(typeof result.generateToken, "string");
    return result;
  }
}

// ---------------------------------------------------------------------------
// B010 — capability travels from `hello` into `matchesResult`.
// ---------------------------------------------------------------------------

test("B010: an advertised capability yields generateAvailable plus a token, and the result passes the shipped validator", async () => {
  const harness = new Harness();
  const result = await harness.matches();
  assert.equal(result.ok, true);
  assert.equal(result.generateAvailable, true);
  assert.equal(typeof result.generateToken, "string");
  assert.equal(security.validateMatchesResult(result).ok, true);
  // hello rode alongside the query — one of each.
  assert.equal(harness.native.callsOf("hello").length, 1);
  assert.equal(harness.native.callsOf("overlayQueryCredentials").length, 1);
});

test("B010: an old peer (hello without the capability, or no hello at all) yields generateAvailable=false and no token", async () => {
  for (const configure of [
    (native) => {
      native.capability = false;
    },
    (native) => {
      native.helloOk = false;
    },
    (native) => {
      native.failWith("hello", "unsupported_type");
    },
  ]) {
    const native = new FakeNative();
    configure(native);
    const harness = new Harness({ native });
    const result = await harness.matches();
    assert.equal(result.ok, true, "metadata query still succeeds");
    assert.equal(result.generateAvailable, false);
    assert.equal("generateToken" in result, false);
  }
});

test("B010: the validator refuses a generate token without an affirmative capability", () => {
  const forged = {
    ok: true,
    type: "matchesResult",
    origin: ORIGIN,
    focusNonce: "nonce-1",
    revision: 5,
    sessionBinding: bindingA(),
    items: [],
    generateAvailable: false,
    generateToken: "gen-1",
  };
  const result = security.validateMatchesResult(forged);
  assert.equal(result.ok, false);
  assert.equal(result.error, "token_without_capability");
});

// ---------------------------------------------------------------------------
// B010/B011 — the worker generate route.
// ---------------------------------------------------------------------------

test("B011: a valid generate consumes the token, sends EXACTLY the session tuple (no settings payload), and forwards only the password", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();

  const response = await harness.generate({
    generateToken: minted.generateToken,
  });
  assert.equal(response.ok, true);
  // The native payload is the closed 4-key tuple. There is no field a
  // settings object could travel in — the schema has none and the payload
  // carries none.
  assert.deepEqual(harness.native.callsOf("generatePendingEntry"), [
    {
      type: "generatePendingEntry",
      payload: {
        origin: ORIGIN,
        expectedDatabaseId: "db-a",
        expectedCacheGeneration: "cache-a1",
        expectedBridgeGeneration: "bridge-a1",
      },
    },
  ]);
  // The result is built field by field: password only. No pending id, no
  // expiry, no settings revision — the app owns the pending record.
  assert.deepEqual(Object.keys(response).sort(), [
    "data",
    "focusNonce",
    "ok",
    "origin",
    "sessionBinding",
    "type",
  ]);
  assert.deepEqual(Object.keys(response.data), ["password"]);
  assert.equal(response.data.password, GENERATED_SECRET);
  assert.ok(!JSON.stringify(response).includes(PENDING_ID_CANARY));
});

test("B012: a generate message carrying a settings key of any name is refused before native I/O", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();
  // Every value shape too: a widened schema could admit one type and this
  // loop must still refuse it (default-deny, no settings key of ANY kind).
  for (const key of ["settings", "generatorSettings", "length", "options"]) {
    for (const value of [{ length: 64 }, [8], 64, "long", true]) {
      const response = await harness.generate({
        generateToken: minted.generateToken,
        [key]: value,
      });
      assert.equal(response.ok, false, `${key}=${JSON.stringify(value)}`);
      assert.equal(
        response.error.code,
        "invalid_request",
        `${key}=${JSON.stringify(value)}`
      );
    }
  }
  assert.deepEqual(harness.native.callsOf("generatePendingEntry"), []);
});

test("B012: a replayed generate token loses by construction — one native call ever, no retry after delivery", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();

  const first = await harness.generate({ generateToken: minted.generateToken });
  assert.equal(first.ok, true);
  const replay = await harness.generate({ generateToken: minted.generateToken });
  assert.equal(replay.ok, false);
  assert.equal(replay.error.code, "stale_session");
  assert.ok(!JSON.stringify(replay).includes(GENERATED_SECRET));
  assert.equal(harness.native.callsOf("generatePendingEntry").length, 1);
});

test("B012: a failed generate does not retry and does not return the token", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();
  harness.native.failWith("generatePendingEntry", "app_bridge_timeout");

  const failed = await harness.generate({ generateToken: minted.generateToken });
  assert.equal(failed.ok, false);
  assert.equal(failed.error.code, "timeout");
  assert.equal(harness.native.callsOf("generatePendingEntry").length, 1);

  // The token was consumed by the failed attempt: no second chance.
  harness.native.errors.clear();
  const second = await harness.generate({ generateToken: minted.generateToken });
  assert.equal(second.ok, false);
  assert.equal(second.error.code, "stale_session");
  assert.equal(harness.native.callsOf("generatePendingEntry").length, 1);
});

test("B012: app lock and expiry surface as the stable public codes", async () => {
  const cases = [
    ["app_bridge_unavailable", "locked"],
    ["unauthorized", "locked"],
    ["unsupported_capability", "unsupported_capability"],
    ["stale_session", "stale_session"],
    ["invalid_request", "invalid_request"],
    ["app_bridge_invalid_response", "internal_error"],
    ["app_bridge_error", "internal_error"],
  ];
  for (const [nativeCode, publicCode] of cases) {
    const harness = new Harness();
    const minted = await harness.mintGenerateToken();
    harness.native.failWith("generatePendingEntry", nativeCode);
    const response = await harness.generate({
      generateToken: minted.generateToken,
    });
    assert.equal(response.ok, false, nativeCode);
    assert.equal(response.error.code, publicCode, nativeCode);
  }
});

test("B012: a stale nonce, a foreign frame, or a changed binding refuses without native I/O reaching the secret", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();

  const wrongNonce = await harness.generate({
    generateToken: minted.generateToken,
    focusNonce: "nonce-2",
  });
  assert.equal(wrongNonce.ok, false);
  assert.equal(wrongNonce.error.code, "stale_session");
  assert.deepEqual(harness.native.callsOf("generatePendingEntry"), []);

  const minted2 = await harness.mintGenerateToken();
  const wrongFrame = await harness.router.dispatch(
    overlayMessage("generate", {
      origin: ORIGIN,
      focusNonce: "nonce-1",
      generateToken: minted2.generateToken,
      sessionBinding: bindingA(),
    }),
    contentScriptSender({ frameUrl: PAGE_URL, frameId: 7, topUrl: PAGE_URL })
  );
  assert.equal(wrongFrame.ok, false);
  assert.equal(wrongFrame.error.code, "forbidden");

  const minted3 = await harness.mintGenerateToken();
  const wrongBinding = await harness.generate({
    generateToken: minted3.generateToken,
    sessionBinding: bindingB(),
  });
  assert.equal(wrongBinding.ok, false);
  assert.equal(wrongBinding.error.code, "stale_session");
  assert.deepEqual(harness.native.callsOf("generatePendingEntry"), []);
});

test("B012: a vault switch in flight (binding echo mismatch) drops the secret before forwarding", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();
  harness.native.echoBinding = bindingB();
  harness.native.echoBindingSet = true;

  const response = await harness.generate({
    generateToken: minted.generateToken,
  });
  assert.equal(response.ok, false);
  assert.equal(response.error.code, "stale_session");
  assert.ok(!JSON.stringify(response).includes(GENERATED_SECRET));
});

test("B012: a worker restart forgets the generate grant — the token answers stale_session", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();
  harness.restart();
  const response = await harness.generate({
    generateToken: minted.generateToken,
  });
  assert.equal(response.ok, false);
  assert.equal(response.error.code, "stale_session");
});

test("B012: fill and generate tokens are not interchangeable, and a cross-purpose attempt burns the token", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();
  assert.equal(typeof minted.fillToken, "string");

  // Fill token presented on the generate path: refused, and burned.
  const crossed = await harness.generate({ generateToken: minted.fillToken });
  assert.equal(crossed.ok, false);
  assert.equal(crossed.error.code, "forbidden");
  const fillAfter = await harness.dispatch(
    overlayMessage("fill", {
      origin: ORIGIN,
      focusNonce: "nonce-1",
      fillToken: minted.fillToken,
      entryId: "entry-1",
      sessionBinding: bindingA(),
    })
  );
  assert.equal(fillAfter.ok, false);
  assert.equal(fillAfter.error.code, "stale_session");

  // Generate token presented on the fill path: refused as well.
  const minted2 = await harness.mintGenerateToken();
  const fillWithGenerate = await harness.dispatch(
    overlayMessage("fill", {
      origin: ORIGIN,
      focusNonce: "nonce-1",
      fillToken: minted2.generateToken,
      entryId: "entry-1",
      sessionBinding: bindingA(),
    })
  );
  assert.equal(fillWithGenerate.ok, false);
  assert.equal(fillWithGenerate.error.code, "forbidden");
  assert.deepEqual(harness.native.callsOf("generatePendingEntry"), []);
  assert.deepEqual(harness.native.callsOf("overlayRevealForFill"), []);
});

test("B012: neither the pending id nor any secret ever reaches worker storage", async () => {
  const harness = new Harness();
  const minted = await harness.mintGenerateToken();
  const response = await harness.generate({
    generateToken: minted.generateToken,
  });
  assert.equal(response.ok, true);
  const stored = JSON.stringify(harness.browser.store);
  assert.ok(!stored.includes(PENDING_ID_CANARY), "pending id persisted");
  assert.ok(!stored.includes(GENERATED_SECRET), "secret persisted");
});

// ---------------------------------------------------------------------------
// B010/B011 — content-script behaviour.
// ---------------------------------------------------------------------------

function generateRow(page) {
  const row = page.allElements().find((el) => el.id === "kv-generate");
  assert.ok(row, "generate control missing");
  return row;
}

test("B010: without the capability the row stays disabled with the honest app-directing copy, and a click sends nothing", async () => {
  const variants = [
    (message) => matchesResult(message), // pre-B2 worker: no field at all
    (message) => matchesResult(message, { generateAvailable: false }),
  ];
  for (const matches of variants) {
    const { page, password, handlers } = await loginPage();
    handlers.matches = matches;
    await page.focus(password);
    const row = generateRow(page);
    assert.equal(row.disabled, true);
    assert.equal(row.getAttribute("aria-disabled"), "true");
    assert.equal(row.textContent, GENERATE_DISABLED_TEXT);
    const sentBefore = page.sent.length;
    await page.click(row);
    assert.equal(page.sent.length, sentBefore, "no message may leave");
  }
});

test("B010: generateAvailable without a token is a legal shape that keeps the row disabled — a click sends nothing", async () => {
  // A worker that advertises the capability but could not mint a token (grant
  // store refusal) sends generateAvailable:true with NO generateToken. The
  // validator accepts it, and the row must require BOTH — the capability flag
  // alone can never activate it.
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) => {
    const result = matchesResult(message, { generateAvailable: true });
    // The helper mints gen-token-1 alongside the flag; strip it explicitly.
    delete result.generateToken;
    return result;
  };
  await page.focus(password);
  const row = generateRow(page);
  assert.equal(row.disabled, true);
  assert.equal(row.getAttribute("aria-disabled"), "true");
  assert.equal(row.textContent, GENERATE_DISABLED_TEXT);
  const sentBefore = page.sent.length;
  await page.click(row);
  assert.equal(page.sent.length, sentBefore, "no message may leave");
  // Enter cannot reach a virtual Generate option either: it passes through.
  await page.pressKey("ArrowDown");
  const enter = await page.pressKey("Enter");
  assert.equal(page.sentOfType("generate").length, 0);
  assert.equal(enter.defaultPrevented, true, "Enter still fills the real item");
});

test("B011: an explicit click generates, fills the password input once through the shipped path, never submits, and tears down", async () => {
  const { page, password, username, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, { generateAvailable: true });
  handlers.generate = (message) =>
    generateResult(message, { generated: GENERATED_SECRET });

  await page.focus(password);
  const row = generateRow(page);
  assert.equal(row.disabled, false);
  assert.equal(row.textContent, GENERATE_ACTIVE_TEXT);

  await page.click(row);

  const sent = page.sentOfType("generate");
  assert.equal(sent.length, 1);
  // Sender-bound to the CURRENT session: same nonce as the metadata query,
  // the minted token, the session binding — and no settings-shaped key.
  assert.equal(sent[0].focusNonce, page.sentOfType("requestMatches")[0].focusNonce);
  assert.equal(sent[0].generateToken, "gen-token-1");
  assert.deepEqual(Object.keys(sent[0]).sort(), [
    "channel",
    "focusNonce",
    "generateToken",
    "origin",
    "sessionBinding",
    "type",
    "version",
  ]);

  assert.equal(password.value, GENERATED_SECRET);
  assert.equal(username.value, "", "username is never touched by generate");
  assert.equal(page.submitCount, 0);
  assert.equal(overlayCount(page), 0, "session tears down after the fill");
});

test("B011: Enter generates only after the row is explicitly arrow-selected", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, { generateAvailable: true });
  handlers.generate = (message) =>
    generateResult(message, { generated: GENERATED_SECRET });

  await page.focus(password);
  // One item + the generate row: ArrowDown moves onto the virtual last option.
  await page.pressKey("ArrowDown");
  const enter = await page.pressKey("Enter");
  assert.equal(enter.defaultPrevented, true);
  assert.equal(page.sentOfType("generate").length, 1);
  assert.equal(password.value, GENERATED_SECRET);
  assert.equal(page.submitCount, 0);
});

test("B011: with no matches the row is active but Enter passes through until the user arrows onto it", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, { items: [], generateAvailable: true });
  handlers.generate = (message) =>
    generateResult(message, { generated: GENERATED_SECRET });

  await page.focus(password);
  const row = generateRow(page);
  assert.equal(row.disabled, false);

  // Enter without explicit selection: the page keeps its key. No hijack.
  const passThrough = await page.pressKey("Enter");
  assert.equal(passThrough.defaultPrevented, false);
  assert.equal(page.sentOfType("generate").length, 0);

  await page.pressKey("ArrowDown");
  const enter = await page.pressKey("Enter");
  assert.equal(enter.defaultPrevented, true);
  assert.equal(page.sentOfType("generate").length, 1);
  assert.equal(password.value, GENERATED_SECRET);
});

test("B011: a second activation while the first is in flight sends nothing (content-side one-shot)", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, { generateAvailable: true });
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  handlers.generate = async (message) => {
    await gate;
    return generateResult(message, { generated: GENERATED_SECRET });
  };

  await page.focus(password);
  await page.pressKey("ArrowDown");
  // Two rapid Enters: the token dies on the first send.
  const first = page.pressKey("Enter");
  const second = page.pressKey("Enter");
  release();
  await first;
  await second;

  assert.equal(page.sentOfType("generate").length, 1);
  assert.equal(password.value, GENERATED_SECRET);
});

test("B012: teardown during an in-flight generate (navigation) discards the late response — nothing fills", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, { generateAvailable: true });
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  handlers.generate = async (message) => {
    await gate;
    return generateResult(message, { generated: GENERATED_SECRET });
  };

  await page.focus(password);
  const row = generateRow(page);
  // Fire the click WITHOUT settling, then navigate away while in flight.
  const clickDone = page.click(row);
  page.window._invoke(new FakeEvent("pagehide", { bubbles: false }));
  assert.equal(overlayCount(page), 0, "pagehide tears the session down");
  release();
  await clickDone;

  assert.equal(password.value, "", "a late response for a dead session fills nothing");
  assert.equal(page.submitCount, 0);
});

test("B012: a generate answer for a previous session (stale nonce via refocus) is ignored", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, { generateAvailable: true });
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  handlers.generate = async (message) => {
    await gate;
    return generateResult(message, { generated: GENERATED_SECRET });
  };

  await page.focus(password);
  const clickDone = page.click(generateRow(page));
  // Escape tears the session down while the request is in flight; a fresh
  // focus on the same field starts a NEW session with a NEW nonce.
  page._propagate(
    password,
    new FakeEvent("keydown", {
      bubbles: true,
      cancelable: true,
      composed: true,
      isTrusted: true, // a REAL user Escape (A040: untrusted keys are ignored)
      key: "Escape",
    })
  );
  assert.equal(overlayCount(page), 0, "Escape dismissed the old session");
  password.blur();
  password.focus();
  release();
  await clickDone;
  await page.settle();

  assert.equal(password.value, "", "the stale-nonce response may not fill");
  // The NEW session is alive and rendered.
  assert.equal(overlayCount(page), 1);
});

test("B012: renderable generate failures show the honest state; stale_session offers retry that re-mints", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, { generateAvailable: true });
  handlers.generate = (message) =>
    errorResult("generateResult", "locked", message);

  await page.focus(password);
  await page.click(generateRow(page));
  assert.equal(statusText(page), "Open and unlock Custode.");
  assert.equal(overlayCount(page), 1, "renderable error keeps the overlay");
  assert.equal(password.value, "");

  handlers.generate = (message) =>
    errorResult("generateResult", "stale_session", message);
  const { page: page2, password: password2, handlers: handlers2 } = await loginPage();
  handlers2.matches = (message) =>
    matchesResult(message, { generateAvailable: true });
  handlers2.generate = (message) =>
    errorResult("generateResult", "stale_session", message);
  await page2.focus(password2);
  await page2.click(generateRow(page2));
  assert.equal(statusText(page2), "Custode session changed.");
  const retry = page2.allElements().find((el) => el.id === "kv-retry");
  assert.ok(retry, "stale_session offers Try again");
  await page2.click(retry);
  // The re-query re-minted a token and re-enabled the row.
  assert.equal(page2.sentOfType("requestMatches").length, 2);
  assert.equal(generateRow(page2).disabled, false);
});

test("B012: the generate row never renders in unsupported-frame (hint) sessions", async () => {
  const { page, password, handlers } = await loginPage({
    bootstrap: {
      ok: true,
      type: "bootstrapResult",
      enabled: true,
      frameSupport: "unsupported",
      revision: 3,
    },
  });
  handlers.matches = () => {
    throw new Error("an unsupported frame must never query");
  };
  await page.focus(password);
  assert.equal(page.sentOfType("requestMatches").length, 0);
  const row = generateRow(page);
  assert.equal(row.disabled, true, "hint sessions keep Generate disabled");
});
