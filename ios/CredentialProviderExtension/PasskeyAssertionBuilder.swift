import CryptoKit
import Foundation
import os

/// spec 023 T303 — builds a WebAuthn assertion from a stored passkey.
///
/// Compiled into both the iOS and the macOS credential provider extension.
/// It is the only code on Apple platforms that touches a passkey's private
/// key, and it never logs one: the `Logger` lines below carry the relying
/// party and nothing else (Constitution I).
///
/// Three algorithms, three different signature encodings, one shared
/// `authenticatorData`. ES256 and RS256 sign DER; Ed25519 signs a raw 64-byte
/// value. Getting that wrong produces a signature the relying party rejects
/// with no explanation, so each path is spelled out rather than shared.
enum PasskeyAssertionBuilder {
  private static let log = Logger(
    subsystem: "dev.camillobucciarelli.keyvault",
    category: "passkey"
  )

  enum Failure: Error {
    case badKey
    case unsupportedAlgorithm
    case signingFailed
  }

  struct Assertion {
    let credentialID: Data
    let authenticatorData: Data
    let signature: Data
    let userHandle: Data
  }

  private static let flagUserPresent: UInt8 = 0x01
  private static let flagUserVerified: UInt8 = 0x04
  private static let flagBackupEligible: UInt8 = 0x08
  private static let flagBackupState: UInt8 = 0x10

  /// `rpIdHash ‖ flags ‖ signCount(0)` — 37 bytes.
  ///
  /// The sign counter is fixed at zero, deliberately. A vault synced across
  /// devices cannot keep a single monotonic counter, and a counter that goes
  /// backwards is a clone signal to the relying party. Zero means "this
  /// authenticator does not count", which WebAuthn permits.
  static func authenticatorData(
    rpId: String,
    backupEligible: Bool,
    backupState: Bool
  ) -> Data {
    var flags = flagUserPresent | flagUserVerified
    if backupEligible { flags |= flagBackupEligible }
    if backupEligible && backupState { flags |= flagBackupState }

    var data = Data(SHA256.hash(data: Data(rpId.utf8)))
    data.append(flags)
    data.append(contentsOf: [0, 0, 0, 0])
    return data
  }

  /// Signs `authenticatorData ‖ clientDataHash` with the stored key.
  ///
  /// `clientDataHash` comes from the system, already hashed: on Apple the
  /// extension never sees the clientDataJSON itself, which is why the
  /// assertion it returns does not carry one.
  static func assert(
    secret: AutofillPasskeySecret,
    clientDataHash: Data
  ) throws -> Assertion {
    guard let credentialID = Data(base64URLEncoded: secret.credentialId) else {
      throw Failure.badKey
    }
    let authData = authenticatorData(
      rpId: secret.rpId,
      backupEligible: secret.backupEligible,
      backupState: secret.backupState
    )
    let message = authData + clientDataHash
    let privateKey = try pkcs8PrivateKey(pem: secret.privateKeyPem)

    let signature: Data
    switch secret.algorithm {
    case .es256:
      signature = try signES256(pkcs8PrivateKey: privateKey, message: message)
    case .eddsa:
      signature = try signEd25519(pkcs8PrivateKey: privateKey, message: message)
    case .rs256:
      signature = try signRS256(pkcs8PrivateKey: privateKey, message: message)
    }

    log.info("assertion built rpId=\(secret.rpId, privacy: .private(mask: .hash))")
    return Assertion(
      credentialID: credentialID,
      authenticatorData: authData,
      signature: signature,
      // A relying party that stored no user handle gets the credential id
      // back, which is what an authenticator with no discoverable handle
      // returns.
      userHandle: secret.userHandle.flatMap { Data(base64URLEncoded: $0) } ?? credentialID
    )
  }

  // ---------------------------------------------------------------------
  // Algorithms
  // ---------------------------------------------------------------------

  /// CryptoKit wants the raw 32-byte scalar; PKCS#8 wraps it in an
  /// `ECPrivateKey` SEQUENCE inside its `privateKey` OCTET STRING.
  private static func signES256(pkcs8PrivateKey: Data, message: Data) throws -> Data {
    guard let ecPrivateKey = DERNode.parse(pkcs8PrivateKey),
          ecPrivateKey.children.count >= 2,
          case let scalar = ecPrivateKey.children[1].content,
          !scalar.isEmpty else {
      throw Failure.badKey
    }
    // A leading zero byte is DER's sign padding, not part of the scalar, and
    // P-256 keys are exactly 32 bytes.
    var raw = scalar
    while raw.count > 32, raw.first == 0 { raw.removeFirst() }
    while raw.count < 32 { raw.insert(0, at: 0) }
    do {
      let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
      return try key.signature(for: message).derRepresentation
    } catch {
      throw Failure.signingFailed
    }
  }

