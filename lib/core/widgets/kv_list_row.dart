import 'package:flutter/material.dart';

import '../theme/app_glyph.dart';
import '../theme/app_radii.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';
import 'kv_icon.dart';

/// Standard list row (PIXEL_SPEC "List row"): radius 22, padding 13/16,
/// leading slot (avatar/square glyph), title 15/600, subtitle 12.5/400
/// `neutral-600`, trailing slot — a chevron by default when [onTap] is set.
///
/// Reused across spec-005's Health categories, Backups actions, and the
/// remote-file picker rows.
class KvListRow extends StatelessWidget {
  const KvListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.radius = AppRadii.row,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    this.backgroundColor,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final resolvedTrailing =
        trailing ??
        (onTap == null
            ? null
            : KvIcon(
                glyph: AppGlyph.chevronRight,
                size: 17,
                color: colors.textTertiary,
              ));

    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? colors.surface,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.rowTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
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
          if (resolvedTrailing != null) ...[
            const SizedBox(width: 8),
            resolvedTrailing,
          ],
        ],
      ),
    );

    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      child: onTap == null
          ? content
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(radius),
                child: content,
              ),
            ),
    );
  }
}
