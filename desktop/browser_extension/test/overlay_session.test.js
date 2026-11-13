// 009 Slice A4 — behavioural tests for the overlay session engine in
// `content_overlay.js` (A028 field detection, A029 metadata-only DOM,
// A030 states, A031 explicit fill, A033 teardown matrix, A034 shadow honesty).
//
// Everything drives the SHIPPED file through `test/fake_page.js`, which
// evaluates it in a fresh isolated-world global with a real-behaving DOM:
// mousedown moves focus unless prevented, focusout precedes focusin, closed
// shadow roots read null from page code, and every message crossing the
// runtime boundary is structured-cloned into the receiving realm.
//
// The worker in these tests is a canned responder shaped exactly like the
// production `matchesResult`/`fillResult` messages — the shipped
// `validateMatchesResult` runs INSIDE the content script against them, so a
// response the real worker could not have produced is rejected by production
// code, not accepted by a lenient fake. The full end-to-end path through the
// real router lives in `secret_lifetime.test.js`.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { FakeEvent } = require("./fake_page.js");
const security = require("../overlay_security.js");
const { bindingA, bindingB } = require("./helpers.js");
const {
  ORIGIN,
  item,
  matchesResult,
  fillResult,
  errorResult,
  loginPage,
  statusText,
  optionRows,
  overlayCount,
} = require("./session_helpers.js");

const GENERATE_TEXT = "Open Custode to generate a password.";

// Fill values are assembled at runtime so no source literal ever forms a
// credential-shaped assignment (GitGuardian scans every commit; on a password
// manager we change the string, never allowlist the finding).
const FILL_VALUE_A = ["canary", "alpha"].join("-");
const FILL_VALUE_B = ["canary", "beta"].join("-");
const FILL_VALUE_C = ["canary", "both"].join("-");

// ---------------------------------------------------------------------------
// A028 — eligible field detection and the focus session.
// ---------------------------------------------------------------------------

test("A028: focusing a writable password input starts a session and queries matches", async () => {
  const { page, password } = await loginPage();
  await page.focus(password);

  const sent = page.sentOfType("requestMatches");
  assert.equal(sent.length, 1);
  assert.equal(sent[0].origin, ORIGIN);
  assert.equal(sent[0].fieldKind, "password");
  assert.equal(typeof sent[0].focusNonce, "string");
  assert.ok(sent[0].focusNonce.length > 0);
  assert.ok(sent[0].focusNonce.length <= security.LIMITS.TOKEN);
  assert.equal(overlayCount(page), 1);
});

test("A028: a username field is eligible only with an associated password field", async () => {
  const withPassword = await loginPage();
  await withPassword.page.focus(withPassword.username);
  assert.equal(withPassword.page.sentOfType("requestMatches").length, 1);
  assert.equal(
    withPassword.page.sentOfType("requestMatches")[0].fieldKind,
    "username"
  );

  // Same field, but the form has no password input: not a credential form.
  const lone = await loginPage();
  lone.password.remove();
  await lone.page.focus(lone.username);
  assert.equal(lone.page.sentOfType("requestMatches").length, 0);
  assert.equal(overlayCount(lone.page), 0);
});

test("A028: disabled, read-only, hidden, and autocomplete-less fields are not eligible", async () => {
  for (const prepare of [
    ({ password }) => {
      password.disabled = true;
    },
    ({ password }) => {
      password.readOnly = true;
    },
    ({ password }) => {
      password.setAttribute("hidden", "");
    },
    ({ form }) => {
      form.style.display = "none"; // hidden ancestor: no client rects
    },
  ]) {
    const ctx = await loginPage();
    prepare(ctx);
    // Direct focusin dispatch: a disabled input cannot receive real focus,
    // but a hostile page can synthesize the event — it must still be refused.
    ctx.page._propagate(ctx.password, new FakeEvent("focusin", { bubbles: true }));
    await ctx.page.settle();
    assert.equal(ctx.page.sentOfType("requestMatches").length, 0);
    assert.equal(overlayCount(ctx.page), 0);
  }

  // Username-shaped input without username/email autocomplete: not eligible.
  const ctx = await loginPage();
  ctx.username.setAttribute("autocomplete", "off");
  await ctx.page.focus(ctx.username);
  assert.equal(ctx.page.sentOfType("requestMatches").length, 0);
});

test("A028: a new eligible focus tears down the old session and mints a fresh nonce", async () => {
  const { page, password, username } = await loginPage();
  await page.focus(password);
  assert.equal(overlayCount(page), 1);

  await page.focus(username);
  const sent = page.sentOfType("requestMatches");
  assert.equal(sent.length, 2);
  assert.notEqual(sent[0].focusNonce, sent[1].focusNonce, "nonce must be per focus session");
  assert.equal(overlayCount(page), 1, "old overlay torn down, one new session");
});

