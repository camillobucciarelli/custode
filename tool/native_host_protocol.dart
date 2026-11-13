import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:password_manager/features/password_manager/data/services/browser_exact_origin.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_autofill_cache.dart';

const nativeHostName = 'dev.camillobucciarelli.keyvault_native_host';
const nativeProtocolVersion = 2;
const maxNativeMessagePayloadBytes = 64 * 1024;
const _maxRevealUsernameBytes = 4096;
const _maxRevealPasswordBytes = 32 * 1024;
const _revealBridgeTimeout = Duration(seconds: 2);

/// spec 023 T501 — `/passkey-assert` waits on a person, not on a lookup.
///
/// The 2-second reveal budget exists because those endpoints answer from
/// memory; this one shows a confirmation in the app and waits for it
/// (FR-015). A two-second ceiling would time out every real sign-in. The
/// page is already waiting on `navigator.credentials.get`, which has no
/// timeout of its own, and a stalled app still ends in a refusal rather
/// than a hang.
const _passkeyAssertBridgeTimeout = Duration(seconds: 90);

const supportedNativeMessageTypes = <String>[
  'hello',
  'status',
  'queryCredentials',
  'searchCredentials',
  'createPendingAssociation',
  'revealForFill',
  // 009 / A008. Deliberately new request types rather than new fields on the
  // existing ones. A native host predating this slice ignores an unknown
  // *field*: it would answer `queryCredentials` with host-only `strongMatches`
  // and `revealForFill` under the lenient popup policy, both of which are
  // exactly the fallback SR-2 forbids, and the extension could only detect the
  // downgrade by noticing an absent echo. It cannot ignore an unknown *type*:
  // it answers `unsupported_type` and there is no path to a secret at all. The
  // fail-closed behaviour is therefore structural instead of contingent.
  'overlayQueryCredentials',
  'overlayRevealForFill',
  // 009 / B007. Same structural fail-closed reasoning as the overlay types:
  // a host predating this slice answers `unsupported_type`, so an old peer
  // can never generate under any policy at all.
  'generatePendingEntry',
  // 023 / T501. Same structural fail-closed reasoning as the types above: a
  // host predating this slice answers `unsupported_type`, so the extension
  // knows to leave `navigator.credentials.get` to the browser instead of
  // wrapping a call nothing can answer.
  'passkeyAssert',
  // 023 / US3. Same structural fail-closed reasoning: a host predating this
  // slice answers `unsupported_type`, so the extension leaves
  // `navigator.credentials.create` to the browser.
  'passkeyCreate',
];

// 023 / T501 note: `challenge` and `allowCredentials` are deliberately NOT in
// the set above, though the contract first said they should be. This set is a
// *rejection* list — a request carrying any of these keys is refused outright
// — and `passkeyAssert` has to carry both, so listing them would refuse every
// sign-in. What the contract actually wanted is that they never come back in
// an error frame, and they cannot: `nativeHostErrorResponse` writes a code and
// a fixed message and never the request payload.

/// Capabilities advertised by `hello`, so the extension can gate the overlay on
/// the host actually implementing this contract instead of probing for it.
///
/// This is the *unconditional* set — what the host binary itself implements.
/// `generatePendingEntryV1` is deliberately not here: it is advertised by
/// `hello` only when the current app bridge descriptor lists it (B007), so an
/// old app makes Generate disappear instead of failing at click time.
const nativeHostCapabilities = <String>[overlayExactOriginCapability];

/// Overlay metadata items returned by one `overlayQueryCredentials` response.
const _maxOverlayItems = 10;

const _sensitiveRequestKeys = <String>{
  'credential',
  'credentials',
  'databasepath',
  'keyfilepath',
  'masterpassword',
  'password',
  'secret',
  'secrets',
};

class NativeHostProtocolException implements Exception {
  const NativeHostProtocolException(
    this.code,
    this.publicMessage, {
    this.canContinue = false,
  });

  final String code;
  final String publicMessage;
  final bool canContinue;

  @override
  String toString() => 'NativeHostProtocolException($code)';
}

class NativeMessageStreamReader {
  NativeMessageStreamReader(
    Stream<List<int>> input, {
    this.maxPayloadBytes = maxNativeMessagePayloadBytes,
  }) : _iterator = StreamIterator<List<int>>(input);

  final int maxPayloadBytes;
  final StreamIterator<List<int>> _iterator;

  List<int>? _currentChunk;
  int _currentOffset = 0;

  Future<Map<String, Object?>?> readMessage() async {
    final header = await _readExactly(4, allowCleanEof: true);
    if (header == null) {
      return null;
    }

    final length = ByteData.sublistView(header).getUint32(0, Endian.little);
    if (length == 0) {
      throw const NativeHostProtocolException(
        'empty_payload',
        'Native message payload is empty.',
        canContinue: true,
      );
    }
    if (length > maxPayloadBytes) {
      throw NativeHostProtocolException(
        'payload_too_large',
        'Native message payload exceeds the v2 size limit.',
      );
    }

    final payload = await _readExactly(length);
    return decodeNativeMessagePayload(
      payload!,
      maxPayloadBytes: maxPayloadBytes,
    );
  }

  Future<Uint8List?> _readExactly(
    int byteCount, {
    bool allowCleanEof = false,
  }) async {
    final builder = BytesBuilder(copy: false);
    var remaining = byteCount;

    while (remaining > 0) {
      if (_currentChunk == null || _currentOffset >= _currentChunk!.length) {
        if (!await _iterator.moveNext()) {
          if (allowCleanEof && builder.length == 0) {
            return null;
          }
          throw const NativeHostProtocolException(
            'incomplete_frame',
            'Native message frame ended before all bytes were read.',
          );
        }
        _currentChunk = _iterator.current;
        _currentOffset = 0;
        if (_currentChunk!.isEmpty) {
          continue;
        }
      }

      final available = _currentChunk!.length - _currentOffset;
      final take = math.min(remaining, available);
      builder.add(
        _currentChunk!.sublist(_currentOffset, _currentOffset + take),
      );
      _currentOffset += take;
      remaining -= take;
    }

    return builder.takeBytes();
  }
}

Uint8List encodeNativeMessage(Map<String, Object?> message) {
  final jsonBytes = utf8.encode(jsonEncode(message));
  final header = ByteData(4)..setUint32(0, jsonBytes.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(jsonBytes))
      .toBytes();
}

Map<String, Object?> decodeNativeMessageFrame(
  Uint8List frame, {
  int maxPayloadBytes = maxNativeMessagePayloadBytes,
}) {
  if (frame.length < 4) {
    throw const NativeHostProtocolException(
      'incomplete_frame',
      'Native message frame is missing its length header.',
    );
  }
  final length = ByteData.sublistView(frame, 0, 4).getUint32(0, Endian.little);
  if (length == 0) {
    throw const NativeHostProtocolException(
      'empty_payload',
      'Native message payload is empty.',
      canContinue: true,
    );
  }
  if (length > maxPayloadBytes) {
    throw const NativeHostProtocolException(
      'payload_too_large',
      'Native message payload exceeds the v2 size limit.',
    );
  }
  if (frame.length - 4 < length) {
    throw const NativeHostProtocolException(
      'incomplete_frame',
      'Native message frame ended before all bytes were read.',
    );
  }
  return decodeNativeMessagePayload(
    Uint8List.sublistView(frame, 4, 4 + length),
    maxPayloadBytes: maxPayloadBytes,
  );
}

