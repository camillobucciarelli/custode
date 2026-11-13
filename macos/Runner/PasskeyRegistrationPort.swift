import FlutterMacOS
import Foundation
import OSLog
import Security

private let passkeyRegistrationPortLog = Logger(
  subsystem: "dev.camillobucciarelli.kdbxKeyVault",
  category: "passkey-registration-port"
)

/// spec 023 T709 — the app half of registering a passkey from the macOS
/// AutoFill extension.
///
/// The extension cannot write the vault (it has no master password), so it
/// asks this process to. The transport is a `CFMessagePort` registered under
/// the App Group identifier, which is what App Sandbox lets two members of the
/// group share without a new entitlement or a new target.
///
/// ## Why two messages and not one
///
/// A `CFMessagePort` callback must return its reply synchronously, and this
/// port is serviced by the main run loop. The answer comes from Dart over a
/// method channel, whose reply is also delivered on the main run loop. A
/// callback that waited for it would be waiting for something that can only
/// arrive after the callback returns.
///
/// So no callback ever waits. `prepare` and `commit` start the Dart call and
/// return a token at once; the extension then sends `result` with that token
/// until the answer is there. Every callback is a dictionary lookup, the main
/// run loop is never blocked, and the Dart reply lands between two polls like
/// any other main-thread event.
///
/// ## Who may ask
///
/// `CFMessagePort` carries no peer identity, and a process that is not
/// sandboxed can look this port up. So every request must carry an
/// HMAC-SHA256 under a secret generated here at launch and stored in the
/// shared keychain access group, which only this app and its extension are
/// signed to read (see `PasskeyRegistrationWire`). A request whose MAC does
/// not verify gets one generic refusal and reaches neither Dart nor the vault.
/// Replies are MACed too, so the extension can tell this process from one
/// that registered the port name while the app was not running.
///
/// A `commit` additionally needs the single-use nonce handed out by the
/// `prepare` it follows, for the same site and user handle. That ties every
/// write to a confirmation the extension showed within the last two minutes.
///
/// This port does not authenticate the user: the extension owns the
/// confirmation and the device owner check, and this side writes headlessly.
///
/// Nothing here is logged except operation names, statuses and counts: never
/// a relying party's user handle, a credential id, a nonce, a token, a MAC or
/// any key material.
final class PasskeyRegistrationPort {
  static let shared = PasskeyRegistrationPort()

  /// A finished answer the extension has not collected is dropped after this
  /// long, and so is a call Dart never answered and a nonce nobody used.
  private static let lifetime: TimeInterval = 120

  /// The extension runs one registration at a time. A handful of slots covers
  /// a retry racing an abandoned attempt without letting a caller queue work.
  private static let maxJobs = 8
  private static let maxNonces = 8

  /// Bound on the excluded credential list forwarded to Dart.
  private static let maxExcludedCredentials = 64

  private struct Job {
    let createdAt: Date
    /// What a `ready` answer to this job's `prepare` hands a nonce out for.
    /// `nil` for a `commit`.
    let binding: Binding?
    /// `nil` while Dart is still working. Flat reply fields otherwise.
    var result: [String: Any]?
  }

  /// The site and user handle a `prepare` was about.
  private struct Binding: Equatable {
    let rpId: String
    let userHandle: String
  }

  private struct Nonce {
    let createdAt: Date
    let binding: Binding
  }

  private var port: CFMessagePort?
  private var secret: Data?
  private var jobs: [String: Job] = [:]
  private var nonces: [String: Nonce] = [:]

  private init() {}

  /// Register the port and service it from the main run loop. Idempotent.
  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard port == nil else { return }

    // A new secret at every launch: whatever a previous run left in the
    // keychain stops verifying the moment this one is stored.
    if let generated = PasskeyRegistrationWire.randomBytes(PasskeyRegistrationWire.secretByteCount) {
      let status = PasskeyRegistrationWire.storeSecret(generated)
      if status == errSecSuccess {
        secret = generated
      } else {
        // Without a secret the extension can read, no request can verify.
        // The port still answers, always with the generic refusal, and
        // AutoFill reports "open Custode".
        passkeyRegistrationPortLog.error("registration secret not stored status=\(status, privacy: .public)")
      }
    } else {
      passkeyRegistrationPortLog.error("registration secret not generated")
    }

