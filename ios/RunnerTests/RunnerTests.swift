import AuthenticationServices
import CryptoKit
import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testPossibleMatchesUseTargetTokensWithoutGenericWords() {
    let entries = [
      makeMetadata(
        id: "acme",
        title: "Acme Admin Portal",
        displayService: "vault.acmecorp.io",
        serviceIdentifiers: [
          AutofillServiceIdentifier(type: .domain, value: "vault.acmecorp.io"),
        ]
      ),
      makeMetadata(
        id: "github",
        title: "GitHub",
        displayService: "github.com",
        serviceIdentifiers: [
          AutofillServiceIdentifier(type: .domain, value: "github.com"),
        ]
      ),
    ]

    let service = ASCredentialServiceIdentifier(
      identifier: "https://login.acme-mobile.com",
      type: .URL
    )

    XCTAssertEqual(
      AutofillMetadataSearch.targetTokens(from: [
        AutofillServiceIdentifier(type: .url, value: "https://login.acme-mobile.com"),
      ]),
      ["acme"]
    )
    XCTAssertEqual(
      AutofillMetadataSearch.possibleMatches(in: entries, for: [service]).map(\.id),
      ["acme"]
    )
  }

  func testManualSearchMatchesSubstringMetadataAndLimitsSingleCharacterQuery() {
    let entries = [
      makeMetadata(
        id: "acme",
        title: "Acme Admin Portal",
        username: "owner@example.com",
        displayService: "vault.acmecorp.io",
        serviceIdentifiers: [
          AutofillServiceIdentifier(type: .url, value: "https://vault.acmecorp.io"),
        ]
      ),
      makeMetadata(id: "zeta", title: "Zeta", displayService: "zeta.example.com"),
    ]

    XCTAssertEqual(AutofillMetadataSearch.search(entries, query: "corp").map(\.id), ["acme"])
    XCTAssertEqual(AutofillMetadataSearch.search(entries, query: "ner@example").map(\.id), ["acme"])
    XCTAssertEqual(AutofillMetadataSearch.search(entries, query: "z").map(\.id), ["zeta"])

    let manyEntries = (0..<30).map { index in
      makeMetadata(id: "alpha-\(index)", title: "Alpha \(index)")
    }
    XCTAssertEqual(
      AutofillMetadataSearch.search(manyEntries, query: "a").count,
      AutofillMetadataSearch.oneCharacterManualSearchLimit
    )
  }

  private func makeMetadata(
    id: String,
    title: String,
    username: String = "",
    displayService: String = "",
    serviceIdentifiers: [AutofillServiceIdentifier] = []
  ) -> AutofillCredentialMetadata {
    AutofillCredentialMetadata(
      id: id,
      title: title,
      username: username,
      displayService: displayService,
      serviceIdentifiers: serviceIdentifiers
    )
  }

}

// spec 023 T002 (specs/DRAFT-passkeys-all-platforms.md): passkey store and
// assertion builder. Vectors are copied from test/fixtures/passkeys/vectors.dart
// (throwaway openssl keys, never registered anywhere).
final class PasskeyTests: XCTestCase {
  private static let es256PrivateKeyPem = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgsXPNUCtYJvj/t3pO
j0l+8lPDf+Hj3BOQG+G9CqFKr9+hRANCAASowUEpj6dRNu1qqBNMFeTTEN/dfNmD
mXl5Ff0wo+76ViV5+FstAJS7jCG7WJ5DnJcOKuzypVCKEhWwiJgycFXw
-----END PRIVATE KEY-----
"""

  private static let es256PublicKeyPem = """
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqMFBKY+nUTbtaqgTTBXk0xDf3XzZ
g5l5eRX9MKPu+lYlefhbLQCUu4whu1ieQ5yXDirs8qVQihIVsIiYMnBV8A==
-----END PUBLIC KEY-----
"""

  private static let eddsaPrivateKeyPem = """
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIE/KNjFb/g7qelADCTqrUfJnMgM3wVBpkXgH6uT7QnUn
-----END PRIVATE KEY-----
"""

  private static let eddsaPublicKeyPem = """
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAfvhLh0hetAAPqudMFN0ZkH6r6IFukCxUBJERIDY8dSc=
-----END PUBLIC KEY-----
"""

  private static let rs256PrivateKeyPem = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCwsRJQhg8SR7ZI
h+74xB8Z2Mx5CollW5o6YKe1je3zV8qXviQuSOFq6VQPWOLPoft7biwOB911P/l/
4dtbHo2qT5un7SaZbnkGX6HWGKO2keX5DdzUIVKdo+06zi7iyQKmO+4ctPs9U3Kz
tGpDeopZcV/a9rvSK+cqMFy8xbnE0docEXkcy5SKbmYZiJUZeRTxOBNnlmOjUAK6
bJ12G+RHa2KrW8ryaUU1budjNSIQ2+6KjYP5QQlR0jDzHrT33B7Ua5XAyEoNwYAY
e0+/4zAZZgl3acMYXsXzgrHSS680P86IsJfXdCJLb4gZnzvlB09xYpLXhYjhLbwh
rwSoVoAdAgMBAAECggEAUb2RIfRq24OWdgaAzM/6LVxo96QivOO8PT6Cx5CB4N4f
6MQ7e7gWpH2N+E2gG/stWsQ0mEcWMgxnEby8XHKNihkrAuxIu5lqXsL2HRQoBKmJ
UQcTPoWt8SSpdld1RFBGq/20oc4uHohQ24be1BnIECnNdQBJEqlh11gpRuFYGA9R
C2z88vXZwS9w3QkWACzroHkHDtF/0M7DZli6dTqlap64HGU36SwmTpdhS4dMlOKg
kycNeNybVrd7AuusXTBRuTqgrjnB+aHqcafTvx6oGaxJJJQi6M03XnCGB1ojLyWz
nGQiVAmR/IoVQdEWrLv6LEiyLhuTMAAsOoR1ZO89xwKBgQDt0JKZqcUJ+axoomk6
B9VeMSrnzwNBbH9tUuj4D4taTlO3riyfbipd6U8tg2bZQ7mL7LPdZ+Q2cI/b0aRU
uL+j7vVu1iOd/s/uTUtTkwZi2E2EcmP2aK0+LcownPUF41QiGgk1m1FC8WeGj1xr
8mNqe3hvTf+PiPj8KMFMY9l4EwKBgQC+M/Z3UnoQ5miuR9WC2nXt/EmUlgyyQbPG
tdl4KwxisvzRu1381z4RWEs+7SvefDmhi4jl/CDO/BHBCr3pEKTiZyQWrBJiLDxX
ikL5ylRmit6Hp7rt8Tplm5zqTLAqCJSLkHxSwql0y62z1WpULoRxQjz8AFP/XlVI
D9sZFXKNDwKBgC9Ef37vUWyUJYJ+lW+lUvFv0FlWugzs5b7y9b8oR8hhPR6LDe96
VA1qbARd07lnTp/TIkTle2SeptlIJ+N2/RA2VK38/gNPPEDfOBOaa3CGEZI7skat
s5FiRIe5CrJq5rQIfMAc6N/nX25NXE9QVBY8CEoHNL5wuRxVdWYbioPlAoGAAcgu
2PNW3W2rMWbO40j0reQdNF0rhUgETSpK/Us59HrEz5o3yTSjCjqPieli7dSwHYlX
IQB5tja6W9qj6NkVEmHw/p1iFrVfY1qSQhDZNZS7fP3fTHdkGquYjsFlLR+jdKNH
5uaX+9YkrHilZGCDMSRzudCu+MeDeQddACEpT5UCgYEAlQ2oiEU9ow/i7cHqMXi9
spEktxPLLsJD3p4ZRsLGW9ofCASFAvbB7FqNjYFQXynsR6CUfov/bDCI0vUF32yW
6sxAAwWmkjl8tlK5AoN7NEw14s3vwfzWsp7OogM2jlH3zgSuIaKC8gYad2jKXIqd
S3j5FI3TDfF5Y0USOnDKs6c=
-----END PRIVATE KEY-----
"""

