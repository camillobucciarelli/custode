import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_glyph.dart';

class KvIcon extends StatelessWidget {
  const KvIcon({
    super.key,
    required this.glyph,
    this.size = 24,
    this.color,
    this.semanticLabel,
  });

  final AppGlyph glyph;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final resolvedColor =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      glyph.assetPath,
      width: size,
      height: size,
      theme: SvgTheme(currentColor: resolvedColor),
      semanticsLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
    );
  }
}
