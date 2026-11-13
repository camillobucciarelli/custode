// 009 — MV3 ORPHANED CONTENT-SCRIPT INSTANCE.
//
// Found in manual QA against a real browser (CDP trace + the extension error
// log): the extension was reloaded while a login page stayed open. Chrome does
// not notify the already-injected content script; it removes the API bridge
// underneath it, so `chrome.runtime` reads back `undefined`. The user pressed
// Enter on the Generate row, `attemptGenerate` reached for
// `chrome.runtime.sendMessage`, and the access itself threw
// `TypeError: Cannot read properties of undefined (reading 'sendMessage')`.
// The overlay died in silence — no error state, no message, then unmounted.
// Reported as "I can't select an entry with the keyboard any more"; the arrow
// keys were in fact fine (opt0 -> opt1 -> opt2, no page submit). What broke
// was the ACTION.
//
// The `if (chrome.runtime.lastError)` branch every callback already carries is
// no defence at all here: it lives INSIDE a callback that an orphan can never
// reach, because the `sendMessage` access that would schedule it is the access
// that throws.
//
// Everything below is asserted through OBSERVABLE behaviour only — thrown or
// not, what the page shows, what was sent, what listeners and timers remain.
// No test reads a private flag. The SHIPPED `content_overlay.js` runs inside
// the `fake_page.js` isolated world; the fake models the browser losing the
// bridge and decides nothing about how the script should respond.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  matchesResult,
  generateResult,
  errorResult,
  loginPage,
  statusText,
  optionRows,
  lightListboxEl,
  overlayCount,
} = require("./session_helpers.js");
const { FakePage } = require("./fake_page.js");

// The honest copy for an orphan. Pinned here so a silent reword has to be a
// deliberate edit in two places: it promises NO automatic retry (an orphan has
// no way back to the worker) and names the one action that actually works.
const EXTENSION_LOST_TEXT =
  "This page lost its connection to Custode. Reload the page to use autofill.";

// Both shapes an orphan is observed in. A guard is only proven if it survives
// both: "runtime-undefined" THROWS on access (the QA trace), "id-undefined"
// does not throw at all, so only an explicit liveness probe catches it.
const MODES = ["runtime-undefined", "id-undefined"];

/** An approved page whose Generate row is active, focused on the password. */
async function generatePage() {
  const ctx = await loginPage();
  ctx.handlers.matches = (message) =>
    matchesResult(message, { generateAvailable: true });
  ctx.handlers.generate = (message) => generateResult(message);
  await ctx.page.focus(ctx.password);
  return ctx;
}

/** Messages sent AFTER a mark — the "zero messages" assertion, precisely. */
function sentSince(page, mark) {
  return page.sent.slice(mark);
}

// ---------------------------------------------------------------------------
// (a) Invalidation, then Enter on a fill row.
// ---------------------------------------------------------------------------

for (const mode of MODES) {
  test(`orphan (${mode}): Enter on a fill row neither throws nor speaks`, async () => {
    const { page, password } = await loginPage();
    await page.focus(password);
    assert.equal(optionRows(page).length, 1, "a fill row is on screen");

    const mark = page.sent.length;
    page.invalidateExtensionContext(mode);

    // The reported gesture. It must not throw — that is the whole bug.
    await assert.doesNotReject(async () => {
      await page.pressKey("Enter");
    });

    // ZERO messages: an orphan cannot reach the worker, so it must not try.
    assert.deepEqual(
      sentSince(page, mark),
      [],
      "an orphan must send nothing at all"
    );
    // Never a silent death: the honest state replaced the rows.
    assert.equal(statusText(page), EXTENSION_LOST_TEXT);
    assert.equal(optionRows(page).length, 0, "entry metadata is cleared");
    assert.equal(password.value, "", "nothing was filled");
    assert.equal(page.submitCount, 0);
  });
}

test("orphan: the fill row's one-shot token is not spent by the refused action", async () => {
  const { page, password } = await loginPage();
  await page.focus(password);
  const mark = page.sent.length;
  page.invalidateExtensionContext();

  // Two presses, to prove the refusal is stable rather than a one-off that
  // burns state on the way through.
  await page.pressKey("Enter");
  await page.pressKey("Enter");

  assert.deepEqual(sentSince(page, mark), []);
  assert.equal(statusText(page), EXTENSION_LOST_TEXT);
});

// ---------------------------------------------------------------------------
// (b) Invalidation, then Enter on the Generate row — the exact QA trace.
// ---------------------------------------------------------------------------