  private static let rs256PublicKeyPem = """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsLESUIYPEke2SIfu+MQf
GdjMeQqJZVuaOmCntY3t81fKl74kLkjhaulUD1jiz6H7e24sDgfddT/5f+HbWx6N
qk+bp+0mmW55Bl+h1hijtpHl+Q3c1CFSnaPtOs4u4skCpjvuHLT7PVNys7RqQ3qK
WXFf2va70ivnKjBcvMW5xNHaHBF5HMuUim5mGYiVGXkU8TgTZ5Zjo1ACumyddhvk
R2tiq1vK8mlFNW7nYzUiENvuio2D+UEJUdIw8x6099we1GuVwMhKDcGAGHtPv+Mw
GWYJd2nDGF7F84Kx0kuvND/OiLCX13QiS2+IGZ875QdPcWKS14WI4S28Ia8EqFaA
HQIDAQAB
-----END PUBLIC KEY-----
"""

  private static let rpId = "webauthn.io"
  private static let rpIdHashHex = "74a6ea9213c99c2f74b22492b320cf40262a94c1a950a0397f29250b60841ef0"
  private static let authDataHex = rpIdHashHex + "1d00000000"
  private let clientDataHash = Data(SHA256.hash(data: Data("client-data".utf8)))

  private func secret(_ pem: String, _ alg: AutofillPasskeyAlgorithm) -> AutofillPasskeySecret {
    AutofillPasskeySecret(
      rpId: Self.rpId, credentialId: "Y3JlZC0x", userHandle: "dXNlci0x",
      username: "alice", privateKeyPem: pem, algorithm: alg,
      backupEligible: true, backupState: true)
  }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  private func der(_ pem: String) -> Data {
    let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    return Data(base64Encoded: body)!
  }

  func testAuthenticatorDataMatchesVector() {
    let data = PasskeyAssertionBuilder.authenticatorData(
      rpId: Self.rpId, backupEligible: true, backupState: true)
    XCTAssertEqual(hex(data), Self.authDataHex)
  }

  func testEs256SignatureVerifies() throws {
    let a = try PasskeyAssertionBuilder.assert(
      secret: secret(Self.es256PrivateKeyPem, .es256), clientDataHash: clientDataHash)
    let pub = try P256.Signing.PublicKey(pemRepresentation: Self.es256PublicKeyPem)
    let sig = try P256.Signing.ECDSASignature(derRepresentation: a.signature)
    XCTAssertEqual(hex(a.authenticatorData), Self.authDataHex)
    XCTAssertTrue(pub.isValidSignature(sig, for: a.authenticatorData + clientDataHash))
  }

  func testEdDsaSignatureVerifies() throws {
    let a = try PasskeyAssertionBuilder.assert(
      secret: secret(Self.eddsaPrivateKeyPem, .eddsa), clientDataHash: clientDataHash)
    let pub = try Curve25519.Signing.PublicKey(
      rawRepresentation: der(Self.eddsaPublicKeyPem).suffix(32))
    XCTAssertEqual(a.signature.count, 64)
    XCTAssertTrue(pub.isValidSignature(a.signature, for: a.authenticatorData + clientDataHash))
  }

