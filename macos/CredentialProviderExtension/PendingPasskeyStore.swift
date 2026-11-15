import CryptoKit
import Foundation
import OSLog
import Security

private let pendingLog = Logger(
  subsystem: "dev.camillobucciarelli.kdbxKeyVault.CredentialProviderExtension",
  category: "passkey-pending"
)

/// spec 024 T016 — one decrypted pending registration. `privateKeyPem` is the
/// secret; `description` never prints it.
struct PendingPasskeyRecord: Equatable, CustomStringConvertible {
  let recordId: String
  let databaseId: String
  let createdAtEpochMs: Int64
  let rpId: String
  /// base64url, unpadded.
  let credentialId: String
  /// base64url, unpadded.
  let userHandle: String?
  let username: String
  let displayName: String?
  let privateKeyPem: String
  let algorithm: String
  let be: Bool
  let bs: Bool
  let origin: String

  var description: String { "PendingPasskeyRecord(recordId: \(recordId), rpId: \(rpId))" }

  var metadata: PendingPasskeyMetadata {
    PendingPasskeyMetadata(
      recordId: recordId, databaseId: databaseId, createdAtEpochMs: createdAtEpochMs,
      rpId: rpId, credentialId: credentialId, username: username)
  }
}

/// The plaintext envelope fields of one pending record: enough to list and
/// match it without the key. NOT authenticated until the record is opened, so
/// it may only decide what is shown or refused, never what is signed.
struct PendingPasskeyMetadata: Equatable {
  let recordId: String
  let databaseId: String
  let createdAtEpochMs: Int64
  let rpId: String
  /// base64url, unpadded.
  let credentialId: String
  let username: String
}

struct PendingPasskeyReadResult {
  let records: [PendingPasskeyRecord]
  let unreadableCount: Int
}

/// Errors carry no record content (SR-1).
enum PendingPasskeyStoreError: Error, LocalizedError {
  case appGroupUnavailable
  case keyUnavailable
  case invalidRecordId
  case unreadable
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .appGroupUnavailable: return "App Group container is not available."
    case .keyUnavailable: return "Pending passkey key is not available."
    case .invalidRecordId: return "recordId must be a UUID."
    case .unreadable: return "Pending passkey record could not be read."
    case .writeFailed: return "Pending passkey record could not be written."
    }
  }
}

/// Pending queue format v1 (spec 024), pure: AAD, payload JSON, envelope,
/// AES-256-GCM. Pinned by `test/fixtures/passkeys/pending_record_v1.json`.
enum PendingPasskeyCodec {
  static let version = 1
  static let algorithm = "AES-256-GCM"
  static let keyId = "passkey-pending-v1"

  /// `version|recordId|databaseId|createdAtEpochMs|rpId|credentialId|usernameB64`.
  /// The username goes in as unpadded base64url so a "|" in it cannot make two
  /// envelopes share an AAD.
  static func aad(_ m: PendingPasskeyMetadata) -> Data {
    let usernameB64 = Data(m.username.utf8).base64URLEncodedString
    return Data(
      "\(version)|\(m.recordId)|\(m.databaseId)|\(m.createdAtEpochMs)|\(m.rpId)|\(m.credentialId)|\(usernameB64)".utf8)
  }

