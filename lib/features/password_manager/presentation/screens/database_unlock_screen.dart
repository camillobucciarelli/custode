import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loggy/loggy.dart';

import '../../../../../core/navigation/app_navigation.dart';
import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_icons.dart';
import '../../../../../core/theme/app_motion.dart';
import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_circle_icon_button.dart';
import '../../../../../core/widgets/kv_confirm_dialog.dart';
import '../../../../../core/widgets/kv_field_decoration.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../../../injection_container.dart' as di;
import '../bloc/database_unlock/database_unlock_bloc.dart';
import '../bloc/database_unlock/database_unlock_event.dart';
import '../bloc/database_unlock/database_unlock_state.dart';
import '../../domain/errors/database_access_failure.dart';
import '../coordinators/android_autofill_save_coordinator.dart';
import '../coordinators/database_session_coordinator.dart';
import '../coordinators/pending_passkey_adoption_coordinator.dart';
import '../widgets/database/biometric_offer_sheet.dart';
import '../widgets/database/source_chip.dart';
import '../widgets/key_file_picker.dart';
import '../utils/platform_utils.dart';
import 'database_selection_screen.dart';
import 'vault_screen.dart';

part 'database_unlock_widgets.part.dart';

class DatabaseUnlockScreen extends StatelessWidget {
  final String databasePath;

  /// Replaces the vault route after a successful unlock. `VaultScreen` needs
  /// the whole vault DI graph, which unlock tests do not build.
  @visibleForTesting
  final Widget Function(String databasePath)? debugVaultBuilder;

  const DatabaseUnlockScreen({
    super.key,
    required this.databasePath,
    this.debugVaultBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          di.sl<DatabaseUnlockBloc>(param1: databasePath)
            ..add(const InitializeDatabaseUnlock()),
      child: _DatabaseUnlockView(vaultBuilder: debugVaultBuilder),
    );
  }
}

class _DatabaseUnlockView extends StatefulWidget {
  const _DatabaseUnlockView({this.vaultBuilder});

  final Widget Function(String databasePath)? vaultBuilder;

  @override
  State<_DatabaseUnlockView> createState() => _DatabaseUnlockViewState();
}

class _DatabaseUnlockViewState extends State<_DatabaseUnlockView> {
  final _passwordCtrl = TextEditingController();
  bool _passwordVisible = false;

  /// Captured in `initState`: teardown must not need the locator (golden tests
  /// run in any order).
  /// Null where autofill save capture is not wired in (same optional
  /// integration `VaultBloc` already takes).
  AndroidAutofillSaveCoordinator? _autofillSaveCoordinator;
  bool _hasPendingCapture = false;
  bool _unlocked = false;

  /// Passkeys-all-platforms FR-9: records waiting in the native queue, shown
  /// before unlock. Needs no session. Stays 0 where the coordinator is not
  /// registered, which keeps the banner out of every scene that has none.
  int _waitingPasskeys = 0;

  @override
  void initState() {
    super.initState();
    if (di.sl.isRegistered<PendingPasskeyAdoptionCoordinator>()) {
      unawaited(
        _loadWaitingPasskeys(di.sl<PendingPasskeyAdoptionCoordinator>()),
      );
    }
    if (di.sl.isRegistered<AndroidAutofillSaveCoordinator>()) {
      _autofillSaveCoordinator = di.sl<AndroidAutofillSaveCoordinator>();
    }
    unawaited(_checkPendingCapture());
  }

  Future<void> _loadWaitingPasskeys(
    PendingPasskeyAdoptionCoordinator coordinator,
  ) async {
    final count = await coordinator.waitingCount();
    if (mounted && count > 0) setState(() => _waitingPasskeys = count);
  }

  Future<void> _checkPendingCapture() async {
    final coordinator = _autofillSaveCoordinator;
    if (coordinator == null) {
      return;
    }
    // `hasPendingCapture` claims the token before it returns, so from here on
    // this screen owns it and must not simply walk away from it.
    final pending = await coordinator.hasPendingCapture();
    if (!pending) {
      return;
    }
    if (!mounted) {
      // The screen went away while we were asking. Nothing will show the notice
      // and nothing will run dispose's abandon, so drop the capture here —
      // otherwise it outlives the unlock the user abandoned and the next
      // unlock, of a possibly different database, would be offered it.
      unawaited(coordinator.abandonPendingCapture());
      return;
    }
    setState(() => _hasPendingCapture = true);
  }