for (const mode of MODES) {
  test(`orphan (${mode}): Enter on Generate neither throws nor speaks`, async () => {
    const { page, password } = await generatePage();

    // Reproduce the reported navigation first: the arrows kept working, which
    // is why the user read the failure as "keyboard selection is broken".
    await page.pressKey("ArrowDown");

    const mark = page.sent.length;
    page.invalidateExtensionContext(mode);

    await assert.doesNotReject(async () => {
      await page.pressKey("Enter");
    });

    assert.deepEqual(
      sentSince(page, mark),
      [],
      "an orphan must not send `generate`"
    );
    assert.equal(statusText(page), EXTENSION_LOST_TEXT);
    assert.equal(password.value, "", "no password was generated into the field");
    assert.equal(page.submitCount, 0);
  });
}

test("orphan: the honest state never promises a retry that cannot happen", async () => {
  const { page } = await generatePage();
  page.invalidateExtensionContext();
  await page.pressKey("ArrowDown");
  await page.pressKey("Enter");

  assert.equal(statusText(page), EXTENSION_LOST_TEXT);
  assert.match(statusText(page), /Reload the page/);
  // `stale_session` is the only state that mints a "Try again" control, and it
  // would be a lie here: the retry path is itself a `chrome.runtime` call.
  const retry = page.allElements().find((el) => el.id === "kv-retry");
  assert.equal(retry, undefined, "an orphan must not offer a retry control");
});

// ---------------------------------------------------------------------------
// A NEW session started on an already-orphaned instance. The realistic order:
// the extension is reloaded first, and only then does the user click a field.
// ---------------------------------------------------------------------------

for (const mode of MODES) {
  test(`orphan (${mode}): a new session sends no query and shows the honest state`, async () => {
    const { page, password } = await loginPage();
    const mark = page.sent.length;
    page.invalidateExtensionContext(mode);

    await assert.doesNotReject(async () => {
      await page.focus(password);
    });

    assert.deepEqual(
      sentSince(page, mark),
      [],
      "an orphan must not send `requestMatches`"
    );
    assert.equal(statusText(page), EXTENSION_LOST_TEXT);
    assert.equal(optionRows(page).length, 0);
  });
}

// ---------------------------------------------------------------------------
// (c) Invalidation, then a NORMAL teardown (Escape).
// ---------------------------------------------------------------------------

for (const mode of MODES) {
  test(`orphan (${mode}): Escape tears down cleanly and silently`, async () => {
    const { page, password } = await loginPage();
    await page.focus(password);
    const mark = page.sent.length;
    page.invalidateExtensionContext(mode);

    await assert.doesNotReject(async () => {
      await page.pressKey("Escape");
    });

    assert.deepEqual(sentSince(page, mark), []);
    // Escape is a dismissal, not a failed action: the user asked for the
    // overlay to go away and it went away. No tombstone is owed.
    assert.equal(overlayCount(page), 0);
  });
}

for (const mode of MODES) {
  test(`orphan (${mode}): pagehide and visibility teardown do not throw`, async () => {
    const { page, password } = await loginPage();
    await page.focus(password);
    page.invalidateExtensionContext(mode);

    await assert.doesNotReject(async () => {
      await page.setVisibility("hidden");
      await page.firePagehide();
    });
    assert.equal(overlayCount(page), 0);
  });
}

for (const mode of MODES) {
  test(`orphan (${mode}): the session watchdog tick does not throw`, async () => {
    const { page, password } = await loginPage();
    await page.focus(password);
    page.invalidateExtensionContext(mode);

    await assert.doesNotReject(async () => {
      await page.tick();
    });
  });
}

// ---------------------------------------------------------------------------
// (d) Invalidation BEFORE bootstrap.
// ---------------------------------------------------------------------------

for (const mode of MODES) {
  test(`orphan (${mode}) before bootstrap: the instance never speaks or builds`, async () => {
    const page = new FakePage({
      url: "https://example.com/login",
      respond: async () => {
        throw new Error("an orphan must not reach the worker at all");
      },
    });
    const doc = page.document;
    const form = doc.createElement("form");
    const password = doc.createElement("input");
    password.setAttribute("type", "password");
    form.appendChild(password);
    doc.body.appendChild(form);

    page.invalidateExtensionContext(mode);

    await assert.doesNotReject(async () => {
      await page.inject();
    });

    assert.deepEqual(page.sent, [], "no bootstrap handshake from an orphan");
    assert.equal(page.listenerCount, 0, "no onMessage listener was registered");

    // Nothing is built: focusing an eligible field produces no overlay,
    // because the instance never activated its document listeners.
    await assert.doesNotReject(async () => {
      await page.focus(password);
    });
    assert.equal(overlayCount(page), 0);
    assert.equal(statusText(page), null);
    assert.deepEqual(page.sent, []);
  });
}

