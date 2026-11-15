import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../domain/models/vault_entry.dart';
import '../../domain/services/host_identity.dart' as domain_host;
import '../../domain/services/url_field_keys.dart';
import 'browser_exact_origin.dart';

/// Bumped 2 -> 3 with the reveal-authorization fix.
///
/// The bump is not what closes the vulnerability: the authorization predicate
/// is new code applied at match time, and the `url` identifiers a version 2
/// cache carries are a restriction, never a permission. What the bump buys is
/// convergence: a version 2 cache still pins a synthetic `https://` origin on
/// every entry whose URL was stored as a bare host, which would keep those
/// entries unusable on their own `http` origin until the cache happened to be
/// rewritten. Rejecting the old version forces the regeneration deterministically.
///
/// Accepted cost: browser autofill is unavailable until the next vault unlock,
/// which is an event the user causes anyway.
///
/// Bumped 3 -> 4 when the `domain` identifier started carrying `:port`. This
/// bump *is* load-bearing: a version 3 cache holds a bare `domain=host` for an
/// entry stored as `host:8443`, so the port the user wrote is simply not in the
/// data and cannot constrain the match. Any port of that host would stay
/// authorized until the cache happened to be rewritten — which is exactly the
/// LAN / shared-host case the scheme de-pin exists to serve.
///
/// Bumped 4 -> 5 for spec 009 Slice A1. Two reasons, both load-bearing:
/// a version 4 cache carries no `cacheGeneration`, so the overlay session
/// binding of SR-4 simply does not exist in the data and could only be faked;
/// and it carries no `exactOrigin` identifier, so every entry would look
/// domain-only to the overlay policy. Rejecting the old version regenerates
/// both deterministically at the next unlock.
const desktopBrowserAutofillCacheVersion = 5;

/// Bumped 1 -> 2 for spec 009 Slice A1: the descriptor now carries the
/// `bridgeGeneration` minted per bridge start and the `cacheGeneration` of the
/// metadata cache it was started for. A version 1 descriptor cannot satisfy the
/// SR-4 binding, so it is rejected rather than treated as unbound.
const desktopBrowserAutofillBridgeDescriptorVersion = 2;

/// 009 / B007 — app-side capability carried by the bridge descriptor.
///
/// Written by the app only when its bridge actually serves
/// `/generate-pending`. The native host advertises `generatePendingEntryV1`
/// in `hello` if and only if the current descriptor lists it, so an old app
/// (descriptor without the field) makes the capability disappear and every
/// `generatePendingEntry` request fail closed with `unsupported_capability` —
/// never a fallback to extension/native-side generation.
const desktopBrowserGeneratePendingCapability = 'generatePendingEntryV1';

/// spec 023 T502 — advertised only when the running app serves
/// `/passkey-assert`. An app predating this slice advertises nothing, so the
/// extension leaves `navigator.credentials.get` alone instead of wrapping a
/// call it cannot answer.
const desktopBrowserPasskeyAssertCapability = 'passkeyAssertV1';

/// spec 023 US3 — advertised only when the running app can both ask the user
/// where a new passkey should go and write it to the vault.
const desktopBrowserPasskeyCreateCapability = 'passkeyCreateV1';
const desktopBrowserAutofillPlatform = 'desktop/browser';
const desktopBrowserAutofillMaxPendingAssociations = 100;

class DesktopBrowserAutofillStoreStatus {
  const DesktopBrowserAutofillStoreStatus({
    required this.directoryPath,
    required this.metadataCount,
    required this.cacheAvailable,
    required this.revealBridgeAvailable,
    this.databaseId,
    this.generatedAtEpochMs,
    this.revealBridgeCreatedAtEpochMs,
  });

  final String? directoryPath;
  final int metadataCount;
  final bool cacheAvailable;
  final bool revealBridgeAvailable;
  final String? databaseId;
  final int? generatedAtEpochMs;
  final int? revealBridgeCreatedAtEpochMs;
}

class DesktopBrowserAutofillServiceIdentifier {
  const DesktopBrowserAutofillServiceIdentifier({
    required this.type,
    required this.value,
  });

  factory DesktopBrowserAutofillServiceIdentifier.fromJson(
    Map<String, Object?> json,
  ) {
    return DesktopBrowserAutofillServiceIdentifier(
      type: _readString(json, 'type'),
      value: _readString(json, 'value'),
    );
  }

  final String type;
  final String value;

  Map<String, Object?> toJson() => {'type': type, 'value': value};

  @override
  bool operator ==(Object other) {
    return other is DesktopBrowserAutofillServiceIdentifier &&
        other.type == type &&
        other.value == value;
  }

  @override
  int get hashCode => Object.hash(type, value);
}

class DesktopBrowserAutofillCredentialMetadata {
  const DesktopBrowserAutofillCredentialMetadata({
    required this.id,
    required this.title,
    required this.username,
    required this.displayService,
    required this.serviceIdentifiers,
    required this.updatedAtEpochMs,
  });

  factory DesktopBrowserAutofillCredentialMetadata.fromJson(
    Map<String, Object?> json,
  ) {
    return DesktopBrowserAutofillCredentialMetadata(
      id: _readString(json, 'id'),
      title: _readString(json, 'title'),
      username: _readString(json, 'username'),
      displayService: _readString(json, 'displayService'),
      serviceIdentifiers: _readList(json, 'serviceIdentifiers')
          .whereType<Map>()
          .map(_stringObjectMap)
          .whereType<Map<String, Object?>>()
          .map(DesktopBrowserAutofillServiceIdentifier.fromJson)
          .where((identifier) => identifier.type.isNotEmpty)
          .where((identifier) => identifier.value.isNotEmpty)
          .toList(growable: false),
      updatedAtEpochMs: _readInt(json, 'updatedAtEpochMs'),
    );
  }

  final String id;
  final String title;
  final String username;
  final String displayService;
  final List<DesktopBrowserAutofillServiceIdentifier> serviceIdentifiers;
  final int updatedAtEpochMs;