  @override
  void dispose() {
    // Leaving the unlock screen without unlocking discards the capture now,
    // instead of leaving the submitted password in the autofill service's
    // memory until it expires.
    if (_hasPendingCapture && !_unlocked) {
      unawaited(_autofillSaveCoordinator?.abandonPendingCapture());
    }
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickKeyFile() async {
    final bloc = context.read<DatabaseUnlockBloc>();
    final current = bloc.state.keyFilePath;
    final picked = await pickKeyFile(context, current: current);
    if (!mounted || picked == null) {
      return;
    }
    // Unlock has no bytes path: a browser never reaches a stored database.
    if (picked.path != null) {
      bloc.add(UpdateKeyFilePath(picked.path));
    } else if (picked.isCleared) {
      bloc.add(const UpdateKeyFilePath(null));
    }
  }

  /// Offer once, then continue to the vault. Neither the offer nor a keystore
  /// failure may stop the unlock the user just completed.
  Future<void> _finishUnlock(DatabaseUnlockState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final coordinator = di.sl<DatabaseSessionCoordinator>();
    // Whatever the unlock could not save (spec 025 D10), plus the offer's own
    // outcome below.
    final notices = <String>[?state.notice];
    try {
      if (await coordinator.shouldOfferBiometricUnlock(
        state.databasePath,
        biometricAvailable: supportsBiometricUnlock && state.biometricAvailable,
      )) {
        if (!mounted) {
          return;
        }
        final enable =
            await showBiometricOfferSheet(
              context,
              databaseName: state.databaseLabel,
            ) ??
            false;
        if (!await coordinator.answerBiometricOffer(
              state.databasePath,
              enable: enable,
            ) &&
            !notices.contains(biometricsNotEnabledNotice)) {
          notices.add(biometricsNotEnabledNotice);
        }
      }
    } catch (e, st) {
      logWarning('Biometric offer failed after unlock.', e, st);
    }
    if (!mounted) {
      return;
    }
    if (notices.isNotEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(notices.join(' '))));
    }
    await AppNavigation.pushFadeReplacement(
      context,
      widget.vaultBuilder?.call(state.databasePath) ??
          VaultScreen(databasePath: state.databasePath),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return Scaffold(
      backgroundColor: colors.ground,
      body: BlocConsumer<DatabaseUnlockBloc, DatabaseUnlockState>(
        listener: (context, state) {
          if (state.unlocked && !_unlocked) {
            _unlocked = true;
            unawaited(_finishUnlock(state));
          }
          if (state.databaseRemoved) {
            AppNavigation.pushFadeReplacement(
              context,
              const DatabaseSelectionScreen(),
            );
          }
        },
        builder: (context, state) {
          // The notice sits outside the phase switch: with biometrics enabled the
          // manual form is never shown, and that is precisely the case where the
          // user is most likely to walk away without knowing what they lose.
          // Issue #276: system back is the on-screen back, confirmation
          // included. Not while the vault is opening: that ends in its own
          // navigation.
          final busy =
              state.phase == UnlockPhase.decrypting ||
              state.phase == UnlockPhase.unlocked;
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && !busy) unawaited(_goToDatabaseSelection());
            },
            child: Column(
              children: [
                if (_hasPendingCapture &&
                    state.phase != UnlockPhase.unlocked &&
                    state.phase != UnlockPhase.decrypting)
                  const _PendingCaptureNotice(),
                if (_waitingPasskeys > 0 &&
                    state.phase != UnlockPhase.unlocked &&
                    state.phase != UnlockPhase.decrypting)
                  _WaitingPasskeysNotice(count: _waitingPasskeys),
                Expanded(child: _phaseView(context, state)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _phaseView(BuildContext context, DatabaseUnlockState state) {
    {
      switch (state.phase) {
        case UnlockPhase.initializing:
          return const _UnlockLoading();
        case UnlockPhase.biometricGate:
          return _BiometricGate(
            onRetry: () => context.read<DatabaseUnlockBloc>().add(
              const RetryBiometricAuthentication(),
            ),
            onUseMasterPassword: () => context.read<DatabaseUnlockBloc>().add(
              const RequestManualUnlockFallback(),
            ),
            errorMessage: state.errorMessage,
          );
        case UnlockPhase.decrypting:
          return _DecryptingView(basename: state.databaseLabel);
        case UnlockPhase.failure:
          if (state.failure is DatabaseFileMissingFailure) {
            return _UnlockMissingView(
              state: state,
              onLocate: _locateFile,
              onRedownload: () => context.read<DatabaseUnlockBloc>().add(
                const RedownloadMissingDatabase(),
              ),
              onRemove: _removeFromList,
              onBack: _goToDatabaseSelection,
            );
          }
          return _UnlockFailureView(
            state: state,
            onBack: _goToDatabaseSelection,
          );
        case UnlockPhase.unlocked:
          return const _UnlockLoading();
        case UnlockPhase.ready:
          final hasPassword = _passwordCtrl.text.isNotEmpty;
          final hasKeyFile =
              state.keyFilePath != null && state.keyFilePath!.trim().isNotEmpty;
          final canSubmit = hasPassword || hasKeyFile;
          return _UnlockReadyForm(
            state: state,
            passwordCtrl: _passwordCtrl,
            passwordVisible: _passwordVisible,
            onPasswordChanged: () => setState(() {}),
            onTogglePasswordVisible: () =>
                setState(() => _passwordVisible = !_passwordVisible),
            onPickKeyFile: _pickKeyFile,
            onClearKeyFile: () => context.read<DatabaseUnlockBloc>().add(
              const UpdateKeyFilePath(null),
            ),
            onBiometricRetry: () => context.read<DatabaseUnlockBloc>().add(
              const RetryBiometricAuthentication(),
            ),
            onSubmit: canSubmit
                ? () {
                    context.read<DatabaseUnlockBloc>().add(
                      UnlockWithManualCredentials(
                        password: _passwordCtrl.text,
                        keyFilePath: state.keyFilePath,
                      ),
                    );
                  }
                : null,
            onBack: _goToDatabaseSelection,
          );
      }
    }
  }

  Future<void> _goToDatabaseSelection() async {
    final hasPasswordDraft = _passwordCtrl.text.isNotEmpty;
    final keyFilePath = context.read<DatabaseUnlockBloc>().state.keyFilePath;
    final hasKeyFileDraft =
        keyFilePath != null && keyFilePath.trim().isNotEmpty;

    if (hasPasswordDraft || hasKeyFileDraft) {
      final shouldLeave = await showKvConfirmDialog(
        context,
        title: 'Return to database list?',
        body:
            'Any unlock credentials entered on this screen will be discarded.',
        confirmLabel: 'Return',
        cancelLabel: 'Stay here',
      );

      if (shouldLeave != true || !mounted) {
        return;
      }
    }

    await AppNavigation.pushFadeReplacement(
      context,
      const DatabaseSelectionScreen(),
    );
  }

  Future<void> _locateFile() async {
    final bloc = context.read<DatabaseUnlockBloc>();
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['kdbx'],
    );
    final selectedPath = result?.files.single.path;
    if (!mounted || selectedPath == null || selectedPath.trim().isEmpty) {
      return;
    }
    bloc.add(LocateMissingDatabaseFile(selectedPath));
  }

  Future<void> _removeFromList() async {
    final bloc = context.read<DatabaseUnlockBloc>();
    final confirmed = await showKvConfirmDialog(
      context,
      title: 'Remove ${bloc.state.databaseLabel} from the list?',
      body: 'The file is already missing. Nothing else is deleted.',
      confirmLabel: 'Remove',
    );
    if (confirmed == true && mounted) {
      bloc.add(const RemoveMissingDatabase());
    }
  }
}
