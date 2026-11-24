import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/utils/mobile_file_storage.dart';
import 'package:password_manager/features/password_manager/data/datasources/biometric_data_source.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/key_file_picker.dart';
import 'package:password_manager/injection_container.dart' as di;

import '../screens/database_selection_unlock_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    debugKeyFileLister = null;
    await resetDatabaseTestDi();
  });

  final entries = [
    AppStorageFileEntry(
      name: 'personal.key',
      path: '/managed/keys/personal.key',
      sizeBytes: 64,
      modifiedAt: DateTime(2026, 1, 10),
    ),
  ];

  /// Mounts a button that runs [pickKeyFile] and hands the result to [onDone].
  Future<void> pumpOpener(
    WidgetTester tester, {
    required void Function(PickedKeyFile?) onDone,
    String? current,
    bool deviceAuth = true,
  }) async {
    debugKeyFileLister = ({required subdirectory}) async => entries;
    // The harness registers the coordinator the picker resolves.
    await pumpableUnlockScreen(databasePath: '/tmp/a.kdbx');
    di.sl.registerLazySingleton<BiometricDataSource>(
      () => _GateBiometrics(deviceAuth),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  onDone(await pickKeyFile(context, current: current)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('gate refused: no sheet, nothing picked', (tester) async {
    var calls = 0;
    PickedKeyFile? picked = const PickedKeyFile(path: 'sentinel');
    await pumpOpener(
      tester,
      deviceAuth: false,
      onDone: (value) {
        calls += 1;
        picked = value;
      },
    );

    expect(find.text('Internal key files'), findsNothing);
    expect(calls, 1);
    expect(picked, isNull);
  });

  testWidgets('key chosen: returns its path and name', (tester) async {
    PickedKeyFile? picked;
    await pumpOpener(tester, onDone: (value) => picked = value);

    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();

    expect(picked?.path, '/managed/keys/personal.key');
    expect(picked?.name, 'personal.key');
    expect(picked?.isCleared, isFalse);
  });

  testWidgets('closing the sheet keeps the current key (null result)', (
    tester,
  ) async {
    var calls = 0;
    PickedKeyFile? picked = const PickedKeyFile(path: 'sentinel');
    await pumpOpener(
      tester,
      current: '/managed/keys/personal.key',
      onDone: (value) {
        calls += 1;
        picked = value;
      },
    );

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(picked, isNull);
  });

  group('KeyFileRow', () {
    Widget host(Widget row) => MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(body: row),
    );

    testWidgets('empty slot offers to add and opens the picker', (
      tester,
    ) async {
      var picks = 0;
      await tester.pumpWidget(
        host(KeyFileRow(onPick: () => picks++, onClear: () {})),
      );

      expect(find.text('Add a key file'), findsOneWidget);
      expect(find.byTooltip('Remove key file'), findsNothing);
      await tester.tap(find.text('Add a key file'));
      expect(picks, 1);
    });

    testWidgets('selected state shows the name and a 44 px remove button', (
      tester,
    ) async {
      var cleared = 0;
      await tester.pumpWidget(
        host(
          KeyFileRow(
            path: '/tmp/personal.key',
            onPick: () {},
            onClear: () => cleared++,
          ),
        ),
      );

      expect(find.text('personal.key'), findsOneWidget);
      final size = tester.getSize(
        find
            .ancestor(
              of: find.byTooltip('Remove key file'),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(size.shortestSide, greaterThanOrEqualTo(44));
      await tester.tap(find.byTooltip('Remove key file'));
      expect(cleared, 1);
    });

    testWidgets('F10: a rebuild with the same stored key does not look its '
        'name up again', (tester) async {
      // An opaque managed name: the only case that needs the async lookup.
      const stored = '/tmp/keys/0123456789abcdef0123456789abcdef';
      Widget row(String path) =>
          host(KeyFileRow(path: path, onPick: () {}, onClear: () {}));
      Future<String>? lookup() => tester
          .widget<FutureBuilder<String>>(find.byType(FutureBuilder<String>))
          .future;

      await tester.pumpWidget(row(stored));
      final first = lookup();
      await tester.pumpWidget(row(stored));
      expect(identical(lookup(), first), isTrue);

      // Another key is another lookup.
      await tester.pumpWidget(
        row('/tmp/keys/fedcba9876543210fedcba9876543210'),
      );
      expect(identical(lookup(), first), isFalse);

      // A plain name needs no lookup at all.
      await tester.pumpWidget(row('/tmp/other.key'));
      expect(find.text('other.key'), findsOneWidget);
      expect(find.byType(FutureBuilder<String>), findsNothing);
    });

    testWidgets('an in-memory name (generated key) renders without a path', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(KeyFileRow(name: 'generated.key', onPick: () {}, onClear: () {})),
      );

      expect(find.text('generated.key'), findsOneWidget);
    });
  });
}

class _GateBiometrics implements BiometricDataSource {
  _GateBiometrics(this.deviceCredentialResult);

  final bool deviceCredentialResult;

  @override
  Future<bool> isDeviceAuthSupported() async => true;

  @override
  Future<bool> authenticateWithDeviceCredential({
    required String reason,
  }) async => deviceCredentialResult;

  @override
  Future<bool> isBiometricAvailable() async => true;

  @override
  Future<bool> authenticate({required String reason}) async => true;
}
