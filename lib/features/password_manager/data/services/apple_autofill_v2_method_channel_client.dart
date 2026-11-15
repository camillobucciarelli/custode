import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/models/apple_autofill_v2_models.dart';
import '../../domain/models/pending_passkey_registration.dart';
import '../../domain/repositories/autofill_ports.dart';

class AppleAutofillV2MethodChannelClient
    implements AppleAutofillV2Client, PendingPasskeyRegistrationPort {
  AppleAutofillV2MethodChannelClient({
    MethodChannel? channel,
    this._isSupportedOverride,
  }) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName =
      'dev.camillobucciarelli.keyvault/apple_autofill_v2';

  /// The native side's "this capture is gone" answer — expected, not an error.
  static const _captureMissingCode = 'android_autofill_capture_missing';

  final MethodChannel _channel;
  final bool? _isSupportedOverride;

  @override
  bool get isSupported {
    final override = _isSupportedOverride;
    if (override != null) {
      return override;
    }
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  Future<AppleAutofillV2PublishResult> publishCredentials({
    required String databaseId,
    required List<AppleAutofillV2Credential> credentials,
    int authSessionTtlMs = 0,
  }) async {
    if (!isSupported) {
      return const AppleAutofillV2PublishResult.unsupported();
    }

    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'publishCredentials',
      {
        'databaseId': databaseId,
        'entries': credentials
            .map((credential) => credential.toChannelMap())
            .toList(growable: false),
        'authSessionTtlMs': authSessionTtlMs,
      },
    );
    return AppleAutofillV2PublishResult.fromMap(result);
  }

  @override
  Future<AppleAutofillV2ClearResult> clearCredentials({
    String? databaseId,
  }) async {
    if (!isSupported) {
      return const AppleAutofillV2ClearResult.unsupported();
    }

    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'clearCredentials',
      databaseId == null ? null : {'databaseId': databaseId},
    );
    return AppleAutofillV2ClearResult.fromMap(result);
  }

  @override
  Future<List<AppleAutofillV2PendingAssociation>>
  readPendingAssociations() async {
    if (!isSupported) {
      return const [];
    }

    final result = await _channel.invokeMethod<List<dynamic>>(
      'readPendingAssociations',
    );
    return (result ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(AppleAutofillV2PendingAssociation.fromMap)
        .toList(growable: false);
  }

  @override
  Future<AppleAutofillV2ClearPendingAssociationsResult>
  clearPendingAssociations({List<String>? ids}) async {
    if (!isSupported) {
      return const AppleAutofillV2ClearPendingAssociationsResult.unsupported();
    }

    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'clearPendingAssociations',
      ids == null ? null : {'ids': ids},
    );
    return AppleAutofillV2ClearPendingAssociationsResult.fromMap(result);
  }

  /// Save capture is an Android-only path: the Apple credential provider has no
  /// equivalent of `onSaveRequest`.
  bool get _supportsCapture =>
      isSupported &&
      (_isSupportedOverride == null
          ? defaultTargetPlatform == TargetPlatform.android
          : true);

  @override
  Future<String?> takePendingCaptureToken() async {
    if (!_supportsCapture) {
      return null;
    }
    return _channel.invokeMethod<String>('takePendingCaptureToken');
  }

  @override
  Future<AndroidAutofillCapture?> readPendingCapture(String token) async {
    if (!_supportsCapture) {
      throw UnsupportedError(
        'Autofill save capture is not supported on this platform.',
      );
    }

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'readPendingCapture',
        {'token': token},
      );
      return result == null ? null : AndroidAutofillCapture.fromMap(result);
    } on PlatformException catch (error) {
      if (error.code == _captureMissingCode) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<AppleAutofillV2ClearPendingAssociationsResult> resolvePendingCapture({
    required String token,
    required AndroidAutofillCaptureOutcome outcome,
  }) async {
    if (!_supportsCapture) {
      throw UnsupportedError(
        'Autofill save capture is not supported on this platform.',
      );
    }

    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'resolvePendingCapture',
      {'token': token, 'outcome': outcome.channelValue},
    );
    return AppleAutofillV2ClearPendingAssociationsResult.fromMap(result);
  }

  @override
  Future<bool?> getExtensionEnabled() async {
    if (!isSupported || defaultTargetPlatform == TargetPlatform.android) {
      return null;
    }
    return _channel.invokeMethod<bool>('getExtensionEnabled');
  }

  @override
  Future<AndroidPasskeyProviderAvailability>
  getPasskeyProviderAvailability() async {
    if (!isSupported || defaultTargetPlatform != TargetPlatform.android) {
      return const AndroidPasskeyProviderAvailability.unsupported();
    }
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getPasskeyProviderAvailability',
      );
      return AndroidPasskeyProviderAvailability.fromMap(result);
    } on MissingPluginException {
      // An older native side that has no such method: not available, which is
      // the honest answer rather than an error the settings row cannot show.
      return const AndroidPasskeyProviderAvailability.unsupported();
    }
  }

  @override
  Future<PendingPasskeyRegistrations> readPendingPasskeyRegistrations() async {
    if (!isSupported) {
      return const PendingPasskeyRegistrations();
    }
    final Map<dynamic, dynamic>? result;
    try {
      result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'readPendingPasskeyRegistrations',
      );
    } on MissingPluginException {
      // A native side without the queue has nothing pending.
      return const PendingPasskeyRegistrations();
    }
    final rawRecords = result?['records'];
    final rawUnreadable = result?['unreadableCount'];
    final records = <PendingPasskeyRegistration>[];
    var unreadable = rawUnreadable is int && rawUnreadable > 0
        ? rawUnreadable
        : 0;
    // Malformed records are counted, never thrown and never logged: the map
    // carries a private key.
    for (final raw in rawRecords is List ? rawRecords : const []) {
      final record = PendingPasskeyRegistration.tryFromChannelMap(raw);
      record == null ? unreadable++ : records.add(record);
    }
    return PendingPasskeyRegistrations(
      records: List.unmodifiable(records),
      unreadableCount: unreadable,
    );
  }

  @override
  Future<int> countPendingPasskeyRegistrations() async {
    if (!isSupported) {
      return 0;
    }
    try {
      return await _channel.invokeMethod<int>(
            'countPendingPasskeyRegistrations',
          ) ??
          0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
  }

  @override
  Future<bool> resolvePendingPasskeyRegistration(String recordId) async {
    if (!isSupported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'resolvePendingPasskeyRegistration',
            {'recordId': recordId},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<AppleAutofillV2Status> getStatus() async {
    if (!isSupported) {
      return const AppleAutofillV2Status.unsupported();
    }

    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getStatus',
    );
    return AppleAutofillV2Status.fromMap(result, supported: true);
  }
}
