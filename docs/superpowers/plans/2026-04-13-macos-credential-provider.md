# macOS Credential Provider Extension — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `ASCredentialProviderExtension` target to the macOS app so Safari and any system autofill picker on macOS 14+ can fill passwords from the vault.

**Architecture:** A new Xcode target (`CredentialProviderExtension`) embedded in the macOS Runner app. It queries credentials from the existing desktop HTTP bridge first (if the app is open and unlocked), then falls back to a UserDefaults App Group snapshot that the Flutter app already writes on iOS and will now also write on macOS. Matching and scoring logic is copied verbatim from the iOS extension.

**Tech Stack:** Swift 5, AuthenticationServices, SwiftUI + NSHostingController, URLSession (async/await), Dart/Flutter (snapshot side).

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `lib/.../ios_autofill_snapshot_coordinator.dart` | Enable macOS in `_isSupportedPlatform` |
| Modify | `macos/Runner/DebugProfile.entitlements` | Add App Group entitlement to Runner |
| Modify | `macos/Runner/Release.entitlements` | Add App Group entitlement to Runner |
| Create | `macos/CredentialProviderExtension/SharedAutofillStore.swift` | UserDefaults App Group read; declares `SharedAutofillCredential` |
| Create | `macos/CredentialProviderExtension/BridgeClient.swift` | Reads `bridge.json`, POSTs `/v1/find`, returns credentials or nil |
| Create | `macos/CredentialProviderExtension/CredentialListView.swift` | SwiftUI credential picker (macOS variant of the iOS view) |
| Create | `macos/CredentialProviderExtension/MacCredentialProviderViewController.swift` | Main VC — bridge + snapshot + match/fill/list logic |
| Create | `macos/CredentialProviderExtension/Info.plist` | Extension manifest |
| Create | `macos/CredentialProviderExtension/CredentialProviderExtension.entitlements` | App Group entitlement for extension |
| Modify | `macos/Runner.xcodeproj/project.pbxproj` | New target, UUIDs, embed phase, deploy target 14.0 |

---

### Task 1: Flutter side — enable macOS snapshot + add App Group to Runner entitlements

**Files:**
- Modify: `lib/features/password_manager/data/services/ios_autofill_snapshot_coordinator.dart:129-134`
- Modify: `macos/Runner/DebugProfile.entitlements`
- Modify: `macos/Runner/Release.entitlements`

- [ ] **Step 1: Update `_isSupportedPlatform` in `ios_autofill_snapshot_coordinator.dart`**

Replace lines 129–134:

```dart
  bool get _isSupportedPlatform {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.iOS ||
           defaultTargetPlatform == TargetPlatform.macOS;
  }
```

- [ ] **Step 2: Run Flutter analyze to verify no errors**

```bash
flutter analyze lib/features/password_manager/data/services/ios_autofill_snapshot_coordinator.dart
```

Expected: `No issues found!`

- [ ] **Step 3: Add App Group to `macos/Runner/DebugProfile.entitlements`**

Full file content after edit:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.files.downloads.read-write</key>
	<true/>
	<key>com.apple.security.device.print</key>
	<true/>
	<key>keychain-access-groups</key>
	<array/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.dev.camillobucciarelli.kdbxKeyVault</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 4: Add App Group to `macos/Runner/Release.entitlements`**

Full file content after edit:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.files.downloads.read-write</key>
	<true/>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)dev.camillobucciarelli.kdbxKeyVault</string>
	</array>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.dev.camillobucciarelli.kdbxKeyVault</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 5: Commit**

```bash
git add lib/features/password_manager/data/services/ios_autofill_snapshot_coordinator.dart \
        macos/Runner/DebugProfile.entitlements \
        macos/Runner/Release.entitlements
git commit -m "feat: enable macOS autofill snapshot + add App Group to macOS Runner entitlements"
```

---

### Task 2: Create macOS extension — SharedAutofillStore.swift

**Files:**
- Create: `macos/CredentialProviderExtension/SharedAutofillStore.swift`

