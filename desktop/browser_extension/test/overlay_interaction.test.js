// 009 Slice A5 — behavioural tests for the interaction surface of
// `content_overlay.js`: the frame-policy display states (A035), the
// listbox/combobox ARIA contract (A036), the keyboard contract (A037), and
// the click-vs-blur pending-action protocol (A038).
//
// Everything drives the SHIPPED file through `test/fake_page.js`, whose event
// model is composed-and-retargeting like Chrome's: UA-style events cross the
// closed shadow boundary up to the document, retargeted to the host. That is
// what makes "a closed overlay captures no page keys" FALSIFIABLE — a page
// listener at the document really does receive every keydown unless the
// overlay actively swallows it.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { FakeEvent } = require("./fake_page.js");
const security = require("../overlay_security.js");
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
} = require("./session_helpers.js");

// Runtime-assembled fill canaries: no credential-shaped source literal, ever
// (GitGuardian; see overlay_session.test.js).
const FILL_VALUE_K = ["canary", "keyboard"].join("-");
const FILL_VALUE_P = ["canary", "pointer"].join("-");

const UNSUPPORTED_TEXT =
  "The overlay is not available in this frame. Copy your login from the Custode app.";

async function pageWithRows(count = 2) {
  const ctx = await loginPage();
  ctx.handlers.matches = (m) =>
    matchesResult(m, {
      items: Array.from({ length: count }, (_, index) =>
        item({ entryId: `entry-${index + 1}`, title: `Row${index + 1}` })
      ),
    });
  await ctx.page.focus(ctx.password);
  assert.equal(optionRows(ctx.page).length, count);
  return ctx;
}

function addSubmitControl(page, form) {
  const submit = page.document.createElement("button");
  submit.setAttribute("type", "submit");
  form.appendChild(submit);
}

// ---------------------------------------------------------------------------
// A035 — frame policy surface in a SUPPORTED document: the detectable
// cross-origin iframe hint. (The unsupported-frame instance itself is covered
// in content_overlay.test.js; the worker-side gate in overlay_routes.test.js.)
// ---------------------------------------------------------------------------

test("A035: focusing a cross-origin iframe shows the manual-copy hint and sends nothing", async () => {
  const { page } = await loginPage();
  const iframe = page.document.createElement("iframe");
  iframe.setAttribute("src", "https://other.example/embedded-login");
  page.document.body.appendChild(iframe);

  await page.focus(iframe);

  assert.equal(overlayCount(page), 1, "the hint state must render");
  assert.equal(statusText(page), UNSUPPORTED_TEXT);
  // Fail closed: the hint is display-only. No metadata query, no fill, and
  // no clipboard API exists anywhere in the extension.
  assert.equal(page.sentOfType("requestMatches").length, 0);
  assert.equal(page.sentOfType("fill").length, 0);
  // An iframe is not a combobox: its ARIA is never touched.
  assert.equal(iframe.getAttribute("aria-expanded"), null);

  // Focus moving back into the page tears the hint down like any session.
  await page.click(page.document.body);
  assert.equal(overlayCount(page), 0);
});

test("A035: a same-origin iframe gets NO hint — its own injected instance owns it", async () => {
  // Absolute AND relative srcs: the browser resolves a relative src against
  // the document URL, and so must the hint check — a raw-attribute compare
  // would misread "/widget" as foreign and paint the hint over a frame that
  // already carries its own real overlay (tester finding, Slice A5).
  for (const src of [
    "https://example.com/widget",
    "/widget",
    "widget.html",
    "../nested/widget.html",
    "//example.com/widget",
  ]) {
    const { page } = await loginPage();
    const iframe = page.document.createElement("iframe");
    iframe.setAttribute("src", src);
    page.document.body.appendChild(iframe);

    await page.focus(iframe);

    assert.equal(overlayCount(page), 0, `src=${JSON.stringify(src)} must get no hint`);
    assert.equal(page.sentOfType("requestMatches").length, 0);
  }
});