// ---------------------------------------------------------------------------
// A029 — metadata-only closed-shadow overlay.
// ---------------------------------------------------------------------------

test("A029: rows expose title and display service only; the entry id never enters the DOM", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, {
      items: [
        item({ entryId: "entry-handle-1", title: "Example", displayService: "example.com" }),
        item({
          entryId: "entry-handle-2",
          title: "Example legacy",
          displayService: "legacy.example.com",
          matchType: "possible",
          fillEligible: false,
        }),
      ],
    });
  await page.focus(password);

  const rows = optionRows(page);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].textContent, "Exampleexample.com");
  assert.equal(rows[1].textContent, "Example legacylegacy.example.com");

  const observable = page.captureObservableState();
  assert.ok(!observable.includes("entry-handle-1"), "entry id leaked into the DOM");
  assert.ok(!observable.includes("entry-handle-2"), "entry id leaked into the DOM");
});

test("A029: the overlay renders only after a successful matches response for the current nonce", async () => {
  const { page, password, username, handlers } = await loginPage();
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  let firstRequest = null;
  handlers.matches = async (message) => {
    if (firstRequest === null) {
      firstRequest = message;
      await gate;
      return matchesResult(message); // stale by the time it arrives
    }
    return matchesResult(message, { items: [item({ title: "Second" })] });
  };

  password.focus(); // first session; its response is gated
  username.focus(); // second session replaces it (no settle in between)
  release();
  await page.settle();

  // The stale first response must not have rendered anything: the single
  // live overlay shows the SECOND session's items.
  assert.equal(overlayCount(page), 1);
  const rows = optionRows(page);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].textContent, "Secondexample.com");
});

// ---------------------------------------------------------------------------
// A030 — states.
// ---------------------------------------------------------------------------

test("A030: the loading state shows while the query is in flight", async () => {
  const { page, password, handlers } = await loginPage();
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  handlers.matches = async (message) => {
    await gate;
    return matchesResult(message);
  };

  password.focus(); // no settle: the response is still pending
  // M13 — the live region is created EMPTY at mount; the text lands one
  // macrotask later so VoiceOver registers the region before its first
  // content mutation (see setStatusText in content_overlay.js).
  assert.equal(statusText(page), "", "region must exist empty at mount");
  page.flushTimers();
  assert.equal(statusText(page), "Loading Custode suggestions…");
  release();
  await page.settle();
  assert.equal(statusText(page), "1 Custode suggestions");
});

test("M13: the live region exists empty at mount and its announcement timer dies with the session", async () => {
  const { page, password } = await loginPage();

  password.focus(); // synchronous: nothing has been drained yet
  const status = page.allElements().find((el) => el.id === "kv-status");
  assert.ok(status, "role=status region must exist immediately at mount");
  assert.equal(status.getAttribute("role"), "status");
  assert.equal(status.getAttribute("aria-live"), "polite");
  assert.equal(status.textContent, "", "region must be created EMPTY");
  assert.ok(page._timeouts.size > 0, "the announcement must be scheduled");

  // Teardown before the tick: Escape kills the session; the pending
  // announcement timer must be cancelled with it (no write into a dead
  // region, no stray timer left behind).
  await page.pressKey("Escape");
  assert.equal(page._timeouts.size, 0, "teardown must cancel the timer");
  assert.equal(status.textContent, "", "no announcement after teardown");
});

test("A030: every terminal state renders its honest text", async () => {
  const cases = [
    [
      (message) => matchesResult(message, { items: [] }),
      "No Custode entries for this site.",
    ],
    [
      (message) =>
        matchesResult(message, {
          items: [item({ matchType: "possible", fillEligible: false })],
        }),
      "Matches exist but cannot be filled here. Open Custode.",
    ],
    [(m) => errorResult("matchesResult", "locked", m), "Open and unlock Custode."],
    [(m) => errorResult("matchesResult", "no_host", m), "Custode native host is unavailable."],
    [(m) => errorResult("matchesResult", "timeout", m), "Custode did not respond in time."],
    [
      (m) => errorResult("matchesResult", "unsupported_frame", m),
      "The overlay is not available in this frame. Copy your login from the Custode app.",
    ],
    [
      (m) => errorResult("matchesResult", "unsupported_capability", m),
      // Neutral: an old native host or an old app both land here.
      "Update Custode to use this feature.",
    ],
    [(m) => errorResult("matchesResult", "stale_session", m), "Custode session changed."],
  ];
  for (const [matches, expected] of cases) {
    const { page, password, handlers } = await loginPage();
    handlers.matches = matches;
    await page.focus(password);
    assert.equal(statusText(page), expected, expected);
    assert.equal(overlayCount(page), 1, expected);
  }
});

