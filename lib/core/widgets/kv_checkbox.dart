import 'package:flutter/material.dart';

import '../theme/app_glyph.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';
import 'kv_icon.dart';

/// Generator character-set row (PIXEL_SPEC "Switch/radio/checkbox" +
/// "Generator" anchors): 22 px checkbox, radius 8, `accent-300` fill with
/// an `accent-900` tick (stroke-width 3.2) when checked; label 14, row gap
/// handled by the caller (`Column` with `SizedBox` separators).
class KvCheckboxRow extends StatelessWidget {
  const KvCheckboxRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: value ? colors.actionFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: value
                      ? null
                      : Border.all(color: colors.divider, width: 1.5),
                ),
                child: value
                    ? KvIcon(
                        glyph: AppGlyph.check,
                        size: 14,
                        color: colors.actionText,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.fieldValue.copyWith(
                    fontSize: 14,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