This file is the macOS counterpart of `ios/CredentialProviderExtension/SharedAutofillStore.swift`. Key difference: it adds an explicit memberwise init (needed because `init(from:)` suppresses Swift's auto-generated memberwise init), and it omits pending-saves logic (saving from extension is out of scope on macOS).

- [ ] **Step 1: Create the directory**

```bash
mkdir -p macos/CredentialProviderExtension
```

- [ ] **Step 2: Create `macos/CredentialProviderExtension/SharedAutofillStore.swift`**

```swift
import Foundation

struct SharedAutofillCredential: Codable {
  let id: String
  let title: String
  let username: String
  let password: String
  let url: String
  let notes: String
  let customFields: [SharedCustomField]

  struct SharedCustomField: Codable {
    let key: String
    let value: String
  }

  // Explicit memberwise init — required because the Decodable init below
  // suppresses Swift's auto-generated memberwise initializer.
  init(
    id: String, title: String, username: String,
    password: String, url: String, notes: String,
    customFields: [SharedCustomField]
  ) {
    self.id = id
    self.title = title
    self.username = username
    self.password = password
    self.url = url
    self.notes = notes
    self.customFields = customFields
  }

  // Custom decoder: `customFields` defaults to [] for cached JSON written
  // by older versions of the app that did not include this field.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id           = try c.decode(String.self, forKey: .id)
    title        = try c.decode(String.self, forKey: .title)
    username     = try c.decode(String.self, forKey: .username)
    password     = try c.decode(String.self, forKey: .password)
    url          = try c.decode(String.self, forKey: .url)
    notes        = try c.decode(String.self, forKey: .notes)
    customFields = try c.decodeIfPresent([SharedCustomField].self, forKey: .customFields) ?? []
  }
}

final class SharedAutofillStore {
  private let appGroupId = "group.dev.camillobucciarelli.kdbxKeyVault"
  private let autofillEntriesKey = "autofill_entries_json"

  func readCredentials() -> [SharedAutofillCredential] {
    guard
      let defaults = UserDefaults(suiteName: appGroupId),
      let json = defaults.string(forKey: autofillEntriesKey),
      let data = json.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([SharedAutofillCredential].self, from: data)
    else {
      return []
    }
    return decoded.filter { !$0.username.isEmpty || !$0.password.isEmpty }
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add macos/CredentialProviderExtension/SharedAutofillStore.swift
git commit -m "feat: add macOS SharedAutofillStore (App Group snapshot reader)"
```

---

### Task 3: Create BridgeClient.swift

**Files:**
- Create: `macos/CredentialProviderExtension/BridgeClient.swift`

Reads `~/.keyvault_autofill/bridge.json`, checks token expiry, POSTs to the running app's HTTP bridge. Returns `nil` on any failure — the caller falls back to the snapshot.

- [ ] **Step 1: Create `macos/CredentialProviderExtension/BridgeClient.swift`**

```swift
import Foundation

private struct BridgeConfig: Decodable {
  let host: String
  let port: Int
  let token: String
  let expiresAtEpochMs: Int64
}

struct BridgeClient {
  private static var bridgeConfigURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".keyvault_autofill")
      .appendingPathComponent("bridge.json")
  }

  private let timeout: TimeInterval = 1.5

  /// Returns the best-matching credentials from the running app, or nil if
  /// the bridge is unavailable (app closed, token expired, network error).
  func findCredentials(for url: String, limit: Int = 10) async -> [SharedAutofillCredential]? {
    guard let config = Self.readConfig(), !isExpired(config) else { return nil }
    return await post(config: config, url: url, limit: limit)
  }

  // MARK: - Private

  private static func readConfig() -> BridgeConfig? {
    guard let data = try? Data(contentsOf: bridgeConfigURL) else { return nil }
    return try? JSONDecoder().decode(BridgeConfig.self, from: data)
  }

  private func isExpired(_ config: BridgeConfig) -> Bool {
    let expiresAt = Date(timeIntervalSince1970: Double(config.expiresAtEpochMs) / 1000.0)
    return Date() >= expiresAt
  }

  private func post(
    config: BridgeConfig,
    url: String,
    limit: Int
  ) async -> [SharedAutofillCredential]? {
    guard let endpoint = URL(string: "http://\(config.host):\(config.port)/v1/find") else {
      return nil
    }

    var request = URLRequest(url: endpoint, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["url": url, "limit": limit]
    )

    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.timeoutIntervalForRequest = timeout
    sessionConfig.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: sessionConfig)

    guard
      let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse,
      http.statusCode == 200
    else { return nil }

    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawList = json["credentials"] as? [[String: Any]]
    else { return nil }

    return rawList.compactMap { dict -> SharedAutofillCredential? in
      guard
        let id       = dict["id"]       as? String,
        let title    = dict["title"]    as? String,
        let username = dict["username"] as? String,
        let password = dict["password"] as? String,
        let url      = dict["url"]      as? String
      else { return nil }
      return SharedAutofillCredential(
        id: id, title: title, username: username,
        password: password, url: url, notes: "",
        customFields: []
      )
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add macos/CredentialProviderExtension/BridgeClient.swift
git commit -m "feat: add BridgeClient — queries desktop HTTP bridge for credentials"
```

---

### Task 4: Create CredentialListView.swift (macOS)

**Files:**
- Create: `macos/CredentialProviderExtension/CredentialListView.swift`

Identical to `ios/CredentialProviderExtension/CredentialListView.swift` except `.navigationBarTitleDisplayMode(.inline)` is removed (iOS-only API). All other SwiftUI APIs are macOS 12+ compatible.

- [ ] **Step 1: Create `macos/CredentialProviderExtension/CredentialListView.swift`**

```swift
import AuthenticationServices
import SwiftUI

struct CredentialListView: View {
  let credentials: [SharedAutofillCredential]
  let bestMatchId: String?
  let onSelect: (SharedAutofillCredential) -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationView {
      List(credentials, id: \.id) { credential in
        Button {
          onSelect(credential)
        } label: {
          CredentialRowView(
            credential: credential,
            isBestMatch: credential.id == bestMatchId
          )
        }
        .buttonStyle(.plain)
      }
      .listStyle(.plain)
      .navigationTitle("Credentials")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
      }
    }
  }
}

private struct CredentialRowView: View {
  let credential: SharedAutofillCredential
  let isBestMatch: Bool

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(Color.accentColor.opacity(0.15))
        .frame(width: 40, height: 40)
        .overlay {
          Text(credential.title.prefix(1).uppercased())
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.accentColor)
        }

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(credential.title.isEmpty ? "Unnamed" : credential.title)
            .font(.body)
            .foregroundColor(.primary)
            .lineLimit(1)
          if isBestMatch {
            Text("Best match")
              .font(.caption2)
              .fontWeight(.medium)
              .foregroundColor(.accentColor)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.accentColor.opacity(0.12))
              .clipShape(Capsule())
          }
        }
        if !credential.username.isEmpty {
          Text(credential.username)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundColor(.secondary.opacity(0.5))
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add macos/CredentialProviderExtension/CredentialListView.swift
git commit -m "feat: add macOS CredentialListView (SwiftUI credential picker)"
```

---

### Task 5: Create MacCredentialProviderViewController.swift

**Files:**
- Create: `macos/CredentialProviderExtension/MacCredentialProviderViewController.swift`

Main VC. Differences from iOS counterpart:
- Uses `BridgeClient` as primary data source, `SharedAutofillStore` as fallback
- `prepareCredentialList` applies best-match logic: silent fill if single score > 0 **or** top score ≥ 140
- `NSHostingController` instead of `UIHostingController`
- No `host.didMove(toParent:)` (macOS NSViewController lifecycle)
- macOS 14 override for `provideCredentialWithoutUserInteraction(for credentialRequest:)`

- [ ] **Step 1: Create `macos/CredentialProviderExtension/MacCredentialProviderViewController.swift`**

```swift
import AuthenticationServices
import SwiftUI

final class MacCredentialProviderViewController: ASCredentialProviderViewController {
  private let store = SharedAutofillStore()
  private let bridge = BridgeClient()

  // MARK: - Credential list

  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    Task { @MainActor in
      let allCredentials = await fetchCredentials(for: serviceIdentifiers)

      guard !allCredentials.isEmpty else {
        cancelWithError(.credentialIdentityNotFound)
        return
      }

      let scored = allCredentials
        .map { cred -> (SharedAutofillCredential, Int) in
          let score = serviceIdentifiers.reduce(0) {
            $0 + matchScore(credential: cred, serviceId: $1)
          }
          return (cred, score)
        }
        .sorted { $0.1 > $1.1 }

      let sorted      = scored.map { $0.0 }
      let topScore    = scored.first?.1 ?? 0
      let matchCount  = scored.filter { $0.1 > 0 }.count
      let bestId      = scored.first(where: { $0.1 > 0 })?.0.id

      // Silent fill: one unambiguous match or exact-domain hit
      if matchCount == 1 || topScore >= 140 {
        guard let best = scored.first(where: { $0.1 > 0 })?.0 else {
          showCredentialList(sorted, bestMatchId: bestId)
          return
        }
        extensionContext.completeRequest(
          withSelectedCredential: ASPasswordCredential(
            user: best.username,
            password: best.password
          )
        )
        return
      }

      showCredentialList(sorted, bestMatchId: bestId)
    }
  }

  private func showCredentialList(
    _ credentials: [SharedAutofillCredential],
    bestMatchId: String?
  ) {
    let rootView = CredentialListView(
      credentials: credentials,
      bestMatchId: bestMatchId,
      onSelect: { [weak self] cred in
        self?.extensionContext.completeRequest(
          withSelectedCredential: ASPasswordCredential(
            user: cred.username,
            password: cred.password
          )
        )
      },
      onCancel: { [weak self] in
        self?.cancelWithError(.userCanceled)
      }
    )

    let host = NSHostingController(rootView: rootView)
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  // MARK: - Silent fill

  override func provideCredentialWithoutUserInteraction(
    for credentialIdentity: ASPasswordCredentialIdentity
  ) {
    Task { @MainActor in
      let credentials = await fetchCredentials(for: [credentialIdentity.serviceIdentifier])
      guard let matched = credentials.first(where: { credential in
        credential.username == credentialIdentity.user &&
        credentialMatchesService(credential, serviceId: credentialIdentity.serviceIdentifier)
      }) else {
        cancelWithError(.userInteractionRequired)
        return
      }
      extensionContext.completeRequest(
        withSelectedCredential: ASPasswordCredential(
          user: matched.username,
          password: matched.password
        )
      )
    }
  }

  // macOS 14 / iOS 17 API
  override func provideCredentialWithoutUserInteraction(
    for credentialRequest: any ASCredentialRequest
  ) {
    if let passwordRequest = credentialRequest as? ASPasswordCredentialRequest,
       let identity = passwordRequest.credentialIdentity as? ASPasswordCredentialIdentity {
      provideCredentialWithoutUserInteraction(for: identity)
    } else {
      cancelWithError(.failed)
    }
  }

  override func prepareInterfaceToProvideCredential(
    for credentialIdentity: ASPasswordCredentialIdentity
  ) {
    // Called after userInteractionRequired — show full list, no silent fill.
    Task { @MainActor in
      let credentials = await fetchCredentials(for: [credentialIdentity.serviceIdentifier])
      guard !credentials.isEmpty else {
        cancelWithError(.credentialIdentityNotFound)
        return
      }
      let scored = credentials
        .map { ($0, matchScore(credential: $0, serviceId: credentialIdentity.serviceIdentifier)) }
        .sorted { $0.1 > $1.1 }
      let bestId = scored.first(where: { $0.1 > 0 })?.0.id
      showCredentialList(scored.map { $0.0 }, bestMatchId: bestId)
    }
  }

  override func prepareInterfaceForExtensionConfiguration() {
    extensionContext.completeExtensionConfigurationRequest()
  }

  // MARK: - Data fetching

  private func fetchCredentials(
    for serviceIdentifiers: [ASCredentialServiceIdentifier]
  ) async -> [SharedAutofillCredential] {
    let url = serviceIdentifiers.first?.identifier ?? ""
    if let bridgeResults = await bridge.findCredentials(for: url),
       !bridgeResults.isEmpty {
      return bridgeResults
    }
    return store.readCredentials()
  }

  // MARK: - Matching

  private func credentialMatchesService(
    _ credential: SharedAutofillCredential,
    serviceId: ASCredentialServiceIdentifier
  ) -> Bool {
    matchScore(credential: credential, serviceId: serviceId) > 0
  }

  private func matchScore(
    credential: SharedAutofillCredential,
    serviceId: ASCredentialServiceIdentifier
  ) -> Int {
    let identifier = serviceId.identifier.lowercased()

    if let entryHost = urlHost(from: credential.url)?.lowercased() {
      let normalizedEntry = stripCommonPrefixes(entryHost)
      let normalizedId    = stripCommonPrefixes(identifier)
      if normalizedEntry == normalizedId { return 140 }
      if normalizedEntry.hasSuffix(".\(normalizedId)") ||
         normalizedId.hasSuffix(".\(normalizedEntry)") { return 110 }
      if registrable(normalizedEntry) == registrable(normalizedId) { return 80 }
    }

    if let url = URL(string: credential.url),
       let scheme = url.scheme,
       (scheme == "androidapp" || scheme == "iosbundleid"),
       let bundleId = url.host?.lowercased() {
      if bundleId == identifier { return 140 }
    }

    for field in credential.customFields {
      let key = field.key.lowercased()
      if key == "kph: iosbundle" || key == "kph: androidpackage" {
        let values = field.value
          .split(whereSeparator: { ",; ".contains($0) })
          .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        if values.contains(identifier) { return 140 }
      }
    }

    return 0
  }

  // MARK: - URL utilities

  private func urlHost(from rawUrl: String) -> String? {
    guard !rawUrl.isEmpty else { return nil }
    let url = rawUrl.contains("://") ? URL(string: rawUrl) : URL(string: "https://\(rawUrl)")
    return url?.host
  }

  private func stripCommonPrefixes(_ domain: String) -> String {
    var d = domain
    for prefix in ["www.", "m.", "mobile."] {
      if d.hasPrefix(prefix) { d = String(d.dropFirst(prefix.count)); break }
    }
    return d
  }

  private func registrable(_ domain: String) -> String {
    let parts = domain.split(separator: ".").filter { !$0.isEmpty }
    guard parts.count >= 2 else { return domain }
    return "\(parts[parts.count - 2]).\(parts.last!)"
  }

  // MARK: - Error helper

  private func cancelWithError(_ code: ASExtensionError.Code) {
    extensionContext.cancelRequest(
      withError: NSError(
        domain: ASExtensionErrorDomain,
        code: code.rawValue,
        userInfo: nil
      )
    )
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add macos/CredentialProviderExtension/MacCredentialProviderViewController.swift
git commit -m "feat: add MacCredentialProviderViewController (bridge + snapshot + match/fill)"
```

---

### Task 6: Create Info.plist and entitlements

**Files:**
- Create: `macos/CredentialProviderExtension/Info.plist`
- Create: `macos/CredentialProviderExtension/CredentialProviderExtension.entitlements`

- [ ] **Step 1: Create `macos/CredentialProviderExtension/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>Custode AutoFill</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionAttributes</key>
		<dict>
			<key>ASCredentialProviderExtensionCapabilities</key>
			<dict>
				<key>ProvidesPasswordCredential</key>
				<true/>
			</dict>
		</dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.authentication-services-credential-provider-ui</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).MacCredentialProviderViewController</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 2: Create `macos/CredentialProviderExtension/CredentialProviderExtension.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.dev.camillobucciarelli.kdbxKeyVault</string>
	</array>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
```

Note: `com.apple.security.network.client` is required so the extension can make the loopback HTTP request to the bridge.

- [ ] **Step 3: Commit**

```bash
git add macos/CredentialProviderExtension/Info.plist \
        macos/CredentialProviderExtension/CredentialProviderExtension.entitlements
git commit -m "feat: add macOS extension Info.plist and entitlements"
```

---

### Task 7: Wire up Xcode project — add extension target and raise deployment target

**Files:**
- Modify: `macos/Runner.xcodeproj/project.pbxproj`

This task makes **many precise edits** to the pbxproj file. Apply them one at a time using an editor that does exact string replacement (not sed — use the Edit tool). After all edits, verify with `xcodebuild`.

The UUIDs used throughout this task (all are 24-char uppercase hex, unique in this file):

| UUID | Object |
|---|---|
| `MACE0000000000000000A001` | appex product file reference |
| `MACE0000000000000000A002` | `MacCredentialProviderViewController.swift` file reference |
| `MACE0000000000000000A003` | `SharedAutofillStore.swift` file reference |
| `MACE0000000000000000A004` | `BridgeClient.swift` file reference |
| `MACE0000000000000000A005` | `CredentialListView.swift` file reference |
| `MACE0000000000000000A006` | `Info.plist` file reference |
| `MACE0000000000000000A007` | `CredentialProviderExtension.entitlements` file reference |
| `MACE0000000000000000B001` | MacCredVC.swift build file (Sources) |
| `MACE0000000000000000B002` | SharedAutofillStore.swift build file (Sources) |
| `MACE0000000000000000B003` | BridgeClient.swift build file (Sources) |
| `MACE0000000000000000B004` | CredentialListView.swift build file (Sources) |
| `MACE0000000000000000B005` | appex build file (Embed App Extensions) |
| `MACE0000000000000000C001` | `PBXNativeTarget` — CredentialProviderExtension |
| `MACE0000000000000000C002` | `PBXGroup` — CredentialProviderExtension folder |
| `MACE0000000000000000D001` | Sources build phase for extension |
| `MACE0000000000000000D002` | Frameworks build phase for extension |
| `MACE0000000000000000D003` | Resources build phase for extension |
| `MACE0000000000000000D004` | Embed App Extensions build phase (in Runner) |
| `MACE0000000000000000E001` | `XCBuildConfiguration` ext Debug |
| `MACE0000000000000000E002` | `XCBuildConfiguration` ext Release |
| `MACE0000000000000000E003` | `XCBuildConfiguration` ext Profile |
| `MACE0000000000000000F001` | `XCConfigurationList` for extension target |
| `MACE0000000000000000F002` | `PBXContainerItemProxy` (Runner → ext) |
| `MACE0000000000000000F003` | `PBXTargetDependency` (Runner depends on ext) |

#### Sub-step 1: Add build file entries (PBXBuildFile section)

Find the line:
```
/* End PBXBuildFile section */
```

Insert **before** it:

```
		MACE0000000000000000B001 /* MacCredentialProviderViewController.swift in Sources */ = {isa = PBXBuildFile; fileRef = MACE0000000000000000A002 /* MacCredentialProviderViewController.swift */; };
		MACE0000000000000000B002 /* SharedAutofillStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = MACE0000000000000000A003 /* SharedAutofillStore.swift */; };
		MACE0000000000000000B003 /* BridgeClient.swift in Sources */ = {isa = PBXBuildFile; fileRef = MACE0000000000000000A004 /* BridgeClient.swift */; };
		MACE0000000000000000B004 /* CredentialListView.swift in Sources */ = {isa = PBXBuildFile; fileRef = MACE0000000000000000A005 /* CredentialListView.swift */; };
		MACE0000000000000000B005 /* CredentialProviderExtension.appex in Embed App Extensions */ = {isa = PBXBuildFile; fileRef = MACE0000000000000000A001 /* CredentialProviderExtension.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };
```

#### Sub-step 2: Add container proxy and Embed App Extensions phase (PBXContainerItemProxy + PBXCopyFilesBuildPhase)

Find the line:
```
/* End PBXContainerItemProxy section */
```

Insert **before** it:

```
		MACE0000000000000000F002 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 33CC10E52044A3C60003C045 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = MACE0000000000000000C001;
			remoteInfo = CredentialProviderExtension;
		};