  func testRs256SignatureVerifies() throws {
    let a = try PasskeyAssertionBuilder.assert(
      secret: secret(Self.rs256PrivateKeyPem, .rs256), clientDataHash: clientDataHash)
    // SecKey wants PKCS#1: the SPKI BIT STRING minus its leading unused-bits byte.
    let spki = try XCTUnwrap(DERNode.parse(der(Self.rs256PublicKeyPem)))
    let pkcs1 = spki.children[1].content.dropFirst()
    let key = try XCTUnwrap(SecKeyCreateWithData(
      Data(pkcs1) as CFData,
      [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
      nil))
    XCTAssertTrue(SecKeyVerifySignature(
      key, .rsaSignatureMessagePKCS1v15SHA256,
      (a.authenticatorData + clientDataHash) as CFData, a.signature as CFData, nil))
  }

  func testBadPemThrows() {
    XCTAssertThrowsError(try PasskeyAssertionBuilder.assert(
      secret: secret("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----", .es256),
      clientDataHash: clientDataHash))
  }

  /// Real publish then read: needs the app group container and the keychain
  /// the test host is entitled to.
  func testSealUnsealRoundTripKeepsPemOutOfMetadata() throws {
    let store = SharedAutofillStore()
    let passkey = AutofillInputPasskey(
      rpId: Self.rpId, credentialId: "Y3JlZC0x", userHandle: "dXNlci0x", username: "alice",
      privateKeyPem: Self.es256PrivateKeyPem, algorithm: "ES256",
      backupEligible: true, backupState: true)
    let entry = AutofillCredentialPublishEntry(
      id: "pk-1", title: "WebAuthn", username: "alice", password: "",
      url: "https://webauthn.io", serviceIdentifiers: [], passkeys: [passkey])

    let done = expectation(description: "publish")
    var outcome: Result<AutofillPublishOutcome, Error>?
    store.publishCredentials(databaseId: "t002-db", entries: [entry]) {
      outcome = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    defer {
      let cleared = expectation(description: "clear")
      store.clearCredentials(databaseId: nil) { _ in cleared.fulfill() }
      wait(for: [cleared], timeout: 30)
    }
    XCTAssertEqual(try outcome?.get().passkeyPublishedCount, 1)

    let metadataURL = try XCTUnwrap(SharedAutofillPaths.metadataURL())
    let metadataText = try String(contentsOf: metadataURL, encoding: .utf8)
    XCTAssertFalse(metadataText.contains("PRIVATE KEY"))
    XCTAssertFalse(metadataText.contains("MIGHAgEAMBMGByqGSM49"))
    XCTAssertFalse(metadataText.contains("dXNlci0x"), "user handle must stay sealed")
    XCTAssertTrue(metadataText.contains("Y3JlZC0x"))

    let sealed = try store.readCredentialSecret(id: "pk-1")
    XCTAssertEqual(sealed.passkeys.count, 1)
    XCTAssertEqual(sealed.passkeys[0].privateKeyPem, Self.es256PrivateKeyPem)
    XCTAssertEqual(sealed.passkeys[0].algorithm, .es256)
    XCTAssertEqual(sealed.passkeys[0].userHandle, "dXNlci0x")
  }
}

// spec 024 T016 / T017 (specs/DRAFT-passkeys-all-platforms.md): registration
// builder and pending passkey queue. Pure: no App Group, no keychain. Constants
// copied from test/fixtures/passkeys/registration_vector.json and
// test/fixtures/passkeys/pending_record_v1.json (FIXTURE ONLY key material).
final class PasskeyRegistrationAndPendingTests: XCTestCase {
  // registration_vector.json
  private static let fixturePem = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg8F12rkq5n+Wm9psx\nSMI2PQ68td61LIO9CKipNRgskZmgCgYIKoZIzj0DAQehRANCAAQnTwOdrfPsadAx\n0WvjvN3W0OeslyoTPqrRo4gxUU/TiUID132Hln20OG7Ihe4gmkEN7vzQtHRcBbks\nntSuh/cl\n-----END PRIVATE KEY-----"
  private static let credentialIdHex = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
  private static let coseKeyHex = "a5010203262001215820274f039dadf3ec69d031d16be3bcddd6d0e7ac972a133eaad1a38831514fd3892258204203d77d87967db4386ec885ee209a410deefcd0b4745c05b92c9ed4ae87f725"
  private static let authDataHex = "a379a6f6eeafb9a55e378c118034e2751e682fab9f2d30ab13d2125586ce19475d00000000000000000000000000000000000000000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f" + coseKeyHex
  private static let attestationObjectHex = "a363666d74646e6f6e656761747453746d74a068617574684461746158a4" + authDataHex

  // pending_record_v1.json
  private static let aesKeyHex = "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
  private static let nonceHex = "808182838485868788898a8b"
  private static let recordId = "00000000-0000-4000-8000-000000000001"
  private static let databaseId = "fixture-database-id"
  private static let createdAt: Int64 = 1767225600000
  private static let credentialId = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
  private static let aad = "1|00000000-0000-4000-8000-000000000001|fixture-database-id|1767225600000|example.com|ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8|YWxpY2U"
  private static let payloadJson = #"{"rpId":"example.com","credentialId":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8","userHandle":"oKGio6SlpqeoqaqrrK2urw","username":"alice","displayName":"Alice","privateKeyPem":"-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg8F12rkq5n+Wm9psx\nSMI2PQ68td61LIO9CKipNRgskZmgCgYIKoZIzj0DAQehRANCAAQnTwOdrfPsadAx\n0WvjvN3W0OeslyoTPqrRo4gxUU/TiUID132Hln20OG7Ihe4gmkEN7vzQtHRcBbks\nntSuh/cl\n-----END PRIVATE KEY-----","algorithm":"ES256","be":true,"bs":true,"origin":"https://example.com"}"#
  private static let sealed = "gIGCg4SFhoeIiYqLVnzMt2sQCLlKD+hJH9L5R9afpr9vS8R3jOscsb9hCB1/dd725tbkBEq7jsGLNEMOA4nmcdwuSoVP9g8Yjvr8rwHe0CyTiDkTYdtWVWH8e+Ul/w3CnebYgTRFHzVtbKIKfrva8hDxc5rOUH1x4MNRrvGFtJbNoXUkxaWoExkcTa6xEQV+KTgpcoAWPF+bKvdZhh3q8KivRuCk+oSMAViQLV8JJaGA3HsFkbXN+ANgHUgQEwrofYbeFIjc+M3xqK+8O8NSsHUwdGjs9sFt+40mxvbOFSmuqCEqGGBEp+qlJUZSPZbEwq5KVPXMvjNcF9P7ielqIhP5MVn3r9LhYeHYjv14cPJzN0d8ezqvbTaavnzxClGKAcdg0sSc4BifiJ4onKiocnh5Reoq0xodij334SCMEkHK4L4ptnQjq6UHH/HEeTCAYNxozqchliVhUxVgGVS+odNz375zYtba0XeGTkF2O1AtBuf4OUkp73aXELF9QwiIp/dnki2I08OhLZGwAAdX7TCLQEXhproNpxz0nzG6T0X9oIscMKGQ/K5qBdxy4/tU9Y548TEEovzG7wbEvEJE7Smr1/v7jok2meAnTnBh0yIsPJn6BAq1LD6FX+iMYP3+WvW1bmW8iTkEgKk10vhho3T4fUWWyAok6qDfa33Usd0BNwF+rgD5SdGpTk29rTdYAeqtvQfSEvzDJOPiwyg="

  private static func bytes(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      data.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return data
  }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  private var key: SymmetricKey { SymmetricKey(data: Self.bytes(Self.aesKeyHex)) }

  private func envelope(
    recordId: String = recordId, databaseId: String = databaseId, rpId: String = "example.com",
    credentialId: String = credentialId, username: String = "alice", sealed: String = sealed
  ) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "version": 1, "algorithm": "AES-256-GCM", "keyId": "passkey-pending-v1",
      "recordId": recordId, "databaseId": databaseId,
      "createdAtEpochMs": Self.createdAt, "rpId": rpId, "credentialId": credentialId,
      "username": username, "sealed": sealed,
    ])
  }

  private var fixtureMetadata: PendingPasskeyMetadata {
    PendingPasskeyMetadata(
      recordId: Self.recordId, databaseId: Self.databaseId, createdAtEpochMs: Self.createdAt,
      rpId: "example.com", credentialId: Self.credentialId, username: "alice")
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
  }

  private func der(_ pem: String) -> Data {
    Data(base64Encoded: pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined())!
  }

  // MARK: T017

  func testRegistrationReproducesSharedVector() throws {
    let registration = try PasskeyRegistrationBuilder.build(
      rpId: "example.com",
      privateKey: P256.Signing.PrivateKey(pemRepresentation: Self.fixturePem),
      credentialID: Self.bytes(Self.credentialIdHex))
    XCTAssertEqual(hex(registration.coseKey), Self.coseKeyHex)
    XCTAssertEqual(hex(registration.authenticatorData), Self.authDataHex)
    XCTAssertEqual(hex(registration.attestationObject), Self.attestationObjectHex)
  }

  /// The generated PEM has the fixture PEM's PKCS#8 shape where PasskeyParser
  /// and the signers look: same AlgorithmIdentifier (ecPublicKey, prime256v1),
  /// an ECPrivateKey v1 with a 32-byte scalar and the matching public point.
  func testGeneratedPemHasFixtureShapeAndSigns() throws {
    let registration = try PasskeyRegistrationBuilder.build(rpId: "example.com")
    XCTAssertEqual(registration.credentialID.count, 32)
    let pem = registration.privateKeyPem
    XCTAssertTrue(pem.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
    XCTAssertTrue(pem.hasSuffix("\n-----END PRIVATE KEY-----"))

    let fixture = try XCTUnwrap(DERNode.parse(der(Self.fixturePem)))
    let info = try XCTUnwrap(DERNode.parse(der(pem)))
    XCTAssertEqual(info.tag, DERNode.sequence)
    XCTAssertEqual(info.children.count, 3)
    XCTAssertEqual(info.children[0].content, Data([0]))
    XCTAssertEqual(info.children[1].content, fixture.children[1].content, "AlgorithmIdentifier")
    let ec = try XCTUnwrap(DERNode.parse(info.children[2].content))
    XCTAssertEqual(ec.children[0].content, Data([1]))
    XCTAssertEqual(ec.children[1].content.count, 32)
    let point = try XCTUnwrap(ec.children.last?.children.first?.content)
    let cose = registration.coseKey
    XCTAssertEqual(point, Data([0]) + Data([4]) + cose[10..<42] + cose[45..<77])

    let clientDataHash = Data(SHA256.hash(data: Data("client-data".utf8)))
    let assertion = try PasskeyAssertionBuilder.assert(
      secret: AutofillPasskeySecret(
        rpId: "example.com", credentialId: registration.credentialID.base64URLEncodedString,
        userHandle: nil, username: "alice", privateKeyPem: pem, algorithm: .es256,
        backupEligible: true, backupState: true),
      clientDataHash: clientDataHash)
    let pub = try P256.Signing.PublicKey(x963Representation: point.dropFirst())
    XCTAssertTrue(pub.isValidSignature(
      try P256.Signing.ECDSASignature(derRepresentation: assertion.signature),
      for: assertion.authenticatorData + clientDataHash))
  }

  // MARK: T016 codec

  func testFixtureEnvelopeOpensToPayload() throws {
    let record = try PendingPasskeyCodec.open(envelope(), key: key, expectedRecordId: Self.recordId)
    XCTAssertEqual(record.databaseId, Self.databaseId)
    XCTAssertEqual(record.createdAtEpochMs, Self.createdAt)
    XCTAssertEqual(record.credentialId, Self.credentialId)
    XCTAssertEqual(record.userHandle, "oKGio6SlpqeoqaqrrK2urw")
    XCTAssertEqual(record.privateKeyPem, Self.fixturePem)
    XCTAssertEqual(record.displayName, "Alice")
    XCTAssertEqual(String(decoding: PendingPasskeyCodec.payloadJSON(record), as: UTF8.self), Self.payloadJson)
    XCTAssertEqual(record.metadata, fixtureMetadata)
    XCTAssertEqual(PendingPasskeyCodec.aad(fixtureMetadata), Data(Self.aad.utf8))
    XCTAssertFalse(record.description.contains("PRIVATE"))
  }

  func testSealWithFixtureNonceReproducesEnvelope() throws {
    let record = try PendingPasskeyCodec.open(envelope(), key: key, expectedRecordId: Self.recordId)
    let data = try PendingPasskeyCodec.seal(
      record, key: key, nonce: AES.GCM.Nonce(data: Self.bytes(Self.nonceHex)))
    // The whole envelope, compact and in the fixture's envelopeKeyOrder.
    XCTAssertEqual(
      String(decoding: data, as: UTF8.self),
      #"{"version":1,"algorithm":"AES-256-GCM","keyId":"passkey-pending-v1","recordId":"00000000-0000-4000-8000-000000000001","databaseId":"fixture-database-id","createdAtEpochMs":1767225600000,"rpId":"example.com","credentialId":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8","username":"alice","sealed":""#
        + Self.sealed + #""}"#)
  }

  /// The AAD carries the username as base64url, so "|" cannot shift a field.
  func testAadKeepsUsernameUnambiguous() {
    func aad(credentialId: String, username: String) -> Data {
      PendingPasskeyCodec.aad(PendingPasskeyMetadata(
        recordId: Self.recordId, databaseId: "d", createdAtEpochMs: 1, rpId: "a.b",
        credentialId: credentialId, username: username))
    }
    XCTAssertEqual(
      String(decoding: aad(credentialId: "AA", username: "a|b\u{e9}?"), as: UTF8.self),
      "1|\(Self.recordId)|d|1|a.b|AA|YXxiw6k_")
    XCTAssertNotEqual(aad(credentialId: "AA|x", username: "y"), aad(credentialId: "AA", username: "x|y"))
  }

  /// Listing reads the envelope only: no key, and nothing of the payload.
  func testMetadataNeedsNoKey() throws {
    XCTAssertEqual(try PendingPasskeyCodec.metadata(envelope(), expectedRecordId: Self.recordId), fixtureMetadata)
    XCTAssertThrowsError(try PendingPasskeyCodec.metadata(Data("not json".utf8), expectedRecordId: Self.recordId))
    XCTAssertThrowsError(try PendingPasskeyCodec.metadata(
      envelope(), expectedRecordId: "00000000-0000-4000-8000-000000000002"))
    // The previous envelope shape (no rpId, credentialId, username).
    let old = try JSONSerialization.data(withJSONObject: [
      "version": 1, "algorithm": "AES-256-GCM", "keyId": "passkey-pending-v1",
      "recordId": Self.recordId, "databaseId": Self.databaseId,
      "createdAtEpochMs": Self.createdAt, "sealed": Self.sealed,
    ])
    XCTAssertThrowsError(try PendingPasskeyCodec.metadata(old, expectedRecordId: Self.recordId))
    XCTAssertThrowsError(try PendingPasskeyCodec.open(old, key: key, expectedRecordId: Self.recordId))
  }

  /// A seal that authenticates, over a payload that disagrees with its
  /// envelope, is unreadable: what was listed must be what gets signed.
  func testPayloadMustMatchEnvelope() throws {
    let record = try PendingPasskeyCodec.open(envelope(), key: key, expectedRecordId: Self.recordId)
    func forged(rpId: String = "example.com", credentialId: String = Self.credentialId, username: String = "alice") throws -> Data {
      let claimed = PendingPasskeyMetadata(
        recordId: Self.recordId, databaseId: Self.databaseId, createdAtEpochMs: Self.createdAt,
        rpId: rpId, credentialId: credentialId, username: username)
      let box = try AES.GCM.seal(
        PendingPasskeyCodec.payloadJSON(record), using: key, authenticating: PendingPasskeyCodec.aad(claimed))
      return envelope(
        rpId: rpId, credentialId: credentialId, username: username,
        sealed: try XCTUnwrap(box.combined).base64EncodedString())
    }
    XCTAssertEqual(try PendingPasskeyCodec.open(forged(), key: key, expectedRecordId: Self.recordId), record)
    XCTAssertThrowsError(try PendingPasskeyCodec.open(forged(rpId: "evil.example"), key: key, expectedRecordId: Self.recordId))
    XCTAssertThrowsError(try PendingPasskeyCodec.open(forged(credentialId: "AAAA"), key: key, expectedRecordId: Self.recordId))
    XCTAssertThrowsError(try PendingPasskeyCodec.open(forged(username: "mallory"), key: key, expectedRecordId: Self.recordId))
  }

  func testNullOptionalsAreWrittenAsNull() {
    let record = PendingPasskeyRecord(
      recordId: Self.recordId, databaseId: "d", createdAtEpochMs: 1, rpId: "a.b",
      credentialId: "AA", userHandle: nil, username: "u", displayName: nil,
      privateKeyPem: "p", algorithm: "ES256", be: false, bs: false, origin: "https://a.b/x")
    XCTAssertEqual(
      String(decoding: PendingPasskeyCodec.payloadJSON(record), as: UTF8.self),
      #"{"rpId":"a.b","credentialId":"AA","userHandle":null,"username":"u","displayName":null,"privateKeyPem":"p","algorithm":"ES256","be":false,"bs":false,"origin":"https://a.b/x"}"#)
  }

  func testChangedAadIsRejected() {
    XCTAssertThrowsError(try PendingPasskeyCodec.open(
      envelope(databaseId: "other-database"), key: key, expectedRecordId: Self.recordId))
    // The plaintext copies are authenticated: changing only one fails the seal.
    XCTAssertThrowsError(try PendingPasskeyCodec.open(
      envelope(rpId: "evil.example"), key: key, expectedRecordId: Self.recordId))
    XCTAssertThrowsError(try PendingPasskeyCodec.open(
      envelope(credentialId: "AAAA"), key: key, expectedRecordId: Self.recordId))
    XCTAssertThrowsError(try PendingPasskeyCodec.open(
      envelope(username: "mallory"), key: key, expectedRecordId: Self.recordId))
    let renamed = "00000000-0000-4000-8000-000000000002"
    // Renamed file: envelope still names the old id.
    XCTAssertThrowsError(try PendingPasskeyCodec.open(envelope(), key: key, expectedRecordId: renamed))
    // Renamed file and envelope rewritten to match: AAD no longer authenticates.
    XCTAssertThrowsError(try PendingPasskeyCodec.open(
      envelope(recordId: renamed), key: key, expectedRecordId: renamed))
    XCTAssertThrowsError(try PendingPasskeyCodec.open(
      envelope(), key: SymmetricKey(size: .bits256), expectedRecordId: Self.recordId))
  }

  // MARK: T016 store (temporary directory, in-memory key)

  func testStoreRoundTripUnreadableAndResolve() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var memoryKey: SymmetricKey?
    var createRequests = 0
    let store = PendingPasskeyStore(directoryURL: dir) { create in
      if create {
        createRequests += 1
        if memoryKey == nil { memoryKey = SymmetricKey(size: .bits256) }
      }
      return memoryKey
    }

    XCTAssertEqual(store.read().records.count, 0)
    XCTAssertNil(memoryKey, "reading never creates the key")

    let record = PendingPasskeyRecord(
      recordId: PendingPasskeyStore.newRecordId(), databaseId: "db-1",
      createdAtEpochMs: 1767225600000, rpId: "example.com",
      credentialId: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8", userHandle: nil,
      username: "alice", displayName: nil, privateKeyPem: Self.fixturePem,
      algorithm: "ES256", be: true, bs: true, origin: "https://example.com")
    try store.write(record)
    XCTAssertEqual(createRequests, 1)
    let file = dir.appendingPathComponent(record.recordId + ".sealed.json")
    let onDisk = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(onDisk.contains("PRIVATE KEY"))
    XCTAssertFalse(onDisk.contains("MIGTAgEAMBMG"), "the key is only inside the seal")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1, "no temp file left")

    // Garbage under a valid name, a record sealed with another key, and a bad name.
    let garbage = dir.appendingPathComponent("00000000-0000-4000-8000-0000000000aa.sealed.json")
    try Data("not json".utf8).write(to: garbage)
    let foreignId = "00000000-0000-4000-8000-0000000000bb"
    let foreign = dir.appendingPathComponent(foreignId + ".sealed.json")
    try PendingPasskeyCodec.seal(
      PendingPasskeyRecord(
        recordId: foreignId, databaseId: "db-1", createdAtEpochMs: 1, rpId: "x.y",
        credentialId: "AA", userHandle: nil, username: "", displayName: nil,
        privateKeyPem: "p", algorithm: "ES256", be: true, bs: true, origin: "https://x.y"),
      key: SymmetricKey(size: .bits256)
    ).write(to: foreign)
    let badName = dir.appendingPathComponent("..%2Fevil.sealed.json")
    try Data("{}".utf8).write(to: badName)

    let read = store.read()
    XCTAssertEqual(read.records, [record])
    XCTAssertEqual(read.unreadableCount, 3)
    XCTAssertEqual(createRequests, 1, "reading never creates the key")
    // Metadata: the foreign record is a valid envelope and is listed; garbage
    // and the bad name are not. Only the right key opens a record.
    XCTAssertEqual(Set(store.readMetadata().map(\.recordId)), [record.recordId, foreignId])
    XCTAssertEqual(store.read(recordId: record.recordId), record)
    XCTAssertNil(store.read(recordId: foreignId))
    XCTAssertNil(store.read(recordId: "00000000-0000-4000-8000-0000000000aa"))
    XCTAssertNil(store.read(recordId: "../x"))
    for url in [garbage, foreign, badName] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "unreadable kept")
    }

    XCTAssertTrue(try store.resolve(recordId: record.recordId))
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertTrue(try store.resolve(recordId: record.recordId), "already absent")
    XCTAssertThrowsError(try store.resolve(recordId: "../autofill_cache_v2"))
    XCTAssertThrowsError(try store.write(PendingPasskeyRecord(
      recordId: "../x", databaseId: "d", createdAtEpochMs: 1, rpId: "a", credentialId: "AA",
      userHandle: nil, username: "", displayName: nil, privateKeyPem: "p",
      algorithm: "ES256", be: true, bs: true, origin: "o")))
  }

  /// FR-11 against the real App Group container and keychain: iOS simulator
  /// only (throwaway container). Never on macOS, where it would reach the
  /// developer's live autofill cache.
  func testQueueSurvivesClearCredentials() throws {
#if os(macOS)
    throw XCTSkip("touches the real macOS App Group container and keychain")
#else
    let store = PendingPasskeyStore()
    let record = PendingPasskeyRecord(
      recordId: PendingPasskeyStore.newRecordId(), databaseId: "t016-db", createdAtEpochMs: 1,
      rpId: "example.com", credentialId: "AA", userHandle: nil, username: "alice",
      displayName: nil, privateKeyPem: Self.fixturePem, algorithm: "ES256",
      be: true, bs: true, origin: "https://example.com")
    try store.write(record)
    defer { _ = try? store.resolve(recordId: record.recordId) }

    let cleared = expectation(description: "clear")
    SharedAutofillStore().clearCredentials(databaseId: nil) { _ in cleared.fulfill() }
    wait(for: [cleared], timeout: 30)

    XCTAssertEqual(store.read().records.filter { $0.recordId == record.recordId }, [record])
#endif
  }

  /// Listing and matching never touch the key; tampered plaintext metadata is
  /// listed as written but can never be opened, so it can never sign.
  func testMetadataReadNeverAsksForTheKey() throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let memoryKey = SymmetricKey(size: .bits256)
    var keyRequests = 0
    let store = PendingPasskeyStore(directoryURL: dir) { _ in
      keyRequests += 1
      return memoryKey
    }
    XCTAssertEqual(store.readMetadata(), [])
    let record = PendingPasskeyRecord(
      recordId: PendingPasskeyStore.newRecordId(), databaseId: "db-1", createdAtEpochMs: 7,
      rpId: "example.com", credentialId: Self.credentialId, userHandle: "oKGi",
      username: "alice", displayName: nil, privateKeyPem: Self.fixturePem,
      algorithm: "ES256", be: true, bs: true, origin: "https://example.com")
    try store.write(record)
    keyRequests = 0

    XCTAssertEqual(store.readMetadata(), [record.metadata])
    XCTAssertEqual(keyRequests, 0, "no keychain access to list")

    let file = dir.appendingPathComponent(record.recordId + ".sealed.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    object["rpId"] = "evil.example"
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    XCTAssertEqual(store.readMetadata().map(\.rpId), ["evil.example"])
    XCTAssertEqual(keyRequests, 0)
    XCTAssertNil(store.read(recordId: record.recordId), "tampered metadata never opens")
    XCTAssertEqual(store.read().unreadableCount, 1)
  }

  /// FR-5: the write goes through the flush-and-rename path and leaves one
  /// complete file; a second write of the same record id never replaces it.
  func testWriteIsCompleteAndNeverOverwrites() throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let memoryKey = SymmetricKey(size: .bits256)
    let store = PendingPasskeyStore(directoryURL: dir) { _ in memoryKey }
    let record = PendingPasskeyRecord(
      recordId: PendingPasskeyStore.newRecordId(), databaseId: "db-1", createdAtEpochMs: 7,
      rpId: "example.com", credentialId: "AA", userHandle: nil, username: "alice",
      displayName: nil, privateKeyPem: Self.fixturePem, algorithm: "ES256",
      be: true, bs: true, origin: "https://example.com")

    // A leftover temp file is never written through.
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let temp = dir.appendingPathComponent(record.recordId + ".tmp")
    try Data("stale".utf8).write(to: temp)
    XCTAssertThrowsError(try store.write(record))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "nothing left behind")

    try store.write(record)
    let file = dir.appendingPathComponent(record.recordId + ".sealed.json")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [file.lastPathComponent])
    let bytes = try Data(contentsOf: file)
    XCTAssertEqual(try PendingPasskeyCodec.open(bytes, key: memoryKey, expectedRecordId: record.recordId), record)
    let permissions = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
    XCTAssertEqual(permissions.intValue & 0o077, 0, "owner only")
  }

  func testWriteWithoutKeyFailsAndLeavesNothing() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PendingPasskeyStore(directoryURL: dir) { _ in nil }
    XCTAssertThrowsError(try store.write(PendingPasskeyRecord(
      recordId: PendingPasskeyStore.newRecordId(), databaseId: "d", createdAtEpochMs: 1,
      rpId: "a", credentialId: "AA", userHandle: nil, username: "", displayName: nil,
      privateKeyPem: "p", algorithm: "ES256", be: true, bs: true, origin: "o")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
  }

  /// The pre-unlock banner count: every record file, readable or not, any
  /// vault, by file name alone. The key is never asked for.
  func testCountNeverAsksForTheKey() throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let memoryKey = SymmetricKey(size: .bits256)
    var keyRequests = 0
    let store = PendingPasskeyStore(directoryURL: dir) { _ in
      keyRequests += 1
      return memoryKey
    }
    XCTAssertEqual(store.count(), 0, "no directory yet")
    for databaseId in ["db-1", "db-2"] {
      try store.write(PendingPasskeyRecord(
        recordId: PendingPasskeyStore.newRecordId(), databaseId: databaseId, createdAtEpochMs: 7,
        rpId: "example.com", credentialId: "AA", userHandle: nil, username: "alice",
        displayName: nil, privateKeyPem: Self.fixturePem, algorithm: "ES256",
        be: true, bs: true, origin: "https://example.com"))
    }
    // Unreadable records count; a temp file and a stray file do not.
    try Data("not json".utf8).write(
      to: dir.appendingPathComponent("00000000-0000-4000-8000-0000000000aa.sealed.json"))
    try Data("x".utf8).write(to: dir.appendingPathComponent("00000000-0000-4000-8000-0000000000bb.tmp"))
    try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    keyRequests = 0

    XCTAssertEqual(store.count(), 3)
    XCTAssertEqual(keyRequests, 0, "counting never touches the key")
    XCTAssertEqual(PendingPasskeyStore(directoryURL: nil) { _ in memoryKey }.count(), 0)
  }

  /// A crash between temp-file creation and the rename leaves the temp file;
  /// the next write removes the old ones, and only those.
  func testWriteSweepsStaleTempFilesOnly() throws {
    let fm = FileManager.default
    let dir = temporaryDirectory()
    defer { try? fm.removeItem(at: dir) }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-PendingPasskeyStore.staleTempAge - 60)
    func file(_ name: String, modified: Date?) throws -> URL {
      let url = dir.appendingPathComponent(name)
      try Data("x".utf8).write(to: url)
      if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
      return url
    }
    let staleTemp = try file("00000000-0000-4000-8000-0000000000a1.tmp", modified: old)
    let freshTemp = try file("00000000-0000-4000-8000-0000000000a2.tmp", modified: nil)
    let oldRecord = try file("00000000-0000-4000-8000-0000000000a3.sealed.json", modified: old)
    let oldOther = try file("notes.txt", modified: old)

    let memoryKey = SymmetricKey(size: .bits256)
    let store = PendingPasskeyStore(directoryURL: dir) { _ in memoryKey }
    try store.write(PendingPasskeyRecord(
      recordId: PendingPasskeyStore.newRecordId(), databaseId: "db-1", createdAtEpochMs: 7,
      rpId: "example.com", credentialId: "AA", userHandle: nil, username: "alice",
      displayName: nil, privateKeyPem: Self.fixturePem, algorithm: "ES256",
      be: true, bs: true, origin: "https://example.com"))

    XCTAssertFalse(fm.fileExists(atPath: staleTemp.path), "old temp file swept")
    XCTAssertTrue(fm.fileExists(atPath: freshTemp.path), "a writer in flight keeps its temp file")
    XCTAssertTrue(fm.fileExists(atPath: oldRecord.path), "a record is never swept, however old")
    XCTAssertTrue(fm.fileExists(atPath: oldOther.path))
    XCTAssertEqual(store.count(), 2)
  }
}