  /// A JSON string fragment, "/" unescaped, nil as null.
  private static func s(_ v: String?) -> String {
    guard let v else { return "null" }
    // Cannot fail for a String.
    let data = try! JSONSerialization.data(
      withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  /// Compact, fixture key order, "/" unescaped, absent optionals as null.
  static func payloadJSON(_ r: PendingPasskeyRecord) -> Data {
    let json = "{\"rpId\":\(s(r.rpId)),\"credentialId\":\(s(r.credentialId))"
      + ",\"userHandle\":\(s(r.userHandle)),\"username\":\(s(r.username))"
      + ",\"displayName\":\(s(r.displayName)),\"privateKeyPem\":\(s(r.privateKeyPem))"
      + ",\"algorithm\":\(s(r.algorithm)),\"be\":\(r.be),\"bs\":\(r.bs)"
      + ",\"origin\":\(s(r.origin))}"
    return Data(json.utf8)
  }

  /// Envelope JSON. `nonce` is for the fixture only; production passes nil.
  static func seal(_ r: PendingPasskeyRecord, key: SymmetricKey, nonce: AES.GCM.Nonce? = nil) throws -> Data {
    let box = try AES.GCM.seal(
      payloadJSON(r), using: key, nonce: nonce ?? AES.GCM.Nonce(),
      authenticating: aad(r.metadata))
    guard let combined = box.combined else { throw PendingPasskeyStoreError.writeFailed }
    // Fixture key order (envelopeKeyOrder).
    let json = "{\"version\":\(version),\"algorithm\":\(s(algorithm)),\"keyId\":\(s(keyId))"
      + ",\"recordId\":\(s(r.recordId)),\"databaseId\":\(s(r.databaseId))"
      + ",\"createdAtEpochMs\":\(r.createdAtEpochMs),\"rpId\":\(s(r.rpId))"
      + ",\"credentialId\":\(s(r.credentialId)),\"username\":\(s(r.username))"
      + ",\"sealed\":\(s(combined.base64EncodedString()))}"
    return Data(json.utf8)
  }

  /// Envelope fields only: no key, no decryption, nothing authenticated.
  /// Not valid JSON, a missing field or the wrong file name is `.unreadable`.
  static func metadata(_ envelopeData: Data, expectedRecordId: String) throws -> PendingPasskeyMetadata {
    try envelope(envelopeData, expectedRecordId: expectedRecordId).metadata
  }

  private static func envelope(_ envelopeData: Data, expectedRecordId: String) throws -> Envelope {
    guard let env = try? JSONDecoder().decode(Envelope.self, from: envelopeData),
          env.version == version, env.algorithm == algorithm, env.keyId == keyId,
          env.recordId == expectedRecordId else {
      throw PendingPasskeyStoreError.unreadable
    }
    return env
  }

  /// Parses and authenticates; `expectedRecordId` is the file name. Any
  /// failure is `.unreadable`, never the underlying error (it may echo content).
  static func open(_ envelopeData: Data, key: SymmetricKey, expectedRecordId: String) throws -> PendingPasskeyRecord {
    do {
      let env = try envelope(envelopeData, expectedRecordId: expectedRecordId)
      guard let combined = Data(base64Encoded: env.sealed) else {
        throw PendingPasskeyStoreError.unreadable
      }
      let plain = try AES.GCM.open(
        AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad(env.metadata))
      let p = try JSONDecoder().decode(Payload.self, from: plain)
      // The envelope copies are what lists and matches used; they must be the
      // sealed values.
      guard p.rpId == env.rpId, p.credentialId == env.credentialId, p.username == env.username else {
        throw PendingPasskeyStoreError.unreadable
      }
      return PendingPasskeyRecord(
        recordId: env.recordId, databaseId: env.databaseId, createdAtEpochMs: env.createdAtEpochMs,
        rpId: p.rpId, credentialId: p.credentialId, userHandle: p.userHandle, username: p.username,
        displayName: p.displayName, privateKeyPem: p.privateKeyPem, algorithm: p.algorithm,
        be: p.be, bs: p.bs, origin: p.origin)
    } catch {
      throw PendingPasskeyStoreError.unreadable
    }
  }

  private struct Envelope: Decodable {
    let version: Int
    let algorithm: String
    let keyId: String
    let recordId: String
    let databaseId: String
    let createdAtEpochMs: Int64
    let rpId: String
    let credentialId: String
    let username: String
    let sealed: String

    var metadata: PendingPasskeyMetadata {
      PendingPasskeyMetadata(
        recordId: recordId, databaseId: databaseId, createdAtEpochMs: createdAtEpochMs,
        rpId: rpId, credentialId: credentialId, username: username)
    }
  }

  private struct Payload: Decodable {
    let rpId: String
    let credentialId: String
    let userHandle: String?
    let username: String
    let displayName: String?
    let privateKeyPem: String
    let algorithm: String
    let be: Bool
    let bs: Bool
    let origin: String
  }
}

/// spec 024 T016 — `passkey_pending_v1/<recordId>.sealed.json` in the App Group
/// container, sealed with its own keychain item. `SharedAutofillStore`'s
/// `clearCredentials` touches neither: it removes named cache files and the
/// `cache-key` account only.
final class PendingPasskeyStore {
  static let directoryName = "passkey_pending_v1"
  static let keychainAccount = "passkey-pending-key"
  private static let suffix = ".sealed.json"
  private static let tempSuffix = ".tmp"
  /// Far longer than any write takes, so a concurrent writer's temp file is
  /// never the one removed.
  static let staleTempAge: TimeInterval = 5 * 60

  /// `create == false` must never create the key (reading is side-effect free).
  typealias KeyProvider = (_ create: Bool) throws -> SymmetricKey?

  private let directoryURL: URL?
  private let keyProvider: KeyProvider

  /// Tests inject a temporary directory and an in-memory key.
  init(directoryURL: URL?, keyProvider: @escaping KeyProvider) {
    self.directoryURL = directoryURL
    self.keyProvider = keyProvider
  }

  /// The real queue: App Group container and the shared keychain group.
  convenience init() {
    self.init(
      directoryURL: SharedAutofillPaths.containerURL()?.appendingPathComponent(Self.directoryName, isDirectory: true),
      keyProvider: PendingPasskeyKeychain.key(create:))
  }

  static func isRecordId(_ value: String) -> Bool {
    // UUID(uuidString:) only takes the 36-char hex-and-dash form: no "/" or "..".
    UUID(uuidString: value) != nil
  }

  static func newRecordId() -> String { UUID().uuidString.lowercased() }

  /// Temporary name, flush to the disk, rename, read back. On any failure
  /// nothing is left behind and the caller must not report success to the
  /// relying party (FR-5).
  func write(_ record: PendingPasskeyRecord) throws {
    guard Self.isRecordId(record.recordId) else { throw PendingPasskeyStoreError.invalidRecordId }
    guard let directoryURL else { throw PendingPasskeyStoreError.appGroupUnavailable }
    guard let key = try? keyProvider(true) else { throw PendingPasskeyStoreError.keyUnavailable }
    let fm = FileManager.default
    let target = directoryURL.appendingPathComponent(record.recordId + Self.suffix)
    let temp = directoryURL.appendingPathComponent(record.recordId + Self.tempSuffix)
    do {
      try createDirectoryIfNeeded(directoryURL)
      Self.removeStaleTempFiles(in: directoryURL)
      let sealed = try PendingPasskeyCodec.seal(record, key: key)
      // O_EXCL: never over an existing temp file.
      let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      guard fd >= 0 else { throw PendingPasskeyStoreError.writeFailed }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
#if os(iOS)
      try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temp.path)
#endif
      try handle.write(contentsOf: sealed)
      // The relying party is about to hear "registered": the bytes must be on
      // the disk, not in a cache a power cut empties. fsync, then the drive's
      // own cache where the file system can (F_FULLFSYNC; -1 is "cannot").
      try handle.synchronize()
      _ = fcntl(fd, F_FULLFSYNC)
      try handle.close()
      try fm.moveItem(at: temp, to: target)
      Self.syncDirectory(directoryURL)
      let back = try PendingPasskeyCodec.open(Data(contentsOf: target), key: key, expectedRecordId: record.recordId)
      guard back == record else { throw PendingPasskeyStoreError.writeFailed }
    } catch {
      try? fm.removeItem(at: temp)
      try? fm.removeItem(at: target)
      pendingLog.error("pending passkey write failed recordId=\(record.recordId, privacy: .public) rpId=\(record.rpId, privacy: .private(mask: .hash))")
      throw PendingPasskeyStoreError.writeFailed
    }
    pendingLog.info("pending passkey queued recordId=\(record.recordId, privacy: .public) rpId=\(record.rpId, privacy: .private(mask: .hash))")
  }

  /// Best effort. A crash between creating the temp file and the rename leaves
  /// it behind for good (it is never listed as a record); each write sweeps
  /// the ones older than `staleTempAge`. Only `*.tmp`: never a record.
  private static func removeStaleTempFiles(in directory: URL) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
    let cutoff = Date().addingTimeInterval(-staleTempAge)
    for name in names where name.hasSuffix(tempSuffix) && !name.hasSuffix(suffix) {
      let path = directory.appendingPathComponent(name).path
      guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
            modified < cutoff else { continue }
      try? fm.removeItem(atPath: path)
    }
  }

