// spec-003 T19: omitted size/theme axes widget matrix — four groups from
// spec.md "Omitted size/theme axes":
//   1. Dark roles: every named state family under AppTheme.darkTheme;
//      text/fill resolves to a declared CustodeColors role and every used
//      text/background pair is in the spec-001 contrast matrix (>=4.5:1).
//   2. Tablet/card widths: selection single-column at 599, two-column at
//      600/1024 without overflow; unlock card <=600 and centred at 1024.
//   3. Error placement: credential/missing-key errors are descendants of
//      the credential field group (not a SnackBar); database-level errors
//      occupy their dedicated surface.
//   4. Sheet geometry: invalid/corrupt/duplicate/key-manager/Face-ID sheets
//      use the root navigator, radius-32 top corners, and documented width
//      constraints in light and dark.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:password_manager/core/theme/app_radii.dart';
import 'package:password_manager/core/theme/custode_colors.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_record.dart';
import 'package:password_manager/features/password_manager/domain/entities/database_security_profile.dart';
import 'package:password_manager/features/password_manager/domain/errors/database_access_failure.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file_selection_data.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_event.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/database_selection_sheets.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/drive_picker_sheet.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/biometric_prompt_sheet.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/internal_key_file_manager_sheet.dart';

import 'database_selection_unlock_test_utils.dart';

/// spec-001 declared text/background pairs (mirrors
/// `test/core/theme/app_theme_test.dart`) — the only pairings allowed to
/// carry body text. Any surface in this matrix using a different
/// combination is a real contrast/role violation, not a test artifact.
double _contrastRatio(Color foreground, Color background) {
  final opaqueForeground = Color.alphaBlend(foreground, background);
  final foregroundLuminance = opaqueForeground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final high = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final low = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (high + 0.05) / (low + 0.05);
}

