import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';

/// PIXEL_SPEC "Tags / badges": padding 3/9, radius 999, size 10-11/600.
/// Reused across spec-005's remote-file "linked" warning, the duplicates
/// screen's Keep/Merge tags, and the (out-of-scope) conflict "differs" tag.
enum KvTagVariant { attention, positive, neutral, meta }

class KvTag extends StatelessWidget {
  const KvTag({
    super.key,
    required this.label,
    this.variant = KvTagVariant.neutral,
  });

  final String label;
  final KvTagVariant variant;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final (background, foreground, border) = switch (variant) {
      KvTagVariant.attention => (
        colors.attentionTint,
        colors.attentionText,
        null,
      ),
      KvTagVariant.positive => (colors.positiveTint, colors.positiveText, null),
      KvTagVariant.neutral => (colors.surface, colors.textPrimary, null),
      KvTagVariant.meta => (
        Colors.transparent,
        colors.textSecondary,
        colors.divider,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        label,
        style: AppTextStyles.labelMicro.copyWith(color: foreground),
      ),
    );
  }
}
