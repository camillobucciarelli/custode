import 'package:flutter/material.dart';

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../utils/totp_utils.dart';

/// One-time-code row (spec-004 FR-2, PIXEL_SPEC "Entry detail"): 38-circle
/// showing the remaining seconds (11 / 700), code monospace 21 with
/// +0.16em letter-spacing, `positiveTint` background. The 1 s tick is
/// driven by the caller (the detail screen's shared `Ticker`, per spec-004
/// "TOTP + reveal" — one ticker for both this row and the reveal countdown
/// bar), not by a timer owned here.
class TotpRow extends StatelessWidget {
  const TotpRow({super.key, required this.data, this.onCopy});

  final TotpData data;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onCopy,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            // 2026-08-31: same surface as every other field row — the green
            // tint made this field look like a different kind of thing. The
            // countdown badge keeps the positive palette as the live signal.
            color: colors.surface,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.positiveFill,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${data.remainingSeconds}s',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: colors.positiveText,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'One-time code',
                      style: AppTextStyles.labelUpper.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      data.code,
                      style: AppTextStyles.otpCode.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
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
                      backgroundColor: colors.surfaceNested,
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    icon: KvIcon(
                      glyph: AppGlyph.copy,
                      size: 17,
                      color: colors.iconNeutral,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
