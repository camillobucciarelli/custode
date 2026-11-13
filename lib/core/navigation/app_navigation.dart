import 'package:material_ui/material_ui.dart';

class AppNavigation {
  AppNavigation._();

  static Future<T?> pushFadeReplacement<T extends Object?, TO extends Object?>(
    BuildContext context,
    Widget page,
  ) {
    return Navigator.of(context).pushReplacement<T, TO>(
      PageRouteBuilder<T>(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, _, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(opacity: curve, child: child);
        },
      ),
    );
  }

  static Future<T?> pushFade<T extends Object?>(
    BuildContext context,
    Widget page,
  ) {
    return Navigator.of(context).push<T>(
      PageRouteBuilder<T>(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, _, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(opacity: curve, child: child);
        },
      ),
    );
  }
}
