// Loads the worker files the way MV3 actually does: `importScripts` evaluates
// every file in ONE shared global scope. Every other test in this directory
// loads them through `require()`, which gives each file its own module scope —
// so a duplicate top-level binding between two worker files is invisible to
// the entire suite while making the real worker fail to register at all
// ("Identifier 'X' has already been declared", registration status code 15).
//
// That is not hypothetical: the Gate A2 manual smoke found exactly this — three
// `const API` declarations plus two `const securityModule` collided, and the
// shipped worker never started. This test is the automated version of that
// smoke step.

"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const EXTENSION_ROOT = path.join(__dirname, "..");

// The exact load order of the production worker: background.js first runs
// importScripts(...) then its own top-level code.
const WORKER_ENTRY = "background.js";

// A permissive `chrome` stub: any property path resolves to a callable no-op.
// The point of this test is LOAD-TIME evaluation (scope collisions, missing
// globals), not behaviour — behaviour is owned by the fake-browser harnesses.
function chromeStub() {
  const handler = {
    get(target, prop) {
      if (prop === Symbol.toPrimitive || prop === "toString") {
        return () => "chrome-stub";
      }
      if (!(prop in target)) {
        target[prop] = new Proxy(function () {}, handler);
      }
      return target[prop];
    },
    apply() {
      return undefined;
    },
  };
  return new Proxy(function () {}, handler);
}

function loadWorker() {
  const sandbox = {
    chrome: chromeStub(),
    crypto: require("node:crypto").webcrypto,
    console,
    setTimeout,
    clearTimeout,
    URL,
    TextEncoder,
    TextDecoder,
  };
  const context = vm.createContext(sandbox);
  const runFile = (name) => {
    const code = fs.readFileSync(path.join(EXTENSION_ROOT, name), "utf8");
    vm.runInContext(code, context, { filename: name });
  };
  // Real importScripts semantics: same context, sequential evaluation.
  sandbox.importScripts = (...names) => names.forEach(runFile);
  sandbox.self = context;
  runFile(WORKER_ENTRY);
  return context;
}

test("worker files evaluate in one shared global scope without collisions", () => {
  // Throws "Identifier ... has already been declared" on any duplicate
  // top-level binding between worker files, exactly like the real worker.
  const context = loadWorker();
  assert.strictEqual(typeof context.CustodeOverlaySecurity, "object");
  assert.strictEqual(typeof context.CustodeOverlayLifecycle, "object");
  assert.strictEqual(typeof context.CustodeOverlayRoutes, "object");
});

test("loading the worker twice in one scope still works (idempotent globals)", () => {
  // `importScripts` never re-runs in production, but the IIFE wrappers must
  // not leak bindings that would collide on a hypothetical second evaluation.
  const context = loadWorker();
  const security = context.CustodeOverlaySecurity;
  const code = fs.readFileSync(
    path.join(EXTENSION_ROOT, "overlay_security.js"),
    "utf8"
  );
  vm.runInContext(code, context, { filename: "overlay_security.js#2" });
  assert.notStrictEqual(context.CustodeOverlaySecurity, undefined);
  assert.strictEqual(typeof security.canonicalizeOrigin, "function");
});
