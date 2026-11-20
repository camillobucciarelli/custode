import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../../../injection_container.dart' as di;
import '../../../domain/models/cloud_storage_error.dart';
import '../../../domain/models/database_sync_mapping.dart';
import '../../../domain/models/remote_file.dart';
import '../../../domain/models/remote_file_selection_data.dart';
import '../../../domain/models/storage_account_summary.dart';
import '../../../domain/repositories/database_sync_repository.dart';
import '../../coordinators/database_session_coordinator.dart';
import '../../utils/cloud_storage_error_presentation.dart';
import '../database/source_option_card.dart';
import 'remote_file_list.dart';
import 'remote_file_row.dart';

/// The only symbol the Open flow knows about the remote file list (spec 025
/// FR-O3): resolves to the chosen file, or null when dismissed. Spec 013
/// swaps this body for the Google Picker without touching callers.
Future<RemoteFile?> pickRemoteFile(BuildContext context) {
  final coordinator = di.sl<DatabaseSessionCoordinator>();
  final syncRepository = di.sl<DatabaseSyncRepository>();
  return KvBottomSheet.show<RemoteFile>(
    context: context,
    builder: (_) => RemoteFilePickerSheet(
      load: coordinator.getRemoteFileSelectionData,
      reconnect: coordinator.reconnectRemoteFileSelectionData,
      switchAccount: coordinator.switchRemoteAccount,
      loadMappings: syncRepository.getAllMappings,
    ),
  );
}

/// Body of the sheet behind [pickRemoteFile]: loads through the injected
/// functions so tests can script every outcome.
class RemoteFilePickerSheet extends StatefulWidget {
  const RemoteFilePickerSheet({
    super.key,
    required this.load,
    required this.reconnect,
    required this.switchAccount,
    this.loadMappings,
  });

  final Future<RemoteFileSelectionData> Function() load;

  /// Reconnect action for an expired or withdrawn Drive grant. The plain load
  /// only connects when the account is signed out, so on mobile, where the
  /// account stays signed in after the scope lapses, repeating it can never
  /// recover; this one forces an interactive re-authorization.
  final Future<RemoteFileSelectionData> Function() reconnect;

  /// Disconnects, then signs in again (spec 025 FR-O4).
  final Future<RemoteFileSelectionData> Function() switchAccount;

  /// Existing mappings, for the `Already added` tag. Best-effort.
  final Future<List<DatabaseSyncMapping>> Function()? loadMappings;

  @override
  State<RemoteFilePickerSheet> createState() => _RemoteFilePickerSheetState();
}

class _RemoteFilePickerSheetState extends State<RemoteFilePickerSheet> {
  RemoteFileSelectionData? _data;
  Object? _error;
  bool _isLoading = false;
  String _query = '';
  List<DatabaseSyncMapping> _mappings = const [];

  @override
  void initState() {
    super.initState();
    _run(widget.load);
    _loadMappings();
  }

  Future<void> _loadMappings() async {
    try {
      final mappings = await widget.loadMappings?.call();
      if (!mounted || mappings == null) return;
      setState(() => _mappings = mappings);
    } catch (_) {
      // The tag is a hint; a failure must never block choosing a file.
    }
  }

