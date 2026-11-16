import 'dart:typed_data';

/// One camera frame's first plane: the luminance (Y) plane on Android, the
/// BGRA buffer on iOS. The platform decoder knows which one it receives.
class QrFrame {
  const QrFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;
}

/// Port: decodes a QR code from a camera frame on the device.
abstract interface class QrCodeDecoder {
  /// The QR code's text, or null when the frame holds none.
  Future<String?> decode(QrFrame frame);
}
