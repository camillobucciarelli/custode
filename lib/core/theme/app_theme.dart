import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_motion.dart';
import 'app_radii.dart';
import 'app_text_styles.dart';
import 'custode_colors.dart';

class AppTheme {
  AppTheme._();

  static bool _licensesRegistered = false;

  static ThemeData get lightTheme {
    _registerLicenses();
    return _buildTheme(CustodeColors.light);
  }

  static ThemeData get darkTheme {
    _registerLicenses();
    return _buildTheme(CustodeColors.dark);
  }

  static ThemeData _buildTheme(CustodeColors colors) {
    final isDark = colors == CustodeColors.dark;
    final brightness = isDark ? Brightness.dark : Brightness.light;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: colors.linkText,
      onPrimary: colors.ground,
      primaryContainer: colors.actionFill,
      onPrimaryContainer: colors.actionText,
      secondary: colors.positiveText,
      onSecondary: colors.ground,
      secondaryContainer: colors.positiveTint,
      onSecondaryContainer: colors.positiveText,
      tertiary: colors.linkText,
      onTertiary: colors.ground,
      tertiaryContainer: colors.attentionTint,
      onTertiaryContainer: colors.attentionText,
      error: colors.attentionText,
      onError: colors.ground,
      errorContainer: colors.attentionTint,
      onErrorContainer: colors.attentionText,
      surface: colors.surface,
      onSurface: colors.textPrimary,
      surfaceDim: colors.surface,
      surfaceBright: colors.surfaceNested,
      surfaceContainerLowest: colors.ground,
      surfaceContainerLow: colors.surfaceNested,
      surfaceContainer: colors.surface,
      surfaceContainerHigh: colors.surface,
      surfaceContainerHighest: colors.surface,
      onSurfaceVariant: colors.textSecondary,
      outline: colors.selectionBorder,
      outlineVariant: colors.divider,
      shadow: isDark ? Colors.black : AppColors.neutral900,
      scrim: Colors.black,
      inverseSurface: isDark ? AppColors.neutral100 : AppColors.neutral900,
      onInverseSurface: isDark ? AppColors.text : AppColors.neutral100,
      inversePrimary: colors.actionFill,
      surfaceTint: Colors.transparent,
    );
    final baseTextTheme = ThemeData(brightness: brightness).textTheme;
    final textTheme = baseTextTheme.copyWith(
      displayLarge: AppTextStyles.heroHeadline.copyWith(
        color: colors.textPrimary,
      ),
      headlineLarge: AppTextStyles.screenTitleLarge.copyWith(
        color: colors.textPrimary,
      ),
      headlineMedium: AppTextStyles.screenTitle.copyWith(
        color: colors.textPrimary,
      ),
      headlineSmall: AppTextStyles.sheetTitleLarge.copyWith(
        color: colors.textPrimary,
      ),
      titleLarge: AppTextStyles.sheetTitle.copyWith(color: colors.textPrimary),
      titleMedium: AppTextStyles.panelTitle.copyWith(color: colors.textPrimary),
      titleSmall: AppTextStyles.rowTitle.copyWith(color: colors.textPrimary),
      bodyLarge: AppTextStyles.fieldValue.copyWith(color: colors.textPrimary),
      bodyMedium: AppTextStyles.body.copyWith(color: colors.textPrimary),
      bodySmall: AppTextStyles.secondary.copyWith(color: colors.textSecondary),
      labelLarge: AppTextStyles.rowTitle.copyWith(color: colors.textPrimary),
      labelMedium: AppTextStyles.meta.copyWith(color: colors.textSecondary),
      labelSmall: AppTextStyles.labelUpper.copyWith(
        color: colors.textSecondary,
      ),
    );
    final filledButtonStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(44, 48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => _filledBackground(colors, states),
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? colors.textSecondary
            : colors.actionText,
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: colors.selectionBorder, width: 2)
            : BorderSide.none,
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.rowCompact),
        ),
      ),
      textStyle: const WidgetStatePropertyAll(AppTextStyles.rowTitle),
      animationDuration: AppMotion.button,
    );
    final outlinedButtonStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(44, 48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => _neutralInteractionBackground(colors, states),
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? colors.textSecondary
            : colors.textPrimary,
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: colors.selectionBorder, width: 2)
            : BorderSide(
                color: states.contains(WidgetState.disabled)
                    ? colors.divider
                    : colors.iconNeutral,
              ),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.rowCompact),
        ),
      ),
      textStyle: const WidgetStatePropertyAll(AppTextStyles.rowTitle),
      animationDuration: AppMotion.button,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[colors],
      fontFamily: AppTextStyles.bodyFamily,
      textTheme: textTheme,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      scaffoldBackgroundColor: colors.ground,
      canvasColor: colors.canvas,
      dividerColor: colors.divider,
      hoverColor: colors.actionFill,
      focusColor: colors.selectionBorder,
      highlightColor: colors.actionEmphasis,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.selectionBorder,
        selectionColor: colors.actionFill,
        selectionHandleColor: colors.selectionBorder,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: AppTextStyles.screenTitle.copyWith(
          color: colors.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
          side: BorderSide(color: colors.divider),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.divider,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceNested,
        // 2026-08-31: hover and focus act on the BORDER only. The default
        // blends hoverColor into the fill, which darkened the field enough
        // to drown the text-selection highlight.
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        constraints: const BoxConstraints(minHeight: 52),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        labelStyle: AppTextStyles.secondary.copyWith(
          color: colors.textSecondary,
        ),
        hintStyle: AppTextStyles.fieldValue.copyWith(
          color: colors.textSecondary,
        ),
        errorStyle: AppTextStyles.meta.copyWith(color: colors.textPrimary),
        disabledBorder: _inputBorder(colors.divider),
        border: _inputBorder(colors.divider),
        enabledBorder: _inputBorder(colors.divider),
        focusedBorder: _inputBorder(colors.selectionBorder, width: 2),
        errorBorder: _inputBorder(colors.attentionText, width: 1.5),
        focusedErrorBorder: _inputBorder(colors.attentionText, width: 2),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(style: filledButtonStyle),
      filledButtonTheme: FilledButtonThemeData(style: filledButtonStyle),
      outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedButtonStyle),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? colors.textSecondary
                : colors.linkText,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? BorderSide(color: colors.selectionBorder, width: 2)
                : BorderSide.none,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.rowCompact),
            ),
          ),
          textStyle: const WidgetStatePropertyAll(AppTextStyles.rowTitle),
          animationDuration: AppMotion.button,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? colors.iconNeutral.withValues(alpha: 0.45)
                : colors.iconNeutral,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => _neutralInteractionBackground(colors, states),
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? BorderSide(color: colors.selectionBorder, width: 2)
                : BorderSide.none,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.iconSquare),
            ),
          ),
          animationDuration: AppMotion.button,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? colors.textSecondary
              : states.contains(WidgetState.selected)
              ? colors.actionText
              : colors.iconNeutral,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? colors.surface
              : states.contains(WidgetState.selected)
              ? colors.actionFill
              : colors.surfaceNested,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? colors.selectionBorder
              : colors.divider,
        ),
        trackOutlineWidth: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused) ? 2 : 1,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? colors.surface
              : states.contains(WidgetState.selected)
              ? colors.actionFill
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(colors.actionText),
        side: WidgetStateBorderSide.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? BorderSide(color: colors.selectionBorder, width: 2)
              : BorderSide(color: colors.iconNeutral),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.iconSquare),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        modalBackgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.sheet),
          ),
          side: BorderSide(color: colors.divider),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.surface,
        contentTextStyle: AppTextStyles.body.copyWith(
          color: colors.textPrimary,
        ),
        actionTextColor: colors.linkText,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.rowNested),
          side: BorderSide(color: colors.divider),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: AppTextStyles.sheetTitle.copyWith(
          color: colors.textPrimary,
        ),
        contentTextStyle: AppTextStyles.body.copyWith(
          color: colors.textPrimary,
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.cardLarge),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.rowNested),
          side: BorderSide(color: colors.divider),
        ),
        menuPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.surfaceNested,
        selectedColor: colors.actionFill,
        labelStyle: WidgetStateTextStyle.resolveWith(
          (states) => AppTextStyles.meta.copyWith(
            color: states.contains(WidgetState.selected)
                ? colors.actionText
                : colors.textPrimary,
          ),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        side: BorderSide(color: colors.divider),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  static Color _filledBackground(
    CustodeColors colors,
    Set<WidgetState> states,
  ) {
    if (states.contains(WidgetState.disabled)) return colors.surface;
    if (states.contains(WidgetState.pressed)) return AppColors.accent500;
    if (states.contains(WidgetState.hovered)) return colors.actionEmphasis;
    return colors.actionFill;
  }

  static Color _neutralInteractionBackground(
    CustodeColors colors,
    Set<WidgetState> states,
  ) {
    final isDark = colors == CustodeColors.dark;
    if (states.contains(WidgetState.pressed)) {
      return isDark ? AppColors.neutral600 : colors.canvas;
    }
    if (states.contains(WidgetState.hovered)) {
      return isDark ? AppColors.neutral700 : colors.surfaceNested;
    }
    return isDark ? AppColors.neutral800 : Colors.transparent;
  }

  static void _registerLicenses() {
    if (_licensesRegistered) return;
    _licensesRegistered = true;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const [
        'Caprasimo',
        'Figtree',
      ], await rootBundle.loadString('assets/fonts/OFL.txt'));
      yield LicenseEntryWithLineBreaks(const [
        'Lucide Icons',
      ], await rootBundle.loadString('assets/icons/lucide/LICENSE'));
    });
  }

  // Material themes expose one border per control, not an outline-offset layer.
  // These borders remain the theme fallback; AppFocusRing adds the exact 2 px
  // external gap where a caller can share its FocusNode with the control.
  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        // AppRadii.row: one radius for every text field — the search bar
        // (this theme) and the form fields (kvFieldDecoration) agree.
        borderRadius: BorderRadius.circular(AppRadii.row),
        borderSide: BorderSide(color: color, width: width),
      );
}