test("A035: a protocol-relative cross-origin src still gets the hint", async () => {
  // Regression for the resolver: "//other.example/x" resolves to ANOTHER
  // origin under this document's scheme and must keep the hint.
  const { page } = await loginPage();
  const iframe = page.document.createElement("iframe");
  iframe.setAttribute("src", "//other.example/embedded-login");
  page.document.body.appendChild(iframe);

  await page.focus(iframe);

  assert.equal(overlayCount(page), 1);
  assert.equal(statusText(page), UNSUPPORTED_TEXT);
  assert.equal(page.sentOfType("requestMatches").length, 0);
});

test("A035: sandboxed/opaque iframe sources are hint targets, not fill targets", async () => {
  for (const src of ["about:srcdoc", "data:text/html,<p>x", ""]) {
    const { page } = await loginPage();
    const iframe = page.document.createElement("iframe");
    if (src !== "") iframe.setAttribute("src", src);
    page.document.body.appendChild(iframe);
    await page.focus(iframe);
    assert.equal(overlayCount(page), 1, `src=${JSON.stringify(src)}`);
    assert.equal(statusText(page), UNSUPPORTED_TEXT);
    assert.equal(page.sentOfType("requestMatches").length, 0);
  }
});

// ---------------------------------------------------------------------------
// M7 — the hint mechanism itself: window blur + activeElement, NEVER focusin
// (the parent document receives no focusin for a child browsing context; the
// fake models the real Chrome behaviour, measured live).
// ---------------------------------------------------------------------------

test("M7: no focusin ever fires for an iframe — a document focusin listener stays silent", async () => {
  const { page } = await loginPage();
  const iframe = page.document.createElement("iframe");
  iframe.setAttribute("src", "https://other.example/embedded-login");
  page.document.body.appendChild(iframe);
  const focusinTargets = [];
  page.document.addEventListener("focusin", (event) => {
    focusinTargets.push(event.target);
  });

  await page.focus(iframe);

  assert.equal(focusinTargets.length, 0, "the parent must receive no focusin");
  // The hint rendered anyway — via window blur + activeElement.
  assert.equal(overlayCount(page), 1);
  assert.equal(statusText(page), UNSUPPORTED_TEXT);
});

test("M7: focus moving from an open fill session into a cross-origin iframe swaps to the hint", async () => {
  const { page, password } = await loginPage();
  const iframe = page.document.createElement("iframe");
  iframe.setAttribute("src", "https://other.example/embedded-login");
  page.document.body.appendChild(iframe);

  await page.focus(password);
  assert.equal(overlayCount(page), 1, "fill session must be open");
  assert.notEqual(statusText(page), UNSUPPORTED_TEXT);

  await page.focus(iframe);
  assert.equal(overlayCount(page), 1, "exactly one overlay: the hint");
  assert.equal(statusText(page), UNSUPPORTED_TEXT);
  // The fill session's combobox ARIA was restored on its teardown.
  assert.equal(password.getAttribute("aria-expanded"), null);
});

test("M7: a window blur with no iframe active (app/tab switch) changes nothing", async () => {
  const { page, password } = await loginPage();
  await page.focus(password);
  assert.equal(overlayCount(page), 1);

  // The whole browser window loses focus; activeElement is still the input.
  page.window._invoke(new FakeEvent("blur", { bubbles: false }));
  await page.settle();

  assert.equal(overlayCount(page), 1, "the session must survive an app switch");
  assert.notEqual(statusText(page), UNSUPPORTED_TEXT);
});