Map<String, Object?> decodeNativeMessagePayload(
  Uint8List payload, {
  int maxPayloadBytes = maxNativeMessagePayloadBytes,
}) {
  if (payload.isEmpty) {
    throw const NativeHostProtocolException(
      'empty_payload',
      'Native message payload is empty.',
      canContinue: true,
    );
  }
  if (payload.length > maxPayloadBytes) {
    throw const NativeHostProtocolException(
      'payload_too_large',
      'Native message payload exceeds the v2 size limit.',
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(payload));
  } on FormatException {
    throw const NativeHostProtocolException(
      'invalid_json',
      'Native message payload is not valid JSON.',
      canContinue: true,
    );
  }

  final message = _asStringObjectMap(decoded);
  if (message == null) {
    throw const NativeHostProtocolException(
      'invalid_request',
      'Native message payload must be a JSON object.',
      canContinue: true,
    );
  }
  return message;
}

Future<Map<String, Object?>> handleNativeHostRequest(
  Map<String, Object?> request, {
  DesktopBrowserAutofillCacheStore? store,
}) async {
  final id = _safeRequestId(request['id']);
  final type = _safeRequestType(request['type']);

  if (_containsSensitiveRequestKey(request)) {
    return nativeHostErrorResponse(
      id: id,
      type: type ?? 'error',
      code: 'legacy_fields_rejected',
      message: 'Native Messaging v2 rejects legacy secret-bearing fields. Open and unlock Custode in the desktop app instead.',
    );
  }

  final version = request['version'] ?? request['v'];
  if (version != nativeProtocolVersion) {
    return nativeHostErrorResponse(
      id: id,
      type: type ?? 'error',
      code: 'unsupported_version',
      message: 'Unsupported Native Messaging protocol version.',
    );
  }

  if (type == null) {
    return nativeHostErrorResponse(
      id: id,
      type: 'error',
      code: 'invalid_request',
      message: 'Native Messaging v2 request type is missing or invalid.',
    );
  }

  if (!supportedNativeMessageTypes.contains(type)) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'unsupported_type',
      message: 'Unsupported Native Messaging v2 request type.',
    );
  }

  final payload = _readPayload(request);
  if (payload == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message:
          'Native Messaging v2 payload must be a JSON object when present.',
    );
  }

  final effectiveStore = store ?? DesktopBrowserAutofillCacheStore();

  return switch (type) {
    'hello' => await _helloResponse(id: id, type: type, store: effectiveStore),
    'status' => await _statusResponse(
      id: id,
      type: type,
      store: effectiveStore,
    ),
    'queryCredentials' => await _queryCredentialsResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    'searchCredentials' => await _searchCredentialsResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    'createPendingAssociation' => await _createPendingAssociationResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    'revealForFill' => await _revealForFillResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    'overlayQueryCredentials' => await _overlayQueryCredentialsResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    'overlayRevealForFill' => await _overlayRevealForFillResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    'generatePendingEntry' => await _generatePendingEntryResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    'passkeyAssert' => await _passkeyAssertResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    'passkeyCreate' => await _passkeyCreateResponse(
      id: id,
      type: type,
      payload: payload,
      store: effectiveStore,
    ),
    _ => nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'unsupported_type',
      message: 'Unsupported Native Messaging v2 request type.',
    ),
  };
}

Map<String, Object?> nativeHostErrorResponse({
  required String type,
  required String code,
  required String message,
  String? id,
}) {
  final response = <String, Object?>{
    'version': nativeProtocolVersion,
    'type': type,
    'ok': false,
    'error': {'code': code, 'message': message},
  };
  if (id != null) {
    response['id'] = id;
  }
  return response;
}

Future<Map<String, Object?>> _helloResponse({
  required String? id,
  required String type,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  return _successResponse(
    id: id,
    type: type,
    data: {
      ...await _statusData(store),
      'supportedMessages': supportedNativeMessageTypes,
      'capabilities': await _advertisedCapabilities(store),
    },
  );
}

/// 009 / B007 — host capabilities plus the app-contract-gated ones.
///
/// `generatePendingEntryV1` appears only when the *current* bridge descriptor
/// says the running app actually serves `/generate-pending`. No descriptor,
/// old descriptor, locked app — the capability is simply absent and the
/// extension keeps Generate disabled with honest copy.
Future<List<String>> _advertisedCapabilities(
  DesktopBrowserAutofillCacheStore store,
) async {
  final descriptor = await store.readBridgeDescriptor();
  return [
    ...nativeHostCapabilities,
    if (descriptor != null &&
        descriptor.appCapabilities.contains(
          desktopBrowserGeneratePendingCapability,
        ))
      desktopBrowserGeneratePendingCapability,
    // 023 / T501: same gate. The running app says whether it can sign; the
    // host never claims it on the app's behalf.
    if (descriptor != null &&
        descriptor.appCapabilities.contains(
          desktopBrowserPasskeyAssertCapability,
        ))
      desktopBrowserPasskeyAssertCapability,
    // 023 / US3: and whether it can create.
    if (descriptor != null &&
        descriptor.appCapabilities.contains(
          desktopBrowserPasskeyCreateCapability,
        ))
      desktopBrowserPasskeyCreateCapability,
  ];
}

Future<Map<String, Object?>> _statusResponse({
  required String? id,
  required String type,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  return _successResponse(id: id, type: type, data: await _statusData(store));
}

Future<Map<String, Object?>> _queryCredentialsResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  final pageTarget = _pageTargetFromPayload(payload);
  if (pageTarget == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'queryCredentials only accepts http(s) page origins.',
    );
  }

  final limit = payload['limit'];
  if (limit != null && (limit is! int || limit < 1 || limit > 10)) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'queryCredentials limit must be an integer between 1 and 10.',
    );
  }

  final pageOrigin = _browserOriginFromPayload(payload);
  final cache = await store.readMetadataCache();
  if (cache == null) {
    return _cacheUnavailableResponse(id: id, type: type);
  }
  final bridgeAvailable = await _isRevealBridgeAvailableForCache(store, cache);

  final strongMatches =
      cache.entries
          .where((entry) => _isStrongBrowserMatch(entry, pageTarget))
          .toList(growable: false)
        ..sort(_compareMetadataByDisplay);
  final strongIds = strongMatches.map((entry) => entry.id).toSet();
  final possibleMatches = strongMatches.isEmpty
      ? _possibleMatches(
          entries: cache.entries
              .where((entry) => !strongIds.contains(entry.id))
              .toList(growable: false),
          pageTarget: pageTarget,
          pageTitle: _safeOptionalString(payload['title'], maxLength: 512),
          limit: limit is int ? limit : 5,
        )
      : const <DesktopBrowserAutofillCredentialMetadata>[];

  return _successResponse(
    id: id,
    type: type,
    data: {
      'metadataOnly': true,
      'fillAvailable': bridgeAvailable,
      'databaseId': cache.databaseId,
      'generatedAtEpochMs': cache.generatedAtEpochMs,
      'target': pageTarget.toJson(),
      // 009 / A014. `strongMatches` is a *host* match, but the popup reveal
      // policy is an origin policy, so a strong match is not necessarily
      // revealable — an entry stored as `https://…` on an `http://` page, for
      // one. The popup used to offer Fill on every strong row and discover the
      // refusal only after the click. The eligibility is now computed with the
      // same predicate the reveal path will apply.
      //
      // The predicate here is deliberately the popup one
      // (`isRevealAuthorizedOrigin`), not the overlay one: this response feeds
      // the popup, whose policy is unchanged by this slice.
      'strongMatches': strongMatches
          .take(limit is int ? limit : 5)
          .map(
            (entry) => _metadataResult(
              entry,
              'strong',
              fillEligible:
                  bridgeAvailable &&
                  pageOrigin != null &&
                  DesktopBrowserAutofillMetadataMapper.isRevealAuthorizedOrigin(
                    serviceIdentifiers: entry.serviceIdentifiers,
                    origin: pageOrigin,
                  ),
            ),
          )
          .toList(growable: false),
      'possibleMatches': possibleMatches
          .map((entry) => _metadataResult(entry, 'possible'))
          .toList(growable: false),
      'message': bridgeAvailable
          ? 'Desktop browser v2 returned metadata. Exact strong matches can be filled after popup user action.'
          : 'Desktop browser v2 returned metadata only. Unlock Custode desktop to enable one-shot fill.',
    },
  );
}

