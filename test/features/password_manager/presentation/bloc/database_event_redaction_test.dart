import 'package:equatable/equatable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_selection/database_selection_event.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_event.dart';
import 'package:password_manager/features/password_manager/presentation/bloc/database_unlock/database_unlock_state.dart';

void main() {
  const masterPassword = 'qa-master-password-do-not-log';
  const keyFilePath = '/tmp/qa-key-file-do-not-log.key';
  const generatedKeyFilePath = '/tmp/generated-key-file-do-not-log.key';
  late bool previousStringify;

  setUp(() {
    previousStringify = EquatableConfig.stringify;
    EquatableConfig.stringify = true;
  });

  tearDown(() {
    EquatableConfig.stringify = previousStringify;
  });

  group('database event redaction', () {
    test('CreateNewDatabase redacts secrets from props and toString', () {
      const event = CreateNewDatabase(
        databaseFileName: 'vault.kdbx',
        password: masterPassword,
        keyFilePath: keyFilePath,
        biometricProtectionEnabled: true,
        generateKeyFile: true,
        generatedKeyFilePath: generatedKeyFilePath,
      );

      expect(event.props.toString(), isNot(contains(masterPassword)));
      expect(event.props.toString(), isNot(contains(keyFilePath)));
      expect(event.props.toString(), isNot(contains(generatedKeyFilePath)));
      expect(event.props.toString(), contains('<redacted>'));

      expect(event.toString(), isNot(contains(masterPassword)));
      expect(event.toString(), isNot(contains(keyFilePath)));
      expect(event.toString(), isNot(contains(generatedKeyFilePath)));
      expect(event.toString(), contains('<redacted>'));
    });

    test('CreateNewDatabase equality includes redacted values', () {
      const event = CreateNewDatabase(
        databaseFileName: 'vault.kdbx',
        password: masterPassword,
        keyFilePath: keyFilePath,
        generatedKeyFilePath: generatedKeyFilePath,
      );

      expect(event, equals(event));
      expect(
        event,
        equals(
          const CreateNewDatabase(
            databaseFileName: 'vault.kdbx',
            password: masterPassword,
            keyFilePath: keyFilePath,
            generatedKeyFilePath: generatedKeyFilePath,
          ),
        ),
      );
      expect(
        event,
        isNot(
          equals(
            const CreateNewDatabase(
              databaseFileName: 'vault.kdbx',
              password: 'different-password',
              keyFilePath: keyFilePath,
              generatedKeyFilePath: generatedKeyFilePath,
            ),
          ),
        ),
      );
      expect(
        event,
        isNot(
          equals(
            const CreateNewDatabase(
              databaseFileName: 'vault.kdbx',
              password: masterPassword,
              keyFilePath: '/tmp/different-key-file.key',
              generatedKeyFilePath: generatedKeyFilePath,
            ),
          ),
        ),
      );
    });

    test(
      'UnlockWithManualCredentials redacts secrets from props and toString',
      () {
        const event = UnlockWithManualCredentials(
          password: masterPassword,
          keyFilePath: keyFilePath,
        );

        expect(event.props.toString(), isNot(contains(masterPassword)));
        expect(event.props.toString(), isNot(contains(keyFilePath)));
        expect(event.props.toString(), contains('<redacted>'));

        expect(event.toString(), isNot(contains(masterPassword)));
        expect(event.toString(), isNot(contains(keyFilePath)));
        expect(event.toString(), contains('<redacted>'));
      },
    );

    test('UnlockWithManualCredentials equality includes redacted values', () {
      const event = UnlockWithManualCredentials(
        password: masterPassword,
        keyFilePath: keyFilePath,
      );

      expect(
        event,
        equals(
          const UnlockWithManualCredentials(
            password: masterPassword,
            keyFilePath: keyFilePath,
          ),
        ),
      );
      expect(
        event,
        isNot(
          equals(
            const UnlockWithManualCredentials(
              password: 'different-password',
              keyFilePath: keyFilePath,
            ),
          ),
        ),
      );
      expect(
        event,
        isNot(
          equals(
            const UnlockWithManualCredentials(
              password: masterPassword,
              keyFilePath: '/tmp/different-key-file.key',
            ),
          ),
        ),
      );
    });

    test('key file update event and unlock state redact key file paths', () {
      const event = UpdateKeyFilePath(keyFilePath);
      const state = DatabaseUnlockState(
        databasePath: '/tmp/vault.kdbx',
        keyFilePath: keyFilePath,
      );

      expect(event.props.toString(), isNot(contains(keyFilePath)));
      expect(event.toString(), isNot(contains(keyFilePath)));
      expect(event.toString(), contains('<redacted keyFilePath>'));

      expect(state.props.toString(), isNot(contains(keyFilePath)));
      expect(state.toString(), isNot(contains(keyFilePath)));
      expect(state.toString(), contains('<redacted keyFilePath>'));

      expect(event, isNot(equals(const UpdateKeyFilePath(null))));
      expect(
        state,
        isNot(
          equals(
            const DatabaseUnlockState(
              databasePath: '/tmp/vault.kdbx',
              keyFilePath: '/tmp/different-key-file.key',
            ),
          ),
        ),
      );
    });

    test('Drive selection redacts remote file identifier', () {
      const remoteFileId = 'drive-file-id-do-not-log';
      const event = SelectDriveDatabase(
        remoteProviderId: 'google_drive',
        remoteFileId: remoteFileId,
        remoteFileName: 'vault.kdbx',
      );

      expect(event.props.toString(), isNot(contains(remoteFileId)));
      expect(event.toString(), isNot(contains(remoteFileId)));
      expect(event.toString(), contains('<redacted remoteFileId>'));
    });
  });
}
