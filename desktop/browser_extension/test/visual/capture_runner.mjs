#!/usr/bin/env node
// 009 A041 — canonical visual-baseline capture/verify runner.
//
// Runs INSIDE the pinned OCI container only (launched by
// ../run_visual_baselines.sh, which pins the image by immutable digest).
// Everything here is fail-closed: any environment mismatch — OS, arch,
// timezone, fonts, Chrome archive/binary hash, Chrome version — aborts with a
// clear message before a single pixel is captured. There is no skip path.
//
// Capture is performed TWICE with a fresh browser profile per pass; the two
// passes must produce byte-identical PNGs or the run fails (this is the
// determinism proof, re-established on every run, including under CPU
// emulation). `--approve` promotes pass 1 to `screenshots/expected/` and
// rewrites `visual_baselines_v1.sha256`. `--verify` writes pass 1 to
// `screenshots/actual/` and compares DECODED PIXELS plus the approved hashes
// against the committed expected files; it never touches expected/.
//
// The unpacked extension under test is assembled in a throwaway directory
// from the UNMODIFIED production `overlay_security.js` + `content_overlay.js`
// plus the TEST-ONLY `harness/background_stub.js`. No production file is
// edited and nothing here is ever packaged.

import { createHash } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const VISUAL_DIR = path.dirname(fileURLToPath(import.meta.url));
const TEST_DIR = path.dirname(VISUAL_DIR);
const EXT_DIR = path.dirname(TEST_DIR);
const ENV_MANIFEST_PATH = path.join(TEST_DIR, "visual_environment_v1.json");
const BASELINE_HASH_PATH = path.join(TEST_DIR, "visual_baselines_v1.sha256");
const EXPECTED_DIR = path.join(TEST_DIR, "screenshots", "expected");
const ACTUAL_DIR = path.join(TEST_DIR, "screenshots", "actual");
const CACHE_DIR = process.env.KEYVAULT_VISUAL_CACHE_DIR ?? "/cache";

const PAGE_PORT = 8907;
const PAGE_ORIGIN = `http://127.0.0.1:${PAGE_PORT}`;

const fail = (message) => {
  console.error(`FAIL: ${message}`);
  process.exit(1);
};

// ---------------------------------------------------------------------------
// Scenario table — one row per approved baseline (spec.md visual inventory).
// `status` is the exact overlay status text the runner waits for; it mirrors
// the production STATE_TEXT map in content_overlay.js. If production copy
// changes, the wait times out and the run fails loudly.
// ---------------------------------------------------------------------------

const STATUS = Object.freeze({
  matches: "2 Custode suggestions",
  possible: "Matches exist but cannot be filled here. Open Custode.",
  "no-matches": "No Custode entries for this site.",
  locked: "Open and unlock Custode.",
  "no-host": "Custode native host is unavailable.",
  "unsupported-frame":
    "The overlay is not available in this frame. Copy your login from the Custode app.",
  loading: "Loading Custode suggestions\u2026",
  "stale-retry": "Custode session changed.",
  timeout: "Custode did not respond in time.",
});

const s = (file, scenario, theme, width, height, dpr, anchor) => ({
  file,
  scenario,
  theme,
  width,
  height,
  dpr,
  anchor,
  status: STATUS[scenario],
});