Future<Map<String, Object?>> _searchCredentialsResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  final query = _safeOptionalString(payload['query'], maxLength: 256) ?? '';
  final limit = payload['limit'];
  if (limit != null && (limit is! int || limit < 1 || limit > 50)) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'searchCredentials limit must be an integer between 1 and 50.',
    );
  }
  final cache = await store.readMetadataCache();
  if (cache == null) {
    return _cacheUnavailableResponse(id: id, type: type);
  }

  final pageTarget = _pageTargetFromPayload(payload, isRequired: false);
  final results = _manualSearch(
    entries: cache.entries,
    query: query,
    limit: limit is int ? limit : 25,
  );

  return _successResponse(
    id: id,
    type: type,
    data: {
      'metadataOnly': true,
      'fillAvailable': false,
      'databaseId': cache.databaseId,
      'generatedAtEpochMs': cache.generatedAtEpochMs,
      if (pageTarget != null) 'target': pageTarget.toJson(),
      'results': results
          .map((entry) => _metadataResult(entry, 'manual'))
          .toList(growable: false),
      'message': 'Global search returned metadata only. Selecting a result creates a pending association for app confirmation.',
    },
  );
}

Future<Map<String, Object?>> _createPendingAssociationResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  final entryId = payload['entryId'];
  if (entryId is! String || entryId.trim().isEmpty || entryId.length > 256) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'createPendingAssociation requires a non-empty entryId string.',
    );
  }

  final target = _pageTargetFromPayload(payload);
  if (target == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'createPendingAssociation only accepts http(s) page origins for the target.',
    );
  }

  final pending = await store.savePendingAssociation(
    entryId: entryId,
    target: target,
  );
  if (pending == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'pending_association_failed',
      message: 'Unable to create pending association. Open and unlock Custode, then try again.',
    );
  }

  return _successResponse(
    id: id,
    type: type,
    data: {
      'pendingAssociation': pending.toJson(),
      'message': 'Pending association saved. Confirm or reject it in the Custode desktop app.',
    },
  );
}

Future<Map<String, Object?>> _revealForFillResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  final entryId = payload['entryId'];
  if (entryId is! String || entryId.trim().isEmpty || entryId.length > 256) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'revealForFill requires a non-empty entryId string.',
    );
  }

  final origin = _browserOriginFromPayload(payload);
  if (origin == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'revealForFill requires the current http(s) tab origin.',
    );
  }

  final target = DesktopBrowserAutofillMetadataMapper.targetFromUrl(origin);
  if (target == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'revealForFill origin is invalid.',
    );
  }

  final cache = await store.readMetadataCache();
  if (cache == null) {
    return _cacheUnavailableResponse(id: id, type: type);
  }

  final entry = cache.entries
      .where((candidate) => candidate.id == entryId.trim())
      .firstOrNull;
  if (entry == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'credential_unavailable',
      message: 'Requested credential metadata is unavailable.',
    );
  }

  if (!_isStrongBrowserMatch(entry, target, origin: origin)) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'strong_match_required',
      message: 'Credential reveal requires an exact strong match for the current site.',
    );
  }

  final descriptor = await store.readBridgeDescriptor();
  if (descriptor == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_unavailable',
      message: 'Custode reveal bridge is unavailable. Open and unlock the desktop app first.',
    );
  }
  if (descriptor.databaseId != cache.databaseId) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'database_mismatch',
      message: 'Custode database changed. Query the current site again.',
    );
  }

  final reveal = await _requestRevealFromAppBridge(
    descriptor: descriptor,
    databaseId: cache.databaseId,
    entryId: entryId.trim(),
    origin: origin,
  );
  if (reveal.errorCode != null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: reveal.errorCode!,
      message: _publicRevealErrorMessage(reveal.errorCode!),
    );
  }

  return _successResponse(
    id: id,
    type: type,
    data: {
      'entryId': reveal.entryId,
      'username': reveal.username,
      'password': reveal.password,
    },
  );
}

/// 023 / T501 — forward a WebAuthn assertion request to the app and hand the
/// signature back to the extension.
///
/// The host is a courier here and nothing more (FR-013a). It never sees a
/// private key, holds no passkey metadata of its own, and makes no policy
/// decision about which credential answers: the rp-id check, the credential
/// lookup and the user's confirmation all happen in the app, which is the
/// only process that has the key. What the host does own is the transport:
/// the origin must be a real http(s) page origin, the payload must be
/// bounded, and a refusal must come back as a refusal rather than a hang.
Future<Map<String, Object?>> _passkeyAssertResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  final origin = _browserOriginFromPayload(payload);
  final rpId = _safeOptionalString(payload['rpId'], maxLength: 253);
  final challenge = _safeOptionalString(payload['challenge'], maxLength: 2048);
  if (origin == null ||
      rpId == null ||
      rpId.trim().isEmpty ||
      challenge == null ||
      challenge.trim().isEmpty) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message:
          'passkeyAssert requires an http(s) origin, an rpId and a challenge.',
    );
  }

  final rawAllowCredentials = payload['allowCredentials'];
  if (rawAllowCredentials != null && rawAllowCredentials is! List) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'passkeyAssert allowCredentials must be a list of strings.',
    );
  }
  final allowCredentials = <String>[
    for (final item in (rawAllowCredentials as List? ?? const []).take(32))
      if (item is String && item.isNotEmpty && item.length <= 512) item,
  ];

  final descriptor = await store.readBridgeDescriptor();
  if (descriptor == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_unavailable',
      message: 'Custode is unavailable. Open and unlock the desktop app first.',
    );
  }
  if (!descriptor.appCapabilities.contains(
    desktopBrowserPasskeyAssertCapability,
  )) {
    // The app is running but cannot sign — no passkey in this vault, or a
    // build without the endpoint. Said plainly so the extension falls back
    // to the browser instead of retrying.
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'passkey_unavailable',
      message: 'This Custode database has no passkey for this site.',
    );
  }

  final call = await _postToAppBridge(
    descriptor: descriptor,
    path: '/passkey-assert',
    body: {
      'databaseId': descriptor.databaseId,
      'origin': origin,
      'rpId': rpId.trim(),
      'challenge': challenge.trim(),
      'allowCredentials': allowCredentials,
    },
    timeout: _passkeyAssertBridgeTimeout,
  );
  if (call.errorCode != null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: call.errorCode!,
      message: _publicRevealErrorMessage(call.errorCode!),
    );
  }

  final data = call.data;
  // A refusal: the app answers 200 with a reason so the page can fall
  // through to the browser's own authenticator. Passed on verbatim, and the
  // reasons are coarse on purpose — none of them says whether this vault
  // holds a passkey for the site.
  final reason = _safeOptionalString(data?['reason'], maxLength: 64);
  if (reason != null) {
    return _successResponse(id: id, type: type, data: {'reason': reason});
  }

  final credentialId = _safeOptionalString(
    data?['credentialId'],
    maxLength: 1024,
  );
  final authenticatorData = _safeOptionalString(
    data?['authenticatorData'],
    maxLength: 4096,
  );
  final signature = _safeOptionalString(data?['signature'], maxLength: 4096);
  final clientDataJson = _safeOptionalString(
    data?['clientDataJSON'],
    maxLength: 8192,
  );
  final rawUserHandle = data?['userHandle'];
  final userHandle = rawUserHandle == null
      ? null
      : _safeOptionalString(rawUserHandle, maxLength: 1024);
  if (credentialId == null ||
      authenticatorData == null ||
      signature == null ||
      clientDataJson == null ||
      (rawUserHandle != null && userHandle == null)) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_invalid_response',
      message: _publicRevealErrorMessage('app_bridge_invalid_response'),
    );
  }

  return _successResponse(
    id: id,
    type: type,
    data: {
      'credentialId': credentialId,
      'authenticatorData': authenticatorData,
      'signature': signature,
      'clientDataJSON': clientDataJson,
      'userHandle': userHandle,
    },
  );
}

