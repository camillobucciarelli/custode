import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loggy/loggy.dart';

import '../../../domain/errors/database_access_failure.dart';
import '../../../domain/models/create_database_step.dart';
import '../../../domain/models/database_dedup_result.dart';
import '../../coordinators/database_session_coordinator.dart';
import 'database_selection_event.dart';
import 'database_selection_state.dart';

/// Maps a typed [DatabaseAccessFailure] to non-secret, basename-only UI copy
/// (C-3). Never renders a raw path or `e.toString()`.
String failureMessage(DatabaseAccessFailure failure) => switch (failure) {
  DatabaseFileMissingFailure(:final basename) =>
    basename.isEmpty
        ? 'Database file was not found.'
        : 'Database file "$basename" was not found.',
  InvalidDatabaseFileFailure(:final basename) =>
    '"$basename" is not a valid Custode database file.',
  CorruptDatabaseFailure(:final basename) =>
    '"$basename" could not be read. The file may be corrupted.',
  KeyFileMissingFailure() =>
    'Key file not found. Locate or select the required key file.',
  InvalidCredentialsFailure() => 'Incorrect master password or key file.',
  MissingCredentialFactorFailure() =>
    'Set a master password or choose a key file to protect the database.',
  InvalidKeyFileFailure() =>
    'The selected key file is empty or could not be read.',
  MetadataStorageUnreadableFailure() =>
    'Saved database details cannot be read on this device.',
};

