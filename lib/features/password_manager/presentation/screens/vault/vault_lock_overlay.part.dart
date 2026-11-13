part of '../vault_screen.dart';

// spec-006 T4/T5 (FR-3): lock overlay + privacy overlay. Both use the same
// dark ground (`neutral-900`, independent of the app's own light/dark theme
// — this is a security surface, not a themed one) with the 76×76 radius-24
// app mark from mock screen 4 ("Lock · Auto-lock e privacy overlay") in
// `10-12 Sicurezza, autofill, estensione.dc.html`.
//
// Auto-lock timing itself (inactivity timer + 30 s background rule) is
// untouched — both widgets are purely presentational, driven by the
// existing `_VaultViewState` state machine.

/// Test-only clock seam so the "locked for `<duration>`" label is
/// deterministic in golden tests, matching the existing
/// `debugEntryDetailNowOverride` seam in vault_entry_detail.part.dart.
@visibleForTesting
DateTime Function() debugLockOverlayNowOverride = DateTime.now;

/// FR-3 privacy overlay (app backgrounded): dark ground, mark only —
/// **zero `Text` widgets** (AC3), so the OS app-switcher preview cannot
/// leak anything.
///
/// Deliberately public (not `_PrivacyOverlay`) even though every other
/// widget in this file family is library-private: AC3 requires a test that
/// mounts *this widget alone* and asserts `find.byType(Text) == findsNothing`
/// — mounting the full `VaultScreen` behind it would find every Text
/// widget in the rest of the (merely visually-covered) tree and the
/// assertion could never hold. See
/// `test/goldens/lock_privacy_overlay_test.dart`.
class PrivacyOverlay extends StatelessWidget {
  const PrivacyOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Custode is backgrounded',
      child: ColoredBox(
        color: AppColors.neutral900,
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Image.asset(
              'assets/logo/app_icon_family/custode-source-1024.png',
              width: 76,
              height: 76,
              fit: BoxFit.cover,
              cacheWidth: (76 * MediaQuery.devicePixelRatioOf(context)).round(),
              cacheHeight: (76 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
            ),
          ),
        ),
      ),
    );
  }
}

/// FR-3 lock overlay: dark ground, mark 76/r24, "Locked for `<duration>`",
/// three actions — biometrics (existing flow, unchanged), master
/// password (existing `DatabaseUnlockScreen` hand-off, unchanged), and
/// closing the database (new — reuses
/// `_VaultViewState._closeCurrentDatabaseAndSelectAnother`'s confirm +
/// `VaultSessionCoordinator.changeDatabase` flow).
class _LockOverlay extends StatefulWidget {
  const _LockOverlay({
    required this.databasePath,
    required this.databaseLabel,
    required this.lockedAt,
    required this.onUnlocked,
    required this.onCloseDatabase,
  });

  final String databasePath;

  /// spec 014 FR-3: the registry name; the path's basename is opaque on
  /// mobile.
  final String databaseLabel;
  final DateTime lockedAt;
  final VoidCallback onUnlocked;
  final Future<void> Function() onCloseDatabase;

  @override
  State<_LockOverlay> createState() => _LockOverlayState();
}

class _LockOverlayState extends State<_LockOverlay> {
  bool _biometricAvailable = false;
  bool _showPasswordFallback = false;
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initBiometric());
  }

  Future<void> _initBiometric() async {
    final available = await di.sl<BiometricDataSource>().isBiometricAvailable();
    if (!mounted) return;
    setState(() => _biometricAvailable = available);
    if (available) {
      await _triggerBiometric();
    } else {
      setState(() => _showPasswordFallback = true);
    }
  }

  Future<void> _triggerBiometric() async {
    if (_isAuthenticating || !mounted) return;
    setState(() => _isAuthenticating = true);
    final ok = await di.sl<BiometricDataSource>().authenticate(
      reason: 'Unlock vault',
    );
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
      return;
    }
    setState(() {
      _isAuthenticating = false;
      _showPasswordFallback = true;
    });
  }

  Future<void> _usePassword() async {
    await di.sl<VaultSessionCoordinator>().lockVault(
      currentDatabasePath: widget.databasePath,
    );
    if (!mounted) return;
    AppNavigation.pushFadeReplacement(
      context,
      DatabaseUnlockScreen(databasePath: widget.databasePath),
    );
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = debugLockOverlayNowOverride().difference(widget.lockedAt);

    return ColoredBox(
      color: AppColors.neutral900,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 34),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/logo/app_icon_family/custode-source-1024.png',
                    width: 76,
                    height: 76,
                    fit: BoxFit.cover,
                    cacheWidth: (76 * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                    cacheHeight: (76 * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _lockedForLabel(elapsed),
                  textAlign: TextAlign.center,
                  style: AppTextStyles.screenTitle.copyWith(
                    color: AppColors.neutral100,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.databaseLabel} is still open in memory. '
                  "Confirm it's you to continue where you left off.",
                  textAlign: TextAlign.center,
                  style: AppTextStyles.body.copyWith(
                    color: AppColors.neutral100.withValues(alpha: 0.62),
                  ),
                ),
                const SizedBox(height: 24),
                if (_biometricAvailable && !_showPasswordFallback)
                  KvPillButton(
                    label: 'Unlock with biometrics',
                    icon: AppIcons.fingerprint,
                    onPressed: _isAuthenticating ? null : _triggerBiometric,
                  ),
                if (_showPasswordFallback) ...[
                  if (_biometricAvailable) ...[
                    KvPillButton(
                      label: 'Unlock with biometrics',
                      icon: AppIcons.fingerprint,
                      onPressed: _isAuthenticating ? null : _triggerBiometric,
                    ),
                    const SizedBox(height: 10),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _usePassword,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.neutral100,
                        side: BorderSide(
                          color: AppColors.neutral100.withValues(alpha: 0.2),
                        ),
                        minimumSize: const Size(44, 52),
                        shape: const StadiumBorder(),
                        textStyle: AppTextStyles.rowTitle,
                      ),
                      child: const Text('Use master password'),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => widget.onCloseDatabase(),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.neutral100.withValues(
                      alpha: 0.5,
                    ),
                  ),
                  child: const Text('Close the database instead'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _lockedForLabel(Duration elapsed) {
  if (elapsed.inMinutes < 1) {
    final seconds = elapsed.inSeconds.clamp(0, 59);
    return 'Locked for $seconds second${seconds == 1 ? '' : 's'}';
  }
  if (elapsed.inHours < 1) {
    final minutes = elapsed.inMinutes;
    return 'Locked for $minutes minute${minutes == 1 ? '' : 's'}';
  }
  final hours = elapsed.inHours;
  return 'Locked for $hours hour${hours == 1 ? '' : 's'}';
}