/// 023 / US3 — forward a passkey registration to the app.
///
/// A courier again, with one difference that matters: the app writes the vault
/// before it answers, so a success here means the credential is durably
/// stored (FR-020). The host must not invent a success, retry on a timeout, or
/// treat a refusal as one — a site told "registered" for a credential the
/// vault does not hold will have deleted the user's password.
Future<Map<String, Object?>> _passkeyCreateResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  final origin = _browserOriginFromPayload(payload);
  final rpId = _safeOptionalString(payload['rpId'], maxLength: 253);
  final challenge = _safeOptionalString(payload['challenge'], maxLength: 2048);
  final username = _safeOptionalString(payload['username'], maxLength: 512);
  // WebAuthn caps `user.id` at 64 bytes, so 88 characters covers its
  // base64url form. Optional: a relying party may register without one, and
  // the app then falls back to a handle of its own.
  //
  // Not `_safeOptionalString`, which truncates: half a user handle is a
  // *different* handle, and forwarding one would store an identifier the
  // relying party never issued — the very failure this field exists to
  // prevent. An over-long value is dropped instead.
  final rawUserHandleRequest = payload['userHandle'];
  final userHandle =
      rawUserHandleRequest is String &&
          rawUserHandleRequest.trim().isNotEmpty &&
          rawUserHandleRequest.trim().length <= 88
      ? rawUserHandleRequest.trim()
      : null;
  if (origin == null ||
      rpId == null ||
      rpId.trim().isEmpty ||
      challenge == null ||
      challenge.trim().isEmpty) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message:
          'passkeyCreate requires an http(s) origin, an rpId and a challenge.',
    );
  }

  final descriptor = await store.readBridgeDescriptor();
  if (descriptor == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_unavailable',
      message: 'Custode is unavailable. Open and unlock the desktop app first.',
    );
  }
  if (!descriptor.appCapabilities.contains(
    desktopBrowserPasskeyCreateCapability,
  )) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'passkey_create_unavailable',
      message: _publicRevealErrorMessage('passkey_create_unavailable'),
    );
  }

  final call = await _postToAppBridge(
    descriptor: descriptor,
    path: '/passkey-create',
    body: {
      'databaseId': descriptor.databaseId,
      'origin': origin,
      'rpId': rpId.trim(),
      'challenge': challenge.trim(),
      'username': username ?? '',
      'userHandle': userHandle ?? '',
    },
    timeout: _passkeyAssertBridgeTimeout,
  );
  if (call.errorCode != null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: call.errorCode!,
      message: _publicRevealErrorMessage(call.errorCode!),
    );
  }

  final data = call.data;
  final reason = _safeOptionalString(data?['reason'], maxLength: 64);
  if (reason != null) {
    return _successResponse(id: id, type: type, data: {'reason': reason});
  }

  final credentialId = _safeOptionalString(
    data?['credentialId'],
    maxLength: 1024,
  );
  final attestationObject = _safeOptionalString(
    data?['attestationObject'],
    maxLength: 16384,
  );
  final clientDataJson = _safeOptionalString(
    data?['clientDataJSON'],
    maxLength: 8192,
  );
  final publicKeyCose = _safeOptionalString(
    data?['publicKeyCose'],
    maxLength: 4096,
  );
  if (credentialId == null ||
      attestationObject == null ||
      clientDataJson == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_invalid_response',
      message: _publicRevealErrorMessage('app_bridge_invalid_response'),
    );
  }

  return _successResponse(
    id: id,
    type: type,
    data: {
      'credentialId': credentialId,
      'attestationObject': attestationObject,
      'clientDataJSON': clientDataJson,
      'publicKeyCose': publicKeyCose,
    },
  );
}

/// 009 / A010 — bounded metadata for the in-page overlay.
///
/// Returns strictly less than `queryCredentials`: no username, no password, no
/// free-text ranking against the page title, and a hard cap of
/// [_maxOverlayItems]. Every item carries its classification and whether it may
/// actually be filled, so the extension never has to infer eligibility from the
/// shape of the response.
Future<Map<String, Object?>> _overlayQueryCredentialsResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  if (payload['matchPolicy'] != overlayMatchPolicy) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'Overlay requests must declare the exact-origin match policy.',
    );
  }
  final rawUrl = payload['url'];
  final target = rawUrl is String && rawUrl.length <= 4096
      ? browserExactOriginOrNull(rawUrl)
      : null;
  if (target == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'Overlay queries require an exact http(s) page origin.',
    );
  }
  final limit = payload['limit'];
  if (limit != null &&
      (limit is! int || limit < 1 || limit > _maxOverlayItems)) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'Overlay query limit must be an integer between 1 and 10.',
    );
  }
  final effectiveLimit = limit is int ? limit : _maxOverlayItems;

  final cache = await store.readMetadataCache();
  if (cache == null) {
    return _cacheUnavailableResponse(id: id, type: type);
  }
  final descriptor = await store.readBridgeDescriptor();
  final binding = _overlaySessionBinding(cache, descriptor);
  final fillAvailable = binding != null;

  final targetHost = DesktopBrowserAutofillMetadataMapper.normalizedHost(
    target,
  );
  final exact = <DesktopBrowserAutofillCredentialMetadata>[];
  final possible = <DesktopBrowserAutofillCredentialMetadata>[];
  for (final entry in cache.entries) {
    if (isExactOriginAuthorized(
      serviceIdentifiers: entry.serviceIdentifiers,
      origin: target,
    )) {
      exact.add(entry);
      continue;
    }
    if (targetHost != null && _isPossibleHostMatch(entry, targetHost)) {
      possible.add(entry);
    }
  }
  exact.sort(_compareMetadataByDisplay);
  possible.sort(_compareMetadataByDisplay);

  final items = <Map<String, Object?>>[
    for (final entry in exact)
      _overlayItem(
        entry,
        matchType: 'exact-origin',
        fillEligible: fillAvailable,
      ),
    for (final entry in possible)
      // SR-2: a host/domain-only entry may be shown so the user understands why
      // nothing is fillable, but it can never be filled.
      _overlayItem(entry, matchType: 'possible', fillEligible: false),
  ].take(effectiveLimit).toList(growable: false);

  // SR-4: the binding captured above must still be the current one at the
  // moment of answering, otherwise a republish that landed mid-query would be
  // answered with a tuple that is already dead.
  if (!await _overlayBindingIsStillCurrent(store, binding)) {
    return _staleSessionResponse(id: id, type: type);
  }

  return _successResponse(
    id: id,
    type: type,
    data: {
      'metadataOnly': true,
      'matchPolicy': overlayMatchPolicy,
      'target': target,
      'fillAvailable': fillAvailable,
      'databaseId': cache.databaseId,
      'sessionBinding': binding == null
          ? null
          : {
              'databaseId': binding.databaseId,
              'cacheGeneration': binding.cacheGeneration,
              'bridgeGeneration': binding.bridgeGeneration,
            },
      'items': items,
    },
  );
}

