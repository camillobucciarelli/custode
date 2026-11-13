part of '../vault_screen.dart';

// 009 / B005 — vault-screen surface for browser-generated pending secrets.
//
// The desktop reveal bridge registers generated-but-unsaved passwords in the
// in-memory `DesktopBrowserPendingGenerationService`; this banner is the app
// UI that closes the loop: it shows the non-secret snapshot ("Password
// generated for <origin>"), and confirming routes through the app's normal
// new-entry editor + `CreateVaultEntry` — no new vault write path.
//
// Consume timing: consume-at-save. The one-shot, origin-bound `consume` runs
// only after the user commits the editor form, so cancelling the editor
// leaves the record pending (still claimable until expiry) and the secret
// never sits in a controller, widget state, stream, or bloc state before the
// commit — it exists outside the service only on the stack frame that hands
// it to `CreateVaultEntry`.

String _pendingGenerationTitleSuggestion(String origin) {
  final host = Uri.tryParse(origin)?.host;
  return (host == null || host.isEmpty) ? origin : host;
}

String _pendingGenerationCountdown(int expiresAtEpochMs, DateTime now) {
  final remainingMs = expiresAtEpochMs - now.millisecondsSinceEpoch;
  final remaining = remainingMs > 0
      ? Duration(milliseconds: remainingMs)
      : Duration.zero;
  final minutes = remaining.inMinutes;
  final seconds = remaining.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _PendingGenerationBanner extends StatefulWidget {
  const _PendingGenerationBanner();

  @override
  State<_PendingGenerationBanner> createState() =>
      _PendingGenerationBannerState();
}

class _PendingGenerationBannerState extends State<_PendingGenerationBanner> {
  late final DesktopBrowserPendingGenerationService _pendingGeneration;
  Timer? _countdownTicker;
  bool _isConfirming = false;

  @override
  void initState() {
    super.initState();
    _pendingGeneration = di.sl<DesktopBrowserPendingGenerationService>();
    _pendingGeneration.pendingListenable.addListener(_onPendingChanged);
    _syncCountdownTicker();
  }

  @override
  void dispose() {
    _pendingGeneration.pendingListenable.removeListener(_onPendingChanged);
    _countdownTicker?.cancel();
    super.dispose();
  }

  void _onPendingChanged() {
    if (mounted) {
      setState(_syncCountdownTicker);
    }
  }

  void _syncCountdownTicker() {
    final hasPending = _pendingGeneration.pendingListenable.value.isNotEmpty;
    if (hasPending) {
      _countdownTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      _countdownTicker?.cancel();
      _countdownTicker = null;
    }
  }

  Future<void> _confirm(PendingGeneratedEntrySnapshot snapshot) async {
    if (_isConfirming) {
      return;
    }
    _isConfirming = true;
    try {
      final payload = await _showEntryDialog(
        context,
        initialTitle: _pendingGenerationTitleSuggestion(snapshot.origin),
        initialUrl: snapshot.origin,
        initialPendingHint: true,
      );
      if (payload == null || !mounted) {
        // Editor cancelled: the record stays pending until expiry.
        return;
      }
      // Late one-shot consume — see header comment. A password the user
      // typed in the editor wins; the record is consumed either way (the
      // browser fill it backs was fulfilled by this save).
      final draft = _pendingGeneration.consume(
        snapshot.id,
        origin: snapshot.origin,
      );
      final password = payload.password.isNotEmpty
          ? payload.password
          : draft?.password;
      if (password == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The generated password expired before saving. Generate a new one from the browser.',
            ),
          ),
        );
        return;
      }
      context.read<VaultBloc>().add(
        CreateVaultEntry(
          title: payload.title,
          username: payload.username,
          password: password,
          url: payload.url,
          notes: payload.notes,
          customFields: payload.customFields,
          attachmentPaths: payload.attachmentPaths,
        ),
      );
    } finally {
      _isConfirming = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PendingGeneratedEntrySnapshot>>(
      valueListenable: _pendingGeneration.pendingListenable,
      builder: (context, pending, _) {
        if (pending.isEmpty) {
          return const SizedBox.shrink();
        }
        final snapshot = pending.first;
        final colors = Theme.of(context).extension<CustodeColors>()!;
        final countdown = _pendingGenerationCountdown(
          snapshot.expiresAtEpochMs,
          DateTime.now(),
        );
        final extra = pending.length > 1
            ? ' (+${pending.length - 1} more)'
            : '';

        return Padding(
          padding: const EdgeInsets.only(bottom: _VaultUiTokens.panelGap),
          child: Material(
            key: const ValueKey('pending-generation-banner'),
            color: colors.surface,
            borderRadius: BorderRadius.circular(_VaultUiTokens.cardRadius),
            child: InkWell(
              borderRadius: BorderRadius.circular(_VaultUiTokens.cardRadius),
              onTap: () => _confirm(snapshot),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _VaultUiTokens.cardPadding,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    KvIcon(
                      glyph: AppGlyph.key,
                      size: 18,
                      color: colors.linkText,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Password generated for ${snapshot.origin} — confirm to save$extra',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.secondary.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Expires in $countdown',
                            style: AppTextStyles.secondary.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('pending-generation-banner-dismiss'),
                      tooltip: 'Dismiss',
                      onPressed: () => _pendingGeneration.reject(snapshot.id),
                      icon: KvIcon(
                        glyph: AppGlyph.close,
                        size: 16,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
