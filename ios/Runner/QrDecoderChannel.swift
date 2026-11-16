import CoreVideo
import Flutter
import Vision

/// Decodes a QR code from a BGRA camera frame with Apple Vision. On-device,
/// no third-party code.
final class QrDecoderChannel {
  static let shared = QrDecoderChannel()

  private let channelName = "dev.camillobucciarelli.kdbxKeyVault/qr_decoder"
  private let queue = DispatchQueue(label: "qr-decoder", qos: .userInitiated)
  private var channel: FlutterMethodChannel?

  func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { [queue] call, result in
      guard call.method == "decode" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data,
        let width = args["width"] as? Int,
        let height = args["height"] as? Int,
        let bytesPerRow = args["bytesPerRow"] as? Int
      else {
        result(FlutterError(code: "bad_args", message: "bytes, width, height, bytesPerRow required", details: nil))
        return
      }
      queue.async {
        let text = QrDecoderChannel.decode(
          bgra: bytes, width: width, height: height, bytesPerRow: bytesPerRow)
        DispatchQueue.main.async { result(text) }
      }
    }
    self.channel = channel
  }

  /// The QR text, or nil when no code is found or the arguments do not
  /// describe the buffer.
  static func decode(bgra: Data, width: Int, height: Int, bytesPerRow: Int) -> String? {
    guard width > 0, height > 0, bytesPerRow >= width * 4,
      bgra.count >= bytesPerRow * (height - 1) + width * 4
    else { return nil }
    var data = bgra
    return data.withUnsafeMutableBytes { raw -> String? in
      guard let base = raw.baseAddress else { return nil }
      var pixelBuffer: CVPixelBuffer?
      // Wraps `data` without copying; the buffer is only used inside this
      // closure, while the bytes are alive.
      let status = CVPixelBufferCreateWithBytes(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        base, bytesPerRow, nil, nil, nil, &pixelBuffer)
      guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
      let request = VNDetectBarcodesRequest()
      request.symbologies = [.qr]
      // Vision reads QR codes at any rotation, so no orientation is passed.
      try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
      return request.results?.compactMap { $0.payloadStringValue }.first
    }
  }
}