/// 009 / A011 — the origin-bound reveal.
///
/// Differs from [_revealForFillResponse] on purpose and the difference is the
/// whole point of the slice. That one applies the popup policy
/// ([DesktopBrowserAutofillMetadataMapper.isRevealAuthorizedOrigin]), which
/// admits a `domain` identifier on an https page and on hosts that cannot hold
/// a WebPKI certificate. This one admits nothing but an exact normalized origin
/// the user actually wrote, and additionally requires the full SR-4 binding to
/// still be current — checked before the app is contacted, and re-checked after
/// it answers.
Future<Map<String, Object?>> _overlayRevealForFillResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  final entryId = payload['entryId'];
  final rawOrigin = payload['origin'];
  final origin = rawOrigin is String && rawOrigin.length <= 4096
      ? browserExactOriginOrNull(rawOrigin)
      : null;
  final expectedDatabaseId = _safeOptionalString(
    payload['expectedDatabaseId'],
    maxLength: 128,
  );
  final expectedCacheGeneration = _safeOptionalString(
    payload['expectedCacheGeneration'],
    maxLength: 128,
  );
  final expectedBridgeGeneration = _safeOptionalString(
    payload['expectedBridgeGeneration'],
    maxLength: 128,
  );
  if (payload['matchPolicy'] != overlayMatchPolicy ||
      entryId is! String ||
      entryId.trim().isEmpty ||
      entryId.length > 256 ||
      origin == null ||
      expectedDatabaseId == null ||
      expectedCacheGeneration == null ||
      expectedBridgeGeneration == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'Overlay reveal request is invalid.',
    );
  }

  final cache = await store.readMetadataCache();
  if (cache == null) {
    return _cacheUnavailableResponse(id: id, type: type);
  }
  final descriptor = await store.readBridgeDescriptor();
  if (descriptor == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_unavailable',
      message: 'Custode reveal bridge is unavailable. Open and unlock the desktop app first.',
    );
  }

  final binding = _overlaySessionBinding(cache, descriptor);
  if (binding == null ||
      binding.databaseId != expectedDatabaseId ||
      binding.cacheGeneration != expectedCacheGeneration ||
      binding.bridgeGeneration != expectedBridgeGeneration) {
    // Every binding mismatch answers identically and before the app is ever
    // contacted, so a stale grant cannot even reach the credential store.
    return _staleSessionResponse(id: id, type: type);
  }

  final entry = cache.entries
      .where((candidate) => candidate.id == entryId.trim())
      .firstOrNull;
  if (entry == null ||
      !isExactOriginAuthorized(
        serviceIdentifiers: entry.serviceIdentifiers,
        origin: origin,
      )) {
    // Uniform refusal: it must not disclose whether the entry exists in this
    // vault, nor which component of the origin failed to match.
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'forbidden',
      message: 'Overlay fill is not authorized for this site.',
    );
  }

  final call = await _postToAppBridge(
    descriptor: descriptor,
    path: '/overlay-reveal',
    body: {
      'version': desktopBrowserAutofillBridgeDescriptorVersion,
      'matchPolicy': overlayMatchPolicy,
      'entryId': entryId.trim(),
      'origin': origin,
      'databaseId': binding.databaseId,
      'cacheGeneration': binding.cacheGeneration,
      'bridgeGeneration': binding.bridgeGeneration,
    },
  );
  if (call.errorCode != null) {
    // An app that predates this slice has no `/overlay-reveal` and answers
    // `not_found`; that surfaces as a plain refusal, never as a retry on the
    // lenient `/reveal` endpoint.
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: call.errorCode!,
      message: _publicRevealErrorMessage(call.errorCode!),
    );
  }

  final data = call.data;
  final username = data?['username'];
  final password = data?['password'];
  if (data?['entryId'] != entryId.trim() ||
      data?['matchPolicy'] != overlayMatchPolicy ||
      data?['origin'] != origin ||
      data?['databaseId'] != binding.databaseId ||
      data?['cacheGeneration'] != binding.cacheGeneration ||
      data?['bridgeGeneration'] != binding.bridgeGeneration ||
      username is! String ||
      password is! String ||
      utf8.encode(username).length > _maxRevealUsernameBytes ||
      utf8.encode(password).length > _maxRevealPasswordBytes) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_invalid_response',
      message: _publicRevealErrorMessage('app_bridge_invalid_response'),
    );
  }

  // SR-4: re-read cache and descriptor *after* the app answered. A vault switch
  // that landed while the request was in flight makes this response stale even
  // though every earlier check passed, and the secret is dropped here.
  if (!await _overlayBindingIsStillCurrent(store, binding)) {
    return _staleSessionResponse(id: id, type: type);
  }

  return _successResponse(
    id: id,
    type: type,
    data: {
      'entryId': entryId.trim(),
      'matchPolicy': overlayMatchPolicy,
      'origin': origin,
      'sessionBinding': {
        'databaseId': binding.databaseId,
        'cacheGeneration': binding.cacheGeneration,
        'bridgeGeneration': binding.bridgeGeneration,
      },
      'username': username,
      'password': password,
    },
  );
}

/// 009 / B007 — app-owned password generation over the native protocol.
///
/// The host is a pure conduit: it validates, forwards to `/generate-pending`,
/// validates the echo, and answers once. It persists nothing — no file, no
/// cache, no log line — and the secret exists only inside this one response.
/// Settings never travel this path in either direction: a request that
/// carries a `settings` field is `invalid_request`, not silently ignored.
Future<Map<String, Object?>> _generatePendingEntryResponse({
  required String? id,
  required String type,
  required Map<String, Object?> payload,
  required DesktopBrowserAutofillCacheStore store,
}) async {
  if (payload.containsKey('settings')) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'Generation settings are app-owned and cannot be supplied.',
    );
  }
  final rawOrigin = payload['origin'];
  final origin = rawOrigin is String && rawOrigin.length <= 4096
      ? browserExactOriginOrNull(rawOrigin)
      : null;
  final expectedDatabaseId = _safeOptionalString(
    payload['expectedDatabaseId'],
    maxLength: 128,
  );
  final expectedCacheGeneration = _safeOptionalString(
    payload['expectedCacheGeneration'],
    maxLength: 128,
  );
  final expectedBridgeGeneration = _safeOptionalString(
    payload['expectedBridgeGeneration'],
    maxLength: 128,
  );
  if (origin == null ||
      expectedDatabaseId == null ||
      expectedCacheGeneration == null ||
      expectedBridgeGeneration == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'invalid_request',
      message: 'Generate request is invalid.',
    );
  }

  final cache = await store.readMetadataCache();
  if (cache == null) {
    return _cacheUnavailableResponse(id: id, type: type);
  }
  final descriptor = await store.readBridgeDescriptor();
  if (descriptor == null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_unavailable',
      message: 'Custode reveal bridge is unavailable. Open and unlock the desktop app first.',
    );
  }
  // B007 negotiation: an app that does not declare the endpoint gets a hard
  // `unsupported_capability` — never a fallback to host-side generation or
  // default settings.
  if (!descriptor.appCapabilities.contains(
    desktopBrowserGeneratePendingCapability,
  )) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'unsupported_capability',
      message: 'Custode desktop does not support password generation yet.',
    );
  }

  final binding = _overlaySessionBinding(cache, descriptor);
  if (binding == null ||
      binding.databaseId != expectedDatabaseId ||
      binding.cacheGeneration != expectedCacheGeneration ||
      binding.bridgeGeneration != expectedBridgeGeneration) {
    return _staleSessionResponse(id: id, type: type);
  }

  final call = await _postToAppBridge(
    descriptor: descriptor,
    path: '/generate-pending',
    body: {
      'version': desktopBrowserAutofillBridgeDescriptorVersion,
      'origin': origin,
      'databaseId': binding.databaseId,
      'cacheGeneration': binding.cacheGeneration,
      'bridgeGeneration': binding.bridgeGeneration,
    },
  );
  if (call.errorCode != null) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: call.errorCode!,
      message: _publicRevealErrorMessage(call.errorCode!),
    );
  }

  final data = call.data;
  final pendingGenerationId = data?['pendingGenerationId'];
  final expiresAtEpochMs = data?['expiresAtEpochMs'];
  final settingsRevision = data?['settingsRevision'];
  final password = data?['password'];
  // Expiry metadata contract: an int, in the future-ish, and no further out
  // than the five-minute ceiling the pending model guarantees (small slack
  // for clock skew between validation and creation).
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final expiryValid =
      expiresAtEpochMs is int &&
      expiresAtEpochMs > nowMs - 60000 &&
      expiresAtEpochMs <= nowMs + 5 * 60 * 1000 + 10000;
  if (pendingGenerationId is! String ||
      pendingGenerationId.isEmpty ||
      pendingGenerationId.length > 256 ||
      !expiryValid ||
      settingsRevision is! int ||
      settingsRevision < 1 ||
      data?['databaseId'] != binding.databaseId ||
      data?['cacheGeneration'] != binding.cacheGeneration ||
      data?['bridgeGeneration'] != binding.bridgeGeneration ||
      password is! String ||
      password.isEmpty ||
      utf8.encode(password).length > _maxRevealPasswordBytes) {
    return nativeHostErrorResponse(
      id: id,
      type: type,
      code: 'app_bridge_invalid_response',
      message: _publicRevealErrorMessage('app_bridge_invalid_response'),
    );
  }

  // SR-4: re-read cache and descriptor after the app answered; a vault switch
  // in flight drops the secret here.
  if (!await _overlayBindingIsStillCurrent(store, binding)) {
    return _staleSessionResponse(id: id, type: type);
  }

  return _successResponse(
    id: id,
    type: type,
    data: {
      'pendingGenerationId': pendingGenerationId,
      'expiresAtEpochMs': expiresAtEpochMs,
      'origin': origin,
      'sessionBinding': {
        'databaseId': binding.databaseId,
        'cacheGeneration': binding.cacheGeneration,
        'bridgeGeneration': binding.bridgeGeneration,
      },
      'settingsRevision': settingsRevision,
      'password': password,
    },
  );
}

