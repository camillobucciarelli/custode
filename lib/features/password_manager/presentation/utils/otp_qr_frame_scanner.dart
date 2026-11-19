import '../../domain/repositories/qr_code_decoder.dart';

/// Feeds camera frames to a QR decoder: at most one decode in flight, at most
/// one per [minInterval], and nothing after the first `otpauth://` result.
class OtpQrFrameScanner {
  OtpQrFrameScanner({
    required this.decode,
    required this.onOtpUri,
    required this.onInvalidQr,
    this.minInterval = const Duration(milliseconds: 300),
    this.now = DateTime.now,
  });

  final Future<String?> Function(QrFrame frame) decode;
  final DateTime Function() now;

  /// Called once, with the first `otpauth://` URI read.
  final void Function(String uri) onOtpUri;

  /// Called when a QR code holds something else; once per distinct code in a
  /// row, so a code held in view does not repeat the message.
  final void Function() onInvalidQr;

  final Duration minInterval;

  bool _busy = false;
  bool _stopped = false;
  DateTime? _lastDecodeAt;
  String? _lastInvalid;

  /// Drops every later frame and any decode still in flight.
  void stop() => _stopped = true;

  /// [frame] is only built when the frame is actually decoded.
  Future<void> offer(QrFrame Function() frame) async {
    if (_stopped || _busy) return;
    final startedAt = now();
    final last = _lastDecodeAt;
    if (last != null && startedAt.difference(last) < minInterval) return;

    _busy = true;
    _lastDecodeAt = startedAt;
    String? text;
    try {
      text = (await decode(frame()))?.trim();
    } catch (_) {
      // A frame that fails to decode is the same as a frame with no code.
      text = null;
    } finally {
      _busy = false;
    }
    if (_stopped || text == null || text.isEmpty) return;

    if (text.startsWith('otpauth://')) {
      _stopped = true;
      onOtpUri(text);
    } else if (text != _lastInvalid) {
      _lastInvalid = text;
      onInvalidQr();
    }
  }
}
