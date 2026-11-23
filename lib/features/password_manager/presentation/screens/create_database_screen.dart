import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_glyph.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/custode_colors.dart';
import '../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../core/widgets/kv_circle_icon_button.dart';
import '../../../../core/widgets/kv_field_decoration.dart';
import '../../../../core/widgets/kv_icon.dart';
import '../../../../core/widgets/kv_list_row.dart';
import '../../../../core/widgets/kv_pill_button.dart';
import '../../../../core/widgets/kv_switch.dart';
import '../../../../injection_container.dart' as di;
import '../../data/datasources/biometric_data_source.dart';
import '../../domain/models/create_database_step.dart';
import '../../domain/models/storage_account_summary.dart';
import '../../domain/usecases/create_database_download_usecase.dart';
import '../../domain/utils/password_strength.dart';
import '../bloc/database_selection/database_selection_bloc.dart';
import '../bloc/database_selection/database_selection_event.dart';
import '../bloc/database_selection/database_selection_state.dart';
import '../coordinators/database_session_coordinator.dart';
import '../utils/platform_utils.dart';
import '../widgets/database/database_source_sheet.dart';
import '../widgets/database/source_chip.dart';
import '../widgets/database/source_option_card.dart';
import '../widgets/entry/strength_strip.dart';
import '../widgets/key_file_picker.dart';

/// Spec 025 FR-C1..C8 create-database wizard, two steps: "Name and place" then
/// "Protect it". The screen owns ephemeral `TextEditingController`s (including
/// password: it never enters BLoC state) and the chosen source; step
/// position/advance policy is coordinator-owned via `DatabaseSelectionBloc`.
///
/// The wizard stays mounted across submission: it dispatches
/// `CreateNewDatabase` itself, disables its controls while creation runs and
/// keeps the draft intact on failure. It pops itself when the flow is
/// cancelled or ends in a decision; on success the selection screen replaces
/// it with the vault, so there is a single navigation.
class CreateDatabaseScreen extends StatefulWidget {
  const CreateDatabaseScreen({super.key});

  @override
  State<CreateDatabaseScreen> createState() => _CreateDatabaseScreenState();
}

/// spec 015 FR-4: the three exclusive key-file modes, presented as one row
/// plus a sheet.
enum KeyFileMode { none, select, generate }

const _generatedKeyLabel = 'New key file, created with the database';

class _CreateDatabaseScreenState extends State<CreateDatabaseScreen> {
  final _databaseNameCtrl = TextEditingController(text: 'new_database');
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  late final DatabaseSessionCoordinator _coordinator;

  bool _passwordVisible = false;
  bool _confirmVisible = false;
  bool _biometricProtectionEnabled = false;
  bool _biometricAvailable = false;
  KeyFileMode _keyFileMode = KeyFileMode.none;
  String? _keyFilePath;
  String? _keyFileName;

  // Step 1: where the database lives. Ephemeral, never in BLoC state.
  DatabaseSource _source = DatabaseSource.device;
  StorageAccountSummary? _account;
  bool _connecting = false;
  String? _connectError;

  // spec 015 FR-14 — web download-only state. The key/database bytes are
  // produced ONCE and retained so a retry after a failed download reuses
  // the same key; nothing is ever persisted.
  Uint8List? _webSelectedKeyBytes;
  CreateDatabaseDownload? _webDownload;
  bool _webKeyDownloadRequested = false;
  bool _webBuilding = false;
  String? _webErrorMessage;

  @override
  void initState() {
    super.initState();
    _coordinator = di.sl<DatabaseSessionCoordinator>();
    context.read<DatabaseSelectionBloc>().add(const StartCreateDatabaseFlow());
    if (supportsRemoteSource) {
      _coordinator.connectedAccountOrNull().then((account) {
        if (mounted) setState(() => _account = account);
      });
    }
    if (supportsBiometricUnlock) {
      di.sl<BiometricDataSource>().isBiometricAvailable().then((available) {
        if (mounted) setState(() => _biometricAvailable = available);
      });
    }
  }

