import Cocoa
import FlutterMacOS
import OSLog

private let autofillLog = Logger(
  subsystem: "dev.camillobucciarelli.kdbxKeyVault",
  category: "autofill-host"
)

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

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 420, height: 640)

    RegisterGeneratedPlugins(registry: flutterViewController)
    OtpAuthDeepLinkForwarder.shared.configure(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    AppleAutofillV2Channel.shared.configure(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    // spec 023 T709: after the channel exists, so a request that arrives
    // early is answered through it rather than turned away.
    PasskeyRegistrationPort.shared.start()
    wipeLegacyAutofillPlaintextArtifacts(reason: "app launch")

    super.awakeFromNib()
  }

  private func wipeLegacyAutofillPlaintextArtifacts(reason: String) {
    let appGroupId = "group.dev.camillobucciarelli.kdbxKeyVault"
    let legacyFileNames = [
      "autofill_entries.json",
      "pending_autofill_saves.json",
    ]
    let legacyDefaultsKeys = [
      "autofill_entries_json",
      "autofill_last_sync_epoch_ms",
      "pending_autofill_saves",
    ]

    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      autofillLog.error("legacy autofill cleanup skipped: app group unavailable reason=\(reason, privacy: .public)")
      return
    }

    for fileName in legacyFileNames {
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
      for key in legacyDefaultsKeys {
        defaults.removeObject(forKey: key)
      }
    }
  }
}