  String get sortKey => [
    displayService,
    title,
    username,
    id,
  ].map((value) => value.toLowerCase()).join('|');

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'username': username,
    'displayService': displayService,
    'updatedAtEpochMs': updatedAtEpochMs,
    'serviceIdentifiers': serviceIdentifiers
        .map((identifier) => identifier.toJson())
        .toList(growable: false),
  };
}

class DesktopBrowserAutofillMetadataCache {
  const DesktopBrowserAutofillMetadataCache({
    required this.version,
    required this.databaseId,
    required this.cacheGeneration,
    required this.generatedAtEpochMs,
    required this.entries,
  });

  factory DesktopBrowserAutofillMetadataCache.fromJson(
    Map<String, Object?> json,
  ) {
    return DesktopBrowserAutofillMetadataCache(
      version: _readInt(json, 'version'),
      databaseId: _readString(json, 'databaseId'),
      cacheGeneration: _readString(json, 'cacheGeneration'),
      generatedAtEpochMs: _readInt(json, 'generatedAtEpochMs'),
      entries: _readList(json, 'entries')
          .whereType<Map>()
          .map(_stringObjectMap)
          .whereType<Map<String, Object?>>()
          .map(DesktopBrowserAutofillCredentialMetadata.fromJson)
          .where((entry) => entry.id.isNotEmpty)
          .toList(growable: false),
    );
  }

  final int version;
  final String databaseId;

  /// SR-4 — opaque non-secret 128-bit generation, new on every publish.
  ///
  /// It is not a capability: knowing it grants nothing. It exists so that a
  /// republish of the *same* vault invalidates every older overlay grant by
  /// comparison, without the extension having to observe the event.
  final String cacheGeneration;
  final int generatedAtEpochMs;
  final List<DesktopBrowserAutofillCredentialMetadata> entries;

  Map<String, Object?> toJson() => {
    'version': version,
    'databaseId': databaseId,
    'cacheGeneration': cacheGeneration,
    'generatedAtEpochMs': generatedAtEpochMs,
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  };
}

class DesktopBrowserAutofillBridgeDescriptor {
  const DesktopBrowserAutofillBridgeDescriptor({
    required this.version,
    required this.port,
    required this.token,
    required this.databaseId,
    required this.cacheGeneration,
    required this.bridgeGeneration,
    required this.createdAtEpochMs,
    this.appCapabilities = const [],
  });

  factory DesktopBrowserAutofillBridgeDescriptor.fromJson(
    Map<String, Object?> json,
  ) {
    return DesktopBrowserAutofillBridgeDescriptor(
      version: _readInt(json, 'version'),
      port: _readInt(json, 'port'),
      token: _readString(json, 'token'),
      databaseId: _readString(json, 'databaseId'),
      cacheGeneration: _readString(json, 'cacheGeneration'),
      bridgeGeneration: _readString(json, 'bridgeGeneration'),
      createdAtEpochMs: _readInt(json, 'createdAtEpochMs'),
      appCapabilities: _readCapabilities(json['appCapabilities']),
    );
  }

  /// Optional for backward compatibility: a pre-B1 app writes no
  /// `appCapabilities` field and gets the empty list, which advertises
  /// nothing. Anything that is not a bounded list of short strings is
  /// treated the same way — fail closed, never fail open.
  static List<String> _readCapabilities(Object? value) {
    if (value is! List || value.length > 16) {
      return const [];
    }
    final result = <String>[];
    for (final item in value) {
      if (item is! String || item.isEmpty || item.length > 64) {
        return const [];
      }
      result.add(item);
    }
    return List.unmodifiable(result);
  }

  final int version;
  final int port;
  final String token;
  final String databaseId;

  /// The `cacheGeneration` of the metadata cache this bridge was started for.
  /// The bridge does not mint it: it reads it from the published cache, so the
  /// two can never disagree by construction.
  final String cacheGeneration;

  /// SR-4 — opaque non-secret 128-bit generation, new on every bridge start.
  final String bridgeGeneration;
  final int createdAtEpochMs;

  /// 009 / B007 — endpoints this app bridge actually serves (non-secret).
  final List<String> appCapabilities;

  Map<String, Object?> toJson() => {
    'version': version,
    'port': port,
    'token': token,
    'databaseId': databaseId,
    'cacheGeneration': cacheGeneration,
    'bridgeGeneration': bridgeGeneration,
    'createdAtEpochMs': createdAtEpochMs,
    'appCapabilities': appCapabilities,
  };
}

class DesktopBrowserAutofillPendingAssociation {
  const DesktopBrowserAutofillPendingAssociation({
    required this.id,
    required this.databaseId,
    required this.entryId,
    required this.serviceIdentifierType,
    required this.serviceIdentifierValue,
    required this.displayService,
    required this.createdAtEpochMs,
    this.platform = desktopBrowserAutofillPlatform,
  });

  factory DesktopBrowserAutofillPendingAssociation.fromJson(
    Map<String, Object?> json,
  ) {
    final type = _readString(json, 'serviceIdentifierType');
    final value = _sanitizePendingAssociationTargetValue(
      type: type,
      value: _readString(json, 'serviceIdentifierValue'),
    );
    return DesktopBrowserAutofillPendingAssociation(
      id: _readString(json, 'id'),
      databaseId: _readString(json, 'databaseId'),
      entryId: _readString(json, 'entryId'),
      serviceIdentifierType: _canonicalPendingAssociationTargetType(type) ?? '',
      serviceIdentifierValue: value,
      displayService: _sanitizePendingAssociationDisplayService(
        type: type,
        value: _readString(json, 'displayService'),
        fallbackValue: value,
      ),
      createdAtEpochMs: _readInt(json, 'createdAtEpochMs'),
      platform: _readString(json, 'platform').isEmpty
          ? desktopBrowserAutofillPlatform
          : _readString(json, 'platform'),
    );
  }

  final String id;
  final String databaseId;
  final String entryId;
  final String serviceIdentifierType;
  final String serviceIdentifierValue;
  final String displayService;
  final int createdAtEpochMs;
  final String platform;

