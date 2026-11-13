import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';

/// Letter avatar used by entry rows and the entry-detail header (PIXEL_SPEC
/// "List row" / "Entry detail" anchors). Rows use favicons never — letter
/// avatars are the deliberate design (spec-004 "Out of scope").
class KvLetterAvatar extends StatelessWidget {
  const KvLetterAvatar({
    super.key,
    required this.letter,
    this.size = 38,
    this.fontSize,
    this.selected = false,
  });

  final String letter;
  final double size;
  final double? fontSize;

  /// Selected state (PIXEL_SPEC "List row"): `accent-300` on `accent-900`
  /// instead of the default `accent-200` on `accent-900`.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final resolved = letter.isEmpty ? '?' : letter[0].toUpperCase();
    // Mock uses a raw accent-200/accent-900 (dark: accent-800/accent-200)
    // pairing for the default avatar that isn't one of CustodeColors'
    // existing semantic roles (attentionTint is accent-100/accent-800,
    // reused elsewhere for warning tints) — selected reuses actionFill/
    // actionText, which already is accent-300/accent-900 in both themes.
    final background = selected
        ? colors.actionFill
        : (isDark ? AppColors.accent800 : AppColors.accent200);
    final foreground = selected
        ? colors.actionText
        : (isDark ? AppColors.accent200 : AppColors.accent900);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Text(
        resolved,
        style: TextStyle(
          fontFamily: AppTextStyles.headingFamily,
          fontSize: fontSize ?? size * 0.39,
          color: foreground,
        ),
      ),
    );
  }
}
