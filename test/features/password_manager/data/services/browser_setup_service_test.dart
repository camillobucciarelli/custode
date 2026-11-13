import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/data/services/browser_setup_service.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_autofill_cache.dart';
import 'package:password_manager/features/password_manager/data/services/desktop_browser_autofill_reveal_bridge_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('BrowserSetupService', () {
    const validExtensionId = 'abcdefghijklmnopabcdefghijklmnop';

    test('uses fixed public Chrome extension details', () {
      expect(
        BrowserSetupService.chromeExtensionId,
        'ogjmlkogmogijgpflnjifiobdmnmommh',
      );
      expect(
        BrowserSetupService.chromeStoreListingUrl,
        'https://chromewebstore.google.com/detail/ogjmlkogmogijgpflnjifiobdmnmommh',
      );
      expect(
        BrowserSetupService.macOSChromeSupportPackageUrl,
        'https://github.com/camillobucciarelli/custode/'
        'releases/latest/download/keyvault-chrome-support-macos.pkg',
      );
    });

    test('validates extension IDs safely', () {
      expect(BrowserSetupService.isValidExtensionId(validExtensionId), isTrue);
      expect(
        BrowserSetupService.isValidExtensionId(' $validExtensionId\n'),
        isTrue,
      );
      expect(
        BrowserSetupService.isValidExtensionId(
          'abcdefghijklmnopabcdefghijklmno',
        ),
        isFalse,
      );
      expect(
        BrowserSetupService.isValidExtensionId(
          'abcdefghijklmnopabcdefghijklmnoq',
        ),
        isFalse,
      );
      expect(
        BrowserSetupService.isValidExtensionId(
          'ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP',
        ),
        isFalse,
      );
      expect(
        BrowserSetupService.isValidExtensionId(
          'abcd;rm -rf /;abcdefghijklmnop',
        ),
        isFalse,
      );
    });

    // F4, closed. The display path's separator is a function of the RENDERED
    // platform and of nothing else — least of all the host. The expectations
    // below are therefore derived from `platform` through [displayPathFor]
    // rather than written out as literals that merely happen to match this
    // host's separator.
    //
    // That alone does not close the gap, and it was measured rather than
    // assumed: with `p.posix.join` mutated back to the host-context `p.join`,
    // every assertion in this group still passes on a POSIX host, because the
    // host separator and the rendered one agree there — and for the Windows
    // target the trailing `replaceAll('/', r'\')` normalises the difference
    // away. The defect is observable at runtime ONLY where host != target,
    // which is the Windows CI job and nowhere else.
    //
    // So the guard that actually holds on every host is the source assertion
    // at the end of this group: the two display-path builders must not consume
    // the host path context. That one dies with the mutant on macOS, Linux and
    // Windows alike.

    /// The path `platform` must be shown, spelled with `platform`'s separator.
    /// Derived, never hard-coded: this is the property under test.
    String displayPathFor(
      BrowserSetupHostPlatform platform,
      List<String> segments,
    ) {
      final separator = platform == BrowserSetupHostPlatform.windows
          ? r'\'
          : '/';
      return ['.', ...segments].join(separator);
    }

    test('generates macOS Chrome installer command', () async {
      final root = await _fakeProjectRoot(scriptName: 'install_host_macos.sh');
      addTearDown(() => root.delete(recursive: true));

      final service = BrowserSetupService(
        projectRoot: root,
        platformOverride: BrowserSetupHostPlatform.macOS,
      );

      final command = service.nativeHostInstallCommand(
        browser: NativeHostBrowser.chrome,
        extensionId: validExtensionId,
      );

      expect(command, isNotNull);
      expect(command!.executable, '/bin/bash');
      expect(command.arguments, [
        p.join(root.path, 'desktop', 'native_host', 'install_host_macos.sh'),
        'chrome',
        validExtensionId,
      ]);
      final script = displayPathFor(BrowserSetupHostPlatform.macOS, const [
        'desktop',
        'native_host',
        'install_host_macos.sh',
      ]);
      expect(command.displayCommand, '$script chrome $validExtensionId');
    });

    test('generates Linux Chromium installer command', () async {
      final root = await _fakeProjectRoot(scriptName: 'install_host_linux.sh');
      addTearDown(() => root.delete(recursive: true));

      final service = BrowserSetupService(
        projectRoot: root,
        platformOverride: BrowserSetupHostPlatform.linux,
      );

      final command = service.nativeHostInstallCommand(
        browser: NativeHostBrowser.chromium,
        extensionId: validExtensionId,
      );

      expect(command, isNotNull);
      expect(command!.executable, '/bin/bash');
      expect(command.arguments, [
        p.join(root.path, 'desktop', 'native_host', 'install_host_linux.sh'),
        '--browser',
        'chromium',
        validExtensionId,
      ]);
      final script = displayPathFor(BrowserSetupHostPlatform.linux, const [
        'desktop',
        'native_host',
        'install_host_linux.sh',
      ]);
      expect(
        command.displayCommand,
        '$script --browser chromium $validExtensionId',
      );
    });

    test('generates Windows Edge installer command', () async {
      final root = await _fakeProjectRoot(
        scriptName: 'install_host_windows.ps1',
      );
      addTearDown(() => root.delete(recursive: true));

      final service = BrowserSetupService(
        projectRoot: root,
        platformOverride: BrowserSetupHostPlatform.windows,
      );

      final command = service.nativeHostInstallCommand(
        browser: NativeHostBrowser.edge,
        extensionId: validExtensionId,
      );

      expect(command, isNotNull);
      expect(command!.executable, 'powershell.exe');
      expect(command.arguments, [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(root.path, 'desktop', 'native_host', 'install_host_windows.ps1'),
        '-Browser',
        'Edge',
        '-ExtensionId',
        validExtensionId,
      ]);
      final script = displayPathFor(BrowserSetupHostPlatform.windows, const [
        'desktop',
        'native_host',
        'install_host_windows.ps1',
      ]);
      expect(
        command.displayCommand,
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script '
        '-Browser Edge -ExtensionId $validExtensionId',
      );
    });

    test('does not run installer for invalid extension IDs', () async {
      final root = await _fakeProjectRoot(scriptName: 'install_host_macos.sh');
      addTearDown(() => root.delete(recursive: true));
      var ranProcess = false;

      final service = BrowserSetupService(
        projectRoot: root,
        platformOverride: BrowserSetupHostPlatform.macOS,
        processRunner: (executable, arguments) async {
          ranProcess = true;
          return ProcessResult(1, 0, '', '');
        },
      );

      final result = await service.registerNativeHost(
        browser: NativeHostBrowser.chrome,
        extensionId: 'invalid;id',
      );

      expect(result, NativeHostInstallResult.invalidExtensionId);
      expect(ranProcess, isFalse);
    });

    test('returns success when installer exits zero', () async {
      final root = await _fakeProjectRoot(scriptName: 'install_host_macos.sh');
      addTearDown(() => root.delete(recursive: true));
      String? executableSeen;
      List<String>? argumentsSeen;

      final service = BrowserSetupService(
        projectRoot: root,
        platformOverride: BrowserSetupHostPlatform.macOS,
        processRunner: (executable, arguments) async {
          executableSeen = executable;
          argumentsSeen = arguments;
          return ProcessResult(1, 0, '', '');
        },
      );

      final result = await service.registerNativeHost(
        browser: NativeHostBrowser.edge,
        extensionId: validExtensionId,
      );

      expect(result, NativeHostInstallResult.success);
      expect(executableSeen, '/bin/bash');
      expect(argumentsSeen, [
        p.join(root.path, 'desktop', 'native_host', 'install_host_macos.sh'),
        'edge',
        validExtensionId,
      ]);
    });

    test(
      'installNativeHost registers Chrome with fixed extension ID',
      () async {
        final root = await _fakeProjectRoot(
          scriptName: 'install_host_macos.sh',
        );
        addTearDown(() => root.delete(recursive: true));
        String? executableSeen;
        List<String>? argumentsSeen;

        final service = BrowserSetupService(
          projectRoot: root,
          platformOverride: BrowserSetupHostPlatform.macOS,
          processRunner: (executable, arguments) async {
            executableSeen = executable;
            argumentsSeen = arguments;
            return ProcessResult(1, 0, '', '');
          },
        );

        expect(
          await service.installNativeHost(),
          NativeHostInstallResult.success,
        );
        expect(executableSeen, '/bin/bash');
        expect(argumentsSeen, [
          p.join(root.path, 'desktop', 'native_host', 'install_host_macos.sh'),
          'chrome',
          BrowserSetupService.chromeExtensionId,
        ]);
      },
    );

    test('returns failed when installer exits nonzero', () async {
      final root = await _fakeProjectRoot(scriptName: 'install_host_macos.sh');
      addTearDown(() => root.delete(recursive: true));
      String? executableSeen;
      List<String>? argumentsSeen;

      final service = BrowserSetupService(
        projectRoot: root,
        platformOverride: BrowserSetupHostPlatform.macOS,
        processRunner: (executable, arguments) async {
          executableSeen = executable;
          argumentsSeen = arguments;
          return ProcessResult(1, 42, '', 'installer failed');
        },
      );

      final result = await service.registerNativeHost(
        browser: NativeHostBrowser.edge,
        extensionId: validExtensionId,
      );

      expect(result, NativeHostInstallResult.failed);
      expect(executableSeen, '/bin/bash');
      expect(argumentsSeen, [
        p.join(root.path, 'desktop', 'native_host', 'install_host_macos.sh'),
        'edge',
        validExtensionId,
      ]);
    });

    test('rejects descriptor with dead bridge port', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-browser-setup-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final service = BrowserSetupService(
        cacheStore: store,
        platformOverride: BrowserSetupHostPlatform.macOS,
      );

      expect(await service.checkBridgeConnection(), BridgeCheckResult.noConfig);
      await _writeCache(store, databaseId: 'db-1');
      expect(
        await service.checkBridgeConnection(),
        BridgeCheckResult.v2AppBridgeUnavailable,
      );

      final deadServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = deadServer.port;
      await deadServer.close();
      await _writeDescriptor(store, port: deadPort);

      expect(
        await service.checkBridgeConnection(),
        BridgeCheckResult.v2AppBridgeUnavailable,
      );
    });

    test('connects only to live authenticated bridge', () async {
      final directory = await Directory.systemTemp.createTemp(
        'kv-browser-setup-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = DesktopBrowserAutofillCacheStore(directory: directory);
      final bridge = DesktopBrowserAutofillRevealBridgeService(
        store: store,
        mapper: const DesktopBrowserAutofillMetadataMapper(),
      );
      addTearDown(bridge.stop);
      await bridge.start(
        databasePath: '/vaults/example.kdbx',
        entries: const [],
      );
      final descriptor = (await store.readBridgeDescriptor())!;
      await _writeCache(store, databaseId: descriptor.databaseId);
      final service = BrowserSetupService(
        cacheStore: store,
        platformOverride: BrowserSetupHostPlatform.macOS,
      );

      expect(
        await service.checkBridgeConnection(),
        BridgeCheckResult.connected,
      );

      await store.writeBridgeDescriptor(
        DesktopBrowserAutofillBridgeDescriptor(
          version: descriptor.version,
          port: descriptor.port,
          token: 'wrong-token-wrong-token-wrong-token-wrong-token',
          databaseId: descriptor.databaseId,
          cacheGeneration: 'cache-gen-1',
          bridgeGeneration: 'bridge-gen-1',
          createdAtEpochMs: descriptor.createdAtEpochMs,
        ),
      );
      expect(
        await service.checkBridgeConnection(),
        BridgeCheckResult.v2AppBridgeUnavailable,
      );
    });

    // F4, the half that holds on EVERY host.
    //
    // The runtime assertions above can only see the host-separator defect
    // where the host separator differs from the rendered one, i.e. on the
    // Windows job. This one reads the two builders' own source instead, so it
    // fails identically on macOS, Linux and Windows — and a Windows runner
    // outage can no longer take the coverage with it silently.
    //
    // The invariant, stated exactly: a display path is rendered for
    // `platform`, which `platformOverride` sets independently of the host, so
    // every JOIN that produces it must carry an explicit path context.
    // `p.relative`, `p.split` and `p.isWithin` are host-context operations on
    // real host paths and are legitimate — what must never happen is joining
    // the result back together with the implicit host context.
    test('the display-path builders never join with the HOST path context', () {
      const path =
          'lib/features/password_manager/data/services/browser_setup_service.dart';
      final unit = parseString(
        content: File(path).readAsStringSync(),
        path: path,
      ).unit;

      final service = unit.declarations
          .whereType<ClassDeclaration>()
          .singleWhere(
            (d) => d.namePart.typeName.lexeme == 'BrowserSetupService',
          );

      for (final name in const [
        '_defaultInstallScriptDisplayPath',
        '_displayPath',
      ]) {
        final method = service.body.members
            .whereType<MethodDeclaration>()
            .singleWhere(
              (m) => m.name.lexeme == name,
              orElse: () => throw StateError('no method "$name"'),
            );
        final body = method.body.toSource();

        // Half 1 — kills "p.posix.join -> p.join": a bare join takes its
        // separator from whatever machine is running, not from `platform`.
        expect(
          RegExp(r'(?<!\.)\bp\.join(?:All)?\(').hasMatch(body),
          isFalse,
          reason:
              '$name joins with the implicit host context. Renders for '
              '`platform`, so the join must be p.posix.join/joinAll.',
        );

        // Half 2 — kills "drop the re-spelling and return p.relative directly":
        // that leaves no bare join to find, only a missing one.
        expect(
          RegExp(r'\bp\.posix\.join(?:All)?\(').hasMatch(body),
          isTrue,
          reason:
              '$name no longer re-spells its path in an explicit context, so '
              'the host separator reaches the rendered string.',
        );
      }
    });
  });
}

