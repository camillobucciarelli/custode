import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:loggy/loggy.dart';

import '../../domain/errors/google_authorization_required_exception.dart';
import '../../domain/models/cloud_storage_error.dart';
import '../../domain/models/storage_account_summary.dart';
import '../datasources/google_token_data_source.dart';
import 'desktop_oauth_pkce_service.dart';
import 'google_oauth_config.dart';

class DriveAuthService {
  DriveAuthService({
    required this._config,
    required this._googleTokenDataSource,
    required this._desktopOAuthPkceService,
    this._isDesktopOverride,
  }) : _googleSignIn = GoogleSignIn.instance;

  final GoogleOAuthConfig _config;
  final GoogleTokenDataSource _googleTokenDataSource;
  final DesktopOAuthPkceService _desktopOAuthPkceService;
  final GoogleSignIn _googleSignIn;
  final bool? _isDesktopOverride;
  bool _googleSignInInitialized = false;
  String? _cachedAccessToken;
  DateTime? _cachedAccessTokenAt;
  Future<void>? _connectInFlight;

  static const _requiredDriveScope = 'https://www.googleapis.com/auth/drive';
  static const _mobileAccessTokenCacheTtl = Duration(minutes: 5);

  // `isDesktopOverride` lets tests set host platform independently of the
  // process host, matching the `platformOverride` convention already used by
  // BrowserSetupService.
  bool get _isDesktop =>
      _isDesktopOverride ??
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> _ensureGoogleSignInInitialized() async {
    if (_googleSignInInitialized) {
      return;
    }

    await _googleSignIn.initialize(
      clientId: Platform.isIOS ? _config.mobileClientId : null,
      serverClientId: Platform.isAndroid ? _config.androidServerClientId : null,
    );
    _googleSignInInitialized = true;
  }

  Future<void> connect() {
    final inFlight = _connectInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<void> operation;
    operation = Future.sync(_connect).whenComplete(() {
      if (identical(_connectInFlight, operation)) {
        _connectInFlight = null;
      }
    });
    _connectInFlight = operation;
    return operation;
  }

  Future<void> _connect() async {
    _clearCachedAccessToken();

    if (_isDesktop) {
      final clientId = _config.desktopClientId;
      final clientSecret = _config.desktopClientSecret;
      if (clientId == null || clientSecret == null) {
        throw _authenticationFailed(_desktopNotConfiguredHint);
      }

      final tokenSet = await _desktopOAuthPkceService.interactiveSignIn(
        clientId: clientId,
        clientSecret: clientSecret,
      );
      final hasRequiredScope = await _desktopOAuthPkceService
          .tokenContainsScope(
            accessToken: tokenSet.accessToken,
            requiredScope: _requiredDriveScope,
          );
      if (!hasRequiredScope) {
        await _googleTokenDataSource.clearDesktopCredentialsJson();
        // Token granted without the Drive scope: only a fresh consent fixes it.
        throw const CloudStorageException(
          CloudStorageErrorCode.authorizationRequired,
        );
      }
      await _googleTokenDataSource.saveDesktopCredentialsJson(
        tokenSet.toJson(),
      );
      return;
    }

    await _ensureGoogleSignInInitialized();

    final signedInUser = await _authenticateForDriveScopes();
    final authz = await _ensureDriveScopeAuthorization(signedInUser);
    _cacheAccessToken(authz.accessToken);
  }

  Future<void> disconnect() async {
    _clearCachedAccessToken();
    await _googleTokenDataSource.clearDesktopCredentialsJson();
    await _ensureGoogleSignInInitialized();

    try {
      await _googleSignIn.disconnect();
    } catch (_) {
      await _googleSignIn.signOut();
    }
  }

  Future<bool> isConnected() async {
    if (_isDesktop) {
      return (await _googleTokenDataSource.getDesktopCredentialsJson()) != null;
    }

    await _ensureGoogleSignInInitialized();
    final lightweightAttempt = _googleSignIn.attemptLightweightAuthentication();
    final current = lightweightAttempt == null
        ? null
        : await lightweightAttempt;
    return current != null;
  }

