import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';

const _channel = MethodChannel(
  'dev.camillobucciarelli.kdbxKeyVault/install_source',
);

/// True when running on Android and installed by Google Play. Any failure
/// reads as "not Play", so sideloaded builds keep the update check.
Future<bool> isInstalledFromGooglePlay({
  bool? isAndroid,
  Future<String?> Function()? installer,
}) async {
  if (!(isAndroid ?? defaultTargetPlatform == TargetPlatform.android)) {
    return false;
  }
  try {
    final pkg =
        await (installer?.call() ??
            _channel.invokeMethod<String>('installerPackage'));
    return pkg == 'com.android.vending';
  } catch (_) {
    return false;
  }
}
