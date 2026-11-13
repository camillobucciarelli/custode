import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/custode_colors.dart';

enum KvHealthState { good, warning }

/// 8 px status dot for list rows (PIXEL_SPEC "List row" trailing). Never
/// colour-only (PIXEL_SPEC §6 accessibility floor): always carries a
/// [semanticsLabel] describing the state in words.
class KvHealthDot extends StatelessWidget {
  const KvHealthDot({
    super.key,
    required this.state,
    required this.semanticsLabel,
    this.size = 8,
  });

  final KvHealthState state;
  final String semanticsLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final color = state == KvHealthState.warning
        ? AppColors.warning
        : colors.positiveFill;
    return Semantics(
      label: semanticsLabel,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
