import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radii.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';

/// The design's text field (PIXEL_SPEC "Field"): surface fill, no border at
/// rest, radius 22, `selectionBorder` ring on focus, `accent700` ring on
/// error. One recipe shared by the entry editor and the unlock form, so a
/// form never draws a field the rest of the app does not.
InputDecoration kvFieldDecoration(
  CustodeColors colors, {
  String? hint,
  Widget? suffixIcon,
  String? errorText,
  Color? fillColor,
}) {
  return InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: fillColor ?? colors.surface,
    // The suffix button keeps the same breathing room on its right as the
    // field's content padding gives on the left.
    suffixIcon: suffixIcon == null
        ? null
        : Padding(padding: const EdgeInsets.only(right: 8), child: suffixIcon),
    errorText: errorText,
    errorMaxLines: 3,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.row),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.row),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.row),
      borderSide: BorderSide(color: colors.selectionBorder, width: 2),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.row),
      borderSide: BorderSide(color: AppColors.accent700, width: 2),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.row),
      borderSide: BorderSide(color: AppColors.accent700, width: 2),
    ),
    // spec-022 F-001: the error text reads the semantic token — a hard-coded
    // `accent800` vanished on the dark ground.
    errorStyle: AppTextStyles.secondary.copyWith(color: colors.attentionText),
  );
}

/// The 11 px uppercase label that sits 7 px above a [kvFieldDecoration] field.
Widget kvFieldLabel(String label, CustodeColors colors) => Padding(
  padding: const EdgeInsets.only(bottom: 7),
  child: Text(
    label,
    style: AppTextStyles.labelUpper.copyWith(color: colors.textSecondary),
  ),
);