```

Find the line:
```
/* End PBXCopyFilesBuildPhase section */
```

Insert **before** it:

```
		MACE0000000000000000D004 /* Embed App Extensions */ = {
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				MACE0000000000000000B005 /* CredentialProviderExtension.appex in Embed App Extensions */,
			);
			name = "Embed App Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		};
```

#### Sub-step 3: Add file references (PBXFileReference section)

Find the line:
```
/* End PBXFileReference section */
```

Insert **before** it:

```
		MACE0000000000000000A001 /* CredentialProviderExtension.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = CredentialProviderExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; };
		MACE0000000000000000A002 /* MacCredentialProviderViewController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MacCredentialProviderViewController.swift; sourceTree = "<group>"; };
		MACE0000000000000000A003 /* SharedAutofillStore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SharedAutofillStore.swift; sourceTree = "<group>"; };
		MACE0000000000000000A004 /* BridgeClient.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BridgeClient.swift; sourceTree = "<group>"; };
		MACE0000000000000000A005 /* CredentialListView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CredentialListView.swift; sourceTree = "<group>"; };
		MACE0000000000000000A006 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		MACE0000000000000000A007 /* CredentialProviderExtension.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = CredentialProviderExtension.entitlements; sourceTree = "<group>"; };
```

#### Sub-step 4: Add Frameworks build phase for extension (PBXFrameworksBuildPhase section)

Find:
```
/* End PBXFrameworksBuildPhase section */
```

Insert **before** it:

```
		MACE0000000000000000D002 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