// spec 024 T018 / T019 (specs/DRAFT-passkeys-all-platforms.md): the pure
// decisions of the registration flow and the cached-plus-pending sign-in list.
// No App Group, no keychain: a temporary directory and an in-memory key.
final class PasskeyProviderLogicTests: XCTestCase {
  private static let published = "sha256:0123abcd"
  private static let credentialA = Data((0..<32).map { UInt8($0) })
  private static let credentialB = Data((32..<64).map { UInt8($0) })

  private func input(
    rpId: String = "example.com", userName: String = "alice",
    userHandle: Data = Data([0xa0, 0xa1, 0xfb, 0xff]),
    algorithms: [Int] = [-7], excluded: [Data] = []
  ) -> PasskeyRegistrationInput {
    PasskeyRegistrationInput(
      rpId: rpId, userName: userName, userHandle: userHandle,
      supportedAlgorithms: algorithms, excludedCredentialIds: excluded)
  }

  private func cached(
    _ id: String, rpId: String = "example.com", credential: Data, username: String = "alice"
  ) -> AutofillCredentialMetadata {
    AutofillCredentialMetadata(
      id: id, title: "Example", username: username, displayService: rpId, serviceIdentifiers: [],
      passkeys: [AutofillPasskeyMetadata(rpId: rpId, credentialId: credential.base64URLEncodedString)])
  }

