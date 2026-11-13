// 009 A040 — assistive-technology activation of the overlay, measured live
// with VoiceOver on macOS: with VO active the arrow keys move the VO cursor
// (which reads the shadow rows directly), NOT the overlay selection, so
// selectedIndex stays -1 and Enter falls through to the page (implicit
// submit). VO+Space (AXPress) on a row inside the closed shadow does not
// reach our click handler either, and aria-activedescendant IDREFs never
// cross a closed shadow boundary.
//
// Two complementary levers, both under test here:
//
//  1. DIRECT PRESS ON THE SHADOW ROWS — every actionable row also handles
//     keydown(Enter/Space), so an AXPress that lands as a key event on the
//     focused row activates it; DOM focus entering the overlay (shadow host
//     or light option) is NOT an outside departure and must not tear the
//     session down.
//  2. GENERIC LIGHT-DOM FALLBACK — a visually sr-only role=listbox sibling
//     of the host whose options carry ONLY indices and static labels
//     ("Suggestion 1 of N", "Generate a password"). VO can reach and actuate
//     it natively; activation runs the EXACT same one-shot fill/generate
//     path as a click on the shadow row of the same index. The anchor's
//     aria-activedescendant points at the LIGHT option ids (same DOM root,
//     so the IDREF resolves — repairing the documented closed-shadow limit).
//
// NON-NEGOTIABLE: entry titles/services/usernames NEVER appear in the light
// DOM (see the extended A032 scan in secret_lifetime.test.js).

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { FakeEvent } = require("./fake_page.js");
const {
  item,
  matchesResult,
  fillResult,
  generateResult,
  loginPage,
  optionRows,
  lightListboxEl,
  lightOptions,
  overlayCount,
} = require("./session_helpers.js");

// Runtime-assembled canaries: no credential-shaped source literal (GitGuardian).
const FILL_VALUE_AT = ["canary", "at", "press"].join("-");
const GEN_VALUE_AT = ["canary", "at", "generated"].join("-");

async function pageWithRows(count = 2, extra = {}) {
  const ctx = await loginPage();
  ctx.handlers.matches = (m) =>
    matchesResult(m, {
      items: Array.from({ length: count }, (_, index) =>
        item({ entryId: `entry-${index + 1}`, title: `Row${index + 1}` })
      ),
      ...extra,
    });
  await ctx.page.focus(ctx.password);
  assert.equal(optionRows(ctx.page).length, count);
  return ctx;
}

/** A REAL (user-agent) key press delivered at `el`. */
function pressOn(page, el, key) {
  const event = new FakeEvent("keydown", {
    bubbles: true,
    cancelable: true,
    composed: true,
    isTrusted: true,
    key,
  });
  page._propagate(el, event);
  return event;
}

/** A PAGE-SYNTHETIC event (isTrusted false), as hostile page code makes. */
function syntheticOn(page, el, type, key) {
  const event = new FakeEvent(type, {
    bubbles: true,
    cancelable: true,
    composed: true,
    key,
  });
  page._propagate(el, event);
  return event;
}

// ---------------------------------------------------------------------------
// Lever 2 — the generic light-DOM fallback listbox.
// ---------------------------------------------------------------------------

test("A040: a light listbox with GENERIC options renders as a sibling in the page tree", async () => {
  const { page } = await pageWithRows(2);

  const listbox = lightListboxEl(page);
  assert.ok(listbox, "light listbox missing");
  assert.equal(listbox.getAttribute("role"), "listbox");
  assert.equal(listbox.getAttribute("aria-label"), "Custode suggestions");
  // In the PAGE tree (light DOM), not inside any shadow root.
  let node = listbox.parentNode;
  let inPageTree = false;
  while (node) {
    if (node === page.document.body) inPageTree = true;
    node = node.parentNode ?? null;
  }
  assert.ok(inPageTree, "the light listbox must live in the page tree");

  // Visually sr-only via the clip pattern: zero rendered pixels, still in
  // the accessibility tree (never display:none / visibility:hidden /
  // aria-hidden).
  const style = listbox.getAttribute("style");
  for (const fragment of ["clip:rect(0 0 0 0)", "clip-path:inset(50%)", "width:1px", "height:1px", "overflow:hidden"]) {
    assert.ok(style.includes(fragment), `sr-only style must include ${fragment}`);
  }
  assert.ok(!style.includes("display:none"));
  assert.ok(!style.includes("visibility:hidden"));
  assert.equal(listbox.getAttribute("aria-hidden"), null);

  // GENERIC labels only: indices and static text, no titles, no services.
  const options = lightOptions(page);
  assert.deepEqual(
    options.map((opt) => opt.textContent),
    ["Suggestion 1 of 2", "Suggestion 2 of 2"]
  );
  assert.deepEqual(
    options.map((opt) => opt.id),
    ["kv-light-option-0", "kv-light-option-1"]
  );
  for (const opt of options) {
    assert.equal(opt.getAttribute("role"), "option");
    assert.equal(opt.getAttribute("type"), "button");
    assert.equal(opt.form, null, "light options must not join a page form");
  }
});