test("M7: the one-shot post-blur poll catches an activeElement that settles late", async () => {
  const { page } = await loginPage();
  const iframe = page.document.createElement("iframe");
  iframe.setAttribute("src", "https://other.example/embedded-login");
  page.document.body.appendChild(iframe);

  // Model an engine where the blur dispatch happens BEFORE activeElement
  // reads the iframe: blur first, activeElement flips after.
  page.window._invoke(new FakeEvent("blur", { bubbles: false }));
  assert.equal(overlayCount(page), 0, "synchronous check must find nothing yet");
  page.document.activeElement = iframe;
  await page.settle(); // drains the one-shot poll

  assert.equal(overlayCount(page), 1, "the deferred re-check must show the hint");
  assert.equal(statusText(page), UNSUPPORTED_TEXT);
  assert.equal(page.sentOfType("requestMatches").length, 0);
});

// ---------------------------------------------------------------------------
// M7 — iframe → iframe. The top window blurs on the way INTO a child browsing
// context and is already blurred once focus is in one, so moving straight from
// iframe A to iframe B fires NO second window blur. A hint that only ever
// re-derives on window blur therefore stays glued to A. Cosmetic, but wrong to
// show — and the fake used to hide it by emitting the second blur anyway.
// ---------------------------------------------------------------------------

/** Two cross-origin iframes at different x offsets, so the hint's anchor is
 *  observable through the overlay host's fixed position. */
async function twoForeignFrames() {
  const ctx = await loginPage();
  const make = (src, left) => {
    const el = ctx.page.document.createElement("iframe");
    el.setAttribute("src", src);
    el._rect = {
      x: left, y: 100, top: 100, bottom: 140,
      left, right: left + 300, width: 300, height: 40,
    };
    ctx.page.document.body.appendChild(el);
    return el;
  };
  return {
    ...ctx,
    frameA: make("https://a.example/login", 10),
    frameB: make("https://b.example/login", 500),
  };
}

const hintLeft = (page) => page.overlayHosts()[0]?.style?.left;

test("M7 FIDELITY: focus moving between two child frames fires no second window blur", async () => {
  // The premise of the bug. If this ever stops holding, the re-check below is
  // dead weight — and the test that proves the re-check works would be
  // passing for the wrong reason.
  const { page, frameA, frameB } = await twoForeignFrames();
  let blurs = 0;
  page.window.addEventListener("blur", () => {
    blurs += 1;
  });

  await page.focus(frameA);
  assert.equal(blurs, 1, "entering the first child frame blurs the top window");
  await page.focus(frameB);
  assert.equal(blurs, 1, "the top window has no focus left to lose");
});

test("M7: focus moving straight from one cross-origin iframe to another re-anchors the hint", async () => {
  const { page, frameA, frameB } = await twoForeignFrames();

  await page.focus(frameA);
  assert.equal(overlayCount(page), 1);
  assert.equal(hintLeft(page), "10px", "the hint is anchored to frame A");

  await page.focus(frameB);

  assert.equal(overlayCount(page), 1, "exactly one hint, never two");
  assert.equal(statusText(page), UNSUPPORTED_TEXT);
  assert.equal(hintLeft(page), "500px", "the hint must follow focus to frame B");
  // A035 is unchanged by the re-anchor: still display-only.
  assert.equal(page.sentOfType("requestMatches").length, 0);
  assert.equal(page.sentOfType("fill").length, 0);
  assert.equal(frameB.getAttribute("aria-expanded"), null);
});