class DatabaseSelectionBloc
    extends Bloc<DatabaseSelectionEvent, DatabaseSelectionState> {
  DatabaseSelectionBloc({required this.databaseSessionCoordinator})
    : super(const DatabaseSelectionInitial()) {
    on<CheckInitialDatabase>(_onCheckInitialDatabase);
    on<SelectExistingDatabase>(_onSelectExistingDatabase);
    on<OpenRecentDatabase>(_onOpenRecentDatabase);
    on<CreateNewDatabase>(_onCreateNewDatabase);
    on<SelectDriveDatabase>(_onSelectDriveDatabase);
    on<RemoveRecentDatabase>(_onRemoveRecentDatabase);
    on<ResolveDuplicateDecision>(_onResolveDuplicateDecision);
    on<LocateMissingDatabase>(_onLocateMissingDatabase);
    on<StartCreateDatabaseFlow>(_onStartCreateDatabaseFlow);
    on<AdvanceCreateDatabaseStep>(_onAdvanceCreateDatabaseStep);
    on<GoBackCreateDatabaseStep>(_onGoBackCreateDatabaseStep);
    on<CancelCreateDatabaseFlow>(_onCancelCreateDatabaseFlow);
    on<DiscardUnreadableMetadata>(_onDiscardUnreadableMetadata);
  }

  final DatabaseSessionCoordinator databaseSessionCoordinator;
  DatabaseDuplicatePrompt? _pendingDuplicatePrompt;

  Future<void> _onCheckInitialDatabase(
    CheckInitialDatabase event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    _safeEmit(emit, const DatabaseSelectionLoading());
    try {
      final result = await databaseSessionCoordinator.checkInitialDatabase();
      _pendingDuplicatePrompt = null;
      _emitResult(emit, result);
    } catch (e, st) {
      logError('Failed to check initial database selection state.', e, st);
      _emitFailure(emit, e);
      _safeEmit(emit, const DatabaseSelectionUnselected());
    }
  }

  Future<void> _onSelectExistingDatabase(
    SelectExistingDatabase event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    _safeEmit(emit, DatabaseSelectionLoading(items: state.items));
    try {
      final result = await databaseSessionCoordinator.selectExistingDatabase(
        fileName: event.fileName,
        selectedPath: event.selectedPath,
        selectedBytes: event.selectedBytes,
        overwriteExisting: event.overwriteExisting,
      );
      _pendingDuplicatePrompt = null;
      _emitResult(emit, result);
    } catch (e, st) {
      logError('Failed while selecting an existing database file.', e, st);
      _emitFailure(emit, e);
      _safeEmit(emit, DatabaseSelectionUnselected(items: state.items));
    }
  }

  Future<void> _onOpenRecentDatabase(
    OpenRecentDatabase event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    _safeEmit(emit, DatabaseSelectionLoading(items: state.items));
    try {
      final result = await databaseSessionCoordinator.openRecentDatabase(
        event.path,
      );
      _pendingDuplicatePrompt = null;
      _emitResult(emit, result);
    } catch (e, st) {
      logError('Failed while opening recent database file.', e, st);
      _emitFailure(emit, e);
      _safeEmit(emit, DatabaseSelectionUnselected(items: state.items));
    }
  }

  Future<void> _onLocateMissingDatabase(
    LocateMissingDatabase event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    _safeEmit(emit, DatabaseSelectionLoading(items: state.items));
    try {
      final result = await databaseSessionCoordinator.locateMissingDatabase(
        databaseId: event.databaseId,
        selectedPath: event.selectedPath,
      );
      _emitResult(emit, result);
    } catch (e, st) {
      logError('Failed while locating a missing database file.', e, st);
      _emitFailure(emit, e);
      _safeEmit(emit, DatabaseSelectionUnselected(items: state.items));
    }
  }

  /// spec 015 FR-10: the wizard stays mounted across submission. While
  /// creation runs the state carries a `submitting` flag; on failure the
  /// state returns to the credentials step with a message, never to a
  /// terminal error state that would unmount the wizard and lose the draft.
  Future<void> _onCreateNewDatabase(
    CreateNewDatabase event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    _safeEmit(
      emit,
      DatabaseSelectionCreateStep(
        CreateDatabaseStep.credentials,
        submitting: true,
        items: state.items,
      ),
    );
    try {
      final result = await databaseSessionCoordinator.createNewDatabase(
        databaseFileName: event.databaseFileName,
        password: event.password,
        keyFilePath: event.keyFilePath,
        biometricProtectionEnabled: event.biometricProtectionEnabled,
        generateKeyFile: event.generateKeyFile,
        generatedKeyFilePath: event.generatedKeyFilePath,
      );
      if (result.status == DatabaseSessionStatus.error) {
        _safeEmit(
          emit,
          DatabaseSelectionCreateStep(
            CreateDatabaseStep.credentials,
            errorMessage: result.message,
            items: result.items,
          ),
        );
        return;
      }
      _pendingDuplicatePrompt = null;
      _emitResult(emit, result);
    } catch (e, st) {
      logError('Failed while creating a new database file.', e, st);
      final message = e is DatabaseAccessFailure
          ? failureMessage(e)
          : 'Unable to create the database. Nothing was changed.';
      _safeEmit(
        emit,
        DatabaseSelectionCreateStep(
          CreateDatabaseStep.credentials,
          errorMessage: message,
          items: state.items,
        ),
      );
    }
  }

  Future<void> _onSelectDriveDatabase(
    SelectDriveDatabase event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    _safeEmit(emit, DatabaseSelectionLoading(items: state.items));
    try {
      final result = await databaseSessionCoordinator.selectDriveDatabase(
        remoteFileId: event.remoteFileId,
        remoteFileName: event.remoteFileName,
        overwriteExisting: event.overwriteExisting,
      );
      _pendingDuplicatePrompt = null;
      _emitResult(emit, result);
    } catch (e, st) {
      logError('Failed while selecting database from Drive.', e, st);
      _emitFailure(emit, e);
      _safeEmit(emit, DatabaseSelectionUnselected(items: state.items));
    }
  }

  Future<void> _onRemoveRecentDatabase(
    RemoveRecentDatabase event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    _safeEmit(emit, DatabaseSelectionLoading(items: state.items));
    try {
      final result = await databaseSessionCoordinator.removeRecentDatabase(
        path: event.path,
        mode: event.mode,
      );
      _emitResult(emit, result);
      _pendingDuplicatePrompt = null;
      _safeEmit(emit, DatabaseSelectionUnselected(items: result.items));
    } catch (e, st) {
      logError('Failed while removing recent database.', e, st);
      _emitFailure(emit, e);
      _safeEmit(emit, DatabaseSelectionUnselected(items: state.items));
    }
  }

  Future<void> _onDiscardUnreadableMetadata(
    DiscardUnreadableMetadata event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    _safeEmit(emit, DatabaseSelectionLoading(items: state.items));
    try {
      final items = await databaseSessionCoordinator
          .discardUnreadableMetadata();
      _safeEmit(
        emit,
        DatabaseSelectionInfo(
          'Saved database details were reset. Add your databases again.',
          items: items,
        ),
      );
      _safeEmit(emit, DatabaseSelectionUnselected(items: items));
    } catch (e, st) {
      logError('Failed while discarding unreadable metadata.', e, st);
      _emitFailure(emit, e);
      _safeEmit(emit, DatabaseSelectionUnselected(items: state.items));
    }
  }

  Future<void> _onResolveDuplicateDecision(
    ResolveDuplicateDecision event,
    Emitter<DatabaseSelectionState> emit,
  ) async {
    final pending = _pendingDuplicatePrompt;
    if (pending == null) {
      _safeEmit(
        emit,
        DatabaseSelectionError(
          'No pending duplicate operation found.',
          items: state.items,
        ),
      );
      return;
    }

    _safeEmit(emit, DatabaseSelectionLoading(items: state.items));
    try {
      final result = await databaseSessionCoordinator.resolveDuplicateDecision(
        duplicatePrompt: pending,
        decision: event.decision,
      );
      if (event.decision == DatabaseDuplicateResolution.cancel) {
        _pendingDuplicatePrompt = null;
      }
      _emitResult(emit, result);
    } catch (e, st) {
      logError('Failed while resolving duplicate decision.', e, st);
      _emitFailure(emit, e);
      _safeEmit(emit, DatabaseSelectionUnselected(items: state.items));
    }
  }

  void _onStartCreateDatabaseFlow(
    StartCreateDatabaseFlow event,
    Emitter<DatabaseSelectionState> emit,
  ) {
    _safeEmit(
      emit,
      DatabaseSelectionCreateStep(
        CreateDatabaseStep.nameAndStorage,
        items: state.items,
      ),
    );
  }

  void _onAdvanceCreateDatabaseStep(
    AdvanceCreateDatabaseStep event,
    Emitter<DatabaseSelectionState> emit,
  ) {
    final current = state;
    final currentStep = current is DatabaseSelectionCreateStep
        ? current.step
        : CreateDatabaseStep.nameAndStorage;
    final nextStep = databaseSessionCoordinator
        .resolveCreateDatabaseStepAdvance(
          current: currentStep,
          fieldsNonEmpty: event.fieldsNonEmpty,
          confirmationMatches: event.confirmationMatches,
        );
    _safeEmit(emit, DatabaseSelectionCreateStep(nextStep, items: state.items));
  }

  void _onGoBackCreateDatabaseStep(
    GoBackCreateDatabaseStep event,
    Emitter<DatabaseSelectionState> emit,
  ) {
    final current = state;
    final currentStep = current is DatabaseSelectionCreateStep
        ? current.step
        : CreateDatabaseStep.nameAndStorage;
    final previousStep = databaseSessionCoordinator
        .resolveCreateDatabaseStepBack(currentStep);
    _safeEmit(
      emit,
      DatabaseSelectionCreateStep(previousStep, items: state.items),
    );
  }

  void _onCancelCreateDatabaseFlow(
    CancelCreateDatabaseFlow event,
    Emitter<DatabaseSelectionState> emit,
  ) {
    _safeEmit(emit, DatabaseSelectionUnselected(items: state.items));
  }

  void _emitFailure(Emitter<DatabaseSelectionState> emit, Object error) {
    if (error is DatabaseAccessFailure) {
      _safeEmit(
        emit,
        DatabaseSelectionError(
          failureMessage(error),
          failure: error,
          items: state.items,
        ),
      );
      return;
    }
    _safeEmit(
      emit,
      DatabaseSelectionError(
        'Unable to complete the requested database operation.',
        items: state.items,
      ),
    );
  }

  void _emitResult(
    Emitter<DatabaseSelectionState> emit,
    DatabaseSelectionSessionResult result,
  ) {
    switch (result.status) {
      case DatabaseSessionStatus.success:
        if (result.path == null || result.path!.trim().isEmpty) {
          _safeEmit(
            emit,
            DatabaseSelectionError(
              'Invalid database path received from session coordinator.',
              items: result.items,
            ),
          );
          _safeEmit(emit, DatabaseSelectionUnselected(items: result.items));
          return;
        }
        if (result.message != null && result.message!.trim().isNotEmpty) {
          _safeEmit(
            emit,
            DatabaseSelectionInfo(result.message!, items: result.items),
          );
        }
        _safeEmit(
          emit,
          DatabaseSelectionSuccess(
            result.path!,
            userMessage: result.message,
            promptBiometricSetup: result.promptBiometricSetup,
            items: result.items,
          ),
        );
        _pendingDuplicatePrompt = null;
      case DatabaseSessionStatus.error:
        _safeEmit(
          emit,
          DatabaseSelectionError(
            result.message ?? 'Unknown database selection error.',
            items: result.items,
          ),
        );
        _safeEmit(emit, DatabaseSelectionUnselected(items: result.items));
      case DatabaseSessionStatus.info:
        _safeEmit(
          emit,
          DatabaseSelectionInfo(result.message ?? '', items: result.items),
        );
      case DatabaseSessionStatus.unselected:
        _safeEmit(emit, DatabaseSelectionUnselected(items: result.items));
      case DatabaseSessionStatus.duplicateDecisionRequired:
        final duplicatePrompt = result.duplicatePrompt;
        if (duplicatePrompt == null) {
          _safeEmit(
            emit,
            DatabaseSelectionError(
              'Duplicate decision required but no prompt data was provided.',
              items: result.items,
            ),
          );
          return;
        }
        _pendingDuplicatePrompt = duplicatePrompt;
        _safeEmit(
          emit,
          DatabaseSelectionDuplicateDecisionRequired(
            duplicatePrompt: duplicatePrompt,
            message:
                result.message ??
                'Duplicate database detected. Choose how to continue.',
            items: result.items,
          ),
        );
    }
  }

  void _safeEmit(
    Emitter<DatabaseSelectionState> emit,
    DatabaseSelectionState nextState,
  ) {
    if (isClosed || emit.isDone) {
      return;
    }
    emit(nextState);
  }
}