test("A040: activating light option N runs the identical fill path as the shadow row N", async () => {
  const { page, password: pwInput, handlers } = await pageWithRows(2);
  const fills = [];
  handlers.fill = (m) => {
    fills.push(m.entryId);
    return fillResult(m, { password: FILL_VALUE_AT });
  };

  await page.click(lightOptions(page)[1]);

  assert.deepEqual(fills, ["entry-2"], "light option 2 must fill entry 2");
  assert.equal(pwInput.value, FILL_VALUE_AT);
  assert.equal(page.submitCount, 0);
  assert.equal(overlayCount(page), 0, "fill ends with teardown");
  assert.equal(lightListboxEl(page)?.isConnected ?? false, false,
    "teardown removes the light listbox too");
});

test("A040: the light activation is one-shot — a double activation sends exactly one fill", async () => {
  const { page, handlers } = await pageWithRows(1);
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  handlers.fill = async (m) => {
    await gate;
    return fillResult(m, { password: FILL_VALUE_AT });
  };
  const opt = lightOptions(page)[0];

  // Two REAL presses before the worker answers: the token must die on the
  // first (both trusted — the untrusted case is the adversarial test below).
  const first = page.click(opt);
  page._propagate(
    opt,
    new FakeEvent("click", { bubbles: true, cancelable: true, composed: true, isTrusted: true })
  );
  release();
  await first;
  await page.settle();

  assert.equal(page.sentOfType("fill").length, 1, "the one-shot token permits exactly one fill request");
});

test("A040: light activation without a fill token sends nothing", async () => {
  // The no-fillable state renders rows (and their light counterparts) but no
  // token exists: activation through the light path must refuse exactly like
  // the shadow path — never a fill message with a missing/void token.
  const { page, handlers } = await pageWithRows(1, { fillToken: null });
  const opt = lightOptions(page)[0];
  await page.click(opt);
  assert.equal(page.sentOfType("fill").length, 0, "no token, no fill request");
  assert.equal(overlayCount(page), 1, "the session stays open");
});

test("A040: the light Generate option runs the one-shot generate path", async () => {
  const { page, password: pwInput, handlers } = await pageWithRows(1, {
    generateAvailable: true,
  });
  handlers.generate = (m) => generateResult(m, { generated: GEN_VALUE_AT });

  const options = lightOptions(page);
  assert.equal(options.length, 2, "1 suggestion + the Generate option");
  assert.equal(options[1].textContent, "Generate a password");
  assert.equal(options[1].id, "kv-light-option-1");

  await page.click(options[1]);

  assert.equal(pwInput.value, GEN_VALUE_AT);
  assert.equal(page.sentOfType("generate").length, 1);
  assert.equal(page.submitCount, 0);
  assert.equal(overlayCount(page), 0);
});

test("A040: without the generate capability the light listbox offers NO generate option", async () => {
  const { page } = await pageWithRows(2);
  assert.equal(lightOptions(page).length, 2, "matches only, no generate");
  assert.ok(!lightOptions(page).some((o) => o.textContent === "Generate a password"));
});

test("A040: zero matches with an active capability still exposes the light Generate option", async () => {
  const { page, password: pwInput, handlers } = await loginPage();
  handlers.matches = (m) =>
    matchesResult(m, { items: [], generateAvailable: true });
  handlers.generate = (m) => generateResult(m, { generated: GEN_VALUE_AT });
  await page.focus(pwInput);

  const options = lightOptions(page);
  assert.deepEqual(options.map((o) => o.textContent), ["Generate a password"]);
  await page.click(options[0]);
  assert.equal(pwInput.value, GEN_VALUE_AT);
  assert.equal(overlayCount(page), 0);
});