  Future<String> getValidAccessToken({bool forceRefresh = false}) async {
    if (_isDesktop) {
      final clientId = _config.desktopClientId;
      final clientSecret = _config.desktopClientSecret;
      if (clientId == null || clientSecret == null) {
        throw _authenticationFailed(_desktopNotConfiguredHint);
      }

      final raw = await _googleTokenDataSource.getDesktopCredentialsJson();
      if (raw == null || raw.trim().isEmpty) {
        throw const CloudStorageException(
          CloudStorageErrorCode.authorizationRequired,
        );
      }

      var tokenSet = DesktopOAuthTokenSet.fromJson(raw);
      if (forceRefresh || DateTime.now().isAfter(tokenSet.expiresAt)) {
        try {
          tokenSet = await _desktopOAuthPkceService.refreshToken(
            clientId: clientId,
            clientSecret: clientSecret,
            refreshToken: tokenSet.refreshToken,
          );
        } on GoogleAuthorizationRequiredException {
          _clearCachedAccessToken();
          try {
            await _googleTokenDataSource.clearDesktopCredentialsJson();
          } catch (_) {}
          rethrow;
        }
      }

      final hasRequiredScope = await _desktopOAuthPkceService
          .tokenContainsScope(
            accessToken: tokenSet.accessToken,
            requiredScope: _requiredDriveScope,
          );
      if (!hasRequiredScope) {
        await _googleTokenDataSource.clearDesktopCredentialsJson();
        throw const CloudStorageException(
          CloudStorageErrorCode.authorizationRequired,
        );
      }

      await _googleTokenDataSource.saveDesktopCredentialsJson(
        tokenSet.toJson(),
      );

      return tokenSet.accessToken;
    }

    await _ensureGoogleSignInInitialized();

    if (!forceRefresh && _hasFreshCachedAccessToken()) {
      return _cachedAccessToken!;
    }

    final lightweightAttempt = _googleSignIn.attemptLightweightAuthentication();
    var user = lightweightAttempt == null ? null : await lightweightAttempt;

    if (user == null) {
      _clearCachedAccessToken();
      throw const CloudStorageException(
        CloudStorageErrorCode.authorizationRequired,
      );
    }

    final authz = await _getExistingDriveScopeAuthorization(user);
    if (authz == null) {
      _clearCachedAccessToken();
      throw const CloudStorageException(
        CloudStorageErrorCode.authorizationRequired,
      );
    }

    final accessToken = authz.accessToken;
    if (accessToken.isEmpty) {
      _clearCachedAccessToken();
      throw _authenticationFailed('Google returned an empty access token.');
    }

    _cacheAccessToken(accessToken);
    return accessToken;
  }

  /// C-2: mobile obtains a real email from the current `GoogleSignInAccount`
  /// (lightweight re-authentication, no interactive prompt). Desktop
  /// Drive-only OAuth does not guarantee identity without expanding scopes,
  /// so it always returns the exact fallback.
  /// C-2: mobile reports the signed-in account's email. Desktop Drive-only
  /// OAuth cannot assert identity without widening the scope, so it returns
  /// the fixed fallback label — deliberately the Google product name, since
  /// Google Drive is the account the user connected.
  static const fallbackAccount = StorageAccountSummary(
    displayLabel: 'Google Drive account',
  );

  Future<StorageAccountSummary> getConnectedAccountSummary() async {
    if (_isDesktop) {
      return fallbackAccount;
    }

    await _ensureGoogleSignInInitialized();
    final lightweightAttempt = _googleSignIn.attemptLightweightAuthentication();
    final user = lightweightAttempt == null ? null : await lightweightAttempt;
    if (user == null || user.email.trim().isEmpty) {
      return fallbackAccount;
    }
    return StorageAccountSummary(displayLabel: user.email, email: user.email);
  }

  Future<GoogleSignInAccount> _authenticateForDriveScopes() async {
    try {
      return await _googleSignIn.authenticate(
        scopeHint: const [_requiredDriveScope],
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        final lightweightAttempt = _googleSignIn
            .attemptLightweightAuthentication();
        final user = lightweightAttempt == null
            ? null
            : await lightweightAttempt;
        if (user != null) {
          return user;
        }
      }
      throw _mapGoogleSignInException(e);
    }
  }

