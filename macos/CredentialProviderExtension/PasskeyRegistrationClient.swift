import Foundation
import OSLog

private let passkeyRegistrationClientLog = Logger(
  subsystem: "dev.camillobucciarelli.kdbxKeyVault.CredentialProviderExtension",
  category: "passkey-registration"
)

/// What the app said about a registration it was asked to prepare.
enum PasskeyRegistrationPrepareOutcome {
  /// A vault is open and unlocked. `replaces` is true when it already holds a
  /// passkey for this site and account. `nonce` is the single-use value the
  /// app requires on the `commit` that follows.
  case ready(replaces: Bool, nonce: String)

  /// The vault already holds one of the credentials the site excluded.
  case excluded

  /// The app is not running, has no vault open, the vault is locked, or the
  /// app could not be authenticated. All have the same remedy, so they are
  /// one case.
  case appUnavailable
}

/// What the app said about a registration it was asked to write.
enum PasskeyRegistrationCommitOutcome {
  /// The vault holds the passkey. Only this case may complete the ceremony.
  case done(credentialID: Data, attestationObject: Data)
  case appUnavailable
  case alreadyExists
  case failed

  /// The app accepted the write and then did not report its outcome in time.
  /// The vault may or may not hold the passkey; the site is not told of one.
  case unknownAfterAccepted
}

/// spec 023 T709 — the extension half of registering a passkey: it asks the
/// running Custode app, which is the only process that can write the vault.
///
/// The transport is the app's `CFMessagePort`, named under the App Group. A
/// port callback has to answer at once and the app's answer comes from Dart
/// asynchronously, so each operation is two kinds of message: the request
/// returns a token, then `result` is polled with it (see
/// `PasskeyRegistrationPort` in the app target for why).
///
/// Every request is MACed with the secret the app stored in the shared
/// keychain group at launch, and every reply must carry a valid MAC bound to
/// that request (see `PasskeyRegistrationWire`). A reply that does not verify
/// is treated as no reply: whatever answered is not the app.
///
/// Everything here runs on a private serial queue. `CFMessagePortSendRequest`
/// blocks its caller, and the caller must never be the extension's main
/// thread. Completions are delivered on the main queue.
///
/// Nothing is logged but operation names and statuses.
final class PasskeyRegistrationClient {
  private let queue = DispatchQueue(
    label: "dev.camillobucciarelli.kdbxKeyVault.passkey-registration-client"
  )

  /// One exchange with the app, which answers from a dictionary lookup.
  private static let sendTimeout: CFTimeInterval = 1
  private static let receiveTimeout: CFTimeInterval = 3
  private static let pollInterval: TimeInterval = 0.1

  /// `prepare` reads the open vault; `commit` backs it up and rewrites it.
  private static let prepareDeadline: TimeInterval = 10
  private static let commitDeadline: TimeInterval = 60

  private enum RunResult {
    /// An authentic final answer.
    case answered([String: Any])
    /// Nothing was started in the app: no secret, no port, refused, or no
    /// authentic reply to the request.
    case notStarted
    /// The app accepted the request and its outcome is unknown.
    case lostAfterAccepted
  }

  func prepare(
    rpId: String,
    userHandle: Data,
    excludedCredentialIDs: [Data],
    completion: @escaping (PasskeyRegistrationPrepareOutcome) -> Void
  ) {
    let userHandleText = userHandle.base64URLEncodedString
    let excluded = excludedCredentialIDs.map { $0.base64URLEncodedString }
    var request: [String: Any] = ["op": "prepare", "rpId": rpId]
    if !userHandleText.isEmpty {
      request["userHandle"] = userHandleText
    }
    if !excluded.isEmpty {
      request["excludeCredentialIds"] = excluded
    }
    let fields = PasskeyRegistrationWire.prepareFields(
      rpId: rpId,
      userHandle: userHandleText,
      excludeCredentialIds: excluded
    )
    queue.async {
      let outcome: PasskeyRegistrationPrepareOutcome
      switch Self.run(request: request, fields: fields, deadline: Self.prepareDeadline) {
      case .answered(let result):
        switch result["status"] as? String {
        case "ready":
          if let nonce = result["nonce"] as? String, !nonce.isEmpty {
            outcome = .ready(replaces: result["replaces"] as? Bool ?? false, nonce: nonce)
          } else {
            outcome = .appUnavailable
          }
        case "excluded":
          outcome = .excluded
        default:
          // noVault, locked, or an answer that makes no sense here.
          outcome = .appUnavailable
        }
      case .notStarted, .lostAfterAccepted:
        // `prepare` writes nothing, so a lost answer is just "not now".
        outcome = .appUnavailable
      }
      DispatchQueue.main.async { completion(outcome) }
    }
  }

  func commit(
    rpId: String,
    username: String,
    userHandle: Data,
    replaceExisting: Bool,
    nonce: String,
    completion: @escaping (PasskeyRegistrationCommitOutcome) -> Void
  ) {
    let userHandleText = userHandle.base64URLEncodedString
    var request: [String: Any] = [
      "op": "commit",
      "rpId": rpId,
      "username": username,
      "replaceExisting": replaceExisting,
      "nonce": nonce,
    ]
    if !userHandleText.isEmpty {
      request["userHandle"] = userHandleText
    }
    let fields = PasskeyRegistrationWire.commitFields(
      rpId: rpId,
      username: username,
      userHandle: userHandleText,
      replaceExisting: replaceExisting,
      nonce: nonce
    )
    queue.async {
      let outcome: PasskeyRegistrationCommitOutcome
      switch Self.run(request: request, fields: fields, deadline: Self.commitDeadline) {
      case .answered(let result):
        outcome = Self.commitOutcome(from: result)
      case .notStarted:
        outcome = .failed
      case .lostAfterAccepted:
        outcome = .unknownAfterAccepted
      }
      DispatchQueue.main.async { completion(outcome) }
    }
  }