  private func pending(
    rpId: String = "example.com", credential: Data, databaseId: String = PasskeyProviderLogicTests.published,
    username: String = "alice"
  ) -> PendingPasskeyMetadata {
    PasskeyProviderLogic.makeRecord(
      input(rpId: rpId, userName: username), databaseId: databaseId,
      credentialID: credential, privateKeyPem: "pem").metadata
  }

  private func status(available: Bool, databaseId: String?) -> AutofillStoreStatus {
    AutofillStoreStatus(
      appGroupAvailable: true, keychainAccessGroupAvailable: true, metadataCount: 1,
      encryptedCacheAvailable: available, cacheAvailable: available,
      databaseId: databaseId, generatedAtEpochMs: 1)
  }

  func testEs256OfferGate() {
    XCTAssertTrue(PasskeyProviderLogic.offersES256([-7]))
    XCTAssertTrue(PasskeyProviderLogic.offersES256([-257, -7]))
    XCTAssertFalse(PasskeyProviderLogic.offersES256([-257, -8]))
    XCTAssertTrue(PasskeyProviderLogic.offersES256([]), "empty is the WebAuthn default set")
  }

  func testPublishedDatabaseIdIsTakenUnchangedOrAbsent() {
    XCTAssertEqual(
      PasskeyProviderLogic.publishedDatabaseId(status(available: true, databaseId: Self.published)),
      Self.published)
    XCTAssertNil(PasskeyProviderLogic.publishedDatabaseId(status(available: false, databaseId: Self.published)))
    XCTAssertNil(PasskeyProviderLogic.publishedDatabaseId(status(available: true, databaseId: nil)))
    XCTAssertNil(PasskeyProviderLogic.publishedDatabaseId(status(available: true, databaseId: "")))
  }