#### Sub-step 5: Add extension group + update Products group + update root group (PBXGroup section)

Find:
```
/* End PBXGroup section */
```

Insert **before** it:

```
		MACE0000000000000000C002 /* CredentialProviderExtension */ = {
			isa = PBXGroup;
			children = (
				MACE0000000000000000A002 /* MacCredentialProviderViewController.swift */,
				MACE0000000000000000A003 /* SharedAutofillStore.swift */,
				MACE0000000000000000A004 /* BridgeClient.swift */,
				MACE0000000000000000A005 /* CredentialListView.swift */,
				MACE0000000000000000A006 /* Info.plist */,
				MACE0000000000000000A007 /* CredentialProviderExtension.entitlements */,
			);
			path = CredentialProviderExtension;
			sourceTree = "<group>";
		};
```

Add the appex to the **Products** group. Find:

```
		33CC10EE2044A3C60003C045 /* Products */ = {
			isa = PBXGroup;
			children = (
				33CC10ED2044A3C60003C045 /* Custode.app */,
				331C80D5294CF71000263BE5 /* RunnerTests.xctest */,
			);
```

Replace with:

```
		33CC10EE2044A3C60003C045 /* Products */ = {
			isa = PBXGroup;
			children = (
				33CC10ED2044A3C60003C045 /* Custode.app */,
				331C80D5294CF71000263BE5 /* RunnerTests.xctest */,
				MACE0000000000000000A001 /* CredentialProviderExtension.appex */,
			);
```