    var context = CFMessagePortContext()
    var shouldFreeInfo: DarwinBoolean = false
    guard let created = CFMessagePortCreateLocal(
      nil,
      PasskeyRegistrationWire.portName as CFString,
      passkeyRegistrationPortCallback,
      &context,
      &shouldFreeInfo
    ) else {
      // Another process already owns the name, or the sandbox refused it.
      // Registration from AutoFill then reports "open Custode", which is the
      // honest answer: this process cannot be reached.
      passkeyRegistrationPortLog.error("passkey registration port unavailable")
      return
    }
    guard let source = CFMessagePortCreateRunLoopSource(nil, created, 0) else {
      passkeyRegistrationPortLog.error("passkey registration port has no run loop source")
      CFMessagePortInvalidate(created)
      return
    }
    // Common modes, so a request is still answered while a menu or a modal
    // panel is tracking.
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    port = created
    passkeyRegistrationPortLog.info("passkey registration port listening")
  }

  // MARK: - Message handling (main run loop)

  /// The one answer to anything that is not an authentic, well-formed
  /// request. It says nothing about which check failed and carries no MAC:
  /// the extension treats an unauthenticated reply as no reply.
  private static let refusal = Data(#"{"state":"rejected"}"#.utf8)

  /// Always returns a reply, and always immediately.
  fileprivate func handle(message: Data?) -> Data {
    guard let message, !message.isEmpty,
          message.count <= PasskeyRegistrationWire.maxMessageBytes,
          let object = try? JSONSerialization.jsonObject(with: message),
          let request = object as? [String: Any],
          let operation = request["op"] as? String,
          let requestMac = request["mac"] as? String else {
      passkeyRegistrationPortLog.error("message refused: malformed or too large")
      return Self.refusal
    }
    guard let secret else {
      passkeyRegistrationPortLog.error("message refused: no registration secret")
      return Self.refusal
    }

    pruneExpired()

    switch operation {
    case "prepare":
      guard let rpId = request["rpId"] as? String, !rpId.isEmpty else { return Self.refusal }
      let userHandle = request["userHandle"] as? String ?? ""
      let excluded = request["excludeCredentialIds"] as? [String] ?? []
      guard excluded.count <= Self.maxExcludedCredentials,
            PasskeyRegistrationWire.isValid(
              mac: requestMac,
              secret: secret,
              fields: PasskeyRegistrationWire.prepareFields(
                rpId: rpId,
                userHandle: userHandle,
                excludeCredentialIds: excluded
              )
            ) else {
        passkeyRegistrationPortLog.error("prepare refused")
        return Self.refusal
      }
      var arguments: [String: Any] = ["rpId": rpId]
      if !userHandle.isEmpty {
        arguments["userHandle"] = userHandle
      }
      if !excluded.isEmpty {
        arguments["excludeCredentialIds"] = excluded
      }
      return begin(
        operation: operation,
        method: "preparePasskeyRegistration",
        arguments: arguments,
        binding: Binding(rpId: rpId, userHandle: userHandle),
        requestMac: requestMac,
        secret: secret
      )

    case "commit":
      guard let rpId = request["rpId"] as? String, !rpId.isEmpty,
            let username = request["username"] as? String,
            let replaceExisting = request["replaceExisting"] as? Bool,
            let nonce = request["nonce"] as? String, !nonce.isEmpty else {
        return Self.refusal
      }
      let userHandle = request["userHandle"] as? String ?? ""
      guard PasskeyRegistrationWire.isValid(
        mac: requestMac,
        secret: secret,
        fields: PasskeyRegistrationWire.commitFields(
          rpId: rpId,
          username: username,
          userHandle: userHandle,
          replaceExisting: replaceExisting,
          nonce: nonce
        )
      ) else {
        passkeyRegistrationPortLog.error("commit refused")
        return Self.refusal
      }
      // Single use: the nonce is gone whether or not it matches.
      guard let issued = nonces.removeValue(forKey: nonce),
            issued.binding == Binding(rpId: rpId, userHandle: userHandle) else {
        passkeyRegistrationPortLog.error("commit refused")
        return Self.refusal
      }
      var arguments: [String: Any] = [
        "rpId": rpId,
        "username": username,
        "replaceExisting": replaceExisting,
      ]
      if !userHandle.isEmpty {
        arguments["userHandle"] = userHandle
      }
      return begin(
        operation: operation,
        method: "commitPasskeyRegistration",
        arguments: arguments,
        binding: nil,
        requestMac: requestMac,
        secret: secret
      )

    case "result":
      guard let token = request["token"] as? String, !token.isEmpty,
            PasskeyRegistrationWire.isValid(
              mac: requestMac,
              secret: secret,
              fields: PasskeyRegistrationWire.resultFields(token: token)
            ),
            let job = jobs[token] else {
        passkeyRegistrationPortLog.error("result refused")
        return Self.refusal
      }
      guard var result = job.result else {
        return reply(["state": "pending"], requestMac: requestMac, secret: secret)
      }
      // Handed over exactly once.
      jobs[token] = nil
      if let binding = job.binding, result["status"] as? String == "ready" {
        // The nonce is minted when the answer is collected, so its two
        // minutes start when the extension can first show the confirmation.
        guard nonces.count < Self.maxNonces,
              let nonce = PasskeyRegistrationWire.randomBytes(PasskeyRegistrationWire.nonceByteCount)?
                .base64URLEncodedString else {
          return Self.refusal
        }
        nonces[nonce] = Nonce(createdAt: Date(), binding: binding)
        result["nonce"] = nonce
      }
      result["state"] = "final"
      return reply(result, requestMac: requestMac, secret: secret)

    default:
      passkeyRegistrationPortLog.error("message refused: unknown operation")
      return Self.refusal
    }
  }

  /// Start the Dart call and hand back the token its answer will be filed
  /// under. Never waits for Dart. Only reached by an authentic request.
  private func begin(
    operation: String,
    method: String,
    arguments: [String: Any],
    binding: Binding?,
    requestMac: String,
    secret: Data
  ) -> Data {
    guard jobs.count < Self.maxJobs,
          let token = PasskeyRegistrationWire.randomBytes(PasskeyRegistrationWire.tokenByteCount)?
            .base64URLEncodedString else {
      passkeyRegistrationPortLog.error("\(operation, privacy: .public) refused: busy")
      return Self.refusal
    }

    let started = AppleAutofillV2Channel.shared.invokeOnDart(
      method: method,
      arguments: arguments
    ) { [weak self] raw in
      self?.finish(token: token, operation: operation, raw: raw)
    }
    guard started else {
      // No Flutter channel: nothing in this process can open a vault yet.
      passkeyRegistrationPortLog.info("\(operation, privacy: .public) answered noVault: no Flutter channel")
      return reply(["state": "final", "status": "noVault"], requestMac: requestMac, secret: secret)
    }

    // `finish` cannot have run yet: Flutter delivers the reply on a later
    // main run loop turn. Should it ever run inline, do not overwrite it.
    if jobs[token] == nil {
      jobs[token] = Job(createdAt: Date(), binding: binding, result: nil)
    }
    passkeyRegistrationPortLog.info("\(operation, privacy: .public) accepted")
    return reply(["state": "accepted", "token": token], requestMac: requestMac, secret: secret)
  }

  private func finish(token: String, operation: String, raw: Any?) {
    let result = Self.sanitize(raw)
    let status = result["status"] as? String ?? "failed"
    passkeyRegistrationPortLog.info("\(operation, privacy: .public) finished status=\(status, privacy: .public)")
    if let job = jobs[token] {
      jobs[token] = Job(createdAt: job.createdAt, binding: job.binding, result: result)
    } else {
      // Ran before `begin` filed the job (see there). No nonce binding is
      // known here, so a `ready` filed this way cannot lead to a commit.
      jobs[token] = Job(createdAt: Date(), binding: nil, result: result)
    }
  }

  /// Reduce whatever Flutter returned to the fields the extension uses.
  ///
  /// Only known keys of the expected type cross to the extension, so a change
  /// on the Dart side can never leak a new field through this port.
  private static func sanitize(_ raw: Any?) -> [String: Any] {
    if let error = raw as? FlutterError {
      passkeyRegistrationPortLog.error("Dart call failed code=\(error.code, privacy: .public)")
      return ["status": "failed"]
    }
    guard let map = raw as? [String: Any], let status = map["status"] as? String else {
      // `FlutterMethodNotImplemented` lands here: the Dart handler is not
      // attached, which means the app has not finished starting.
      if let object = raw as? NSObject, object === FlutterMethodNotImplemented {
        return ["status": "noVault"]
      }
      return ["status": "failed"]
    }

    let knownStatuses: Set<String> = [
      "ready", "noVault", "locked", "alreadyExists", "excluded", "failed", "done",
    ]
    guard knownStatuses.contains(status) else { return ["status": "failed"] }

    var result: [String: Any] = ["status": status]
    if let replaces = map["replaces"] as? Bool {
      result["replaces"] = replaces
    }
    for key in ["credentialId", "attestationObject"] {
      if let value = map[key] as? String {
        result[key] = value
      }
    }
    return result
  }

  private func pruneExpired() {
    let cutoff = Date().addingTimeInterval(-Self.lifetime)
    jobs = jobs.filter { $0.value.createdAt > cutoff }
    nonces = nonces.filter { $0.value.createdAt > cutoff }
  }

  /// Serialize an authentic reply: the fields, plus a MAC that binds them to
  /// the request they answer.
  private func reply(_ fields: [String: Any], requestMac: String, secret: Data) -> Data {
    var object = fields
    object["mac"] = PasskeyRegistrationWire.mac(
      secret: secret,
      fields: PasskeyRegistrationWire.replyFields(requestMac: requestMac, reply: fields)
    )
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          data.count <= PasskeyRegistrationWire.maxMessageBytes else {
      // An answer that does not fit is not sent in pieces: the extension
      // treats anything but `done` as a failure and creates nothing.
      return Self.refusal
    }
    return data
  }
}

/// `CFMessagePortCallBack`. Runs on the main run loop, where the port's source
/// is installed, and returns at once (see [PasskeyRegistrationPort]).
///
/// `data` is only valid for the duration of the call, so it is copied before
/// anything else looks at it. The returned object is released by the system,
/// hence `passRetained`.
private func passkeyRegistrationPortCallback(
  _ port: CFMessagePort?,
  _ messageId: Int32,
  _ data: CFData?,
  _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CFData>? {
  var message: Data?
  if let data {
    let length = CFDataGetLength(data)
    if length > 0, let bytes = CFDataGetBytePtr(data) {
      message = Data(bytes: bytes, count: length)
    } else {
      message = Data()
    }
  }
  let answer = PasskeyRegistrationPort.shared.handle(message: message)
  return Unmanaged.passRetained(answer as CFData)
}