const SCENARIOS = Object.freeze([
  s("overlay-chrome-1440x900-dpr1-light-matches.png", "matches", "light", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-dark-matches.png", "matches", "dark", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-light-possible.png", "possible", "light", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-dark-possible.png", "possible", "dark", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-light-no-matches.png", "no-matches", "light", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-dark-no-matches.png", "no-matches", "dark", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-light-locked.png", "locked", "light", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-dark-locked.png", "locked", "dark", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-light-no-host.png", "no-host", "light", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-dark-no-host.png", "no-host", "dark", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-light-unsupported-frame.png", "unsupported-frame", "light", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-dark-unsupported-frame.png", "unsupported-frame", "dark", 1440, 900, 1, "top"),
  s("overlay-chrome-390x844-dpr2-light-matches-below.png", "matches", "light", 390, 844, 2, "top"),
  s("overlay-chrome-390x844-dpr2-dark-matches-below.png", "matches", "dark", 390, 844, 2, "top"),
  s("overlay-chrome-1024x768-dpr1-light-matches-flipped.png", "matches", "light", 1024, 768, 1, "bottom"),
  s("overlay-chrome-1440x900-dpr1-light-loading.png", "loading", "light", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-dark-stale-retry.png", "stale-retry", "dark", 1440, 900, 1, "top"),
  s("overlay-chrome-1440x900-dpr1-light-timeout.png", "timeout", "light", 1440, 900, 1, "top"),
]);

const sha256 = (buffer) => createHash("sha256").update(buffer).digest("hex");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// Environment verification — fail closed, never skip.
// ---------------------------------------------------------------------------

const loadEnvManifest = () => {
  const manifest = JSON.parse(fs.readFileSync(ENV_MANIFEST_PATH, "utf8"));
  if (manifest.version !== 1) fail("visual_environment_v1.json version is not 1");
  return manifest;
};

const verifyEnvironment = (env) => {
  if (process.platform !== "linux" || os.arch() !== "x64") {
    fail(
      `environment mismatch: runner requires linux x86_64, got ${process.platform} ${os.arch()}. ` +
        "Run through ./desktop/browser_extension/test/run_visual_baselines.sh."
    );
  }
  const osRelease = fs.readFileSync("/etc/os-release", "utf8");
  const idMatch = /^ID=(.*)$/m.exec(osRelease)?.[1]?.replaceAll('"', "");
  const versionMatch = /^VERSION_ID=(.*)$/m.exec(osRelease)?.[1]?.replaceAll('"', "");
  if (
    idMatch !== env.platform.osRelease.id ||
    versionMatch !== env.platform.osRelease.versionId
  ) {
    fail(
      `environment mismatch: os-release ${idMatch} ${versionMatch}, ` +
        `manifest requires ${env.platform.osRelease.id} ${env.platform.osRelease.versionId}. ` +
        "The container image is not the pinned digest."
    );
  }
  if (process.env.TZ !== env.timezone) {
    fail(`environment mismatch: TZ=${process.env.TZ}, manifest requires ${env.timezone}`);
  }
  const resolvedTz = new Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (resolvedTz !== env.timezone) {
    fail(`environment mismatch: resolved timezone ${resolvedTz} != ${env.timezone}`);
  }
  if (!env.rendering.flags.includes(`--lang=${env.locale}`)) {
    fail("environment manifest is inconsistent: rendering flags do not pin the locale");
  }

  // Fonts: recompute the aggregate hash over every unique fontconfig file.
  const fontList = execFileSync("fc-list", ["--format", "%{file}\n"], { encoding: "utf8" });
  const fontFiles = [...new Set(fontList.split("\n").filter((line) => line.length > 0))].sort();
  const lines = fontFiles.map((file) => `${file} ${sha256(fs.readFileSync(file))}`);
  const aggregate = sha256(Buffer.from(lines.sort().join("\n") + "\n", "utf8"));
  if (fontFiles.length !== env.fonts.fileCount || aggregate !== env.fonts.aggregateSha256) {
    fail(
      `environment mismatch: font set hash ${aggregate} (${fontFiles.length} files), ` +
        `manifest requires ${env.fonts.aggregateSha256} (${env.fonts.fileCount} files)`
    );
  }
};

// ---------------------------------------------------------------------------
// Chrome for Testing — pinned download, hash-verified, cached.
// ---------------------------------------------------------------------------

const ensureChrome = async (env) => {
  const { version, archiveUrl, archiveSha256, binaryPath, binarySha256 } = env.browser;
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const archivePath = path.join(CACHE_DIR, `chrome-linux64-${version}.zip`);

  if (!fs.existsSync(archivePath) || sha256(fs.readFileSync(archivePath)) !== archiveSha256) {
    console.error(`downloading Chrome for Testing ${version} ...`);
    const response = await fetch(archiveUrl);
    if (!response.ok) fail(`Chrome archive download failed: HTTP ${response.status}`);
    fs.writeFileSync(archivePath, Buffer.from(await response.arrayBuffer()));
  }
  const archiveHash = sha256(fs.readFileSync(archivePath));
  if (archiveHash !== archiveSha256) {
    fail(
      `environment mismatch: Chrome archive sha256 ${archiveHash}, ` +
        `manifest requires ${archiveSha256}. Refusing to run an unpinned browser.`
    );
  }

  const extractDir = path.join(CACHE_DIR, `chrome-extract-${archiveSha256.slice(0, 16)}`);
  const binary = path.join(extractDir, binaryPath);
  if (!fs.existsSync(binary)) {
    fs.rmSync(extractDir, { recursive: true, force: true });
    fs.mkdirSync(extractDir, { recursive: true });
    execFileSync("python3", ["-m", "zipfile", "-e", archivePath, extractDir]);
    // python3 -m zipfile does not preserve the executable bit.
    for (const name of fs.readdirSync(path.dirname(binary))) {
      fs.chmodSync(path.join(path.dirname(binary), name), 0o755);
    }
  }
  const binaryHash = sha256(fs.readFileSync(binary));
  if (binaryHash !== binarySha256) {
    fail(
      `environment mismatch: Chrome binary sha256 ${binaryHash}, manifest requires ${binarySha256}`
    );
  }
  const reported = execFileSync(binary, ["--version"], { encoding: "utf8" }).trim();
  if (!reported.includes(version)) {
    fail(`environment mismatch: chrome --version reported "${reported}", expected ${version}`);
  }
  return binary;
};

// ---------------------------------------------------------------------------
// Throwaway unpacked test extension: production overlay files + test stub.
// ---------------------------------------------------------------------------

const assembleExtension = (workDir) => {
  const extension = path.join(workDir, "extension");
  fs.mkdirSync(extension, { recursive: true });
  for (const file of ["overlay_security.js", "content_overlay.js"]) {
    fs.copyFileSync(path.join(EXT_DIR, file), path.join(extension, file));
  }
  fs.copyFileSync(
    path.join(VISUAL_DIR, "harness", "background_stub.js"),
    path.join(extension, "background_stub.js")
  );
  fs.writeFileSync(
    path.join(extension, "manifest.json"),
    JSON.stringify(
      {
        manifest_version: 3,
        name: "Custode visual harness (test only, never packaged)",
        version: "1.0",
        background: { service_worker: "background_stub.js" },
        content_scripts: [
          {
            matches: ["http://127.0.0.1/*"],
            js: ["overlay_security.js", "content_overlay.js"],
            run_at: "document_idle",
          },
        ],
      },
      null,
      2
    )
  );
  return extension;
};

const startPageServer = () => {
  const pageHtml = fs.readFileSync(path.join(VISUAL_DIR, "harness", "page.html"));
  const server = http.createServer((request, response) => {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(pageHtml);
  });
  return new Promise((resolve) => {
    server.listen(PAGE_PORT, "127.0.0.1", () => resolve(server));
  });
};

// ---------------------------------------------------------------------------
// Minimal CDP client over the Node >= 22 global WebSocket.
// ---------------------------------------------------------------------------

class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.eventWaiters = [];
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== undefined) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(`${pending.method}: ${message.error.message}`));
        else pending.resolve(message.result);
        return;
      }
      this.eventWaiters = this.eventWaiters.filter((waiter) => {
        if (waiter.method !== message.method || waiter.sessionId !== message.sessionId) return true;
        waiter.resolve(message.params);
        return false;
      });
    });
  }

  static connect(url) {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      socket.addEventListener("open", () => resolve(new Cdp(socket)));
      socket.addEventListener("error", () => reject(new Error(`CDP connect failed: ${url}`)));
    });
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, 120000);
      this.pending.set(id, {
        method,
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
      this.socket.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }

  waitEvent(method, sessionId) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`CDP event timed out: ${method}`)),
        120000
      );
      this.eventWaiters.push({
        method,
        sessionId,
        resolve: (params) => {
          clearTimeout(timer);
          resolve(params);
        },
      });
    });
  }

  close() {
    this.socket.close();
  }
}

