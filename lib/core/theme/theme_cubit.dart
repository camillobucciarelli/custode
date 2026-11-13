import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeCubit extends Cubit<ThemeMode> {
  ThemeCubit(this._sharedPreferences)
    : super(_loadInitialTheme(_sharedPreferences));

  static const _themeModePreferenceKey = 'theme_mode';

  final SharedPreferences _sharedPreferences;

  static ThemeMode _loadInitialTheme(SharedPreferences sharedPreferences) {
    final themeModeValue = sharedPreferences.getString(_themeModePreferenceKey);

    return switch (themeModeValue) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.system,
    };
  }

  void toggleTheme() {
    final nextTheme = switch (state) {
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.system => ThemeMode.light,
    };

    setTheme(nextTheme);
  }

  void setTheme(ThemeMode mode) {
    emit(mode);
    unawaited(_sharedPreferences.setString(_themeModePreferenceKey, mode.name));
  }
}
