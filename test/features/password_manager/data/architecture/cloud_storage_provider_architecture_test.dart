import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// spec 010 T004 — architecture guard for the cloud storage provider port.
//
// Source-level assertions, split in two tiers:
//
//  * BASELINE assertions describe what is already true on main and run
//    unconditionally, so any drift fails immediately.
//  * TARGET assertions describe the post-refactor shape. Each is committed
//    `skip`ped with the task ID that makes it true (constitution IX forbids
//    committing a red suite); that task's diff removes the skip. The
//    identifier lists below are owned by spec.md acceptance criterion 3 and
//    plan.md M6 — do not extend them here without changing the spec.

const _feature = 'lib/features/password_manager';
const _domain = '$_feature/domain';
const _presentation = '$_feature/presentation';
const _orchestrator = '$_feature/data/services/database_sync_orchestrator.dart';

/// spec.md acceptance criterion 3 — banned contract/state identifiers.
// Each name is split across two adjacent string literals (concatenated at
// compile time) so this file — which has to spell the list out — is not
// itself a hit for the pattern it enforces.
const _bannedIdentifiers = [
  'Drive'
      'RemoteFile',
  'Drive'
      'AccountSummary',
  'Drive'
      'PickerData',
  'LoadDrive'
      'RemoteFiles',
  'linkedDrive'
      'FileName',
  'remoteDrive'
      'Files',
  'getDrive'
      'PickerData',
  'linkDatabase'
      'ToDrive',
];

/// plan.md M6 — the only places the v1 serialized keys may still appear.
const _legacyKeyAllowlist = [
  '$_domain/models/database_sync_mapping.dart',
  'test/features/password_manager/domain/models/database_sync_mapping_test.dart',
  'test/features/password_manager/data/datasources/sync_metadata_data_source_test.dart',
];

/// plan.md M6 — every `*Drive*` identifier presentation may still use, each
/// an intentional Google product action/label. Names, never globs.
const _presentationDriveAllowlist = <String>{
  // VaultEvent product actions.
  'ConnectGoogleDrive',
  'DisconnectGoogleDrive',
  'LinkCurrentDatabaseToDrive',
  'UnlinkCurrentDatabaseFromDrive',
  'BackgroundDriveSync',
  'SelectDriveDatabase',
  'GoogleDriveReconnectSucceeded',
  'GoogleDriveReconnectFailed',
  // VaultState flags naming the Google Drive product connection/link.
  'isDriveConnected',
  'isDriveLinked',
  'driveReconnectRequired',
  // Coordinators / router results / widgets that are Google Drive UI.
  'GoogleDriveReconnectCoordinator',
  'GoogleDriveReconnectContinuation',
  'selectDriveDatabase',
  'stageDriveDownload',
  'DriveLinkResult',
  'ExistingDriveLinkResult',
  'NewDriveLinkResult',
  'driveOpenErrorMessage',
  // Private handlers/helpers inside the above surfaces.
  '_onConnectGoogleDrive',
  '_onDisconnectGoogleDrive',
  '_onLinkCurrentDatabaseToDrive',
  '_onUnlinkCurrentDatabaseFromDrive',
  '_onBackgroundDriveSync',
  '_onSelectDriveDatabase',
  '_onGoogleDriveReconnectSucceeded',
  '_onGoogleDriveReconnectFailed',
  '_emitDriveAuthorizationRequired',
  '_requiresDrivePermissionReauth',
  '_buildDriveConnectErrorMessage',
  '_driveAuthorizationRequiredMessage',
  '_preloadDriveStateFromLocalMapping',
  '_prepareDriveDuplicate',
  '_pickExistingDriveFile',
  '_createNewDriveFile',
};

/// Google *service* names may appear in a presentation TEST that wires the
/// real Google stack behind a fake repository to prove an auth failure
/// reaches BLoC state (`vault_bloc_background_sync_test.dart`). They may
/// never appear in production presentation — asserted separately below.
const _testOnlyGoogleServiceNames = <String>{
  'GoogleDriveApiService',
  'listKdbxFilesInDrive',
};