  Map<String, Object?> toJson() {
    final type = _canonicalPendingAssociationTargetType(serviceIdentifierType);
    final value = _sanitizePendingAssociationTargetValue(
      type: serviceIdentifierType,
      value: serviceIdentifierValue,
    );
    final display = _sanitizePendingAssociationDisplayService(
      type: serviceIdentifierType,
      value: displayService,
      fallbackValue: value,
    );
    return {
      'id': id,
      'databaseId': databaseId,
      'entryId': entryId,
      'serviceIdentifierType': type ?? serviceIdentifierType,
      'serviceIdentifierValue': value,
      'displayService': display,
      'createdAtEpochMs': createdAtEpochMs,
      'platform': platform,
    };
  }
}

class DesktopBrowserAutofillAssociationTarget {
  const DesktopBrowserAutofillAssociationTarget({
    required this.type,
    required this.value,
    required this.displayService,
  });

  final String type;
  final String value;
  final String displayService;

  Map<String, Object?> toJson() => {
    'type': type,
    'value': value,
    'displayService': displayService,
  };
}

class DesktopBrowserAutofillCacheStore {
  DesktopBrowserAutofillCacheStore({
    this._directory,
    this._legacyDirectoryOverride,
  });

  final Directory? _directory;

  /// Test seam for [cleanupLegacyStore]; production always derives the legacy
  /// path from [legacyMacosDirectory].
  final Directory? _legacyDirectoryOverride;

