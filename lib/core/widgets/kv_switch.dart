import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/custode_colors.dart';

/// Toggle switch (PIXEL_SPEC "Switch / radio / checkbox"): 44 x 26, radius
/// 999, knob 20 with 3 px inset; on `accent-2-400`, off `neutral-300`.
/// spec-005's second real use (auto-sync toggle, CSV "avoid duplicates"
/// toggle) — first appearance in the design system as a dedicated widget.
class KvSwitch extends StatelessWidget {
  const KvSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Semantics(
      label: semanticLabel,
      toggled: value,
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
          width: 44,
          height: 26,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? colors.positiveFill : AppColors.neutral300,
            borderRadius: BorderRadius.circular(999),
          ),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: colors.ground,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