test("A030: an authorization failure tears down instead of rendering a state", async () => {
  for (const code of ["disabled", "forbidden", "invalid_request", "internal_error"]) {
    const { page, password, handlers } = await loginPage();
    handlers.matches = (m) => errorResult("matchesResult", code, m);
    await page.focus(password);
    assert.equal(overlayCount(page), 0, code);
  }
});

test("A030: the stale state offers retry, which re-queries the same focus session", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (m) => errorResult("matchesResult", "stale_session", m);
  await page.focus(password);

  const retry = page.allElements().find((el) => el.id === "kv-retry");
  assert.ok(retry, "stale state must offer a retry control");
  assert.equal(retry.getAttribute("type"), "button");

  handlers.matches = (message) => matchesResult(message);
  await page.click(retry);

  const sent = page.sentOfType("requestMatches");
  assert.equal(sent.length, 2);
  assert.equal(sent[0].focusNonce, sent[1].focusNonce, "retry keeps the focus session");
  assert.equal(statusText(page), "1 Custode suggestions");
});

test("A030: Generate is present, disabled, and honest in every rendered state", async () => {
  const variants = [
    (message) => matchesResult(message),
    (message) => matchesResult(message, { items: [] }),
    (m) => errorResult("matchesResult", "locked", m),
  ];
  for (const matches of variants) {
    const { page, password, handlers } = await loginPage();
    handlers.matches = matches;
    await page.focus(password);
    const generate = page.allElements().find((el) => el.id === "kv-generate");
    assert.ok(generate, "generate control missing");
    assert.equal(generate.disabled, true);
    assert.equal(generate.getAttribute("type"), "button");
    assert.equal(generate.textContent, GENERATE_TEXT);

    // Clicking it must do nothing: no message of any kind leaves.
    const sentBefore = page.sent.length;
    await page.click(generate);
    assert.equal(page.sent.length, sentBefore);
  }
});

test("A030: a malformed matches success is refused by the shipped validator and tears down", async () => {
  const { page, password, handlers } = await loginPage();
  // A worker bug (or forged response) that smuggles a username into an item.
  handlers.matches = (message) => {
    const result = matchesResult(message);
    result.items[0].username = "alice";
    return result;
  };
  await page.focus(password);
  assert.equal(overlayCount(page), 0);
  assert.ok(!page.captureObservableState().includes("alice"));
});

// ---------------------------------------------------------------------------
// A031 — explicit fill.
// ---------------------------------------------------------------------------

test("A031: clicking an eligible row fills both fields, dispatches bubbling input/change, never submits", async () => {
  const { page, form, password, username, handlers } = await loginPage();
  handlers.fill = (message) =>
    fillResult(message, { username: "alice", password: FILL_VALUE_B });
  await page.focus(password);

  const observedOnForm = [];
  form.addEventListener("input", (event) => observedOnForm.push(["input", event.target]));
  form.addEventListener("change", (event) => observedOnForm.push(["change", event.target]));

  const row = optionRows(page)[0];
  await page.click(row);

  // The fill request carried the token, entry, and binding of this session.
  const fills = page.sentOfType("fill");
  assert.equal(fills.length, 1);
  assert.equal(fills[0].fillToken, "token-1");
  assert.equal(fills[0].entryId, "entry-1");
  assert.deepEqual(fills[0].sessionBinding, bindingA());

  assert.equal(password.value, FILL_VALUE_B);
  assert.equal(username.value, "alice");
  // Bubbling input+change reached the page's own form listener for BOTH fields.
  assert.deepEqual(
    observedOnForm.map(([type, target]) => [type, target === password ? "pw" : "user"]),
    [
      ["input", "user"],
      ["change", "user"],
      ["input", "pw"],
      ["change", "pw"],
    ]
  );
  assert.equal(page.submitCount, 0, "the overlay must never submit");
  assert.equal(overlayCount(page), 0, "fill ends with teardown");
});

test("A031: the overlay click survives the click-vs-blur hazard because mousedown is prevented", async () => {
  // `page.click` models the REAL default action: mousedown moves focus unless
  // prevented. If the overlay did not prevent it, the anchor would blur, the
  // session would tear down, and the click would hit a removed row.
  const { page, password } = await loginPage();
  await page.focus(password);
  const row = optionRows(page)[0];
  await page.click(row);
  assert.equal(password.value, FILL_VALUE_A, "fill must survive the pointer press");
});

