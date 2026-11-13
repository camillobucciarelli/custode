import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'desktop_browser_autofill_cache.dart';

/// Result of installing the desktop native messaging host.
enum NativeHostInstallResult {
  success,
  invalidExtensionId,
  scriptNotFound,
  unsupportedPlatform,
  failed,
}

enum NativeHostBrowser { chrome, edge, chromium }

enum BrowserSetupHostPlatform { macOS, windows, linux, unsupported }

class NativeHostInstallCommand {
  const NativeHostInstallCommand({
    required this.executable,
    required this.arguments,
    required this.displayCommand,
  });

  final String executable;
  final List<String> arguments;
  final String displayCommand;
}

typedef NativeHostProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Result of verifying desktop browser autofill connectivity.
enum BridgeCheckResult {
  connected,
  notRunning,
  noConfig,
  v2AppBridgeUnavailable,
}

class BrowserSetupService {
  BrowserSetupService({
    DesktopBrowserAutofillCacheStore? cacheStore,
    this._projectRoot,
    this._platformOverride,
    NativeHostProcessRunner? processRunner,
  }) : _cacheStore = cacheStore ?? DesktopBrowserAutofillCacheStore(),
       _processRunner = processRunner ?? Process.run;

  static final RegExp _extensionIdPattern = RegExp(r'^[a-p]{32}$');
  static const _bridgeProbeTimeout = Duration(seconds: 2);
  static const chromeExtensionId = 'ogjmlkogmogijgpflnjifiobdmnmommh';
  static const chromeStoreListingUrl =
      'https://chromewebstore.google.com/detail/$chromeExtensionId';
  static const macOSChromeSupportPackageUrl =
      'https://github.com/camillobucciarelli/custode/'
      'releases/latest/download/keyvault-chrome-support-macos.pkg';

  /// Where a build that does not bundle the native host (the Microsoft Store
  /// MSIX, see issue #209: MSIX virtualization hides the host's registry and
  /// file writes from Chrome/Edge) sends the user to get the sideload zip,
  /// which does bundle it.
  static const sideloadReleasesUrl =
      'https://github.com/camillobucciarelli/custode/'
      'releases/latest';

  final DesktopBrowserAutofillCacheStore _cacheStore;
  final Directory? _projectRoot;
  final BrowserSetupHostPlatform? _platformOverride;
  final NativeHostProcessRunner _processRunner;

  // ---------------------------------------------------------------------------
  // Bridge connectivity check
  // ---------------------------------------------------------------------------

  /// Returns whether the Flutter desktop app bridge is running and reachable.
  Future<BridgeCheckResult> checkBridgeConnection() async {
    if (!_isDesktop) return BridgeCheckResult.notRunning;
    final cache = await _cacheStore.readMetadataCache();
    if (cache == null) return BridgeCheckResult.noConfig;
    final descriptor = await _cacheStore.readBridgeDescriptor();
    if (descriptor == null || descriptor.databaseId != cache.databaseId) {
      return BridgeCheckResult.v2AppBridgeUnavailable;
    }
    return await _probeBridge(descriptor)
        ? BridgeCheckResult.connected
        : BridgeCheckResult.v2AppBridgeUnavailable;
  }

