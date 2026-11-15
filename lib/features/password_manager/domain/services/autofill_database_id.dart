import '../repositories/database_registry_repository.dart';
import 'host_identity.dart';

/// The ids the vault at one path is known by on the autofill surfaces
/// (published cache, pending associations, pending passkey records).
///
/// The id is not a secret, but it decides which vault a queued credential
/// lands in: matching is exact equality against these two ids, never fuzzy.
class AutofillDatabaseIds {
  const AutofillDatabaseIds({required this.published, required this.legacy});

  /// What the cache is published under: [registryAutofillDatabaseId] when the
  /// path is in the registry, else [legacy].
  final String published;

  /// `sha256:` of the trimmed path. Everything written before the registry id
  /// existed carries this one, so it stays accepted.
  final String legacy;

  bool matches(String databaseId) =>
      databaseId == published || databaseId == legacy;
}

/// Survives a path change (for example an iOS container relocation): the
/// registry row keeps its `databaseId` and only its path is re-resolved.
String registryAutofillDatabaseId(String registryDatabaseId) =>
    'reg:$registryDatabaseId';

/// The single place the autofill id of [databasePath] is computed. A path
/// that is not registered, or a registry that cannot be read, falls back to
/// the legacy path hash.
Future<AutofillDatabaseIds> autofillDatabaseIdsFor(
  String databasePath,
  DatabaseRegistryRepository? registry,
) async {
  final path = databasePath.trim();
  final legacy = databaseIdForPath(path);
  try {
    for (final record in await registry?.list() ?? const []) {
      if (record.canonicalPath == path) {
        return AutofillDatabaseIds(
          published: registryAutofillDatabaseId(record.databaseId),
          legacy: legacy,
        );
      }
    }
  } on Object {
    // Fall through: the legacy id still identifies the vault by its path.
  }
  return AutofillDatabaseIds(published: legacy, legacy: legacy);
}
