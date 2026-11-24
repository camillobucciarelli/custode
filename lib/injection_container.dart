import 'package:get_it/get_it.dart';
import 'package:loggy/loggy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/di/core_di.dart';
import 'core/utils/mobile_file_storage.dart';
import 'features/password_manager/data/datasources/key_file_names_data_source.dart';
import 'features/password_manager/data/datasources/secure_data_source.dart';
import 'features/password_manager/data/services/database_file_hash_recorder.dart';
import 'features/password_manager/data/services/legacy_database_registry_migration.dart';
import 'features/password_manager/di/password_manager_data_di.dart';
import 'features/password_manager/di/password_manager_domain_di.dart';
import 'features/password_manager/di/password_manager_presentation_di.dart';
import 'features/password_manager/presentation/coordinators/session_secret_holder.dart';

final sl = GetIt.instance;

Future<void> init() async {
  final sharedPreferences = await SharedPreferences.getInstance();

  await registerCoreDependencies(sl, sharedPreferences: sharedPreferences);
  registerPasswordManagerDataDependencies(
    sl,
    keepVaultsOpenWhile: () => sl<SessionSecretHolder>().hasSecret,
  );
  registerPasswordManagerDomainDependencies(sl);
  registerPasswordManagerPresentationDependencies(sl);

  // P1-3: bridges the pre-registry SharedPreferences path keys into the
  // registry, exactly once (durable marker), before any widget is built.
  // A persistent failure (e.g. no write permission on the registry store)
  // must not brick every future launch: `migrate()` has already rolled
  // itself back to the empty-registry/previous-active snapshot before
  // rethrowing, so it is safe to log and continue here — the marker was
  // never written, so the next launch simply retries the migration.
  try {
    await sl<LegacyDatabaseRegistryMigration>().migrate();
  } catch (error, stackTrace) {
    logWarning(
      'Legacy database registry migration failed and was rolled back; '
      'continuing startup, the migration will retry on next launch.',
      error,
      stackTrace,
    );
  }

  // P1-4: fills in any registry record whose `fileHash` is absent (created
  // before this field existed, or left absent by a prior failed refresh)
  // so Locate/duplicate-detection never compares against a stale value.
  // Cheap (one read per record) and best-effort — a failure here must not
  // block startup.
  await sl<DatabaseFileHashRecorder>().reconcileMissingHashes();

  // spec-011 FR-6: unconditional startup deletion of the legacy global
  // 'MASTER_PASSWORD' entry. Awaited here so it completes before any widget
  // is built and therefore before any biometric unlock can read the keystore.
  // Idempotent delete at every launch — zero migration state to persist.
  await sl<SecureDataSource>().deleteLegacyMasterPassword();

  // spec 014 FR-3: from here on every managed key-file write records its
  // human-readable name and every listing shows it.
  MobileFileStorage.keyFileNames = sl<KeyFileNamesDataSource>();
}