  func testExclusionAndSameAccountConflicts() {
    let cache = [cached("e1", credential: Self.credentialA)]
    let queue = [pending(credential: Self.credentialB, databaseId: "sha256:other-vault", username: "bob")]

    XCTAssertEqual(PasskeyProviderLogic.conflict(
      input(userName: "carol", excluded: [Self.credentialA]), cached: cache, pending: []), .excludedCredential)
    XCTAssertEqual(PasskeyProviderLogic.conflict(
      input(userName: "carol", excluded: [Self.credentialB]), cached: [], pending: queue), .excludedCredential,
      "a pending record of any vault counts")
    XCTAssertEqual(PasskeyProviderLogic.conflict(
      input(rpId: "other.example", userName: "carol", excluded: [Self.credentialA]), cached: cache, pending: queue),
      .none, "an excluded id held for another rp is not a match")
    XCTAssertEqual(PasskeyProviderLogic.conflict(
      input(userName: "carol", excluded: [Data([1, 2, 3])]), cached: cache, pending: queue), .none)

    XCTAssertEqual(PasskeyProviderLogic.conflict(input(userName: "ALICE"), cached: cache, pending: []), .sameAccount)
    XCTAssertEqual(PasskeyProviderLogic.conflict(input(userName: "bob"), cached: [], pending: queue), .sameAccount)
    XCTAssertEqual(PasskeyProviderLogic.conflict(
      input(rpId: "other.example"), cached: cache, pending: queue), .none)
  }

