import 'package:get_it/get_it.dart';

import '../domain/services/password_generator_service.dart';
import '../domain/usecases/create_database_usecase.dart';
import '../domain/usecases/get_active_database_usecase.dart';
import '../domain/usecases/link_database_to_remote_usecase.dart';
import '../domain/usecases/load_sync_merge_field_display_usecase.dart';
import '../domain/usecases/resolve_database_duplicate_usecase.dart';
import '../domain/usecases/sync_database_now_usecase.dart';
import '../domain/usecases/sync_merge_usecases.dart';
import '../domain/usecases/unlock_database_usecase.dart';
import '../domain/usecases/validate_database_usecase.dart';

void registerPasswordManagerDomainDependencies(GetIt sl) {
  sl.registerLazySingleton(() => PasswordGeneratorService());
  sl.registerLazySingleton(() => GetActiveDatabaseUseCase(sl()));
  sl.registerLazySingleton(() => ResolveDatabaseDuplicateUseCase(sl(), sl()));
  // spec 010 T401/T502: the two atomic remote actions behind the sync port.
  sl.registerLazySingleton(() => LinkDatabaseToRemoteUseCase(sl()));
  sl.registerLazySingleton(() => SyncDatabaseNowUseCase(sl()));
  sl.registerLazySingleton(() => UnlockDatabaseUseCase());
  sl.registerLazySingleton(() => ValidateDatabaseUseCase());
  sl.registerLazySingleton(
    () => CreateDatabaseUseCase(databaseFileRepository: sl()),
  );

  // spec 008 T310 — the merge command use cases. The coordinator (Phase 5)
  // depends on these; `LoadSyncMergeFieldDisplayUseCase` stays in its own
  // library so importing the commands cannot bring the transient plaintext
  // response into scope, and only the field widget (Phase 6) resolves it.
  sl.registerLazySingleton(() => StartSyncMergeReviewUseCase(sl()));
  sl.registerLazySingleton(() => UpdateSyncMergeDecisionUseCase(sl()));
  sl.registerLazySingleton(() => CommitSyncMergeUseCase(sl()));
  sl.registerLazySingleton(() => CancelSyncMergeUseCase(sl()));
  sl.registerLazySingleton(() => InvalidateSyncMergeUseCase(sl()));
  sl.registerLazySingleton(() => RecoverPendingSyncMergeUploadUseCase(sl()));
  sl.registerLazySingleton(() => LoadSyncMergeFieldDisplayUseCase(sl()));
}
