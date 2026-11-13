import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_icons.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/custode_colors.dart';
import '../../../../core/widgets/kv_pill_button.dart';
import '../../domain/models/create_database_step.dart';
import '../../domain/usecases/create_database_download_usecase.dart';
import '../bloc/database_selection/database_selection_bloc.dart';
import '../bloc/database_selection/database_selection_event.dart';
import '../bloc/database_selection/database_selection_state.dart';

/// spec 015 FR-1/FR-10 create-database wizard, two steps (C-5/C-6): the
/// screen owns ephemeral `TextEditingController`s (including password — it
/// never enters BLoC state); step position/advance policy is
/// coordinator-owned via `DatabaseSelectionBloc`.
///
/// The wizard stays mounted across submission: it dispatches
/// `CreateNewDatabase` itself, disables its controls while creation runs,
/// keeps the draft intact on failure, and pops only when the flow leaves the
/// create state (success, duplicate decision, cancel).
class CreateDatabaseScreen extends StatefulWidget {
  const CreateDatabaseScreen({super.key, this.debugWebMode});

  /// Overrides `kIsWeb` in tests so the FR-14 download-only flow can be
  /// exercised without a real browser (T022).
  @visibleForTesting
  final bool? debugWebMode;

  @override
  State<CreateDatabaseScreen> createState() => _CreateDatabaseScreenState();
}

/// spec 015 FR-4: the three-way exclusive key control.
enum KeyFileMode { none, select, generate }

class _CreateDatabaseScreenState extends State<CreateDatabaseScreen> {
  final _databaseNameCtrl = TextEditingController(text: 'new_database.kdbx');
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _passwordVisible = false;
  bool _confirmVisible = false;
  bool _biometricProtectionEnabled = false;
  KeyFileMode _keyFileMode = KeyFileMode.none;
  String? _keyFilePath;
  String? _keyFileName;

  // spec 015 FR-14 — web download-only state. The key/database bytes are
  // produced ONCE and retained so a retry after a failed download reuses
  // the same key; nothing is ever persisted.
  Uint8List? _webSelectedKeyBytes;
  CreateDatabaseDownload? _webDownload;
  bool _webKeyDownloadRequested = false;
  bool _webBuilding = false;
  String? _webErrorMessage;

  bool get _isWeb => widget.debugWebMode ?? kIsWeb;

  @override
  void initState() {
    super.initState();
    context.read<DatabaseSelectionBloc>().add(const StartCreateDatabaseFlow());
  }

  @override
  void dispose() {
    _databaseNameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickKeyFile() async {
    // FR-14: web has no durable path — the key is read as bytes.
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select a Key File',
      withData: _isWeb,
    );
    if (!mounted || result == null) return;
    final file = result.files.single;
    if (_isWeb ? file.bytes == null : file.path == null) return;
    setState(() {
      _keyFileMode = KeyFileMode.select;
      _keyFilePath = file.path;
      _keyFileName = file.name;
      _webSelectedKeyBytes = _isWeb ? file.bytes : null;
      _webDownload = null;
      _webKeyDownloadRequested = false;
    });
  }

  PasswordStrengthCategory _strengthCategory(String password) {
    if (password.isEmpty) return PasswordStrengthCategory.weak;
    var charsetSize = 0;
    if (RegExp(r'[a-z]').hasMatch(password)) charsetSize += 26;
    if (RegExp(r'[A-Z]').hasMatch(password)) charsetSize += 26;
    if (RegExp(r'[0-9]').hasMatch(password)) charsetSize += 10;
    if (RegExp(r'[^a-zA-Z0-9]').hasMatch(password)) charsetSize += 32;
    if (charsetSize == 0) return PasswordStrengthCategory.weak;
    final bits = password.length * (log(charsetSize) / log(2));
    if (bits < 40) return PasswordStrengthCategory.weak;
    if (bits < 60) return PasswordStrengthCategory.fair;
    if (bits < 80) return PasswordStrengthCategory.good;
    return PasswordStrengthCategory.strong;
  }