  /// Ed25519's PKCS#8 `privateKey` is an OCTET STRING wrapping the 32-byte
  /// seed in a second OCTET STRING — one layer more than the others.
  private static func signEd25519(pkcs8PrivateKey: Data, message: Data) throws -> Data {
    let seed: Data
    if pkcs8PrivateKey.count == 32 {
      seed = pkcs8PrivateKey
    } else if let inner = DERNode.parse(pkcs8PrivateKey), inner.content.count == 32 {
      seed = inner.content
    } else {
      throw Failure.badKey
    }
    do {
      let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
      // Raw 64 bytes, not DER: EdDSA signatures are not DER-encoded.
      return try key.signature(for: message)
    } catch {
      throw Failure.signingFailed
    }
  }

  /// CryptoKit has no RSA, so this goes through `SecKey` with the PKCS#1
  /// structure PKCS#8 wraps.
  private static func signRS256(pkcs8PrivateKey: Data, message: Data) throws -> Data {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(
      pkcs8PrivateKey as CFData,
      attributes as CFDictionary,
      &error
    ) else {
      error?.release()
      throw Failure.badKey
    }
    guard let signature = SecKeyCreateSignature(
      key,
      .rsaSignatureMessagePKCS1v15SHA256,
      message as CFData,
      &error
    ) else {
      error?.release()
      throw Failure.signingFailed
    }
    return signature as Data
  }

  // ---------------------------------------------------------------------
  // PKCS#8
  // ---------------------------------------------------------------------

  /// The algorithm-specific structure inside PKCS#8's `privateKey` OCTET
  /// STRING: `PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey }`.
  private static func pkcs8PrivateKey(pem: String) throws -> Data {
    guard let der = derFromPEM(pem),
          let info = DERNode.parse(der),
          info.tag == DERNode.sequence,
          info.children.count >= 3 else {
      throw Failure.badKey
    }
    return info.children[2].content
  }

  private static func derFromPEM(_ pem: String) -> Data? {
    let lines = pem.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard lines.count >= 3,
          lines.first?.hasPrefix("-----BEGIN ") == true,
          lines.last?.hasPrefix("-----END ") == true else {
      return nil
    }
    return Data(base64Encoded: lines.dropFirst().dropLast().joined())
  }
}

/// Minimal DER reader: enough to walk PKCS#8 and ECPrivateKey.
///
/// A deliberate mirror of the Dart `DerNode` in `passkey_parser.dart` — the
/// two must agree on what a stored key means, and a full ASN.1 library on
/// either side would be more surface than this needs.
struct DERNode {
  static let sequence: UInt8 = 0x30

  let tag: UInt8
  let content: Data
  let children: [DERNode]

  static func parse(_ data: Data) -> DERNode? {
    guard let (node, end) = read(data, from: data.startIndex), end == data.endIndex else {
      return nil
    }
    return node
  }

  private static func parseAll(_ data: Data) -> [DERNode] {
    var nodes: [DERNode] = []
    var offset = data.startIndex
    while offset < data.endIndex {
      guard let (node, next) = read(data, from: offset) else { return nodes }
      nodes.append(node)
      offset = next
    }
    return nodes
  }

  private static func read(_ data: Data, from offset: Data.Index) -> (DERNode, Data.Index)? {
    guard data.distance(from: offset, to: data.endIndex) >= 2 else { return nil }
    let tag = data[offset]
    var cursor = data.index(offset, offsetBy: 2)
    var length = Int(data[data.index(offset, offsetBy: 1)])

    if length & 0x80 != 0 {
      let count = length & 0x7f
      guard count > 0, count <= 4,
            data.distance(from: cursor, to: data.endIndex) >= count else {
        return nil
      }
      length = 0
      for index in 0..<count {
        length = (length << 8) | Int(data[data.index(cursor, offsetBy: index)])
      }
      cursor = data.index(cursor, offsetBy: count)
    }

    guard data.distance(from: cursor, to: data.endIndex) >= length else { return nil }
    let end = data.index(cursor, offsetBy: length)
    // Re-based so nested parsing sees a zero-indexed slice.
    let content = Data(data[cursor..<end])
    let constructed = tag & 0x20 != 0
    return (
      DERNode(tag: tag, content: content, children: constructed ? parseAll(content) : []),
      end
    )
  }
}
