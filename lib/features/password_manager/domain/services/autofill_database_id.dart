import 'package:loggy/loggy.dart';
import 'package:path/path.dart' as p;

import '../../../../core/utils/portable_path.dart';
import '../repositories/database_registry_repository.dart';
import 'host_identity.dart';

/// The ids the vault at one path is known by on the autofill surfaces
/// (published cache, pending associations, pending passkey records).
///
/// The id is not a secret, but it decides which vault a queued credential
/// lands in: matching is exact equality against these two ids, never fuzzy.
class AutofillDatabaseIds {
  const AutofillDatabaseIds({
    required this.published,
    required this.legacy,
    this.registryUnavailable = false,
  });

  /// What the cache is published under: [registryAutofillDatabaseId] when the
  /// path is in the registry, else [legacy].
  final String published;

  /// `sha256:` of the trimmed path. Everything written before the registry id
  /// existed carries this one, so it stays accepted.
  final String legacy;

  /// The registry could not be read, so [published] is only the fallback and
  /// the vault's real registry id is unknown for now.
  final bool registryUnavailable;

  bool matches(String databaseId) =>
      databaseId == published || databaseId == legacy;

  /// True when [databaseId] is a registry id that cannot be told apart from
  /// the open vault's own until the registry is readable again. Such a record
  /// must be left alone: neither adopted nor reported as another vault's.
  bool isUndecidable(String databaseId) =>
      registryUnavailable && databaseId.startsWith(_registryPrefix);
}

const _registryPrefix = 'reg:';

/// Survives a path change (for example an iOS container relocation): the
/// registry row keeps its `databaseId` and only its path is re-resolved.
String registryAutofillDatabaseId(String registryDatabaseId) =>
    '$_registryPrefix$registryDatabaseId';

/// The single place the autofill id of [databasePath] is computed. A path
/// that is not registered falls back to the legacy path hash; so does a
/// registry that cannot be read, flagged as
/// [AutofillDatabaseIds.registryUnavailable].
Future<AutofillDatabaseIds> autofillDatabaseIdsFor(
  String databasePath,
  DatabaseRegistryRepository? registry,
) async {
  final path = databasePath.trim();
  final legacy = databaseIdForPath(path);
  try {
    for (final record in await registry?.list() ?? const []) {
      if (_sameFile(record.canonicalPath, path)) {
        return AutofillDatabaseIds(
          published: registryAutofillDatabaseId(record.databaseId),
          legacy: legacy,
        );
      }
    }
  } on Object catch (e) {
    // Type only: a message could quote a path.
    logWarning('Autofill database id: registry unreadable (${e.runtimeType}).');
    return AutofillDatabaseIds(
      published: legacy,
      legacy: legacy,
      registryUnavailable: true,
    );
  }
  return AutofillDatabaseIds(published: legacy, legacy: legacy);
}

/// Two spellings of one file: normalized (`.`, `..`, separators, and case
/// where the path style folds it), then with symlinks resolved, which is what
/// folds `/var` onto `/private/var`. Same comparison as
/// `resolveDatabaseIdForSync`; never basename or fuzzy.
// ponytail: case aliases on a case-insensitive macOS/iOS volume are not
// folded (p.equals only folds on Windows); such a path keeps the legacy id.
bool _sameFile(String a, String b) {
  if (p.equals(p.normalize(a.trim()), p.normalize(b))) return true;
  try {
    return p.equals(
      PortablePath.resolveForComparison(a.trim()),
      PortablePath.resolveForComparison(b),
    );
  } on Object {
    return false; // Unresolvable: the normalized comparison stands.
  }
}
