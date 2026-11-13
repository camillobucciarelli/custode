import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/utils/format_bytes.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_circle_icon_button.dart';
import '../../../../../core/widgets/kv_tag.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../domain/models/remote_file.dart';

/// FR-2 / T8: one row per `RemoteFile` — name, `modifiedTime`, `size`,
/// and an already-linked warning `KvTag` when the file id appears in another
/// `DatabaseSyncMapping` ([isLinkedElsewhere], AC4).
///
/// Redesigned 2026-08-31: hover and selection use the vault records recipe
/// (selected = accent-200 fill with accent-400 border, hover = half-alpha
/// selection border on a transparent fill), and linking is a contextual
/// "Link" button that appears on the selected row — the picker no longer
/// carries a detached bottom action bar.
class RemoteFileRow extends StatefulWidget {
  const RemoteFileRow({
    super.key,
    required this.file,
    required this.selected,
    required this.isLinkedElsewhere,
    this.onTap,
    this.onLink,
  });

  final RemoteFile file;
  final bool selected;
  final bool isLinkedElsewhere;
  final VoidCallback? onTap;

  /// Rendered as the trailing "Link" button on the selected row only.
  final VoidCallback? onLink;

  @override
  State<RemoteFileRow> createState() => _RemoteFileRowState();
}

class _RemoteFileRowState extends State<RemoteFileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final selected = widget.selected;
    final file = widget.file;
    final subtitleParts = <String>[
      if (file.modifiedTime != null)
        'Modified ${_formatDate(file.modifiedTime!)}',
      if (file.size != null) formatBytes(file.size!),
      if (widget.isLinkedElsewhere) 'linked to another database',
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? AppColors.accent200 : colors.surface,
        border: Border.all(
          color: selected
              ? AppColors.accent400
              : _hovered
              ? colors.selectionBorder.withValues(alpha: 0.5)
              : Colors.transparent,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onHover: (hovered) => setState(() => _hovered = hovered),
          hoverColor: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.surfaceNested,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: KvIcon(
                    glyph: AppGlyph.fileText,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.rowTitle.copyWith(
                          color: selected
                              ? AppColors.accent800
                              : colors.textPrimary,
                          fontWeight: selected ? FontWeight.w600 : null,
                        ),
                      ),
                      if (subtitleParts.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitleParts.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.secondary.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.isLinkedElsewhere) ...[
                  const SizedBox(width: 8),
                  const KvTag(label: 'Linked', variant: KvTagVariant.attention),
                ],
                if (selected && widget.onLink != null) ...[
                  const SizedBox(width: 10),
                  // Same icon-action recipe as every other list row action.
                  KvCircleIconButton(
                    glyph: AppGlyph.link,
                    tooltip: 'Link this file',
                    filled: true,
                    onPressed: widget.onLink,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final local = value.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}