void _expectDeclaredPair(
  CustodeColors colors,
  Color foreground,
  Color background,
) {
  final declaredPairs = <Color>{
    colors.actionFill,
    colors.actionEmphasis,
    colors.attentionTint,
    colors.positiveTint,
    colors.ground,
    colors.surface,
    colors.surfaceNested,
  };
  expect(
    declaredPairs.contains(background),
    isTrue,
    reason:
        'Background $background is not one of the spec-001 declared '
        'surfaces for text.',
  );
  expect(
    _contrastRatio(foreground, background),
    greaterThanOrEqualTo(4.5),
    reason: '$foreground on $background must meet 4.5:1 (spec-001).',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    await (FontLoader(
      'Caprasimo',
    )..addFont(rootBundle.load('assets/fonts/Caprasimo-Regular.ttf'))).load();
    await (FontLoader('Figtree')
          ..addFont(rootBundle.load('assets/fonts/Figtree-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-SemiBold.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Figtree-Bold.ttf')))
        .load();
  });

  tearDown(resetDatabaseTestDi);

  // =========================================================================
  // Group 1 — Dark roles
  // =========================================================================
  group('Dark roles', () {
    testWidgets('welcome: headline resolves to textPrimary on ground', (
      tester,
    ) async {
      final result = await pumpableSelectionScreen(themeMode: ThemeMode.dark);
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final headline = tester.widget<Text>(
        find.text('Your vault, in a file you own.'),
      );
      _expectDeclaredPair(
        CustodeColors.dark,
        headline.style!.color!,
        CustodeColors.dark.ground,
      );
      expect(headline.style!.color, CustodeColors.dark.textPrimary);
    });

    testWidgets('recent: title resolves to textPrimary on ground', (
      tester,
    ) async {
      final result = await pumpableSelectionScreen(
        themeMode: ThemeMode.dark,
        records: [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: '/tmp/personal.kdbx',
            displayName: 'personal.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ],
        existingPaths: const {'/tmp/personal.kdbx'},
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final title = tester.widget<Text>(find.text('Databases'));
      expect(title.style!.color, CustodeColors.dark.textPrimary);
      final rowTitle = tester.widget<Text>(find.text('personal.kdbx'));
      expect(rowTitle.style!.color, CustodeColors.dark.textPrimary);
    });

    testWidgets('create steps 1-2: title resolves to textPrimary', (
      tester,
    ) async {
      final result = await pumpableCreateDatabaseScreen(
        themeMode: ThemeMode.dark,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.text('Name your database')).style!.color,
        CustodeColors.dark.textPrimary,
      );

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Choose your credentials')).style!.color,
        CustodeColors.dark.textPrimary,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Drive loading/empty resolve textPrimary/textSecondary', (
      tester,
    ) async {
      await tester.pumpWidget(
        pumpableSheetHost(
          themeMode: ThemeMode.dark,
          onOpen: (context) async {
            await showDrivePickerSheet(
              context,
              loadPickerData: () async => const RemoteFileSelectionData(
                files: [],
                account: StorageAccountSummary(
                  displayLabel: 'jane@example.com',
                  email: 'jane@example.com',
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final title = tester.widget<Text>(find.text('Open from Google Drive'));
      expect(title.style!.color, CustodeColors.dark.textPrimary);
    });

    testWidgets('invalid sheet resolves declared roles', (tester) async {
      await tester.pumpWidget(
        pumpableSheetHost(
          themeMode: ThemeMode.dark,
          onOpen: (context) =>
              showInvalidDatabaseFileDialog(context, basename: 'bad.kdbx'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .renderObject<RenderParagraph>(find.text('Invalid database file'))
            .text
            .style!
            .color,
        CustodeColors.dark.textPrimary,
      );
    });

    testWidgets('corrupt sheet resolves declared roles', (tester) async {
      await tester.pumpWidget(
        pumpableSheetHost(
          themeMode: ThemeMode.dark,
          onOpen: (context) =>
              showCorruptDatabaseFileDialog(context, basename: 'bad.kdbx'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .renderObject<RenderParagraph>(
              find.text('Database file is corrupted'),
            )
            .text
            .style!
            .color,
        CustodeColors.dark.textPrimary,
      );
    });

    testWidgets('duplicate sheet resolves declared roles', (tester) async {
      await tester.pumpWidget(
        pumpableSheetHost(
          themeMode: ThemeMode.dark,
          onOpen: (context) async {
            await showDuplicateDatabaseSheet(
              context,
              importedName: 'a.kdbx',
              existingName: 'b.kdbx',
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<Text>(find.text('Duplicate database detected'))
            .style!
            .color,
        CustodeColors.dark.textPrimary,
      );
    });

    final baseRecords = [
      DatabaseRecord(
        databaseId: 'db-1',
        canonicalPath: '/tmp/personal.kdbx',
        displayName: 'personal.kdbx',
        sourceType: DatabaseSourceType.local,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ),
    ];
    const profiles = {
      'db-1': DatabaseSecurityProfile(
        databaseId: 'db-1',
        biometricProtectionEnabled: false,
      ),
    };

    testWidgets('unlock ready resolves declared roles', (tester) async {
      final result = await pumpableUnlockScreen(
        databasePath: '/tmp/personal.kdbx',
        themeMode: ThemeMode.dark,
        records: baseRecords,
        securityProfiles: profiles,
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Text>(find.text('personal.kdbx')).style!.color,
        CustodeColors.dark.textPrimary,
      );
    });

    testWidgets('unlock wrong-password resolves declared roles', (
      tester,
    ) async {
      final result = await pumpableUnlockScreen(
        databasePath: '/tmp/personal.kdbx',
        themeMode: ThemeMode.dark,
        records: baseRecords,
        securityProfiles: profiles,
      );
      result.harness.unlockUseCase.error = const InvalidCredentialsFailure();
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'wrong');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock vault'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final errorText = tester.widget<Text>(
        find.text('Incorrect master password or key file.'),
      );
      _expectDeclaredPair(
        CustodeColors.dark,
        errorText.style!.color ?? CustodeColors.dark.textPrimary,
        CustodeColors.dark.ground,
      );
    });

    testWidgets('unlock key-selected resolves declared roles', (tester) async {
      final result = await pumpableUnlockScreen(
        databasePath: '/tmp/personal.kdbx',
        themeMode: ThemeMode.dark,
        records: baseRecords,
        securityProfiles: profiles,
      );
      result.harness.fileRepository.existingPaths.add('/tmp/personal.key');
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      tester
          .element(find.byType(Scaffold).first)
          .read<DatabaseUnlockBloc>()
          .add(const UpdateKeyFilePath('/tmp/personal.key'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final buttonFinder = find.ancestor(
        of: find.text('Unlock with key file'),
        matching: find.byType(ElevatedButton),
      );
      expect(buttonFinder, findsOneWidget);
      final buttonStyle = tester.widget<ElevatedButton>(buttonFinder).style!;
      expect(
        buttonStyle.foregroundColor?.resolve(const {}),
        CustodeColors.dark.actionText,
      );
      expect(
        buttonStyle.backgroundColor?.resolve(const {}),
        CustodeColors.dark.actionFill,
      );
    });

    testWidgets('unlock decrypting resolves declared roles', (tester) async {
      final result = await pumpableUnlockScreen(
        databasePath: '/tmp/personal.kdbx',
        themeMode: ThemeMode.dark,
        records: baseRecords,
        securityProfiles: profiles,
      );
      result.harness.unlockUseCase.hang = true;
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'x');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock vault'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<Text>(
              find.text(
                'Deriving your encryption key with Argon2. This can take '
                'a moment.',
              ),
            )
            .style!
            .color,
        CustodeColors.dark.textSecondary,
      );
    });

    testWidgets('key manager sheet resolves declared roles', (tester) async {
      await tester.pumpWidget(
        pumpableSheetHost(
          themeMode: ThemeMode.dark,
          onOpen: (context) => showInternalKeyFileManagerSheet(
            context,
            listKeyFiles: ({required subdirectory}) async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Text>(find.text('Internal key files')).style!.color,
        CustodeColors.dark.textPrimary,
      );
    });

    testWidgets('Biometric prompt resolves declared roles', (tester) async {
      await tester.pumpWidget(
        pumpableSheetHost(
          themeMode: ThemeMode.dark,
          onOpen: (context) async {
            await showBiometricPromptDialog(context, basename: 'work.kdbx');
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .renderObject<RenderParagraph>(
              find.text('Use biometric unlock for work.kdbx?'),
            )
            .text
            .style!
            .color,
        CustodeColors.dark.textPrimary,
      );
    });
  });

  // =========================================================================
  // Group 2 — Tablet/card widths
  // =========================================================================
  group('Tablet/card widths', () {
    Future<void> pumpSelectionAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final result = await pumpableSelectionScreen(
        records: [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: '/tmp/personal.kdbx',
            displayName: 'personal.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ],
        existingPaths: const {'/tmp/personal.kdbx'},
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
    }

    testWidgets('599 renders single-column (Row not present at top level)', (
      tester,
    ) async {
      await pumpSelectionAt(tester, 599);
      expect(tester.takeException(), isNull);
      // Single-column layout stacks the header above the list in one
      // scroll view; no side-by-side Row hosting both columns.
      expect(
        find.byKey(const ValueKey('selection-two-column-row')),
        findsNothing,
      );
    });

    testWidgets('600 and 1024 render two-column without overflow', (
      tester,
    ) async {
      for (final width in [600.0, 1024.0]) {
        await pumpSelectionAt(tester, width);
        expect(tester.takeException(), isNull, reason: 'width=$width');
        expect(
          find.byKey(const ValueKey('selection-two-column-row')),
          findsOneWidget,
          reason: 'width=$width',
        );
        await resetDatabaseTestDi();
      }
    });

    testWidgets('unlock card is <=600 wide and centred at 1024', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1024, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const path = '/tmp/personal.kdbx';
      final result = await pumpableUnlockScreen(
        databasePath: path,
        records: [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: path,
            displayName: 'personal.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ],
        securityProfiles: const {
          'db-1': DatabaseSecurityProfile(
            databaseId: 'db-1',
            biometricProtectionEnabled: false,
          ),
        },
      );
      await tester.pumpWidget(result.widget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final cardFinder = find.ancestor(
        of: find.text('personal.kdbx'),
        matching: find.byType(ConstrainedBox),
      );
      final constraints = tester
          .widgetList<ConstrainedBox>(cardFinder)
          .map((w) => w.constraints)
          .firstWhere((c) => c.maxWidth <= 600);
      expect(constraints.maxWidth, lessThanOrEqualTo(600));

      final cardCenter = tester.getCenter(
        find
            .ancestor(
              of: find.text('personal.kdbx'),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(cardCenter.dx, closeTo(1024 / 2, 1));
    });
  });

  // =========================================================================
  // Group 3 — Error placement
  // =========================================================================
  group('Error placement', () {
    testWidgets(
      'credential/missing-key errors are descendants of the credential '
      'field group, not a SnackBar',
      (tester) async {
        const path = '/tmp/personal.kdbx';
        final records = [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: path,
            displayName: 'personal.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ];
        const profiles = {
          'db-1': DatabaseSecurityProfile(
            databaseId: 'db-1',
            biometricProtectionEnabled: false,
          ),
        };

        final result = await pumpableUnlockScreen(
          databasePath: path,
          records: records,
          securityProfiles: profiles,
        );
        result.harness.unlockUseCase.error = const InvalidCredentialsFailure();

        await tester.pumpWidget(result.widget);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), 'wrong');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Unlock vault'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(SnackBar), findsNothing);
        expect(
          find.descendant(
            of: find.byType(TextFormField),
            matching: find.text('Incorrect master password or key file.'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'missing/corrupt database errors occupy the failure surface, not '
      'inline field errors or a SnackBar',
      (tester) async {
        const path = '/tmp/personal.kdbx';
        final records = [
          DatabaseRecord(
            databaseId: 'db-1',
            canonicalPath: path,
            displayName: 'personal.kdbx',
            sourceType: DatabaseSourceType.local,
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ];
        const profiles = {
          'db-1': DatabaseSecurityProfile(
            databaseId: 'db-1',
            biometricProtectionEnabled: false,
          ),
        };

        final result = await pumpableUnlockScreen(
          databasePath: path,
          records: records,
          securityProfiles: profiles,
        );
        result.harness.unlockUseCase.error = const CorruptDatabaseFailure(
          'personal.kdbx',
        );

        await tester.pumpWidget(result.widget);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), 'x');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Unlock vault'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(SnackBar), findsNothing);
        // Failure surface replaces the credential form entirely (C-4
        // `failure` phase): no TextFormField remains on screen.
        expect(find.byType(TextFormField), findsNothing);
        expect(find.textContaining('personal.kdbx'), findsWidgets);
      },
    );
  });

  // =========================================================================
  // Group 4 — Sheet geometry
  // =========================================================================
  group('Sheet geometry', () {
    Future<void> expectSheetGeometry(
      WidgetTester tester,
      Future<void> Function(BuildContext context) onOpen, {
      required ThemeMode themeMode,
      required double width,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        pumpableSheetHost(onOpen: onOpen, themeMode: themeMode),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      if (width >= 600) {
        // 2026-09-05 (user-directed): choosers are a `Dialog` on wide
        // windows, capped at the same 560 px the sheet used to be.
        expect(find.byType(BottomSheet), findsNothing);
        final dialog = find.byType(Dialog);
        expect(dialog, findsOneWidget);
        // `Dialog` itself fills the route; its `Material` is the card.
        final card = find
            .descendant(of: dialog, matching: find.byType(Material))
            .first;
        expect(
          tester.getSize(card).width,
          lessThanOrEqualTo(560.5),
          reason: 'Dialog content must respect the 560 px max width.',
        );
        return;
      }

      expect(find.byType(BottomSheet), findsOneWidget);

      // The radius-32 top corners come from `AppTheme`'s
      // `bottomSheetTheme.shape` (not an explicit `KvBottomSheet.show`
      // param), applied to the `Material` surface hosting the sheet.
      final materialShapes = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Material),
            ),
          )
          .map((m) => m.shape)
          .whereType<RoundedRectangleBorder>()
          .toList();
      final sheetShape = materialShapes.firstWhere(
        (shape) =>
            (shape.borderRadius as BorderRadius).topLeft.x == AppRadii.sheet,
        orElse: () => throw StateError(
          'No radius-${AppRadii.sheet} top-corner Material shape found '
          'under the BottomSheet.',
        ),
      );
      final radius = sheetShape.borderRadius as BorderRadius;
      expect(radius.topLeft.x, AppRadii.sheet);
      expect(radius.topRight.x, AppRadii.sheet);
    }

    /// Yes/no confirmations and single-action messages are an `AlertDialog`
    /// on every width.
    Future<void> expectConfirmDialog(
      WidgetTester tester,
      Future<void> Function(BuildContext context) onOpen, {
      required ThemeMode themeMode,
      required double width,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        pumpableSheetHost(onOpen: onOpen, themeMode: themeMode),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
    }

    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      for (final width in [390.0, 1024.0]) {
        testWidgets(
          'invalid file: dialog on every width @ ${width.toInt()} '
          '(${themeMode.name})',
          (tester) async => expectConfirmDialog(
            tester,
            (context) =>
                showInvalidDatabaseFileDialog(context, basename: 'bad.kdbx'),
            themeMode: themeMode,
            width: width,
          ),
        );

        testWidgets(
          'corrupt file: dialog on every width @ ${width.toInt()} '
          '(${themeMode.name})',
          (tester) async => expectConfirmDialog(
            tester,
            (context) =>
                showCorruptDatabaseFileDialog(context, basename: 'bad.kdbx'),
            themeMode: themeMode,
            width: width,
          ),
        );

        testWidgets(
          'duplicate sheet: root navigator, radius-32, width @ '
          '${width.toInt()} (${themeMode.name})',
          (tester) async => expectSheetGeometry(
            tester,
            (context) async {
              await showDuplicateDatabaseSheet(
                context,
                importedName: 'a.kdbx',
                existingName: 'b.kdbx',
              );
            },
            themeMode: themeMode,
            width: width,
          ),
        );

        testWidgets(
          'key-manager sheet: root navigator, radius-32, width @ '
          '${width.toInt()} (${themeMode.name})',
          (tester) async => expectSheetGeometry(
            tester,
            (context) => showInternalKeyFileManagerSheet(
              context,
              listKeyFiles: ({required subdirectory}) async => [],
            ),
            themeMode: themeMode,
            width: width,
          ),
        );

        testWidgets(
          'Biometric prompt: dialog on every width @ '
          '${width.toInt()} (${themeMode.name})',
          (tester) async => expectConfirmDialog(
            tester,
            (context) async {
              await showBiometricPromptDialog(context, basename: 'work.kdbx');
            },
            themeMode: themeMode,
            width: width,
          ),
        );
      }
    }

    test('KvBottomSheet.show always uses the root navigator', () {
      final source = File('lib/core/widgets/kv_bottom_sheet.dart')
          .readAsStringSync();
      expect(source, contains('useRootNavigator: true'));
    });
  });
}