  /// Best effort: makes the rename itself durable.
  private static func syncDirectory(_ url: URL) {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { return }
    if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
    close(fd)
  }

  private func recordFileNames() -> [String] {
    guard let directoryURL,
          let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else { return [] }
    return names.filter { $0.hasSuffix(Self.suffix) }.sorted()
  }

  /// How many record files are queued, readable or not, for every vault. File
  /// names only: no keychain access, nothing opened or decrypted, so it is safe
  /// before the vault is unlocked.
  func count() -> Int { recordFileNames().count }

  /// Envelope fields of every parseable record: no keychain access, no
  /// decryption. For listing and comparing before user verification; files
  /// that are not a v1 envelope are skipped (the decrypting `read()` counts
  /// them).
  func readMetadata() -> [PendingPasskeyMetadata] {
    guard let directoryURL else { return [] }
    return recordFileNames().compactMap { name in
      let id = String(name.dropLast(Self.suffix.count))
      guard Self.isRecordId(id),
            let data = try? Data(contentsOf: directoryURL.appendingPathComponent(name)) else { return nil }
      return try? PendingPasskeyCodec.metadata(data, expectedRecordId: id)
    }
  }

  /// Decrypts one record, or nil. Call only after user verification. Opening
  /// authenticates the envelope, so tampered plaintext metadata yields nil.
  /// Never creates the key.
  func read(recordId: String) -> PendingPasskeyRecord? {
    guard let directoryURL, Self.isRecordId(recordId),
          let data = try? Data(contentsOf: directoryURL.appendingPathComponent(recordId + Self.suffix)),
          let key = try? keyProvider(false) else { return nil }
    return try? PendingPasskeyCodec.open(data, key: key, expectedRecordId: recordId)
  }

