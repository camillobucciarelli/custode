// 009 Slice A4 / A032 — executable secret-lifetime tests.
//
// METHOD. These tests run the WHOLE shipped path end to end: the content
// script in its isolated world (`fake_page.js`), the real `OverlayLifecycle`
// and `OverlayRouter` as the worker, and a fake native host that models only
// the Slice A1 transport contract. The secret searched for is the REAL one
// redeemed through the production dispatcher — never a copy planted by the
// test — so a leak anywhere on the real path is found by looking for the real
// bytes. Asserting on internal state ("the map is empty") proves nothing; an
// empty map coexists happily with a password sitting in a dataset attribute.
//
// WHAT IS CAPTURED: the full page DOM and every shadow root ever created
// (attached or detached), all element attributes/dataset/inline style/text,
// the content world's globals, its console output, every message the content
// script ever sent, the worker's durable storage, and the teardown broadcasts.
//
// WHAT IS DELIBERATELY NOT CLAIMED (SR-5): garbage collection, heap erasure,
// DevTools invisibility, performance-timeline absence, or that the page
// cannot read the value THE FILL PUT IN ITS OWN INPUT. JavaScript cannot
// verify any of those, so no test below pretends to.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { FakePage } = require("./fake_page.js");
const { FakeBrowser } = require("./fake_browser.js");
const routes = require("../overlay_routes.js");
const { OverlayLifecycle } = require("../overlay_lifecycle.js");
const { security, RUNTIME_ID, bindingA, bindingB } = require("./helpers.js");

const ORIGIN = "https://example.com";
const PAGE_URL = "https://example.com/login";

// Distinctive, grep-able, and never a plausible attribute value by accident.
// Assembled at runtime: no credential-shaped literal in the source (GitGuardian).
const A032_FILL_VALUE = ["a032", "canary", "fill", "token"].join("-");
const SECRET_USERNAME = "kv-A032-real-username-77b1e0";
// B012 — the GENERATED secret and the app-owned pending id, both redeemed
// through the production dispatcher; the scan looks for the real bytes.
const B2_GENERATED_VALUE = ["b012", "canary", "generated", "secret"].join("-");
const B2_PENDING_ID = ["b012", "pending", "id", "canary"].join("-");

/** Models the Slice A1 native transport only; no authorization decisions. */
class FakeNative {
  constructor() {
    this.binding = bindingA();
    this.items = [
      {
        entryId: "entry-1",
        title: "Example",
        displayService: "example.com",
        matchType: "exact-origin",
        fillEligible: true,
      },
    ];
  }

