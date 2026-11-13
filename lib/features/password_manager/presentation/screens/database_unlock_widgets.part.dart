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
              child: Icon(AppIcons.warning, color: colors.attentionText),
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

/// FR-5 ready state: feature square 66/radius24, title 32, the shared
/// `kvFieldDecoration` password field, primary pill. One layout on every
/// width (2026-09-05, user-directed: no per-width variants outside the vault
/// shell): top-aligned, circular back icon, content capped at 480 px and
/// centred horizontally on wide windows. A selected key file is one
/// `KvListRow` under the field; the "Use a key file" / "Biometric unlock"
/// inline links (1×14 divider) offer whatever is not yet on screen.
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

  /// Null disables the primary pill (C-5-adjacent: no credential entered).
  final VoidCallback? onSubmit;
  final VoidCallback onBack;

  /// "Biometric unlock" link: on-demand biometric attempt from the ready
  /// state. Reuses `RetryBiometricAuthentication` — the same gate path the
  /// bootstrap flow already drives — instead of a new biometric entry point.
  final VoidCallback onBiometricRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final basename = state.databaseLabel;
    final hasKeyFile =
        state.keyFilePath != null && state.keyFilePath!.trim().isNotEmpty;

    final credentialError =
        state.failure != null &&
            (state.failure is InvalidCredentialsFailure ||
                state.failure is KeyFileMissingFailure)
        ? state.errorMessage
        : null;

    // Top-aligned like every other screen, the outer 20 px gutter is the
    // only lateral padding; wide windows only cap the width.
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 66,
                    height: 66,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.attentionTint,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(AppIcons.lock, color: colors.attentionText),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  basename,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.screenTitleLarge.copyWith(
                    fontSize: 32,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Enter your master password or select a key file to '
                  'unlock this vault.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.body.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 24),
                // The same field recipe as the entry editor: label above,
                // hint inside, circle action on the right. Its helper reads
                // "Optional while a key file is selected." / "Required if no
                // key file is selected." under the field.
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
                      glyph: passwordVisible ? AppGlyph.eyeOff : AppGlyph.eye,
                      tooltip: passwordVisible
                          ? 'Hide password'
                          : 'Show password',
                      nested: true,
                      onPressed: onTogglePasswordVisible,
                    ),
                  ),
                ),
                if (credentialError == null) ...[
                  const SizedBox(height: 6),
                  Text(
                    hasKeyFile
                        ? 'Optional while a key file is selected.'
                        : 'Required if no key file is selected.',
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                if (hasKeyFile) ...[
                  const SizedBox(height: 16),
                  _KeyFileSelector(
                    keyFilePath: state.keyFilePath!,
                    onPickKeyFile: onPickKeyFile,
                    onClearKeyFile: onClearKeyFile,
                  ),
                ],
                const SizedBox(height: 20),
                KvPillButton(
                  label: hasKeyFile ? 'Unlock with key file' : 'Unlock vault',
                  onPressed: onSubmit,
                ),
                const SizedBox(height: 14),
                _UnlockLinkRow(
                  // The row above owns changing the key file once one is
                  // selected; this only offers what is not yet on screen.
                  onPickKeyFile: hasKeyFile ? null : () => onPickKeyFile(),
                  // Only after the user left the biometric gate through "Use
                  // master password instead": that is the one case where a
                  // stored credential exists and a second attempt can unlock.
                  // Sensor presence alone used to show it, and then it did
                  // nothing useful.
                  biometricAvailable:
                      state.manualFallbackRequested && !state.biometricVerified,
                  onBiometricRetry: onBiometricRetry,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Circular back icon replaces the old "Back to database list" text link
    // (mock 02 "Unlock" default) — same pattern as `_CreateHeader` in
    // create_database_screen.dart.
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    onPressed: onBack,
                    icon: const Icon(AppIcons.back),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            Expanded(child: content),
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

/// FR-5 default: "Use a key file" link, plus (only when
/// `biometricAvailable`) a 1×14 divider and "Biometric unlock" — 13 px
/// `linkText` inline links (mock 01-02 "Unlock" default state). The name is
/// deliberately generic: the sensor is Face ID, Touch ID, fingerprint or
/// face unlock depending on the device, and the OS prompt names it.
class _UnlockLinkRow extends StatelessWidget {
  const _UnlockLinkRow({
    required this.onPickKeyFile,
    required this.biometricAvailable,
    required this.onBiometricRetry,
  });

  /// Null hides the link (a key file is already selected).
  final VoidCallback? onPickKeyFile;
  final bool biometricAvailable;
  final VoidCallback onBiometricRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    Widget link(IconData icon, String label, VoidCallback onTap) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: colors.linkText),
              const SizedBox(width: 7),
              Text(
                label,
                style: AppTextStyles.body.copyWith(
                  fontSize: 13,
                  color: colors.linkText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        children: [
          if (onPickKeyFile != null)
            link(AppIcons.key, 'Use a key file', onPickKeyFile!),
          if (onPickKeyFile != null && biometricAvailable)
            Container(width: 1, height: 14, color: colors.divider),
          if (biometricAvailable)
            link(AppIcons.fingerprint, 'Biometric unlock', onBiometricRetry),
        ],
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

/// The selected key file as one standard list row (same `KvListRow` the
/// rest of the app uses): tap changes it, the trailing circle removes it.
/// Replaces the old card with two outlined buttons, which was the only
/// surface on this screen not drawn from the shared widget set.
class _KeyFileSelector extends StatelessWidget {
  const _KeyFileSelector({
    required this.keyFilePath,
    required this.onPickKeyFile,
    required this.onClearKeyFile,
  });

  final String keyFilePath;
  final Future<void> Function() onPickKeyFile;
  final VoidCallback onClearKeyFile;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final basename = kIsWeb ? keyFilePath : p.basename(keyFilePath);
    // spec 014 FR-3: a managed key rests under an opaque identifier; the
    // real name is recorded by `MobileFileStorage` and looked up here.
    final opaque = MobileFileStorage.isOpaqueFileName(basename);

    return FutureBuilder<String>(
      future: opaque
          ? MobileFileStorage.keyFileDisplayName(keyFilePath)
          : Future.value(basename),
      initialData: opaque ? 'Key file' : basename,
      builder: (context, snapshot) => KvListRow(
        title: snapshot.data!,
        subtitle: opaque || isManagedStoragePlatform
            ? 'Stored in app internal key storage.'
            : keyFilePath,
        semanticLabel: 'Change key file',
        onTap: () => onPickKeyFile(),
        leading: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.positiveTint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: KvIcon(
            glyph: AppGlyph.key,
            size: 18,
            color: colors.positiveText,
          ),
        ),
        trailing: KvCircleIconButton(
          glyph: AppGlyph.close,
          tooltip: 'Remove key file',
          nested: true,
          onPressed: onClearKeyFile,
        ),
      ),
    );
  }
}
