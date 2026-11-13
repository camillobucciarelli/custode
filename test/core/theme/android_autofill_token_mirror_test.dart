import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_colors.dart';
import 'package:password_manager/core/theme/app_radii.dart';
import 'package:password_manager/core/theme/app_text_styles.dart';

/// spec-016 T703 (D7): the Android autofill picker cannot read the Flutter
/// theme, so its colours are mirrored into Android resources by hand. This test
/// is the only thing stopping the two copies from drifting: change an
/// [AppColors] value without copying it over and it fails here.
void main() {
  const lightMirror = <String, Color>{
    'kv_picker_ground': AppColors.neutral100,
    'kv_picker_surface': AppColors.neutral200,
    'kv_picker_text_primary': AppColors.text,
    'kv_picker_text_secondary': AppColors.neutral700,
    'kv_picker_divider': AppColors.divider,
    'kv_picker_focus': AppColors.accent700,
    'kv_picker_accent_tint': AppColors.accent100,
  };

  const darkMirror = <String, Color>{
    'kv_picker_ground': AppColors.neutral900,
    'kv_picker_surface': AppColors.neutral800,
    'kv_picker_text_primary': AppColors.neutral100,
    'kv_picker_text_secondary': AppColors.neutral400,
    'kv_picker_focus': AppColors.accent300,
    'kv_picker_accent_tint': AppColors.accent800,
  };

  group('Android autofill token mirror', () {
    test('the light resources match their AppColors source', () {
      final resources = _readColors(
        'android/app/src/main/res/values/colors.xml',
      );

      for (final entry in lightMirror.entries) {
        expect(
          resources[entry.key],
          isNotNull,
          reason: '${entry.key} is missing from the light colour resources.',
        );
        expect(
          resources[entry.key],
          _argb(entry.value),
          reason:
              '${entry.key} drifted from its AppColors source. Copy the Dart '
              'value into android/app/src/main/res/values/colors.xml.',
        );
      }
    });

    test('the dark resources match their AppColors source', () {
      final resources = _readColors(
        'android/app/src/main/res/values-night/colors.xml',
      );

      for (final entry in darkMirror.entries) {
        expect(
          resources[entry.key],
          isNotNull,
          reason: '${entry.key} is missing from the dark colour resources.',
        );
        expect(
          resources[entry.key],
          _argb(entry.value),
          reason:
              '${entry.key} drifted from its AppColors source. Copy the Dart '
              'value into android/app/src/main/res/values-night/colors.xml.',
        );
      }
    });

    // The dimens file names an AppTextStyles source for each size, so the same
    // drift risk applies to the type scale as to the colours.
    test('the picker type scale matches AppTextStyles', () {
      final dimens = _readDimens('android/app/src/main/res/values/dimens.xml');

      const mirror = <String, double>{
        'kv_picker_title_text': 20, // AppTextStyles.panelTitleLarge
        'kv_picker_body_text': 13.5, // AppTextStyles.body
        'kv_picker_row_title_text': 15, // AppTextStyles.rowTitle
        'kv_picker_row_subtitle_text': 12.5, // AppTextStyles.secondary
        'kv_picker_field_text': 15, // AppTextStyles.fieldValue
      };

      expect(
        dimens['kv_picker_title_text'],
        AppTextStyles.panelTitleLarge.fontSize,
      );
      expect(dimens['kv_picker_body_text'], AppTextStyles.body.fontSize);
      expect(
        dimens['kv_picker_row_title_text'],
        AppTextStyles.rowTitle.fontSize,
      );
      expect(
        dimens['kv_picker_row_subtitle_text'],
        AppTextStyles.secondary.fontSize,
      );
      expect(dimens['kv_picker_field_text'], AppTextStyles.fieldValue.fontSize);

      // Every size the picker declares is one of the mirrored five: a new sp
      // value with no Dart source is exactly the drift this guards against.
      for (final entry in mirror.entries) {
        expect(dimens[entry.key], entry.value, reason: entry.key);
      }
    });

    test('the picker radii match AppRadii', () {
      final dimens = _readDimens('android/app/src/main/res/values/dimens.xml');

      expect(dimens['kv_picker_radius'], AppRadii.rowCompact);
      expect(dimens['kv_picker_radius_field'], AppRadii.rowNested);
    });

    test('every mirrored name exists in both themes', () {
      final light = _readColors('android/app/src/main/res/values/colors.xml');
      final dark = _readColors(
        'android/app/src/main/res/values-night/colors.xml',
      );

      // A picker token defined only in one theme renders as the wrong colour in
      // the other, which is exactly the drift this file exists to catch.
      final mirrored = light.keys.where(
        (name) => name.startsWith('kv_picker_'),
      );
      expect(mirrored, isNotEmpty);
      expect(dark.keys.toSet(), containsAll(mirrored));
    });
  });
}

/// `#AARRGGBB`, upper case — the form the resource files use.
String _argb(Color color) {
  final value = color
      .toARGB32()
      .toRadixString(16)
      .toUpperCase()
      .padLeft(8, '0');
  return '#$value';
}

Map<String, String> _readColors(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path is missing.');

  final pattern = RegExp(
    r'<color\s+name="([^"]+)"\s*>\s*(#[0-9A-Fa-f]{6,8})\s*</color>',
  );
  return {
    for (final match in pattern.allMatches(file.readAsStringSync()))
      match.group(1)!: _normalizeHex(match.group(2)!),
  };
}

/// Values are `20dp` / `13.5sp`; the unit is dropped, the number is what mirrors.
Map<String, double> _readDimens(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path is missing.');

  final pattern = RegExp(
    r'<dimen\s+name="([^"]+)"\s*>\s*([0-9.]+)(?:dp|sp)\s*</dimen>',
  );
  return {
    for (final match in pattern.allMatches(file.readAsStringSync()))
      match.group(1)!: double.parse(match.group(2)!),
  };
}

/// Android allows `#RRGGBB`; Dart colours are always opaque-qualified.
String _normalizeHex(String raw) {
  final hex = raw.substring(1).toUpperCase();
  return hex.length == 6 ? '#FF$hex' : '#$hex';
}