  private static func commitOutcome(
    from result: [String: Any]
  ) -> PasskeyRegistrationCommitOutcome {
    switch result["status"] as? String {
    case "done":
      // `done` without both values is not a registration the site can be
      // told about, so it is not `done`. The app did say it wrote, though,
      // so the user is told the vault may hold a passkey.
      guard let credentialIdText = result["credentialId"] as? String,
            let attestationText = result["attestationObject"] as? String,
            let credentialID = Data(base64URLEncoded: credentialIdText),
            let attestationObject = Data(base64URLEncoded: attestationText),
            !credentialID.isEmpty,
            !attestationObject.isEmpty else {
        passkeyRegistrationClientLog.error("commit answered done without a usable credential")
        return .unknownAfterAccepted
      }
      return .done(credentialID: credentialID, attestationObject: attestationObject)
    case "noVault", "locked":
      return .appUnavailable
    case "alreadyExists":
      return .alreadyExists
    default:
      return .failed
    }
  }

  // MARK: - Transport (private queue only)

  /// Send `request`, then poll until the app has the answer or `deadline`
  /// passes.
  private static func run(
    request: [String: Any],
    fields: [String],
    deadline: TimeInterval
  ) -> RunResult {
    let operation = request["op"] as? String ?? "?"
    // Read at every operation: the app writes a new secret at each launch.
    guard let secret = PasskeyRegistrationWire.readSecret() else {
      // Custode has not run since the secret was last readable, or the
      // keychain refused. Either way there is no app to talk to.
      passkeyRegistrationClientLog.info("\(operation, privacy: .public): no registration secret")
      return .notStarted
    }
    guard let port = CFMessagePortCreateRemote(
      nil,
      PasskeyRegistrationWire.portName as CFString
    ) else {
      // The usual reason: Custode is not running.
      passkeyRegistrationClientLog.info("\(operation, privacy: .public): app port not found")
      return .notStarted
    }
    defer { CFMessagePortInvalidate(port) }

    guard let first = exchange(request, fields: fields, secret: secret, on: port) else {
      passkeyRegistrationClientLog.error("\(operation, privacy: .public): no authentic reply")
      return .notStarted
    }

    let token: String
    switch first["state"] as? String {
    case "final":
      return answered(first, operation: operation)
    case "accepted":
      guard let accepted = first["token"] as? String, !accepted.isEmpty else {
        return .notStarted
      }
      token = accepted
    default:
      return .notStarted
    }

    let poll: [String: Any] = ["op": "result", "token": token]
    let pollFields = PasskeyRegistrationWire.resultFields(token: token)
    let giveUpAt = Date().addingTimeInterval(deadline)
    while Date() < giveUpAt {
      Thread.sleep(forTimeInterval: pollInterval)
      guard let polled = exchange(poll, fields: pollFields, secret: secret, on: port) else {
        passkeyRegistrationClientLog.error("\(operation, privacy: .public): app stopped answering")
        return .lostAfterAccepted
      }
      switch polled["state"] as? String {
      case "pending":
        continue
      case "final":
        return answered(polled, operation: operation)
      default:
        return .lostAfterAccepted
      }
    }
    passkeyRegistrationClientLog.error("\(operation, privacy: .public): timed out")
    return .lostAfterAccepted
  }

  private static func answered(_ reply: [String: Any], operation: String) -> RunResult {
    let status = reply["status"] as? String ?? "?"
    passkeyRegistrationClientLog.info("\(operation, privacy: .public): status=\(status, privacy: .public)")
    return .answered(reply)
  }

  /// One MACed request and its authentic reply. `nil` for a transport
  /// failure, a malformed reply, or a reply whose MAC does not verify.
  private static func exchange(
    _ object: [String: Any],
    fields: [String],
    secret: Data,
    on port: CFMessagePort
  ) -> [String: Any]? {
    let requestMac = PasskeyRegistrationWire.mac(secret: secret, fields: fields)
    var message = object
    message["mac"] = requestMac
    guard let data = try? JSONSerialization.data(withJSONObject: message),
          data.count <= PasskeyRegistrationWire.maxMessageBytes else {
      return nil
    }
    var unmanagedReply: Unmanaged<CFData>?
    // A non-nil reply mode makes this call wait for the reply, running this
    // queue's thread's run loop in that mode. The timeouts bound the wait.
    let status = CFMessagePortSendRequest(
      port,
      1,
      data as CFData,
      sendTimeout,
      receiveTimeout,
      CFRunLoopMode.defaultMode.rawValue,
      &unmanagedReply
    )
    // The reply follows the Create Rule, so it is taken even on failure.
    let replyData: Data? = unmanagedReply.map { $0.takeRetainedValue() as Data }
    // 0 is kCFMessagePortSuccess.
    guard status == 0, let replyData,
          !replyData.isEmpty,
          replyData.count <= PasskeyRegistrationWire.maxMessageBytes,
          let parsed = try? JSONSerialization.jsonObject(with: replyData),
          let reply = parsed as? [String: Any],
          let replyMac = reply["mac"] as? String,
          PasskeyRegistrationWire.isValid(
            mac: replyMac,
            secret: secret,
            fields: PasskeyRegistrationWire.replyFields(requestMac: requestMac, reply: reply)
          ) else {
      return nil
    }
    return reply
  }
}
