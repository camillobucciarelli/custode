import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../../core/theme/app_backgrounds.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_icons.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../data/services/browser_setup_service.dart';
import '../widgets/styled_info_container.dart';

/// A step-by-step wizard that guides the user through connecting the
/// Custode browser extension to the desktop app.
///
/// Should only be shown on desktop platforms.
class BrowserSetupScreen extends StatefulWidget {
  const BrowserSetupScreen({super.key, this.service, this.openUrl});

  final BrowserSetupService? service;

  /// Test seam for the external-URL launches; defaults to [launchUrl].
  @visibleForTesting
  final Future<bool> Function(Uri url)? openUrl;

  static bool get shouldShow {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  @override
  State<BrowserSetupScreen> createState() => _BrowserSetupScreenState();
}

@visibleForTesting
class BrowserSetupInitialStatus {
  const BrowserSetupInitialStatus({
    required this.appBridgeConnected,
    required this.extensionStepCompleted,
    required this.nativeHostStepCompleted,
    required this.connectionStepCompleted,
  });

  final bool appBridgeConnected;
  final bool extensionStepCompleted;
  final bool nativeHostStepCompleted;
  final bool connectionStepCompleted;

  bool get allConfigured =>
      extensionStepCompleted &&
      nativeHostStepCompleted &&
      connectionStepCompleted;
}

@visibleForTesting
BrowserSetupInitialStatus browserSetupInitialStatusForBridge(
  BridgeCheckResult bridge,
) {
  return BrowserSetupInitialStatus(
    appBridgeConnected: bridge == BridgeCheckResult.connected,
    extensionStepCompleted: false,
    nativeHostStepCompleted: false,
    connectionStepCompleted: false,
  );
}

class _BrowserSetupScreenState extends State<BrowserSetupScreen> {
  late final BrowserSetupService _service;

  // Step status
  _StepStatus _nativeHostStatus = _StepStatus.pending;
  _StepStatus _extensionStatus = _StepStatus.pending;
  _StepStatus _connectionStatus = _StepStatus.pending;

  String? _errorMessage;
  String? _nativeHostSetupMessage;
  List<String> _staleManifestPaths = const [];
  bool _isCheckingConnection = false;
  bool _appBridgeConnected = false;

  bool get _usesMacOSCompanionInstaller =>
      defaultTargetPlatform == TargetPlatform.macOS;

  bool get _hasNativeHostInstaller =>
      _usesMacOSCompanionInstaller || _service.canRunNativeHostInstaller;

  /// Issue #209: a build without the bundled installer (the Microsoft Store
  /// MSIX) cannot register the native host, so step 2 sends the user to the
  /// GitHub sideload zip instead of a dead "Configura Chrome" button.
  bool get _usesSideloadFallback =>
      !_usesMacOSCompanionInstaller && !_service.canRunNativeHostInstaller;

  Future<bool> _openUrl(Uri url) =>
      widget.openUrl?.call(url) ??
      launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? BrowserSetupService();
    _checkInitialState();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _checkInitialState() async {
    final bridge = await _service.checkBridgeConnection();
    if (!mounted) return;
    unawaited(_checkStaleManifest());

    final initialStatus = browserSetupInitialStatusForBridge(bridge);
    setState(() {
      _appBridgeConnected = initialStatus.appBridgeConnected;
      if (initialStatus.extensionStepCompleted) {
        _extensionStatus = _StepStatus.done;
      }
      if (initialStatus.nativeHostStepCompleted) {
        _nativeHostStatus = _StepStatus.done;
      }
      if (initialStatus.connectionStepCompleted) {
        _connectionStatus = _StepStatus.done;
      }
    });
  }