  /// Every record decrypted, plus a count of the rest: for the unlocked app.
  /// Unreadable files are never deleted or logged (FR-9, SR-5). Never creates
  /// the key.
  func read() -> PendingPasskeyReadResult {
    guard let directoryURL else { return PendingPasskeyReadResult(records: [], unreadableCount: 0) }
    let files = recordFileNames()
    guard !files.isEmpty else { return PendingPasskeyReadResult(records: [], unreadableCount: 0) }
    let key = try? keyProvider(false)
    var records: [PendingPasskeyRecord] = []
    var unreadable = 0
    for name in files {
      let id = String(name.dropLast(Self.suffix.count))
      if let key, Self.isRecordId(id),
         let data = try? Data(contentsOf: directoryURL.appendingPathComponent(name)),
         let record = try? PendingPasskeyCodec.open(data, key: key, expectedRecordId: id) {
        records.append(record)
      } else {
        unreadable += 1
      }
    }
    if unreadable > 0 {
      pendingLog.error("pending passkey records unreadable count=\(unreadable, privacy: .public)")
    }
    return PendingPasskeyReadResult(records: records, unreadableCount: unreadable)
  }

  /// Deletes one record. True when the file is gone afterwards, including
  /// when it was already absent.
  func resolve(recordId: String) throws -> Bool {
    guard Self.isRecordId(recordId) else { throw PendingPasskeyStoreError.invalidRecordId }
    guard let directoryURL else { throw PendingPasskeyStoreError.appGroupUnavailable }
    let url = directoryURL.appendingPathComponent(recordId + Self.suffix)
    let fm = FileManager.default
    var gone = !fm.fileExists(atPath: url.path)
    if !gone { gone = (try? fm.removeItem(at: url)) != nil }
    pendingLog.info("pending passkey resolved recordId=\(recordId, privacy: .public) gone=\(gone, privacy: .public)")
    return gone
  }

  private func createDirectoryIfNeeded(_ url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // The key is device-only, so a backed-up copy is useless; keep it out (SR-4).
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = url
    try? mutable.setResourceValues(values)
  }
}

/// The queue's own generic-password item: same service and access group as
/// the cache key, account `passkey-pending-key`, device-only.
enum PendingPasskeyKeychain {
  static func key(create: Bool) throws -> SymmetricKey? {
    if let data = try read() { return SymmetricKey(data: data) }
    guard create else { return nil }
    let key = SymmetricKey(size: .bits256)
    var query = baseQuery()
    query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    // Never delete-then-add: an existing key protects records already queued.
    if status == errSecDuplicateItem, let data = try read() { return SymmetricKey(data: data) }
    guard status == errSecSuccess else { throw PendingPasskeyStoreError.keyUnavailable }
    return key
  }

