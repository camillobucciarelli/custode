import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  static const neutral100 = Color(0xFFF9F4ED);
  static const neutral200 = Color(0xFFEEE7DB);
  static const neutral300 = Color(0xFFDCD3C4);
  static const neutral400 = Color(0xFFC0B6A5);
  static const neutral500 = Color(0xFFA19786);
  static const neutral600 = Color(0xFF82796A);

  /// Accessibility-approved deviation from handoff `#645c50`.
  static const neutral700 = Color(0xFF665F53);
  static const neutral800 = Color(0xFF474238);
  static const neutral900 = Color(0xFF2E2B25);

  static const accent100 = Color(0xFFFFF2EB);
  static const accent200 = Color(0xFFFFE1D0);
  static const accent300 = Color(0xFFFFC6A5);
  static const accent400 = Color(0xFFF6A06B);
  static const accent500 = Color(0xFFD67F48);
  static const accent600 = Color(0xFFB2622D);
  static const accent700 = Color(0xFF8C491A);
  static const accent800 = Color(0xFF643312);
  static const accent900 = Color(0xFF402310);

  static const accent2_100 = Color(0xFFF0FAE1);
  static const accent2_200 = Color(0xFFE1EECC);
  static const accent2_300 = Color(0xFFCCDBB2);
  static const accent2_400 = Color(0xFFAEBF92);
  static const accent2_500 = Color(0xFF8FA073);
  static const accent2_600 = Color(0xFF728157);
  static const accent2_700 = Color(0xFF56633F);
  static const accent2_800 = Color(0xFF3D472B);
  static const accent2_900 = Color(0xFF272E1B);

  static const text = Color(0xFF201E1D);
  static const divider = Color(0x29201E1D);

  // Compatibility-only aliases for untouched screens. New code uses Organic
  // ramps through CustodeColors semantic roles.
  static const primary = accent400;
  static const primaryLight = accent300;
  static const primaryDark = accent800;
  static const secondary = accent2_400;
  static const secondaryLight = accent2_300;
  static const secondaryDark = accent2_800;
  static const tertiary = accent500;
  static const tertiaryLight = accent300;
  static const tertiaryDark = accent900;
  static const darkSeed = accent400;
  static const backgroundLight = neutral100;
  static const surfaceLight = neutral200;
  static const textPrimaryLight = text;
  static const textSecondaryLight = neutral700;
  static const dividerLight = divider;
  static const darkGradientFrom = neutral900;
  static const darkGradientTo = neutral900;
  static const lightGradientFrom = neutral100;
  static const lightGradientTo = neutral100;
  static const backgroundDark = neutral900;
  static const surfaceDark = neutral800;
  static const textPrimaryDark = neutral100;
  static const textSecondaryDark = Color(0x9EF9F4ED);
  static const dividerDark = Color(0x38F9F4ED);
  static const error = accent800;
  static const success = accent2_600;
  static const warning = accent500;
}