Add the extension group to the **root group**. Find:

```
		33CC10E42044A3C60003C045 = {
			isa = PBXGroup;
			children = (
				33FAB671232836740065AC1E /* Runner */,
				33CEB47122A05771004F2AC0 /* Flutter */,
				331C80D6294CF71000263BE5 /* RunnerTests */,
				33CC10EE2044A3C60003C045 /* Products */,
				D73912EC22F37F3D000D13A0 /* Frameworks */,
				4FCC8104D1348442046AB49B /* Pods */,
			);
```

Replace with:

```
		33CC10E42044A3C60003C045 = {
			isa = PBXGroup;
			children = (
				33FAB671232836740065AC1E /* Runner */,
				33CEB47122A05771004F2AC0 /* Flutter */,
				MACE0000000000000000C002 /* CredentialProviderExtension */,
				331C80D6294CF71000263BE5 /* RunnerTests */,
				33CC10EE2044A3C60003C045 /* Products */,
				D73912EC22F37F3D000D13A0 /* Frameworks */,
				4FCC8104D1348442046AB49B /* Pods */,
			);
```

#### Sub-step 6: Add extension PBXNativeTarget

Find:
```
/* End PBXNativeTarget section */
```

Insert **before** it:

```
		MACE0000000000000000C001 /* CredentialProviderExtension */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = MACE0000000000000000F001 /* Build configuration list for PBXNativeTarget "CredentialProviderExtension" */;
			buildPhases = (
				MACE0000000000000000D001 /* Sources */,
				MACE0000000000000000D002 /* Frameworks */,
				MACE0000000000000000D003 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = CredentialProviderExtension;
			productName = CredentialProviderExtension;
			productReference = MACE0000000000000000A001 /* CredentialProviderExtension.appex */;
			productType = "com.apple.product-type.app-extension";
		};
```

