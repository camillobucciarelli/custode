import 'package:material_ui/material_ui.dart';

class AppFocusRing extends StatelessWidget {
  const AppFocusRing({
    super.key,
    required this.focusNode,
    required this.borderRadius,
    required this.child,
  });

  final FocusNode focusNode;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: focusNode,
    child: child,
    builder: (context, child) => Stack(
      clipBehavior: Clip.none,
      children: [
        child!,
        if (focusNode.hasFocus)
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: CustomPaint(
                  key: const ValueKey('app-focus-ring-painter'),
                  painter: _FocusRingPainter(
                    color: Theme.of(context).focusColor,
                    borderRadius: borderRadius,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _FocusRingPainter extends CustomPainter {
  const _FocusRingPainter({required this.color, required this.borderRadius});

  static const _gap = 2.0;
  static const _strokeWidth = 2.0;

  final Color color;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final control = borderRadius.toRRect(Offset.zero & size);
    final ring = control.inflate(_gap + _strokeWidth / 2);
    canvas.drawRRect(
      ring,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _FocusRingPainter oldDelegate) =>
      color != oldDelegate.color || borderRadius != oldDelegate.borderRadius;
}
