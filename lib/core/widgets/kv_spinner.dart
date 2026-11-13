import 'package:material_ui/material_ui.dart';

import '../theme/app_colors.dart';

/// `syncing` spinner (PIXEL_SPEC "Progress and meters"): 34 circle, 3 px ring
/// `neutral-300` with an `accent-400` top arc. First dedicated use: the Sync
/// destination's `syncing` hero (spec-005 T5).
class KvSpinner extends StatelessWidget {
  const KvSpinner({super.key, this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: 3,
        backgroundColor: AppColors.neutral300,
        valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent400),
      ),
    );
  }
}