  private static func read() throws -> Data? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
      throw PendingPasskeyStoreError.keyUnavailable
    }
    return data
  }

  private static func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SharedAutofillPaths.keychainService,
      kSecAttrAccount as String: PendingPasskeyStore.keychainAccount,
    ]
    if let group = accessGroup() { query[kSecAttrAccessGroup as String] = group }
    return query
  }

  /// Same resolution as `SharedAutofillStore.resolveKeychainAccessGroup`:
  /// macOS reads the entitlement; iOS omits the group and gets the default
  /// (the single shared keychain-access-groups entry).
  private static func accessGroup() -> String? {
#if os(macOS)
    guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
          let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
          let groups = value as? [String] else {
      return nil
    }
    let suffix = SharedAutofillPaths.keychainAccessGroupSuffix
    return groups.first { $0 == suffix || $0.hasSuffix(".\(suffix)") }
#else
    return nil
#endif
  }
}

/// spec 024 T018 — what a registration request says, free of
/// AuthenticationServices types so the decisions below are unit-testable.
struct PasskeyRegistrationInput {
  let rpId: String
  let userName: String
  let userHandle: Data
  /// COSE algorithm identifiers the relying party accepts.
  let supportedAlgorithms: [Int]
  let excludedCredentialIds: [Data]
}

enum PasskeyRegistrationConflict {
  case none
  case sameAccount
  case excludedCredential
}

/// spec 024 T018/T019 — the pure decisions of the Apple credential provider,
/// mirroring the Android `PasskeyProviderLogic`: the ES256 gate (FR-4), the
/// exclusion check (FR-7), the pending record (queue format v1) and the list
/// of passkeys offered for a sign-in, cached plus pending (FR-10).
enum PasskeyProviderLogic {
  /// Marks a list row or identity backed by a pending record, not a cache entry.
  static let pendingRecordPrefix = "pending-passkey:"

  /// The published cache's id, unchanged, or nil when nothing is published
  /// (vault locked or never unlocked).
  static func publishedDatabaseId(_ status: AutofillStoreStatus) -> String? {
    guard status.cacheAvailable, let id = status.databaseId, !id.isEmpty else { return nil }
    return id
  }

  /// FR-4. An empty list is the WebAuthn default set (ES256 and RS256), as on
  /// Android.
  static func offersES256(_ algorithms: [Int]) -> Bool {
    algorithms.isEmpty || algorithms.contains(AutofillPasskeyAlgorithm.es256.coseIdentifier)
  }