  Future<GoogleSignInClientAuthorization> _ensureDriveScopeAuthorization(
    GoogleSignInAccount user,
  ) async {
    try {
      final existing = await user.authorizationClient.authorizationForScopes(
        const [_requiredDriveScope],
      );
      if (existing != null) {
        return existing;
      }
      final granted = await user.authorizationClient.authorizeScopes(const [
        _requiredDriveScope,
      ]);
      return granted;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        final rehydratedUser = await _tryRecoverSignedInUser();
        if (rehydratedUser != null) {
          final recoveredAuthz = await rehydratedUser.authorizationClient
              .authorizationForScopes(const [_requiredDriveScope]);
          if (recoveredAuthz != null) {
            return recoveredAuthz;
          }
          // Signed in, but the Drive scope was declined on the consent
          // screen: access to the storage was denied by the user.
          throw const CloudStorageException(CloudStorageErrorCode.forbidden);
        }
      }
      throw _mapGoogleSignInException(e);
    }
  }

  Future<GoogleSignInClientAuthorization?> _getExistingDriveScopeAuthorization(
    GoogleSignInAccount user,
  ) async {
    try {
      return await user.authorizationClient.authorizationForScopes(const [
        _requiredDriveScope,
      ]);
    } on GoogleSignInException catch (e) {
      throw _mapGoogleSignInException(e);
    }
  }

  Future<GoogleSignInAccount?> _tryRecoverSignedInUser() async {
    final lightweightAttempt = _googleSignIn.attemptLightweightAuthentication();
    if (lightweightAttempt != null) {
      return lightweightAttempt;
    }
    return null;
  }

  bool _hasFreshCachedAccessToken() {
    final token = _cachedAccessToken;
    final issuedAt = _cachedAccessTokenAt;
    if (token == null || issuedAt == null || token.isEmpty) {
      return false;
    }

    return DateTime.now().difference(issuedAt) < _mobileAccessTokenCacheTtl;
  }

  void _cacheAccessToken(String token) {
    if (token.isEmpty) {
      _clearCachedAccessToken();
      return;
    }

    _cachedAccessToken = token;
    _cachedAccessTokenAt = DateTime.now();
  }

  void _clearCachedAccessToken() {
    _cachedAccessToken = null;
    _cachedAccessTokenAt = null;
  }

  static const _desktopNotConfiguredHint =
      'Desktop OAuth is not configured. Set GOOGLE_DESKTOP_CLIENT_ID and GOOGLE_DESKTOP_CLIENT_SECRET.';

  /// spec 010 T203: configuration and sign-in failures surface as the fixed
  /// `authenticationFailed` error. The app-authored [hint] (never SDK text,
  /// never a credential) goes to the log so a misconfigured build is still
  /// diagnosable from the field.
  CloudStorageException _authenticationFailed(String hint) {
    logWarning('Google sign-in unavailable: $hint');
    return const CloudStorageException(
      CloudStorageErrorCode.authenticationFailed,
    );
  }

  CloudStorageException _mapGoogleSignInException(
    GoogleSignInException exception,
  ) {
    if (exception.code == GoogleSignInExceptionCode.canceled) {
      return const CloudStorageException(CloudStorageErrorCode.cancelled);
    }
    if (exception.code == GoogleSignInExceptionCode.clientConfigurationError) {
      if (Platform.isAndroid) {
        return _authenticationFailed(
          'Android Google Sign-In is not configured. Set GOOGLE_WEB_CLIENT_ID in --dart-define-from-file.',
        );
      }
      if (Platform.isIOS) {
        return _authenticationFailed(
          'iOS Google Sign-In is not configured. Set GOOGLE_IOS_CLIENT_ID in --dart-define-from-file.',
        );
      }
    }
    // Only the SDK's enum code is logged; the description is free text.
    return _authenticationFailed(
      'Google sign-in failed (${exception.code.name}).',
    );
  }
}