  Future<void> _run(Future<RemoteFileSelectionData> Function() loader) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      final data = await loader();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _error = e;
        _isLoading = false;
      });
    }
  }

  /// spec 010 T105: remote identity is the `(providerId, id)` tuple.
  bool _isAlreadyAdded(RemoteFile file) => _mappings.any(
    (mapping) =>
        mapping.pointsAt(providerId: file.providerId, remoteFileId: file.id),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final data = _data;
    final error = _error;
    final requiresReconnect =
        error != null && isCloudAuthorizationRequired(error);
    // ponytail: the list is `.kdbx` files only, so filtering by name here is
    // enough; the Google Picker (spec 013) replaces the whole listing.
    final needle = _query.trim().toLowerCase();
    final files = data == null
        ? const <RemoteFile>[]
        : data.files
              .where((file) => file.name.toLowerCase().contains(needle))
              .toList(growable: false);
    final height = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      300.0,
      560.0,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Semantics(
              header: true,
              child: Text(
                'Open from Google Drive',
                style: AppTextStyles.sheetTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: height,
            child: RemoteFileList(
              horizontalPadding: 0,
              files: files,
              isLoading: _isLoading,
              errorMessage: error == null ? null : driveOpenErrorMessage(error),
              reconnectRequired: requiresReconnect,
              isReconnecting: _isLoading && error != null,
              onReconnect: () =>
                  _run(requiresReconnect ? widget.reconnect : widget.load),
              onQueryChanged: (value) => setState(() => _query = value),
              header: data == null || _isLoading
                  ? null
                  : _AccountHeader(
                      account: data.account,
                      onSwitch: () => _run(widget.switchAccount),
                    ),
              emptyMessage:
                  'No .kdbx files found for ${data?.account.email ?? data?.account.displayLabel ?? 'this account'}.',
              emptyAction: KvSecondaryPillButton(
                label: 'Switch account',
                onPressed: () => _run(widget.switchAccount),
              ),
              rowBuilder: (context, file) => RemoteFileRow(
                file: file,
                selected: false,
                isLinkedElsewhere: false,
                alreadyAdded: _isAlreadyAdded(file),
                showChevron: true,
                background: colors.surfaceNested,
                onTap: () => Navigator.of(context).pop(file),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const SourcePrivacyLine(),
        ],
      ),
    );
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.account, required this.onSwitch});

  final StorageAccountSummary account;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final label = account.email ?? account.displayLabel;
    return Row(
      children: [
        ExcludeSemantics(
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.accent300,
              shape: BoxShape.circle,
            ),
            child: Text(
              label.characters.first.toUpperCase(),
              style: AppTextStyles.rowTitle.copyWith(
                color: AppColors.accent900,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                // Sentence case (copy contract): `labelUpper` is the label
                // style, and a screen reader spells an all-caps literal.
                'Google account',
                style: AppTextStyles.labelUpper.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.rowTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(44, 44),
            foregroundColor: colors.linkText,
          ),
          onPressed: onSwitch,
          child: const Text('Switch account'),
        ),
      ],
    );
  }
}

/// Preserves the former dialog's exact granular OAuth error copy (C-3-adjacent:
/// still never renders a raw `e.toString()` for a recognized failure).
@visibleForTesting
String driveOpenErrorMessage(Object error) {
  // spec 010: typed provider failures map by code and never render
  // `toString()`; the substring branches below serve untyped exceptions.
  if (error is CloudStorageException) {
    return switch (error.code) {
      CloudStorageErrorCode.cancelled => 'Google sign-in was cancelled during authorization. Please try again and grant Drive permissions.',
      CloudStorageErrorCode.forbidden => 'Google Drive permission was not granted. Enable Drive access and try again.',
      CloudStorageErrorCode.authorizationRequired => 'Google Drive session expired or unavailable. Use Reconnect below to sign in again.',
      _ => error.safeMessage,
    };
  }
  final message = error.toString();
  final normalized = message.toLowerCase();

  if (normalized.contains('google sign-in cancelled')) {
    return 'Google sign-in was cancelled during authorization. Please try again and grant Drive permissions.';
  }
  if (normalized.contains(
    'google account selected, but drive permission was not granted',
  )) {
    return 'Account selected, but Drive permission was not granted. Please try again and accept the requested permissions.';
  }
  if (normalized.contains('android google sign-in is not configured')) {
    return 'Android Google Sign-In is not configured. Check GOOGLE_WEB_CLIENT_ID.';
  }
  if (normalized.contains('ios google sign-in is not configured')) {
    return 'iOS Google Sign-In is not configured. Check GOOGLE_IOS_CLIENT_ID.';
  }
  if (normalized.contains('desktop oauth is not configured')) {
    return 'Desktop Google Sign-In is not configured. Check GOOGLE_DESKTOP_CLIENT_ID and GOOGLE_DESKTOP_CLIENT_SECRET.';
  }
  if (normalized.contains('unable to open system browser')) {
    return 'Unable to open the system browser for Google sign-in. Check your default browser and try again.';
  }
  if (normalized.contains('google authentication timeout')) {
    return 'Google sign-in timed out. Complete authorization in your browser and try again.';
  }
  if (normalized.contains('authorization was not granted')) {
    return 'Google Drive permission was not granted. Enable Drive access and try again.';
  }
  if (normalized.contains('authorization needs to be renewed') ||
      normalized.contains('authorization is outdated') ||
      normalized.contains('google account not connected')) {
    return 'Google Drive session expired or unavailable. Use Reconnect below to sign in again.';
  }
  if (normalized.contains('google sign-in failed')) {
    // Unrecognized Google failure: the platform code and description are the
    // only actionable detail, so show them instead of a generic sentence.
    return 'Unable to open database from Google Drive. '
        '${message.replaceFirst(RegExp(r'^Exception:\s*'), '')}';
  }
  return 'Unable to open database from Google Drive.';
}
