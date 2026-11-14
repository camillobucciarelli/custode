import CryptoKit
import Foundation
import Security

/// spec 024 T017 — creates an ES256 passkey and its `fmt: "none"` attestation.
///
/// Byte-for-byte the shape of the Dart `PasskeyGenerator`
/// (`lib/features/password_manager/data/services/passkey_generator.dart`),
/// pinned by `test/fixtures/passkeys/registration_vector.json`. The CBOR is
/// hand-written: one fixed shape, no dependency (FR-3).
///
/// Compiled into both credential provider extensions and both Runner apps.
/// It never logs: nothing here is safe to print except the rpId, and the
/// caller already knows that.
enum PasskeyRegistrationBuilder {
  enum Failure: Error {
    case randomUnavailable
  }

  struct Registration {
    let credentialID: Data
    /// PKCS#8 `PRIVATE KEY` PEM (CryptoKit's encoding). The secret.
    let privateKeyPem: String
    let coseKey: Data
    let authenticatorData: Data
    let attestationObject: Data
  }

  static let credentialIDLength = 32

  /// UP | UV | BE | BS | AT. UV is honest only because the caller ran
  /// `PasskeyUserPresence` before building (SR-3).
  static let flags: UInt8 = 0x01 | 0x04 | 0x08 | 0x10 | 0x40

  /// `privateKey` and `credentialID` are injectable for the shared vector;
  /// production passes neither.
  static func build(
    rpId: String,
    privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
    credentialID: Data? = nil
  ) throws -> Registration {
    let credentialID = try credentialID ?? randomCredentialID()
    let coseKey = coseKey(for: privateKey.publicKey)
    let authData = authenticatorData(rpId: rpId, credentialID: credentialID, coseKey: coseKey)
    return Registration(
      credentialID: credentialID,
      // ponytail: CryptoKit's PKCS#8 omits the optional ECPrivateKey
      // parameters the Dart generator writes; every reader in the repo
      // (PasskeyParser, both signers, Kotlin PKCS8EncodedKeySpec) accepts both.
      privateKeyPem: privateKey.pemRepresentation,
      coseKey: coseKey,
      authenticatorData: authData,
      attestationObject: attestationObject(authenticatorData: authData)
    )
  }

  static func randomCredentialID() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: credentialIDLength)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw Failure.randomUnavailable
    }
    return Data(bytes)
  }

  /// `{1: 2, 3: -7, -1: 1, -2: x, -3: y}` in canonical order.
  static func coseKey(for publicKey: P256.Signing.PublicKey) -> Data {
    let raw = publicKey.rawRepresentation // x ‖ y, 32 bytes each
    var data = Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
    data.append(raw.prefix(32))
    data.append(contentsOf: [0x22, 0x58, 0x20])
    data.append(raw.suffix(32))
    return data
  }

  /// `rpIdHash ‖ flags ‖ signCount(0) ‖ AAGUID(0) ‖ len ‖ credentialId ‖ COSE_Key`.
  static func authenticatorData(rpId: String, credentialID: Data, coseKey: Data) -> Data {
    var data = Data(SHA256.hash(data: Data(rpId.utf8)))
    data.append(flags)
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(Data(count: 16))
    data.append(contentsOf: [UInt8(credentialID.count >> 8 & 0xff), UInt8(credentialID.count & 0xff)])
    data.append(credentialID)
    data.append(coseKey)
    return data
  }

  /// `{"fmt": "none", "attStmt": {}, "authData": bytes}`, canonical order.
  static func attestationObject(authenticatorData: Data) -> Data {
    var data = Data([0xa3])
    data.append(contentsOf: [0x63] + Array("fmt".utf8) + [0x64] + Array("none".utf8))
    data.append(contentsOf: [0x67] + Array("attStmt".utf8) + [0xa0])
    data.append(contentsOf: [0x68] + Array("authData".utf8))
    let length = authenticatorData.count
    switch length {
    case ..<24: data.append(0x40 | UInt8(length))
    case ..<0x100: data.append(contentsOf: [0x58, UInt8(length)])
    default: data.append(contentsOf: [0x59, UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
    }
    data.append(authenticatorData)
    return data
  }
}