// ---------------------------------------------------------------------------
// F1 — an orphan that leaves NO tombstone must not strand the tab.
//
// This extension ships no `content_scripts` manifest block: every instance
// arrives via `scripting.registerContentScripts` / `executeScript`. So the
// bootstrap guard is load-bearing, and holding it after going inert without a
// notice is the silent, UNRECOVERABLE death this whole path exists to abolish
// — the tab shows nothing and refuses re-injection until the user reloads.
// Regression caught in review: the sequence below survived on origin/main.
// ---------------------------------------------------------------------------

for (const mode of MODES) {
  test(`orphan (${mode}) with no session: inert but recoverable, never stranded`, async () => {
    const { page, password } = await loginPage();
    // No field is focused, so there is no session and nothing on screen.
    page.invalidateExtensionContext(mode);
    await assert.doesNotReject(async () => {
      await page.deliver({ channel: "custode-overlay", type: "teardown" });
    });

    // Nothing was shown, so nothing was promised.
    assert.equal(statusText(page), null, "no tombstone was left");
    assert.equal(overlayCount(page), 0);
    // Therefore the guard MUST be free: it exists only to stop a second
    // overlay mounting beside a notice, and there is no notice.
    assert.equal(
      page.guarded,
      false,
      "a silent inert exit must release the bootstrap guard"
    );

    // And the release must be worth something: a new worker re-injects into
    // this same page and serves it. (Listener COUNT is not the assertion: in
    // the runtime-undefined shape the orphan's own handle could not be
    // unregistered, so an inert leftover is expected alongside the new one.)
    const before = page.sentOfType("bootstrap").length;
    page.restoreExtensionContext();
    await page.inject();
    assert.equal(
      page.sentOfType("bootstrap").length,
      before + 1,
      "the re-injected instance completed a fresh handshake"
    );

    await page.focus(password);
    assert.equal(overlayCount(page), 1, "the tab is served again");
    assert.equal(optionRows(page).length, 1, "and it offers real suggestions");
  });
}

test("orphan WITH a tombstone keeps the guard: no overlay mounts beside the notice", async () => {
  const { page, password } = await loginPage();
  await page.focus(password);
  page.invalidateExtensionContext();
  await page.pressKey("Enter");

  // The complement of the test above, and the reason the release is
  // conditional rather than unconditional.
  assert.equal(statusText(page), EXTENSION_LOST_TEXT, "a tombstone is on screen");
  assert.equal(
    page.guarded,
    true,
    "the guard is held while a notice is telling the user to reload"
  );

  // A re-injection is refused, so the user is never shown a working overlay
  // sitting next to a notice that says autofill is broken.
  const before = page.sentOfType("bootstrap").length;
  page.restoreExtensionContext();
  await page.inject();
  assert.equal(
    page.sentOfType("bootstrap").length,
    before,
    "re-injection bailed on the guard without handshaking"
  );
  assert.equal(overlayCount(page), 1, "no second overlay mounted");
  assert.equal(statusText(page), EXTENSION_LOST_TEXT);
});

// ---------------------------------------------------------------------------
// F2/F3 — the tombstone is ONE sentence, and it dangles no IDREF.
// ---------------------------------------------------------------------------

test("F2: the tombstone holds no surviving control that looks live", async () => {
  const { page, password } = await generatePage();
  // Arrow onto the Generate row so it is enabled AND selected — the exact
  // state the reviewer measured surviving into the notice.
  await page.pressKey("ArrowDown");
  const generateBefore = page.allElements().find((el) => el.id === "kv-generate");
  assert.notEqual(generateBefore, undefined);
  assert.equal(generateBefore.disabled, false);
  assert.equal(generateBefore.getAttribute("aria-selected"), "true");

  page.invalidateExtensionContext();
  await page.pressKey("Enter");

  // The Generate row is gone, not merely greyed: a disabled control still
  // occupies the notice and still reads as an offer.
  assert.equal(
    page.allElements().find((el) => el.id === "kv-generate"),
    undefined,
    "the Generate row must not survive into the tombstone"
  );
  assert.equal(page.allElements().find((el) => el.id === "kv-retry"), undefined);

  // Whatever remains renders exactly the one honest sentence.
  const host = page.overlayHosts()[0];
  assert.notEqual(host, undefined, "the tombstone host is still on screen");
  assert.equal(statusText(page), EXTENSION_LOST_TEXT);
  // Leaf nodes only, and never the injected <style> sheet — this is about
  // what the user READS, not about the stylesheet the shadow root carries.
  const shown = page
    .allElements()
    .filter((el) => el.childNodes.length === 0 && el.tagName !== "STYLE")
    .map((el) => (el.textContent ?? "").trim())
    .filter((t) => t.length > 0);
  assert.deepEqual(
    shown,
    [EXTENSION_LOST_TEXT],
    "the tombstone renders one sentence and nothing else"
  );
});

