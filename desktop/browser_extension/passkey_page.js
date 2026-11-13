// spec 023 T503 — MAIN-world wrapper for `navigator.credentials.get`.
//
// This file runs in the PAGE's world, which is the only world where patching
// `navigator.credentials` is visible to the site. That is also why it holds
// no secret, no token and no policy: everything here is readable and
// spoofable by the page. It is a courier between the site's promise and the
// isolated world, and nothing more.
//
// The security rules it does NOT enforce, deliberately, because the page
// could defeat them here: which origin is asking (the worker derives that
// from `sender.url`), which relying party a passkey may answer for (the app
// checks rpId against that origin), and whether the user agreed (the app
// asks them). A page that forges a message to the isolated world gains
// nothing it could not get by calling `navigator.credentials.get` honestly.
(() => {
  "use strict";

  // One wrapper per world. A second injection — a re-registration, an
  // `executeScript` against the same document — must not wrap the wrapper,
  // or each layer would add another round trip and the innermost would call
  // a `get` that is itself already wrapped.
  if (window.__keyvaultPasskeyWrapped) return;
  const credentials = navigator.credentials;
  if (!credentials || typeof credentials.get !== "function") return;
  window.__keyvaultPasskeyWrapped = true;

  const CHANNEL = "keyvault-passkey";
  const originalGet = credentials.get.bind(credentials);
  const originalCreate =
    typeof credentials.create === "function"
      ? credentials.create.bind(credentials)
      : null;

  // Correlates one request with its answer. Not a secret — the page can read
  // it — just a way to keep two concurrent sign-ins apart.
  let nextRequestId = 1;
  const pending = new Map();

  window.addEventListener("message", (event) => {
    // Only this frame talks to its own bridge. A message from an iframe or
    // an opener is not an answer to anything asked here.
    if (event.source !== window) return;
    const data = event.data;
    if (
      !data ||
      data.channel !== CHANNEL ||
      (data.kind !== "passkey-get-result" && data.kind !== "passkey-create-result")
    ) {
      return;
    }
    const resolve = pending.get(data.requestId);
    if (!resolve) return;
    pending.delete(data.requestId);
    resolve(data);
  });

  function base64UrlFromBuffer(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function bufferFromBase64Url(value) {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }

  function askExtension(kind, request) {
    return new Promise((resolve) => {
      const requestId = nextRequestId++;
      pending.set(requestId, resolve);
      window.postMessage(
        { channel: CHANNEL, kind, requestId, ...request },
        window.location.origin
      );
    });
  }

  /**
   * The shape a relying party's own JS reads off the resolved promise.
   *
   * Not a real `PublicKeyCredential`: the constructor is not callable from
   * here, and a site that checks `instanceof` will reject this. That is the
   * documented limit of the desktop path (research R12) — sites that only
   * read the fields, which is the common case, work.
   */
  function toCredential(result) {
    const rawId = bufferFromBase64Url(result.credentialId);
    return {
      id: result.credentialId,
      rawId,
      type: "public-key",
      authenticatorAttachment: "cross-platform",
      response: {
        clientDataJSON: bufferFromBase64Url(result.clientDataJSON),
        authenticatorData: bufferFromBase64Url(result.authenticatorData),
        signature: bufferFromBase64Url(result.signature),
        userHandle: result.userHandle ? bufferFromBase64Url(result.userHandle) : null,
      },
      getClientExtensionResults: () => ({}),
    };
  }

  credentials.get = async function get(options) {
    const publicKey = options?.publicKey;
    // Anything that is not a WebAuthn sign-in — a federated or password
    // credential, a `create`-shaped call — goes straight to the browser.
    if (!publicKey || !publicKey.challenge) {
      return originalGet(options);
    }

    // An abort the site already fired, or fires while we are asking, belongs
    // to the site's own promise: pass it through untouched rather than
    // resolving with a credential nobody is waiting for any more.
    if (options?.signal?.aborted) return originalGet(options);

    // Conditional (and silent) mediation is passkey autofill, not a sign-in
    // the user asked for: login pages fire it on load, with no gesture. The
    // contract is that it resolves only if a credential can be offered
    // without interrupting anybody, so answering it with a modal
    // confirmation would pop a dialog on every page load — and holding it for
    // the app's whole budget would keep the browser's own autofill UI waiting
    // that long. Both mediations belong to the browser.
    const mediation = options?.mediation;
    if (mediation === "conditional" || mediation === "silent") {
      return originalGet(options);
    }

    let request;
    try {
      request = {
        rpId: publicKey.rpId || window.location.hostname,
        challenge: base64UrlFromBuffer(publicKey.challenge),
        allowCredentials: Array.isArray(publicKey.allowCredentials)
          ? publicKey.allowCredentials
              .map((entry) => (entry?.id ? base64UrlFromBuffer(entry.id) : null))
              .filter((value) => typeof value === "string")
          : [],
      };
    } catch {
      // A challenge that is not a buffer is the site's bug, not ours: let
      // the browser raise the error it would have raised anyway.
      return originalGet(options);
    }

    const result = await askExtension("passkey-get", request);
    // Every refusal — no passkey here, the user declined, the app is locked,
    // the extension never answered — falls through to the browser's own
    // authenticator. Custode having nothing to offer must never stop a
    // security key or a platform passkey from working.
    if (!result || result.ok !== true) {
      return originalGet(options);
    }
    try {
      return toCredential(result);
    } catch {
      return originalGet(options);
    }
  };

  // spec 023 US3 — registration.
  //
  // Wrapped for the same reason `get` is, and with the same fallthrough: a
  // site whose registration Custode declines must still be able to register a
  // platform passkey or a security key.
  if (originalCreate) {
    credentials.create = async function create(options) {
      const publicKey = options?.publicKey;
      if (!publicKey || !publicKey.challenge) return originalCreate(options);
      if (options?.signal?.aborted) return originalCreate(options);

      // Custode creates ES256 credentials only. A site that will not accept
      // ES256 is one this authenticator cannot serve, so it goes straight to
      // the browser rather than being refused after a confirmation the user
      // did not need to see.
      const params = publicKey.pubKeyCredParams;
      if (
        Array.isArray(params) &&
        params.length > 0 &&
        !params.some((param) => param?.alg === -7)
      ) {
        return originalCreate(options);
      }

      let request;
      try {
        request = {
          rpId: publicKey.rp?.id || window.location.hostname,
          challenge: base64UrlFromBuffer(publicKey.challenge),
          username: publicKey.user?.name || "",
          // The relying party's own account identifier. It is what a
          // discoverable sign-in has to hand back, so a credential stored
          // without it is one the site cannot resolve to an account.
          userHandle: publicKey.user?.id
            ? base64UrlFromBuffer(publicKey.user.id)
            : "",
        };
      } catch {
        return originalCreate(options);
      }

      const result = await askExtension("passkey-create", request);
      if (!result || result.ok !== true) return originalCreate(options);
      try {
        return toRegistrationCredential(result);
      } catch {
        return originalCreate(options);
      }
    };
  }

  /**
   * The registration shape a relying party reads. Same documented limit as the
   * sign-in one: a plain object, not a real `PublicKeyCredential`.
   */
  function toRegistrationCredential(result) {
    const rawId = bufferFromBase64Url(result.credentialId);
    const attestationObject = bufferFromBase64Url(result.attestationObject);
    const clientDataJSON = bufferFromBase64Url(result.clientDataJSON);
    const publicKey = result.publicKeyCose
      ? bufferFromBase64Url(result.publicKeyCose)
      : null;
    return {
      id: result.credentialId,
      rawId,
      type: "public-key",
      authenticatorAttachment: "cross-platform",
      response: {
        clientDataJSON,
        attestationObject,
        // The three accessors a modern relying party calls instead of parsing
        // the attestation object itself.
        getTransports: () => ["internal", "hybrid"],
        getPublicKeyAlgorithm: () => -7,
        getPublicKey: () => publicKey,
        getAuthenticatorData: () => authenticatorDataFrom(attestationObject),
      },
      getClientExtensionResults: () => ({}),
    };
  }

  /**
   * The authData bytes out of the CBOR attestation object.
   *
   * The object is always `{fmt, attStmt, authData}` with authData last and its
   * own byte-string header, so the payload is whatever follows that header —
   * no CBOR parser needed for a shape this app itself produced.
   */
  function authenticatorDataFrom(attestationObject) {
    const bytes = new Uint8Array(attestationObject);
    // "authData" as CBOR text(8): 0x68 'a' 'u' 't' 'h' 'D' 'a' 't' 'a'.
    const marker = [0x68, 0x61, 0x75, 0x74, 0x68, 0x44, 0x61, 0x74, 0x61];
    for (let i = 0; i + marker.length < bytes.length; i += 1) {
      if (marker.every((byte, offset) => bytes[i + offset] === byte)) {
        let cursor = i + marker.length;
        const header = bytes[cursor++];
        if (header === 0x58) cursor += 1;
        else if (header === 0x59) cursor += 2;
        return bytes.slice(cursor).buffer;
      }
    }
    return new ArrayBuffer(0);
  }
})();