  /// spec 015 FR-8: an invalid character blocks advancing out of step 1 —
  /// no silent sanitisation.
  bool get _nameValid {
    final trimmed = _databaseNameCtrl.text.trim();
    return trimmed.isNotEmpty && !trimmed.contains(RegExp(r'[\\/:*?"<>|]'));
  }

  bool get _hasPassword => _passwordCtrl.text.isNotEmpty;

  bool get _hasKeyFactor => switch (_keyFileMode) {
    KeyFileMode.none => false,
    KeyFileMode.select =>
      _isWeb ? _webSelectedKeyBytes != null : _keyFilePath != null,
    KeyFileMode.generate => true,
  };

  /// spec 015 FR-3: the confirmation is mandatory only for a non-empty
  /// password.
  bool get _confirmationOk =>
      !_hasPassword || _confirmCtrl.text == _passwordCtrl.text;

  bool get _hasFactor => _hasPassword || _hasKeyFactor;

  /// spec 015 FR-2: why the submit control is inert, stated to the user.
  String? get _submitBlockReason {
    if (!_hasFactor) {
      return 'Set a master password or choose a key file to protect the '
          'database.';
    }
    if (!_confirmationOk) {
      return 'Confirm the master password to continue.';
    }
    return null;
  }

  void _advance(CreateDatabaseStep current, {required bool submitting}) {
    if (submitting) return;
    switch (current) {
      case CreateDatabaseStep.nameAndStorage:
        context.read<DatabaseSelectionBloc>().add(
          AdvanceCreateDatabaseStep(fieldsNonEmpty: _nameValid),
        );
      case CreateDatabaseStep.credentials:
        _submit();
    }
  }

  void _back(CreateDatabaseStep current, {required bool submitting}) {
    if (submitting) return;
    if (current == CreateDatabaseStep.nameAndStorage) {
      // The BlocConsumer listener owns the pop: cancelling emits a
      // non-create state, which pops this route exactly once.
      context.read<DatabaseSelectionBloc>().add(
        const CancelCreateDatabaseFlow(),
      );
      return;
    }
    context.read<DatabaseSelectionBloc>().add(const GoBackCreateDatabaseStep());
  }

  void _submit() {
    if (_submitBlockReason != null) return;
    if (_isWeb) {
      _buildWebDownload();
      return;
    }
    context.read<DatabaseSelectionBloc>().add(
      CreateNewDatabase(
        databaseFileName: _databaseNameCtrl.text.trim(),
        password: _passwordCtrl.text,
        keyFilePath: _keyFileMode == KeyFileMode.select ? _keyFilePath : null,
        biometricProtectionEnabled: _biometricProtectionEnabled,
        generateKeyFile: _keyFileMode == KeyFileMode.generate,
      ),
    );
  }

  String get _webBaseName {
    final trimmed = _databaseNameCtrl.text.trim();
    final base = trimmed.isEmpty ? 'new_database' : trimmed;
    return base.toLowerCase().endsWith('.kdbx')
        ? base.substring(0, base.length - 5)
        : base;
  }

  /// FR-14: both artefacts are produced once, in memory; a retry reuses the
  /// same generated key.
  Future<void> _buildWebDownload() async {
    if (_webBuilding) return;
    setState(() => _webBuilding = true);
    try {
      final download = await const CreateDatabaseDownloadUseCase()(
        CreateDatabaseDownloadRequest(
          password: _passwordCtrl.text,
          selectedKeyFileBytes: _keyFileMode == KeyFileMode.select
              ? _webSelectedKeyBytes
              : null,
          generateKeyFile: _keyFileMode == KeyFileMode.generate,
        ),
      );
      if (!mounted) return;
      setState(() {
        _webDownload = download;
        _webKeyDownloadRequested = false;
        _webErrorMessage = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _webErrorMessage = 'Unable to prepare the database for download.';
      });
    } finally {
      if (mounted) {
        setState(() => _webBuilding = false);
      }
    }
  }

