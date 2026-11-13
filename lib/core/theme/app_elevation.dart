import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';

class AppElevation {
  AppElevation._();

  static final sm = <BoxShadow>[
    BoxShadow(
      color: AppColors.neutral900.withValues(alpha: 0.14),
      offset: const Offset(0, 1),
      blurRadius: 2,
    ),
  ];

  static final md = <BoxShadow>[
    BoxShadow(
      color: AppColors.neutral900.withValues(alpha: 0.16),
      offset: const Offset(0, 3),
      blurRadius: 10,
    ),
  ];

  static final lg = <BoxShadow>[
    BoxShadow(
      color: AppColors.neutral900.withValues(alpha: 0.22),
      offset: const Offset(0, 12),
      blurRadius: 32,
    ),
  ];

  static final darkLg = <BoxShadow>[
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.50),
      offset: const Offset(0, 12),
      blurRadius: 32,
    ),
  ];
}
