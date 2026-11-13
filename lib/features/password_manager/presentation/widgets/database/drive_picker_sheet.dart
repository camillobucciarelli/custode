import 'package:flutter/material.dart';

import '../../../../../core/theme/app_icons.dart';
import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../domain/models/cloud_storage_error.dart';
import '../../../domain/models/remote_file_selection_data.dart';
import '../../../domain/models/storage_account_summary.dart';
import '../../../domain/models/remote_file.dart';
import '../../utils/cloud_storage_error_presentation.dart';
import 'drive_picker_skeleton.dart';

class DrivePickerSheetResult {
  const DrivePickerSheetResult.file(this.file)
    : createAndUpload = false,
      switchAccount = false;

  const DrivePickerSheetResult.createAndUpload()
    : file = null,
      createAndUpload = true,
      switchAccount = false;

  const DrivePickerSheetResult.switchAccount()
    : file = null,
      createAndUpload = false,
      switchAccount = true;

  final RemoteFile? file;
  final bool createAndUpload;
  final bool switchAccount;
}

/// FR-3: Drive picker — skeleton loading, then either the `.kdbx` file list
/// or the empty state naming the connected account (C-2) with create+upload
/// / switch-account actions.
Future<DrivePickerSheetResult?> showDrivePickerSheet(
  BuildContext context, {
  required Future<RemoteFileSelectionData> Function() loadPickerData,
  Future<RemoteFileSelectionData> Function()? reconnectPickerData,
}) {
  return KvBottomSheet.show<DrivePickerSheetResult>(
    context: context,
    builder: (_) => _DrivePickerSheetContent(
      loadPickerData: loadPickerData,
      reconnectPickerData: reconnectPickerData,
    ),
  );
}

/// Preserves the former dialog's exact granular OAuth error copy (moved
/// here from `database_selection_screen.dart`, C-3-adjacent: still never
/// renders a raw `e.toString()` for a recognized failure).
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

class _DrivePickerSheetContent extends StatefulWidget {
  const _DrivePickerSheetContent({
    required this.loadPickerData,
    this.reconnectPickerData,
  });

  final Future<RemoteFileSelectionData> Function() loadPickerData;

  /// Reconnect action for an expired or withdrawn Drive grant. The plain load
  /// only connects when the account is signed out, so on mobile — where the
  /// account stays signed in after the scope lapses — repeating it can never
  /// recover; this one forces an interactive re-authorization.
  final Future<RemoteFileSelectionData> Function()? reconnectPickerData;

  @override
  State<_DrivePickerSheetContent> createState() =>
      _DrivePickerSheetContentState();
}

class _DrivePickerSheetContentState extends State<_DrivePickerSheetContent> {
  RemoteFileSelectionData? _data;
  Object? _error;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reconnect = false}) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
    });
    try {
      final loader = reconnect
          ? (widget.reconnectPickerData ?? widget.loadPickerData)
          : widget.loadPickerData;
      final data = await loader();
      if (!mounted) return;
      setState(() {
        _data = data;
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final data = _data;
    final error = _error;
    final requiresReconnect =
        error != null && isCloudAuthorizationRequired(error);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Open from Google Drive',
            textAlign: TextAlign.center,
            style: AppTextStyles.sheetTitleLarge.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 14),
          if (error != null) ...[
            Text(
              requiresReconnect
                  ? 'Google authorization expired'
                  : 'Unable to connect to Google Drive',
              textAlign: TextAlign.center,
              style: AppTextStyles.panelTitleLarge.copyWith(
                color: colors.attentionText,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              driveOpenErrorMessage(error),
              textAlign: TextAlign.center,
              style: AppTextStyles.body.copyWith(color: colors.attentionText),
            ),
            const SizedBox(height: 14),
            Semantics(
              container: true,
              button: true,
              enabled: !_isLoading,
              label: requiresReconnect
                  ? 'Reconnect Google Drive'
                  : 'Retry Google Drive connection',
              child: ExcludeSemantics(
                child: KvPillButton(
                  label: _isLoading
                      ? 'Connecting...'
                      : requiresReconnect
                      ? 'Reconnect'
                      : 'Retry',
                  onPressed: _isLoading
                      ? null
                      : () => _load(reconnect: requiresReconnect),
                ),
              ),
            ),
          ] else if (_isLoading || data == null) ...[
            const DrivePickerSkeletonRow(),
            const DrivePickerSkeletonRow(),
            const DrivePickerSkeletonRow(),
          ] else if (data.files.isEmpty)
            _DriveEmptyState(account: data.account)
          else
            ...data.files.map(
              (file) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadii.card),
                  onTap: () =>
                      Navigator.of(context)
                          .pop(DrivePickerSheetResult.file(file)),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(AppRadii.card),
                    ),
                    child: Row(
                      children: [
                        Icon(AppIcons.file, color: colors.iconNeutral),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.rowTitle.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        Icon(
                          AppIcons.chevronRight,
                          color: colors.iconNeutral,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DriveEmptyState extends StatelessWidget {
  const _DriveEmptyState({required this.account});

  final StorageAccountSummary account;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final label = account.email ?? account.displayLabel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'No .kdbx files found for $label.',
          textAlign: TextAlign.center,
          style: AppTextStyles.body.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 16),
        KvPillButton(
          label: 'Create & upload a new database',
          onPressed: () =>
              Navigator.of(context)
                  .pop(const DrivePickerSheetResult.createAndUpload()),
        ),
        const SizedBox(height: 10),
        KvSecondaryPillButton(
          label: 'Switch account',
          onPressed: () =>
              Navigator.of(context)
                  .pop(const DrivePickerSheetResult.switchAccount()),
        ),
      ],
    );
  }
}
