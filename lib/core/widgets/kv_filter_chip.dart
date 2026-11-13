import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radii.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';
import 'app_focus_ring.dart';

/// spec-019 T016 — one chip of the phone's folder row (FR-014).
///
/// The chip is a filter, not a navigation control: the first chip is `Folders`
/// and opens the sheet, the rest select a top-level folder
/// (`decisions-folder-management.md`).
///
/// PIXEL_SPEC "Chip / inline action": height 34–40, radius 999, `neutral-200`
/// ground, 12.5–13 / 600 label. The visible pill stays inside that range and
/// the **target** is padded out to 44 (Constitution V), so touch does not have
/// to be as precise as the design is small.
class KvFilterChip extends StatefulWidget {
  const KvFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  /// Shown after the label when present, as the folder column does.
  final int? count;

  static const double minTarget = 44;
  static const double chipHeight = 36;

  @override
  State<KvFilterChip> createState() => _KvFilterChipState();
}

class _KvFilterChipState extends State<KvFilterChip> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final selected = widget.selected;
    final radius = BorderRadius.circular(AppRadii.pill);

    final chip = Container(
      height: KvFilterChip.chipHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // The same selected recipe as the folder tree's rows (FR-006k): one
        // vault, one way of looking chosen.
        color: selected ? AppColors.accent200 : colors.surface,
        borderRadius: radius,
        border: Border.all(
          color: selected ? AppColors.accent400 : Colors.transparent,
        ),
      ),
      // Label and count are two Texts, not one interpolated string: the count
      // is a secondary detail with its own weight, and a caller looking for
      // the folder by name should find the name.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.meta.copyWith(
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.accent800 : colors.textPrimary,
            ),
          ),
          if (widget.count != null) ...[
            const SizedBox(width: 6),
            Text(
              '${widget.count}',
              style: AppTextStyles.meta.copyWith(
                color: selected ? AppColors.accent800 : colors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );

    return Semantics(
      selected: selected,
      button: true,
      child: SizedBox(
        height: KvFilterChip.minTarget,
        child: AppFocusRing(
          focusNode: _focusNode,
          borderRadius: radius,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              focusNode: _focusNode,
              onTap: widget.onPressed,
              borderRadius: radius,
              child: Center(child: chip),
            ),
          ),
        ),
      ),
    );
  }
}