  func testRecordFromRequestRoundTripsThroughTheQueue() throws {
    let record = PasskeyProviderLogic.makeRecord(
      input(), databaseId: Self.published, credentialID: Data([0xfb, 0xff, 0xfe]),
      privateKeyPem: "SENTINEL-PEM", recordId: "00000000-0000-4000-8000-000000000002",
      createdAtEpochMs: 1767225600000)
    XCTAssertEqual(record.databaseId, Self.published)
    XCTAssertEqual(record.rpId, "example.com")
    XCTAssertEqual(record.credentialId, "-__-", "base64url, unpadded")
    XCTAssertEqual(record.userHandle, "oKH7_w")
    XCTAssertEqual(record.username, "alice")
    XCTAssertNil(record.displayName)
    XCTAssertEqual(record.algorithm, "ES256")
    XCTAssertTrue(record.be)
    XCTAssertTrue(record.bs)
    XCTAssertEqual(record.origin, "https://example.com")
    XCTAssertFalse(String(describing: record).contains("SENTINEL"))
    XCTAssertNil(PasskeyProviderLogic.makeRecord(
      input(userHandle: Data()), databaseId: "d", credentialID: Data([1]), privateKeyPem: "p").userHandle)

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = SymmetricKey(size: .bits256)
    let store = PendingPasskeyStore(directoryURL: dir) { _ in key }
    try store.write(record)
    XCTAssertEqual(store.read().records, [record])
    XCTAssertEqual(store.readMetadata(), [record.metadata])
  }

