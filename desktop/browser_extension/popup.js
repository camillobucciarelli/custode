// Extension popup — spec 006 FR-7. Renders four states: matches, app
// locked, host not found, possible-only matches. Native Messaging v2
// protocol usage (message shapes to background.js) is unchanged — this
// file only changed *rendering*, not the wire contract.

const markElement = document.getElementById("mark");
const bodyElement = document.getElementById("popupBody");

let inFlight = false;
let currentTab = null; // { id, origin, title } of the active tab, if any

// ---------- small DOM helpers (no framework: this is a 400px popup) ----------

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function clearBody() {
  bodyElement.textContent = "";
}

function setMarkDim(dim) {
  markElement.classList.toggle("pop-mark--dim", dim);
}

function searchIconSvg() {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("width", "14");
  svg.setAttribute("height", "14");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "2.75");
  svg.setAttribute("stroke-linecap", "round");
  svg.innerHTML =
    '<circle cx="11" cy="11" r="7"/><path d="m16.5 16.5 4 4"/>';
  return svg;
}

function lockIconSvg() {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("width", "17");
  svg.setAttribute("height", "17");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "2.75");
  svg.setAttribute("stroke-linecap", "round");
  svg.innerHTML =
    '<rect x="4" y="10" width="16" height="10" rx="4"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>';
  return svg;
}

// ---------- native messaging plumbing (unchanged protocol, unchanged shapes) ----------

function errorText(response, fallback) {
  if (!response?.error) {
    return fallback;
  }
  if (typeof response.error === "string") {
    return response.error;
  }
  return response.error.message || response.error.code || fallback;
}

async function getActiveTab() {
  return new Promise((resolve) => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        resolve(null);
        return;
      }
      resolve(tabs[0] || null);
    });
  });
}

async function sendExtensionMessage(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(message, (response) => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        resolve({
          ok: false,
          error: {
            code: "extension_message_failed",
            message: lastError.message,
          },
        });
        return;
      }
      resolve(response);
    });
  });
}

function activeTabOrigin(tabUrl) {
  try {
    const url = new URL(tabUrl);
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return null;
    }
    return url.origin;
  } catch (_) {
    return null;
  }
}