Map<String, Object?> _overlayItem(
  DesktopBrowserAutofillCredentialMetadata entry, {
  required String matchType,
  required bool fillEligible,
}) {
  return {
    'entryId': entry.id,
    'title': entry.title,
    'displayService': entry.displayService,
    'matchType': matchType,
    'fillEligible': fillEligible,
  };
}

/// Host-level match, used only to classify an entry as *possible* metadata.
///
/// This is the lenient rule on purpose — it is the same `_cleanHost`-based
/// comparison the popup uses for ranking — and it is confined to display. It
/// never sets `fillEligible`.
bool _isPossibleHostMatch(
  DesktopBrowserAutofillCredentialMetadata entry,
  String targetHost,
) {
  for (final identifier in entry.serviceIdentifiers) {
    if (identifier.type != 'domain' && identifier.type != 'url') {
      continue;
    }
    final host = DesktopBrowserAutofillMetadataMapper.normalizedHost(
      identifier.value,
    );
    if (host != null && host == targetHost) {
      return true;
    }
  }
  return false;
}

class _OverlaySessionBinding {
  const _OverlaySessionBinding({
    required this.databaseId,
    required this.cacheGeneration,
    required this.bridgeGeneration,
  });

  final String databaseId;
  final String cacheGeneration;
  final String bridgeGeneration;

  bool matches(_OverlaySessionBinding? other) {
    return other != null &&
        other.databaseId == databaseId &&
        other.cacheGeneration == cacheGeneration &&
        other.bridgeGeneration == bridgeGeneration;
  }
}

/// The SR-4 tuple, or `null` when cache and descriptor do not describe one and
/// the same live session.
_OverlaySessionBinding? _overlaySessionBinding(
  DesktopBrowserAutofillMetadataCache cache,
  DesktopBrowserAutofillBridgeDescriptor? descriptor,
) {
  if (descriptor == null ||
      cache.databaseId.isEmpty ||
      cache.cacheGeneration.isEmpty ||
      descriptor.databaseId != cache.databaseId ||
      descriptor.cacheGeneration != cache.cacheGeneration ||
      descriptor.bridgeGeneration.isEmpty) {
    return null;
  }
  return _OverlaySessionBinding(
    databaseId: cache.databaseId,
    cacheGeneration: cache.cacheGeneration,
    bridgeGeneration: descriptor.bridgeGeneration,
  );
}

Future<bool> _overlayBindingIsStillCurrent(
  DesktopBrowserAutofillCacheStore store,
  _OverlaySessionBinding? expected,
) async {
  final cache = await store.readMetadataCache();
  if (cache == null) {
    // A cache that vanished mid-request means the vault locked or switched.
    // Only the "no fillable item" case may legitimately carry a null binding,
    // and that case still requires a readable cache.
    return false;
  }
  final current = _overlaySessionBinding(
    cache,
    await store.readBridgeDescriptor(),
  );
  if (expected == null) {
    return current == null;
  }
  return expected.matches(current);
}

Map<String, Object?> _staleSessionResponse({
  required String? id,
  required String type,
}) {
  return nativeHostErrorResponse(
    id: id,
    type: type,
    code: 'stale_session',
    message: 'Custode session changed. Query the current site again.',
  );
}

Map<String, Object?> _successResponse({
  required String? id,
  required String type,
  required Map<String, Object?> data,
}) {
  final response = <String, Object?>{
    'version': nativeProtocolVersion,
    'type': type,
    'ok': true,
    'data': data,
  };
  if (id != null) {
    response['id'] = id;
  }
  return response;
}

Future<Map<String, Object?>> _statusData(
  DesktopBrowserAutofillCacheStore store,
) async {
  final status = await store.status();
  final bridgeStatus = status.revealBridgeAvailable
      ? 'available'
      : status.cacheAvailable
      ? 'metadata_cache_available'
      : 'unavailable';
  return {
    'host': {
      'name': nativeHostName,
      'protocolVersion': nativeProtocolVersion,
      'status': 'available',
    },
    'appBridge': {
      'connected': status.revealBridgeAvailable,
      'status': bridgeStatus,
      'reason': status.revealBridgeAvailable
          ? null
          : status.cacheAvailable
          ? 'reveal_bridge_unavailable'
          : 'app_bridge_unavailable',
      'revealBridgeAvailable': status.revealBridgeAvailable,
      'createdAtEpochMs': status.revealBridgeCreatedAtEpochMs,
    },
    'vault': {
      'connected': status.cacheAvailable,
      'unlocked': status.cacheAvailable,
      'status': status.cacheAvailable
          ? 'metadata_cache_available'
          : 'not_connected',
      'metadataCount': status.metadataCount,
      'databaseId': status.databaseId,
      'generatedAtEpochMs': status.generatedAtEpochMs,
    },
    'safeMode': false,
    'metadataOnly': !status.revealBridgeAvailable,
    'cacheDirectory': status.directoryPath,
    'message': status.revealBridgeAvailable
        ? 'Native Messaging v2 can fill exact strong matches after popup user action.'
        : status.cacheAvailable
        ? 'Native Messaging v2 can read metadata, but reveal bridge is unavailable. Unlock Custode desktop.'
        : 'Native Messaging v2 is running; open and unlock Custode to publish desktop browser metadata.',
  };
}