  Future<void> _openChromeStore() async {
    setState(() {
      _extensionStatus = _StepStatus.loading;
      _errorMessage = null;
    });
    try {
      final opened = await _openUrl(
        Uri.parse(BrowserSetupService.chromeStoreListingUrl),
      );
      if (!mounted) return;
      setState(() {
        _extensionStatus = opened ? _StepStatus.pending : _StepStatus.error;
        if (!opened) {
          _errorMessage = 'Impossibile aprire Chrome Web Store. Riprova.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _extensionStatus = _StepStatus.error;
        _errorMessage = 'Impossibile aprire Chrome Web Store. Riprova.';
      });
    }
  }

  Future<void> _installNativeHost() async {
    setState(() {
      _nativeHostStatus = _StepStatus.loading;
      _nativeHostSetupMessage = null;
      _errorMessage = null;
    });

    if (_usesMacOSCompanionInstaller || _usesSideloadFallback) {
      final url = _usesMacOSCompanionInstaller
          ? BrowserSetupService.macOSChromeSupportPackageUrl
          : BrowserSetupService.sideloadReleasesUrl;
      var opened = false;
      try {
        opened = await _openUrl(Uri.parse(url));
      } catch (_) {
        opened = false;
      }
      if (!mounted) return;
      final message = _usesSideloadFallback
          ? (opened
                ? 'Scarica lo zip di Custode dalla release, avvialo e ripeti il passo 2 da quella versione.'
                : 'Impossibile aprire la pagina delle release GitHub.')
          : opened
          ? 'Apri il pacchetto scaricato, completa l’installazione e riavvia Chrome.'
          : 'Impossibile scaricare Chrome Support per macOS.';
      setState(() {
        _nativeHostSetupMessage = message;
        _nativeHostStatus = opened ? _StepStatus.pending : _StepStatus.error;
        _errorMessage = opened ? null : message;
      });
      return;
    }

    final result = await _service.installNativeHost();
    if (!mounted) return;

    final success = result == NativeHostInstallResult.success;
    final message = _nativeHostInstallMessage(result);
    setState(() {
      _nativeHostSetupMessage = message;
      _nativeHostStatus = success ? _StepStatus.done : _StepStatus.error;
      _errorMessage = success ? null : message;
    });
  }

  String _nativeHostInstallMessage(NativeHostInstallResult result) {
    switch (result) {
      case NativeHostInstallResult.success:
        return 'Chrome configurato. Riavvia Chrome e verifica la connessione.';
      case NativeHostInstallResult.invalidExtensionId:
        return 'Configurazione Chrome non valida. Aggiorna Custode e riprova.';
      case NativeHostInstallResult.scriptNotFound:
        return 'Installer Chrome non disponibile in questa versione di Custode.';
      case NativeHostInstallResult.unsupportedPlatform:
        return 'Configurazione automatica di Chrome non supportata su questa piattaforma.';
      case NativeHostInstallResult.failed:
        return 'Configurazione Chrome non riuscita. Riprova o reinstalla Custode.';
    }
  }

  Future<void> _checkStaleManifest() async {
    final stale = await _service.staleUserManifests();
    if (!mounted) return;
    setState(
      () => _staleManifestPaths = stale
          .map((file) => file.path)
          .toList(growable: false),
    );
  }

  Future<void> _removeStaleManifest() async {
    final stalePaths = _staleManifestPaths.join(', ');
    final removed = await _service.removeStaleUserManifests();
    if (!mounted) return;
    setState(() {
      _staleManifestPaths = const [];
      if (!removed) {
        _errorMessage =
            'Impossibile rimuovere la vecchia registrazione. '
            'Elimina a mano: $stalePaths';
      }
    });
    if (removed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Vecchia registrazione rimossa. Riavvia Chrome e riprova.',
          ),
        ),
      );
    }
  }

  Future<void> _checkConnection() async {
    setState(() {
      _isCheckingConnection = true;
      _connectionStatus = _StepStatus.loading;
      _errorMessage = null;
    });

    final result = await _service.checkBridgeConnection();
    if (!mounted) return;
    unawaited(_checkStaleManifest());

    setState(() {
      _isCheckingConnection = false;
      switch (result) {
        case BridgeCheckResult.connected:
          _appBridgeConnected = true;
          _connectionStatus = _StepStatus.done;
        case BridgeCheckResult.noConfig:
          _appBridgeConnected = false;
          _connectionStatus = _StepStatus.error;
          _errorMessage = 'Sblocca il vault in Custode e riprova.';
        case BridgeCheckResult.notRunning:
          _appBridgeConnected = false;
          _connectionStatus = _StepStatus.error;
          _errorMessage = 'Bridge non raggiungibile. Riavvia Custode, sblocca il vault e riprova.';
        case BridgeCheckResult.v2AppBridgeUnavailable:
          _appBridgeConnected = false;
          _connectionStatus = _StepStatus.error;
          _errorMessage = 'Collegamento non disponibile. Blocca e sblocca il vault, poi riprova.';
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final horizontalPadding = viewportWidth < 420 ? 16.0 : 24.0;
    final cardPadding = viewportWidth < 420 ? 18.0 : 24.0;
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: const Text('Estensione browser desktop'),
      ),
      body: Container(
        decoration: BoxDecoration(gradient: AppBackgrounds.gradient(context)),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                topInset + 16,
                horizontalPadding,
                32,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  tween: Tween(begin: 0.97, end: 1),
                  builder: (context, v, child) => Transform.scale(
                    scale: v,
                    child: Opacity(opacity: v, child: child),
                  ),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(cardPadding),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header
                          Row(
                            children: [
                              Icon(
                                AppIcons.key,
                                size: 36,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Estensione Chrome',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Installa l\'estensione e collegala a Custode',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          const Divider(height: 1),
                          const SizedBox(height: 20),

                          // 2026-08-31: an old dev registration in the
                          // per-user NativeMessagingHosts directory shadows
                          // the production package (Chrome reads the user
                          // level first) and the store extension reports
                          // "host not found" with everything else correct.
                          if (_staleManifestPaths.isNotEmpty) ...[
                            _StaleManifestCard(
                              paths: _staleManifestPaths,
                              onRemove: _removeStaleManifest,
                            ),
                            const SizedBox(height: 16),
                          ],

                          // Step 1 — Install Extension
                          _SetupStep(
                            number: 1,
                            title: 'Installa l\'estensione',
                            description: 'Apri Chrome Web Store e installa l\'estensione Custode.',
                            status: _extensionStatus,
                            actionLabel: _extensionStatus == _StepStatus.loading
                                ? 'Apertura in corso…'
                                : 'Apri Chrome Web Store',
                            onAction: _extensionStatus != _StepStatus.loading
                                ? _openChromeStore
                                : null,
                          ),

                          const SizedBox(height: 12),

                          // Step 2 — Native Host
                          _SetupStep(
                            number: 2,
                            title: 'Collega Chrome a Custode',
                            description: _usesMacOSCompanionInstaller
                                ? 'Scarica e installa il componente Chrome Support firmato per macOS.'
                                : _hasNativeHostInstaller
                                ? 'Configura automaticamente il collegamento sicuro con Chrome.'
                                : 'Questa versione di Custode non include il collegamento con Chrome (ad esempio la build Microsoft Store). Usa lo zip della release GitHub per attivarlo.',
                            status: _nativeHostStatus,
                            actionLabel:
                                _nativeHostStatus == _StepStatus.loading
                                ? 'Configurazione in corso…'
                                : _usesMacOSCompanionInstaller
                                ? 'Scarica Chrome Support'
                                : _usesSideloadFallback
                                ? 'Apri le release GitHub'
                                : 'Configura Chrome',
                            onAction: _nativeHostStatus != _StepStatus.loading
                                ? _installNativeHost
                                : null,
                          ),

                          // spec-006 T8/PIXEL_SPEC "Command block": shows the
                          // *real* command `_installNativeHost` runs
                          // automatically (radius 18, neutral-900/mono-11.5,
                          // copyable) — transparency for anyone who wants to
                          // run it by hand, not a new manual-install flow.
                          if (!_usesMacOSCompanionInstaller &&
                              _hasNativeHostInstaller) ...[
                            const SizedBox(height: 10),
                            _NativeHostCommandBlock(
                              command: _service.nativeHostInstallCommandText(
                                browser: NativeHostBrowser.chrome,
                                extensionId:
                                    BrowserSetupService.chromeExtensionId,
                              ),
                            ),
                          ],

                          if (_nativeHostSetupMessage != null &&
                              _nativeHostStatus != _StepStatus.error) ...[
                            const SizedBox(height: 12),
                            _InlineStatusMessage(
                              message: _nativeHostSetupMessage!,
                              isError: false,
                            ),
                          ],

                          const SizedBox(height: 12),

                          // Step 3 — Verify connection
                          _SetupStep(
                            number: 3,
                            title: 'Verifica la connessione',
                            description: 'Sblocca il vault e tieni Custode aperto, poi verifica che il bridge app sia pronto.',
                            status: _connectionStatus,
                            actionLabel: _isCheckingConnection
                                ? 'Verifica in corso…'
                                : 'Verifica',
                            onAction: !_isCheckingConnection
                                ? _checkConnection
                                : null,
                          ),

                          if (_appBridgeConnected) ...[
                            const SizedBox(height: 12),
                            const _AppBridgeStatusBanner(),
                          ],

                          // spec-006 T9: static diagnostic screen, always
                          // reachable (the app's own bridge-connectivity
                          // check cannot detect a Chrome-side "native host
                          // not found" specifically — see the final report).
                          const SizedBox(height: 12),
                          Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => HostNotFoundDiagnosticScreen(
                                    service: _service,
                                  ),
                                ),
                              ),
                              child: const Text('Diagnostica collegamento'),
                            ),
                          ),

                          // Error message
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 16),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .errorContainer
                                    .withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.error
                                      .withValues(alpha: 0.4),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    AppIcons.warning,
                                    size: 16,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onErrorContainer,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          if (_appBridgeConnected) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Ultimo controllo: riavvia Chrome e apri il popup Custode. La voce Host deve risultare Available.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Supporting widgets
// ---------------------------------------------------------------------------

enum _StepStatus { pending, disabled, loading, done, error }

/// Warning card for a stale per-user Native Messaging manifest that
/// shadows the production (system-level) registration.
class _StaleManifestCard extends StatelessWidget {
  const _StaleManifestCard({required this.paths, required this.onRemove});

  final List<String> paths;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Vecchia registrazione di sviluppo trovata',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Un manifest utente obsoleto sta oscurando quello installato dal '
            'pacchetto Chrome Support: l\'estensione dello store non trova '
            'il collegamento. Rimuovilo e riavvia Chrome.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          for (final path in paths)
            Text(
              path,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace', fontSize: 11),
            ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: onRemove,
              child: const Text('Rimuovi registrazione obsoleta'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.number,
    required this.title,
    required this.description,
    required this.status,
    required this.actionLabel,
    this.onAction,
  });

  final int number;
  final String title;
  final String description;
  final _StepStatus status;
  final String actionLabel;
  final VoidCallback? onAction;

  // spec-006 T8/PIXEL_SPEC "Step cards": radius 24 padding 16 — done card
  // `positiveTint` + 40-square check, active card `surface` + numbered
  // 40-square `actionFill`, pending card at 60 % opacity. Business logic
  // (`_StepStatus`, title/description/actionLabel/onAction) is untouched —
  // this only restyles the container.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final isDisabled = status == _StepStatus.disabled;
    final isDone = status == _StepStatus.done;
    final isLoading = status == _StepStatus.loading;
    final isError = status == _StepStatus.error;
    // "Pending" per the pixel spec means "not yet reached" — the step
    // hasn't started and has no live status to show, i.e. `disabled` in
    // this screen's own state machine (its `pending` value means "ready to
    // act on", which is the pixel spec's "active").
    final isPendingUnreached = isDisabled;
    final isActive = !isDone && !isPendingUnreached;

    final Color cardColor = isDone
        ? colors.positiveTint
        : isError
        ? colors.attentionTint
        : colors.surface;
    final Color badgeColor = isDone
        ? colors.positiveFill
        : isError
        ? colors.attentionText
        : isActive
        ? colors.actionFill
        : colors.surfaceNested;
    final Color badgeFgColor = isDone
        ? colors.positiveText
        : isError
        ? colors.attentionTint
        : isActive
        ? colors.actionText
        : colors.textSecondary;
    final Color textColor = isDone
        ? colors.positiveText
        : isError
        ? colors.attentionText
        : colors.textPrimary;

    Widget badge;
    if (isDone) {
      badge = KvIcon(glyph: AppGlyph.check, size: 18, color: badgeFgColor);
    } else if (isError) {
      badge = KvIcon(glyph: AppGlyph.warning, size: 18, color: badgeFgColor);
    } else if (isLoading) {
      badge = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: badgeFgColor),
      );
    } else {
      badge = Text(
        '$number',
        style: AppTextStyles.labelMicro.copyWith(color: badgeFgColor),
      );
    }

    return Opacity(
      opacity: isPendingUnreached ? 0.6 : 1.0,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: badge,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.rowTitle.copyWith(color: textColor),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: AppTextStyles.metaLarge.copyWith(
                      color: isError ? textColor : colors.textSecondary,
                    ),
                  ),
                  if (!isDone && !isPendingUnreached) ...[
                    const SizedBox(height: 10),
                    KvPillButton(
                      label: actionLabel,
                      onPressed: onAction,
                      expand: false,
                      compact: true,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// spec-006 T8/PIXEL_SPEC "Command block": radius 18 padding 12/14,
/// `neutral900` background, mono 11.5 `neutral100` text, 30 px copy button.
class _NativeHostCommandBlock extends StatefulWidget {
  const _NativeHostCommandBlock({required this.command});

  final String command;

  @override
  State<_NativeHostCommandBlock> createState() =>
      _NativeHostCommandBlockState();
}

class _NativeHostCommandBlockState extends State<_NativeHostCommandBlock> {
  bool _copied = false;
  bool _copying = false;

  Future<void> _copy() async {
    if (_copying) return;
    _copying = true;
    await Clipboard.setData(ClipboardData(text: widget.command));
    if (!mounted) {
      _copying = false;
      return;
    }
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
    _copying = false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.neutral900,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.command,
              style: AppTextStyles.meta.copyWith(
                fontFamily: AppTextStyles.monoFamily,
                fontFamilyFallback: AppTextStyles.monoFallback,
                color: AppColors.neutral100,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 30,
            height: 30,
            child: IconButton(
              tooltip: _copied ? 'Copied' : 'Copy',
              onPressed: _copy,
              style: IconButton.styleFrom(
                backgroundColor: AppColors.neutral100.withValues(alpha: 0.12),
                padding: EdgeInsets.zero,
              ),
              icon: KvIcon(
                glyph: _copied ? AppGlyph.check : AppGlyph.copy,
                size: 15,
                color: AppColors.neutral100,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// spec-006 T9 — static diagnostic screen naming the real native-host id
/// (`BrowserSetupService.nativeHostName`) and the three likely causes.
/// Always reachable from the setup screen (see the final report: the app's
/// own bridge check cannot detect this specific Chrome-side failure, so
/// this is informational rather than driven by a live check).
class HostNotFoundDiagnosticScreen extends StatelessWidget {
  const HostNotFoundDiagnosticScreen({super.key, required this.service});

  final BrowserSetupService service;

  String get _expectedManifestDirectory => switch (defaultTargetPlatform) {
    TargetPlatform.macOS =>
      '~/Library/Application Support/Google/Chrome/NativeMessagingHosts/',
    TargetPlatform.linux => '~/.config/google-chrome/NativeMessagingHosts/',
    TargetPlatform.windows =>
      r'HKCU\Software\Google\Chrome\NativeMessagingHosts',
    _ => 'the browser\'s NativeMessagingHosts directory',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Scaffold(
      backgroundColor: colors.ground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Verifica collegamento'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: colors.attentionTint,
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: colors.actionFill,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: KvIcon(
                            glyph: AppGlyph.warning,
                            size: 20,
                            color: colors.actionText,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Host non raggiungibile',
                                style: AppTextStyles.rowTitle.copyWith(
                                  color: colors.attentionText,
                                ),
                              ),
                              Text(
                                'Chrome non trova ${service.nativeHostName}',
                                style: AppTextStyles.metaLarge.copyWith(
                                  color: colors.attentionText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "· L'ID estensione registrato non corrisponde a "
                      'quello caricato\n'
                      '· Lo script di installazione è stato eseguito per '
                      'un altro browser\n'
                      '· Chrome è stato aperto prima della registrazione',
                      style: AppTextStyles.secondary.copyWith(
                        color: colors.attentionText,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Manifest atteso in',
                      style: AppTextStyles.labelUpper.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _expectedManifestDirectory,
                      style: AppTextStyles.meta.copyWith(
                        fontFamily: AppTextStyles.monoFamily,
                        fontFamilyFallback: AppTextStyles.monoFallback,
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              KvPillButton(
                label: 'Riprova la verifica',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 9),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.textPrimary,
                    side: BorderSide(color: colors.divider),
                    minimumSize: const Size(44, 52),
                    shape: const StadiumBorder(),
                    textStyle: AppTextStyles.rowTitle,
                  ),
                  child: const Text('Rivedi il passo 2'),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Il resto di Custode continua a funzionare: senza host '
                'manca solo il riempimento automatico nel browser.',
                style: AppTextStyles.meta.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineStatusMessage extends StatelessWidget {
  const _InlineStatusMessage({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = isError ? colorScheme.error : Colors.green;
    return StyledInfoContainer(
      padding: const EdgeInsets.all(10),
      borderRadius: 8,
      backgroundColor: color.withValues(alpha: 0.1),
      borderColor: color.withValues(alpha: 0.35),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? AppIcons.warning : AppIcons.check,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _AppBridgeStatusBanner extends StatelessWidget {
  const _AppBridgeStatusBanner();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return StyledInfoContainer(
      padding: const EdgeInsets.all(12),
      borderRadius: 10,
      backgroundColor: colorScheme.primaryContainer.withValues(alpha: 0.24),
      borderColor: colorScheme.primary.withValues(alpha: 0.25),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.info, size: 16, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Custode è pronto per collegarsi all\'estensione Chrome.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