const launchChrome = (binary, flags, extensionDir, profileDir) =>
  new Promise((resolve, reject) => {
    const args = [
      ...flags,
      `--user-data-dir=${profileDir}`,
      "--remote-allow-origins=*",
      `--load-extension=${extensionDir}`,
      "--remote-debugging-port=0",
      "about:blank",
    ];
    const child = spawn(binary, args, { stdio: ["ignore", "ignore", "pipe"] });
    console.error("  chrome launched, waiting for DevTools endpoint ...");
    let stderr = "";
    const onData = (chunk) => {
      stderr += chunk.toString();
      const match = /DevTools listening on (ws:\/\/\S+)/.exec(stderr);
      if (match) {
        child.stderr.off("data", onData);
        resolve({ child, wsUrl: match[1] });
      }
    };
    child.stderr.on("data", onData);
    child.on("exit", (code) => reject(new Error(`chrome exited early (${code}): ${stderr}`)));
    setTimeout(() => reject(new Error(`chrome did not expose DevTools: ${stderr}`)), 30000);
  });

// ---------------------------------------------------------------------------
// Per-scenario capture.
// ---------------------------------------------------------------------------

const collectTexts = (node, out) => {
  if (!node) return;
  if (node.nodeName === "#text" && typeof node.nodeValue === "string") out.push(node.nodeValue);
  for (const child of node.children ?? []) collectTexts(child, out);
  for (const shadow of node.shadowRoots ?? []) collectTexts(shadow, out);
  if (node.contentDocument) collectTexts(node.contentDocument, out);
};