test("M7: the re-anchored hint discloses nothing about either child origin", async () => {
  // SECURITY: the parent cannot know a cross-origin child's origin and must
  // never look like it does. The rendered surface is the frozen state string
  // and nothing else — before and after the re-anchor.
  const { page, frameA, frameB } = await twoForeignFrames();

  await page.focus(frameA);
  await page.focus(frameB);

  // Scoped to what the EXTENSION rendered. The page's own iframes carry their
  // `src` in the page tree — that is the page's data, not a disclosure, so a
  // whole-document scan would be vacuously red.
  const host = page.overlayHosts()[0];
  const rendered = [];
  const walk = (node) => {
    for (const child of node.childNodes ?? []) {
      rendered.push(child.tagName ?? "", child.id ?? "", child._text ?? "");
      for (const [name, value] of child._attributes ?? []) rendered.push(name, value);
      if (child._shadow) walk(child._shadow);
      walk(child);
    }
  };
  for (const [name, value] of host._attributes) rendered.push(name, value);
  walk(host._shadow);

  const surface = rendered.join("\n");
  assert.equal(statusText(page), UNSUPPORTED_TEXT);
  assert.ok(!surface.includes("a.example"), "frame A's origin must not leak");
  assert.ok(!surface.includes("b.example"), "frame B's origin must not leak");
  assert.ok(!surface.includes("https://"), "no URL of any kind is rendered");
});

test("M7: a same-origin second iframe drops the hint instead of re-anchoring", async () => {
  // Frame B carries its own injected instance; painting the parent's hint over
  // it would double up. Failing "closed" here means removing the hint.
  const { page, frameA } = await twoForeignFrames();
  const sameOrigin = page.document.createElement("iframe");
  sameOrigin.setAttribute("src", "/widget");
  page.document.body.appendChild(sameOrigin);

  await page.focus(frameA);
  assert.equal(overlayCount(page), 1);

  await page.focus(sameOrigin);

  assert.equal(overlayCount(page), 0, "no hint may survive on a same-origin frame");
});

test("M7: focus returning from a second iframe to the top document tears the hint down", async () => {
  const { page, frameA, frameB, password } = await twoForeignFrames();

  await page.focus(frameA);
  await page.focus(frameB);
  assert.equal(overlayCount(page), 1);

  await page.focus(password);

  // The hint is gone; what is open now is a normal fill session on the input.
  assert.equal(statusText(page) !== UNSUPPORTED_TEXT, true);
  assert.equal(overlayCount(page), 1, "exactly one overlay: the fill session");
  assert.equal(password.getAttribute("aria-expanded"), "true");
});

test("M7: the re-check is event-independent — a silent activeElement swap still re-anchors", async () => {
  // The load-bearing property. Whether the engine reports focusout on the
  // outgoing iframe element is detail we refuse to depend on, so the re-check
  // is driven by state: model an engine that fires NOTHING at all.
  const { page, frameA, frameB } = await twoForeignFrames();
  await page.focus(frameA);
  assert.equal(hintLeft(page), "10px");

  page.document.activeElement = frameB; // no focusout, no blur, no focusin
  await page.tick(); // one watchdog interval

  assert.equal(overlayCount(page), 1);
  assert.equal(hintLeft(page), "500px", "the watchdog must re-anchor to frame B");
  assert.equal(page.sentOfType("requestMatches").length, 0);
});

test("M7: a silent swap to a non-frame active element removes the hint", async () => {
  const { page, frameA } = await twoForeignFrames();
  await page.focus(frameA);
  assert.equal(overlayCount(page), 1);

  page.document.activeElement = page.document.body;
  await page.tick();

  assert.equal(overlayCount(page), 0);
});

test("M7: the hint re-check adds no timer that outlives the session", async () => {
  const { page, frameA, frameB } = await twoForeignFrames();
  const idle = page.timerCounts;

  await page.focus(frameA);
  await page.focus(frameB);
  assert.equal(overlayCount(page), 1, "a hint must be open for this to mean anything");

  await page.firePagehide(); // teardown through a non-focus path

  assert.equal(overlayCount(page), 0);
  assert.deepEqual(
    page.timerCounts,
    idle,
    "every timer the hint created must die with it"
  );
});

// ---------------------------------------------------------------------------
// A037 — keyboard.
// ---------------------------------------------------------------------------