#### Sub-step 7: Update Runner target — add Embed phase + dependency

Find the Runner target definition:

```
		33CC10EC2044A3C60003C045 /* Runner */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 33CC10FB2044A3C60003C045 /* Build configuration list for PBXNativeTarget "Runner" */;
			buildPhases = (
				7D2A43F7842501625D13F654 /* [CP] Check Pods Manifest.lock */,
				33CC10E92044A3C60003C045 /* Sources */,
				33CC10EA2044A3C60003C045 /* Frameworks */,
				33CC10EB2044A3C60003C045 /* Resources */,
				33CC110E2044A8840003C045 /* Bundle Framework */,
				3399D490228B24CF009A79C7 /* ShellScript */,
				7F8C5EC3DFA8BE997226B381 /* [CP] Embed Pods Frameworks */,
				F784FF64469D085688A3C613 /* [CP] Copy Pods Resources */,
				B2E4A8F13C7D9E5A0F2B4C6D /* Copy Flutter dSYMs */,
			);
			buildRules = (
			);
			dependencies = (
				33CC11202044C79F0003C045 /* PBXTargetDependency */,
			);
```

Replace with:

```
		33CC10EC2044A3C60003C045 /* Runner */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 33CC10FB2044A3C60003C045 /* Build configuration list for PBXNativeTarget "Runner" */;
			buildPhases = (
				7D2A43F7842501625D13F654 /* [CP] Check Pods Manifest.lock */,
				33CC10E92044A3C60003C045 /* Sources */,
				33CC10EA2044A3C60003C045 /* Frameworks */,
				33CC10EB2044A3C60003C045 /* Resources */,
				33CC110E2044A8840003C045 /* Bundle Framework */,
				3399D490228B24CF009A79C7 /* ShellScript */,
				7F8C5EC3DFA8BE997226B381 /* [CP] Embed Pods Frameworks */,
				F784FF64469D085688A3C613 /* [CP] Copy Pods Resources */,
				B2E4A8F13C7D9E5A0F2B4C6D /* Copy Flutter dSYMs */,
				MACE0000000000000000D004 /* Embed App Extensions */,
			);
			buildRules = (
			);
			dependencies = (
				33CC11202044C79F0003C045 /* PBXTargetDependency */,
				MACE0000000000000000F003 /* PBXTargetDependency */,
			);
```