test("A040: a non-eligible entry's light option is disabled and can never fill", async () => {
  const { page, password: pwInput, handlers } = await loginPage();
  handlers.matches = (m) =>
    matchesResult(m, {
      items: [
        item({ entryId: "entry-1", title: "Fillable" }),
        item({ entryId: "entry-2", matchType: "possible", fillEligible: false }),
      ],
    });
  await page.focus(pwInput);

  const options = lightOptions(page);
  assert.equal(options[1].getAttribute("aria-disabled"), "true");
  await page.click(options[1]);
  assert.equal(page.sentOfType("fill").length, 0);
  assert.equal(overlayCount(page), 1, "the session stays open");
});

// ---------------------------------------------------------------------------
// A040 SECURITY — the light options are PAGE-reachable DOM. A hostile page
// can getElementById + dispatchEvent synthetic events at them; without the
// isTrusted guard that is a no-gesture fill = credential exfiltration
// (tester-proven, live). This test is the PERMANENT adversarial repro.
// ---------------------------------------------------------------------------

test("A040 security: page-synthetic events on the light surface produce ZERO fill/generate", async () => {
  const { page, password: pwInput, handlers } = await pageWithRows(2, {
    generateAvailable: true,
  });
  handlers.fill = (m) => fillResult(m, { password: FILL_VALUE_AT });
  handlers.generate = (m) => generateResult(m, { generated: GEN_VALUE_AT });
  const sentBefore = page.sent.length;

  // Synthetic click AND keydown(Enter/Space) on EVERY light option, the
  // listbox itself, every shadow row, and the Generate row.
  const targets = [
    ...lightOptions(page),
    lightListboxEl(page),
    ...optionRows(page),
    page.allElements().find((el) => el.id === "kv-generate"),
  ];
  for (const target of targets) {
    syntheticOn(page, target, "click");
    syntheticOn(page, target, "keydown", "Enter");
    syntheticOn(page, target, "keydown", " ");
  }
  // And the anchor keyboard path: synthetic ArrowDown + Enter at the anchor
  // must not drive the selection nor fill.
  syntheticOn(page, pwInput, "keydown", "ArrowDown");
  syntheticOn(page, pwInput, "keydown", "Enter");
  await page.settle();

  assert.equal(page.sentOfType("fill").length, 0, "no synthetic event may fill");
  assert.equal(page.sentOfType("generate").length, 0, "no synthetic event may generate");
  assert.equal(page.sent.length, sentBefore, "no message of any kind was sent");
  assert.equal(pwInput.value, "", "no secret reached the input");
  assert.equal(overlayCount(page), 1, "the session is untouched");

  // Counter-proof: the SAME surface activated by a real gesture fills.
  await page.click(lightOptions(page)[0]);
  assert.equal(pwInput.value, FILL_VALUE_AT, "a trusted activation still fills");
  assert.equal(page.sentOfType("fill").length, 1);
});

// ---------------------------------------------------------------------------
// ARIA — anchor activedescendant now points at LIGHT ids (same root).
// ---------------------------------------------------------------------------

test("A040: the anchor's aria-activedescendant names an existing LIGHT option and tracks the selection", async () => {
  const { page, password: pwInput } = await pageWithRows(2, { generateAvailable: true });

  const idsInLightDom = () => lightOptions(page).map((o) => o.id);
  assert.equal(pwInput.getAttribute("aria-controls"), "kv-light-listbox");
  assert.equal(pwInput.getAttribute("aria-activedescendant"), "kv-light-option-0");
  assert.ok(idsInLightDom().includes("kv-light-option-0"), "IDREF must resolve in the same root");
  assert.equal(lightOptions(page)[0].getAttribute("aria-selected"), "true");

  await page.pressKey("ArrowDown");
  assert.equal(pwInput.getAttribute("aria-activedescendant"), "kv-light-option-1");
  assert.deepEqual(
    lightOptions(page).map((o) => o.getAttribute("aria-selected")),
    ["false", "true", "false"]
  );

  // The virtual Generate row is the last light option; the sync covers it.
  await page.pressKey("ArrowDown");
  assert.equal(pwInput.getAttribute("aria-activedescendant"), "kv-light-option-2");
  assert.equal(lightOptions(page)[2].getAttribute("aria-selected"), "true");

  // Teardown restores the anchor ARIA (absent stays absent) and removes the
  // light listbox from the page tree.
  await page.pressKey("Escape");
  assert.equal(pwInput.getAttribute("aria-activedescendant"), null);
  assert.equal(pwInput.getAttribute("aria-controls"), null);
  assert.equal(lightListboxEl(page)?.isConnected ?? false, false);
});

