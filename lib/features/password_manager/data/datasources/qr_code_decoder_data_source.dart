import 'package:flutter/services.dart';

import '../../domain/repositories/qr_code_decoder.dart';

/// Decodes QR codes with the platform's own library: ZXing
/// (`com.google.zxing:core`) on Android, Apple Vision on iOS. See
/// `QrDecoderChannel.kt` and `QrDecoderChannel.swift`.
class QrCodeDecoderDataSource implements QrCodeDecoder {
  const QrCodeDecoderDataSource({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'dev.camillobucciarelli.kdbxKeyVault/qr_decoder';

  final MethodChannel _channel;

  @override
  Future<String?> decode(QrFrame frame) =>
      _channel.invokeMethod<String>('decode', <String, Object>{
        'bytes': frame.bytes,
        'width': frame.width,
        'height': frame.height,
        'bytesPerRow': frame.bytesPerRow,
      });
}