test("A037: arrows move the selection, clamp at both ends, and are never swallowed", async () => {
  const { page } = await pageWithRows(3);
  const selected = () =>
    optionRows(page).findIndex((row) => row.getAttribute("aria-selected") === "true");

  assert.equal(selected(), 0);
  let event = await page.pressKey("ArrowDown");
  assert.equal(selected(), 1);
  assert.equal(event.defaultPrevented, false, "arrows pass through");
  await page.pressKey("ArrowDown");
  assert.equal(selected(), 2);
  await page.pressKey("ArrowDown");
  assert.equal(selected(), 2, "clamped at the last row");
  await page.pressKey("ArrowUp");
  await page.pressKey("ArrowUp");
  event = await page.pressKey("ArrowUp");
  assert.equal(selected(), 0, "clamped at the first row");
  assert.equal(event.defaultPrevented, false);
  assert.equal(listboxEl(page).getAttribute("aria-activedescendant"), "kv-option-0");
});

test("A037: Enter fills the CURRENT row and consumes only that keystroke", async () => {
  const { page, password: pwInput, handlers } = await pageWithRows(2);
  const fills = [];
  handlers.fill = (m) => {
    fills.push(m.entryId);
    return fillResult(m, { password: FILL_VALUE_K });
  };
  const pageSawKeys = [];
  page.document.addEventListener("keydown", (event) => {
    pageSawKeys.push([event.key, event.defaultPrevented]);
  });

  await page.pressKey("ArrowDown"); // select Row2
  const enter = await page.pressKey("Enter");

  assert.deepEqual(fills, ["entry-2"], "Enter must fill the SELECTED row");
  assert.equal(pwInput.value, FILL_VALUE_K);
  assert.equal(enter.defaultPrevented, true, "the fill Enter is consumed");
  // Propagation stopped for the fill Enter ONLY: the page saw the arrow but
  // never the Enter, and nothing became a submit.
  assert.deepEqual(pageSawKeys, [["ArrowDown", false]]);
  assert.equal(page.submitCount, 0);
  assert.equal(overlayCount(page), 0, "fill ends with teardown");
});

test("A037: ArrowDown + Enter beats page interception and implicit form submit", async () => {
  const { page, form, password: pwInput, handlers } = await loginPage();
  addSubmitControl(page, form);
  handlers.matches = (m) =>
    matchesResult(m, {
      items: [
        item({ entryId: "entry-1", title: "Row1" }),
        item({ entryId: "entry-2", title: "Row2" }),
      ],
    });
  const fills = [];
  handlers.fill = (m) => {
    fills.push(m.entryId);
    return fillResult(m, { password: FILL_VALUE_K });
  };
  let submits = 0;
  form.addEventListener("submit", (event) => {
    submits += 1;
    event.preventDefault();
  });
  // Registered before the pre-fix focus session's anchor listener, like page
  // code already installed by a framework. It owns no default action, but can
  // stop a later target listener from seeing Enter; browser submit still follows.
  pwInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") event.stopImmediatePropagation();
  });

  await page.focus(pwInput);
  await page.pressKey("ArrowDown");
  const enter = await page.pressKey("Enter");

  assert.equal(submits, 0, "implicit submit must be suppressed");
  assert.deepEqual(fills, ["entry-2"], "the active second row must fill");
  assert.equal(pwInput.value, FILL_VALUE_K);
  assert.equal(enter.defaultPrevented, true);
});

test("A037: Enter suppresses submit before a failed fill response settles", async () => {
  const { page, form, password: pwInput, handlers } = await loginPage();
  addSubmitControl(page, form);
  handlers.matches = (m) =>
    matchesResult(m, {
      items: [
        item({ entryId: "entry-1", title: "Row1" }),
        item({ entryId: "entry-2", title: "Row2" }),
      ],
    });
  let releaseFill;
  handlers.fill = (m) =>
    new Promise((resolve) => {
      releaseFill = () => resolve(errorResult("fillResult", "timeout", m));
    });
  let submits = 0;
  form.addEventListener("submit", (event) => {
    submits += 1;
    event.preventDefault();
  });
  pwInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") event.stopImmediatePropagation();
  });

  await page.focus(pwInput);
  await page.pressKey("ArrowDown");
  const pressing = page.pressKey("Enter");

  assert.equal(submits, 0, "Enter must be consumed before reveal settles");
  assert.equal(typeof releaseFill, "function", "fill request must start synchronously");
  releaseFill();
  const enter = await pressing;
  assert.equal(enter.defaultPrevented, true);
  assert.equal(submits, 0);
  assert.equal(pwInput.value, "");
  assert.equal(statusText(page), "Custode did not respond in time.");
});