function fillCredentialInPage(username, password) {
  function isVisible(element) {
    const style = globalThis.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return (
      style.visibility !== "hidden" &&
      style.display !== "none" &&
      rect.width > 0 &&
      rect.height > 0
    );
  }

  function canFillInput(element) {
    return (
      element instanceof HTMLInputElement &&
      !element.disabled &&
      !element.readOnly &&
      isVisible(element)
    );
  }

  function setNativeValue(element, value) {
    const prototype = Object.getPrototypeOf(element);
    const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
    if (descriptor?.set) {
      descriptor.set.call(element, value);
    } else {
      element.value = value;
    }
    element.dispatchEvent(new Event("input", { bubbles: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function textScore(element, passwordField) {
    const haystack = [
      element.autocomplete,
      element.name,
      element.id,
      element.getAttribute("aria-label"),
      element.placeholder,
    ]
      .join(" ")
      .toLowerCase();
    let score = 0;
    if (/username|user-name|email|e-mail|login|account/.test(haystack)) {
      score += 20;
    }
    if (element.type === "email") {
      score += 10;
    }
    if (element.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING) {
      score += 4;
    }
    return score;
  }

  const passwordFields = Array.from(document.querySelectorAll('input[type="password"]'))
    .filter(canFillInput);
  if (passwordFields.length === 0) {
    return { filled: false, reason: "no_password_field" };
  }

  const passwordField = passwordFields[0];
  const scope = passwordField.form || document;
  const usernameCandidates = Array.from(
    scope.querySelectorAll('input:not([type]), input[type="text"], input[type="email"], input[type="search"], input[type="tel"], input[type="url"]')
  ).filter((element) => canFillInput(element) && element !== passwordField);
  usernameCandidates.sort(
    (left, right) => textScore(right, passwordField) - textScore(left, passwordField)
  );

  const usernameField = usernameCandidates[0] || null;
  if (usernameField && username) {
    setNativeValue(usernameField, username);
  }
  setNativeValue(passwordField, password);
  passwordField.focus();
  return {
    filled: true,
    usernameFilled: Boolean(usernameField && username),
    passwordFilled: true,
  };
}

async function executeFill(tabId, username, password) {
  return new Promise((resolve) => {
    chrome.scripting.executeScript(
      {
        target: { tabId },
        func: fillCredentialInPage,
        args: [username, password],
      },
      (results) => {
        const lastError = chrome.runtime.lastError;
        if (lastError) {
          resolve({ ok: false, error: lastError.message });
          return;
        }
        resolve({ ok: true, result: results?.[0]?.result || null });
      }
    );
  });
}

// ---------- rendering: shared pieces ----------

function tabLetters(origin) {
  try {
    const host = new URL(origin).hostname.replace(/^www\./, "");
    return host.slice(0, 2).toLowerCase();
  } catch (_) {
    return "??";
  }
}

function renderStatusGrid(host, bridge) {
  const grid = el("section", "status-grid");
  grid.appendChild(renderStatusCard("Native host", host.value, host.variant));
  grid.appendChild(renderStatusCard("App / vault bridge", bridge.value, bridge.variant));
  return grid;
}

function renderStatusCard(label, value, variant) {
  const card = el("article", `status-card status-card--${variant}`);
  card.appendChild(el("div", "status-label", label));
  card.appendChild(el("div", "status-value", value));
  return card;
}

function renderTabRow(origin, meta, { onRefresh } = {}) {
  const row = el("div", "tab-row");
  const avatar = el("span", "tab-avatar", tabLetters(origin));
  const info = el("div", "tab-info");
  info.appendChild(el("div", "tab-title", origin.replace(/^https?:\/\//, "")));
  info.appendChild(el("div", "tab-meta", meta));
  row.appendChild(avatar);
  row.appendChild(info);
  if (onRefresh) {
    const action = el("button", "tab-action", "Refresh");
    action.type = "button";
    action.addEventListener("click", onRefresh);
    row.appendChild(action);
  }
  return row;
}

function resultTitle(result) {
  const title = (result.title || "").trim();
  const service = (result.displayService || "").trim();
  if (title && service) {
    return `${title} · ${service}`;
  }
  return title || service || "Untitled entry";
}

function resultMeta(result) {
  const username = (result.displayUsername || "").trim();
  if (username) return username;
  // Avoid repeating displayService here: resultTitle() already folds it
  // in whenever both title and service are present.
  const title = (result.title || "").trim();
  const service = (result.displayService || "").trim();
  return title && service ? "" : service;
}

function renderMatchRow(result, kind, { onFill, onAsk } = {}) {
  const row = el("div", "match-row");
  const info = el("div", "match-info");
  info.appendChild(el("div", "match-title", resultTitle(result)));
  info.appendChild(el("div", "match-meta", resultMeta(result)));
  row.appendChild(info);

  // AC5 / T13: `strong` and `possible` are TEXT, never colour-only —
  // this span's textContent is the actual signal, the class only tints it.
  const tag = el("span", `match-tag match-tag--${kind}`, kind);
  row.appendChild(tag);

  // __fillable is set by callers from the background/native-host response
  // (fillAvailable AND the per-entry fillEligible). Only an explicit `false`
  // disables the button — undefined (e.g. no signal attached) defaults to
  // available, matching prior behavior for callers that don't yet compute it.
  if (kind === "strong" && result.__fillable === false) {
    // 009 / A014: a strong match is a *host* match, so it may still fail the
    // origin-bound reveal policy (scheme, port, or a domain-only entry on a
    // page the policy does not admit). Say so up front instead of offering a
    // Fill button that will be refused.
    row.appendChild(el("span", "match-note", "Open Custode"));
  } else if (kind === "strong" && onFill) {
    const button = el("button", "fill-btn", "Fill");
    button.type = "button";
    button.addEventListener("click", () => onFill(result));
    row.appendChild(button);
  } else if (kind === "possible" && onAsk) {
    const button = el("button", "ask-btn", "Ask app");
    button.type = "button";
    button.addEventListener("click", () => onAsk(result));
    row.appendChild(button);
  }

  return row;
}

function renderMatchGroup(label, count, rows) {
  const wrapper = el("div");
  wrapper.appendChild(el("div", "match-group-label", `${label} · ${count}`));
  const list = el("div", "match-list");
  rows.forEach((row) => list.appendChild(row));
  wrapper.appendChild(list);
  return wrapper;
}

function renderSearchRow(placeholder, initialValue) {
  const row = el("div", "search-row");
  row.appendChild(searchIconSvg());
  const input = document.createElement("input");
  input.type = "search";
  input.id = "searchInput";
  input.autocomplete = "off";
  input.spellcheck = false;
  input.placeholder = placeholder;
  if (initialValue) input.value = initialValue;
  row.appendChild(input);
  return { row, input };
}

function renderFooterNote(text) {
  return el("p", "footer-note", text);
}

function renderStatusMessage(text, isError) {
  return el("p", `status-message${isError ? " status-message--error" : ""}`, text || "");
}

// ---------- rendering: the four states ----------

function renderHostMissingState() {
  setMarkDim(true);
  clearBody();
  bodyElement.appendChild(
    renderStatusGrid(
      { value: "Not found", variant: "warn" },
      { value: "Unknown", variant: "neutral" }
    )
  );
  bodyElement.appendChild(
    el(
      "p",
      "host-missing-text",
      "The messaging host isn\u2019t registered for this browser. Custode\u2019s desktop app can walk you through it in Desktop browser extension."
    )
  );
  const actions = el("div", "action-row");
  const showMe = el("button", "primary-pill-btn", "Show me how");
  showMe.type = "button";
  showMe.addEventListener("click", () => {
    chrome.tabs.create({
      url: "https://github.com/camillobucciarelli/key-vault-password-manager/blob/main/docs/desktop_browser_autofill.md",
    }); // Deep link to the native-host setup doc (no in-app browser-setup screen to link to yet).
  });
  const checkAgain = el("button", "secondary-pill-btn", "Check again");
  checkAgain.type = "button";
  checkAgain.addEventListener("click", () => void initializePopup());
  actions.appendChild(showMe);
  actions.appendChild(checkAgain);
  bodyElement.appendChild(actions);
}

function renderLockedState() {
  setMarkDim(true);
  clearBody();
  bodyElement.appendChild(
    renderStatusGrid(
      { value: "Connected", variant: "ok" },
      { value: "Locked", variant: "warn" }
    )
  );
  const warning = el("div", "locked-warning");
  warning.appendChild(lockIconSvg());
  const p = document.createElement("p");
  p.textContent = "Custode is locked. Unlock the desktop app to search and fill.";
  warning.appendChild(p);
  bodyElement.appendChild(warning);

  const open = el("button", "primary-pill-btn", "Refresh status");
  open.type = "button";
  open.style.width = "100%";
  open.addEventListener("click", () => void initializePopup());
  bodyElement.appendChild(open);
}

async function fillCredential(entryId, origin) {
  if (inFlight) return;
  const tab = currentTab;
  if (!tab?.id || !origin) {
    return;
  }

  inFlight = true;
  const message = renderStatusMessage("Requesting one-shot fill\u2026");
  bodyElement.appendChild(message);

  let username = null;
  let password = null;
  let response = null;
  try {
    response = await sendExtensionMessage({
      type: "KEYVAULT_V2_REVEAL_FOR_FILL",
      entryId,
      origin,
    });
    if (!response?.ok) {
      message.textContent = errorText(response, "Unable to reveal credential for this site.");
      message.className = "status-message status-message--error";
      return;
    }

    username = typeof response.data?.username === "string" ? response.data.username : "";
    password = typeof response.data?.password === "string" ? response.data.password : "";
    if (!password) {
      message.textContent = "Credential did not include a fillable password.";
      message.className = "status-message status-message--error";
      return;
    }

    const fillResult = await executeFill(tab.id, username, password);
    if (!fillResult.ok || !fillResult.result?.filled) {
      message.textContent = "Unable to fill this page.";
      message.className = "status-message status-message--error";
      return;
    }
    message.textContent = "Filled current page. Password was not stored by the extension.";
  } finally {
    if (response?.data) {
      response.data.username = "";
      response.data.password = "";
    }
    username = null;
    password = null;
    response = null;
    inFlight = false;
  }
}

async function createPendingAssociation(entryId, origin) {
  if (!origin || inFlight) return;
  inFlight = true;
  const message = renderStatusMessage("Creating pending association\u2026");
  bodyElement.appendChild(message);
  try {
    const response = await sendExtensionMessage({
      type: "KEYVAULT_V2_CREATE_PENDING_ASSOCIATION",
      entryId,
      url: origin,
    });
    if (!response?.ok) {
      message.textContent = errorText(response, "Unable to create pending association.");
      message.className = "status-message status-message--error";
      return;
    }
    message.textContent = "Pending association saved. Confirm it in Custode desktop.";
  } finally {
    inFlight = false;
  }
}

async function searchMetadata(query) {
  if (inFlight) return;
  inFlight = true;
  try {
    const response = await sendExtensionMessage({
      type: "KEYVAULT_V2_SEARCH_CREDENTIALS",
      query: query || "",
      url: currentTab?.origin || null,
      limit: 25,
    });
    if (!response?.ok) {
      return;
    }
    // Manual search never gets a strong/possible classification from the
    // native host (searchCredentials always returns fillAvailable: false and
    // an unclassified `results` list — see tool/native_host_protocol.dart
    // _searchCredentialsResponse). A free-text match also lacks the
    // host-exact guarantee an automatic tab match has, so every result here
    // is treated as "possible" (Ask app / pending association), never
    // "strong" (Fill).
    renderResultsIntoMatchArea([], response.data?.results || []);
  } finally {
    inFlight = false;
  }
}

let matchAreaElement = null;

function renderResultsIntoMatchArea(strong, possible) {
  if (!matchAreaElement) return;
  matchAreaElement.textContent = "";

  if (strong.length === 0 && possible.length === 0) {
    matchAreaElement.appendChild(
      el("p", "host-missing-text", "No match. Selecting a manual search result creates a pending association for app confirmation.")
    );
    return;
  }

  if (strong.length > 0) {
    matchAreaElement.appendChild(
      renderMatchGroup(
        "Matches",
        strong.length,
        strong.map((result) =>
          renderMatchRow(result, "strong", {
            onFill: (r) => void fillCredential(r.entryId, currentTab?.origin),
          })
        )
      )
    );
  }
  if (possible.length > 0) {
    // createPendingAssociation() is a silent no-op without an origin (no
    // valid URL on the active tab, e.g. a browser-internal page) — hide the
    // "Ask app" button rather than render one that does nothing on click.
    const originAvailable = Boolean(currentTab?.origin);
    matchAreaElement.appendChild(
      renderMatchGroup(
        "Possible",
        possible.length,
        possible.map((result) =>
          renderMatchRow(result, "possible", {
            onAsk: originAvailable
              ? (r) => void createPendingAssociation(r.entryId, currentTab?.origin)
              : null,
          })
        )
      )
    );
  }
}

async function reportMatchCountForBadge(tabId, strongCount, possibleCount) {
  if (typeof tabId !== "number") return;
  // Fire-and-forget: background.js persists this in chrome.storage and
  // re-derives the badge from there (T14 — never worker-memory-only).
  void sendExtensionMessage({
    type: "KEYVAULT_V2_REPORT_MATCH_COUNT",
    tabId,
    count: strongCount + possibleCount,
  });
}

async function renderMatchesState(tab, origin, response) {
  setMarkDim(false);
  clearBody();

  const strong = response.data?.strongMatches || [];
  const possible = response.data?.possibleMatches || [];
  const fillAvailable = response.data?.fillAvailable === true;

  bodyElement.appendChild(
    renderStatusGrid(
      { value: "Connected", variant: "ok" },
      { value: "Unlocked", variant: "ok" }
    )
  );

  const meta = strong.length > 0 ? "Current tab" : "No exact match";
  bodyElement.appendChild(
    renderTabRow(origin, meta, { onRefresh: () => void initializePopup() })
  );

  matchAreaElement = el("div");
  bodyElement.appendChild(matchAreaElement);
  renderResultsIntoMatchArea(
    strong.map((r) => ({
      ...r,
      __fillable: fillAvailable && r.fillEligible !== false,
    })),
    possible
  );

  const { row: searchRow, input } = renderSearchRow("Search title, user, service");
  bodyElement.appendChild(searchRow);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") void searchMetadata(input.value);
  });

  bodyElement.appendChild(
    renderFooterNote(
      "Passwords are revealed only when you click Fill on an exact match, and dropped right after."
    )
  );

  void reportMatchCountForBadge(tab.id, strong.length, possible.length);
}

// ---------- 009 Slice C — the single global overlay switch ----------
//
// Slice A2 shipped this as a PER-SITE control: the user had to open the popup
// and click "Turn on" once for every site they wanted the overlay on. That is
// unusable in practice, so Slice C replaces it with one switch that asks for
// the broad optional host permission once.
//
// The copy below is deliberately explicit about the size of that grant. It
// says what is being handed over (every http(s) site), why it is needed (the
// overlay is a content script and Chromium has no "ask me later, per site"
// injection), and what it does NOT imply (the extension does not read page
// content, and the app still only ever reveals credentials for an exact
// origin match). Understating a broad permission is the failure mode worth
// engineering against here.

const overlaySecurity = globalThis.CustodeOverlaySecurity;

// Transient, popup-lifetime only: a declined permission prompt is not durable
// state and must never be persisted.
let overlayRequestDenied = false;

const OVERLAY_TITLE = "In-page autofill overlay";

function overlayControlCopy(state) {
  switch (state) {
    case "unsupported":
      // The switch is OFF and this page is not an http(s) page. Turning it on
      // from here would visibly do nothing, so the honest answer is where it
      // works — and the switch is still offered, because the grant is global.
      return {
        title: OVERLAY_TITLE,
        meta: "Off. It appears on http(s) pages; this page is not one.",
        action: "Turn on",
      };
    case "reconciling":
      return { title: OVERLAY_TITLE, meta: "Checking\u2026", action: null };
    case "enabled":
      return {
        title: OVERLAY_TITLE,
        meta: "On for all sites. Custode still shows only exact matches.",
        action: "Turn off",
      };
    case "denied":
      return {
        title: OVERLAY_TITLE,
        meta: "Access was declined. Nothing was saved or turned on.",
        action: "Try again",
      };
    default:
      return {
        title: OVERLAY_TITLE,
        meta: "Off. Turning it on asks for access to all http(s) sites.",
        action: "Turn on",
      };
  }
}

/**
 * The one honest sentence about what the broad grant does and does not mean.
 * Rendered under the switch in every state, so it is present when the user is
 * deciding, not only after they have decided.
 */
const OVERLAY_SCOPE_NOTE =
  "The overlay needs access to every http(s) site because Chrome cannot grant " +
  "it site by site as you browse. It does not read page content: it shows a " +
  "suggestion box next to a login field, and only for entries already saved " +
  "in your vault that match the exact site, scheme and port.";

function renderOverlayControl(state, onToggle) {
  const copy = overlayControlCopy(state);
  const wrapper = el("div");
  const row = el("div", "tab-row");
  const info = el("div", "tab-info");
  info.appendChild(el("div", "tab-title", copy.title));
  info.appendChild(el("div", "tab-meta", copy.meta));
  row.appendChild(info);
  if (copy.action) {
    const button = el("button", "tab-action", copy.action);
    button.type = "button";
    button.id = "overlayToggle";
    button.addEventListener("click", onToggle);
    row.appendChild(button);
  }
  wrapper.appendChild(row);
  wrapper.appendChild(renderFooterNote(OVERLAY_SCOPE_NOTE));
  return wrapper;
}

async function sendOverlayMessage(type, fields) {
  return sendExtensionMessage({
    channel: overlaySecurity.CHANNEL,
    version: overlaySecurity.MESSAGE_VERSION,
    type,
    ...fields,
  });
}

/**
 * The permission request lives here and nowhere else: it needs the popup's user
 * gesture, so it is issued synchronously from the click handler before any
 * await. Only after the browser reports a grant does the background worker get
 * asked to persist the opt-in — and it re-verifies the grant before writing.
 *
 * SLICE C: one request for the whole broad set, taken from the shipped
 * constant rather than spelled here, so the popup can never ask for something
 * the manifest does not offer as optional.
 */
function requestOverlayPermission() {
  return chrome.permissions
    .request({ origins: [...overlaySecurity.GLOBAL_PERMISSION_PATTERNS] })
    .catch(() => false);
}

async function appendOverlayControl() {
  const tab = await getActiveTab();
  // The tab is OPTIONAL context now, never a precondition: `tabId` drives the
  // courtesy injection of the page the user is looking at, and `tabUrl` only
  // decides whether the off state says "this page is not an http(s) page".
  const tabId = typeof tab?.id === "number" ? tab.id : null;
  const tabUrl = typeof tab?.url === "string" && tab.url.length > 0 ? tab.url : null;

  const response = await sendOverlayMessage("getSiteState", { tabId, tabUrl });
  const state =
    response?.ok === true
      ? response.state
      : overlayRequestDenied
        ? "denied"
        : "disabled";

  bodyElement.appendChild(
    renderOverlayControl(state, () => {
      void toggleOverlay(state, tabId);
    })
  );
}

/**
 * macOS grant race: the OS-level permission prompt CLOSES this popup, killing
 * the continuation below before `setSiteState enable` can be sent — the first
 * Allow used to leave the site Off. The durable one-shot intent written here
 * (under the user gesture, BEFORE the request) lets the worker's
 * `permissions.onAdded` listener finish the enable instead.
 *
 * `chrome.storage.session` on purpose: it dies with the browser, and its
 * default access level (TRUSTED_CONTEXTS) already covers popup + worker while
 * excluding content scripts — no `setAccessLevel` call needed.
 */
function writeEnableIntent(tabId) {
  return chrome.storage.session
    .set({
      [overlaySecurity.OVERLAY_ENABLE_INTENT_KEY]: {
        tabId,
        createdAt: Date.now(),
      },
    })
    .catch(() => {});
}

function clearEnableIntent() {
  return chrome.storage.session
    .remove(overlaySecurity.OVERLAY_ENABLE_INTENT_KEY)
    .catch(() => {});
}

async function toggleOverlay(state, tabId) {
  if (state === "enabled") {
    overlayRequestDenied = false;
    // Turning OFF never depends on the tab, the page kind, or the permission
    // still being held: withdrawing consent must work from wherever the user
    // happens to be when they change their mind.
    await sendOverlayMessage("setSiteState", { tabId, enabled: false });
    void initializePopup();
    return;
  }

  // Not awaited before the request on purpose: `permissions.request` must stay
  // synchronous with the click gesture. The storage IPC completes long before
  // the user can answer the prompt, so the onAdded consumer always sees it.
  void writeEnableIntent(tabId);
  const granted = await requestOverlayPermission();
  if (granted !== true) {
    // Declined (or the request failed): the intent must not linger for a later
    // unrelated grant. TTL is the backstop, this is the prompt cleanup.
    void clearEnableIntent();
    overlayRequestDenied = true;
    void initializePopup();
    return;
  }
  overlayRequestDenied = false;
  await sendOverlayMessage("setSiteState", { tabId, enabled: true });
  // Popup survived (Linux/Windows): the enable completed here, burn the
  // intent. If the worker's onAdded path consumed it first, both ran through
  // the same idempotent enable — one coherent outcome either way.
  void clearEnableIntent();
  void initializePopup();
}

// ---------- entry point ----------

async function initializePopup() {
  void refreshBadgeForActiveTab();
  await renderPopupState();
  await appendOverlayControl();
}

// Fire-and-forget: the toolbar badge/icon otherwise only re-derives on
// tabs.onActivated/onUpdated (background.js T14), so it can lag a lock/
// unlock until the next tab event. Opening the popup is itself a moment the
// user is looking at the icon, so nudge a refresh — never blocks popup
// render, and a failure here is invisible on purpose (the popup's own
// status fetch below is the source of truth for what's on screen).
async function refreshBadgeForActiveTab() {
  const tab = await getActiveTab();
  if (!tab?.id) return;
  try {
    await sendExtensionMessage({ type: "KEYVAULT_V2_REFRESH_BADGE", tabId: tab.id });
  } catch (_) {
    // Best-effort only.
  }
}

async function renderPopupState() {
  setMarkDim(true);
  clearBody();
  bodyElement.appendChild(renderStatusMessage("Checking native host\u2026"));

  const statusResponse = await sendExtensionMessage({ type: "KEYVAULT_V2_STATUS" });
  if (!statusResponse?.ok) {
    renderHostMissingState();
    return;
  }

  const vaultConnected = statusResponse.data?.vault?.connected === true;
  if (!vaultConnected) {
    renderLockedState();
    return;
  }

  const tab = await getActiveTab();
  const origin = activeTabOrigin(tab?.url || "");
  if (!tab?.id || !origin) {
    setMarkDim(false);
    clearBody();
    bodyElement.appendChild(
      renderStatusGrid(
        { value: "Connected", variant: "ok" },
        { value: "Unlocked", variant: "ok" }
      )
    );
    bodyElement.appendChild(
      el("p", "host-missing-text", "Open an http(s) page to search Custode for this site.")
    );
    const { row: searchRow, input } = renderSearchRow("Search title, user, service");
    bodyElement.appendChild(searchRow);
    matchAreaElement = el("div");
    bodyElement.appendChild(matchAreaElement);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") void searchMetadata(input.value);
    });
    bodyElement.appendChild(
      renderFooterNote("Passwords are revealed only when you click Fill on an exact match, and dropped right after.")
    );
    return;
  }

  currentTab = { id: tab.id, origin, title: tab.title || "" };

  const queryResponse = await sendExtensionMessage({
    type: "KEYVAULT_V2_QUERY_CREDENTIALS",
    url: origin,
    title: tab.title || "",
    limit: 10,
  });

  if (!queryResponse?.ok) {
    // Host and vault were confirmed reachable/unlocked just above; this is a
    // separate, likely-transient failure. Don't reuse renderHostMissingState()
    // here — it would falsely claim the host isn't registered.
    setMarkDim(false);
    clearBody();
    bodyElement.appendChild(
      renderStatusGrid(
        { value: "Connected", variant: "ok" },
        { value: "Unlocked", variant: "ok" }
      )
    );
    bodyElement.appendChild(
      renderStatusMessage(
        errorText(queryResponse, "Unable to load matches for this page. Try again."),
        true
      )
    );
    const actions = el("div", "action-row");
    const tryAgain = el("button", "secondary-pill-btn", "Try again");
    tryAgain.type = "button";
    tryAgain.addEventListener("click", () => void initializePopup());
    actions.appendChild(tryAgain);
    bodyElement.appendChild(actions);
    return;
  }

  await renderMatchesState(tab, origin, queryResponse);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => void initializePopup(), { once: true });
} else {
  void initializePopup();
}
