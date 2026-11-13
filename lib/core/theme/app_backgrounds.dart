import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppBackgrounds {
  AppBackgrounds._();

  static LinearGradient gradient(BuildContext context) {
    // Compatibility-only. Organic surfaces use CustodeColors.ground directly.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark
        ? [AppColors.darkGradientFrom, AppColors.darkGradientTo]
        : [AppColors.lightGradientFrom, AppColors.lightGradientTo];
    final stops = isDark ? const [0.0, 1.0] : const [0.0, 1.0];

    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
      stops: stops,
    );
  }
}