const captureScenario = async (cdp, scenario) => {
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  const send = (method, params) => cdp.send(method, params, sessionId);

  await send("Page.enable");
  await send("DOM.enable");
  await send("Runtime.enable");
  await send("Emulation.setFocusEmulationEnabled", { enabled: true });
  await send("Emulation.setDeviceMetricsOverride", {
    width: scenario.width,
    height: scenario.height,
    deviceScaleFactor: scenario.dpr,
    mobile: false,
  });
  await send("Emulation.setEmulatedMedia", {
    features: [
      { name: "prefers-color-scheme", value: scenario.theme },
      { name: "prefers-reduced-motion", value: "reduce" },
    ],
  });

  const loaded = cdp.waitEvent("Page.loadEventFired", sessionId);
  const url = `${PAGE_ORIGIN}/page.html?scenario=${scenario.scenario}&anchor=${scenario.anchor}`;
  await send("Page.navigate", { url });
  await loaded;
  await send("Runtime.evaluate", {
    expression: "document.fonts.ready.then(() => true)",
    awaitPromise: true,
  });

  // Focus the password anchor until the overlay host exists. The content
  // script bootstraps asynchronously; a focus landing before its listeners
  // attach is re-driven by a blur + refocus on the next attempt.
  const focusExpression = `(() => {
    const el = document.getElementById("password");
    const hostPresent = () =>
      Array.from(document.body.children).some((c) => c.style && c.style.position === "fixed");
    if (hostPresent()) return true;
    if (document.activeElement === el) el.blur();
    el.focus();
    return hostPresent();
  })()`;
  let hostSeen = false;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const { result } = await send("Runtime.evaluate", { expression: focusExpression });
    if (result.value === true) {
      hostSeen = true;
      break;
    }
    await sleep(100);
  }
  if (!hostSeen) throw new Error(`${scenario.file}: overlay host never appeared`);

  // Wait for the exact status text of this scenario inside the closed shadow
  // root (CDP pierces closed shadow roots; page JS cannot, by design).
  let statusSeen = false;
  for (let attempt = 0; attempt < 150; attempt += 1) {
    const { root } = await send("DOM.getDocument", { depth: -1, pierce: true });
    const texts = [];
    collectTexts(root, texts);
    if (texts.some((text) => text.includes(scenario.status))) {
      statusSeen = true;
      break;
    }
    await sleep(100);
  }
  if (!statusSeen) {
    throw new Error(
      `${scenario.file}: status text "${scenario.status}" never rendered (production copy changed?)`
    );
  }

  await send("Runtime.evaluate", {
    expression:
      "new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))",
    awaitPromise: true,
  });

  const { data } = await send("Page.captureScreenshot", { format: "png" });
  await cdp.send("Target.closeTarget", { targetId });
  return Buffer.from(data, "base64");
};