test("A037: trusted keydown at a non-anchor is not intercepted", async () => {
  const { page, password: pwInput, username } = await pageWithRows(1);
  const event = new FakeEvent("keydown", {
    bubbles: true,
    cancelable: true,
    composed: true,
    isTrusted: true,
    key: "Enter",
  });

  username.dispatchEvent(event);

  assert.equal(page.document.activeElement, pwInput, "password remains the live anchor");
  assert.equal(event.defaultPrevented, false);
  assert.equal(page.sentOfType("fill").length, 0);
  assert.equal(overlayCount(page), 1);
});

test("A037: Enter on a non-eligible row does nothing and passes through", async () => {
  const { page, password: pwInput, handlers } = await loginPage();
  handlers.matches = (m) =>
    matchesResult(m, {
      items: [
        item({ entryId: "entry-1", title: "Fillable" }),
        item({
          entryId: "entry-2",
          title: "MetadataOnly",
          matchType: "possible",
          fillEligible: false,
        }),
      ],
    });
  await page.focus(pwInput);
  await page.pressKey("ArrowDown"); // select the non-eligible row
  const enter = await page.pressKey("Enter");

  assert.equal(page.sentOfType("fill").length, 0, "a non-eligible row can never fill");
  assert.equal(enter.defaultPrevented, false, "an unused Enter is not swallowed");
  assert.equal(overlayCount(page), 1, "the session stays open");
});

test("A037: Escape dismisses the current focus session without swallowing the key", async () => {
  const { page } = await pageWithRows(1);
  const escape = await page.pressKey("Escape");
  assert.equal(overlayCount(page), 0);
  assert.equal(escape.defaultPrevented, false);
});

test("A037: Tab tears down and passes through", async () => {
  const { page } = await pageWithRows(1);
  const pageSaw = [];
  page.document.addEventListener("keydown", (event) => {
    pageSaw.push([event.key, event.defaultPrevented]);
  });
  const tab = await page.pressKey("Tab");
  assert.equal(overlayCount(page), 0, "Tab must tear the session down");
  assert.equal(tab.defaultPrevented, false, "Tab must not be swallowed");
  assert.deepEqual(pageSaw, [["Tab", false]], "the page keeps its Tab");
});

test("A037: a closed overlay captures no page keys", async () => {
  const { page, form, password: pwInput } = await pageWithRows(1);
  addSubmitControl(page, form);
  const pageSaw = [];
  page.document.addEventListener("keydown", (event) => {
    pageSaw.push([event.key, event.defaultPrevented]);
  });
  const keydownListenersWithSession = page.document.listenerTypes.filter(
    (type) => type === "keydown"
  ).length;

  await page.pressKey("Escape"); // close the session; focus stays on the anchor
  assert.equal(overlayCount(page), 0);
  pageSaw.length = 0;
  const sentBefore = page.sent.length;

  for (const key of ["Enter", "ArrowDown", "ArrowUp", "Escape", "a"]) {
    await page.pressKey(key);
  }

  // Every key reached the page untouched: nothing captured, nothing
  // prevented, nothing sent, nothing rendered. Structurally so — the closed
  // overlay holds no keydown listener at all.
  assert.deepEqual(pageSaw, [
    ["Enter", false],
    ["ArrowDown", false],
    ["ArrowUp", false],
    ["Escape", false],
    ["a", false],
  ]);
  assert.equal(
    page.submitCount,
    1,
    "with no overlay session, Enter keeps the page's implicit submit"
  );
  assert.equal(page.sent.length, sentBefore);
  const keydownListenersAfter = page.document.listenerTypes.filter(
    (type) => type === "keydown"
  ).length;
  assert.equal(
    keydownListenersAfter,
    keydownListenersWithSession - 1,
    "session keydown listener must be aborted"
  );
});