test("A031: a non-eligible row cannot request a fill", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) =>
    matchesResult(message, {
      items: [item({ matchType: "possible", fillEligible: false })],
      fillToken: null,
    });
  await page.focus(password);
  const row = optionRows(page)[0];
  await page.click(row);
  assert.equal(page.sentOfType("fill").length, 0);
  assert.equal(password.value, "");
});

test("A031: the fill token is one-shot on the content side too", async () => {
  const { page, password, handlers } = await loginPage();
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  handlers.fill = async (message) => {
    await gate;
    return fillResult(message);
  };
  await page.focus(password);
  const row = optionRows(page)[0];

  // Two clicks before any response: only one fill request may leave.
  const first = page.click(row);
  const second = page.click(row);
  release();
  await first;
  await second;
  assert.equal(page.sentOfType("fill").length, 1);
});

test("A031: a fill response with a foreign session binding is refused without filling", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.fill = (message) => fillResult(message, { sessionBinding: bindingB() });
  await page.focus(password);
  await page.click(optionRows(page)[0]);

  assert.equal(password.value, "");
  assert.equal(overlayCount(page), 0, "binding mismatch fails closed");
});

test("A031: a fill response for the wrong entry or origin is refused without filling", async () => {
  for (const overrides of [{ entryId: "entry-2" }, { origin: "https://other.example" }]) {
    const { page, password, handlers } = await loginPage();
    handlers.fill = (message) => ({ ...fillResult(message), ...overrides });
    await page.focus(password);
    await page.click(optionRows(page)[0]);
    assert.equal(password.value, "", JSON.stringify(overrides));
  }
});

test("A031: a fill response landing after the anchor lost focus does not fill", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.fill = (message) => {
    // While the reveal is in flight, the page moves focus elsewhere.
    page._moveFocus(page.document.body);
    return fillResult(message);
  };
  await page.focus(password);
  await page.click(optionRows(page)[0]);
  assert.equal(password.value, "");
});

test("A031: a fill response landing after Escape cannot fill (stale nonce)", async () => {
  const { page, password, handlers } = await loginPage();
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  handlers.fill = async (message) => {
    await gate;
    return fillResult(message);
  };
  await page.focus(password);
  const clicking = page.click(optionRows(page)[0]);
  await page.pressKey("Escape"); // teardown while the reveal is in flight
  release();
  await clicking;
  assert.equal(password.value, "");
  assert.equal(overlayCount(page), 0);
});

test("A031: a fill response from a previous focus session cannot fill the new one", async () => {
  // The dangerous variant of staleness: a NEW session exists when the old
  // response lands, so a "session is not null" guard is not enough — only the
  // per-focus nonce distinguishes the two.
  const { page, password, username, handlers } = await loginPage();
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  handlers.fill = async (message) => {
    await gate;
    return fillResult(message);
  };
  await page.focus(password);
  const clicking = page.click(optionRows(page)[0]); // fill in flight, gated
  username.focus(); // replaces the session; same entry ids, same binding
  release();
  await clicking;
  await page.settle();

  assert.equal(password.value, "", "a stale-nonce fill response must be ignored");
  assert.equal(username.value, "");
  assert.equal(overlayCount(page), 1, "the new session stays untouched");
});

test("A031: a renderable fill error keeps the session and shows the state", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.fill = (m) => errorResult("fillResult", "stale_session", m);
  await page.focus(password);
  await page.click(optionRows(page)[0]);
  assert.equal(password.value, "");
  assert.equal(overlayCount(page), 1);
  assert.equal(statusText(page), "Custode session changed.");
});

test("A031: focusing the username fills the associated password field as well", async () => {
  const { page, password, username, handlers } = await loginPage();
  handlers.fill = (message) =>
    fillResult(message, { username: "alice", password: FILL_VALUE_C });
  await page.focus(username);
  await page.click(optionRows(page)[0]);
  assert.equal(username.value, "alice");
  assert.equal(password.value, FILL_VALUE_C);
});

// ---------------------------------------------------------------------------
// A033 — teardown matrix.
// ---------------------------------------------------------------------------

async function openSession() {
  const ctx = await loginPage();
  ctx.password.setAttribute("aria-expanded", "false"); // pre-existing ARIA
  await ctx.page.focus(ctx.password);
  assert.equal(overlayCount(ctx.page), 1);
  assert.equal(ctx.password.getAttribute("aria-expanded"), "true");
  return ctx;
}