  Future<void> _downloadWebKeyFile() async {
    final download = _webDownload;
    final keyBytes = download?.keyFileBytes;
    if (keyBytes == null) return;
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Download key file',
      fileName: '$_webBaseName.keyx',
      bytes: keyBytes,
    );
    if (!mounted || saved == null) {
      // A dismissed save dialog saved nothing: the FR-14 "key first" gate
      // must stay closed.
      return;
    }
    setState(() => _webKeyDownloadRequested = true);
  }

  Future<void> _downloadWebDatabase() async {
    final download = _webDownload;
    if (download == null) return;
    if (download.keyFileBytes != null && !_webKeyDownloadRequested) {
      // FR-14: the database download stays blocked until the key download
      // has been requested.
      return;
    }
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Download database',
      fileName: '$_webBaseName.kdbx',
      bytes: download.databaseBytes,
    );
    if (!mounted || saved == null) return;
    // FR-14: nothing is persisted — return to database selection. The
    // BlocConsumer listener owns the single pop.
    context.read<DatabaseSelectionBloc>().add(const CancelCreateDatabaseFlow());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return BlocConsumer<DatabaseSelectionBloc, DatabaseSelectionState>(
      listenWhen: (previous, current) =>
          previous is DatabaseSelectionCreateStep &&
          current is! DatabaseSelectionCreateStep,
      listener: (context, state) {
        // Creation finished (success, duplicate decision, info): the flow
        // continues on the selection screen underneath.
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
      buildWhen: (previous, current) => current is DatabaseSelectionCreateStep,
      builder: (context, state) {
        final createState = state is DatabaseSelectionCreateStep ? state : null;
        final step = createState?.step ?? CreateDatabaseStep.nameAndStorage;
        final submitting = createState?.submitting ?? false;
        final errorMessage = createState?.errorMessage;

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || submitting) return;
            // Dispatch only: the listener above performs the single pop
            // when the state leaves the create flow.
            context.read<DatabaseSelectionBloc>().add(
              const CancelCreateDatabaseFlow(),
            );
          },
          child: Scaffold(
            backgroundColor: colors.ground,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CreateHeader(
                      step: step,
                      onBack: submitting
                          ? null
                          : () => _back(step, submitting: submitting),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: SingleChildScrollView(
                        child: switch (step) {
                          CreateDatabaseStep.nameAndStorage => _NameStep(
                            controller: _databaseNameCtrl,
                            enabled: !submitting,
                            onChanged: () => setState(() {}),
                          ),
                          CreateDatabaseStep.credentials
                              when _isWeb && _webDownload != null =>
                            _WebDownloadStep(
                              hasKeyFile: _webDownload!.keyFileBytes != null,
                              keyDownloadRequested: _webKeyDownloadRequested,
                              onDownloadKeyFile: _downloadWebKeyFile,
                              onDownloadDatabase: _downloadWebDatabase,
                              onEditCredentials: () => setState(() {
                                _webDownload = null;
                                _webKeyDownloadRequested = false;
                              }),
                            ),
                          CreateDatabaseStep.credentials => _CredentialsStep(
                            passwordCtrl: _passwordCtrl,
                            confirmCtrl: _confirmCtrl,
                            passwordVisible: _passwordVisible,
                            confirmVisible: _confirmVisible,
                            enabled: !submitting,
                            onTogglePassword: () => setState(
                              () => _passwordVisible = !_passwordVisible,
                            ),
                            onToggleConfirm: () => setState(
                              () => _confirmVisible = !_confirmVisible,
                            ),
                            onChanged: () => setState(() {}),
                            strengthCategoryOf: _strengthCategory,
                            keyFileMode: _keyFileMode,
                            keyFileName: _keyFileName,
                            onKeyFileModeChanged: (mode) {
                              if (mode == KeyFileMode.select) {
                                _pickKeyFile();
                                return;
                              }
                              setState(() {
                                _keyFileMode = mode;
                                _keyFilePath = null;
                                _keyFileName = null;
                              });
                            },
                            onChangeKeyFile: _pickKeyFile,
                            onRemoveKeyFile: () => setState(() {
                              _keyFileMode = KeyFileMode.none;
                              _keyFilePath = null;
                              _keyFileName = null;
                            }),
                            biometricProtectionEnabled:
                                _biometricProtectionEnabled,
                            onBiometricChanged: (value) => setState(
                              () => _biometricProtectionEnabled = value,
                            ),
                            // FR-14: no biometric step on web, plus the
                            // inline keeps-nothing notice.
                            isWeb: _isWeb,
                            errorMessage: errorMessage ?? _webErrorMessage,
                            submitBlockReason: _submitBlockReason,
                          ),
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (!(_isWeb &&
                        _webDownload != null &&
                        step == CreateDatabaseStep.credentials))
                      KvPillButton(
                        label: submitting
                            ? 'Creating…'
                            : step == CreateDatabaseStep.credentials
                            ? (_isWeb ? 'Prepare downloads' : 'Create')
                            : 'Continue',
                        onPressed:
                            submitting ||
                                _webBuilding ||
                                (step == CreateDatabaseStep.credentials &&
                                    _submitBlockReason != null) ||
                                (step == CreateDatabaseStep.nameAndStorage &&
                                    !_nameValid)
                            ? null
                            : () => _advance(step, submitting: submitting),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CreateHeader extends StatelessWidget {
  const _CreateHeader({required this.step, required this.onBack});

  final CreateDatabaseStep step;
  final VoidCallback? onBack;

  static const _stepLabels = {
    CreateDatabaseStep.nameAndStorage: 'Step 1 of 2',
    CreateDatabaseStep.credentials: 'Step 2 of 2',
  };

  static const _stepTitles = {
    CreateDatabaseStep.nameAndStorage: 'Name your database',
    CreateDatabaseStep.credentials: 'Choose your credentials',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final index = CreateDatabaseStep.values.indexOf(step);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                onPressed: onBack,
                icon: const Icon(AppIcons.back),
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Row(
                children: List.generate(2, (i) {
                  final done = i <= index;
                  return Expanded(
                    child: Container(
                      height: 4,
                      margin: EdgeInsets.only(right: i == 1 ? 0 : 6),
                      decoration: BoxDecoration(
                        color: done ? colors.actionEmphasis : colors.canvas,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          _stepLabels[step]!,
          style: AppTextStyles.labelUpper.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 6),
        Text(
          _stepTitles[step]!,
          style: AppTextStyles.screenTitle.copyWith(color: colors.textPrimary),
        ),
      ],
    );
  }
}

class _NameStep extends StatefulWidget {
  const _NameStep({
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  State<_NameStep> createState() => _NameStepState();
}

class _NameStepState extends State<_NameStep> {
  String? _error;

  String? _validate(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'Enter a database file name.';
    }
    if (trimmed.contains(RegExp(r'[\\/:*?"<>|]'))) {
      return 'Invalid characters in file name.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: widget.controller,
          enabled: widget.enabled,
          onChanged: (value) {
            setState(() => _error = _validate(value));
            widget.onChanged();
          },
          decoration: InputDecoration(
            labelText: 'Database file name',
            prefixIcon: const Icon(AppIcons.file),
            errorText: _error,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Custode app storage',
          style: AppTextStyles.secondary.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          'Choose the database file name and security options. On native platforms, the database and generated key file are saved in app internal storage, so export manual backups regularly.',
          style: AppTextStyles.body.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// spec 015 FR-1: the single credentials step — optional password (FR-3),
/// three-way key control (FR-4), biometric activation at the bottom.
class _CredentialsStep extends StatelessWidget {
  const _CredentialsStep({
    required this.passwordCtrl,
    required this.confirmCtrl,
    required this.passwordVisible,
    required this.confirmVisible,
    required this.enabled,
    required this.onTogglePassword,
    required this.onToggleConfirm,
    required this.onChanged,
    required this.strengthCategoryOf,
    required this.keyFileMode,
    required this.keyFileName,
    required this.onKeyFileModeChanged,
    required this.onChangeKeyFile,
    required this.onRemoveKeyFile,
    required this.biometricProtectionEnabled,
    required this.onBiometricChanged,
    required this.isWeb,
    required this.errorMessage,
    required this.submitBlockReason,
  });

  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool passwordVisible;
  final bool confirmVisible;
  final bool enabled;
  final VoidCallback onTogglePassword;
  final VoidCallback onToggleConfirm;
  final VoidCallback onChanged;
  final PasswordStrengthCategory Function(String) strengthCategoryOf;
  final KeyFileMode keyFileMode;
  final String? keyFileName;
  final ValueChanged<KeyFileMode> onKeyFileModeChanged;
  final VoidCallback onChangeKeyFile;
  final VoidCallback onRemoveKeyFile;
  final bool biometricProtectionEnabled;
  final ValueChanged<bool> onBiometricChanged;
  final bool isWeb;
  final String? errorMessage;
  final String? submitBlockReason;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final hasPassword = passwordCtrl.text.isNotEmpty;
    final category = strengthCategoryOf(passwordCtrl.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: passwordCtrl,
          enabled: enabled,
          obscureText: !passwordVisible,
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: 'Master Password (optional)',
            prefixIcon: const Icon(AppIcons.lock),
            suffixIcon: IconButton(
              icon: Icon(passwordVisible ? AppIcons.eyeOff : AppIcons.eye),
              onPressed: enabled ? onTogglePassword : null,
            ),
          ),
        ),
        // spec 015 FR-3: strength meter and confirmation only exist for a
        // non-empty password.
        if (hasPassword) ...[
          const SizedBox(height: 10),
          _StrengthMeter(category: category),
          const SizedBox(height: 8),
          TextFormField(
            controller: confirmCtrl,
            enabled: enabled,
            obscureText: !confirmVisible,
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              labelText: 'Confirm Password',
              prefixIcon: const Icon(AppIcons.lock),
              suffixIcon: IconButton(
                icon: Icon(confirmVisible ? AppIcons.eyeOff : AppIcons.eye),
                onPressed: enabled ? onToggleConfirm : null,
              ),
              errorText:
                  confirmCtrl.text.isNotEmpty &&
                      confirmCtrl.text != passwordCtrl.text
                  ? 'Passwords do not match.'
                  : null,
            ),
          ),
        ],
        const SizedBox(height: 20),
        Text('Key File', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        RadioGroup<KeyFileMode>(
          groupValue: keyFileMode,
          onChanged: enabled
              ? (mode) {
                  if (mode != null) onKeyFileModeChanged(mode);
                }
              : (_) {},
          child: Column(
            children: [
              RadioListTile<KeyFileMode>(
                contentPadding: EdgeInsets.zero,
                value: KeyFileMode.none,
                enabled: enabled,
                title: const Text('No key file'),
              ),
              RadioListTile<KeyFileMode>(
                contentPadding: EdgeInsets.zero,
                value: KeyFileMode.select,
                enabled: enabled,
                title: const Text('Select an existing file'),
                subtitle:
                    keyFileMode == KeyFileMode.select && keyFileName != null
                    ? Text(keyFileName!, overflow: TextOverflow.ellipsis)
                    : null,
                secondary:
                    keyFileMode == KeyFileMode.select && keyFileName != null
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Tooltip(
                            message: 'Change key file',
                            child: IconButton(
                              icon: const Icon(AppIcons.edit),
                              onPressed: enabled ? onChangeKeyFile : null,
                            ),
                          ),
                          Tooltip(
                            message: 'Remove key file',
                            child: IconButton(
                              icon: const Icon(AppIcons.close),
                              onPressed: enabled ? onRemoveKeyFile : null,
                            ),
                          ),
                        ],
                      )
                    : null,
              ),
              RadioListTile<KeyFileMode>(
                contentPadding: EdgeInsets.zero,
                value: KeyFileMode.generate,
                enabled: enabled,
                title: const Text('Generate automatically'),
                subtitle: keyFileMode == KeyFileMode.generate
                    // spec 015 FR-13: permanent inline backup warning on the
                    // generated-key option. No modal, no checkbox.
                    ? const Text(
                        'Back up the generated key file: losing it makes '
                        'the database inaccessible.',
                      )
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (!isWeb)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable biometric protection'),
            subtitle: const Text(
              'If enabled, unlock requires biometric authentication when available.',
            ),
            value: biometricProtectionEnabled,
            onChanged: enabled ? onBiometricChanged : null,
          )
        else
          Builder(
            builder: (context) {
              final colors = Theme.of(context).extension<CustodeColors>()!;
              return Text(
                'The web app keeps nothing: the database and key file are '
                'only downloaded to your device. Reloading the page loses '
                'this draft and the key.',
                style: AppTextStyles.secondary.copyWith(
                  color: colors.textSecondary,
                ),
              );
            },
          ),
        if (submitBlockReason != null) ...[
          const SizedBox(height: 8),
          Text(
            submitBlockReason!,
            style: AppTextStyles.secondary.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
        if (errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            errorMessage!,
            style: AppTextStyles.secondary.copyWith(
              color: colors.attentionText,
            ),
          ),
        ],
      ],
    );
  }
}

/// spec 015 FR-14: the download phase — two explicit gestures, key first,
/// then database; nothing persisted.
class _WebDownloadStep extends StatelessWidget {
  const _WebDownloadStep({
    required this.hasKeyFile,
    required this.keyDownloadRequested,
    required this.onDownloadKeyFile,
    required this.onDownloadDatabase,
    required this.onEditCredentials,
  });

  final bool hasKeyFile;
  final bool keyDownloadRequested;
  final VoidCallback onDownloadKeyFile;
  final VoidCallback onDownloadDatabase;
  final VoidCallback onEditCredentials;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final databaseEnabled = !hasKeyFile || keyDownloadRequested;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'The web app keeps nothing: the database and key file are only '
          'downloaded to your device. Reloading the page loses this draft '
          'and the key.',
          style: AppTextStyles.secondary.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 16),
        if (hasKeyFile) ...[
          OutlinedButton.icon(
            onPressed: onDownloadKeyFile,
            icon: const Icon(AppIcons.save),
            label: Text(
              keyDownloadRequested
                  ? 'Download key file again'
                  : 'Download key file',
            ),
          ),
          const SizedBox(height: 8),
          if (!keyDownloadRequested)
            Text(
              'Download the key file first: the database download unlocks '
              'after it.',
              style: AppTextStyles.secondary.copyWith(
                color: colors.textSecondary,
              ),
            ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          onPressed: databaseEnabled ? onDownloadDatabase : null,
          icon: const Icon(AppIcons.save),
          label: const Text('Download database'),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: onEditCredentials,
          child: const Text('Edit credentials'),
        ),
      ],
    );
  }
}

class _StrengthMeter extends StatelessWidget {
  const _StrengthMeter({required this.category});

  final PasswordStrengthCategory category;

  static const _labels = {
    PasswordStrengthCategory.weak: 'Weak',
    PasswordStrengthCategory.fair: 'Fair',
    PasswordStrengthCategory.good: 'Good',
    PasswordStrengthCategory.strong: 'Strong',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final activeCount = PasswordStrengthCategory.values.indexOf(category) + 1;
    return Row(
      children: [
        ...List.generate(4, (i) {
          final active = i < activeCount;
          return Expanded(
            child: Container(
              height: 6,
              margin: EdgeInsets.only(right: i == 3 ? 8 : 8),
              decoration: BoxDecoration(
                color: active ? colors.actionEmphasis : colors.canvas,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          );
        }),
        Text(
          _labels[category]!,
          style: AppTextStyles.secondary.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}
