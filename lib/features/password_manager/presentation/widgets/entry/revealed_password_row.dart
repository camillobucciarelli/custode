import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_motion.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_icon.dart';

/// Revealed-password row (spec-004 FR-2, PIXEL_SPEC "Entry detail"):
/// `attentionTint` background, monospace 16 with word-break, 4 px countdown
/// bar draining as [remainingFraction] falls. The *bar's* width transition
/// respects `AppMotion`/reduced motion; the underlying 12 s expiry timer
/// (owned by [RevealController], not this widget) is a security control and
/// is never itself disabled by reduced motion.
class RevealedPasswordRow extends StatelessWidget {
  const RevealedPasswordRow({
    super.key,
    required this.password,
    required this.remainingFraction,
    required this.remainingSeconds,
    required this.onHide,
    this.onCopy,
    this.label = 'Password',
    this.hideTooltip = 'Hide password',
  });

  final String password;

  /// spec 023 US1b: a secret custom field reveals through this same row,
  /// under its own key.
  final String label;
  final String hideTooltip;
  final double remainingFraction;
  final int remainingSeconds;
  final VoidCallback onHide;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    // The bar steps once per second (shared ticker, see RevealController's
    // doc comment); this only smooths that per-second step visually and is
    // zeroed under reduced motion. It never affects the 12s expiry itself.
    final barDuration = AppMotion.duration(context, const Duration(seconds: 1));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: colors.attentionTint,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: AppTextStyles.labelUpper.copyWith(
                        color: colors.attentionText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      password,
                      style: AppTextStyles.secretLarge.copyWith(
                        color: colors.attentionText,
                      ),
                    ),
                  ],
                ),
              ),
              // Same order and spacing as the hidden row's trailing
              // buttons (eye, then copy, 8 px apart) so nothing jumps
              // when the password toggles.
              const SizedBox(width: 8),
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  tooltip: hideTooltip,
                  onPressed: onHide,
                  style: IconButton.styleFrom(
                    backgroundColor: colors.actionFill,
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  icon: KvIcon(
                    glyph: AppGlyph.eyeOff,
                    size: 17,
                    color: colors.actionText,
                  ),
                ),
              ),
              if (onCopy != null) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    tooltip: 'Copy',
                    onPressed: onCopy,
                    style: IconButton.styleFrom(
                      backgroundColor: colors.actionFill,
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    icon: KvIcon(
                      glyph: AppGlyph.copy,
                      size: 17,
                      color: colors.actionText,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // Countdown bar with its remaining-seconds label beside it, so
          // the number reads as the bar's value, not part of the field
          // label above.
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    height: 5,
                    // Track vs fill must actually contrast — accent300 on
                    // accent400 read as one solid bar (2026-08-31).
                    color: colors.attentionText.withValues(alpha: 0.15),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TweenAnimationBuilder<double>(
                        duration: barDuration,
                        tween: Tween<double>(
                          end: remainingFraction.clamp(0.0, 1.0),
                        ),
                        builder: (context, factor, child) =>
                            FractionallySizedBox(
                              widthFactor: factor,
                              // Without this the fill laid out at height 0
                              // and the bar showed only its track, always
                              // (2026-08-31).
                              heightFactor: 1,
                              child: child,
                            ),
                        child: const DecoratedBox(
                          // Saturated accent, not attentionText: accent900
                          // read as a grey bar on the light tint
                          // (2026-08-31).
                          decoration: BoxDecoration(color: AppColors.accent500),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${remainingSeconds}s',
                style: AppTextStyles.meta.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.attentionText,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
