import 'package:loggy/loggy.dart';

import '../../domain/models/apple_autofill_v2_models.dart';
import '../../domain/models/vault_entry.dart';
import '../../domain/repositories/autofill_ports.dart';
import '../../domain/repositories/database_registry_repository.dart';
import '../../domain/services/apple_autofill_v2_payload_mapper.dart';
import '../../domain/services/autofill_database_id.dart';

abstract interface class AppleAutofillV2CoordinatorContract {
  Future<void> publishVault({
    required String databasePath,
    required List<VaultEntry> entries,
  });

  Future<void> clearCredentials({String? databasePath});

  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  });

  Future<void> clearPendingAssociations({List<String>? ids});
}

class NoopAppleAutofillV2Coordinator
    implements AppleAutofillV2CoordinatorContract {
  const NoopAppleAutofillV2Coordinator();

  @override
  Future<void> publishVault({
    required String databasePath,
    required List<VaultEntry> entries,
  }) async {}

  @override
  Future<void> clearCredentials({String? databasePath}) async {}

  @override
  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  }) async {
    return const [];
  }

  @override
  Future<void> clearPendingAssociations({List<String>? ids}) async {}
}

class AppleAutofillV2Coordinator implements AppleAutofillV2CoordinatorContract {
  AppleAutofillV2Coordinator({
    required this.client,
    required this.mapper,
    this.databaseRegistry,
  });

  /// Android only: how long one device authentication is reused before the
  /// picker prompts again. Long enough that filling a username field and then
  /// the password field of the same login prompts once, short enough that a
  /// later fill re-authenticates.
  static const authSessionTtl = Duration(seconds: 30);

  final AppleAutofillV2Client client;
  final AppleAutofillV2PayloadMapper mapper;

  /// Resolves the stable id the cache is published under; without it (or for
  /// an unregistered path) the id is the legacy path hash.
  final DatabaseRegistryRepository? databaseRegistry;

  @override
  Future<void> publishVault({
    required String databasePath,
    required List<VaultEntry> entries,
  }) async {
    if (!client.isSupported) {
      return;
    }

    final ids = await _idsForPath(databasePath);
    if (ids == null) {
      await clearCredentials();
      return;
    }

    try {
      await client.publishCredentials(
        databaseId: ids.published,
        credentials: mapper.mapEntries(entries),
        authSessionTtlMs: authSessionTtl.inMilliseconds,
      );
    } catch (e, st) {
      logWarning('Apple Autofill v2 publish failed.', e, st);
    }
  }

  @override
  Future<void> clearCredentials({String? databasePath}) async {
    if (!client.isSupported) {
      return;
    }

    try {
      await client.clearCredentials(
        databaseId: (await _idsForPath(databasePath))?.published,
      );
    } catch (e, st) {
      logWarning('Apple Autofill v2 clear failed.', e, st);
    }
  }

  @override
  Future<List<AppleAutofillV2PendingAssociation>> readPendingAssociations({
    String? databasePath,
  }) async {
    if (!client.isSupported) {
      return const [];
    }

    final ids = await _idsForPath(databasePath);
    if (ids == null) {
      return const [];
    }

    try {
      final pendingAssociations = await client.readPendingAssociations();
      return pendingAssociations
          // Associations queued before the registry id carry the path hash.
          .where((association) => ids.matches(association.databaseId))
          .toList(growable: false);
    } catch (e, st) {
      logWarning('Apple Autofill v2 read pending associations failed.', e, st);
      return const [];
    }
  }

  @override
  Future<void> clearPendingAssociations({List<String>? ids}) async {
    if (!client.isSupported) {
      return;
    }

    try {
      await client.clearPendingAssociations(ids: ids);
    } catch (e, st) {
      logWarning('Apple Autofill v2 clear pending associations failed.', e, st);
    }
  }

  Future<AutofillDatabaseIds?> _idsForPath(String? databasePath) async {
    if (databasePath == null || databasePath.trim().isEmpty) {
      return null;
    }
    return autofillDatabaseIdsFor(databasePath, databaseRegistry);
  }
}
