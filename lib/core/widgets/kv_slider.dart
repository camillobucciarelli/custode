import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/custode_colors.dart';

/// Generator length slider (PIXEL_SPEC "Generator" / "Core components ·
/// Slider"): track height 8 radius 999 `neutral-200`, filled `accent-400`,
/// thumb 24 circle `accent-400` with a 3 px `neutral-100` ring.
/// Thin `SliderTheme` wrap over Material's `Slider` — the geometry PIXEL_SPEC
/// asks for is exactly what `SliderTheme` already parameterises, so a
/// bespoke painter isn't warranted here.
class KvSlider extends StatelessWidget {
  const KvSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 8,
        activeTrackColor: AppColors.accent400,
        inactiveTrackColor: colors.surfaceNested,
        thumbColor: AppColors.accent400,
        overlayColor: AppColors.accent400.withValues(alpha: 0.16),
        thumbShape: const _RingThumbShape(),
      ),
      child: Slider(
        value: value.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: max - min,
        label: '$value',
        onChanged: (v) => onChanged(v.round()),
      ),
    );
  }
}

class _RingThumbShape extends SliderComponentShape {
  const _RingThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(12);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(
      center,
      12,
      Paint()..color = sliderTheme.thumbColor ?? AppColors.accent400,
    );
    canvas.drawCircle(
      center,
      12,
      Paint()
        ..color = AppColors.neutral100
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }
}
