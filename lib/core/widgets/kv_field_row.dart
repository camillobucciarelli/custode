import 'package:flutter/material.dart';

import '../theme/app_radii.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';
import 'kv_icon.dart';
import '../theme/app_glyph.dart';

/// Copyable detail-screen field row (PIXEL_SPEC "Field row"): radius 22,
/// padding 13/16, label 11 uppercase `neutral-600`, value 15, a 36-circle
/// copy button. Tapping anywhere on the row also copies, matching the
/// existing entry-detail tap-to-copy affordance.
class KvFieldRow extends StatelessWidget {
  const KvFieldRow({
    super.key,
    required this.label,
    this.value,
    this.valueWidget,
    this.valueColor,
    this.onCopy,
    this.trailing,
    this.backgroundColor,
    this.labelColor,
    this.maxLines = 1,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.showCopyButton = true,
  });

  final String label;
  final String? value;
  final Widget? valueWidget;
  final Color? valueColor;
  final VoidCallback? onCopy;
  final Widget? trailing;
  final Color? backgroundColor;
  final Color? labelColor;
  final int? maxLines;
  final CrossAxisAlignment crossAxisAlignment;

  /// When false, the row is still tap-to-copy (if [onCopy] is set) but does
  /// not render the visible 36-circle copy button — matches the mock's
  /// Notes row, which is copyable by tap but has no trailing glyph.
  final bool showCopyButton;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: backgroundColor ?? colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.row),
      ),
      child: Row(
        crossAxisAlignment: crossAxisAlignment,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: AppTextStyles.labelUpper.copyWith(
                    color: labelColor ?? colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                valueWidget ??
                    Text(
                      value ?? '',
                      maxLines: maxLines,
                      overflow: maxLines == null ? null : TextOverflow.ellipsis,
                      style: AppTextStyles.fieldValue.copyWith(
                        color: valueColor ?? colors.textPrimary,
                      ),
                    ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          if (trailing == null && onCopy != null && showCopyButton) ...[
            const SizedBox(width: 8),
            _CopyButton(onPressed: onCopy!, colors: colors),
          ],
        ],
      ),
    );

    if (onCopy == null || trailing != null) {
      return content;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onCopy,
        borderRadius: BorderRadius.circular(AppRadii.row),
        child: content,
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.onPressed, required this.colors});

  final VoidCallback onPressed;
  final CustodeColors colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        tooltip: 'Copy',
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: colors.surfaceNested,
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        icon: KvIcon(glyph: AppGlyph.copy, size: 17, color: colors.iconNeutral),
      ),
    );
  }
}