Map<String, Object?> _cacheUnavailableResponse({
  required String? id,
  required String type,
}) {
  return nativeHostErrorResponse(
    id: id,
    type: type,
    code: 'app_bridge_unavailable',
    message: 'Custode desktop metadata cache is unavailable. Open and unlock the desktop app first.',
  );
}

Future<bool> _isRevealBridgeAvailableForCache(
  DesktopBrowserAutofillCacheStore store,
  DesktopBrowserAutofillMetadataCache cache,
) async {
  final descriptor = await store.readBridgeDescriptor();
  return descriptor != null && descriptor.databaseId == cache.databaseId;
}

String? _browserOriginFromPayload(Map<String, Object?> payload) {
  final rawOrigin = payload['origin'] ?? payload['url'];
  if (rawOrigin is! String ||
      rawOrigin.trim().isEmpty ||
      rawOrigin.length > 4096) {
    return null;
  }
  final uri = Uri.tryParse(rawOrigin.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  // Keep the host as the browser served it: the reveal policy re-normalizes it
  // for matching, but it also has to ask whether *this* name can obtain a
  // WebPKI certificate, and collapsing `m.`/`www.`/`mobile.` here would hand it
  // a single-label name (`m.me` -> `me`) that would pass as non-public.
  final host = DesktopBrowserAutofillMetadataMapper.normalizedHost(
    uri.host,
    stripPrefixes: false,
  );
  if (host == null) {
    return null;
  }
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    host: host,
    port: uri.hasPort ? uri.port : null,
  ).toString();
}

Future<_RevealBridgeResult> _requestRevealFromAppBridge({
  required DesktopBrowserAutofillBridgeDescriptor descriptor,
  required String databaseId,
  required String entryId,
  required String origin,
}) async {
  final call = await _postToAppBridge(
    descriptor: descriptor,
    path: '/reveal',
    body: {
      'version': desktopBrowserAutofillBridgeDescriptorVersion,
      'databaseId': databaseId,
      'entryId': entryId,
      'origin': origin,
    },
  );
  if (call.errorCode != null) {
    return _RevealBridgeResult.error(call.errorCode!);
  }

  final data = call.data;
  final returnedEntryId = data?['entryId'];
  final username = data?['username'];
  final password = data?['password'];
  if (returnedEntryId != entryId ||
      username is! String ||
      password is! String ||
      utf8.encode(username).length > _maxRevealUsernameBytes ||
      utf8.encode(password).length > _maxRevealPasswordBytes) {
    return const _RevealBridgeResult.error('app_bridge_invalid_response');
  }

  return _RevealBridgeResult.success(
    entryId: returnedEntryId as String,
    username: username,
    password: password,
  );
}

/// Direct loopback POST to the app bridge with bearer auth and the 2-second
/// timeout budget. Shared by the popup and overlay reveal paths; the two differ
/// in what they send and in how strictly they validate what comes back, never
/// in transport.
Future<({Map<String, Object?>? data, String? errorCode})> _postToAppBridge({
  required DesktopBrowserAutofillBridgeDescriptor descriptor,
  required String path,
  required Map<String, Object?> body,
  Duration timeout = _revealBridgeTimeout,
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = (_) => 'DIRECT';
  try {
    final uri = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: descriptor.port,
      path: path,
    );
    final request = await client.postUrl(uri).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${descriptor.token}',
    );
    request.write(jsonEncode(body));

    final response = await request.close().timeout(timeout);
    final bytes = await _readHttpResponseBytes(
      response,
      maxNativeMessagePayloadBytes,
    ).timeout(timeout);
    final decoded = _decodeBridgeResponse(bytes);
    if (decoded == null) {
      return (data: null, errorCode: 'app_bridge_invalid_response');
    }
    if (response.statusCode != HttpStatus.ok) {
      return (
        data: null,
        errorCode: _safeBridgeErrorCode(decoded) ?? 'app_bridge_error',
      );
    }
    return (data: _asStringObjectMap(decoded['data']), errorCode: null);
  } on TimeoutException {
    return (data: null, errorCode: 'app_bridge_timeout');
  } on SocketException {
    return (data: null, errorCode: 'app_bridge_unavailable');
  } on HttpException {
    return (data: null, errorCode: 'app_bridge_error');
  } catch (_) {
    return (data: null, errorCode: 'app_bridge_error');
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _readHttpResponseBytes(
  HttpClientResponse response,
  int maxBytes,
) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
    if (builder.length > maxBytes) {
      throw const HttpException('response_too_large');
    }
  }
  return builder.takeBytes();
}

Map<String, Object?>? _decodeBridgeResponse(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxNativeMessagePayloadBytes) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    return null;
  }
  return _asStringObjectMap(decoded);
}

String? _safeBridgeErrorCode(Map<String, Object?> response) {
  final error = _asStringObjectMap(response['error']);
  final code = error?['code'];
  if (code is! String || code.isEmpty || code.length > 64) {
    return null;
  }
  return RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(code) ? code : null;
}

DesktopBrowserAutofillAssociationTarget? _pageTargetFromPayload(
  Map<String, Object?> payload, {
  bool isRequired = true,
}) {
  final rawUrl = payload['url'];
  if (rawUrl == null && !isRequired) {
    return null;
  }
  if (rawUrl is! String || rawUrl.trim().isEmpty || rawUrl.length > 4096) {
    return null;
  }
  final uri = Uri.tryParse(rawUrl);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return DesktopBrowserAutofillMetadataMapper.targetFromUrl(rawUrl);
}

bool _isStrongBrowserMatch(
  DesktopBrowserAutofillCredentialMetadata entry,
  DesktopBrowserAutofillAssociationTarget target, {
  String? origin,
}) {
  if (origin != null) {
    // Reveal path: the page origin must be authorized as a whole (scheme, host
    // and port), never by host alone.
    return DesktopBrowserAutofillMetadataMapper.isRevealAuthorizedOrigin(
      serviceIdentifiers: entry.serviceIdentifiers,
      origin: origin,
    );
  }
  // Metadata-only path (queryCredentials): no secret leaves the host, and the
  // caller only supplies a host target, so a host match stays sufficient.
  for (final identifier in entry.serviceIdentifiers) {
    if (identifier.type == 'domain' || identifier.type == 'url') {
      final host = DesktopBrowserAutofillMetadataMapper.normalizedHost(
        identifier.value,
      );
      if (host != null && host == target.value) {
        return true;
      }
    }
  }
  return false;
}

List<DesktopBrowserAutofillCredentialMetadata> _possibleMatches({
  required List<DesktopBrowserAutofillCredentialMetadata> entries,
  required DesktopBrowserAutofillAssociationTarget pageTarget,
  required String? pageTitle,
  required int limit,
}) {
  final rawTargets = <String>[pageTarget.value];
  if (pageTitle != null) {
    rawTargets.add(pageTitle);
  }
  final tokens = _targetTokens(rawTargets);
  if (tokens.isEmpty || limit <= 0) {
    return const [];
  }
  return _rankedSearch(
    entries: entries,
    tokens: tokens,
    includeUsername: false,
    requireAllTokens: false,
    limit: limit,
  );
}

List<DesktopBrowserAutofillCredentialMetadata> _manualSearch({
  required List<DesktopBrowserAutofillCredentialMetadata> entries,
  required String query,
  required int limit,
}) {
  if (limit <= 0) {
    return const [];
  }
  final tokens = _manualSearchTokens(query);
  if (tokens.isEmpty) {
    return (List<DesktopBrowserAutofillCredentialMetadata>.of(
      entries,
    )..sort(_compareMetadataByDisplay)).take(limit).toList(growable: false);
  }
  return _rankedSearch(
    entries: entries,
    tokens: tokens,
    includeUsername: true,
    requireAllTokens: true,
    limit: limit,
  );
}