Future<void> _writeCache(
  DesktopBrowserAutofillCacheStore store, {
  required String databaseId,
}) {
  return store.writeMetadataCache(
    DesktopBrowserAutofillMetadataCache(
      version: desktopBrowserAutofillCacheVersion,
      databaseId: databaseId,
      cacheGeneration: 'cache-gen-1',
      generatedAtEpochMs: 1,
      entries: const [],
    ),
  );
}

Future<void> _writeDescriptor(
  DesktopBrowserAutofillCacheStore store, {
  required int port,
}) {
  return store.writeBridgeDescriptor(
    DesktopBrowserAutofillBridgeDescriptor(
      version: desktopBrowserAutofillBridgeDescriptorVersion,
      port: port,
      token: 'test-token-test-token-test-token-test-token',
      databaseId: 'db-1',
      cacheGeneration: 'cache-gen-1',
      bridgeGeneration: 'bridge-gen-1',
      createdAtEpochMs: 1,
    ),
  );
}

Future<Directory> _fakeProjectRoot({required String scriptName}) async {
  final root = await Directory.systemTemp.createTemp('kv-browser-setup-');
  await Directory(p.join(root.path, 'desktop', 'browser_extension'))
      .create(recursive: true);
  final script = File(p.join(root.path, 'desktop', 'native_host', scriptName));
  await script.create(recursive: true);
  return root;
}