test("F2: no interactive element survives inside the tombstone", async () => {
  const { page } = await generatePage();
  await page.pressKey("ArrowDown");
  page.invalidateExtensionContext();
  await page.pressKey("Enter");

  const interactive = page
    .allElements()
    .filter(
      (el) =>
        el.tagName === "BUTTON" ||
        el.getAttribute("role") === "option" ||
        el.getAttribute("role") === "button"
    )
    .map((el) => el.id);
  assert.deepEqual(interactive, [], "a dead notice offers no controls");
});

test("F3: the emptied listbox leaves no dangling aria-activedescendant", async () => {
  const { page, password } = await loginPage();
  await page.focus(password);
  const list = page.allElements().find((el) => el.id === "kv-list");
  assert.notEqual(list, undefined);
  assert.equal(list.getAttribute("aria-activedescendant"), "kv-option-0");

  page.invalidateExtensionContext();
  await page.pressKey("Enter");

  // The rows it pointed at are gone; the IDREF must go with them.
  assert.equal(optionRows(page).length, 0);
  assert.equal(
    list.getAttribute("aria-activedescendant"),
    null,
    "kv-list must not reference a row that no longer exists"
  );
});

test("F3: every ordinary state swap also drops the IDREF", async () => {
  // Not orphan-specific: the same dangling reference existed on the plain
  // error states, which clear the rows through the same branch.
  const { page, password, username, handlers } = await loginPage();
  await page.focus(password);
  const list = page.allElements().find((el) => el.id === "kv-list");
  assert.equal(list.getAttribute("aria-activedescendant"), "kv-option-0");

  // `timeout` clears the rows through the same branch as every other
  // non-`matches` state, so the IDREF must go there too. Focus has to LEAVE
  // the field and come back for a second session to start.
  handlers.matches = (message) => errorResult("matchesResult", "timeout", message);
  await page.focus(username);
  await page.focus(password);
  assert.equal(statusText(page), "Custode did not respond in time.");

  // Scoped to the LIVE listbox: `allElements()` is a harness x-ray that also
  // reports the shadow roots of already-removed overlays, so the first
  // session's rows stay visible to it after teardown.
  const listNow = page
    .allElements()
    .filter((el) => el.id === "kv-list")
    .pop();
  assert.equal(listNow.childNodes.length, 0, "the error state has no rows");
  assert.equal(
    listNow.getAttribute("aria-activedescendant"),
    null,
    "no state swap may leave a dangling IDREF"
  );
});

// ---------------------------------------------------------------------------
// (e) Nothing survives the exit path.
// ---------------------------------------------------------------------------

test("orphan: the exit path leaves no listener and no timer alive", async () => {
  const { page, password } = await generatePage();
  await page.pressKey("ArrowDown");
  // "id-undefined" is the shape in which the API needed to unregister the
  // runtime listener still exists, so removal is observable. See the
  // companion test below for the shape in which it provably cannot be.
  page.invalidateExtensionContext("id-undefined");
  await page.pressKey("Enter");

  // The runtime onMessage listener is dropped: the instance can no longer be
  // told to do anything.
  assert.equal(page.listenerCount, 0, "no runtime listener survives");
  // The watchdog interval and both deferred timers (blur, live region) are
  // cleared. A surviving interval would re-enter the session every second.
  assert.equal(page.pendingTimerCount, 0, "no timer survives");
  // The A040 light listbox is gone: an empty listbox whose rows no longer
  // activate is worse for AT than no listbox at all.
  assert.equal(lightListboxEl(page), undefined);

  // Inert means inert: further page activity drives nothing and sends nothing.
  const mark = page.sent.length;
  await assert.doesNotReject(async () => {
    await page.focus(password);
    await page.pressKey("ArrowDown");
    await page.pressKey("Enter");
    await page.fireScroll();
    await page.setViewport(800, 600);
    await page.tick();
  });
  assert.deepEqual(sentSince(page, mark), [], "an inert instance stays silent");
  assert.equal(page.pendingTimerCount, 0);
  assert.equal(page.submitCount, 0);
  // The tombstone is still the only thing on screen, still honest.
  assert.equal(statusText(page), EXTENSION_LOST_TEXT);
});

