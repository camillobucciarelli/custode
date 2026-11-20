import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../domain/models/remote_file.dart';
import '../database/drive_picker_skeleton.dart';

/// The one remote `.kdbx` list: optional [header], search, then skeleton
/// rows while loading, the typed error with its Reconnect/Retry action, an
/// empty state, or one row per file (spec 025 FR-O3). Shared by the Open
/// flow's Drive sheet and the vault's "link to a Drive file" picker; each
/// caller owns its data and builds its own [RemoteFileRow]s through
/// [rowBuilder].
///
/// Needs a bounded height: the file list scrolls inside it.
class RemoteFileList extends StatelessWidget {
  const RemoteFileList({
    super.key,
    required this.files,
    required this.isLoading,
    required this.rowBuilder,
    required this.onQueryChanged,
    this.errorMessage,
    this.reconnectRequired = false,
    this.isReconnecting = false,
    this.onReconnect,
    this.header,
    this.emptyMessage = 'No .kdbx files found.',
    this.emptyAction,
    this.horizontalPadding = 20,
  });

  final List<RemoteFile> files;
  final bool isLoading;
  final Widget Function(BuildContext context, RemoteFile file) rowBuilder;
  final ValueChanged<String> onQueryChanged;

  /// Safe, already-mapped message. Non-null switches the body to the error
  /// surface.
  final String? errorMessage;
  final bool reconnectRequired;
  final bool isReconnecting;
  final VoidCallback? onReconnect;

  /// Account line above the search field.
  final Widget? header;
  final String emptyMessage;
  final Widget? emptyAction;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final side = EdgeInsets.symmetric(horizontal: horizontalPadding);
    final error = errorMessage;

    final Widget body;
    if (error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                reconnectRequired
                    ? 'Google authorization expired'
                    : 'Unable to connect to Google Drive',
                textAlign: TextAlign.center,
                style: AppTextStyles.panelTitleLarge.copyWith(
                  color: colors.attentionText,
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.body.copyWith(
                    color: colors.attentionText,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Semantics(
                container: true,
                button: true,
                enabled: !isReconnecting,
                label: reconnectRequired
                    ? 'Reconnect Google Drive'
                    : 'Retry Google Drive connection',
                child: ExcludeSemantics(
                  child: KvPillButton(
                    label: isReconnecting
                        ? 'Reconnecting...'
                        : reconnectRequired
                        ? 'Reconnect'
                        : 'Retry',
                    onPressed: isReconnecting ? null : onReconnect,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (isLoading) {
      body = Padding(
        padding: side,
        child: const Column(
          children: [
            DrivePickerSkeletonRow(),
            DrivePickerSkeletonRow(),
            DrivePickerSkeletonRow(),
          ],
        ),
      );
    } else if (files.isEmpty) {
      body = Center(
        child: Padding(
          padding: side,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                emptyMessage,
                textAlign: TextAlign.center,
                style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              ),
              if (emptyAction != null) ...[
                const SizedBox(height: 16),
                emptyAction!,
              ],
            ],
          ),
        ),
      );
    } else {
      body = ListView.separated(
        padding: side,
        itemCount: files.length,
        separatorBuilder: (_, _) => const SizedBox(height: 9),
        itemBuilder: (context, index) => rowBuilder(context, files[index]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null) Padding(padding: side, child: header),
        Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            16,
            horizontalPadding,
            12,
          ),
          child: TextField(
            enabled: !isReconnecting,
            decoration: InputDecoration(
              hintText: 'Search .kdbx files',
              prefixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: KvIcon(
                  glyph: AppGlyph.search,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ),
            ),
            onChanged: onQueryChanged,
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}