test("A037: two blocking fields without a submitter do not implicitly submit", async () => {
  const { page } = await pageWithRows(1);
  await page.pressKey("Escape");

  const enter = await page.pressKey("Enter");

  assert.equal(enter.defaultPrevented, false);
  assert.equal(page.submitCount, 0);
});

// ---------------------------------------------------------------------------
// A038 — click-vs-blur.
// ---------------------------------------------------------------------------

test("A038: pointer-down inside the overlay preserves the anchor focus and marks the action pending", async () => {
  const { page, password: pwInput } = await pageWithRows(1);
  const row = optionRows(page)[0];

  const mousedown = new FakeEvent("mousedown", {
    bubbles: true,
    cancelable: true,
    composed: true,
    isTrusted: true, // a REAL pointer press — the adversarial (untrusted) case is A040
  });
  page._propagate(row, mousedown);

  assert.equal(mousedown.defaultPrevented, true, "the focus-stealing default is prevented");
  assert.equal(page.document.activeElement, pwInput, "the anchor keeps focus");
  assert.equal(overlayCount(page), 1);
});

test("A038: a deferred outside blur cannot remove the row before the click lands", async () => {
  // The race, reproduced: a spurious focusout fires at the anchor BETWEEN the
  // overlay mousedown and its click (AT and window-refocus sequences do
  // this). The pending action must hold the deferred teardown off so the
  // click still hits a live row and the fill completes.
  const { page, password: pwInput, handlers } = await pageWithRows(1);
  handlers.fill = (m) => fillResult(m, { password: FILL_VALUE_P });
  const row = optionRows(page)[0];

  // A real pointer sequence (trusted) interleaved with a spurious focusout.
  const mousedown = new FakeEvent("mousedown", { bubbles: true, cancelable: true, composed: true, isTrusted: true });
  page._propagate(row, mousedown);
  page._propagate(
    pwInput,
    new FakeEvent("focusout", { bubbles: true, composed: true, isTrusted: true })
  );
  assert.equal(row.isConnected, true, "the deferred blur must not remove the row mid-pointer");

  page._propagate(row, new FakeEvent("mouseup", { bubbles: true, composed: true, isTrusted: true }));
  page._propagate(row, new FakeEvent("click", { bubbles: true, cancelable: true, composed: true, isTrusted: true }));
  await page.settle();

  assert.equal(pwInput.value, FILL_VALUE_P, "the click must win the race");
  assert.equal(page.submitCount, 0);
  assert.equal(overlayCount(page), 0, "the action still ends in teardown");
});