function assertTornDown({ page, password }, label) {
  assert.equal(overlayCount(page), 0, `${label}: host still attached`);
  assert.equal(
    password.getAttribute("aria-expanded"),
    "false",
    `${label}: anchor ARIA not restored`
  );
  assert.equal(page._intervals.size, 0, `${label}: watchdog timer still running`);
}

test("A033: Escape tears the session down and restores the anchor ARIA", async () => {
  const ctx = await openSession();
  await ctx.page.pressKey("Escape");
  assertTornDown(ctx, "escape");
});

test("A033: an outside pointer press blurs the anchor and tears down", async () => {
  const ctx = await openSession();
  await ctx.page.click(ctx.page.document.body);
  assertTornDown(ctx, "outside blur");
});

test("A033: pagehide tears down", async () => {
  const ctx = await openSession();
  await ctx.page.firePagehide();
  assertTornDown(ctx, "pagehide");
});

test("A033: hiding the document tears down", async () => {
  const ctx = await openSession();
  await ctx.page.setVisibility("hidden");
  assertTornDown(ctx, "visibility");
});

test("A033: anchor disconnection is detected by the watchdog", async () => {
  const ctx = await openSession();
  ctx.form.remove();
  await ctx.page.tick();
  assert.equal(overlayCount(ctx.page), 0);
  assert.equal(ctx.page._intervals.size, 0);
});

test("A033: the session times out at the token TTL ceiling", async () => {
  const ctx = await openSession();
  ctx.page.advanceTime(security.LIMITS.TOKEN_TTL_MS + 1);
  await ctx.page.tick();
  assertTornDown(ctx, "timeout");
});

test("A033: a teardown broadcast drops the session even when the origin stays authorized", async () => {
  const ctx = await openSession();
  // Revalidation still approves — the LISTENER survives, the SESSION must not:
  // rendering may never outlive the revision that authorized it.
  await ctx.page.deliver({
    channel: security.CHANNEL,
    version: security.MESSAGE_VERSION,
    type: "teardown",
    revision: 4,
  });
  assertTornDown(ctx, "broadcast");
  assert.equal(ctx.page.listenerCount, 1, "still authorized: listener stays");
});

test("A033: disable tears down the session, the listeners, and releases the guard", async () => {
  const ctx = await openSession();
  ctx.page.respond = async (message) => {
    if (message.type === "bootstrap") return { ok: false, error: { code: "disabled" } };
    throw new Error(`unexpected ${message.type}`);
  };
  await ctx.page.deliver({
    channel: security.CHANNEL,
    version: security.MESSAGE_VERSION,
    type: "teardown",
    revision: 5,
  });
  assertTornDown(ctx, "disable");
  assert.equal(ctx.page.listenerCount, 0);
  assert.equal(ctx.page.guarded, false);

  // The instance is fully inert: an eligible focus neither speaks to the
  // worker nor renders. (The anchor still holds focus from before, so a
  // DIFFERENT eligible field is focused — a same-element focus would fire no
  // focusin at all and prove nothing about the listeners.)
  const sentBefore = ctx.page.sentOfType("requestMatches").length;
  await ctx.page.focus(ctx.username);
  assert.equal(ctx.page.sentOfType("requestMatches").length, sentBefore);
  assert.equal(overlayCount(ctx.page), 0);
});

test("A033: a dead worker during the matches query tears down", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = async () => {
    throw new Error("Extension context invalidated.");
  };
  await page.focus(password);
  assert.equal(overlayCount(page), 0);
});

// ---------------------------------------------------------------------------
// A034 — Shadow DOM honesty.
// ---------------------------------------------------------------------------

test("A034: the shadow root is closed — null for page code — and that is ALL it guarantees", async () => {
  const { page, form, password } = await loginPage();
  await page.focus(password);

  const host = page.overlayHosts()[0];
  // Style/collision isolation evidence: page code cannot reach the internals.
  assert.equal(host.shadowRoot, null);

  // And the honest other half: the page still observes the host's existence,
  // its removal, the filled value, and the dispatched events. Closed mode is
  // NOT invisibility and these assertions pin that no test claims otherwise.
  assert.equal(host.isConnected, true);
  assert.equal(host.parentNode, page.document.body);

  const seenByPage = [];
  form.addEventListener("input", (event) => seenByPage.push(event.type));
  await page.click(optionRows(page)[0]);

  assert.equal(password.value, FILL_VALUE_A, "the page can read the filled value");
  assert.ok(seenByPage.includes("input"), "the page observes dispatched events");
  assert.equal(host.isConnected, false, "the page observes the host's removal");
});
