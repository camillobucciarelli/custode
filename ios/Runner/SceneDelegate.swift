import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    configureOtpAuthChannelIfPossible()
    connectionOptions.urlContexts.forEach { OtpAuthDeepLinkForwarder.shared.receive($0.url) }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let otpAuthContexts = URLContexts.filter { $0.url.scheme?.lowercased() == "otpauth" }
    let otherContexts = URLContexts.subtracting(otpAuthContexts)
    otpAuthContexts.forEach { OtpAuthDeepLinkForwarder.shared.receive($0.url) }
    if !otherContexts.isEmpty {
      super.scene(scene, openURLContexts: otherContexts)
    }
  }

  private func configureOtpAuthChannelIfPossible() {
    if XCTestHost.isActive { return }
    if let controller = window?.rootViewController as? FlutterViewController {
      OtpAuthDeepLinkForwarder.shared.configure(binaryMessenger: controller.binaryMessenger)
      AppleAutofillV2Channel.shared.configure(binaryMessenger: controller.binaryMessenger)
    }
  }
}
