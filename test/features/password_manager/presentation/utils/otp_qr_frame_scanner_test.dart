import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/datasources/qr_code_decoder_data_source.dart';
import 'package:password_manager/features/password_manager/domain/repositories/qr_code_decoder.dart';
import 'package:password_manager/features/password_manager/presentation/utils/otp_qr_frame_scanner.dart';

QrFrame _frame() =>
    QrFrame(bytes: Uint8List(4), width: 2, height: 2, bytesPerRow: 2);

void main() {
  late DateTime clock;
  late List<String> uris;
  late int invalid;

  OtpQrFrameScanner scanner(Future<String?> Function(QrFrame) decode) =>
      OtpQrFrameScanner(
        decode: decode,
        onOtpUri: uris.add,
        onInvalidQr: () => invalid++,
        now: () => clock,
      );

  void advance([int ms = 300]) => clock = clock.add(Duration(milliseconds: ms));

  setUp(() {
    clock = DateTime(2026);
    uris = [];
    invalid = 0;
  });

  test('drops frames while a decode is in flight', () async {
    final pending = Completer<String?>();
    var calls = 0;
    var built = 0;
    final s = scanner((_) {
      calls++;
      return pending.future;
    });
    QrFrame build() {
      built++;
      return _frame();
    }

    final first = s.offer(build);
    advance(1000);
    await s.offer(build);
    expect(calls, 1);
    expect(built, 1, reason: 'a dropped frame must not be copied');

    pending.complete(null);
    await first;
    await s.offer(build);
    expect(calls, 2);
  });

  test('decodes at most once per interval', () async {
    var calls = 0;
    final s = scanner((_) async {
      calls++;
      return null;
    });

    await s.offer(_frame);
    advance(299);
    await s.offer(_frame);
    expect(calls, 1);
    advance(1);
    await s.offer(_frame);
    expect(calls, 2);
  });

  test('reports the first otpauth URI once and then stops', () async {
    var calls = 0;
    final s = scanner((_) async {
      calls++;
      return ' otpauth://totp/a?secret=JBSWY3DPEHPK3PXP\n';
    });

    await s.offer(_frame);
    advance();
    await s.offer(_frame);
    expect(uris, ['otpauth://totp/a?secret=JBSWY3DPEHPK3PXP']);
    expect(calls, 1);
    expect(invalid, 0);
  });

  test('reports a non-OTP code once while it stays in view, '
      'then keeps scanning', () async {
    final results = [
      'https://example.com',
      'https://example.com',
      'other',
      'otpauth://totp/a?secret=A',
    ];
    final s = scanner((_) async => results.removeAt(0));

    await s.offer(_frame);
    advance();
    await s.offer(_frame);
    expect(invalid, 1);
    advance();
    await s.offer(_frame);
    expect(invalid, 2);
    advance();
    await s.offer(_frame);
    expect(uris, ['otpauth://totp/a?secret=A']);
  });

  test('a decode error counts as no code and scanning continues', () async {
    var calls = 0;
    final s = scanner((_) async {
      if (calls++ == 0) throw PlatformException(code: 'decode_failed');
      return 'otpauth://totp/a?secret=A';
    });

    await s.offer(_frame);
    expect(uris, isEmpty);
    advance();
    await s.offer(_frame);
    expect(uris, hasLength(1));
  });

  test('stop() discards a decode still in flight', () async {
    final pending = Completer<String?>();
    final s = scanner((_) => pending.future);

    final first = s.offer(_frame);
    s.stop();
    pending.complete('otpauth://totp/a?secret=A');
    await first;
    expect(uris, isEmpty);
  });

  test(
    'the channel data source sends the frame and returns the text',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel(QrCodeDecoderDataSource.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return 'otpauth://totp/a?secret=A';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final text = await const QrCodeDecoderDataSource().decode(
        QrFrame(
          bytes: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
          width: 2,
          height: 2,
          bytesPerRow: 3,
        ),
      );

      expect(text, 'otpauth://totp/a?secret=A');
      expect(seen!.method, 'decode');
      expect(seen!.arguments, {
        'bytes': [1, 2, 3, 4, 5, 6],
        'width': 2,
        'height': 2,
        'bytesPerRow': 3,
      });
    },
  );
}