List<DesktopBrowserAutofillCredentialMetadata> _rankedSearch({
  required List<DesktopBrowserAutofillCredentialMetadata> entries,
  required List<String> tokens,
  required bool includeUsername,
  required bool requireAllTokens,
  required int limit,
}) {
  final scored = <_ScoredMetadata>[];
  for (final entry in entries) {
    final score = _scoreMetadataEntry(
      entry: entry,
      tokens: tokens,
      includeUsername: includeUsername,
      requireAllTokens: requireAllTokens,
    );
    if (score > 0) {
      scored.add(_ScoredMetadata(entry: entry, score: score));
    }
  }
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) {
      return byScore;
    }
    return _compareMetadataByDisplay(a.entry, b.entry);
  });
  return scored.take(limit).map((match) => match.entry).toList(growable: false);
}

int _scoreMetadataEntry({
  required DesktopBrowserAutofillCredentialMetadata entry,
  required List<String> tokens,
  required bool includeUsername,
  required bool requireAllTokens,
}) {
  final fields = <_WeightedSearchField>[
    _WeightedSearchField(entry.title, 6),
    _WeightedSearchField(entry.displayService, 8),
    if (includeUsername) _WeightedSearchField(entry.username, 5),
  ];
  for (final identifier in entry.serviceIdentifiers) {
    fields.add(_WeightedSearchField(identifier.value, 9));
    if (identifier.type == 'domain' || identifier.type == 'url') {
      final host = DesktopBrowserAutofillMetadataMapper.normalizedHost(
        identifier.value,
      );
      if (host != null) {
        fields.add(_WeightedSearchField(host, 10));
      }
    }
  }

  var total = 0;
  var matchedTokens = 0;
  for (final token in tokens) {
    int? bestScore;
    for (final field in fields) {
      final value = _normalizedSearchValue(field.value);
      if (!value.contains(token)) {
        continue;
      }
      var score = field.weight;
      if (value == token) {
        score += 12;
      } else if (value.startsWith(token)) {
        score += 6;
      } else if (_containsComponentPrefix(token, value)) {
        score += 4;
      }
      bestScore = bestScore == null ? score : math.max(bestScore, score);
    }
    if (bestScore != null) {
      total += bestScore;
      matchedTokens += 1;
    } else if (requireAllTokens) {
      return 0;
    }
  }
  return matchedTokens > 0 ? total + (matchedTokens * 2) : 0;
}

Map<String, Object?> _metadataResult(
  DesktopBrowserAutofillCredentialMetadata entry,
  String matchType, {
  bool fillEligible = false,
}) {
  return {
    'entryId': entry.id,
    'title': entry.title,
    'displayService': entry.displayService,
    'matchType': matchType,
    'fillEligible': fillEligible,
  };
}

List<String> _targetTokens(Iterable<String> rawValues) {
  final tokens = <String>[];
  final seen = <String>{};
  for (final rawValue in rawValues) {
    for (final token in _tokensFromRawValue(rawValue)) {
      if (seen.add(token)) {
        tokens.add(token);
      }
    }
  }
  return tokens;
}

List<String> _manualSearchTokens(String query) {
  final normalized = _normalizedSearchValue(query);
  if (normalized.isEmpty) {
    return const [];
  }
  return normalized
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

List<String> _tokensFromRawValue(String rawValue) {
  final normalized = _normalizedSearchValue(rawValue);
  if (normalized.isEmpty) {
    return const [];
  }
  return normalized
      .split(RegExp(r'[.\-_/:\\\s]+'))
      .map((token) => token.replaceAll(RegExp(r'^[^a-z0-9]+|[^a-z0-9]+$'), ''))
      .where((token) => token.length >= 3)
      .where((token) => !_genericTargetTokens.contains(token))
      .toList(growable: false);
}

String _normalizedSearchValue(String value) {
  return value.trim().toLowerCase();
}

bool _containsComponentPrefix(String token, String value) {
  return value
      .split(RegExp(r'[.\-_/:\\\s]+'))
      .any((component) => component.startsWith(token));
}

String? _safeOptionalString(Object? value, {required int maxLength}) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  return trimmed.length <= maxLength
      ? trimmed
      : trimmed.substring(0, maxLength);
}

int _compareMetadataByDisplay(
  DesktopBrowserAutofillCredentialMetadata left,
  DesktopBrowserAutofillCredentialMetadata right,
) {
  return left.sortKey.compareTo(right.sortKey);
}

Map<String, Object?>? _readPayload(Map<String, Object?> request) {
  if (!request.containsKey('payload') || request['payload'] == null) {
    return const <String, Object?>{};
  }
  return _asStringObjectMap(request['payload']);
}

Map<String, Object?>? _asStringObjectMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      return null;
    }
    result[key] = entry.value as Object?;
  }
  return result;
}

String? _safeRequestId(Object? value) {
  if (value is! String || value.isEmpty || value.length > 128) {
    return null;
  }
  final isSafe = RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);
  return isSafe ? value : null;
}

String? _safeRequestType(Object? value) {
  if (value is! String || value.isEmpty || value.length > 64) {
    return null;
  }
  final isSafe = RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(value);
  return isSafe ? value : null;
}

String _publicRevealErrorMessage(String code) {
  return switch (code) {
    'app_bridge_timeout' => 'Custode reveal bridge timed out.',
    'app_bridge_unavailable' =>
      'Custode reveal bridge is unavailable. Open and unlock the desktop app.',
    'app_bridge_invalid_response' =>
      'Custode reveal bridge returned an invalid response.',
    'database_mismatch' => 'Custode database changed. Query the site again.',
    'stale_session' => 'Custode session changed. Query the site again.',
    'forbidden' => 'Overlay fill is not authorized for this site.',
    'not_found' => 'Custode reveal bridge does not support this request.',
    'credential_unavailable' => 'Requested credential is unavailable.',
    'strong_match_required' =>
      'Credential reveal requires an exact strong match for the current site.',
    'invalid_request' => 'Reveal request is invalid.',
    'unauthorized' => 'Custode reveal bridge authentication failed.',
    'rate_limited' => 'Too many generation requests. Try again shortly.',
    'unsupported_capability' =>
      'Custode desktop does not support password generation yet.',
    'passkey_unavailable' =>
      'This Custode database has no passkey for this site.',
    'passkey_create_unavailable' => 'This Custode build cannot create passkeys. Open and unlock the desktop app.',
    _ => 'Custode reveal bridge failed.',
  };
}

bool _containsSensitiveRequestKey(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String && _sensitiveRequestKeys.contains(key.toLowerCase())) {
        return true;
      }
      if (_containsSensitiveRequestKey(entry.value)) {
        return true;
      }
    }
  } else if (value is Iterable) {
    for (final item in value) {
      if (_containsSensitiveRequestKey(item)) {
        return true;
      }
    }
  }
  return false;
}

const _genericTargetTokens = <String>{
  'www',
  'com',
  'net',
  'org',
  'login',
  'signin',
  'sign',
  'auth',
  'account',
  'accounts',
  'http',
  'https',
  'mobile',
  'app',
};

class _WeightedSearchField {
  const _WeightedSearchField(this.value, this.weight);

  final String value;
  final int weight;
}

class _ScoredMetadata {
  const _ScoredMetadata({required this.entry, required this.score});

  final DesktopBrowserAutofillCredentialMetadata entry;
  final int score;
}

class _RevealBridgeResult {
  const _RevealBridgeResult.success({
    required this.entryId,
    required this.username,
    required this.password,
  }) : errorCode = null;

  const _RevealBridgeResult.error(this.errorCode)
    : entryId = null,
      username = null,
      password = null;

  final String? entryId;
  final String? username;
  final String? password;
  final String? errorCode;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}
