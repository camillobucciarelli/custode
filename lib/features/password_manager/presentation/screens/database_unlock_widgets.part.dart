part of 'database_unlock_screen.dart';

class _UnlockLoading extends StatelessWidget {
  const _UnlockLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

/// FR-5: full-screen dark biometric gate — circle 104 / glyph 50, centred
/// text, two stacked pills. Always dark regardless of app theme: wraps its
/// subtree in `AppTheme.darkTheme` so every descendant (including
/// `KvPillButton`) resolves `CustodeColors.dark` roles through the theme
/// extension instead of duplicating literal hex values.
class _BiometricGate extends StatelessWidget {
  const _BiometricGate({
    required this.onRetry,
    required this.onUseMasterPassword,
    this.errorMessage,
  });

  final VoidCallback onRetry;

  /// Always-available escape hatch to the manual credential form. The
  /// master password is the primary credential, so hiding it behind a
  /// failed biometric attempt would only lock users with a broken sensor
  /// out of their own vault.
  final VoidCallback onUseMasterPassword;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.darkTheme,
      child: Builder(
        builder: (context) {
          final colors = Theme.of(context).extension<CustodeColors>()!;
          return ColoredBox(
            color: colors.ground,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 104,
                        height: 104,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colors.actionFill,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          AppIcons.fingerprint,
                          size: 50,
                          color: colors.actionText,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Authenticate with biometrics',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.screenTitle.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      if (errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          errorMessage!,
                          textAlign: TextAlign.center,
                          style: AppTextStyles.body.copyWith(
                            color: colors.attentionText,
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      KvPillButton(label: 'Retry', onPressed: onRetry),
                      const SizedBox(height: 14),
                      _UnlockCaptionLink(
                        label: 'Use master password instead',
                        onTap: onUseMasterPassword,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// C-4 decrypting: entered before the KDBX await, indeterminate only, no
/// cancel affordance. Reduced motion freezes it to a static busy state.
class _DecryptingView extends StatelessWidget {
  const _DecryptingView({required this.basename});

  final String basename;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              label: 'Decrypting, please wait',
              child: SizedBox(
                width: 34,
                height: 34,
                child: reducedMotion
                    ? Icon(AppIcons.hourglassTop, color: colors.actionEmphasis)
                    : CircularProgressIndicator(
                        strokeWidth: 3,
                        color: colors.actionEmphasis,
                      ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Decrypting $basename',
              textAlign: TextAlign.center,
              style: AppTextStyles.sheetTitleLarge.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Deriving your encryption key with Argon2. This can take a moment.',
              textAlign: TextAlign.center,
              style: AppTextStyles.body.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// C-3: database-level failures (missing/invalid/corrupt) are a dead end
/// until the user goes back — never phrased as a credentials problem.
class _UnlockFailureView extends StatelessWidget {
  const _UnlockFailureView({required this.state, required this.onBack});

  final DatabaseUnlockState state;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 66,
              height: 66,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.attentionTint,
                borderRadius: BorderRadius.circular(24),
              ),
              child: KvIcon(
                glyph: AppGlyph.warning,
                size: 24,
                color: colors.attentionText,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              state.errorMessage ?? 'This database could not be opened.',
              textAlign: TextAlign.center,
              style: AppTextStyles.sheetTitleLarge.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 24),
            KvPillButton(label: 'Back to database list', onPressed: onBack),
          ],
        ),
      ),
    );
  }
}

/// The `Unlock` mockup: back, source chip, lock square, name, then the
/// credential group (password field, key-file row) and the primary pill. One
/// layout on every width (no per-width variants outside the vault shell):
/// top-aligned, content capped at 480 px and centred on wide windows. Every
/// error the bloc leaves in the ready phase renders inside the credential
/// group, next to the field it concerns.
class _UnlockReadyForm extends StatelessWidget {
  const _UnlockReadyForm({
    required this.state,
    required this.passwordCtrl,
    required this.passwordVisible,
    required this.onPasswordChanged,
    required this.onTogglePasswordVisible,
    required this.onPickKeyFile,
    required this.onClearKeyFile,
    required this.onSubmit,
    required this.onBack,
    required this.onBiometricRetry,
  });

  final DatabaseUnlockState state;
  final TextEditingController passwordCtrl;
  final bool passwordVisible;
  final VoidCallback onPasswordChanged;
  final VoidCallback onTogglePasswordVisible;
  final Future<void> Function() onPickKeyFile;
  final VoidCallback onClearKeyFile;

  /// Null disables the primary pill (no credential entered).
  final VoidCallback? onSubmit;
  final VoidCallback onBack;

  /// "Use biometrics" link: on-demand biometric attempt from the ready state.
  /// Reuses `RetryBiometricAuthentication`, the same gate path the bootstrap
  /// flow already drives, instead of a new biometric entry point.
  final VoidCallback onBiometricRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    // The field's errorText is announced by InputDecorator as a live region.
    final credentialError = (state.errorMessage?.isNotEmpty ?? false)
        ? state.errorMessage
        : null;
    final notice = state.notice;

    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 20),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: TweenAnimationBuilder<double>(
            duration: AppMotion.duration(context, AppMotion.unlock),
            curve: AppMotion.inCurve,
            tween: Tween(begin: 0.98, end: 1),
            builder: (context, value, child) => Transform.scale(
              scale: value,
              child: Opacity(opacity: value, child: child),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SourceChip(
                  remote: state.isRemoteLinked,
                  account: state.remoteAccount,
                ),
                const SizedBox(height: 14),
                _UnlockHeaderSquare(
                  glyph: AppGlyph.lock,
                  background: colors.surface,
                  foreground: colors.textPrimary,
                ),
                const SizedBox(height: 14),
                Semantics(
                  header: true,
                  child: Text(
                    state.databaseLabel,
                    style: AppTextStyles.screenTitleLarge.copyWith(
                      fontSize: 32,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Column(
                  key: const ValueKey('unlock-credentials'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    kvFieldLabel('Master password', colors),
                    TextFormField(
                      controller: passwordCtrl,
                      obscureText: !passwordVisible,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: AppTextStyles.secret.copyWith(
                        color: colors.textPrimary,
                      ),
                      onChanged: (_) => onPasswordChanged(),
                      onFieldSubmitted: (_) => onSubmit?.call(),
                      decoration: kvFieldDecoration(
                        colors,
                        hint: 'Master password',
                        errorText: credentialError,
                        suffixIcon: KvCircleIconButton(
                          glyph: passwordVisible
                              ? AppGlyph.eyeOff
                              : AppGlyph.eye,
                          tooltip: passwordVisible
                              ? 'Hide password'
                              : 'Show password',
                          nested: true,
                          size: 44,
                          iconSize: 18,
                          onPressed: onTogglePasswordVisible,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    KeyFileRow(
                      path: state.keyFilePath,
                      onPick: () => onPickKeyFile(),
                      onClear: onClearKeyFile,
                    ),
                    // Not an error: the key above is usable, only the choice
                    // was not saved. Announced, never blocking.
                    if (notice != null) ...[
                      const SizedBox(height: 8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          notice,
                          style: AppTextStyles.secondary.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 26),
                KvPillButton(label: 'Unlock', onPressed: onSubmit),
                // FR-U1: offered whenever biometric protection is on for this
                // database and the device can do it. It never unlocks by
                // itself: it re-enters the biometric gate, and only a passed
                // gate reads the stored credential.
                if (state.biometricEnabled && state.biometricAvailable)
                  Center(
                    child: TextButton.icon(
                      onPressed: onBiometricRetry,
                      style: TextButton.styleFrom(
                        foregroundColor: colors.linkText,
                        minimumSize: const Size(44, 44),
                        textStyle: AppTextStyles.rowTitle,
                      ),
                      icon: KvIcon(glyph: AppGlyph.fingerprint, size: 18),
                      label: const Text('Use biometrics'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _UnlockBackButton(onBack: onBack),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

class _UnlockBackButton extends StatelessWidget {
  const _UnlockBackButton({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: KvCircleIconButton(
        glyph: AppGlyph.back,
        tooltip: 'Back to databases',
        size: 44,
        iconSize: 18,
        onPressed: onBack,
      ),
    );
  }
}

/// The 66 px rounded square above the database name, shared by the ready and
/// missing views.
class _UnlockHeaderSquare extends StatelessWidget {
  const _UnlockHeaderSquare({
    required this.glyph,
    required this.background,
    required this.foreground,
  });

  final AppGlyph glyph;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 66,
      height: 66,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: ExcludeSemantics(
        child: KvIcon(glyph: glyph, size: 28, color: foreground),
      ),
    );
  }
}

/// The `UnlockMissing` mockup (spec 025 FR-U4): the file is gone, so the screen
/// offers the repairs instead of a dead end. Re-download needs a sync mapping
/// and a platform that supports remote sources; remove asks first.
class _UnlockMissingView extends StatelessWidget {
  const _UnlockMissingView({
    required this.state,
    required this.onLocate,
    required this.onRedownload,
    required this.onRemove,
    required this.onBack,
  });

  final DatabaseUnlockState state;
  final VoidCallback onLocate;
  final VoidCallback onRedownload;
  final VoidCallback onRemove;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final error = state.errorMessage;
    final canRedownload = state.isRemoteLinked && supportsRemoteSource;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _UnlockBackButton(onBack: onBack),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SourceChip(
                          remote: state.isRemoteLinked,
                          account: state.remoteAccount,
                        ),
                        const SizedBox(height: 14),
                        _UnlockHeaderSquare(
                          glyph: AppGlyph.warning,
                          background: colors.attentionTint,
                          foreground: colors.attentionText,
                        ),
                        const SizedBox(height: 14),
                        Semantics(
                          header: true,
                          child: Text(
                            "${state.databaseLabel} can't be found",
                            style: AppTextStyles.screenTitleLarge.copyWith(
                              fontSize: 32,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'The file is no longer where Custode last saw it.',
                          style: AppTextStyles.body.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                        if (error != null && error.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              error,
                              style: AppTextStyles.secondary.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colors.attentionText,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        KvPillButton(label: 'Locate file', onPressed: onLocate),
                        if (canRedownload) ...[
                          const SizedBox(height: 10),
                          KvSecondaryPillButton(
                            label: 'Download again from Google Drive',
                            onPressed: onRedownload,
                          ),
                        ],
                        const SizedBox(height: 6),
                        Center(
                          child: TextButton(
                            onPressed: onRemove,
                            style: TextButton.styleFrom(
                              foregroundColor: colors.linkText,
                              minimumSize: const Size(44, 44),
                              textStyle: AppTextStyles.rowTitle,
                            ),
                            child: const Text('Remove from list'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Center(
              child: TextButton.icon(
                onPressed: onBack,
                style: TextButton.styleFrom(
                  foregroundColor: colors.linkText,
                  minimumSize: const Size(44, 44),
                  textStyle: AppTextStyles.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                icon: KvIcon(glyph: AppGlyph.back, size: 16),
                label: const Text('Back to databases'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// spec-016: an autofill save is waiting on this unlock.
///
/// It sits above every unlock phase, not inside the password form: with
/// biometrics enabled that form is never shown, and that is exactly the case
/// where the user is most likely to walk away without knowing what it costs.
///
/// Styled as part of the screen rather than as a coloured block: the system
/// biometric prompt covers the app while it is up, so this has to still read
/// as the screen's own message once the prompt is dismissed.
class _PendingCaptureNotice extends StatelessWidget {
  const _PendingCaptureNotice();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.rowNested),
          border: Border.all(color: colors.attentionText, width: 1.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(AppIcons.save, size: 20, color: colors.attentionText),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A password is waiting to be saved',
                    style: AppTextStyles.rowTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'You just submitted it in another app. Unlock to save it — '
                    'leave this screen and it is discarded.',
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single caption-style link: "Use master password instead" (biometric
/// gate).
class _UnlockCaptionLink extends StatelessWidget {
  const _UnlockCaptionLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return InkWell(
      onTap: onTap,
      child: Text(
        label,
        style: AppTextStyles.body.copyWith(
          fontSize: 13.5,
          color: colors.linkText,
        ),
      ),
    );
  }
}

/// Passkeys-all-platforms FR-9: a passkey created in the autofill surface is
/// waiting for this unlock. Same styling as [_PendingCaptureNotice].
class _WaitingPasskeysNotice extends StatelessWidget {
  const _WaitingPasskeysNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final title = count == 1
        ? '1 passkey is waiting'
        : '$count passkeys are waiting';
    const body =
        'Created on this device and not yet in your vault. Unlock to add '
        'them. Until then they exist only on this device.';

    return SafeArea(
      bottom: false,
      child: Semantics(
        container: true,
        liveRegion: true,
        label: '$title. $body',
        excludeSemantics: true,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(AppRadii.rowNested),
            border: Border.all(color: colors.attentionText, width: 1.5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(AppIcons.key, size: 20, color: colors.attentionText),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.rowTitle.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: AppTextStyles.secondary.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
