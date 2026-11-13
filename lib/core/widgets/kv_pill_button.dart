import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';

/// Primary pill button (PIXEL_SPEC "Buttons" table): height 52, radius 999,
/// `accent-300` fill, `accent-900` text in Caprasimo 15. Extracted on its
/// second real use within spec-003 (welcome actions, unlock primary
/// action, create-flow footer).
class KvPillButton extends StatelessWidget {
  const KvPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = true,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  /// Compact pill: height 46, text 14 (PIXEL_SPEC "Primary compact").
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final height = compact ? 46.0 : 52.0;
    final textStyle = TextStyle(
      fontFamily: AppTextStyles.headingFamily,
      fontWeight: FontWeight.w400,
      fontSize: compact ? 14 : 15,
    );

    final button = ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: colors.actionFill,
        disabledBackgroundColor: colors.surface,
        foregroundColor: colors.actionText,
        disabledForegroundColor: colors.textSecondary,
        minimumSize: Size(44, height),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: const StadiumBorder(),
        elevation: 0,
        textStyle: textStyle,
        animationDuration: AppMotion.button,
      ),
      child: icon == null
          ? Text(label)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Text(label),
              ],
            ),
    );

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Secondary pill: transparent fill, 1 px divider border, text colour.
class KvSecondaryPillButton extends StatelessWidget {
  const KvSecondaryPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final button = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.textPrimary,
        side: BorderSide(color: colors.divider),
        minimumSize: const Size(44, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: const StadiumBorder(),
        textStyle: AppTextStyles.rowTitle,
        animationDuration: AppMotion.button,
      ),
      child: Text(label),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
