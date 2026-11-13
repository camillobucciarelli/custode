import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/data/datasources/google_token_data_source.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_oauth_pkce_service.dart';
import 'package:password_manager/features/password_manager/data/services/drive_auth_service.dart';
import 'package:password_manager/features/password_manager/data/services/google_oauth_config.dart';
import 'package:password_manager/features/password_manager/domain/errors/google_authorization_required_exception.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file_selection_data.dart';
import 'package:password_manager/features/password_manager/domain/models/storage_account_summary.dart';
import 'package:password_manager/features/password_manager/domain/models/remote_file.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/database/drive_picker_sheet.dart';
import 'package:xml/xml.dart';

const _iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
const _syntheticDesktopConfig = GoogleOAuthConfig(
  mobileClientId: null,
  androidServerClientId: null,
  desktopClientId: 'synthetic-desktop-client-id',
  desktopClientSecret: 'synthetic-desktop-client-secret',
);

void main() {
  test('iOS registers a Google callback under CFBundleURLTypes', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final schemes = _iosUrlSchemes(plist);
    final reindented = XmlDocument.parse(plist)
        .toXmlString(pretty: true, indent: '  ');

    expect(_iosUrlSchemes(reindented), schemes);
    expect(
      schemes.any(
        (scheme) =>
            RegExp(r'^com\.googleusercontent\.apps\.[A-Za-z0-9._-]+$')
                .hasMatch(scheme),
      ),
      isTrue,
    );
  });

  test(
    'iOS callback matches GOOGLE_IOS_CLIENT_ID',
    () {
      final callbackScheme =
          'com.googleusercontent.apps.${_iosClientId.replaceFirst('.apps.googleusercontent.com', '')}';

      expect(
        _iosUrlSchemes(File('ios/Runner/Info.plist').readAsStringSync())
            .contains(callbackScheme),
        isTrue,
        reason: 'Installed iOS callback scheme does not match OAuth config.',
      );
    },
    skip: _iosClientId.isEmpty
        ? 'GOOGLE_IOS_CLIENT_ID not supplied; exact release contract is manual.'
        : false,
  );

  test('macOS Drive connect reaches PKCE with synthetic config', () async {
    final httpClient = http.Client();
    addTearDown(httpClient.close);
    final pkce = _RecordingPkceService(httpClient: httpClient);
    final auth = DriveAuthService(
      config: _syntheticDesktopConfig,
      googleTokenDataSource: _NoopGoogleTokenDataSource(),
      desktopOAuthPkceService: pkce,
      isDesktopOverride: true,
    );

    await expectLater(
      auth.connect(),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Unable to open system browser'),
        ),
      ),
    );
    expect(pkce.receivedExpectedConfig, isTrue);
  });

  testWidgets('Drive sheet exposes iOS and macOS auth errors', (tester) async {
    const cases = [
      (
        error: 'iOS Google Sign-In is not configured.',
        visible:
            'iOS Google Sign-In is not configured. Check GOOGLE_IOS_CLIENT_ID.',
      ),
      (
        error: 'Desktop OAuth is not configured. Set GOOGLE_DESKTOP_CLIENT_ID and GOOGLE_DESKTOP_CLIENT_SECRET.',
        visible: 'Desktop Google Sign-In is not configured. Check GOOGLE_DESKTOP_CLIENT_ID and GOOGLE_DESKTOP_CLIENT_SECRET.',
      ),
      (
        error: 'Unable to open system browser for Google sign-in.',
        visible: 'Unable to open the system browser for Google sign-in. Check your default browser and try again.',
      ),
      (
        error: 'Google authentication timeout.',
        visible: 'Google sign-in timed out. Complete authorization in your browser and try again.',
      ),
    ];

    for (final testCase in cases) {
      await tester.pumpWidget(
        _driveSheetHost(() async => throw Exception(testCase.error)),
      );
      await _tapAndExpect(tester, testCase.visible);
    }
  });

  testWidgets(
    'expired authorization stays open and reconnect retries load once',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _driveSheetHost(() async {
          calls += 1;
          if (calls == 1) {
            throw const GoogleAuthorizationRequiredException();
          }
          return const RemoteFileSelectionData(
            files: [
              RemoteFile(
                providerId: 'google_drive',
                id: 'remote-1',
                name: 'Vault.kdbx',
              ),
            ],
            account: StorageAccountSummary(
              displayLabel: 'Google Drive account',
            ),
          );
        }),
      );

      await tester.tap(find.text('Connect Google Drive'));
      await tester.pumpAndSettle();

      expect(find.text('Open from Google Drive'), findsOneWidget);
      expect(find.text('Google authorization expired'), findsOneWidget);
      expect(
        find.text(
          'Google Drive session expired or unavailable. Use Reconnect below to sign in again.',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Reconnect Google Drive'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(find.text('Open from Google Drive'), findsOneWidget);
      expect(find.text('Vault.kdbx'), findsOneWidget);
    },
  );

  testWidgets('cancelled reconnect stays open and Retry can succeed', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _driveSheetHost(() async {
        calls += 1;
        if (calls == 1) {
          throw const GoogleAuthorizationRequiredException();
        }
        if (calls == 2) {
          throw Exception('Google sign-in cancelled.');
        }
        return const RemoteFileSelectionData(
          files: [
            RemoteFile(
              providerId: 'google_drive',
              id: 'remote-1',
              name: 'Vault.kdbx',
            ),
          ],
          account: StorageAccountSummary(displayLabel: 'Google Drive account'),
        );
      }),
    );

    await tester.tap(find.text('Connect Google Drive'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
    await tester.pumpAndSettle();

    expect(find.text('Open from Google Drive'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      find.text(
        'Google sign-in was cancelled during authorization. Please try again and grant Drive permissions.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(calls, 3);
    expect(find.text('Vault.kdbx'), findsOneWidget);
  });

  testWidgets('an untyped stale-grant failure reads as expired authorization', (
    tester,
  ) async {
    // spec 010 types most provider failures, but `driveOpenErrorMessage`
    // still routes untyped exceptions by message. A type-only predicate let
    // the heading and button say "Unable to connect"/"Retry" above a body
    // telling the user to press Reconnect.
    await tester.pumpWidget(
      _driveSheetHost(
        () async => throw Exception(
          'Google Drive authorization needs to be renewed with full Drive access.',
        ),
      ),
    );

    await tester.tap(find.text('Connect Google Drive'));
    await tester.pumpAndSettle();

    expect(find.text('Google authorization expired'), findsOneWidget);
    expect(find.text('Unable to connect to Google Drive'), findsNothing);
    expect(
      find.text(
        'Google Drive session expired or unavailable. Use Reconnect below to sign in again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.bySemanticsLabel('Reconnect Google Drive'), findsOneWidget);
  });

  testWidgets(
    'Reconnect runs the forced-reconnect loader, not the plain load',
    (tester) async {
      var loads = 0;
      var reconnects = 0;
      await tester.pumpWidget(
        _driveSheetHost(
          () async {
            loads += 1;
            throw Exception('Google account not connected. Please reconnect.');
          },
          reconnectPickerData: () async {
            reconnects += 1;
            return const RemoteFileSelectionData(
              files: [
                RemoteFile(
                  providerId: 'google_drive',
                  id: 'remote-1',
                  name: 'Vault.kdbx',
                ),
              ],
              account: StorageAccountSummary(
                displayLabel: 'Google Drive account',
              ),
            );
          },
        ),
      );

      await tester.tap(find.text('Connect Google Drive'));
      await tester.pumpAndSettle();
      expect(loads, 1);

      await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
      await tester.pumpAndSettle();

      expect(loads, 1);
      expect(reconnects, 1);
      expect(find.text('Vault.kdbx'), findsOneWidget);
    },
  );

  testWidgets('a non-authorization failure still retries the plain load', (
    tester,
  ) async {
    var loads = 0;
    var reconnects = 0;
    await tester.pumpWidget(
      _driveSheetHost(
        () async {
          loads += 1;
          if (loads == 1) {
            throw Exception('Google sign-in cancelled.');
          }
          return const RemoteFileSelectionData(
            files: [
              RemoteFile(
                providerId: 'google_drive',
                id: 'remote-1',
                name: 'Vault.kdbx',
              ),
            ],
            account: StorageAccountSummary(
              displayLabel: 'Google Drive account',
            ),
          );
        },
        reconnectPickerData: () async {
          reconnects += 1;
          throw StateError('reconnect must not run for a cancelled sign-in');
        },
      ),
    );

    await tester.tap(find.text('Connect Google Drive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(reconnects, 0);
    expect(loads, 2);
    expect(find.text('Vault.kdbx'), findsOneWidget);
  });

  testWidgets('rapid reconnect taps start one retry', (tester) async {
    var calls = 0;
    final retry = Completer<RemoteFileSelectionData>();
    await tester.pumpWidget(
      _driveSheetHost(() {
        calls += 1;
        if (calls == 1) {
          throw const GoogleAuthorizationRequiredException();
        }
        return retry.future;
      }),
    );

    await tester.tap(find.text('Connect Google Drive'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
    await tester.tap(find.bySemanticsLabel('Reconnect Google Drive'));
    await tester.pump();

    expect(calls, 2);
    expect(find.text('Connecting...'), findsOneWidget);
    expect(find.bySemanticsLabel('Reconnect Google Drive'), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Connecting...'),
          )
          .onPressed,
      isNull,
    );

    retry.complete(
      const RemoteFileSelectionData(
        files: [
          RemoteFile(
            providerId: 'google_drive',
            id: 'remote-1',
            name: 'Vault.kdbx',
          ),
        ],
        account: StorageAccountSummary(displayLabel: 'Google Drive account'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Vault.kdbx'), findsOneWidget);
  });
}

List<String> _iosUrlSchemes(String plist) {
  final root = XmlDocument.parse(plist).rootElement.getElement('dict');
  final urlTypes = root == null ? null : _plistValue(root, 'CFBundleURLTypes');
  if (urlTypes == null || urlTypes.name.local != 'array') return const [];

  return urlTypes.findElements('dict').expand((urlType) {
    final schemes = _plistValue(urlType, 'CFBundleURLSchemes');
    return schemes?.findElements('string').map((value) => value.innerText) ??
        const Iterable<String>.empty();
  }).toList();
}

XmlElement? _plistValue(XmlElement dictionary, String key) {
  final values = dictionary.childElements.toList();
  for (var index = 0; index + 1 < values.length; index++) {
    if (values[index].name.local == 'key' && values[index].innerText == key) {
      return values[index + 1];
    }
  }
  return null;
}

Widget _driveSheetHost(
  Future<RemoteFileSelectionData> Function() loadPickerData, {
  Future<RemoteFileSelectionData> Function()? reconnectPickerData,
}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDrivePickerSheet(
          context,
          loadPickerData: loadPickerData,
          reconnectPickerData: reconnectPickerData,
        ),
        child: const Text('Connect Google Drive'),
      ),
    ),
  );
}

Future<void> _tapAndExpect(WidgetTester tester, String visible) async {
  await tester.tap(find.text('Connect Google Drive'));
  await tester.pumpAndSettle();
  final message = find.text(visible);
  expect(message, findsOneWidget);
  Navigator.of(tester.element(message)).pop();
  await tester.pumpAndSettle();
}

class _NoopGoogleTokenDataSource implements GoogleTokenDataSource {
  @override
  Future<void> clearDesktopCredentialsJson() async {}

  @override
  Future<String?> getDesktopCredentialsJson() async => null;

  @override
  Future<void> saveDesktopCredentialsJson(String json) async {}
}

class _RecordingPkceService extends DesktopOAuthPkceService {
  _RecordingPkceService({required super.httpClient});

  bool receivedExpectedConfig = false;

  @override
  Future<DesktopOAuthTokenSet> interactiveSignIn({
    required String clientId,
    required String clientSecret,
  }) async {
    receivedExpectedConfig =
        clientId == _syntheticDesktopConfig.desktopClientId &&
        clientSecret == _syntheticDesktopConfig.desktopClientSecret;
    throw Exception('Unable to open system browser for Google sign-in.');
  }
}