void main() {
  group('baseline (green on main)', () {
    test('domain imports no Google SDK, HTTP transport or data services', () {
      final offenders = _filesUnder(_domain).where(
        (f) => _importsAny(f, const [
          'package:google_sign_in',
          'package:googleapis',
          'package:http/',
          '/data/',
        ]),
      );
      expect(offenders, isEmpty);
    });

    test(
      'presentation imports no Google SDK, HTTP or Google data services',
      () {
        final offenders = _filesUnder(_presentation).where(
          (f) => _importsAny(f, const [
            'package:google_sign_in',
            'package:googleapis',
            'package:http/',
            'data/services/google_',
            'data/services/drive_',
            'data/services/desktop_oauth_',
          ]),
        );
        expect(offenders, isEmpty);
      },
    );

    test('no provider registry, factory or provider map exists', () {
      final offenders = _filesUnder('lib').where(
        (f) => RegExp(
          r'CloudStorageProviderRegistry|CloudStorageProviderFactory|Map<String,\s*CloudStorageProvider>',
        ).hasMatch(_read(f)),
      );
      expect(offenders, isEmpty);
    });

    test('presentation never imports the provider port', () {
      final offenders = _filesUnder(_presentation)
          .where((f) => _read(f).contains('cloud_storage_provider.dart'));
      expect(offenders, isEmpty);
    });
  });

  group('target (enabled by the task that makes it true)', () {
    test('T301: orchestrator has no Google/Drive dependency', () {
      final source = _read(_orchestrator);
      expect(
        RegExp(
          r'GoogleDriveApiService|DriveAuthService|drive_remote_file|drive_account_summary|google_drive_api_service|drive_auth_service',
        ).hasMatch(source),
        isFalse,
      );
      expect(source, contains('CloudStorageProvider'));
    });

    test('T501: exactly one port, exactly one production implementation', () {
      final ports = _filesUnder(
        'lib',
      ).where((f) => _read(f).contains('abstract class CloudStorageProvider'));
      final impls = _filesUnder('lib').where(
        (f) =>
            RegExp(r'class \w+ implements CloudStorageProvider')
                .hasMatch(_read(f)),
      );
      expect(ports, hasLength(1));
      expect(impls, hasLength(1));
    });

    test('T601b: banned identifiers have zero references in lib and test', () {
      final pattern = RegExp(_bannedIdentifiers.join('|'));
      final offenders = [
        ..._filesUnder('lib'),
        ..._filesUnder('test'),
      ].where((f) => pattern.hasMatch(_read(f)));
      expect(offenders, isEmpty);
    });

    test(
      'T601b: v1 keys survive only in the decoder and migration fixtures',
      () {
        // The literal v1 keys, deliberately built from parts so this guard's
        // own source is not a hit for the pattern it enforces.
        final pattern = RegExp(
          'drive'
          r'FileId|'
          'drive'
          r'FileName',
        );
        final offenders = [..._filesUnder('lib'), ..._filesUnder('test')]
            .where((f) => pattern.hasMatch(_read(f)))
            .where((f) => !_legacyKeyAllowlist.contains(f));
        expect(offenders, isEmpty);
      },
    );

    test('T601b: every *Drive* identifier in presentation is individually allowlisted', () {
      final pattern = RegExp(r'\b[A-Za-z_][A-Za-z0-9_]*Drive[A-Za-z0-9_]*\b');
      Set<String> namesIn(List<String> files) => {
        for (final f in files)
          ...pattern.allMatches(_read(f)).map((m) => m.group(0)!),
      };

      final production = namesIn(_filesUnder(_presentation));
      expect(
        production.difference(_presentationDriveAllowlist),
        isEmpty,
        reason: 'production presentation names',
      );
      expect(
        production.intersection(_testOnlyGoogleServiceNames),
        isEmpty,
        reason: 'a Google service name reached production presentation',
      );

      final tests = namesIn([
        ..._filesUnder('test/features/password_manager/presentation'),
        ..._filesUnder('test/goldens'),
      ]);
      expect(
        tests.difference(
          _presentationDriveAllowlist.union(_testOnlyGoogleServiceNames),
        ),
        isEmpty,
        reason: 'presentation test names',
      );
    });
  });
}

List<String> _filesUnder(String root) =>
    Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        // Separators normalised so the `/`-written allowlists above match on
        // Windows too, where `listSync` yields `\`.
        .map((f) => f.path.replaceAll('\\', '/'))
        .where((p) => p.endsWith('.dart'))
        .toList()
      ..sort();

String _read(String path) => File(path).readAsStringSync();

bool _importsAny(String path, List<String> needles) {
  final imports = _read(path)
      .split('\n')
      .where((line) => line.startsWith('import '));
  return imports.any((line) => needles.any(line.contains));
}