  static bool get isPlatformSupported {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  Directory? get directory {
    if (!isPlatformSupported) {
      return null;
    }
    return _directory ?? defaultDirectory();
  }

  File? get metadataFile {
    final dir = directory;
    return dir == null ? null : File(p.join(dir.path, 'metadata.json'));
  }

  File? get pendingAssociationsFile {
    final dir = directory;
    return dir == null
        ? null
        : File(p.join(dir.path, 'pending_associations.json'));
  }

  File? get bridgeDescriptorFile {
    final dir = directory;
    return dir == null ? null : File(p.join(dir.path, 'bridge.json'));
  }

  /// macOS security analysis (fix/macos-autofill-store-location).
  ///
  /// The store lives in a *dedicated* Team-ID-prefixed app group container,
  /// separate from `group.dev.camillobucciarelli.kdbxKeyVault` (which stays
  /// owned by the Apple autofill CredentialProviderExtension):
  ///
  /// - On macOS Sequoia, "App Data protection" TCC-guards group containers.
  ///   The native host is an ephemeral process (spawned per browser request,
  ///   <1s lifetime) and TCC's per-process grant does not attribute reliably
  ///   to short-lived processes: with the legacy non-prefixed group the
  ///   "would like to access data from other apps" prompt reappeared on
  ///   every spawn (measured). Sequoia honors signature *membership* — no
  ///   prompt, ever — only for group IDs prefixed with the signing Team ID
  ///   (measured: zero prompts across repeated third-party-parented spawns
  ///   of a Developer-ID-signed probe declaring this group).
  /// - Threat model unchanged: pre-Sequoia the group container never
  ///   protected this store from other non-sandboxed same-user processes,
  ///   so a dedicated membership-readable container restores the
  ///   pre-Sequoia status quo rather than widening access. The directory is
  ///   written 0700 and files 0600 (same-user POSIX protection, equivalent
  ///   to any user-level secret store).
  /// - The bearer token in `bridge.json` is not sufficient to reveal
  ///   secrets on its own: a caller also needs loopback access to the
  ///   bridge port, the descriptor's triple binding
  ///   (`databaseId`/`cacheGeneration`/`bridgeGeneration`) to match the
  ///   live cache, the vault unlocked in the app, and a page origin the
  ///   reveal policy authorizes. The `.kdbx` vault is never in this store.
  /// - Least privilege: the native host's entitlements declare only this
  ///   group, so it cannot read the credential provider's container.
  /// - Version skew: app and host of the same release derive the path from
  ///   this one function. An old host paired with a new app finds no
  ///   descriptor/cache in the old location (the app deletes it, see
  ///   [cleanupLegacyStore]) and fails closed — no dual-read fallback, so
  ///   there is exactly one store to protect.
  static Directory? defaultDirectory({Map<String, String>? environment}) {
    if (!isPlatformSupported) {
      return null;
    }
    final env = environment ?? Platform.environment;
    if (Platform.isWindows) {
      final base = _firstNonEmpty([
        env['LOCALAPPDATA'],
        env['APPDATA'],
        env['USERPROFILE'],
      ]);
      return base == null
          ? null
          : Directory(p.join(base, 'KeyVault', 'AutofillBrowserV2'));
    }

    final home = _firstNonEmpty([env['HOME'], env['USERPROFILE']]);
    if (Platform.isMacOS && home != null) {
      return Directory(
        p.join(
          _macosUserHome(home),
          'Library',
          'Group Containers',
          'A8QUU5F9G3.dev.camillobucciarelli.kdbxKeyVault.browser',
          'browser_v2',
        ),
      );
    }
    return home == null
        ? null
        : Directory(p.join(home, '.keyvault_autofill', 'browser_v2'));
  }

  /// The pre-Sequoia-fix macOS store location, inside the shared app group
  /// container. Only used by [cleanupLegacyStore]; `null` off macOS.
  static Directory? legacyMacosDirectory({Map<String, String>? environment}) {
    if (!Platform.isMacOS) {
      return null;
    }
    final env = environment ?? Platform.environment;
    final home = _firstNonEmpty([env['HOME'], env['USERPROFILE']]);
    if (home == null) {
      return null;
    }
    return Directory(
      p.join(
        _macosUserHome(home),
        'Library',
        'Group Containers',
        'group.dev.camillobucciarelli.kdbxKeyVault',
        'browser_v2',
      ),
    );
  }

  /// The real user home even when running sandboxed, where `HOME` points
  /// inside `~/Library/Containers/<bundle>/Data`.
  static String _macosUserHome(String home) {
    final containersMarker = p.join('Library', 'Containers');
    final markerIndex = home.indexOf(containersMarker);
    return markerIndex < 0
        ? home
        : home.substring(0, markerIndex).replaceFirst(RegExp(r'[/\\]+$'), '');
  }

  /// Best-effort deletion of the legacy macOS store (migration, one-way).
  ///
  /// Nothing in the old store is worth preserving: the metadata cache is
  /// regenerated at the next publish and the bridge descriptor is rewritten
  /// on every bridge start. What must NOT happen is the old `bridge.json`
  /// (which carries a bearer token) staying orphaned in the old container,
  /// so the whole directory is deleted. The app keeps the legacy group
  /// entitlement (the credential provider still uses that group), so the
  /// sandboxed app can perform this delete.
  Future<void> cleanupLegacyStore({Map<String, String>? environment}) async {
    // Load-bearing guard: only a store pointing at the real default location
    // may clean up. A store with an injected directory (tests, tooling) must
    // never delete a legacy store — without this line, every test that
    // starts a bridge against a temp store would delete the developer's real
    // legacy container. Pinned by the 'never touches the legacy store when
    // the directory is injected' tests; checked before any override or
    // platform logic so the pin holds on every platform.
    if (_directory != null) {
      return;
    }
    final legacy =
        _legacyDirectoryOverride ??
        legacyMacosDirectory(environment: environment);
    if (legacy == null) {
      return;
    }
    try {
      if (await legacy.exists()) {
        await legacy.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<DesktopBrowserAutofillStoreStatus> status() async {
    final cache = await readMetadataCache();
    final descriptor = await readBridgeDescriptor();
    final bridgeMatchesCache =
        cache != null &&
        descriptor != null &&
        descriptor.databaseId == cache.databaseId;
    return DesktopBrowserAutofillStoreStatus(
      directoryPath: directory?.path,
      metadataCount: cache?.entries.length ?? 0,
      cacheAvailable: cache != null,
      revealBridgeAvailable: bridgeMatchesCache,
      databaseId: cache?.databaseId,
      generatedAtEpochMs: cache?.generatedAtEpochMs,
      revealBridgeCreatedAtEpochMs: bridgeMatchesCache
          ? descriptor.createdAtEpochMs
          : null,
    );
  }

  Future<void> writeMetadataCache(
    DesktopBrowserAutofillMetadataCache cache,
  ) async {
    final file = metadataFile;
    if (file == null) {
      return;
    }
    await _writeJsonFile(file, cache.toJson());
  }

  Future<DesktopBrowserAutofillMetadataCache?> readMetadataCache() async {
    final file = metadataFile;
    if (file == null || !await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final map = _stringObjectMap(decoded);
      if (map == null) {
        return null;
      }
      final cache = DesktopBrowserAutofillMetadataCache.fromJson(map);
      if (cache.version != desktopBrowserAutofillCacheVersion ||
          cache.databaseId.isEmpty ||
          cache.cacheGeneration.isEmpty) {
        return null;
      }
      return cache;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCredentials() async {
    await _deleteFile(metadataFile);
    await _deleteFile(pendingAssociationsFile);
    await _deleteFile(bridgeDescriptorFile);
  }

  Future<void> writeBridgeDescriptor(
    DesktopBrowserAutofillBridgeDescriptor descriptor,
  ) async {
    final file = bridgeDescriptorFile;
    if (file == null) {
      return;
    }
    await _writeJsonFile(file, descriptor.toJson());
  }

  Future<DesktopBrowserAutofillBridgeDescriptor?> readBridgeDescriptor() async {
    final file = bridgeDescriptorFile;
    if (file == null || !await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final map = _stringObjectMap(decoded);
      if (map == null) {
        return null;
      }
      final descriptor = DesktopBrowserAutofillBridgeDescriptor.fromJson(map);
      if (descriptor.version != desktopBrowserAutofillBridgeDescriptorVersion ||
          descriptor.port < 1 ||
          descriptor.port > 65535 ||
          descriptor.token.length < 32 ||
          descriptor.databaseId.isEmpty ||
          // `cacheGeneration` is deliberately allowed to be empty: the bridge
          // copies it from the published metadata cache, and a bridge running
          // without one is still perfectly valid for the popup reveal path. It
          // just cannot satisfy the overlay binding, which requires the value
          // to be non-empty *and* equal to the current cache's.
          descriptor.bridgeGeneration.isEmpty) {
        return null;
      }
      return descriptor;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearBridgeDescriptor() async {
    await _deleteFile(bridgeDescriptorFile);
  }

  Future<List<DesktopBrowserAutofillPendingAssociation>>
  readPendingAssociations() async {
    final file = pendingAssociationsFile;
    if (file == null || !await file.exists()) {
      return const [];
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        return const [];
      }
      return decoded
          .whereType<Map>()
          .map(_stringObjectMap)
          .whereType<Map<String, Object?>>()
          .map(DesktopBrowserAutofillPendingAssociation.fromJson)
          .where((association) => association.id.isNotEmpty)
          .where((association) => association.databaseId.isNotEmpty)
          .where((association) => association.entryId.isNotEmpty)
          .where((association) => association.serviceIdentifierValue.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<int> clearPendingAssociations({List<String>? ids}) async {
    final file = pendingAssociationsFile;
    if (file == null || !await file.exists()) {
      return 0;
    }
    if (ids == null) {
      final count = (await readPendingAssociations()).length;
      await _deleteFile(file);
      return count;
    }

    final idsToClear = ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (idsToClear.isEmpty) {
      return 0;
    }

    final associations = await readPendingAssociations();
    final remaining = associations
        .where((association) => !idsToClear.contains(association.id))
        .toList(growable: false);
    final cleared = associations.length - remaining.length;
    if (cleared == 0) {
      return 0;
    }
    if (remaining.isEmpty) {
      await _deleteFile(file);
    } else {
      await _writeJsonFile(
        file,
        remaining.map((association) => association.toJson()).toList(),
      );
    }
    return cleared;
  }

  Future<DesktopBrowserAutofillPendingAssociation?> savePendingAssociation({
    required String entryId,
    required DesktopBrowserAutofillAssociationTarget target,
    int? createdAtEpochMs,
    String? id,
  }) async {
    final cache = await readMetadataCache();
    if (cache == null) {
      return null;
    }
    final normalizedEntryId = entryId.trim();
    final normalizedTarget = _normalizedPendingAssociationTarget(target);
    final entryExists = cache.entries.any(
      (entry) => entry.id == normalizedEntryId,
    );
    if (!entryExists || normalizedEntryId.isEmpty || normalizedTarget == null) {
      return null;
    }

    final pending = DesktopBrowserAutofillPendingAssociation(
      id: id ?? _newPendingId(),
      databaseId: cache.databaseId,
      entryId: normalizedEntryId,
      serviceIdentifierType: normalizedTarget.type,
      serviceIdentifierValue: normalizedTarget.value,
      displayService: normalizedTarget.displayService.isEmpty
          ? normalizedTarget.value
          : normalizedTarget.displayService,
      createdAtEpochMs:
          createdAtEpochMs ?? DateTime.now().millisecondsSinceEpoch,
    );

    final file = pendingAssociationsFile;
    if (file == null) {
      return null;
    }
    final associations =
        (await readPendingAssociations())
            .where(
              (association) =>
                  association.databaseId != pending.databaseId ||
                  association.entryId != pending.entryId ||
                  association.serviceIdentifierType !=
                      pending.serviceIdentifierType ||
                  association.serviceIdentifierValue !=
                      pending.serviceIdentifierValue,
            )
            .toList(growable: true)
          ..add(pending);
    final capped =
        associations.length > desktopBrowserAutofillMaxPendingAssociations
        ? associations.sublist(
            associations.length - desktopBrowserAutofillMaxPendingAssociations,
          )
        : associations;
    await _writeJsonFile(
      file,
      capped.map((association) => association.toJson()).toList(growable: false),
    );
    return pending;
  }

  Future<void> _writeJsonFile(File file, Object? jsonValue) async {
    final parent = file.parent;
    await parent.create(recursive: true);
    await _chmodOwnerOnly(parent.path, isDirectory: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(jsonValue), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await temp.rename(file.path);
    await _chmodOwnerOnly(file.path, isDirectory: false);
  }

  Future<void> _deleteFile(File? file) async {
    if (file == null) {
      return;
    }
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _chmodOwnerOnly(String path, {required bool isDirectory}) async {
    if (Platform.isWindows) {
      return;
    }
    try {
      await Process.run('chmod', [isDirectory ? '700' : '600', path]);
    } catch (_) {}
  }
}

class DesktopBrowserAutofillMetadataMapper {
  const DesktopBrowserAutofillMetadataMapper();

  DesktopBrowserAutofillMetadataCache mapVault({
    required String databasePath,
    required List<VaultEntry> entries,
    int? generatedAtEpochMs,
  }) {
    final generatedAt =
        generatedAtEpochMs ?? DateTime.now().millisecondsSinceEpoch;
    return DesktopBrowserAutofillMetadataCache(
      version: desktopBrowserAutofillCacheVersion,
      databaseId: databaseIdForPath(databasePath),
      // SR-4: a brand new generation on every publish, including a republish of
      // the same vault.
      cacheGeneration: newDesktopBrowserAutofillGeneration(),
      generatedAtEpochMs: generatedAt,
      entries: entries
          .map((entry) => mapEntry(entry, updatedAtEpochMs: generatedAt))
          .whereType<DesktopBrowserAutofillCredentialMetadata>()
          .toList(growable: false),
    );
  }

  /// [requirePassword] is what keeps a passkey-only entry out of the
  /// *password* metadata cache (spec 023 T210): it has nothing to fill, so
  /// listing it in the popup would offer the user an empty password. The
  /// reveal bridge passes `false`, because a passkey-only entry does have
  /// something to sign with; nothing it builds is written to the cache.
  DesktopBrowserAutofillCredentialMetadata? mapEntry(
    VaultEntry entry, {
    required int updatedAtEpochMs,
    bool requirePassword = true,
  }) {
    final id = entry.id.trim();
    if (id.isEmpty || (requirePassword && entry.password.isEmpty)) {
      return null;
    }
    final identifiers = _serviceIdentifiersForEntry(entry);
    final displayService = displayServiceFromIdentifiers(identifiers);
    return DesktopBrowserAutofillCredentialMetadata(
      id: id,
      title: _trimForMetadata(
        entry.title,
        fallback: displayService.isEmpty ? 'Untitled' : displayService,
      ),
      username: _trimForMetadata(entry.username),
      displayService: displayService,
      serviceIdentifiers: identifiers,
      updatedAtEpochMs:
          entry.updatedAt?.millisecondsSinceEpoch ?? updatedAtEpochMs,
    );
  }

  static String databaseIdForPath(String databasePath) =>
      domain_host.databaseIdForPath(databasePath);

  /// The host of [rawValue], lowercased and collapsed onto its bare form.
  ///
  /// Set [stripPrefixes] to `false` to get the host *as served*, keeping the
  /// `www.`/`m.`/`mobile.` label. Only security predicates need that form; see
  /// [_cannotObtainWebPkiCertificate].
  static String? normalizedHost(
    String? rawValue, {
    bool stripPrefixes = true,
  }) => domain_host.normalizedHost(rawValue, stripPrefixes: stripPrefixes);

  static String? normalizedOrigin(String? rawValue) {
    final value = rawValue?.trim() ?? '';
    if (value.isEmpty || _isNativeAppValue(value)) {
      return null;
    }
    final uri = Uri.tryParse(_valueWithDefaultScheme(value));
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return null;
    }
    final host = _cleanHost(uri.host);
    if (host == null) {
      return null;
    }
    return Uri(
      scheme: scheme,
      host: host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  /// Whether the http(s) page [origin] is authorized to receive the secrets of
  /// an entry exposing [serviceIdentifiers].
  ///
  /// This is the single authorization policy for credential reveal; both the
  /// native host and the in-app reveal bridge must route through it.
  ///
  /// Rules:
  /// - a `url` identifier authorizes its exact origin only (scheme, host and
  ///   port), plus the `http` -> `https` upgrade of that same host and port;
  /// - a `domain` identifier authorizes the bare host when the entry does not
  ///   also pin a `url` identifier for that host, on an `https` page always and
  ///   on an `http` page only when the host cannot obtain a public WebPKI
  ///   certificate (see [_cannotObtainWebPkiCertificate]); when the stored
  ///   value declared a port, that port must match too.
  ///
  /// The pin is only ever set by an entry that *declared* a scheme: a URL field
  /// holding a bare host emits no `url` identifier at all, because inferring
  /// `https://` there would invent an origin the user never wrote. See
  /// [_serviceIdentifiersForEntry]. The port is not inferred but written, so it
  /// survives that de-pin inside the `domain` identifier.
  ///
  /// The `http` allowance for non-WebPKI hosts is not a comfort/security
  /// trade-off. On those hosts `https` is *not obtainable*, so requiring it
  /// would be requiring the impossible; on a publicly resolvable host it is
  /// obtainable, so requiring it is legitimate.
  ///
  /// Consequence: a page served over `http` can never obtain the secrets of an
  /// entry stored as `https`, a bare public host is never authorized over
  /// `http`, and a port mismatch is never authorized.
  static bool isRevealAuthorizedOrigin({
    required List<DesktopBrowserAutofillServiceIdentifier> serviceIdentifiers,
    required String origin,
  }) {
    final targetOrigin = normalizedOrigin(origin);
    final targetHost = normalizedHost(origin);
    // The WebPKI question is about the name the browser actually resolved and
    // would validate a certificate against, so it is asked of the un-collapsed
    // host. See [_cannotObtainWebPkiCertificate].
    final targetHostAsServed = normalizedHost(origin, stripPrefixes: false);
    if (targetOrigin == null ||
        targetHost == null ||
        targetHostAsServed == null) {
      return false;
    }
    final target = Uri.parse(targetOrigin);

    final pinnedHosts = <String>{};
    for (final identifier in serviceIdentifiers) {
      if (identifier.type != 'url') {
        continue;
      }
      final host = normalizedHost(identifier.value);
      if (host != null) {
        pinnedHosts.add(host);
      }
    }

    for (final identifier in serviceIdentifiers) {
      if (identifier.type == 'url') {
        final identifierOrigin = normalizedOrigin(identifier.value);
        if (identifierOrigin == null) {
          continue;
        }
        if (identifierOrigin == targetOrigin ||
            _isHttpsUpgrade(Uri.parse(identifierOrigin), target)) {
          return true;
        }
        continue;
      }
      if (identifier.type == 'domain' && !pinnedHosts.contains(targetHost)) {
        final schemeAllowed =
            target.scheme == 'https' ||
            _cannotObtainWebPkiCertificate(targetHostAsServed);
        if (!schemeAllowed) {
          continue;
        }
        final host = normalizedHost(identifier.value);
        if (host == null || host != targetHost) {
          continue;
        }
        // A port the user wrote is an assertion they actually made, so it keeps
        // constraining even when no scheme was written. Only the *scheme* claim
        // is inferred and therefore dropped.
        final declaredPort = _declaredPort(identifier.value);
        if (declaredPort != null && declaredPort != target.port) {
          continue;
        }
        return true;
      }
    }
    return false;
  }

  /// Same host and port, `http` stored but the page is served over `https`.
  ///
  /// Safe to allow for one narrow reason: the clause only ever widens towards
  /// `https` pages, and a browser only renders such a page after validating a
  /// certificate for that exact host. It is the opposite of a downgrade.
  ///
  /// The reason is deliberately not "whoever serves valid https already
  /// controls the origin": [_cleanHost] still strips `www.`/`m.`/`mobile.`
  /// prefixes, so identifier and target hosts are compared after collapsing
  /// distinct hosts onto one another, and a certificate valid for
  /// `m.bank.example` would not by itself say anything about
  /// `https://mobile.bank.example`. The clause survives that strip because it
  /// grants `https` pages only; it would not survive being generalized.
  static bool _isHttpsUpgrade(Uri identifier, Uri target) {
    return identifier.scheme == 'http' &&
        target.scheme == 'https' &&
        identifier.host == target.host &&
        (identifier.hasPort ? identifier.port : null) ==
            (target.hasPort ? target.port : null);
  }

  /// Names for which no publicly trusted CA can issue a certificate, so `https`
  /// is not obtainable and cannot be demanded.
  ///
  /// Must be asked of the host *as served*, never of the [_cleanHost] output.
  /// That strip is a matching affordance that collapses distinct DNS names onto
  /// one identity; feeding it here lets the collapse manufacture a property the
  /// real name does not have — `m.me` would become the single-label `me` and a
  /// cleartext `http://m.me` page would be authorized, even though `m.me`
  /// resolves publicly and holds a WebPKI certificate.
  ///
  /// This is not an arbitrary convenience list. It is the same distinction the
  /// W3C Secure Contexts spec draws when it treats `localhost` / `127.0.0.1` as
  /// potentially trustworthy, and every suffix below is reserved by an RFC or
  /// by the CA/Browser Forum baseline requirements, which forbid issuance for
  /// non-public names:
  /// - `.local` — RFC 6762 (mDNS)
  /// - `.home.arpa` — RFC 8375 (the standardized home network name)
  /// - `.localhost` — RFC 6761
  /// - `.internal` — ICANN-reserved for private use (2024)
  /// - `.lan`, `.home`, `.intranet`, `.corp`, `.private` — never delegated,
  ///   permanently withheld by ICANN over name-collision risk
  /// plus RFC 1918 / RFC 4193 / RFC 3927 / RFC 4291 address literals and
  /// single-label hosts, which have no public parent zone to be issued under.
  ///
  /// Deliberately absent:
  /// - a bare public IP literal. `1.1.1.1` proves a public address *can* hold a
  ///   WebPKI certificate, so the "not obtainable" criterion does not apply —
  ///   and a public IP over cleartext `http` is exactly the hostile-path case.
  /// - `.test`, `.example`, `.invalid` (RFC 2606). They do satisfy the
  ///   criterion, but they are documentation and testing placeholders rather
  ///   than names anything is deployed under, and `example.test` is this
  ///   repository's own stand-in for a public host in the downgrade tests.
  ///   Admitting them would make every future test written against
  ///   `example.test` silently lenient over `http`.
  static bool _cannotObtainWebPkiCertificate(String host) {
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      final bytes = address.rawAddress;
      if (address.type == InternetAddressType.IPv4) {
        return bytes[0] == 10 || // 10/8
            (bytes[0] == 172 &&
                bytes[1] >= 16 &&
                bytes[1] <= 31) || // 172.16/12
            (bytes[0] == 192 && bytes[1] == 168) || // 192.168/16
            bytes[0] == 127 || // 127/8
            (bytes[0] == 169 && bytes[1] == 254); // 169.254/16
      }
      // Unreachable today: _cleanHost rejects any host containing ':', so an
      // IPv6 literal never gets this far. Kept so that fixing that separately
      // does not silently drop loopback and private IPv6 out of the set.
      final isLoopback =
          bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1; // ::1
      return isLoopback ||
          (bytes[0] & 0xfe) == 0xfc || // fc00::/7
          (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80); // fe80::/10
    }

    // Single-label host (`nas`, `router`, `localhost`): no public parent zone.
    if (!host.contains('.')) {
      return true;
    }

    // Exact match matters for the multi-label entries: `home.arpa` is reserved,
    // while `.arpa` itself is a delegated zone.
    return _nonPublicSuffixes.contains(host) ||
        _nonPublicSuffixes.any((suffix) => host.endsWith('.$suffix'));
  }

  static const _nonPublicSuffixes = <String>{
    'local',
    'home.arpa',
    'localhost',
    'internal',
    'intranet',
    'private',
    'corp',
    'home',
    'lan',
  };

  static DesktopBrowserAutofillAssociationTarget? targetFromUrl(
    String? rawUrl,
  ) {
    final host = normalizedHost(rawUrl);
    if (host == null) {
      return null;
    }
    return DesktopBrowserAutofillAssociationTarget(
      type: 'domain',
      value: host,
      displayService: host,
    );
  }

  static String displayServiceFromIdentifiers(
    List<DesktopBrowserAutofillServiceIdentifier> identifiers,
  ) {
    // A `domain` identifier may carry `:port`; display stays host-only.
    final domain = identifiers
        .where((identifier) => identifier.type == 'domain')
        .map((identifier) => normalizedHost(identifier.value))
        .whereType<String>()
        .firstOrNull;
    if (domain != null && domain.isNotEmpty) {
      return domain;
    }
    final url = identifiers
        .where((identifier) => identifier.type == 'url')
        .map((identifier) => normalizedHost(identifier.value))
        .whereType<String>()
        .firstOrNull;
    return url ?? '';
  }

  List<DesktopBrowserAutofillServiceIdentifier> _serviceIdentifiersForEntry(
    VaultEntry entry,
  ) {
    final identifiers = <DesktopBrowserAutofillServiceIdentifier>[];
    final seen = <DesktopBrowserAutofillServiceIdentifier>{};

    void add(DesktopBrowserAutofillServiceIdentifier? identifier) {
      if (identifier == null || identifier.value.trim().isEmpty) {
        return;
      }
      if (seen.add(identifier)) {
        identifiers.add(identifier);
      }
    }

    // Only a URL that *declared* a scheme pins an origin. `normalizedOrigin`
    // infers `https://` for a bare host, and pinning that inferred value would
    // attribute to the user an origin they never wrote — which is what locked
    // `http`-only hosts (a NAS, a router, a LAN service) out of reveal.
    //
    // Note the silent declassing this leaves in place: a URL field carrying a
    // scheme that is neither `http` nor `https` (`ftp://`, `ssh://`, a custom
    // one) yields no origin either, so the entry keeps only its `domain`
    // identifier and is authorized host-wise, not origin-wise.
    final origin = _hasExplicitScheme(entry.url)
        ? normalizedOrigin(entry.url)
        : null;
    final host = _domainIdentifierValue(entry.url);
    if (origin != null) {
      add(DesktopBrowserAutofillServiceIdentifier(type: 'url', value: origin));
    }
    if (host != null) {
      add(DesktopBrowserAutofillServiceIdentifier(type: 'domain', value: host));
    }
    add(_exactOriginIdentifier(entry.url));

    for (final field in entry.customFields) {
      final key = _normalizeFieldKey(field.key);
      if (_isDomainField(key)) {
        for (final value in _splitCustomFieldValues(field.value)) {
          final domain = _domainIdentifierValue(value);
          if (domain != null) {
            add(
              DesktopBrowserAutofillServiceIdentifier(
                type: 'domain',
                value: domain,
              ),
            );
          }
        }
        continue;
      }
      if (_isUrlField(key)) {
        for (final value in _splitCustomFieldValues(field.value)) {
          final urlOrigin = _hasExplicitScheme(value)
              ? normalizedOrigin(value)
              : null;
          final urlHost = _domainIdentifierValue(value);
          if (urlOrigin != null) {
            add(
              DesktopBrowserAutofillServiceIdentifier(
                type: 'url',
                value: urlOrigin,
              ),
            );
          }
          if (urlHost != null) {
            add(
              DesktopBrowserAutofillServiceIdentifier(
                type: 'domain',
                value: urlHost,
              ),
            );
          }
          add(_exactOriginIdentifier(value));
        }
      }
    }
    return identifiers;
  }

  /// The 009 overlay identifier for a stored URL, or `null` when the stored
  /// value is not an absolute http(s) URL.
  ///
  /// Deliberately *not* derived from [normalizedOrigin]: that helper routes
  /// through `_cleanHost`, so by the time it returns, `https://www.example.com`
  /// has already become `https://example.com` and the label the user wrote is
  /// gone. An identifier that has lost a hostname label cannot authorize an
  /// exact-origin fill, which is why the overlay policy reads this type and
  /// never the `url` type.
  ///
  /// The same de-pin rule as the `url` identifier applies: a URL field holding
  /// a bare host declares no scheme, so it yields no exact origin and the entry
  /// stays domain-only — visible as possible metadata, never fillable.
  static DesktopBrowserAutofillServiceIdentifier? _exactOriginIdentifier(
    String? rawValue,
  ) {
    if (!_hasExplicitScheme(rawValue)) {
      return null;
    }
    final exactOrigin = browserExactOriginOrNull(rawValue?.trim());
    if (exactOrigin == null) {
      return null;
    }
    return DesktopBrowserAutofillServiceIdentifier(
      type: exactOriginServiceIdentifierType,
      value: exactOrigin,
    );
  }

  String _trimForMetadata(String value, {String fallback = ''}) {
    final trimmed = value.trim();
    final effective = trimmed.isEmpty ? fallback : trimmed;
    return effective.length <= 512 ? effective : effective.substring(0, 512);
  }

  static bool _isDomainField(String key) {
    return key == 'domain' ||
        key == 'domains' ||
        key == 'webdomain' ||
        key == 'hostname' ||
        key == 'host' ||
        key == 'kph:domain' ||
        key == 'kph:webdomain' ||
        RegExp(r'^kph:domain\d+$').hasMatch(key) ||
        RegExp(r'^kph:webdomain\d+$').hasMatch(key);
  }

  static bool _isUrlField(String key) => isUrlFieldKey(key);

  static String _normalizeFieldKey(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
  }

  static Iterable<String> _splitCustomFieldValues(String value) sync* {
    for (final token in value.split(RegExp(r'[,;\s]+'))) {
      final trimmed = token.trim();
      if (trimmed.isNotEmpty) {
        yield trimmed;
      }
    }
  }

  /// Whether the stored value carries a scheme the user actually typed, as
  /// opposed to the `https://` [_valueWithDefaultScheme] supplies. A
  /// protocol-relative `//host` counts as inferred: it names no scheme.
  static bool _hasExplicitScheme(String? rawValue) {
    final value = rawValue?.trim() ?? '';
    return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);
  }

  /// The port the stored value spells out, or `null` when it spells out none.
  ///
  /// Parsed under a scheme with no default port on purpose: `Uri` drops a port
  /// equal to the scheme default, so under the inferred `https://` a written
  /// `:443` would vanish and a written `:80` would survive — the presence of
  /// the user's assertion would depend on a scheme they never wrote.
  static int? _declaredPort(String? rawValue) {
    final value = rawValue?.trim() ?? '';
    if (value.isEmpty || _isNativeAppValue(value)) {
      return null;
    }
    final authorityAndRest = _hasExplicitScheme(value)
        ? value.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '')
        : (value.startsWith('//') ? value.substring(2) : value);
    final uri = Uri.tryParse('pm-port://$authorityAndRest');
    return (uri != null && uri.hasPort) ? uri.port : null;
  }

  /// The `domain` identifier value for a stored URL/host: the normalized host,
  /// carrying `:port` when the stored value declared one.
  static String? _domainIdentifierValue(String? rawValue) {
    final host = normalizedHost(rawValue);
    if (host == null) {
      return null;
    }
    final port = _declaredPort(rawValue);
    return port == null ? host : '$host:$port';
  }

  static String _valueWithDefaultScheme(String value) =>
      domain_host.valueWithDefaultScheme(value);

  static String? _cleanHost(String? rawHost, {bool stripPrefixes = true}) =>
      domain_host.cleanHost(rawHost, stripPrefixes: stripPrefixes);

  static bool _isNativeAppValue(String value) =>
      domain_host.isNativeAppValue(value);
}

DesktopBrowserAutofillAssociationTarget? _normalizedPendingAssociationTarget(
  DesktopBrowserAutofillAssociationTarget target,
) {
  final type = _canonicalPendingAssociationTargetType(target.type);
  if (type == null) {
    return null;
  }

  final value = switch (type) {
    'domain' => DesktopBrowserAutofillMetadataMapper.normalizedHost(
      target.value,
    ),
    // Same de-pin rule as _serviceIdentifiersForEntry: a `url` target that
    // names no scheme asserts no origin, and inferring `https://` here would
    // attribute one to the user. Unreachable from the extension today (the
    // native host only ever builds `domain` targets), aligned so the rule does
    // not live in one place out of two.
    'url' =>
      DesktopBrowserAutofillMetadataMapper._hasExplicitScheme(target.value)
          ? DesktopBrowserAutofillMetadataMapper.normalizedOrigin(target.value)
          : null,
    _ => null,
  };
  if (value == null || value.isEmpty) {
    return null;
  }

  final displayService = switch (type) {
    'domain' => DesktopBrowserAutofillMetadataMapper.normalizedHost(
      target.displayService,
    ),
    'url' => DesktopBrowserAutofillMetadataMapper.normalizedHost(
      target.displayService,
    ),
    _ => null,
  };

  return DesktopBrowserAutofillAssociationTarget(
    type: type,
    value: value,
    displayService:
        displayService ??
        DesktopBrowserAutofillMetadataMapper.normalizedHost(value) ??
        value,
  );
}

String? _canonicalPendingAssociationTargetType(String type) {
  final normalized = type.trim().toLowerCase().replaceAll(
    RegExp(r'[\s_-]+'),
    '',
  );
  return switch (normalized) {
    'domain' => 'domain',
    'url' => 'url',
    _ => null,
  };
}

String _sanitizePendingAssociationTargetValue({
  required String type,
  required String value,
}) {
  final targetType = _canonicalPendingAssociationTargetType(type);
  if (targetType == null) {
    return '';
  }
  return switch (targetType) {
        'domain' => DesktopBrowserAutofillMetadataMapper.normalizedHost(value),
        'url' => DesktopBrowserAutofillMetadataMapper.normalizedOrigin(value),
        _ => null,
      } ??
      '';
}

String _sanitizePendingAssociationDisplayService({
  required String type,
  required String value,
  required String fallbackValue,
}) {
  final targetType = _canonicalPendingAssociationTargetType(type);
  final normalized = targetType == null
      ? null
      : DesktopBrowserAutofillMetadataMapper.normalizedHost(value);
  return normalized ?? fallbackValue;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

/// A fresh opaque non-secret 128-bit generation id (SR-4).
///
/// Random rather than a counter so that two independent app runs, or a vault
/// republished after a crash, cannot reproduce an older value and silently
/// revalidate a stale overlay grant.
String newDesktopBrowserAutofillGeneration() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

String _newPendingId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final suffix = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'desktop-${DateTime.now().microsecondsSinceEpoch}-$suffix';
}

String _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is String ? value.trim() : '';
}

int _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is int ? value : 0;
}

List<Object?> _readList(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is List ? value.cast<Object?>() : const [];
}

Map<String, Object?>? _stringObjectMap(Object? value) {
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

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}
