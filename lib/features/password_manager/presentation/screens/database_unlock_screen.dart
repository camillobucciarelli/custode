import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

import '../../../../../core/navigation/app_navigation.dart';
import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_icons.dart';
import '../../../../../core/theme/app_motion.dart';
import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/utils/mobile_file_storage.dart';
import '../../../../../core/widgets/kv_confirm_dialog.dart';
import '../../../../../core/widgets/kv_circle_icon_button.dart';
import '../../../../../core/widgets/kv_field_decoration.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_list_row.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../../../injection_container.dart' as di;
import '../bloc/database_unlock/database_unlock_bloc.dart';
import '../bloc/database_unlock/database_unlock_event.dart';
import '../bloc/database_unlock/database_unlock_state.dart';
import '../coordinators/android_autofill_save_coordinator.dart';
import '../coordinators/database_session_coordinator.dart';
import '../../data/datasources/biometric_data_source.dart';
import '../widgets/managed_key_picker_gate.dart';
import '../../domain/errors/database_access_failure.dart';
import '../widgets/database/biometric_prompt_sheet.dart';
import '../widgets/internal_key_file_manager_sheet.dart';
import '../utils/platform_utils.dart';
import 'database_selection_screen.dart';
import 'vault_screen.dart';

part 'database_unlock_widgets.part.dart';

class DatabaseUnlockScreen extends StatelessWidget {
  final String databasePath;
  final bool promptBiometricSetup;

  const DatabaseUnlockScreen({
    super.key,
    required this.databasePath,
    this.promptBiometricSetup = false,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          di.sl<DatabaseUnlockBloc>(param1: databasePath)
            ..add(const InitializeDatabaseUnlock()),
      child: _DatabaseUnlockView(promptBiometricSetup: promptBiometricSetup),
    );
  }
}

class _DatabaseUnlockView extends StatefulWidget {
  const _DatabaseUnlockView({required this.promptBiometricSetup});

  final bool promptBiometricSetup;

  @override
  State<_DatabaseUnlockView> createState() => _DatabaseUnlockViewState();
}

class _DatabaseUnlockViewState extends State<_DatabaseUnlockView> {
  final _passwordCtrl = TextEditingController();
  bool _passwordVisible = false;
  bool _biometricPromptHandled = false;

  /// Captured in `initState`: teardown must not need the locator (golden tests
  /// run in any order).
  /// Null where autofill save capture is not wired in (same optional
  /// integration `VaultBloc` already takes).
  AndroidAutofillSaveCoordinator? _autofillSaveCoordinator;
  bool _hasPendingCapture = false;
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    if (di.sl.isRegistered<AndroidAutofillSaveCoordinator>()) {
      _autofillSaveCoordinator = di.sl<AndroidAutofillSaveCoordinator>();
    }
    unawaited(_checkPendingCapture());
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
    if (isManagedStoragePlatform) {
      final bloc = context.read<DatabaseUnlockBloc>();
      final currentKeyFilePath = bloc.state.keyFilePath;
      // spec 015 FR-12 (T018): managed keys list only after device auth.
      final authorized = await authorizeManagedKeyPickerAccess(
        di.sl<BiometricDataSource>(),
      );
      if (!mounted || !authorized) {
        return;
      }
      final protectedPaths = await di
          .sl<DatabaseSessionCoordinator>()
          .getProtectedKeyFilePaths();
      if (!mounted) {
        return;
      }
      final result = await showInternalKeyFileManagerSheet(
        context,
        initiallySelectedPath: currentKeyFilePath,
        protectedPaths: {...protectedPaths, ?currentKeyFilePath},
      );
      if (!mounted || result == null) {
        return;
      }

      if (result.selectedPath != null) {
        bloc.add(UpdateKeyFilePath(result.selectedPath));
        return;
      }

      if (result.currentSelectionDeleted &&
          currentKeyFilePath != null &&
          currentKeyFilePath.trim().isNotEmpty) {
        bloc.add(const UpdateKeyFilePath(null));
      }
      return;
    }

    final result = await FilePicker.pickFiles(withData: false);
    if (!mounted || result == null) {
      return;
    }

    final selected = result.files.single;
    String? path = selected.path;
    if (path == null || path.isEmpty) {
      return;
    }

    if (!mounted) {
      return;
    }

    context.read<DatabaseUnlockBloc>().add(UpdateKeyFilePath(path));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return Scaffold(
      backgroundColor: colors.ground,
      body: BlocConsumer<DatabaseUnlockBloc, DatabaseUnlockState>(
        listener: (context, state) {
          if (widget.promptBiometricSetup &&
              !_biometricPromptHandled &&
              state.phase == UnlockPhase.ready) {
            _biometricPromptHandled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) {
                return;
              }
              _showBiometricSetupPrompt();
            });
          }
          if (state.unlocked) {
            _unlocked = true;
            AppNavigation.pushFadeReplacement(
              context,
              VaultScreen(databasePath: state.databasePath),
            );
          }
        },
        builder: (context, state) {
          // The notice sits outside the phase switch: with biometrics enabled the
          // manual form is never shown, and that is precisely the case where the
          // user is most likely to walk away without knowing what they lose.
          return Column(
            children: [
              if (_hasPendingCapture &&
                  state.phase != UnlockPhase.unlocked &&
                  state.phase != UnlockPhase.decrypting)
                const _PendingCaptureNotice(),
              Expanded(child: _phaseView(context, state)),
            ],
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

  Future<void> _showBiometricSetupPrompt() async {
    final basename = context.read<DatabaseUnlockBloc>().state.databaseLabel;
    final shouldEnable = await showBiometricPromptDialog(
      context,
      basename: basename,
    );

    if (shouldEnable == null || !mounted) {
      return;
    }

    await di.sl<DatabaseSessionCoordinator>().updateBiometricProtection(
      databasePath: context.read<DatabaseUnlockBloc>().state.databasePath,
      enabled: shouldEnable,
    );
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          shouldEnable
              ? 'Biometric protection enabled for this database.'
              : 'Biometric protection remains disabled for this database.',
        ),
      ),
    );

    if (shouldEnable) {
      context.read<DatabaseUnlockBloc>().add(const InitializeDatabaseUnlock());
    }
  }
}