  /// FR-7. An excluded credential id already held for this rp refuses; the
  /// same `(rpId, username)` only warns. Pending records of any vault count:
  /// the credential exists on this device either way.
  static func conflict(
    _ input: PasskeyRegistrationInput,
    cached: [AutofillCredentialMetadata],
    pending: [PendingPasskeyMetadata]
  ) -> PasskeyRegistrationConflict {
    let cachedForRp = cached.filter { $0.passkeys.contains { sameRp($0.rpId, input.rpId) } }
    let pendingForRp = pending.filter { sameRp($0.rpId, input.rpId) }

    let excluded = Set(input.excludedCredentialIds.map { $0.base64URLEncodedString })
    let heldIds = cachedForRp.flatMap { $0.passkeys.filter { sameRp($0.rpId, input.rpId) }.map { unpadded($0.credentialId) } }
      + pendingForRp.map { unpadded($0.credentialId) }
    if heldIds.contains(where: excluded.contains) { return .excludedCredential }

    let name = input.userName
    if cachedForRp.contains(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame })
      || pendingForRp.contains(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame }) {
      return .sameAccount
    }
    return .none
  }

  /// The record queued for a freshly built registration. The request exposes
  /// no origin and no display name, so `origin` is `https://<rpId>` and
  /// `displayName` is null.
  static func makeRecord(
    _ input: PasskeyRegistrationInput,
    databaseId: String,
    credentialID: Data,
    privateKeyPem: String,
    recordId: String = PendingPasskeyStore.newRecordId(),
    createdAtEpochMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
  ) -> PendingPasskeyRecord {
    PendingPasskeyRecord(
      recordId: recordId, databaseId: databaseId, createdAtEpochMs: createdAtEpochMs,
      rpId: input.rpId, credentialId: credentialID.base64URLEncodedString,
      userHandle: input.userHandle.isEmpty ? nil : input.userHandle.base64URLEncodedString,
      username: input.userName, displayName: nil, privateKeyPem: privateKeyPem,
      algorithm: AutofillPasskeyAlgorithm.es256.rawValue, be: true, bs: true,
      origin: "https://\(input.rpId)")
  }

  /// FR-10. Cache records holding a passkey for `rpId`, then pending records
  /// as list rows, filtered by `allowed` (empty means any). Nothing without a
  /// published cache; a pending record only for the published vault, and not
  /// twice when the cache already holds the same credential.
  static func offers(
    rpId: String,
    allowed: Set<String>,
    publishedDatabaseId: String?,
    cached: [AutofillCredentialMetadata],
    pending: [PendingPasskeyMetadata]
  ) -> [AutofillCredentialMetadata] {
    guard let publishedDatabaseId, !publishedDatabaseId.isEmpty, !rpId.isEmpty else { return [] }
    let allowedIds = Set(allowed.map(unpadded))
    func matches(_ passkeyRpId: String, _ credentialId: String) -> Bool {
      sameRp(passkeyRpId, rpId) && (allowedIds.isEmpty || allowedIds.contains(unpadded(credentialId)))
    }

    var offers = cached.filter { $0.passkeys.contains { matches($0.rpId, $0.credentialId) } }
    let cachedIds = Set(cached.flatMap { $0.passkeys.filter { sameRp($0.rpId, rpId) }.map { unpadded($0.credentialId) } })
    for record in pending
    where record.databaseId == publishedDatabaseId
      && matches(record.rpId, record.credentialId)
      && !cachedIds.contains(unpadded(record.credentialId)) {
      offers.append(AutofillCredentialMetadata(
        id: pendingRecordPrefix + record.recordId,
        title: record.rpId,
        username: record.username,
        displayService: record.rpId,
        serviceIdentifiers: [],
        updatedAtEpochMs: record.createdAtEpochMs,
        passkeys: [AutofillPasskeyMetadata(rpId: record.rpId, credentialId: record.credentialId)],
        hasPassword: false))
    }
    return offers
  }

  /// The queue record id behind a pending row or identity, or nil.
  static func pendingRecordId(_ recordIdentifier: String) -> String? {
    guard recordIdentifier.hasPrefix(pendingRecordPrefix) else { return nil }
    return String(recordIdentifier.dropFirst(pendingRecordPrefix.count))
  }

  /// The signing key of one pending row, under the same rules as `offers`:
  /// same published vault, same rp, the credential the request named.
  /// `records` are decrypted, so this runs only after user verification.
  static func pendingSecret(
    records: [PendingPasskeyRecord],
    publishedDatabaseId: String?,
    recordIdentifier: String,
    rpId: String,
    credentialId: String?
  ) -> AutofillPasskeySecret? {
    guard let publishedDatabaseId, !publishedDatabaseId.isEmpty,
          let recordId = pendingRecordId(recordIdentifier) else { return nil }
    guard let record = records.first(where: {
      $0.recordId == recordId && $0.databaseId == publishedDatabaseId && sameRp($0.rpId, rpId)
        && (credentialId == nil || unpadded($0.credentialId) == unpadded(credentialId!))
    }), let algorithm = AutofillPasskeyAlgorithm(rawValue: record.algorithm) else { return nil }
    return AutofillPasskeySecret(
      rpId: record.rpId, credentialId: record.credentialId, userHandle: record.userHandle,
      username: record.username, privateKeyPem: record.privateKeyPem, algorithm: algorithm,
      backupEligible: record.be, backupState: record.be && record.bs)
  }

  private static func sameRp(_ a: String, _ b: String) -> Bool {
    a.caseInsensitiveCompare(b) == .orderedSame
  }

  private static func unpadded(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: "= \n\t"))
  }
}
