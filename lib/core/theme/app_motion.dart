import 'package:material_ui/material_ui.dart';

class AppMotion {
  AppMotion._();

  static const row = Duration(milliseconds: 190);
  static const button = Duration(milliseconds: 220);
  static const sheetIn = Duration(milliseconds: 240);
  static const sheetOut = Duration(milliseconds: 180);
  static const unlock = Duration(milliseconds: 280);
  static const copyVisibility = Duration(milliseconds: 1600);
  static const copyIn = Duration(milliseconds: 200);
  static const copyOut = Duration(milliseconds: 200);
  static const spinner = Duration(milliseconds: 900);

  static const inCurve = Curves.easeOutCubic;
  static const outCurve = Curves.easeInCubic;
  static const spinnerCurve = Curves.linear;

  static Duration duration(BuildContext context, Duration value) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
}
