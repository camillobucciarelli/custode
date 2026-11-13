import 'package:flutter/material.dart';

import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/theme/custode_colors.dart';

/// FR-3: Drive picker loading state — row-shaped skeletons, never a
/// spinner.
class DrivePickerSkeletonRow extends StatelessWidget {
  const DrivePickerSkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Container(
      height: 62,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colors.surfaceNested,
              borderRadius: BorderRadius.circular(AppRadii.iconSquare),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 12,
                  width: 140,
                  decoration: BoxDecoration(
                    color: colors.surfaceNested,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: 90,
                  decoration: BoxDecoration(
                    color: colors.surfaceNested,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