  @override
  void dispose() {
    _databaseNameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    final account = await _coordinator.connectRemoteAccount();
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _account = account;
      if (account == null) {
        _connectError = 'Could not connect to Google Drive.';
      } else {
        _source = DatabaseSource.remote;
      }
    });
  }

  /// The empty row offers both ways to get a key; a filled row reopens the
  /// same sheet to change it.
  Future<void> _chooseKeyFile() async {
    final choice = await KvBottomSheet.show<KeyFileMode>(
      context: context,
      builder: (sheetContext) => const _KeyChoiceSheet(),
    );
    if (!mounted || choice == null) return;
    if (choice == KeyFileMode.generate) {
      setState(() {
        _keyFileMode = KeyFileMode.generate;
        _keyFilePath = null;
        _keyFileName = _generatedKeyLabel;
        _webSelectedKeyBytes = null;
        _webDownload = null;
        _webKeyDownloadRequested = false;
      });
      return;
    }
    final picked = await pickKeyFile(context, current: _keyFilePath);
    if (!mounted || picked == null) return;
    if (picked.isCleared) {
      _clearKeyFile();
      return;
    }
    setState(() {
      _keyFileMode = KeyFileMode.select;
      _keyFilePath = picked.path;
      _keyFileName = picked.name;
      _webSelectedKeyBytes = picked.bytes;
      _webDownload = null;
      _webKeyDownloadRequested = false;
    });
  }

  void _clearKeyFile() => setState(() {
    _keyFileMode = KeyFileMode.none;
    _keyFilePath = null;
    _keyFileName = null;
    _webSelectedKeyBytes = null;
    _webDownload = null;
    _webKeyDownloadRequested = false;
  });

  /// spec 015 FR-8: an invalid character blocks advancing out of step 1 —
  /// no silent sanitisation.
  String? get _nameError {
    final trimmed = _databaseNameCtrl.text.trim();
    if (trimmed.isEmpty) return 'Enter a database name.';
    if (trimmed.contains(RegExp(r'[\\/:*?"<>|]'))) {
      return 'Invalid characters in the name.';
    }
    return null;
  }

  bool get _nameValid => _nameError == null;

  /// `Personal` and `Personal.kdbx` both mean the file `Personal.kdbx`.
  String get _fileName {
    final trimmed = _databaseNameCtrl.text.trim();
    return trimmed.toLowerCase().endsWith('.kdbx') ? trimmed : '$trimmed.kdbx';
  }

  bool get _hasPassword => _passwordCtrl.text.isNotEmpty;

  bool get _hasKeyFactor => switch (_keyFileMode) {
    KeyFileMode.none => false,
    KeyFileMode.select => _keyFilePath != null || _webSelectedKeyBytes != null,
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
    if (!persistsDatabases) {
      _buildWebDownload();
      return;
    }
    context.read<DatabaseSelectionBloc>().add(
      CreateNewDatabase(
        databaseFileName: _fileName,
        password: _passwordCtrl.text,
        keyFilePath: _keyFileMode == KeyFileMode.select ? _keyFilePath : null,
        biometricProtectionEnabled: _biometricProtectionEnabled,
        generateKeyFile: _keyFileMode == KeyFileMode.generate,
        createOnRemote: _source == DatabaseSource.remote && _account != null,
      ),
    );
  }

  String get _webBaseName => _fileName.substring(0, _fileName.length - 5);

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
          current is! DatabaseSelectionCreateStep &&
          // Success is the selection screen's navigation (vault or unlock).
          current is! DatabaseSelectionSuccess,
      listener: (context, state) {
        // Cancelled or ended in a decision: the flow continues on the
        // selection screen underneath.
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
        final showingDownloads =
            !persistsDatabases &&
            _webDownload != null &&
            step == CreateDatabaseStep.credentials;
        final blockReason = step == CreateDatabaseStep.credentials
            ? _submitBlockReason
            : null;

        return PopScope(
          canPop: false,
          // Issue #276: system back is the on-screen back, one step at a
          // time; from the first step `_back` cancels and the listener
          // above performs the single pop.
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back(step, submitting: submitting);
          },
          child: Scaffold(
            backgroundColor: colors.ground,
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
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
                                error: _nameError,
                                fileName: _fileName,
                                source: _source,
                                account: _account,
                                connecting: _connecting,
                                connectError: _connectError,
                                onSelectDevice: () => setState(
                                  () => _source = DatabaseSource.device,
                                ),
                                onSelectRemote: _account == null
                                    ? _connect
                                    : () => setState(
                                        () => _source = DatabaseSource.remote,
                                      ),
                                onChanged: () => setState(() {}),
                              ),
                              CreateDatabaseStep.credentials
                                  when showingDownloads =>
                                _WebDownloadStep(
                                  hasKeyFile:
                                      _webDownload!.keyFileBytes != null,
                                  keyDownloadRequested:
                                      _webKeyDownloadRequested,
                                  onDownloadKeyFile: _downloadWebKeyFile,
                                  onDownloadDatabase: _downloadWebDatabase,
                                  onEditCredentials: () => setState(() {
                                    _webDownload = null;
                                    _webKeyDownloadRequested = false;
                                  }),
                                ),
                              CreateDatabaseStep.credentials =>
                                _CredentialsStep(
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
                                  keyFileMode: _keyFileMode,
                                  keyFilePath: _keyFilePath,
                                  keyFileName: _keyFileName,
                                  onChooseKeyFile: _chooseKeyFile,
                                  onClearKeyFile: _clearKeyFile,
                                  biometricEnabled: _biometricProtectionEnabled,
                                  biometricUnavailable:
                                      !supportsBiometricUnlock ||
                                      !_biometricAvailable,
                                  onBiometricChanged: (value) => setState(
                                    () => _biometricProtectionEnabled = value,
                                  ),
                                  errorMessage:
                                      errorMessage ?? _webErrorMessage,
                                ),
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (!showingDownloads) ...[
                          KvPillButton(
                            label: submitting
                                ? 'Creating $_fileName…'
                                : step == CreateDatabaseStep.credentials
                                ? (persistsDatabases
                                      ? 'Create database'
                                      : 'Prepare downloads')
                                : 'Continue',
                            onPressed:
                                submitting ||
                                    _webBuilding ||
                                    blockReason != null ||
                                    (step ==
                                            CreateDatabaseStep.nameAndStorage &&
                                        !_nameValid)
                                ? null
                                : () => _advance(step, submitting: submitting),
                          ),
                          if (step == CreateDatabaseStep.credentials) ...[
                            const SizedBox(height: 10),
                            // Disabled-button reason, announced when it
                            // changes; otherwise the outcome caption.
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                blockReason ??
                                    (persistsDatabases
                                        ? 'Opens right away, no need to type '
                                              'the password again.'
                                        : 'Downloads the database. The '
                                              'browser keeps nothing.'),
                                textAlign: TextAlign.center,
                                style: AppTextStyles.secondary.copyWith(
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
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

  static const _stepTitles = {
    CreateDatabaseStep.nameAndStorage: 'Name and place',
    CreateDatabaseStep.credentials: 'Protect it',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final index = CreateDatabaseStep.values.indexOf(step);
    final label = 'Step ${index + 1} of 2';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: KvCircleIconButton(
            glyph: AppGlyph.back,
            tooltip: 'Back',
            size: 44,
            iconSize: 18,
            onPressed: onBack,
          ),
        ),
        const SizedBox(height: 14),
        Semantics(
          container: true,
          label: label,
          excludeSemantics: true,
          child: Row(
            children: List.generate(2, (i) {
              return Expanded(
                child: Container(
                  height: 5,
                  margin: EdgeInsets.only(right: i == 1 ? 0 : 6),
                  decoration: BoxDecoration(
                    color: i <= index ? colors.actionEmphasis : colors.divider,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          label,
          style: AppTextStyles.secondary.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 6),
        Semantics(
          header: true,
          child: Text(
            _stepTitles[step]!,
            style: AppTextStyles.screenTitle.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// spec 025 FR-C2: where the database lives, then its name.
class _NameStep extends StatelessWidget {
  const _NameStep({
    required this.controller,
    required this.enabled,
    required this.error,
    required this.fileName,
    required this.source,
    required this.account,
    required this.connecting,
    required this.connectError,
    required this.onSelectDevice,
    required this.onSelectRemote,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? error;
  final String fileName;
  final DatabaseSource source;
  final StorageAccountSummary? account;
  final bool connecting;
  final String? connectError;
  final VoidCallback onSelectDevice;
  final VoidCallback onSelectRemote;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final selectable = enabled && !connecting;
    final remoteSubtitle = !supportsRemoteSource
        ? 'Not available in the browser'
        : connecting
        ? 'Connecting…'
        : account == null
        ? 'Not connected'
        : account!.email ?? account!.displayLabel;
    final showConnect = supportsRemoteSource && account == null;
    final check = KvIcon(
      glyph: AppGlyph.check,
      size: 18,
      color: colors.attentionText,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        kvFieldLabel('Where it lives', colors),
        SourceOptionCard(
          onSheet: false,
          glyph: databaseSourceGlyph(remote: false),
          title: 'This device',
          subtitle: persistsDatabases
              ? "Stays in Custode's storage"
              : 'Downloaded to your device',
          selected: source == DatabaseSource.device,
          trailing: source == DatabaseSource.device ? check : const SizedBox(),
          onTap: selectable ? onSelectDevice : null,
        ),
        const SizedBox(height: 8),
        SourceOptionCard(
          onSheet: false,
          glyph: databaseSourceGlyph(remote: true),
          title: 'Google Drive',
          subtitle: remoteSubtitle,
          selected: source == DatabaseSource.remote,
          actionLabel: showConnect ? 'Connect' : null,
          trailing: showConnect
              ? null
              : source == DatabaseSource.remote
              ? check
              : const SizedBox(),
          onTap: supportsRemoteSource && selectable ? onSelectRemote : null,
        ),
        if (connectError != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              connectError!,
              style: AppTextStyles.secondary.copyWith(
                color: colors.attentionText,
              ),
            ),
          ),
        ],
        const SizedBox(height: 22),
        kvFieldLabel('Database name', colors),
        TextFormField(
          controller: controller,
          enabled: enabled,
          autocorrect: false,
          onChanged: (_) => onChanged(),
          style: AppTextStyles.fieldValue.copyWith(color: colors.textPrimary),
          decoration: kvFieldDecoration(
            colors,
            hint: 'Database name',
            errorText: error,
          ),
        ),
        if (error == null) ...[
          const SizedBox(height: 7),
          Text(
            'Saved as $fileName',
            style: AppTextStyles.secondary.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// spec 025 FR-C3: the single credentials step — optional password (015
/// FR-3), the key-file row (015 FR-4 as row plus sheet), biometrics.
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
    required this.keyFileMode,
    required this.keyFilePath,
    required this.keyFileName,
    required this.onChooseKeyFile,
    required this.onClearKeyFile,
    required this.biometricEnabled,
    required this.biometricUnavailable,
    required this.onBiometricChanged,
    required this.errorMessage,
  });

  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool passwordVisible;
  final bool confirmVisible;
  final bool enabled;
  final VoidCallback onTogglePassword;
  final VoidCallback onToggleConfirm;
  final VoidCallback onChanged;
  final KeyFileMode keyFileMode;
  final String? keyFilePath;
  final String? keyFileName;
  final VoidCallback onChooseKeyFile;
  final VoidCallback onClearKeyFile;
  final bool biometricEnabled;
  final bool biometricUnavailable;
  final ValueChanged<bool> onBiometricChanged;
  final String? errorMessage;

  Widget _visibilityToggle(bool visible, VoidCallback onPressed, String what) =>
      KvCircleIconButton(
        glyph: visible ? AppGlyph.eyeOff : AppGlyph.eye,
        tooltip: visible ? 'Hide $what' : 'Show $what',
        nested: true,
        size: 44,
        iconSize: 18,
        onPressed: enabled ? onPressed : null,
      );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final hasPassword = passwordCtrl.text.isNotEmpty;
    final mismatch =
        confirmCtrl.text.isNotEmpty && confirmCtrl.text != passwordCtrl.text;
    final biometricOn = biometricEnabled && !biometricUnavailable;
    final biometricTap = enabled && !biometricUnavailable
        ? () => onBiometricChanged(!biometricOn)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        kvFieldLabel('Master password', colors),
        TextFormField(
          controller: passwordCtrl,
          enabled: enabled,
          obscureText: !passwordVisible,
          autocorrect: false,
          enableSuggestions: false,
          style: AppTextStyles.secret.copyWith(color: colors.textPrimary),
          onChanged: (_) => onChanged(),
          decoration: kvFieldDecoration(
            colors,
            hint: 'Master password',
            suffixIcon: _visibilityToggle(
              passwordVisible,
              onTogglePassword,
              'password',
            ),
          ),
        ),
        // spec 015 FR-3: strength meter and confirmation only exist for a
        // non-empty password.
        if (hasPassword) ...[
          const SizedBox(height: 10),
          StrengthBar(assessment: evaluatePasswordStrength(passwordCtrl.text)),
          const SizedBox(height: 18),
          kvFieldLabel('Confirm password', colors),
          TextFormField(
            controller: confirmCtrl,
            enabled: enabled,
            obscureText: !confirmVisible,
            autocorrect: false,
            enableSuggestions: false,
            style: AppTextStyles.secret.copyWith(color: colors.textPrimary),
            onChanged: (_) => onChanged(),
            decoration: kvFieldDecoration(
              colors,
              hint: 'Confirm password',
              errorText: mismatch ? 'Passwords do not match.' : null,
              suffixIcon: _visibilityToggle(
                confirmVisible,
                onToggleConfirm,
                'confirmation',
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        KeyFileRow(
          path: keyFilePath,
          name: keyFileName,
          emptySubtitle: 'Optional second factor',
          onPick: enabled ? onChooseKeyFile : () {},
          onClear: enabled ? onClearKeyFile : () {},
        ),
        if (keyFileMode == KeyFileMode.generate) ...[
          const SizedBox(height: 8),
          // spec 015 FR-13: permanent inline backup warning on the generated
          // key. No modal, no checkbox.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colors.attentionTint,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KvIcon(
                  glyph: AppGlyph.warning,
                  size: 17,
                  color: colors.attentionText,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Back up the generated key file: losing it makes the '
                    'database inaccessible.',
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.attentionText,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        KvListRow(
          title: 'Unlock with biometrics',
          subtitle: biometricUnavailable
              ? 'Not available on this device'
              : null,
          radius: 22,
          leading: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.ground,
              shape: BoxShape.circle,
            ),
            child: KvIcon(
              glyph: AppGlyph.fingerprint,
              size: 18,
              color: colors.textSecondary,
            ),
          ),
          trailing: KvSwitch(
            value: biometricOn,
            semanticLabel: 'Unlock with biometrics',
            onChanged: biometricTap == null ? null : onBiometricChanged,
          ),
          onTap: biometricTap,
        ),
        if (!persistsDatabases) ...[
          const SizedBox(height: 12),
          Text(
            'The web app keeps nothing: the database and key file are '
            'only downloaded to your device. Reloading the page loses '
            'this draft and the key.',
            style: AppTextStyles.secondary.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
        if (errorMessage != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              errorMessage!,
              style: AppTextStyles.secondary.copyWith(
                color: colors.attentionText,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The two ways to get a key file (spec 025 FR-C3).
class _KeyChoiceSheet extends StatelessWidget {
  const _KeyChoiceSheet();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              'Add a key file',
              style: AppTextStyles.sheetTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          SourceOptionCard(
            glyph: AppGlyph.folderOpen,
            title: 'Choose a file',
            subtitle: 'Use a key file you already have',
            onTap: () => Navigator.of(context).pop(KeyFileMode.select),
          ),
          const SizedBox(height: 8),
          SourceOptionCard(
            glyph: AppGlyph.magic,
            title: 'Generate a new key file',
            subtitle: 'Created with the database',
            onTap: () => Navigator.of(context).pop(KeyFileMode.generate),
          ),
        ],
      ),
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
          KvSecondaryPillButton(
            onPressed: onDownloadKeyFile,
            label: keyDownloadRequested
                ? 'Download key file again'
                : 'Download key file',
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
        KvSecondaryPillButton(
          onPressed: databaseEnabled ? onDownloadDatabase : null,
          label: 'Download database',
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
