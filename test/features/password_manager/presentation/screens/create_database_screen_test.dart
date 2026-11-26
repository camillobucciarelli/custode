// Spec 025 S3 (T301/T302/T305): the Create wizard on the Kv design system.
// Source selection, name validation, the three key modes through the row and
// sheet, the optional password, biometric availability, a refused submission
// that keeps the draft, and the web download-only outcome behind the
// capability override. Replaces the spec 015 T014 assertions that targeted
// stock Material widgets.
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/widgets/kv_switch.dart';
import 'package:password_manager/features/password_manager/domain/models/create_database_step.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_encryption.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_bloc.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_event.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_state.dart';
import 'package:password_manager/features/password_manager/presentation/screens/create_database_screen.dart';
import 'package:password_manager/features/password_manager/presentation/utils/platform_utils.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/source_option_card.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/key_file_picker.dart';

import '../coordinators/fake_database_ports.dart';
import 'database_selection_unlock_test_utils.dart';

const _webCapabilities = PlatformCapabilities(
  supportsRemoteSource: false,
  supportsBiometricUnlock: false,
  persistsDatabases: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    debugPlatformCapabilities = null;
    await resetDatabaseTestDi();
  });

  Future<DatabaseTestHarness> pumpWizard(
    WidgetTester tester, {
    bool biometricAvailable = false,
    FakeDatabaseSyncRepository? syncRepository,
  }) async {
    final result = await pumpableCreateDatabaseScreen(
      biometricAvailable: biometricAvailable,
      syncRepository: syncRepository,
    );
    await tester.pumpWidget(result.widget);
    await tester.pumpAndSettle();
    return result.harness;
  }

  Future<void> pumpWebWizard(WidgetTester tester) async {
    debugPlatformCapabilities = _webCapabilities;
    await pumpWizard(tester);
  }

  Future<void> goToCredentials(WidgetTester tester) async {
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  ElevatedButton primaryButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.byType(ElevatedButton));

  /// The KDF runs in a real isolate (`Isolate.run`), whose result arrives on
  /// the real event loop that fake-async pumps never advance.
  Future<void> prepareDownloads(WidgetTester tester) async {
    await tester.tap(find.text('Prepare downloads'));
    for (
      var i = 0;
      i < 400 && find.text('Download database').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> addGeneratedKey(WidgetTester tester) async {
    await tester.tap(find.text('Add a key file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate a new key file'));
    await tester.pumpAndSettle();
  }

  const password = 'kv-test-only-not-a-real-password';

  Future<void> enterPasswordAndConfirm(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), password);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), password);
    await tester.pumpAndSettle();
  }

  testWidgets('FR-X6: while creating, the action names the database', (
    tester,
  ) async {
    await pumpWizard(tester);
    await goToCredentials(tester);

    tester
        .element(find.byType(CreateDatabaseScreen))
        .read<DatabaseSelectionBloc>()
        // ignore: invalid_use_of_visible_for_testing_member
        .emit(
          const DatabaseSelectionCreateStep(
            CreateDatabaseStep.credentials,
            submitting: true,
          ),
        );
    // One frame delivers the stream event, the next builds from it.
    await tester.pump();
    await tester.pump();

    expect(find.text('Creating new_database.kdbx…'), findsOneWidget);
    expect(primaryButton(tester).onPressed, isNull);
  });

  group('FR-C2 step 1: where it lives', () {
    testWidgets('This device is the default and Drive offers Connect when '
        'signed out', (tester) async {
      await pumpWizard(tester);

      expect(find.text('Name and place'), findsOneWidget);
      expect(find.text('Step 1 of 2'), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('This device')),
        matchesSemantics(
          label: "This device, Stays in Custode's storage",
          isButton: true,
          isSelected: true,
          isEnabled: true,
          hasEnabledState: true,
          hasSelectedState: true,
          hasTapAction: true,
          isFocusable: false,
        ),
      );
    });

    testWidgets('Connect signs in once and selects Drive with its account', (
      tester,
    ) async {
      final sync = FakeDatabaseSyncRepository();
      sync.account = const StorageAccountSummary(
        displayLabel: 'mara@example.com',
        email: 'mara@example.com',
      );
      await pumpWizard(tester, syncRepository: sync);

      await tester.tap(find.text('Google Drive'));
      await tester.pumpAndSettle();

      expect(sync.connectCalls, 1);
      expect(find.text('mara@example.com'), findsOneWidget);
      expect(find.text('Connect'), findsNothing);
    });

    testWidgets('an already connected account is selectable without signing '
        'in again', (tester) async {
      final sync = FakeDatabaseSyncRepository()..connected = true;
      sync.account = const StorageAccountSummary(
        displayLabel: 'mara@example.com',
        email: 'mara@example.com',
      );
      await pumpWizard(tester, syncRepository: sync);

      expect(find.text('mara@example.com'), findsOneWidget);
      expect(find.text('Connect'), findsNothing);
      await tester.tap(find.text('Google Drive'));
      await tester.pumpAndSettle();
      expect(sync.connectCalls, 0);
    });

    testWidgets('a refused sign-in keeps This device and says so', (
      tester,
    ) async {
      final sync = _RefusingSyncRepository();
      await pumpWizard(tester, syncRepository: sync);

      await tester.tap(find.text('Google Drive'));
      await tester.pumpAndSettle();

      expect(find.text('Could not connect to Google Drive.'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
    });

    testWidgets('the capability override disables Drive in place with its '
        'reason and never signs in', (tester) async {
      final sync = FakeDatabaseSyncRepository();
      debugPlatformCapabilities = _webCapabilities;
      await pumpWizard(tester, syncRepository: sync);

      expect(find.text('Google Drive'), findsOneWidget);
      expect(find.text('Not available in the browser'), findsOneWidget);
      expect(find.text('Connect'), findsNothing);
      await tester.tap(find.text('Google Drive'));
      await tester.pumpAndSettle();
      expect(sync.connectCalls, 0);
    });

    testWidgets('the live caption names the file, with or without the '
        'extension', (tester) async {
      await pumpWizard(tester);
      expect(find.text('Saved as new_database.kdbx'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), 'Personal');
      await tester.pumpAndSettle();
      expect(find.text('Saved as Personal.kdbx'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), 'Work.KDBX');
      await tester.pumpAndSettle();
      expect(find.text('Saved as Work.KDBX'), findsOneWidget);
    });
  });

  group('FR-8 name validation blocks step 1', () {
    testWidgets('an invalid character disables Continue and shows the error', (
      tester,
    ) async {
      await pumpWizard(tester);

      await tester.enterText(find.byType(TextFormField), 'bad:name');
      await tester.pumpAndSettle();

      expect(find.text('Invalid characters in the name.'), findsOneWidget);
      expect(find.textContaining('Saved as'), findsNothing);
      expect(
        primaryButton(tester).onPressed,
        isNull,
        reason: 'FR-8: no silent sanitisation, the step must not advance',
      );
      expect(find.text('Name and place'), findsOneWidget);
    });

    testWidgets('an empty name blocks Continue', (tester) async {
      await pumpWizard(tester);

      await tester.enterText(find.byType(TextFormField), '   ');
      await tester.pumpAndSettle();

      expect(find.text('Enter a database name.'), findsOneWidget);
      expect(primaryButton(tester).onPressed, isNull);
    });

    testWidgets('a valid name advances to the single credentials step', (
      tester,
    ) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      expect(find.text('Protect it'), findsOneWidget);
      expect(find.text('Step 2 of 2'), findsOneWidget);
    });
  });

  group('FR-3 optional password', () {
    testWidgets('empty password: no confirmation field, no strength meter, '
        'and the inert submit states why', (tester) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      expect(find.text('Confirm password'), findsNothing);
      expect(find.text('Weak'), findsNothing);
      expect(primaryButton(tester).onPressed, isNull);
      expect(
        find.text(
          'Set a master password or choose a key file to protect the '
          'database.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('non-empty password: strength shown, confirmation mandatory, '
        'mismatch shown at the field', (tester) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      await tester.enterText(find.byType(TextFormField).at(0), password);
      await tester.pumpAndSettle();

      // Label and hint, both named for the field.
      expect(find.text('Confirm password'), findsWidgets);
      expect(find.text('Strong'), findsOneWidget);
      expect(find.text('Confirm the master password to continue.'), findsOne);

      await tester.enterText(find.byType(TextFormField).at(1), 'different');
      await tester.pumpAndSettle();

      expect(find.text('Passwords do not match.'), findsOneWidget);
      expect(primaryButton(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextFormField).at(1), password);
      await tester.pumpAndSettle();
      expect(primaryButton(tester).onPressed, isNotNull);
      expect(find.text('Create database'), findsOneWidget);
      expect(
        find.text('Opens right away, no need to type the password again.'),
        findsOneWidget,
      );
    });

    testWidgets('the eye toggles reveal each field', (tester) async {
      await pumpWizard(tester);
      await goToCredentials(tester);
      await tester.enterText(find.byType(TextFormField).at(0), password);
      await tester.pumpAndSettle();

      EditableText editable(int i) => tester.widget<EditableText>(
        find.descendant(
          of: find.byType(TextFormField).at(i),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable(0).obscureText, isTrue);
      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      expect(editable(0).obscureText, isFalse);
      expect(editable(1).obscureText, isTrue);
      await tester.tap(find.byTooltip('Show confirmation'));
      await tester.pumpAndSettle();
      expect(editable(1).obscureText, isFalse);
    });
  });

  group('FR-C3 key file row and sheet', () {
    testWidgets('the empty row offers both choices in a sheet', (tester) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      await tester.tap(find.text('Add a key file'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a file'), findsOneWidget);
      expect(find.text('Generate a new key file'), findsOneWidget);
    });

    testWidgets('generate is a factor by itself and shows the permanent '
        'FR-13 backup warning inline', (tester) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      await addGeneratedKey(tester);

      expect(
        find.text('New key file, created with the database'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Back up the generated key file: losing it makes the database '
          'inaccessible.',
        ),
        findsOneWidget,
      );
      expect(
        primaryButton(tester).onPressed,
        isNotNull,
        reason: 'FR-2: a generated key file is a valid sole factor',
      );
    });

    testWidgets('removing the key returns to none and removes the factor', (
      tester,
    ) async {
      await pumpWizard(tester);
      await goToCredentials(tester);
      await addGeneratedKey(tester);

      await tester.tap(find.byTooltip('Remove key file'));
      await tester.pumpAndSettle();

      expect(find.text('Add a key file'), findsOneWidget);
      expect(
        find.textContaining('Back up the generated key file'),
        findsNothing,
      );
      expect(primaryButton(tester).onPressed, isNull);
    });

    testWidgets('choose a file selects it as the sole factor and shows its '
        'name (bytes picker)', (tester) async {
      debugPlatformCapabilities = _webCapabilities;
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _BytesFilePicker();
      addTearDown(() => FilePickerPlatform.instance = original);
      await pumpWizard(tester);
      await goToCredentials(tester);

      await tester.tap(find.text('Add a key file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();

      expect(find.text('web.key'), findsOneWidget);
      expect(primaryButton(tester).onPressed, isNotNull);
      expect(find.byType(KeyFileRow), findsOneWidget);

      await tester.tap(find.byTooltip('Remove key file'));
      await tester.pumpAndSettle();
      expect(find.text('Add a key file'), findsOneWidget);
    });
  });

  group('biometric switch', () {
    testWidgets('disabled with its reason when the device has none', (
      tester,
    ) async {
      await pumpWizard(tester);
      await goToCredentials(tester);

      expect(find.text('Unlock with biometrics'), findsOneWidget);
      expect(find.text('Not available on this device'), findsOneWidget);
      await tester.tap(find.byType(KvSwitch));
      await tester.pumpAndSettle();
      expect(tester.widget<KvSwitch>(find.byType(KvSwitch)).value, isFalse);
    });

    testWidgets('toggles when the device offers biometrics', (tester) async {
      await pumpWizard(tester, biometricAvailable: true);
      await goToCredentials(tester);

      expect(find.text('Not available on this device'), findsNothing);
      await tester.tap(find.byType(KvSwitch));
      await tester.pumpAndSettle();
      expect(tester.widget<KvSwitch>(find.byType(KvSwitch)).value, isTrue);
    });
  });

  group('encryption', () {
    testWidgets('defaults to AES-256 with Argon2id and sends the sheet\'s '
        'choice with the create event', (tester) async {
      final events = <Object?>[];
      final previousObserver = Bloc.observer;
      Bloc.observer = _EventRecorder(events);
      addTearDown(() => Bloc.observer = previousObserver);

      await pumpWizard(tester);
      await goToCredentials(tester);
      expect(
        find.text('AES-256 \u00b7 Argon2id (recommended)'),
        findsOneWidget,
      );

      await tester.tap(find.text('Encryption'));
      await tester.pumpAndSettle();
      expect(
        find.text('The recommended setting suits almost everyone.'),
        findsOneWidget,
      );
      expect(find.text('Recommended'), findsNWidgets(2));
      const keePassNote = 'KeePass 2 needs a plugin to open it';
      Finder noteIn(String cipher) => find.descendant(
        of: find.widgetWithText(SourceOptionCard, cipher),
        matching: find.textContaining(keePassNote),
      );
      expect(noteIn('Twofish'), findsOneWidget);
      expect(noteIn('AES-256'), findsNothing);
      expect(noteIn('ChaCha20'), findsNothing);
      expect(
        tester.getSemantics(find.text('AES-256')),
        isSemantics(isSelected: true),
      );

      await tester.tap(find.text('ChaCha20'));
      await tester.pump();
      await tester.ensureVisible(find.text('AES-KDF'));
      await tester.tap(find.text('AES-KDF'));
      await tester.pump();
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.text('ChaCha20 \u00b7 AES-KDF'), findsOneWidget);

      await enterPasswordAndConfirm(tester);
      await tester.tap(find.text('Create database'));
      await tester.pumpAndSettle();

      final create = events.whereType<CreateNewDatabase>().single;
      expect(
        create.encryption,
        const VaultEncryption(
          cipher: VaultCipher.chaCha20,
          kdf: VaultKdf.aesKdf,
        ),
      );
    });

    testWidgets('dismissing the sheet keeps the previous choice', (
      tester,
    ) async {
      await pumpWizard(tester);
      await goToCredentials(tester);
      await tester.tap(find.text('Encryption'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Twofish'));
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(
        find.text('AES-256 \u00b7 Argon2id (recommended)'),
        findsOneWidget,
      );
    });
  });

  group('issue #276: system back is the on-screen back', () {
    testWidgets('from credentials it returns to step 1 with the draft', (
      tester,
    ) async {
      await pumpWizard(tester);
      await tester.enterText(find.byType(TextFormField), 'MyVault');
      await tester.pumpAndSettle();
      await goToCredentials(tester);
      expect(find.text('Protect it'), findsOneWidget);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();

      expect(find.byType(CreateDatabaseScreen), findsOneWidget);
      expect(find.text('Name and place'), findsOneWidget);
      expect(find.text('MyVault'), findsOneWidget);
    });

    testWidgets('from step 1 it leaves the wizard', (tester) async {
      await pumpWizard(tester);
      final bloc = tester
          .element(find.byType(CreateDatabaseScreen))
          .read<DatabaseSelectionBloc>();
      expect(bloc.state, isA<DatabaseSelectionCreateStep>());

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();

      expect(bloc.state, isNot(isA<DatabaseSelectionCreateStep>()));
    });
  });

  group('FR-10/FR-11 failure keeps the wizard mounted', () {
    testWidgets('a refused submission renders in the wizard with the draft '
        'intact', (tester) async {
      await pumpWizard(tester, biometricAvailable: true);
      await tester.enterText(find.byType(TextFormField), 'MyVault');
      await tester.pumpAndSettle();
      await goToCredentials(tester);

      // FR-11 refusal: biometrics on with no password to store.
      await addGeneratedKey(tester);
      await tester.tap(find.byType(KvSwitch));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create database'));
      await tester.pumpAndSettle();

      expect(find.byType(CreateDatabaseScreen), findsOneWidget);
      expect(find.text('Protect it'), findsOneWidget);
      expect(
        find.textContaining('Biometric unlock needs a master password'),
        findsOneWidget,
      );

      // Draft intact: going back shows the typed name.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('MyVault'), findsOneWidget);
    });
  });

  group('FR-C8 web download-only outcome (capability override)', () {
    testWidgets('keeps-nothing caption, a disabled biometric row in place, '
        'and the two-gesture order: the database download stays blocked '
        'until the key download is requested', (tester) async {
      await pumpWebWizard(tester);
      await goToCredentials(tester);

      expect(find.text('Unlock with biometrics'), findsOneWidget);
      expect(find.text('Not available on this device'), findsOneWidget);
      expect(
        find.textContaining('Reloading the page loses this draft'),
        findsOneWidget,
      );

      await addGeneratedKey(tester);
      expect(
        find.text('Downloads the database. The browser keeps nothing.'),
        findsOneWidget,
      );
      await prepareDownloads(tester);

      expect(find.text('Download key file'), findsOneWidget);
      final databaseButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Download database'),
      );
      expect(
        databaseButton.onPressed,
        isNull,
        reason:
            'FR-14: creation stays blocked until the key download has '
            'been requested',
      );
      expect(
        find.textContaining('Download the key file first'),
        findsOneWidget,
      );
    });

    testWidgets('password-only on web needs no key gesture and persists '
        'nothing', (tester) async {
      await pumpWebWizard(tester);
      await goToCredentials(tester);
      await enterPasswordAndConfirm(tester);

      await prepareDownloads(tester);

      expect(find.text('Download key file'), findsNothing);
      final databaseButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Download database'),
      );
      expect(databaseButton.onPressed, isNotNull);
    });
  });
}

class _EventRecorder extends BlocObserver {
  _EventRecorder(this.events);

  final List<Object?> events;

  @override
  void onEvent(Bloc<dynamic, dynamic> bloc, Object? event) {
    super.onEvent(bloc, event);
    events.add(event);
  }
}

class _RefusingSyncRepository extends FakeDatabaseSyncRepository {
  @override
  Future<void> connect() async => throw Exception('cancelled');
}

class _BytesFilePicker extends FilePickerPlatform {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    return FilePickerResult([
      PlatformFile(
        name: 'web.key',
        size: 3,
        bytes: Uint8List.fromList(const [1, 2, 3]),
      ),
    ]);
  }
}
