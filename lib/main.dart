import 'dart:ui';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:loggy/loggy.dart';

import 'core/theme/app_theme.dart';
import 'core/theme/theme_cubit.dart';
import 'injection_container.dart' as di;
import 'features/password_manager/presentation/bloc/database_selection/database_selection_bloc.dart';
import 'features/password_manager/presentation/bloc/database_selection/database_selection_event.dart';
import 'features/password_manager/presentation/screens/database_selection_screen.dart';
import 'features/password_manager/presentation/coordinators/android_autofill_save_coordinator.dart';
import 'features/password_manager/presentation/coordinators/otpauth_deep_link_coordinator.dart';

Future<void> main() async {
  await _bootstrapApp();
}

Future<void> _bootstrapApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  _configureLogging();
  await di.init();
  await di.sl<OtpAuthDeepLinkCoordinator>().initialize();
  // spec-016: claim a pending autofill save capture now, so the unlock screen
  // and the biometric prompt can both say why they are asking without waiting
  // on a channel round-trip. Inert wherever save capture is unsupported.
  await di.sl<AndroidAutofillSaveCoordinator>().hasPendingCapture();
  runApp(const PasswordManagerApp());
}

void _configureLogging() {
  Loggy.initLoggy(
    logPrinter: const PrettyPrinter(),
    logOptions: kReleaseMode
        ? const LogOptions(LogLevel.error, stackTraceLevel: LogLevel.error)
        : const LogOptions(LogLevel.all, stackTraceLevel: LogLevel.error),
  );

  FlutterError.onError = (details) {
    if (_isKnownKeyboardRepeatAssertion(details)) {
      return;
    }
    FlutterError.presentError(details);
    logError(
      'Unhandled Flutter framework error',
      details.exception,
      details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    logError('Unhandled platform error', error, stack);
    return true;
  };
}

bool _isKnownKeyboardRepeatAssertion(FlutterErrorDetails details) {
  final message = details.exceptionAsString();
  return message.contains('A KeyDownEvent is dispatched') &&
      message.contains('physical key is already pressed');
}

class PasswordManagerApp extends StatelessWidget {
  const PasswordManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => ThemeCubit(di.sl())),
        BlocProvider(
          create: (_) =>
              di.sl<DatabaseSelectionBloc>()..add(CheckInitialDatabase()),
        ),
      ],
      child: BlocBuilder<ThemeCubit, ThemeMode>(
        builder: (context, themeMode) {
          return MaterialApp(
            title: 'Custode',
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeMode,
            home: const DatabaseSelectionScreen(),
            builder: (context, child) {
              final brightness = Theme.of(context).brightness;
              final overlayStyle = brightness == Brightness.light
                  ? SystemUiOverlayStyle.dark
                  : SystemUiOverlayStyle.light;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: overlayStyle,
                child: child ?? const SizedBox.shrink(),
              );
            },
          );
        },
      ),
    );
  }
}
