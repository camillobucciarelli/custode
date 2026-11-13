import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_icons.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../domain/utils/password_strength.dart';

/// Entry-detail strength strip (spec-004 FR-1/FR-4, PIXEL_SPEC "Entry
/// detail"): radius 20, padding 12/16, 32-circle glyph, text 12.5. The
/// `.warning` variant (FR-4) additionally shows the 4-notch strength bar,
/// the reuse count and a "Generate a new one" chip that opens the
/// generator pre-filled with the entry's constraints.
class StrengthStrip extends StatelessWidget {
  const StrengthStrip.normal({
    super.key,
    required this.assessment,
    required this.changedAgoLabel,
  }) : isWarning = false,
       reusedByCount = 0,
       onGenerateNew = null;

  const StrengthStrip.warning({
    super.key,
    required this.assessment,
    required this.changedAgoLabel,
    required this.reusedByCount,
    required this.onGenerateNew,
  }) : isWarning = true;

  final PasswordStrengthAssessment assessment;
  final String changedAgoLabel;
  final bool isWarning;
  final int reusedByCount;
  final VoidCallback? onGenerateNew;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    if (!isWarning) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: colors.positiveTint,
          // 2026-08-31: the tint alone melted into the ground — a border in
          // the palette's fill shade keeps the box legible.
          border: Border.all(color: colors.positiveFill),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.positiveFill,
                shape: BoxShape.circle,
              ),
              child: Icon(
                AppIcons.shield,
                size: 17,
                color: colors.positiveText,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: AppTextStyles.secondary.copyWith(
                    color: colors.positiveText,
                  ),
                  children: [
                    TextSpan(
                      text: assessment.label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: ' · $changedAgoLabel'),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final reuseText = reusedByCount > 0
        ? ", and it's also used by $reusedByCount other item${reusedByCount == 1 ? '' : 's'}"
        : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.attentionTint,
        // Same rule as the normal strip: bordered in the fill shade.
        border: Border.all(color: colors.actionFill),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.actionFill,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  AppIcons.warning,
                  size: 17,
                  color: colors.actionText,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.attentionText,
                    ),
                    children: [
                      TextSpan(
                        text: '${assessment.label} password',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: '$reuseText. Last $changedAgoLabel.'),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _StrengthNotches(level: assessment.level, colors: colors),
          const SizedBox(height: 10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onGenerateNew,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: colors.actionFill,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      AppIcons.autorenew,
                      size: 16,
                      color: colors.actionText,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      'Generate a new one',
                      style: AppTextStyles.secondary.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.actionText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StrengthNotches extends StatelessWidget {
  const _StrengthNotches({required this.level, required this.colors});

  final PasswordStrengthLevel level;
  final CustodeColors colors;

  @override
  Widget build(BuildContext context) {
    final filled = switch (level) {
      PasswordStrengthLevel.weak => 1,
      PasswordStrengthLevel.fair => 2,
      PasswordStrengthLevel.good => 3,
      PasswordStrengthLevel.strong => 4,
    };
    final activeColor = level == PasswordStrengthLevel.strong
        ? colors.positiveFill
        : AppColors.accent400;

    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                color: i < filled ? activeColor : colors.actionFill,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// "changed 4 months ago" / "not changed yet" style label from a nullable
/// timestamp. Kept intentionally coarse (days/months/years) — this is
/// caption copy, not a precise duration.
String describeTimeAgo(DateTime? value, DateTime now) {
  if (value == null) {
    return 'not changed yet';
  }
  final days = now.difference(value).inDays;
  if (days < 1) {
    return 'changed today';
  }
  if (days < 30) {
    return 'changed $days day${days == 1 ? '' : 's'} ago';
  }
  if (days < 365) {
    final months = (days / 30).floor();
    return 'changed $months month${months == 1 ? '' : 's'} ago';
  }
  final years = (days / 365).floor();
  return 'changed $years year${years == 1 ? '' : 's'} ago';
}