  send = async (type, payload) => {
    if (type === "hello") {
      // B007 — the host advertises the generation capability.
      return { ok: true, data: { capabilities: [security.GENERATE_CAPABILITY] } };
    }
    if (type === "generatePendingEntry") {
      return {
        ok: true,
        data: {
          pendingGenerationId: B2_PENDING_ID,
          expiresAtEpochMs: Date.now() + 5 * 60 * 1000,
          origin: payload.origin,
          sessionBinding: { ...this.binding },
          settingsRevision: 4,
          password: B2_GENERATED_VALUE,
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
    if (type === "overlayRevealForFill") {
      return {
        ok: true,
        data: {
          entryId: payload.entryId,
          matchPolicy: routes.MATCH_POLICY,
          origin: payload.origin,
          sessionBinding: { ...this.binding },
          username: SECRET_USERNAME,
          password: A032_FILL_VALUE,
        },
      };
    }
    return { ok: true, data: {} };
  };
}

/**
 * The full shipped stack: real worker (lifecycle + router) answering a real
 * content script, over a fake browser and fake native transport.
 */
async function fullStack() {
  const browser = new FakeBrowser({
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
  const native = new FakeNative();
  const lifecycle = new OverlayLifecycle({ browser });
  const router = new routes.OverlayRouter({
    lifecycle,
    runtimeId: RUNTIME_ID,
    native: native.send,
    now: () => Date.now(),
  });

  const page = new FakePage({ url: PAGE_URL });
  page.respond = (message) =>
    router.dispatch(message, {
      id: RUNTIME_ID,
      url: page.url,
      frameId: 0,
      tab: { id: 42, url: page.url },
    });

  const doc = page.document;
  const form = doc.createElement("form");
  const username = doc.createElement("input");
  username.setAttribute("type", "text");
  username.setAttribute("autocomplete", "username");
  const password = doc.createElement("input");
  password.setAttribute("type", "password");
  form.appendChild(username);
  form.appendChild(password);
  doc.body.appendChild(form);

  await page.inject();
  assert.equal(page.listenerCount, 1, "bootstrap must be approved end to end");
  return { page, browser, native, lifecycle, form, username, password };
}

/** Every observable surface EXCEPT the allowed sink (input values). */
function observableSurfaces({ page, browser }) {
  return [
    page.captureObservableState(),
    JSON.stringify(page.sent),
    JSON.stringify(browser.store),
    JSON.stringify(browser.deliveredTeardowns),
  ].join("\n");
}

function assertNoSecretIn(text, label) {
  assert.ok(!text.includes(A032_FILL_VALUE), `${label}: password leaked`);
  assert.ok(!text.includes(SECRET_USERNAME), `${label}: username leaked`);
  assert.ok(!text.includes(B2_GENERATED_VALUE), `${label}: generated secret leaked`);
  assert.ok(!text.includes(B2_PENDING_ID), `${label}: pending id leaked`);
}

function optionRow(page) {
  // Shadow rows only: the A040 light fallback options are role=option too,
  // but carry GENERIC labels and are scanned separately below.
  const row = page
    .allElements()
    .find(
      (el) =>
        el.getAttribute("role") === "option" && el.id.startsWith("kv-option-")
    );
  assert.ok(row, "expected a rendered match row");
  return row;
}

// ---------------------------------------------------------------------------

test("A032: the rendered match surface contains neither password nor username", async () => {
  const stack = await fullStack();
  await stack.page.focus(stack.password);

  // The row rendered from the real worker's real metadata answer.
  assert.equal(optionRow(stack.page).textContent, "Exampleexample.com");
  assertNoSecretIn(observableSurfaces(stack), "after metadata render");
});

// A040 — the extended A032 scan: entry TITLES and services (not only
// secrets) must never appear in the LIGHT DOM. The light fallback listbox
// lives in the page tree, so anything written there is page-readable; it may
// carry indices and static labels only. Canaries are distinctive and
// runtime-assembled (GitGuardian).
const A040_TITLE_CANARY = ["a040", "title", "canary"].join("-");
const A040_SERVICE_CANARY = ["a040", "service", "canary"].join("-");

test("A040/A032: entry titles, services, and entry ids never appear in the light DOM", async () => {
  const stack = await fullStack();
  stack.native.items[0].title = A040_TITLE_CANARY;
  stack.native.items[0].displayService = A040_SERVICE_CANARY;
  await stack.page.focus(stack.password);

  // Sanity: the metadata really rendered — inside the shadow.
  assert.equal(
    optionRow(stack.page).textContent,
    `${A040_TITLE_CANARY}${A040_SERVICE_CANARY}`
  );

  // The light DOM (page tree, shadow roots excluded) holds NONE of it: no
  // title, no service, no entry id, no secret — before AND after moving the
  // selection (the sync writes aria-selected/activedescendant, never text).
  for (const pass of ["initial", "after ArrowDown"]) {
    const light = stack.page.captureLightDomState();
    assert.ok(!light.includes(A040_TITLE_CANARY), `${pass}: title in light DOM`);
    assert.ok(!light.includes(A040_SERVICE_CANARY), `${pass}: service in light DOM`);
    assert.ok(!light.includes("entry-1"), `${pass}: entry id in light DOM`);
    assertNoSecretIn(light, `${pass}: light DOM`);
    await stack.page.pressKey("ArrowDown");
  }
});

test("A040 security: a page-synthetic click on a light option yields no fill message and no secret anywhere", async () => {
  // The tester's live exfiltration repro, permanent: page code reaches the
  // light option (it IS page DOM) and dispatches a synthetic click. Without
  // the isTrusted guard this produced a REAL fill message through the REAL
  // dispatcher and the credential landed in the input with zero user
  // gesture. The guard must keep every surface clean.
  const { FakeEvent } = require("./fake_page.js");
  const stack = await fullStack();
  await stack.page.focus(stack.password);
  const lightOption = stack.page
    .allElements()
    .find((el) => el.id === "kv-light-option-0");
  assert.ok(lightOption, "the light option exists — and is page-reachable");

  lightOption.dispatchEvent(
    new FakeEvent("click", { bubbles: true, cancelable: true, composed: true })
  );
  stack.page._propagate(
    lightOption,
    new FakeEvent("keydown", { bubbles: true, cancelable: true, composed: true, key: "Enter" })
  );
  await stack.page.settle();

  assert.equal(stack.page.sentOfType("fill").length, 0, "no fill message may be sent");
  assert.equal(stack.password.value, "", "no secret may reach the input");
  assert.equal(stack.username.value, "");
  assertNoSecretIn(observableSurfaces(stack), "after synthetic activation");
  assert.equal(stack.page.overlayHosts().length, 1, "the session is untouched");
});

test("A032: after an explicit fill the secret exists in the input values and in no other captured surface", async () => {
  const stack = await fullStack();
  await stack.page.focus(stack.password);
  await stack.page.click(optionRow(stack.page));

  // The one allowed, inherent sink (SR-5): the native input values.
  assert.equal(stack.password.value, A032_FILL_VALUE);
  assert.equal(stack.username.value, SECRET_USERNAME);

  // Everything else: DOM/attributes/dataset/style/text of page AND detached
  // shadow trees, content-world globals, console, every content-sent message,
  // worker durable storage, teardown broadcasts.
  assertNoSecretIn(observableSurfaces(stack), "after fill");
  assert.deepEqual(stack.page.consoleLines, [], "nothing may be logged");
  assert.equal(stack.page.submitCount, 0);
});

test("A032: a vault switch between metadata and fill yields stale_session and the secret never appears anywhere", async () => {
  const stack = await fullStack();
  await stack.page.focus(stack.password);
  const row = optionRow(stack.page);

  // Vault B publishes under the same entry UUID and origin (SR-4 regression):
  // the reveal now answers with B's binding, which the router must refuse
  // BEFORE forwarding any secret.
  stack.native.binding = bindingB();
  await stack.page.click(row);

  assert.equal(stack.password.value, "", "no fill may happen across a vault switch");
  assert.equal(stack.username.value, "");
  assertNoSecretIn(observableSurfaces(stack), "after stale vault switch");
  // The content script renders the stale state rather than tearing down.
  const status = stack.page.allElements().find((el) => el.id === "kv-status");
  assert.equal(status.textContent, "Custode session changed.");
});

test("B012: after an explicit generate the secret exists in the password input value and in no other captured surface — pending id nowhere at all", async () => {
  const stack = await fullStack();
  await stack.page.focus(stack.password);
  const generate = stack.page
    .allElements()
    .find((el) => el.id === "kv-generate");
  assert.ok(generate, "generate row missing");
  assert.equal(generate.disabled, false, "capability must activate the row");
  await stack.page.click(generate);

  // The one allowed, inherent sink (SR-5): the password input value.
  assert.equal(stack.password.value, B2_GENERATED_VALUE);
  assert.equal(stack.username.value, "", "generate never touches the username");

  // Everything else: DOM/attributes/dataset/style/text of page AND detached
  // shadow trees (document.title included), content-world globals, console,
  // every content-sent message, worker durable storage, teardown broadcasts.
  // The pending id must appear NOWHERE — not even in the allowed sink.
  assertNoSecretIn(observableSurfaces(stack), "after generate");
  assert.ok(!stack.page.inputValues().join("\n").includes(B2_PENDING_ID));
  assert.deepEqual(stack.page.consoleLines, [], "nothing may be logged");
  assert.equal(stack.page.submitCount, 0, "generate never submits");
  assert.equal(
    stack.page.overlayHosts().length,
    0,
    "the session tears down after the generated fill"
  );
});

test("B012: a replayed generate token at the real dispatcher yields stale_session and no secret", async () => {
  const stack = await fullStack();
  await stack.page.focus(stack.password);
  const generate = stack.page
    .allElements()
    .find((el) => el.id === "kv-generate");
  await stack.page.click(generate);
  assert.equal(stack.password.value, B2_GENERATED_VALUE, "first generate fills");

  const request = stack.page.sentOfType("generate")[0];
  stack.password.value = "";
  // Replay the consumed token straight at the real dispatcher, as a page that
  // captured the message would.
  const replay = await stack.page.respond({
    channel: security.CHANNEL,
    version: security.MESSAGE_VERSION,
    type: "generate",
    origin: ORIGIN,
    focusNonce: request.focusNonce,
    generateToken: request.generateToken,
    sessionBinding: bindingA(),
  });
  assert.equal(replay.ok, false);
  assert.equal(replay.error.code, "stale_session");
  assert.ok(!JSON.stringify(replay).includes(B2_GENERATED_VALUE));
  assert.ok(!JSON.stringify(replay).includes(B2_PENDING_ID));
  assert.equal(stack.password.value, "");
});

test("A032: a replayed fill token yields no secret on any surface", async () => {
  const stack = await fullStack();
  await stack.page.focus(stack.password);
  const firstFillToken = (await (async () => {
    await stack.page.click(optionRow(stack.page));
    return stack.page.sentOfType("fill")[0].fillToken;
  })());
  assert.equal(stack.password.value, A032_FILL_VALUE, "first fill succeeds");

  // Replay the consumed token straight at the real dispatcher, as a page that
  // captured the message would.
  stack.password.value = "";
  const replay = await stack.page.respond({
    channel: security.CHANNEL,
    version: security.MESSAGE_VERSION,
    type: "fill",
    origin: ORIGIN,
    focusNonce: stack.page.sentOfType("fill")[0].focusNonce,
    fillToken: firstFillToken,
    entryId: "entry-1",
    sessionBinding: bindingA(),
  });
  assert.equal(replay.ok, false);
  assert.equal(replay.error.code, "stale_session");
  assert.ok(!JSON.stringify(replay).includes(A032_FILL_VALUE));
  assert.equal(stack.password.value, "");
});