  func testOffersMergeCachedAndPendingUnderOneFilter() {
    let cache = [
      cached("e1", credential: Self.credentialA),
      cached("e2", rpId: "other.example", credential: Self.credentialB),
    ]
    let mine = pending(credential: Self.credentialB)
    let adopted = pending(credential: Self.credentialA) // also in the cache
    let otherVault = pending(credential: Data([9, 9]), databaseId: "sha256:other-vault")
    let otherRp = pending(rpId: "other.example", credential: Data([8, 8]))
    let queue = [mine, adopted, otherVault, otherRp]

    func ids(_ allowed: Set<String> = [], published: String? = Self.published, rpId: String = "Example.com") -> [String] {
      PasskeyProviderLogic.offers(
        rpId: rpId, allowed: allowed, publishedDatabaseId: published, cached: cache, pending: queue
      ).map(\.id)
    }
    let mineId = PasskeyProviderLogic.pendingRecordPrefix + mine.recordId

    XCTAssertEqual(ids(), ["e1", mineId], "no duplicate, no other vault, no other rp")
    XCTAssertEqual(ids([Self.credentialB.base64URLEncodedString]), [mineId])
    XCTAssertEqual(ids([Self.credentialA.base64URLEncodedString + "="]), ["e1"])
    XCTAssertEqual(ids([Data([7]).base64URLEncodedString]), [])
    XCTAssertEqual(ids(published: nil), [], "nothing without a published cache")
    XCTAssertEqual(ids(published: "sha256:other-vault"), ["e1", PasskeyProviderLogic.pendingRecordPrefix + otherVault.recordId])

    let row = PasskeyProviderLogic.offers(
      rpId: "example.com", allowed: [], publishedDatabaseId: Self.published, cached: [], pending: [mine])[0]
    XCTAssertEqual(row.passkeys, [AutofillPasskeyMetadata(rpId: "example.com", credentialId: mine.credentialId)])
    XCTAssertEqual(row.username, "alice")
    XCTAssertFalse(row.hasPassword)
  }

  func testPendingPasskeySignsOnlyForItsPublishedVault() throws {
    let registration = try PasskeyRegistrationBuilder.build(rpId: "example.com")
    let record = PasskeyProviderLogic.makeRecord(
      input(), databaseId: Self.published, credentialID: registration.credentialID,
      privateKeyPem: registration.privateKeyPem)
    let identifier = PasskeyProviderLogic.pendingRecordPrefix + record.recordId

    func secret(
      published: String? = Self.published, identifier: String = identifier,
      rpId: String = "example.com", credentialId: String? = record.credentialId
    ) -> AutofillPasskeySecret? {
      PasskeyProviderLogic.pendingSecret(
        records: [record], publishedDatabaseId: published, recordIdentifier: identifier,
        rpId: rpId, credentialId: credentialId)
    }
    XCTAssertNil(secret(published: nil))
    XCTAssertNil(secret(published: "sha256:other-vault"))
    XCTAssertNil(secret(identifier: record.recordId), "a cache entry id never reaches the queue")
    XCTAssertNil(PasskeyProviderLogic.pendingRecordId(record.recordId))
    XCTAssertEqual(PasskeyProviderLogic.pendingRecordId(identifier), record.recordId)
    XCTAssertNil(secret(rpId: "other.example"))
    XCTAssertNil(secret(credentialId: "AAAA"))
    XCTAssertNotNil(secret(credentialId: nil))

    let found = try XCTUnwrap(secret())
    let clientDataHash = Data(SHA256.hash(data: Data("client-data".utf8)))
    let assertion = try PasskeyAssertionBuilder.assert(secret: found, clientDataHash: clientDataHash)
    let publicKey = try P256.Signing.PrivateKey(pemRepresentation: registration.privateKeyPem).publicKey
    let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
    XCTAssertTrue(publicKey.isValidSignature(signature, for: assertion.authenticatorData + clientDataHash))
    XCTAssertEqual(assertion.credentialID, registration.credentialID)
    XCTAssertEqual(assertion.userHandle, Data([0xa0, 0xa1, 0xfb, 0xff]))
  }
}