const capturePass = async (chromeBinary, flags, extensionDir, passLabel) => {
  const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), `kv-visual-profile-${passLabel}-`));
  const { child, wsUrl } = await launchChrome(chromeBinary, flags, extensionDir, profileDir);
  console.error(`  [pass ${passLabel}] DevTools at ${wsUrl}`);
  const shots = new Map();
  try {
    const cdp = await Cdp.connect(wsUrl);
    console.error(`  [pass ${passLabel}] CDP connected`);
    for (const scenario of SCENARIOS) {
      console.error(`  [pass ${passLabel}] capturing ${scenario.file} ...`);
      shots.set(scenario.file, await captureScenario(cdp, scenario));
      console.error(`  [pass ${passLabel}] captured ${scenario.file}`);
    }
    cdp.close();
  } finally {
    child.kill("SIGKILL");
    fs.rmSync(profileDir, { recursive: true, force: true });
  }
  return shots;
};

// ---------------------------------------------------------------------------
// PNG decode (8-bit RGB/RGBA, non-interlaced) for pixel-level comparison.
// ---------------------------------------------------------------------------

const decodePng = (buffer, label) => {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (!buffer.subarray(0, 8).equals(signature)) fail(`${label}: not a PNG`);
  let offset = 8;
  let header = null;
  const idat = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      header = {
        width: data.readUInt32BE(0),
        height: data.readUInt32BE(4),
        bitDepth: data[8],
        colorType: data[9],
        interlace: data[12],
      };
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") {
      break;
    }
    offset += 12 + length;
  }
  if (!header) fail(`${label}: PNG missing IHDR`);
  if (header.bitDepth !== 8 || ![2, 6].includes(header.colorType) || header.interlace !== 0) {
    fail(`${label}: unsupported PNG format (depth ${header.bitDepth}, color ${header.colorType})`);
  }
  const bpp = header.colorType === 6 ? 4 : 3;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = header.width * bpp;
  const pixels = Buffer.alloc(header.height * stride);
  for (let y = 0; y < header.height; y += 1) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const out = pixels.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? pixels.subarray((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x += 1) {
      const left = x >= bpp ? out[x - bpp] : 0;
      const up = prev ? prev[x] : 0;
      const upLeft = prev && x >= bpp ? prev[x - bpp] : 0;
      let value = line[x];
      if (filter === 1) value += left;
      else if (filter === 2) value += up;
      else if (filter === 3) value += (left + up) >> 1;
      else if (filter === 4) {
        const p = left + up - upLeft;
        const pa = Math.abs(p - left);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - upLeft);
        value += pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
      } else if (filter !== 0) {
        fail(`${label}: unknown PNG filter ${filter}`);
      }
      out[x] = value & 0xff;
    }
  }
  return { ...header, bpp, pixels };
};

// ---------------------------------------------------------------------------
// Approve / verify.
// ---------------------------------------------------------------------------

const readBaselineHashes = () => {
  if (!fs.existsSync(BASELINE_HASH_PATH)) {
    fail("visual_baselines_v1.sha256 is missing; run --approve first (with design review)");
  }
  const rows = new Map();
  for (const line of fs.readFileSync(BASELINE_HASH_PATH, "utf8").split("\n")) {
    if (line.trim().length === 0) continue;
    const match = /^([0-9a-f]{64})  (\S+)$/.exec(line);
    if (!match) fail(`visual_baselines_v1.sha256 has a malformed row: "${line}"`);
    rows.set(match[2], match[1]);
  }
  return rows;
};

const writeShots = (dir, shots) => {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  for (const [file, buffer] of shots) fs.writeFileSync(path.join(dir, file), buffer);
};