// ---------------------------------------------------------------------------
// Lever 1 — direct press on the shadow rows; focus-in-overlay is not outside.
// ---------------------------------------------------------------------------

test("A040: keydown Enter and Space on a shadow row activate the fill", async () => {
  for (const key of ["Enter", " "]) {
    const { page, password: pwInput, handlers } = await pageWithRows(2);
    const fills = [];
    handlers.fill = (m) => {
      fills.push(m.entryId);
      return fillResult(m, { password: FILL_VALUE_AT });
    };
    const row = optionRows(page)[1];
    const event = pressOn(page, row, key);
    await page.settle();

    assert.deepEqual(fills, ["entry-2"], `key=${JSON.stringify(key)} must fill the pressed row`);
    assert.equal(pwInput.value, FILL_VALUE_AT);
    assert.equal(event.defaultPrevented, true, "the activating press is consumed");
    assert.equal(page.submitCount, 0);
    assert.equal(overlayCount(page), 0);
  }
});

test("A040: keydown Enter on the active Generate row triggers generate", async () => {
  const { page, password: pwInput, handlers } = await pageWithRows(1, {
    generateAvailable: true,
  });
  handlers.generate = (m) => generateResult(m, { generated: GEN_VALUE_AT });
  const generate = page.allElements().find((el) => el.id === "kv-generate");

  pressOn(page, generate, "Enter");
  await page.settle();

  assert.equal(pwInput.value, GEN_VALUE_AT);
  assert.equal(overlayCount(page), 0);
});

test("A040: DOM focus entering the overlay does NOT tear the session down, and the press still fills", async () => {
  const { page, password: pwInput, handlers } = await pageWithRows(2);
  handlers.fill = (m) => fillResult(m, { password: FILL_VALUE_AT });
  const row = optionRows(page)[0];

  // An AT press can move real DOM focus onto the row first: the anchor gets
  // focusout, the overlay gets focusin. That must NOT be an outside blur.
  await page.focus(row);
  assert.equal(overlayCount(page), 1, "focus inside the overlay must not tear down");
  assert.equal(page._timeouts.size, 0, "the deferred blur teardown must be cancelled");

  // The press then lands on the focused row and fills.
  pressOn(page, row, "Enter");
  await page.settle();
  assert.equal(pwInput.value, FILL_VALUE_AT);
  assert.equal(overlayCount(page), 0);
});

test("A040: DOM focus on a LIGHT option does not tear down; its press fills", async () => {
  const { page, password: pwInput, handlers } = await pageWithRows(2);
  handlers.fill = (m) => fillResult(m, { password: FILL_VALUE_AT });
  const opt = lightOptions(page)[1];

  await page.focus(opt);
  assert.equal(overlayCount(page), 1, "focus on a light option must not tear down");

  const event = pressOn(page, opt, " ");
  await page.settle();
  assert.equal(event.defaultPrevented, true);
  assert.equal(pwInput.value, FILL_VALUE_AT);
  assert.equal(overlayCount(page), 0);
});

test("A040: focus leaving the overlay for the page IS an outside departure", async () => {
  const { page } = await pageWithRows(1);
  const row = optionRows(page)[0];
  await page.focus(row);
  assert.equal(overlayCount(page), 1);

  // From the overlay to a plain page control: genuine departure, teardown.
  const other = page.document.createElement("input");
  page.document.body.appendChild(other);
  await page.focus(other);
  assert.equal(overlayCount(page), 0, "leaving the overlay must tear down");
});

test("A040: hint sessions build no light listbox", async () => {
  const { page } = await loginPage();
  const iframe = page.document.createElement("iframe");
  iframe.setAttribute("src", "https://other.example/embedded-login");
  page.document.body.appendChild(iframe);
  await page.focus(iframe);
  assert.equal(overlayCount(page), 1, "the hint renders");
  assert.equal(lightListboxEl(page), undefined, "no light listbox for a hint");
});