test("A038: a teardown broadcast wins over a pending pointer action", async () => {
  // The broadcast is a revocation signal: rendering may never outlive the
  // revision that authorized it, and a pointer press in flight is not a
  // stay of execution. Today this holds structurally (the broadcast handler
  // has no pending-action guard); this test pins it BEHAVIOURALLY so a
  // future "finish the click first" guard cannot slip in unnoticed
  // (mutation A5-M10 is exactly that guard).
  const { page, password: pwInput } = await pageWithRows(1);
  const row = optionRows(page)[0];

  page._propagate(
    row,
    new FakeEvent("mousedown", { bubbles: true, cancelable: true, composed: true, isTrusted: true })
  );

  // The broadcast lands mid-pointer; revalidation still approves the origin,
  // so the listener survives — the SESSION must not.
  await page.deliver({
    channel: security.CHANNEL,
    version: security.MESSAGE_VERSION,
    type: "teardown",
    revision: 4,
  });
  assert.equal(overlayCount(page), 0, "the broadcast must remove the host despite the pending action");

  // The click that follows hits a dead row: no fill request, no message of
  // any kind, no secret in the input.
  const sentBefore = page.sent.length; // bootstrap + matches + revalidation
  page._propagate(row, new FakeEvent("mouseup", { bubbles: true, composed: true, isTrusted: true }));
  page._propagate(
    row,
    new FakeEvent("click", { bubbles: true, cancelable: true, composed: true, isTrusted: true })
  );
  await page.settle();

  assert.equal(page.sentOfType("fill").length, 0);
  assert.equal(page.sent.length, sentBefore, "a dead row must not speak at all");
  assert.equal(pwInput.value, "");
});

test("A038: a genuine outside blur still tears down promptly (after the pointer task)", async () => {
  const { page } = await pageWithRows(1);
  await page.click(page.document.body);
  assert.equal(overlayCount(page), 0);
  assert.equal(page._timeouts.size, 0, "no orphan deferred timer");
});

test("A038: overlay controls are type=button, outside every page form, and produce zero submits", async () => {
  const { page, form } = await pageWithRows(2);
  const shadowButtons = page
    .allElements()
    .filter((el) => el.tagName === "BUTTON");
  assert.ok(shadowButtons.length >= 3, "rows + generate control expected");
  for (const button of shadowButtons) {
    assert.equal(button.getAttribute("type"), "button");
    assert.equal(button.form, null, "overlay controls must not join a page form");
  }
  let submitSeen = 0;
  form.addEventListener("submit", () => {
    submitSeen += 1;
  });
  await page.click(optionRows(page)[0]);
  assert.equal(page.submitCount, 0);
  assert.equal(submitSeen, 0);
});

// ---------------------------------------------------------------------------
// A039 — input delivery and late-ineligibility refusals (the five REQUIRED
// named DOM assertions live in content_overlay.test.js).
// ---------------------------------------------------------------------------

test("A039: fill drives framework-controlled inputs through the prototype value setter", async () => {
  const { page, password: pwInput, handlers } = await loginPage();
  handlers.fill = (m) => fillResult(m, { password: FILL_VALUE_P });
  await page.focus(pwInput);

  // A framework shadows `value` with an instance accessor to track writes.
  // The fill must go through the PROTOTYPE (native) setter — updating the
  // real value storage, bypassing the framework interceptor — and notify via
  // the bubbling `input` event, which is how the framework actually learns.
  let interceptorWrites = 0;
  Object.defineProperty(pwInput, "value", {
    configurable: true,
    get: () => "",
    set: () => {
      interceptorWrites += 1;
    },
  });
  const inputEvents = [];
  pwInput.addEventListener("input", (event) => inputEvents.push(event.type));

  await page.click(optionRows(page)[0]);

  assert.equal(pwInput._value, FILL_VALUE_P, "the native storage must hold the value");
  assert.equal(interceptorWrites, 0, "the framework interceptor must be bypassed");
  assert.deepEqual(inputEvents, ["input"], "the framework is notified by the event");
});

test("A039: no fill lands on a field made read-only or hidden after the query", async () => {
  for (const sabotage of [
    (pwInput) => {
      pwInput.readOnly = true;
    },
    (pwInput) => {
      pwInput.setAttribute("hidden", "");
    },
    (pwInput) => {
      pwInput.disabled = true;
    },
  ]) {
    const { page, password: pwInput } = await pageWithRows(1);
    sabotage(pwInput);
    await page.click(optionRows(page)[0]);
    assert.equal(pwInput.value, "", "an ineligible field must never receive the secret");
    assert.equal(overlayCount(page), 0, "the refusal fails closed");
  }
});