const main = async () => {
  const mode = process.argv[2];
  if (mode !== "--verify" && mode !== "--approve") {
    fail("usage: capture_runner.mjs --verify | --approve");
  }

  const env = loadEnvManifest();
  verifyEnvironment(env);
  console.error("environment lock verified (os/arch/tz/fonts)");
  const chromeBinary = await ensureChrome(env);
  console.error("chrome-for-testing archive/binary hashes verified");

  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "kv-visual-"));
  const extensionDir = assembleExtension(workDir);
  const server = await startPageServer();

  let pass1;
  try {
    pass1 = await capturePass(chromeBinary, env.rendering.flags, extensionDir, "1");
    const pass2 = await capturePass(chromeBinary, env.rendering.flags, extensionDir, "2");
    // Determinism proof: both passes byte-identical, every run.
    const unstable = SCENARIOS.filter(
      (scenario) =>
        sha256(pass1.get(scenario.file)) !== sha256(pass2.get(scenario.file))
    ).map((scenario) => scenario.file);
    if (unstable.length > 0) {
      fail(
        `capture is nondeterministic between two passes for: ${unstable.join(", ")}. ` +
          "Refusing to approve/verify; investigate before lowering the bar."
      );
    }
    console.error("determinism: two independent capture passes are byte-identical");
  } finally {
    server.close();
    fs.rmSync(workDir, { recursive: true, force: true });
  }

  if (mode === "--approve") {
    writeShots(EXPECTED_DIR, pass1);
    const lines = [...pass1.entries()]
      .map(([file, buffer]) => `${sha256(buffer)}  ${file}`)
      .sort((a, b) => a.localeCompare(b));
    fs.writeFileSync(BASELINE_HASH_PATH, lines.join("\n") + "\n");
    console.error(`approved ${pass1.size} baselines into screenshots/expected/`);
    console.error("baseline update requires human design review before commit");
    return;
  }

  // --verify: never touches expected/.
  writeShots(ACTUAL_DIR, pass1);
  const approvedHashes = readBaselineHashes();
  const expectedFiles = fs.existsSync(EXPECTED_DIR) ? fs.readdirSync(EXPECTED_DIR).sort() : [];
  const wantedFiles = SCENARIOS.map((scenario) => scenario.file).sort();
  if (JSON.stringify(expectedFiles) !== JSON.stringify(wantedFiles)) {
    fail(
      `screenshots/expected/ does not contain exactly the 18 approved baselines.\n` +
        `  present: ${expectedFiles.join(", ") || "(none)"}`
    );
  }
  if (
    approvedHashes.size !== wantedFiles.length ||
    wantedFiles.some((file) => !approvedHashes.has(file))
  ) {
    fail("visual_baselines_v1.sha256 rows do not match the 18 approved basenames");
  }

  const failures = [];
  for (const scenario of SCENARIOS) {
    const expectedBuffer = fs.readFileSync(path.join(EXPECTED_DIR, scenario.file));
    const expectedHash = sha256(expectedBuffer);
    if (expectedHash !== approvedHashes.get(scenario.file)) {
      failures.push(`${scenario.file}: expected PNG does not match its approved sha256 (unapproved baseline edit)`);
      continue;
    }
    const actualBuffer = pass1.get(scenario.file);
    const expected = decodePng(expectedBuffer, `expected/${scenario.file}`);
    const actual = decodePng(actualBuffer, `actual/${scenario.file}`);
    if (
      expected.width !== actual.width ||
      expected.height !== actual.height ||
      expected.colorType !== actual.colorType
    ) {
      failures.push(
        `${scenario.file}: dimensions/color mode differ ` +
          `(expected ${expected.width}x${expected.height}/${expected.colorType}, ` +
          `actual ${actual.width}x${actual.height}/${actual.colorType})`
      );
      continue;
    }
    if (!expected.pixels.equals(actual.pixels)) {
      let firstDiff = -1;
      for (let index = 0; index < expected.pixels.length; index += 1) {
        if (expected.pixels[index] !== actual.pixels[index]) {
          firstDiff = index;
          break;
        }
      }
      const pixelIndex = Math.floor(firstDiff / expected.bpp);
      failures.push(
        `${scenario.file}: decoded pixels differ (first at x=${pixelIndex % expected.width}, ` +
          `y=${Math.floor(pixelIndex / expected.width)}); actual written to screenshots/actual/`
      );
      continue;
    }
    console.error(`  verified ${scenario.file}`);
  }

  if (failures.length > 0) {
    fail(`visual verification failed:\n  ${failures.join("\n  ")}`);
  }
  console.error(`verify OK: ${SCENARIOS.length} baselines match pixels and approved hashes`);
};

main().catch((error) => {
  fail(error.message);
});