test("orphan (runtime-undefined): the surviving runtime listener is provably inert", async () => {
  const { page, password } = await generatePage();
  await page.pressKey("ArrowDown");
  // In THIS shape `chrome.runtime.onMessage.removeListener` is gone with the
  // rest of the bridge, so the handle cannot be unregistered — the honest
  // contract is that it is unreachable and does nothing, not that it is
  // absent. Asserting absence here would only be asserting that the fake is
  // more cooperative than Chrome.
  page.invalidateExtensionContext("runtime-undefined");
  await page.pressKey("Enter");

  const mark = page.sent.length;
  // Real Chrome could not deliver this at all; driving it anyway is strictly
  // stronger than assuming it cannot arrive.
  await assert.doesNotReject(async () => {
    await page.deliver({ channel: "custode-overlay", type: "teardown" });
  });
  assert.deepEqual(
    sentSince(page, mark),
    [],
    "the orphaned handler must not revalidate"
  );
  assert.equal(page.pendingTimerCount, 0);
  assert.equal(statusText(page), EXTENSION_LOST_TEXT);
});

test("orphan: the anchor's ARIA is restored even though the tombstone stays", async () => {
  const { page, password } = await loginPage();
  // A036 — the anchor is decorated as a combobox for the session's lifetime.
  await page.focus(password);
  assert.equal(password.getAttribute("aria-expanded"), "true");

  page.invalidateExtensionContext();
  await page.pressKey("Enter");

  // A dead overlay must not leave the field advertising an expanded listbox.
  assert.equal(password.getAttribute("aria-expanded"), null);
  assert.equal(password.getAttribute("aria-haspopup"), null);
  assert.equal(password.getAttribute("aria-activedescendant"), null);
});

test("orphan: the tombstone carries no entry metadata", async () => {
  const { page, password } = await loginPage();
  await page.focus(password);
  assert.equal(optionRows(page).length, 1);

  page.invalidateExtensionContext();
  await page.pressKey("Enter");

  // SR-5/A029 — the state swap clears the rows, so the frozen sentence is the
  // only text the dead overlay holds.
  assert.equal(optionRows(page).length, 0);
  const text = page
    .allElements()
    .map((el) => el.textContent ?? "")
    .join(" ");
  assert.equal(text.includes("Example"), false, "no entry title survives");
  assert.equal(text.includes("example.com"), false, "no service survives");
});

// ---------------------------------------------------------------------------
// Invalidation mid-flight: between the send and the callback.
// ---------------------------------------------------------------------------

test("orphan mid-flight: a response arriving after invalidation is handled without throwing", async () => {
  const { page, password, handlers } = await loginPage();
  handlers.matches = (message) => {
    // The bridge dies while the query is in flight. Reading `lastError` in the
    // callback is itself a `chrome.runtime` access and would throw.
    page.invalidateExtensionContext();
    return matchesResult(message);
  };

  await assert.doesNotReject(async () => {
    await page.focus(password);
  });
  // Inert, observably: nothing was rendered from the response that arrived
  // after the bridge died, nothing was filled, and no timer was left running.
  assert.equal(optionRows(page).length, 0, "a post-mortem response renders nothing");
  assert.equal(password.value, "");
  assert.equal(page.pendingTimerCount, 0);

  const mark = page.sent.length;
  await assert.doesNotReject(async () => {
    await page.pressKey("Enter");
  });
  assert.deepEqual(sentSince(page, mark), []);
});

// ---------------------------------------------------------------------------
// The normal path is untouched.
// ---------------------------------------------------------------------------

test("a LIVE context still fills normally — the guard costs the happy path nothing", async () => {
  const { page, password, username } = await loginPage();
  await page.focus(password);
  assert.equal(optionRows(page).length, 1);

  const enter = await page.pressKey("Enter");
  assert.equal(enter.defaultPrevented, true);
  assert.equal(page.sentOfType("fill").length, 1);
  assert.equal(password.value.length > 0, true, "the fill still happens");
  assert.equal(username.value, "alice");
  assert.equal(overlayCount(page), 0, "and the session tears down normally");
  assert.equal(page.submitCount, 0);
});

test("a LIVE context still generates normally", async () => {
  const { page, password } = await generatePage();
  await page.pressKey("ArrowDown");
  const enter = await page.pressKey("Enter");

  assert.equal(enter.defaultPrevented, true);
  assert.equal(page.sentOfType("generate").length, 1);
  assert.equal(password.value.length > 0, true);
  assert.equal(overlayCount(page), 0);
});

test("a LIVE context still bootstraps and registers its listener", async () => {
  const { page } = await loginPage();
  assert.equal(page.listenerCount, 1);
  assert.equal(page.sentOfType("bootstrap").length, 1);
});