#### Sub-step 8: Add extension to project targets + TargetAttributes (PBXProject section)

Find:

```
			targets = (
				33CC10EC2044A3C60003C045 /* Runner */,
				331C80D4294CF70F00263BE5 /* RunnerTests */,
				33CC111A2044C6BA0003C045 /* Flutter Assemble */,
			);
```

Replace with:

```
			targets = (
				33CC10EC2044A3C60003C045 /* Runner */,
				MACE0000000000000000C001 /* CredentialProviderExtension */,
				331C80D4294CF70F00263BE5 /* RunnerTests */,
				33CC111A2044C6BA0003C045 /* Flutter Assemble */,
			);
```

Find the TargetAttributes dict (it contains `33CC111A2044C6BA0003C045`). Look for:

```
				33CC111A2044C6BA0003C045 = {
					CreatedOnToolsVersion = 9.2;
					ProvisioningStyle = Manual;
				};
```

Replace with:

```
				33CC111A2044C6BA0003C045 = {
					CreatedOnToolsVersion = 9.2;
					ProvisioningStyle = Manual;
				};
				MACE0000000000000000C001 = {
					CreatedOnToolsVersion = 15.0;
					SystemCapabilities = {
						com.apple.Sandbox = {
							enabled = 1;
						};
					};
				};
```

#### Sub-step 9: Add Resources build phase for extension (PBXResourcesBuildPhase section)

Find:
```
/* End PBXResourcesBuildPhase section */
```

Insert **before** it:

```
		MACE0000000000000000D003 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

#### Sub-step 10: Add Sources build phase for extension (PBXSourcesBuildPhase section)

Find:
```
/* End PBXSourcesBuildPhase section */
```

Insert **before** it:

```
		MACE0000000000000000D001 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				MACE0000000000000000B001 /* MacCredentialProviderViewController.swift in Sources */,
				MACE0000000000000000B002 /* SharedAutofillStore.swift in Sources */,
				MACE0000000000000000B003 /* BridgeClient.swift in Sources */,
				MACE0000000000000000B004 /* CredentialListView.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

#### Sub-step 11: Add target dependency (PBXTargetDependency section)

Find:
```
/* End PBXTargetDependency section */
```

Insert **before** it:

```
		MACE0000000000000000F003 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = MACE0000000000000000C001 /* CredentialProviderExtension */;
			targetProxy = MACE0000000000000000F002 /* PBXContainerItemProxy */;
		};
```

#### Sub-step 12: Add build configurations for extension (XCBuildConfiguration section)

Find:
```
/* End XCBuildConfiguration section */
```

Insert **before** it:

```
		MACE0000000000000000E001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				APPLICATION_EXTENSION_API_ONLY = YES;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_ENTITLEMENTS = CredentialProviderExtension/CredentialProviderExtension.entitlements;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = A8QUU5F9G3;
				INFOPLIST_FILE = CredentialProviderExtension/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
					"@executable_path/../../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.camillobucciarelli.kdbxKeyVault.CredentialProviderMac;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = macosx;
				SKIP_INSTALL = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
				VERSIONING_SYSTEM = "apple-generic";
			};
			name = Debug;
		};
		MACE0000000000000000E002 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				APPLICATION_EXTENSION_API_ONLY = YES;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_ENTITLEMENTS = CredentialProviderExtension/CredentialProviderExtension.entitlements;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = A8QUU5F9G3;
				INFOPLIST_FILE = CredentialProviderExtension/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
					"@executable_path/../../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.camillobucciarelli.kdbxKeyVault.CredentialProviderMac;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = macosx;
				SKIP_INSTALL = YES;
				SWIFT_VERSION = 5.0;
				VERSIONING_SYSTEM = "apple-generic";
			};
			name = Release;
		};
		MACE0000000000000000E003 /* Profile */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				APPLICATION_EXTENSION_API_ONLY = YES;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_ENTITLEMENTS = CredentialProviderExtension/CredentialProviderExtension.entitlements;
				CODE_SIGN_IDENTITY = "Apple Development";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = A8QUU5F9G3;
				INFOPLIST_FILE = CredentialProviderExtension/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
					"@executable_path/../../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.camillobucciarelli.kdbxKeyVault.CredentialProviderMac;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = macosx;
				SKIP_INSTALL = YES;
				SWIFT_VERSION = 5.0;
				VERSIONING_SYSTEM = "apple-generic";
			};
			name = Profile;
		};
