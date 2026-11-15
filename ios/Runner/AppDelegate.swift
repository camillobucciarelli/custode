import Flutter
import OSLog
import UIKit

private let autofillLog = Logger(
  subsystem: "dev.camillobucciarelli.kdbxKeyVault",
  category: "autofill-host"
)

/// True only when this process is the host of an XCTest bundle. RunnerTests is
/// hosted by the real app (TEST_HOST); letting Flutter start there runs Dart
/// startup, which calls native `clearCredentials` and can wipe the real
/// App Group autofill cache and keychain key. Requires the XCTest class AND an
/// XCTest-set environment variable, so neither alone (a stray env var in a
/// normal launch, or a linked XCTest) can blank the app. No user-settable flag.
enum XCTestHost {
  static let isActive: Bool = {
    guard NSClassFromString("XCTestCase") != nil else { return false }
    let env = ProcessInfo.processInfo.environment
    return env["XCTestConfigurationFilePath"] != nil
      || env["XCTestBundlePath"] != nil
      || env["XCTestSessionIdentifier"] != nil
  }()
}

/// Main.storyboard's root controller. Under an XCTest host it never loads its
/// view, so the Flutter engine is never run (see XCTestHost). Identical to
/// FlutterViewController in every normal launch.
@objc(RunnerViewController)
final class RunnerViewController: FlutterViewController {
  override func loadView() {
    if XCTestHost.isActive {
      view = UIView()
      return
    }
    super.loadView()
  }

  override func viewDidLoad() {
    if XCTestHost.isActive { return }
    super.viewDidLoad()
  }
}

final class OtpAuthDeepLinkForwarder {
  static let shared = OtpAuthDeepLinkForwarder()

  private let channelName = "dev.camillobucciarelli.kdbxKeyVault/otpauth_deep_link"
  private var channel: FlutterMethodChannel?
  private var pendingUrls: [String] = []

  func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takePendingUrls" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.drainPendingUrls() ?? [])
    }
    self.channel = channel
  }

  func receive(_ url: URL) {
    guard url.scheme?.lowercased() == "otpauth" else { return }
    let urlString = url.absoluteString
    pendingUrls.append(urlString)
    channel?.invokeMethod("receiveOtpAuthUrl", arguments: urlString)
  }

  private func drainPendingUrls() -> [String] {
    let urls = pendingUrls
    pendingUrls.removeAll()
    return urls
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let appGroupId = "group.dev.camillobucciarelli.kdbxKeyVault"
  private let legacyAutofillFileNames = [
    "autofill_entries.json",
    "pending_autofill_saves.json",
  ]
  private let legacyAutofillDefaultsKeys = [
    "autofill_entries_json",
    "autofill_last_sync_epoch_ms",
    "pending_autofill_saves",
  ]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if XCTestHost.isActive {
      autofillLog.info("XCTest host: Flutter not started")
      return true
    }
    wipeLegacyAutofillPlaintextArtifacts(reason: "app launch")
    excludeManagedStorageFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    if url.scheme?.lowercased() == "otpauth" {
      OtpAuthDeepLinkForwarder.shared.receive(url)
      return true
    }
    return super.application(app, open: url, options: options)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }


  /// spec 014 FR-7 (T013): the managed vault directories never enter the
  /// iCloud/iTunes backup. Databases and key files are recoverable only
  /// through their own credentials and explicit export, never via a backup
  /// that outlives the device passcode.
  private func excludeManagedStorageFromBackup() {
    guard let documents = FileManager.default.urls(
      for: .documentDirectory, in: .userDomainMask
    ).first else { return }
    for name in ["databases", "keys", "metadata", "database_imports"] {
      var url = documents.appendingPathComponent(name, isDirectory: true)
      try? FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true
      )
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    }
  }

  private func wipeLegacyAutofillPlaintextArtifacts(reason: String) {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      autofillLog.error("legacy autofill cleanup skipped: app group unavailable reason=\(reason, privacy: .public)")
      return
    }

    for fileName in legacyAutofillFileNames {
      let url = containerURL.appendingPathComponent(fileName)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      do {
        try FileManager.default.removeItem(at: url)
        autofillLog.info("legacy autofill plaintext file removed name=\(fileName, privacy: .public) reason=\(reason, privacy: .public)")
      } catch {
        autofillLog.error("legacy autofill plaintext removal failed name=\(fileName, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
      }
    }

    if let defaults = UserDefaults(suiteName: appGroupId) {
      for key in legacyAutofillDefaultsKeys {
        defaults.removeObject(forKey: key)
      }
    }
  }
}
