import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/domain/models/cloud_storage_error.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/sync/remote_file_picker.dart';

void main() {
  group('driveOpenErrorMessage', () {
    test('keeps the platform code and description of an unrecognized '
        'Google failure so field reports are diagnosable', () {
      final message = driveOpenErrorMessage(
        Exception(
          'Google sign-in failed (uiUnavailable): No Activity is available',
        ),
      );

      expect(message, contains('uiUnavailable'));
      expect(message, contains('No Activity is available'));
      expect(message, isNot(startsWith('Exception:')));
    });

    test('recognized failures keep their existing copy', () {
      expect(
        driveOpenErrorMessage(Exception('Google sign-in cancelled.')),
        'Google sign-in was cancelled during authorization. Please try again and grant Drive permissions.',
      );
      expect(
        driveOpenErrorMessage(Exception('something else entirely')),
        'Unable to open database from Google Drive.',
      );
    });

    // spec 010: typed provider failures map by code, never by toString().
    test('typed CloudStorageException maps by code', () {
      expect(
        driveOpenErrorMessage(
          const CloudStorageException(CloudStorageErrorCode.cancelled),
        ),
        'Google sign-in was cancelled during authorization. Please try again and grant Drive permissions.',
      );
      expect(
        driveOpenErrorMessage(
          const CloudStorageException(CloudStorageErrorCode.forbidden),
        ),
        'Google Drive permission was not granted. Enable Drive access and try again.',
      );
      expect(
        driveOpenErrorMessage(
          const CloudStorageException(
            CloudStorageErrorCode.authorizationRequired,
          ),
        ),
        'Google Drive session expired or unavailable. Use Reconnect below to sign in again.',
      );
      expect(
        driveOpenErrorMessage(
          const CloudStorageException(CloudStorageErrorCode.serverFailure),
        ),
        'Cloud storage service is temporarily unavailable.',
      );
    });
  });
}
