import 'dart:convert';

import 'package:equatable/equatable.dart';

/// spec 010 decode rule 6: a persisted mapping whose required identity is
/// missing or malformed. Deliberately carries nothing from the entry — no
/// path, id or provider — so it can be surfaced and logged as-is.
final class SyncMappingDecodeException implements Exception {
  const SyncMappingDecodeException();

  @override
  String toString() => 'Sync mapping identity is missing or malformed.';
}

class DatabaseSyncMapping extends Equatable {
  const DatabaseSyncMapping({
    this.databaseId,
    required this.databasePath,
    required this.providerId,
    required this.remoteFileId,
    required this.remoteFileName,
    this.lastSyncedLocalChecksum,
    this.lastSyncedRemoteChecksum,
    this.lastSyncedRemoteModifiedTime,
    this.lastSyncAt,
    this.autoSyncEnabled = true,
    this.lastError,
  });

  /// spec 010 §Persisted mapping schema: the shape every save writes.
  static const schemaVersion = 2;

  /// spec 010 decode rule 1: a version-1 mapping predates `providerId`, and
  /// every version-1 mapping was written by the Google Drive integration.
  static const _v1DefaultProviderId = 'google_drive';

  /// spec 014 FR-6: the registry identifier this mapping is keyed by.
  /// Nullable only because pre-keying constructions stamp it at upsert time.
  final String? databaseId;

  final String databasePath;

  /// Stable machine id of the provider that owns [remoteFileId]. Remote
  /// identity is always the tuple `(providerId, remoteFileId)`.
  final String providerId;
  final String remoteFileId;

  /// Display name only; never identity.
  final String remoteFileName;
  final String? lastSyncedLocalChecksum;
  final String? lastSyncedRemoteChecksum;
  final DateTime? lastSyncedRemoteModifiedTime;
  final DateTime? lastSyncAt;
  final bool autoSyncEnabled;
  final String? lastError;

  /// Whether this mapping links to the given remote file. Remote identity is
  /// the tuple, never the id alone (spec 010). The one lookup behind both the
  /// picker's `Already added` tag and import conflict detection.
  bool pointsAt({required String providerId, required String remoteFileId}) =>
      this.providerId == providerId && this.remoteFileId == remoteFileId;

  DatabaseSyncMapping copyWith({
    String? databaseId,
    String? databasePath,
    String? providerId,
    String? remoteFileId,
    String? remoteFileName,
    String? lastSyncedLocalChecksum,
    String? lastSyncedRemoteChecksum,
    DateTime? lastSyncedRemoteModifiedTime,
    DateTime? lastSyncAt,
    bool? autoSyncEnabled,
    String? lastError,
    bool clearError = false,
  }) {
    return DatabaseSyncMapping(
      databaseId: databaseId ?? this.databaseId,
      databasePath: databasePath ?? this.databasePath,
      providerId: providerId ?? this.providerId,
      remoteFileId: remoteFileId ?? this.remoteFileId,
      remoteFileName: remoteFileName ?? this.remoteFileName,
      lastSyncedLocalChecksum:
          lastSyncedLocalChecksum ?? this.lastSyncedLocalChecksum,
      lastSyncedRemoteChecksum:
          lastSyncedRemoteChecksum ?? this.lastSyncedRemoteChecksum,
      lastSyncedRemoteModifiedTime:
          lastSyncedRemoteModifiedTime ?? this.lastSyncedRemoteModifiedTime,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
      lastError: clearError ? null : lastError ?? this.lastError,
    );
  }

  /// Version-2 shape only (spec 010 §Write-forward): generic identity keys,
  /// no legacy Drive keys. Every other key is byte-semantically the same as
  /// version 1.
  Map<String, dynamic> toMap() {
    return {
      'schemaVersion': schemaVersion,
      'databaseId': databaseId,
      'databasePath': databasePath,
      'providerId': providerId,
      'remoteFileId': remoteFileId,
      'remoteFileName': remoteFileName,
      'lastSyncedLocalChecksum': lastSyncedLocalChecksum,
      'lastSyncedRemoteChecksum': lastSyncedRemoteChecksum,
      'lastSyncedRemoteModifiedTime': lastSyncedRemoteModifiedTime
          ?.toUtc()
          .toIso8601String(),
      'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
      'autoSyncEnabled': autoSyncEnabled,
      'lastError': lastError,
    };
  }

