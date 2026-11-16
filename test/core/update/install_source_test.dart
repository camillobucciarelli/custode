import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/update/install_source.dart';

void main() {
  Future<bool> check(bool android, String? pkg) =>
      isInstalledFromGooglePlay(isAndroid: android, installer: () async => pkg);

  test('Play installer on Android is detected', () async {
    expect(await check(true, 'com.android.vending'), isTrue);
  });
  test('sideload, other store, non-Android are not Play', () async {
    expect(await check(true, null), isFalse);
    expect(await check(true, 'com.google.android.packageinstaller'), isFalse);
    expect(await check(false, 'com.android.vending'), isFalse);
  });
  test('channel failure is not Play', () async {
    expect(
      await isInstalledFromGooglePlay(
        isAndroid: true,
        installer: () async => throw Exception('x'),
      ),
      isFalse,
    );
  });
}
