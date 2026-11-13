import 'package:flutter/material.dart';

import 'app_colors.dart';

@immutable
class CustodeColors extends ThemeExtension<CustodeColors> {
  const CustodeColors({
    required this.ground,
    required this.surface,
    required this.surfaceNested,
    required this.canvas,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.divider,
    required this.actionFill,
    required this.actionText,
    required this.actionEmphasis,
    required this.attentionTint,
    required this.attentionText,
    required this.linkText,
    required this.positiveFill,
    required this.positiveTint,
    required this.positiveText,
    required this.selectionBorder,
    required this.iconNeutral,
  });

  static const light = CustodeColors(
    ground: AppColors.neutral100,
    surface: AppColors.neutral200,
    surfaceNested: AppColors.neutral100,
    canvas: AppColors.neutral300,
    textPrimary: AppColors.text,
    textSecondary: AppColors.neutral700,
    textTertiary: AppColors.neutral700,
    divider: AppColors.divider,
    actionFill: AppColors.accent300,
    actionText: AppColors.accent900,
    actionEmphasis: AppColors.accent400,
    attentionTint: AppColors.accent100,
    attentionText: AppColors.accent900,
    linkText: AppColors.accent800,
    positiveFill: AppColors.accent2_400,
    positiveTint: AppColors.accent2_100,
    positiveText: AppColors.accent2_900,
    selectionBorder: AppColors.accent400,
    iconNeutral: AppColors.neutral700,
  );

  static final dark = CustodeColors(
    ground: AppColors.neutral900,
    surface: AppColors.neutral800,
    surfaceNested: AppColors.neutral900,
    canvas: AppColors.neutral900,
    textPrimary: AppColors.neutral100,
    textSecondary: AppColors.neutral100.withValues(alpha: 0.62),
    textTertiary: AppColors.neutral100.withValues(alpha: 0.62),
    divider: AppColors.neutral100.withValues(alpha: 0.22),
    actionFill: AppColors.accent300,
    actionText: AppColors.accent900,
    actionEmphasis: AppColors.accent400,
    attentionTint: AppColors.accent800,
    attentionText: AppColors.accent200,
    linkText: AppColors.accent300,
    positiveFill: AppColors.accent2_400,
    positiveTint: AppColors.accent2_800,
    positiveText: AppColors.accent2_200,
    selectionBorder: AppColors.accent300,
    iconNeutral: AppColors.neutral100.withValues(alpha: 0.72),
  );

  final Color ground;
  final Color surface;
  final Color surfaceNested;
  final Color canvas;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color divider;
  final Color actionFill;
  final Color actionText;
  final Color actionEmphasis;
  final Color attentionTint;
  final Color attentionText;
  final Color linkText;
  final Color positiveFill;
  final Color positiveTint;
  final Color positiveText;
  final Color selectionBorder;
  final Color iconNeutral;

  @override
  CustodeColors copyWith({
    Color? ground,
    Color? surface,
    Color? surfaceNested,
    Color? canvas,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? divider,
    Color? actionFill,
    Color? actionText,
    Color? actionEmphasis,
    Color? attentionTint,
    Color? attentionText,
    Color? linkText,
    Color? positiveFill,
    Color? positiveTint,
    Color? positiveText,
    Color? selectionBorder,
    Color? iconNeutral,
  }) => CustodeColors(
    ground: ground ?? this.ground,
    surface: surface ?? this.surface,
    surfaceNested: surfaceNested ?? this.surfaceNested,
    canvas: canvas ?? this.canvas,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    divider: divider ?? this.divider,
    actionFill: actionFill ?? this.actionFill,
    actionText: actionText ?? this.actionText,
    actionEmphasis: actionEmphasis ?? this.actionEmphasis,
    attentionTint: attentionTint ?? this.attentionTint,
    attentionText: attentionText ?? this.attentionText,
    linkText: linkText ?? this.linkText,
    positiveFill: positiveFill ?? this.positiveFill,
    positiveTint: positiveTint ?? this.positiveTint,
    positiveText: positiveText ?? this.positiveText,
    selectionBorder: selectionBorder ?? this.selectionBorder,
    iconNeutral: iconNeutral ?? this.iconNeutral,
  );

  @override
  CustodeColors lerp(covariant CustodeColors? other, double t) {
    if (other == null) return this;
    return CustodeColors(
      ground: Color.lerp(ground, other.ground, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceNested: Color.lerp(surfaceNested, other.surfaceNested, t)!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      actionFill: Color.lerp(actionFill, other.actionFill, t)!,
      actionText: Color.lerp(actionText, other.actionText, t)!,
      actionEmphasis: Color.lerp(actionEmphasis, other.actionEmphasis, t)!,
      attentionTint: Color.lerp(attentionTint, other.attentionTint, t)!,
      attentionText: Color.lerp(attentionText, other.attentionText, t)!,
      linkText: Color.lerp(linkText, other.linkText, t)!,
      positiveFill: Color.lerp(positiveFill, other.positiveFill, t)!,
      positiveTint: Color.lerp(positiveTint, other.positiveTint, t)!,
      positiveText: Color.lerp(positiveText, other.positiveText, t)!,
      selectionBorder: Color.lerp(selectionBorder, other.selectionBorder, t)!,
      iconNeutral: Color.lerp(iconNeutral, other.iconNeutral, t)!,
    );
  }
}