  /// spec 010 §Backward-compatible decode, rules 1-6.
  ///
  /// Version 1 (no `schemaVersion`) defaults `providerId` to Google Drive and
  /// reads the legacy `driveFileId` / `driveFileName` keys only when the
  /// generic key is absent or empty — a valid generic value always wins.
  /// Version 2 reads generic keys only. Missing or malformed identity throws
  /// [SyncMappingDecodeException]; nothing is guessed and nothing is written.
  factory DatabaseSyncMapping.fromMap(Map<String, dynamic> map) {
    final version = map['schemaVersion'];
    final isV1 = version == null || version == 1;

    String? nonEmpty(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;

    final databasePath = nonEmpty(map['databasePath']);
    final providerId =
        nonEmpty(map['providerId']) ?? (isV1 ? _v1DefaultProviderId : null);
    final remoteFileId =
        nonEmpty(map['remoteFileId']) ??
        (isV1 ? nonEmpty(map['driveFileId']) : null);
    final remoteFileName =
        nonEmpty(map['remoteFileName']) ??
        (isV1 ? nonEmpty(map['driveFileName']) : null);
    if (databasePath == null ||
        providerId == null ||
        remoteFileId == null ||
        remoteFileName == null) {
      throw const SyncMappingDecodeException();
    }

    return DatabaseSyncMapping(
      databaseId: map['databaseId'] as String?,
      databasePath: databasePath,
      providerId: providerId,
      remoteFileId: remoteFileId,
      remoteFileName: remoteFileName,
      lastSyncedLocalChecksum: map['lastSyncedLocalChecksum'] as String?,
      lastSyncedRemoteChecksum: map['lastSyncedRemoteChecksum'] as String?,
      lastSyncedRemoteModifiedTime: map['lastSyncedRemoteModifiedTime'] == null
          ? null
          : DateTime.tryParse(map['lastSyncedRemoteModifiedTime'] as String)
                ?.toLocal(),
      lastSyncAt: map['lastSyncAt'] == null
          ? null
          : DateTime.tryParse(map['lastSyncAt'] as String)?.toLocal(),
      autoSyncEnabled: map['autoSyncEnabled'] as bool? ?? true,
      lastError: map['lastError'] as String?,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory DatabaseSyncMapping.fromJson(String source) {
    return DatabaseSyncMapping.fromMap(
      jsonDecode(source) as Map<String, dynamic>,
    );
  }

  @override
  List<Object?> get props => [
    databaseId,
    databasePath,
    providerId,
    remoteFileId,
    remoteFileName,
    lastSyncedLocalChecksum,
    lastSyncedRemoteChecksum,
    lastSyncedRemoteModifiedTime,
    lastSyncAt,
    autoSyncEnabled,
    lastError,
  ];
}

/// Snapshot of both mapping slots involved in a `moveMappingPath` call,
/// exact enough to be inverted byte-for-byte. `sourceBefore`/
/// `destinationBefore` are `null` when no mapping occupied that path before
/// the move — restoring from a `null` snapshot means "delete", never
/// "invent a mapping".
class DatabaseSyncMappingPathMove extends Equatable {
  const DatabaseSyncMappingPathMove({
    required this.fromDatabasePath,
    required this.toDatabasePath,
    required this.sourceBefore,
    required this.destinationBefore,
  });

  final String fromDatabasePath;
  final String toDatabasePath;
  final DatabaseSyncMapping? sourceBefore;
  final DatabaseSyncMapping? destinationBefore;

  @override
  List<Object?> get props => [
    fromDatabasePath,
    toDatabasePath,
    sourceBefore,
    destinationBefore,
  ];
}