  Future<bool> _probeBridge(
    DesktopBrowserAutofillBridgeDescriptor descriptor,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = _bridgeProbeTimeout
      ..findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final request = await client.postUrl(
          Uri(
            scheme: 'http',
            host: InternetAddress.loopbackIPv4.address,
            port: descriptor.port,
            path: '/status',
          ),
        );
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${descriptor.token}',
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) return false;
        final decoded = jsonDecode(await utf8.decoder.bind(response).join());
        if (decoded is! Map || decoded['ok'] != true) return false;
        final data = decoded['data'];
        return data is Map && data['databaseId'] == descriptor.databaseId;
      })().timeout(_bridgeProbeTimeout);
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Native host installation
  // ---------------------------------------------------------------------------

  Future<NativeHostInstallResult> installNativeHost() {
    return registerNativeHost(
      browser: NativeHostBrowser.chrome,
      extensionId: chromeExtensionId,
    );
  }

  Future<NativeHostInstallResult> registerNativeHost({
    required NativeHostBrowser browser,
    required String extensionId,
  }) async {
    final command = nativeHostInstallCommand(
      browser: browser,
      extensionId: extensionId,
    );
    if (!isValidExtensionId(extensionId)) {
      return NativeHostInstallResult.invalidExtensionId;
    }
    if (!_isDesktop) return NativeHostInstallResult.unsupportedPlatform;
    if (command == null) return NativeHostInstallResult.scriptNotFound;

    try {
      final result = await _processRunner(
        command.executable,
        command.arguments,
      );
      return result.exitCode == 0
          ? NativeHostInstallResult.success
          : NativeHostInstallResult.failed;
    } catch (e, st) {
      debugPrint('[BrowserSetup] native-host registration failed: $e\n$st');
      return NativeHostInstallResult.failed;
    }
  }

  NativeHostInstallCommand? nativeHostInstallCommand({
    required NativeHostBrowser browser,
    required String extensionId,
  }) {
    final normalizedExtensionId = extensionId.trim();
    if (!isValidExtensionId(normalizedExtensionId)) return null;
    final platform = _hostPlatform;
    if (!_supportsBrowser(platform, browser)) return null;
    final script = _installScriptPath(platform);
    if (script == null) return null;

    final arguments = _installScriptArguments(
      platform: platform,
      browser: browser,
      scriptPath: script,
      extensionId: normalizedExtensionId,
    );
    return NativeHostInstallCommand(
      executable: _installScriptExecutable(platform),
      arguments: arguments,
      displayCommand: nativeHostInstallCommandText(
        browser: browser,
        extensionId: normalizedExtensionId,
      ),
    );
  }

  String nativeHostInstallCommandText({
    required NativeHostBrowser browser,
    String extensionId = '<EXTENSION_ID>',
  }) {
    final platform = _hostPlatform;
    final scriptPath = _installScriptPath(platform);
    final script = scriptPath == null
        ? _defaultInstallScriptDisplayPath(platform)
        : _displayPath(scriptPath, platform: platform);
    final browserArg = _browserScriptArgument(browser, platform);

    switch (platform) {
      case BrowserSetupHostPlatform.macOS:
        return '$script $browserArg $extensionId';
      case BrowserSetupHostPlatform.linux:
        return '$script --browser $browserArg $extensionId';
      case BrowserSetupHostPlatform.windows:
        return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File '
            '$script -Browser $browserArg -ExtensionId $extensionId';
      case BrowserSetupHostPlatform.unsupported:
        return 'Native Messaging install non supportato su questa piattaforma';
    }
  }

  String? get nativeHostBuildCommandText {
    final root = _projectRootPath;
    if (root == null) return null;
    final script = p.join(root, 'tool', 'build_native_host.sh');
    if (!File(script).existsSync()) return null;
    return _displayPath(script, platform: _hostPlatform);
  }

  bool get canRunNativeHostInstaller =>
      _isDesktop && _installScriptPath(_hostPlatform) != null;

  List<NativeHostBrowser> get supportedBrowsers {
    switch (_hostPlatform) {
      case BrowserSetupHostPlatform.macOS:
      case BrowserSetupHostPlatform.windows:
        return const [NativeHostBrowser.chrome, NativeHostBrowser.edge];
      case BrowserSetupHostPlatform.linux:
        return const [
          NativeHostBrowser.chrome,
          NativeHostBrowser.chromium,
          NativeHostBrowser.edge,
        ];
      case BrowserSetupHostPlatform.unsupported:
        return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // Stale user-level manifest detection (2026-08-31)
  // ---------------------------------------------------------------------------

  /// Chromium browsers read the per-user Native Messaging manifest BEFORE
  /// the system-level one, so an old dev registration in a user directory —
  /// pointing at an unpacked extension id — silently shadows a correctly
  /// installed production package and the store extension reports the host
  /// as "not found".
  ///
  /// Checked per browser (Chrome, Edge, Brave, Vivaldi, Chromium, Opera —
  /// Arc reads Chrome's directories). A user manifest is flagged only when
  /// BOTH hold: it does not allow [extensionId] (the store id), and that
  /// browser's system-level manifest exists (a production install is
  /// present to fall back to). A lone user-level dev manifest is a
  /// legitimate dev setup and is left alone.
  Future<List<File>> staleUserManifests({
    String extensionId = chromeExtensionId,
  }) async {
    if (kIsWeb) return const [];
    final stale = <File>[];
    for (final pair in _manifestDirectoryPairs()) {
      final userFile = File(p.join(pair.user, '$nativeHostName.json'));
      if (!userFile.existsSync()) continue;
      if (!File(p.join(pair.system, '$nativeHostName.json')).existsSync()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await userFile.readAsString());
        final origins = decoded is Map ? decoded['allowed_origins'] : null;
        if (origins is List &&
            origins.contains('chrome-extension://$extensionId/')) {
          continue;
        }
      } catch (_) {
        // Unreadable manifest shadows the system one all the same.
      }
      stale.add(userFile);
    }
    return stale;
  }

  /// Deletes every manifest found by [staleUserManifests]. Returns true when
  /// nothing stale remains afterwards.
  Future<bool> removeStaleUserManifests({
    String extensionId = chromeExtensionId,
  }) async {
    var allRemoved = true;
    for (final file in await staleUserManifests(extensionId: extensionId)) {
      try {
        await file.delete();
      } catch (_) {
        allRemoved = false;
      }
    }
    return allRemoved;
  }

  /// (user directory, system directory) per supported browser on this
  /// platform. Windows registers manifests via the registry — out of scope.
  List<({String user, String system})> _manifestDirectoryPairs() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return const [];
    switch (_hostPlatform) {
      case BrowserSetupHostPlatform.macOS:
        final appSupport = p.join(home, 'Library', 'Application Support');
        return [
          (
            user: p.join(
              appSupport,
              'Google',
              'Chrome',
              'NativeMessagingHosts',
            ),
            system: '/Library/Google/Chrome/NativeMessagingHosts',
          ),
          (
            user: p.join(appSupport, 'Microsoft Edge', 'NativeMessagingHosts'),
            system: '/Library/Microsoft/Edge/NativeMessagingHosts',
          ),
          (
            user: p.join(
              appSupport,
              'BraveSoftware',
              'Brave-Browser',
              'NativeMessagingHosts',
            ),
            system: '/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts',
          ),
          (
            user: p.join(appSupport, 'Vivaldi', 'NativeMessagingHosts'),
            system: '/Library/Application Support/Vivaldi/NativeMessagingHosts',
          ),
          (
            user: p.join(appSupport, 'Chromium', 'NativeMessagingHosts'),
            system:
                '/Library/Application Support/Chromium/NativeMessagingHosts',
          ),
          (
            user: p.join(
              appSupport,
              'com.operasoftware.Opera',
              'NativeMessagingHosts',
            ),
            system: '/Library/Application Support/com.operasoftware.Opera/NativeMessagingHosts',
          ),
        ];
      case BrowserSetupHostPlatform.linux:
        final config = p.join(home, '.config');
        return [
          (
            user: p.join(config, 'google-chrome', 'NativeMessagingHosts'),
            system: '/etc/opt/chrome/native-messaging-hosts',
          ),
          (
            user: p.join(config, 'chromium', 'NativeMessagingHosts'),
            system: '/etc/chromium/native-messaging-hosts',
          ),
          (
            user: p.join(config, 'microsoft-edge', 'NativeMessagingHosts'),
            system: '/etc/opt/edge/native-messaging-hosts',
          ),
        ];
      case BrowserSetupHostPlatform.windows:
      case BrowserSetupHostPlatform.unsupported:
        return const [];
    }
  }

  static bool isValidExtensionId(String value) {
    return _extensionIdPattern.hasMatch(value.trim());
  }

  // ---------------------------------------------------------------------------
  // Extension folder lookup
  // ---------------------------------------------------------------------------

  /// Absolute path to the browser extension folder inside the project root.
  ///
  /// Works during development (when the script lives in
  /// `.../desktop/native_host/`).  In a shipped `.app` this would need to
  /// resolve from the bundle, but for now dev-mode is enough.
  String? get extensionFolderPath {
    final projectRoot = _projectRootPath;
    if (projectRoot == null) return null;
    final ext = p.join(projectRoot, 'desktop', 'browser_extension');
    return Directory(ext).existsSync() ? ext : null;
  }

  String get nativeHostName => 'dev.camillobucciarelli.keyvault_native_host';

  String get bridgeConfigPath =>
      _cacheStore.directory?.path ??
      DesktopBrowserAutofillCacheStore.defaultDirectory()?.path ??
      'Desktop browser Autofill cache directory unavailable';

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  bool get _isDesktop {
    if (kIsWeb) return false;
    return _hostPlatform != BrowserSetupHostPlatform.unsupported;
  }

  BrowserSetupHostPlatform get _hostPlatform {
    final override = _platformOverride;
    if (override != null) return override;
    if (Platform.isMacOS) return BrowserSetupHostPlatform.macOS;
    if (Platform.isWindows) return BrowserSetupHostPlatform.windows;
    if (Platform.isLinux) return BrowserSetupHostPlatform.linux;
    return BrowserSetupHostPlatform.unsupported;
  }

  /// Tries to locate the current platform installer relative to the executable
  /// or the project source tree (dev mode).
  String? _installScriptPath(BrowserSetupHostPlatform platform) {
    final scriptName = _installScriptName(platform);
    if (scriptName == null) return null;

    final root = _projectRootPath;
    if (root != null) {
      final candidate = p.join(root, 'desktop', 'native_host', scriptName);
      if (File(candidate).existsSync()) return candidate;
    }

    final found = _findScriptFrom(
      p.dirname(Platform.resolvedExecutable),
      scriptName,
    );
    if (found != null) return found;

    debugPrint('[BrowserSetup] $scriptName not found');
    return null;
  }

  String? get _projectRootPath {
    final explicitRoot = _projectRoot;
    if (explicitRoot != null && explicitRoot.existsSync()) {
      return explicitRoot.path;
    }

    return _findProjectRootFrom(p.dirname(Platform.resolvedExecutable));
  }

  String? _findScriptFrom(String start, String scriptName) {
    final exe = Platform.resolvedExecutable;
    var dir = start;
    for (var i = 0; i < 12; i++) {
      final candidate = p.join(dir, 'desktop', 'native_host', scriptName);
      if (File(candidate).existsSync()) return candidate;
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    debugPrint('[BrowserSetup] $scriptName not found near $exe');
    return null;
  }

  String? _findProjectRootFrom(String start) {
    var dir = start;
    for (var i = 0; i < 12; i++) {
      if (Directory(p.join(dir, 'desktop', 'native_host')).existsSync() &&
          Directory(p.join(dir, 'desktop', 'browser_extension')).existsSync()) {
        return dir;
      }
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    return null;
  }

  String? _installScriptName(BrowserSetupHostPlatform platform) {
    switch (platform) {
      case BrowserSetupHostPlatform.macOS:
        return 'install_host_macos.sh';
      case BrowserSetupHostPlatform.windows:
        return 'install_host_windows.ps1';
      case BrowserSetupHostPlatform.linux:
        return 'install_host_linux.sh';
      case BrowserSetupHostPlatform.unsupported:
        return null;
    }
  }

  String _installScriptExecutable(BrowserSetupHostPlatform platform) {
    return switch (platform) {
      BrowserSetupHostPlatform.windows => 'powershell.exe',
      _ => '/bin/bash',
    };
  }

  List<String> _installScriptArguments({
    required BrowserSetupHostPlatform platform,
    required NativeHostBrowser browser,
    required String scriptPath,
    required String extensionId,
  }) {
    final browserArg = _browserScriptArgument(browser, platform);
    return switch (platform) {
      BrowserSetupHostPlatform.macOS => [scriptPath, browserArg, extensionId],
      BrowserSetupHostPlatform.linux => [
        scriptPath,
        '--browser',
        browserArg,
        extensionId,
      ],
      BrowserSetupHostPlatform.windows => [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptPath,
        '-Browser',
        browserArg,
        '-ExtensionId',
        extensionId,
      ],
      BrowserSetupHostPlatform.unsupported => const [],
    };
  }

  String _browserScriptArgument(
    NativeHostBrowser browser,
    BrowserSetupHostPlatform platform,
  ) {
    return switch (browser) {
      NativeHostBrowser.chrome =>
        platform == BrowserSetupHostPlatform.windows ? 'Chrome' : 'chrome',
      NativeHostBrowser.edge =>
        platform == BrowserSetupHostPlatform.windows ? 'Edge' : 'edge',
      NativeHostBrowser.chromium => 'chromium',
    };
  }

  bool _supportsBrowser(
    BrowserSetupHostPlatform platform,
    NativeHostBrowser browser,
  ) {
    return switch (platform) {
      BrowserSetupHostPlatform.macOS || BrowserSetupHostPlatform.windows =>
        browser == NativeHostBrowser.chrome ||
            browser == NativeHostBrowser.edge,
      BrowserSetupHostPlatform.linux => true,
      BrowserSetupHostPlatform.unsupported => false,
    };
  }

  String _defaultInstallScriptDisplayPath(BrowserSetupHostPlatform platform) {
    final scriptName = _installScriptName(platform);
    if (scriptName == null) return '<INSTALL_SCRIPT>';
    // `p.posix.join`, NOT `p.join`: this string is rendered for [platform],
    // which `platformOverride` lets a caller set independently of the host, so
    // the host separator has no business here. `p.join` on a Windows host
    // produced `./desktop\native_host\install_host_macos.sh` — a macOS
    // instruction with Windows separators. The Windows branch below converts
    // to `\` explicitly, so building in POSIX first is correct for every
    // combination instead of only for host == target.
    final raw = p.posix.join('desktop', 'native_host', scriptName);
    final windowsSeparator = String.fromCharCode(92);
    return platform == BrowserSetupHostPlatform.windows
        ? '.\\${raw.replaceAll('/', windowsSeparator)}'
        : './$raw';
  }

  String _displayPath(
    String path, {
    required BrowserSetupHostPlatform platform,
  }) {
    final root = _projectRootPath;
    var display = path;
    final windowsSeparator = String.fromCharCode(92);
    if (root != null && p.isWithin(root, path)) {
      // Re-spelled in POSIX for the same reason as
      // [_defaultInstallScriptDisplayPath]: `p.relative` yields the HOST
      // separator, but the string is rendered for [platform].
      final relative = p.posix.joinAll(p.split(p.relative(path, from: root)));
      display = platform == BrowserSetupHostPlatform.windows
          ? '.\\${relative.replaceAll('/', windowsSeparator)}'
          : './$relative';
    }
    if (platform == BrowserSetupHostPlatform.windows) {
      display = display.replaceAll('/', windowsSeparator);
    }
    return _quoteForDisplay(display);
  }

  String _quoteForDisplay(String value) {
    if (!value.contains(RegExp(r'\s'))) return value;
    return '"${value.replaceAll('"', '\\"')}"';
  }
}
