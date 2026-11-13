import 'package:material_ui/material_ui.dart';

class AppTextStyles {
  AppTextStyles._();

  static const headingFamily = 'Caprasimo';
  static const bodyFamily = 'Figtree';
  static const monoFamily = 'monospace';
  static const monoFallback = <String>['SFMono-Regular', 'Menlo', 'Consolas'];

  static const heroHeadline = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w400,
    fontSize: 38,
    height: 1.10,
    letterSpacing: -0.57,
  );
  static const screenTitle = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w400,
    fontSize: 28,
    height: 1.14,
    letterSpacing: -0.42,
  );
  static const screenTitleLarge = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w400,
    fontSize: 30,
    height: 1.14,
    letterSpacing: -0.45,
  );
  static const sheetTitle = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w400,
    fontSize: 22,
    height: 1.15,
    letterSpacing: -0.33,
  );
  static const sheetTitleLarge = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w400,
    fontSize: 24,
    height: 1.15,
    letterSpacing: -0.36,
  );
  static const panelTitle = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w400,
    fontSize: 18,
    height: 1.20,
    letterSpacing: -0.27,
  );
  static const panelTitleLarge = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w400,
    fontSize: 20,
    height: 1.20,
    letterSpacing: -0.30,
  );
  static const numeric = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w700,
    fontSize: 18,
    height: 1,
  );
  static const numericLarge = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w700,
    fontSize: 22,
    height: 1,
  );
  static const rowTitle = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 1.25,
  );
  static const fieldValue = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 15,
    height: 1.40,
  );
  static const fieldValueDense = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 14.5,
    height: 1.40,
  );
  static const body = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 13.5,
    height: 1.45,
  );
  static const secondary = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 12.5,
    height: 1.40,
  );
  static const meta = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 11.5,
    height: 1.50,
  );
  static const metaLarge = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 12,
    height: 1.50,
  );
  static const labelUpper = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w700,
    fontSize: 11,
    height: 1.20,
    letterSpacing: 0.99,
  );
  static const labelMicro = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w700,
    fontSize: 10,
    height: 1.20,
    letterSpacing: 0.8,
  );
  static const secret = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 13.5,
    height: 1.40,
  );
  static const secretLarge = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 16,
    height: 1.40,
  );
  static const otpCode = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontWeight: FontWeight.w600,
    fontSize: 21,
    height: 1.20,
    letterSpacing: 3.36,
  );

  static const named = <String, TextStyle>{
    'heroHeadline': heroHeadline,
    'screenTitle': screenTitle,
    'screenTitleLarge': screenTitleLarge,
    'sheetTitle': sheetTitle,
    'sheetTitleLarge': sheetTitleLarge,
    'panelTitle': panelTitle,
    'panelTitleLarge': panelTitleLarge,
    'numeric': numeric,
    'numericLarge': numericLarge,
    'rowTitle': rowTitle,
    'fieldValue': fieldValue,
    'fieldValueDense': fieldValueDense,
    'body': body,
    'secondary': secondary,
    'meta': meta,
    'metaLarge': metaLarge,
    'labelUpper': labelUpper,
    'labelMicro': labelMicro,
    'secret': secret,
    'secretLarge': secretLarge,
    'otpCode': otpCode,
  };
}