```

#### Sub-step 13: Add XCConfigurationList for extension (XCConfigurationList section)

Find:
```
/* End XCConfigurationList section */
```

Insert **before** it:

```
		MACE0000000000000000F001 /* Build configuration list for PBXNativeTarget "CredentialProviderExtension" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				MACE0000000000000000E001 /* Debug */,
				MACE0000000000000000E002 /* Release */,
				MACE0000000000000000E003 /* Profile */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
```

#### Sub-step 14: Raise project-level deployment target from 10.15 to 14.0

The project.pbxproj has three occurrences of `MACOSX_DEPLOYMENT_TARGET = 10.15;` in the project-level build configurations (Profile `338D0CE9`, Debug `33CC10F9`, Release `33CC10FA`). Replace all three:

```
				MACOSX_DEPLOYMENT_TARGET = 14.0;
```

Use `replace_all: true` in the Edit tool — this will hit all three occurrences.

- [ ] **Step 1 through 14: Apply all sub-steps above to `macos/Runner.xcodeproj/project.pbxproj`**

Apply sub-steps 1–14 using the Edit tool for each precise string replacement.

- [ ] **Step 15: Verify the pbxproj parses correctly**

```bash
plutil -lint macos/Runner.xcodeproj/project.pbxproj
```

Expected: `macos/Runner.xcodeproj/project.pbxproj: OK`

- [ ] **Step 16: Commit**

```bash
git add macos/Runner.xcodeproj/project.pbxproj
git commit -m "feat: add CredentialProviderExtension target to macOS Xcode project, raise deploy target to 14.0"
```

---

### Task 8: Build verification

- [ ] **Step 1: Flutter analyze (Dart side)**

```bash
flutter analyze
```

Expected: `No issues found!`

- [ ] **Step 2: Attempt macOS build**

```bash
flutter build macos --debug 2>&1 | tail -30
```

Expected: build succeeds. Look for `Build Succeeded` in the output.

If the build fails with Swift compile errors, diagnose from the error message — the most likely issues are:
- `APPLICATION_EXTENSION_API_ONLY` blocking an API: switch to an extension-safe alternative
- Missing `import` in a Swift file: add the missing import
- Xcode can't find files: verify the file paths in the `.pbxproj` match the actual filesystem paths

- [ ] **Step 3: Commit if no further changes were needed**

```bash
git add -p   # review any fixups
git commit -m "fix: resolve build issues from macOS extension"   # only if there were fixes
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| macOS deployment target → 14.0 | Task 7 sub-step 14 |
| New Xcode target `CredentialProviderExtension` | Task 7 sub-steps 6–13 |
| Bundle ID `dev.camillobucciarelli.kdbxKeyVault.CredentialProviderMac` | Task 7 sub-step 12 |
| Extension point `com.apple.authentication-services-credential-provider-ui` | Task 6 Info.plist |
| `BridgeClient.swift` — reads bridge.json, POST /v1/find, 1.5s timeout | Task 3 |
| Token expiry check | Task 3 (`isExpired`) |
| `SharedAutofillStore.swift` (App Group fallback) | Task 2 |
| `MacCredentialProviderViewController.swift` — bridge + fallback | Task 5 |
| Best-match logic (score > 0 single / score ≥ 140 silent fill) | Task 5 |
| `prepareCredentialList` | Task 5 |
| `provideCredentialWithoutUserInteraction(for:)` | Task 5 |
| `provideCredentialWithoutUserInteraction(for credentialRequest:)` macOS 14 | Task 5 |
| `prepareInterfaceToProvideCredential` — shows full list | Task 5 |
| `prepareInterfaceForExtensionConfiguration` | Task 5 |
| `CredentialListView.swift` via `NSHostingController` | Tasks 4 + 5 |
| `IosAutofillSnapshotCoordinator` enabled on macOS | Task 1 |
| App Group in Runner entitlements | Task 1 |
| App Group in extension entitlements | Task 6 |
| Extension embedded in Runner | Task 7 sub-steps 2 + 7 |

All spec requirements covered. No placeholders detected.
