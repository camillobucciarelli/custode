import 'package:material_ui/material_ui.dart';

class StyledInfoContainer extends StatelessWidget {
  const StyledInfoContainer({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.borderRadius = 10,
    this.backgroundColor,
    this.borderColor,
    this.backgroundAlpha = 0.86,
    this.borderAlpha = 0.75,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? backgroundColor;
  final Color? borderColor;
  final double backgroundAlpha;
  final double borderAlpha;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color:
            backgroundColor ??
            theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: backgroundAlpha,
            ),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color:
              borderColor ??
              theme.colorScheme.outlineVariant.withValues(alpha: borderAlpha),
        ),
      ),
      child: child,
    );
  }
}
