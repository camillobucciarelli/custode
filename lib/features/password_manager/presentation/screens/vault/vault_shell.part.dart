part of '../vault_screen.dart';

class _VaultLayoutBreakpoints {
  const _VaultLayoutBreakpoints._();

  static const double tabletMax = Breakpoints.tablet;
  static const double compactPhone = 380;
}

class _VaultUiTokens {
  const _VaultUiTokens._();

  static const double cardPadding = 14;
  static const double cardRadius = 18;
  static const double panelGap = 12;
  static const double recordListSpacing = 8;
  static const Duration itemTransitionDuration = Duration(milliseconds: 190);
  static const Duration buttonTransitionDuration = Duration(milliseconds: 220);
}

class VaultScreen extends StatelessWidget {
  const VaultScreen({
    super.key,
    required this.databasePath,
    // spec-006 T16: the lock/privacy overlays are only reachable via a real
    // inactivity timer firing or a >=30s background/resume cycle — neither
    // is practical to drive deterministically from a widget test. These
    // test-only seeds let goldens render the overlays directly, matching
    // the `debugEntryDetailNowOverride` / `debugLockOverlayNowOverride`
    // clock-seam convention already used elsewhere in this file family.
    @visibleForTesting this.debugInitiallyLocked = false,
    @visibleForTesting this.debugInitiallyBackground = false,
  });

  final String databasePath;
  final bool debugInitiallyLocked;
  final bool debugInitiallyBackground;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          di.sl<VaultBloc>(param1: databasePath)..add(const InitializeVault()),
      child: _VaultView(
        debugInitiallyLocked: debugInitiallyLocked,
        debugInitiallyBackground: debugInitiallyBackground,
      ),
    );
  }
}

/// Padding metrics for the vault pane. spec-018 T047: this used to also
/// publish `isMobile` / `isCompact` / `isTablet` — three more width
/// comparisons, against a fourth threshold, that **nothing read**. They are
/// deleted rather than kept in step, because a spare notion of "is this wide?"
/// lying around is how the shell, the list and the router drifted apart in
/// the first place (D2). Layout decisions come from `VaultLayoutClass`; this
/// type now only carries padding.
class _VaultLayoutSpec {
  const _VaultLayoutSpec({
    required this.horizontalPadding,
    required this.contentTopPadding,
  });

  final double horizontalPadding;
  final double contentTopPadding;

  static _VaultLayoutSpec fromWidth(double width) {
    return _VaultLayoutSpec(
      horizontalPadding: width < _VaultLayoutBreakpoints.compactPhone
          ? 12.0
          : 16.0,
      contentTopPadding: width < _VaultLayoutBreakpoints.tabletMax ? 8 : 12,
    );
  }
}

class _VaultView extends StatefulWidget {
  const _VaultView({
    this.debugInitiallyLocked = false,
    this.debugInitiallyBackground = false,
  });

  final bool debugInitiallyLocked;
  final bool debugInitiallyBackground;

  @override
  State<_VaultView> createState() => _VaultViewState();
}

class _VaultViewState extends State<_VaultView> with WidgetsBindingObserver {
  bool _syncConflictSheetOpen = false;
  late final VaultShellRouter _router;
  // Resolved once, at construction, and held for this State's lifetime.
  // `dispose()` must not reach back into the service locator: a widget's
  // teardown has to stay valid even while the DI graph is being torn down or
  // rebuilt around it (test teardown does exactly that today, and a future
  // "change database" flow that re-registered the graph would do it in
  // production). Reading `di.sl<T>()` at destruction time makes teardown
  // depend on a global still being registered, which is an ordering
  // assumption a `dispose()` cannot enforce.
  late final OtpAuthDeepLinkCoordinator _otpAuthCoordinator;
  VaultDestination _selectedDestination = VaultDestination.vault;
  Widget? _activePane;
  // spec-018 FR-003: the ONE owner of "which record is being looked at".
  // Previously `_EntriesCardState` kept a private copy for its own inline
  // split while the router published a pane from a different rule, so the
  // highlighted row and the visible detail could disagree (D3, D8). An id
  // only — never a `VaultEntry`, never a secret (Constitution I).
  String? _selectedEntryId;
  // True while a detail session is live, so selecting the same row twice is
  // a no-op instead of stacking a second session.
  bool _hasDetailSession = false;
  DateTime? _backgroundedAt;
  bool _isBackground = false;
  // The one lock state of the shell, plus the two hooks a surface outside
  // this subtree needs, published through `VaultShellSessionScope`.
  // `_LockOverlay` is a widget inside this Scaffold's body, so anything
  // hosted on the Navigator (a pushed detail, a dialog, a sheet) renders
  // *above* it and would stay live and tappable while the vault is locked,
  // and sits outside the pointer `Listener` that feeds the inactivity timer.
  // This stays the only definition of "locked" (spec 017 FR-003).
  late final VaultShellSession _session = VaultShellSession(
    onUserActivity: _resetInactivityTimer,
    lockAndReauthenticate: _lockAndReauthenticate,
  );
  bool get _isLocked => _session.isLocked;
  set _isLocked(bool value) => _session.isLocked = value;
  // spec-006 T4: when the lock overlay engaged, so it can render "locked
  // for <duration>" (FR-3). Cleared on unlock.
  DateTime? _lockedAt;
  Timer? _inactivityTimer;
  StreamSubscription<OtpAuthDeepLinkEvent>? _otpAuthSubscription;
  final List<OtpAuthDeepLinkEvent> _otpAuthEventQueue = [];
  int? _inactivityTimeoutSeconds;
  bool _otpAuthVaultMarkedAvailable = false;
  bool _isHandlingOtpAuth = false;
  String? _activeAppleAutofillAssociationDialogId;
  // spec-016 US3: one capture confirmation at a time, and one pull per
  // foregrounding — the app is launched again for every save request.
  bool _isAndroidAutofillSaveDialogOpen = false;
  bool _androidAutofillCapturePulled = false;
  // Guards against `_router.dispose()` (below) synchronously cancelling any
  // open session and calling back into `onPaneChanged` -> `setState` while
  // *this* State's own `dispose()` is still running. `mounted` alone does
  // not catch this: `State.mounted` only reflects whether `_element` has
  // been cleared, which happens *after* `dispose()` returns, so it is still
  // `true` for the whole duration of `dispose()` even though the Element's
  // lifecycle has already moved past "active" — calling `setState` in that
  // window trips a framework assertion. Found while adding spec-004's entry
  // detail/editor/generator golden tests (the first tests that ever tear
  // down `VaultScreen` while a pane/sheet session is open); the same crash
  // would hit a real user who closes/backgrounds the app with an entry,
  // editor, or generator open.
  bool _isDisposing = false;

  @override
  void initState() {
    super.initState();
    _isLocked = widget.debugInitiallyLocked;
    _isBackground = widget.debugInitiallyBackground;
    if (_isLocked) {
      _lockedAt = debugLockOverlayNowOverride();
    }
    _router = VaultShellRouter(
      onPaneChanged: (pane) {
        if (mounted && !_isDisposing) {
          setState(() => _activePane = pane);
        }
      },
    );
    // FR-002e: the folder column yields to the generator column, so the shell
    // must rebuild when the editor opens or closes it.
    _router.generatorColumnOpen.addListener(_onGeneratorColumnChanged);
    WidgetsBinding.instance.addObserver(this);
    _otpAuthCoordinator = di.sl<OtpAuthDeepLinkCoordinator>();
    _otpAuthSubscription = _otpAuthCoordinator.events.listen(
      _handleOtpAuthEvent,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowAutofillOnboardingDialog();
      _loadInactivityTimeout();
    });
  }

  void _onGeneratorColumnChanged() {
    if (!mounted || _isDisposing) {
      return;
    }
    // Deferred rather than immediate: the editor clears this flag from its own
    // `dispose`, which runs while the element tree is locked, and a synchronous
    // `setState` there throws. The flag only selects a layout — never the
    // outcome of a pending write — so a frame's delay costs nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_isDisposing) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _isDisposing = true;
    _router.generatorColumnOpen.removeListener(_onGeneratorColumnChanged);
    _router.dispose();
    _inactivityTimer?.cancel();
    _otpAuthSubscription?.cancel();
    _otpAuthCoordinator.markVaultUnavailable();
    _session.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _selectDestination(VaultDestination destination) async {
    if (destination == _selectedDestination) {
      return;
    }
    if (!await _router.cancelForDestinationChange() || !mounted) {
      return;
    }
    setState(() {
      _selectedDestination = destination;
      // spec-018 FR-003: leaving the Vault destination ends the detail
      // session, so the selection must go with it.
      _selectedEntryId = null;
      _hasDetailSession = false;
    });
  }

  /// spec-018 FR-001a: the records list reports a selection; the shell
  /// decides how it is presented. One entry point, so push and pane can
  /// never diverge again.
  Future<void> _selectEntry(BuildContext context, String entryId) async {
    if (_selectedEntryId == entryId && _hasDetailSession) {
      return;
    }
    // Close whatever detail (and anything stacked on it) is open before
    // opening the next one, so two records can never be shown at once
    // (FR-001). This also runs the editor's discard guard, so switching rows
    // mid-edit asks before throwing the edit away rather than silently
    // dropping it — the same protection a destination change already had.
    if (_hasDetailSession && !await _router.cancelForDestinationChange()) {
      return;
    }
    // Both guards are needed: `mounted`/`_isDisposing` for this State, and
    // `context.mounted` for the caller's context, which is the one handed to
    // the router below and belongs to the vault pane, not to this State.
    if (!mounted || _isDisposing || !context.mounted) {
      return;
    }
    setState(() {
      _selectedEntryId = entryId;
      _hasDetailSession = true;
    });
    await _openEntryDetailsSurface(context, entryId: entryId);
    // The session ended — by back, escape, completion, or the record being
    // deleted. FR-003/G4.4: whatever ended it clears the selection, so the
    // highlight can never outlive the detail it points at.
    if (!mounted || _isDisposing || _selectedEntryId != entryId) {
      return;
    }
    setState(() {
      _selectedEntryId = null;
      _hasDetailSession = false;
    });
  }

  /// spec-018 FR-002a/FR-002e: the layout class for this frame.
  ///
  /// It is the window width's class, with one adjustment: while the editor is
  /// showing its generator as a column, the folder column is dropped to make
  /// room. Below `VaultLayoutWidths.foldersAndGenerator` (1232) the two
  /// cannot coexist — at the 1024 design baseline they never do — and the
  /// design's rule is explicit that the folder column is what yields, never
  /// the records list, which is the screen's navigation spine.
  VaultLayoutClass _effectiveLayout(BuildContext context) {
    final layout = VaultLayoutClass.fromWidth(MediaQuery.sizeOf(context).width);
    if (layout == VaultLayoutClass.wideWithFolders &&
        _router.generatorColumnOpen.value &&
        MediaQuery.sizeOf(context).width <
            VaultLayoutWidths.foldersAndGenerator) {
      return VaultLayoutClass.wide;
    }
    return layout;
  }

  /// FR-014: a selection that has left the visible list is not a selection.
  ///
  /// Deletion does not come through here — a deleted record ends its own
  /// session from inside the detail (FR-007), which resolves the await in
  /// [_selectEntry]. This covers the case the detail cannot see: the record
  /// still exists but a search or folder change filtered it out of the list.
  void _dropSelectionIfNotVisible(Set<String> visibleEntryIds) {
    final selected = _selectedEntryId;
    if (selected == null || visibleEntryIds.contains(selected)) {
      return;
    }
    // Called from a build; cancelling a session mutates the router and can
    // publish a new pane, so defer it out of the build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposing || _selectedEntryId != selected) {
        return;
      }
      unawaited(_router.cancelForDestinationChange());
    });
  }

  void _markOtpAuthVaultAvailableIfReady(VaultState state) {
    if (_otpAuthVaultMarkedAvailable ||
        state.isLoading ||
        state.rootGroupId == null) {
      return;
    }
    _otpAuthVaultMarkedAvailable = true;
    _otpAuthCoordinator.markVaultAvailable();
  }

  Future<void> _handleOtpAuthEvent(OtpAuthDeepLinkEvent event) async {
    if (!mounted) {
      return;
    }
    final errorMessage = event.errorMessage;
    if (errorMessage != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(errorMessage)));
      return;
    }

    final otpAuth = event.otpAuth;
    if (otpAuth == null) {
      return;
    }

    if (_isHandlingOtpAuth) {
      _otpAuthEventQueue.add(event);
      return;
    }

    _isHandlingOtpAuth = true;
    try {
      final shouldAdd = await _router.confirm(
        context: context,
        title: 'Add OTP account?',
        body:
            'An OTP account for ${otpAuth.title} was received. Review it before saving to this vault.',
        cancelLabel: 'Not now',
        confirmLabel: 'Review',
      );

      if (shouldAdd != ConfirmDecision.confirm || !mounted) {
        return;
      }

      final payload = await _showEntryDialog(
        context,
        initialOtpAuth: otpAuth,
        router: _router,
      );
      if (payload == null || !mounted) {
        return;
      }

      context.read<VaultBloc>().add(
        CreateVaultEntry(
          title: payload.title,
          username: payload.username,
          password: payload.password,
          url: payload.url,
          notes: payload.notes,
          customFields: payload.customFields,
          attachmentPaths: payload.attachmentPaths,
        ),
      );
    } finally {
      _isHandlingOtpAuth = false;
      if (mounted && _otpAuthEventQueue.isNotEmpty) {
        final next = _otpAuthEventQueue.removeAt(0);
        unawaited(_handleOtpAuthEvent(next));
      }
    }
  }

  Future<void> _loadInactivityTimeout() async {
    if (!mounted) return;
    final databasePath = context.read<VaultBloc>().state.databasePath;
    final seconds = await di
        .sl<VaultSessionCoordinator>()
        .getInactivityLockTimeoutForPath(databasePath: databasePath);
    if (!mounted) return;
    setState(() => _inactivityTimeoutSeconds = seconds);
    _resetInactivityTimer();
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    final seconds = _inactivityTimeoutSeconds;
    if (seconds == null || _isLocked || _isBackground) return;
    _inactivityTimer = Timer(
      Duration(seconds: seconds),
      _triggerInactivityLock,
    );
  }

  /// Lock now and send the user to the unlock screen, replacing *this*
  /// shell's route.
  ///
  /// Owned here rather than by the surface that asks for it: the reveal gate
  /// is a root-navigator sheet that can be opened from the detail (a pane, or
  /// a pushed route) or from the history dialog, so `pushReplacement` on the
  /// caller's Navigator replaced whichever of those happened to be on top and
  /// left the unlocked shell alive underneath it.
  Future<void> _lockAndReauthenticate(String databasePath) async {
    await di.sl<VaultSessionCoordinator>().lockVault(
      currentDatabasePath: databasePath,
    );
    if (!mounted) return;
    final shellRoute = ModalRoute.of(context);
    if (shellRoute != null) {
      Navigator.of(context).popUntil((route) => route == shellRoute);
    }
    if (!mounted) return;
    AppNavigation.pushFadeReplacement(
      context,
      DatabaseUnlockScreen(databasePath: databasePath),
    );
  }

  void _triggerInactivityLock() {
    if (!mounted || _isLocked) return;
    setState(() {
      _isLocked = true;
      _lockedAt = debugLockOverlayNowOverride();
    });
  }

  void _dismissLock() {
    if (!mounted) return;
    setState(() {
      _isLocked = false;
      _lockedAt = null;
    });
    _resetInactivityTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        _backgroundedAt ??= debugLockOverlayNowOverride();
        _inactivityTimer?.cancel();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundedAt ??= debugLockOverlayNowOverride();
        _inactivityTimer?.cancel();
        if (!_isLocked && mounted) {
          setState(() => _isBackground = true);
        }
        break;
      case AppLifecycleState.resumed:
        _onAppResumed();
        break;
      case AppLifecycleState.detached:
        // spec-011 FR-2: process termination drops the in-memory session
        // secret. Keystore contents are untouched in Slice 1.
        di.sl<VaultSessionCoordinator>().handleAppDetached();
        break;
    }
  }

  /// Background lock backstop when `Lock on inactivity` is unset: `Never`
  /// disables the foreground timer, not the guarantee that a backgrounded
  /// vault eventually locks.
  static const _kUnsetBackgroundLockCeiling = Duration(minutes: 15);

  void _onAppResumed() {
    if (!mounted) return;

    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;

    final elapsed = backgroundedAt != null
        ? DateTime.now().difference(backgroundedAt)
        : Duration.zero;
    // 2026-08-31: the FOREGROUND inactivity timer runs only when configured
    // (the old fixed 30 s background rule locked vaults whose setting says
    // `Never`). For the background an unset timeout still keeps a
    // conservative ceiling (PR #180 review): a password manager left in the
    // background must not stay unlocked forever, so `Never` governs the
    // foreground timer while a long backstop covers the background.
    final timeoutSeconds = _inactivityTimeoutSeconds;
    final backgroundCeiling = timeoutSeconds != null
        ? Duration(seconds: timeoutSeconds)
        : _kUnsetBackgroundLockCeiling;
    final shouldLock = elapsed >= backgroundCeiling;

    setState(() {
      _isBackground = false;
      if (shouldLock) {
        _isLocked = true;
        _lockedAt = debugLockOverlayNowOverride();
      }
    });

    if (!shouldLock) {
      _resetInactivityTimer();
    }
    // A save request brings the app forward with a new capture waiting.
    _androidAutofillCapturePulled = false;
  }

  void _maybeShowAutofillOnboardingDialog() {
    // Autofill v1 onboarding is intentionally disabled. Milestone 1 keeps the
    // Flutter shell clean while native Android/Apple/Desktop v2 integrations are
    // rebuilt against the new domain contracts.
  }

  Future<void> _closeCurrentDatabaseAndSelectAnother(
    BuildContext shellContext,
  ) async {
    final confirmed = await _showConfirmation(
      shellContext,
      title: 'Close database',
      body: 'Close this database and return to file selection? Saved credentials for the current database will be removed.',
      confirmLabel: 'Close database',
    );

    if (confirmed != ConfirmDecision.confirm || !mounted) {
      return;
    }

    try {
      final databasePath = context.read<VaultBloc>().state.databasePath;
      await di.sl<VaultSessionCoordinator>().changeDatabase(
        currentDatabasePath: databasePath,
      );

      if (!mounted) {
        return;
      }

      await AppNavigation.pushFadeReplacement(
        context,
        const DatabaseSelectionScreen(),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to close current database.')),
      );
    }
  }

  void _maybePullAndroidAutofillCapture(
    BuildContext context,
    VaultState state,
  ) {
    if (_androidAutofillCapturePulled ||
        state.isLoading ||
        state.rootGroupId == null) {
      return;
    }
    _androidAutofillCapturePulled = true;
    context.read<VaultBloc>().add(const CheckAndroidAutofillCapture());
  }

  void _maybeShowAndroidAutofillSaveDialog(
    BuildContext context,
    VaultState state,
  ) {
    final pending = state.pendingAndroidAutofillSave;
    if (pending == null || _isAndroidAutofillSaveDialogOpen || state.isSaving) {
      return;
    }
    _isAndroidAutofillSaveDialogOpen = true;
    unawaited(_showAndroidAutofillSaveDialog(context, pending));
  }

  /// FR-008: says which of the two things is about to happen before anything
  /// is written, and names the entry when it is an update.
  Future<void> _showAndroidAutofillSaveDialog(
    BuildContext context,
    AndroidAutofillPendingSave pending,
  ) async {
    final bloc = context.read<VaultBloc>();
    final isUpdate = pending.kind == AndroidAutofillSaveKind.update;
    final username = pending.capture.username.trim();
    final target = pending.capture.association ?? 'this app';
    try {
      // Name the username in both cases: which account is being written is the
      // thing the user needs to check before saying yes.
      final account = username.isEmpty ? 'this account' : username;
      final decision = await _router.confirm(
        context: context,
        title: isUpdate ? 'Update this password?' : 'Save to your vault?',
        body: isUpdate
            // "history" is the KDBX record, not a screen in this app: there is
            // no history UI, so promising one sends the user looking for it.
            ? 'The password for $account in "${pending.displayTitle}" will be '
                  'replaced. The previous one is kept in the entry\'s KDBX '
                  'history, readable by any KeePass client.'
            : 'A new entry will be created for $account on $target.',
        cancelLabel: 'Not now',
        confirmLabel: isUpdate ? 'Update' : 'Save',
      );
      if (decision == ConfirmDecision.confirm) {
        bloc.add(const ConfirmAndroidAutofillCapture());
      } else if (decision == ConfirmDecision.cancel) {
        // An explicit no is remembered, so the same submission is not
        // offered again (FR-011).
        bloc.add(const DeclineAndroidAutofillCapture());
      } else {
        bloc.add(const CancelAndroidAutofillCapture());
      }
    } finally {
      _isAndroidAutofillSaveDialogOpen = false;
    }
  }

  void _maybeShowAppleAutofillAssociationDialog(VaultState state) {
    if (state.pendingAppleAutofillAssociations.isEmpty ||
        state.isSaving ||
        state.isLoading) {
      return;
    }

    final pending = state.pendingAppleAutofillAssociations.first;
    if (_activeAppleAutofillAssociationDialogId == pending.id) {
      return;
    }
    if (_activeAppleAutofillAssociationDialogId != null) {
      return;
    }

    _activeAppleAutofillAssociationDialogId = pending.id;
    unawaited(
      _showAppleAutofillAssociationDialog(
        state: state,
        id: pending.id,
        entryId: pending.entryId,
        displayService: pending.displayService,
        serviceIdentifierValue: pending.serviceIdentifierValue,
      ),
    );
  }

  Future<void> _showAppleAutofillAssociationDialog({
    required VaultState state,
    required String id,
    required String entryId,
    required String displayService,
    required String serviceIdentifierValue,
  }) async {
    try {
      final entry = _findVaultEntryById(state, entryId);
      final target = _appleAutofillAssociationTargetLabel(
        displayService: displayService,
        serviceIdentifierValue: serviceIdentifierValue,
      );

      // spec-006 T7/FR-5: Target / Entry / Username rows (screen 7) instead
      // of the generic title/body the `_router.confirm` builds — same
      // `ConfirmationSurface` presentation, same Confirm/Reject decision the
      // pending-association flow already acts on below, unchanged.
      final shouldLink = await _router.open<ConfirmDecision>(
        context: context,
        surface: ConfirmationSurface<ConfirmDecision>(
          builder: (surfaceContext) => _LinkAutofillCredentialDialog(
            target: target,
            entryTitle: entry == null
                ? null
                : (entry.title.isEmpty ? '(Untitled)' : entry.title),
            username: entry == null
                ? null
                : (entry.username.isEmpty ? 'No username' : entry.username),
            onReject: () =>
                VaultOperationScope.of(surfaceContext)
                    .complete(ConfirmDecision.cancel),
            onLink: () =>
                VaultOperationScope.of(surfaceContext)
                    .complete(ConfirmDecision.confirm),
          ),
        ),
      );

      if (!mounted || shouldLink == null) {
        return;
      }

      context.read<VaultBloc>().add(
        shouldLink == ConfirmDecision.confirm
            ? ConfirmAppleAutofillPendingAssociation(id)
            : RejectAppleAutofillPendingAssociation(id),
      );
    } finally {
      if (_activeAppleAutofillAssociationDialogId == id) {
        _activeAppleAutofillAssociationDialogId = null;
      }
    }
  }

  VaultEntry? _findVaultEntryById(VaultState state, String entryId) {
    for (final entry in state.allEntries) {
      if (entry.id == entryId) {
        return entry;
      }
    }
    return null;
  }

  String _appleAutofillAssociationTargetLabel({
    required String displayService,
    required String serviceIdentifierValue,
  }) {
    final display = displayService.trim();
    if (display.isNotEmpty) {
      return display;
    }

    final serviceIdentifier = serviceIdentifierValue.trim();
    if (serviceIdentifier.isNotEmpty) {
      return serviceIdentifier;
    }

    return 'Unknown service';
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return VaultShellSessionScope(
      session: _session,
      child: VaultShellRouterScope(
        router: _router,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppBackgrounds.gradient(context),
                ),
              ),
              BlocListener<VaultBloc, VaultState>(
                listener: (context, state) {
                  _markOtpAuthVaultAvailableIfReady(state);
                  if (state.errorMessage != null &&
                      state.errorMessage!.isNotEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(state.errorMessage!)),
                    );
                    context.read<VaultBloc>().add(const ClearVaultError());
                  }
                  if (state.infoMessage != null &&
                      state.infoMessage!.isNotEmpty) {
                    final isSyncInfo =
                        state.infoMessage!.toLowerCase().contains('sync') ||
                        state.infoMessage!.toLowerCase().contains(
                          'google drive',
                        );
                    if (isSyncInfo) {
                      _showSyncSnackBar(
                        context,
                        state.infoMessage!,
                        status: state.syncStatus,
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(state.infoMessage!)),
                      );
                    }
                    context.read<VaultBloc>().add(const ClearVaultInfo());
                  }
                  if (state.syncError != null && state.syncError!.isNotEmpty) {
                    final needsReconnectAction = state.driveReconnectRequired;
                    _showSyncSnackBar(
                      context,
                      state.syncError!,
                      status: state.syncStatus,
                      action: needsReconnectAction
                          ? SnackBarAction(
                              label: 'Reconnect',
                              onPressed: () {
                                final bloc = context.read<VaultBloc>();
                                unawaited(
                                  di
                                      .sl<GoogleDriveReconnectCoordinator>()
                                      .reconnect(
                                        owner: this,
                                        bloc: bloc,
                                        continuation:
                                            GoogleDriveReconnectContinuation
                                                .resumeSync,
                                        isOwnerActive: () => context.mounted,
                                      ),
                                );
                              },
                            )
                          : null,
                    );
                    context.read<VaultBloc>().add(
                      const ClearVaultSyncFeedback(),
                    );
                  }
                  // spec-008 T507/T608: a conflict found by a background or
                  // auto sync stays a persistent status on the Sync tab. Only a
                  // manual sync (which sets the conflict message) opens the
                  // sheet, and only one sheet at a time.
                  if (state.pendingSyncConflict != null &&
                      state.syncError != null &&
                      !_syncConflictSheetOpen) {
                    _syncConflictSheetOpen = true;
                    unawaited(
                      _showSyncConflictDialog(
                        context,
                        state.pendingSyncConflict!,
                      ).whenComplete(() => _syncConflictSheetOpen = false),
                    );
                  }
                  _maybeShowAppleAutofillAssociationDialog(state);
                  _maybePullAndroidAutofillCapture(context, state);
                  _maybeShowAndroidAutofillSaveDialog(context, state);
                },
                child: BlocSelector<VaultBloc, VaultState, bool>(
                  selector: (state) => state.isLoading,
                  builder: (context, isLoading) {
                    if (isLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    return Stack(
                      children: [
                        Listener(
                          onPointerDown: (_) => _resetInactivityTimer(),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final spec = _VaultLayoutSpec.fromWidth(
                                constraints.maxWidth,
                              );

                              final vaultPane = Padding(
                                padding: EdgeInsets.fromLTRB(
                                  spec.horizontalPadding,
                                  topInset + spec.contentTopPadding,
                                  spec.horizontalPadding,
                                  spec.horizontalPadding,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // spec-019 FR-013 / C-03-12: the database
                                    // status card used to sit here, inside the
                                    // records list, at every width. Its actions
                                    // did not go away — they moved to the header
                                    // below and to the folder column (FR-015).
                                    if (!_effectiveLayout(context)
                                        .hasFolderPane) ...[
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _VaultNameHeader(
                                              titleStyle:
                                                  AppTextStyles.screenTitle,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          KvCircleIconButton(
                                            glyph: AppGlyph.delete,
                                            tooltip: 'Recycle bin',
                                            size: 32,
                                            onPressed: () => unawaited(
                                              _showRecycleBinDialog(context),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          KvCircleIconButton(
                                            glyph: AppGlyph.duplicates,
                                            tooltip: 'Manage duplicates',
                                            size: 32,
                                            onPressed: () => unawaited(
                                              _showDuplicatesDialog(context),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(
                                        height: _VaultUiTokens.panelGap,
                                      ),
                                    ],
                                    // 009 / B005: browser-generated pending
                                    // secret awaiting the app's confirm/save.
                                    const _PendingGenerationBanner(),
                                    // spec 023 T502: the bridge's sign-in
                                    // confirmation. Draws nothing until a
                                    // page asks for a signature.
                                    const _PasskeyApprovalListener(),
                                    Expanded(
                                      child: _VaultEntriesCardSection(
                                        layout: _effectiveLayout(context),
                                        onAddRecord: () =>
                                            _createRecordInCurrentFolder(
                                              context,
                                            ),
                                        selectedEntryId: _selectedEntryId,
                                        onSelectEntry: (entryId) => unawaited(
                                          _selectEntry(context, entryId),
                                        ),
                                        onVisibleEntriesChanged:
                                            _dropSelectionIfNotVisible,
                                      ),
                                    ),
                                  ],
                                ),
                              );

                              return _VaultNavigationLayout(
                                width: constraints.maxWidth,
                                // spec-018 FR-002a: one classification, from
                                // the window width, computed here and passed
                                // down. No descendant re-derives it.
                                layout: _effectiveLayout(context),
                                selectedDestination: _selectedDestination,
                                activePane: _activePane,
                                vaultPane: vaultPane,
                                onSelectDestination: _selectDestination,
                                settingsNeedsAttention:
                                    _inactivityTimeoutSeconds == null,
                                onSecuritySettingsChanged:
                                    _loadInactivityTimeout,
                                onBackFromPane:
                                    _router.requestCancelCurrentPane,
                                onCloseDatabase: () =>
                                    _closeCurrentDatabaseAndSelectAnother(
                                      context,
                                    ),
                                onOpenRecycleBin: () {
                                  unawaited(_showRecycleBinDialog(context));
                                },
                                onOpenDuplicates: () {
                                  unawaited(_showDuplicatesDialog(context));
                                },
                                onChangeDatabase: () =>
                                    _closeCurrentDatabaseAndSelectAnother(
                                      context,
                                    ),
                              );
                            },
                          ),
                        ),
                        BlocSelector<VaultBloc, VaultState, bool>(
                          selector: (state) => state.isSaving,
                          builder: (context, isSaving) {
                            if (!isSaving) {
                              return const SizedBox.shrink();
                            }

                            return const _SavingOverlay();
                          },
                        ),
                        if (_isBackground && !_isLocked) const PrivacyOverlay(),
                        if (_isLocked)
                          _LockOverlay(
                            databasePath: context
                                .read<VaultBloc>()
                                .state
                                .databasePath,
                            databaseLabel: context
                                .read<VaultBloc>()
                                .state
                                .databaseLabel,
                            lockedAt:
                                _lockedAt ?? debugLockOverlayNowOverride(),
                            onUnlocked: _dismissLock,
                            onCloseDatabase: () =>
                                _closeCurrentDatabaseAndSelectAnother(context),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _syncStatusStripBuildWhen(VaultState previous, VaultState current) {
  return previous.databasePath != current.databasePath ||
      previous.isDriveConnected != current.isDriveConnected ||
      previous.isDriveLinked != current.isDriveLinked ||
      previous.linkedRemoteFileName != current.linkedRemoteFileName ||
      previous.syncStatus != current.syncStatus ||
      previous.lastSyncAt != current.lastSyncAt ||
      previous.lastSyncedLocalChecksum != current.lastSyncedLocalChecksum ||
      previous.autoSyncEnabled != current.autoSyncEnabled ||
      previous.isSyncing != current.isSyncing ||
      previous.isOffline != current.isOffline ||
      previous.duplicateGroupCount != current.duplicateGroupCount;
}

bool _entriesCardBuildWhen(VaultState previous, VaultState current) {
  return previous.visibleEntries != current.visibleEntries ||
      previous.folderCounts != current.folderCounts ||
      previous.rootGroupId != current.rootGroupId ||
      previous.groups != current.groups ||
      previous.currentGroupId != current.currentGroupId ||
      previous.folderDescendantIds != current.folderDescendantIds ||
      previous.sortBy != current.sortBy ||
      previous.searchQuery != current.searchQuery;
}

class _VaultEntriesCardSection extends StatelessWidget {
  const _VaultEntriesCardSection({
    required this.layout,
    required this.selectedEntryId,
    required this.onSelectEntry,
    required this.onVisibleEntriesChanged,
    required this.onAddRecord,
  });

  /// spec-018 FR-002a: the shell's single classification, passed down. The
  /// card uses it only to decide whether the sort control and the add
  /// affordance belong to its own header or to the list header above it — the
  /// two must never both render them (FR-014).
  final VaultLayoutClass layout;
  final VoidCallback onAddRecord;

  /// spec-018 FR-003: shell-owned, passed in. The card holds no selection
  /// state of its own.
  final String? selectedEntryId;
  final ValueChanged<String> onSelectEntry;
  final ValueChanged<Set<String>> onVisibleEntriesChanged;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<VaultBloc, VaultState>(
      buildWhen: _entriesCardBuildWhen,
      builder: (context, state) {
        onVisibleEntriesChanged(
          state.visibleEntries.map((entry) => entry.id).toSet(),
        );
        // spec-019 FR-006i/FR-006j: the subtree of the selected folder,
        // minus the folder itself — what is left is exactly the set of
        // records on loan from a subfolder.
        final currentGroupId = state.currentGroupId;
        final subfolderIds = currentGroupId == null
            ? const <String>{}
            : (state.descendantIds(currentGroupId)..remove(currentGroupId));

        return _EntriesCard(
          showSortControl: layout.hasFolderPane,
          onAddRecord: onAddRecord,
          entries: state.visibleEntries,
          groups: state.groups,
          currentGroupId: currentGroupId,
          rootGroupId: state.rootGroupId,
          folderCounts: state.folderCounts,
          // 2026-08-31: without the folder column the list IS the file
          // system — subfolders and records together, tap to descend.
          folderBrowser: !layout.hasFolderPane,
          searchQuery: state.searchQuery,
          sortBy: state.sortBy,
          subfolderIds: subfolderIds,
          selectedEntryId: selectedEntryId,
          onSelectEntry: onSelectEntry,
        );
      },
    );
  }
}

enum VaultDestination { vault, health, sync, settings }

extension on VaultDestination {
  String get label => switch (this) {
    VaultDestination.vault => 'Vault',
    VaultDestination.health => 'Health',
    VaultDestination.sync => 'Sync',
    VaultDestination.settings => 'Settings',
  };

  /// spec-019 FR-017 / DQ-4 — `ICONS.md` is normative and the artboards are
  /// hand-drawn approximations of it. Vault is a `lock`, not a folder: the
  /// destination is the vault, and folders are one thing inside it. Sync is
  /// `refresh-cw`, the act, not `cloud`, the place.
  AppGlyph get glyph => switch (this) {
    VaultDestination.vault => AppGlyph.lock,
    VaultDestination.health => AppGlyph.shieldCheck,
    VaultDestination.sync => AppGlyph.sync,
    VaultDestination.settings => AppGlyph.settings,
  };
}

class _VaultNavigationLayout extends StatelessWidget {
  const _VaultNavigationLayout({
    required this.width,
    required this.selectedDestination,
    required this.activePane,
    required this.vaultPane,
    required this.layout,
    required this.onSelectDestination,
    required this.onBackFromPane,
    required this.onCloseDatabase,
    required this.onOpenRecycleBin,
    required this.onOpenDuplicates,
    required this.onChangeDatabase,
    required this.settingsNeedsAttention,
    required this.onSecuritySettingsChanged,
  });

  /// True while auto-lock is not configured for the open database — the
  /// Settings destination then carries an attention badge.
  final bool settingsNeedsAttention;

  /// Called after the security settings change, so the shell reloads the
  /// auto-lock timeout (and the badge) without reopening the vault.
  final VoidCallback onSecuritySettingsChanged;

  final VoidCallback onOpenRecycleBin;
  final VoidCallback onOpenDuplicates;
  final Future<void> Function() onChangeDatabase;

  final double width;

  /// spec-018 FR-002a: computed once by the shell from the window width and
  /// passed in. Nothing below this widget re-measures to pick a layout.
  final VaultLayoutClass layout;
  final VaultDestination selectedDestination;
  final Widget? activePane;
  final Widget vaultPane;
  final ValueChanged<VaultDestination> onSelectDestination;
  final Future<bool> Function() onBackFromPane;
  final Future<void> Function() onCloseDatabase;

  @override
  Widget build(BuildContext context) {
    if (layout.hasTabBar) {
      return Column(
        children: [
          Expanded(
            child: KeyedSubtree(
              key: const ValueKey('vault-mobile-body'),
              child: activePane == null
                  ? _destinationBody()
                  : _VaultPaneHost(pane: activePane!, onBack: onBackFromPane),
            ),
          ),
          _VaultTabBar(
            selected: selectedDestination,
            onSelected: onSelectDestination,
            settingsNeedsAttention: settingsNeedsAttention,
          ),
        ],
      );
    }

    // spec-018 FR-002b: one rail width. The vault variant's `76` was drift
    // in a single artboard, corrected to the design's stated 72 — see the
    // spec's design-decisions section.
    const railWidth = VaultColumns.rail;
    // Side insets are taken here, outside the fixed-width rail: a phone in
    // landscape puts its display cutout on the left, and a `SafeArea` inside
    // the 72 px box left the icons no room — they were pushed under the body
    // and the rail read as missing (Pixel 11 Pro, 2026-09-05).
    return SafeArea(
      top: false,
      bottom: false,
      child: Row(
        // A destination shorter than the window (Health) would otherwise be
        // vertically centered by the Row's default cross-axis alignment.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('vault-rail'),
            width: railWidth,
            child: _VaultRail(
              selected: selectedDestination,
              onSelected: onSelectDestination,
              settingsNeedsAttention: settingsNeedsAttention,
            ),
          ),
          const _VaultVerticalDivider(),
          Expanded(child: _railBody(context, railWidth)),
        ],
      ),
    );
  }

  Widget _destinationBody() => switch (selectedDestination) {
    VaultDestination.vault => vaultPane,
    // spec-005: Health/Sync/Settings get first-class screens instead of a
    // placeholder button (FR-4/FR-1/FR-8). Padding/topInset match the
    // Vault pane so all four destinations align under the same header.
    VaultDestination.health => const _VaultDestinationScaffold(
      child: _VaultHealthDestination(),
    ),
    VaultDestination.sync => const _VaultDestinationScaffold(
      child: _VaultSyncDestination(),
    ),
    // spec-006 T1: was aliased to `_VaultBackupsDestination` as a spec-005
    // stopgap ("Settings" didn't have its own screen yet). Backups & import
    // is now reached from a row inside the real Settings destination.
    VaultDestination.settings => _VaultDestinationScaffold(
      child: _VaultSettingsDestination(
        onCloseDatabase: onCloseDatabase,
        onSecurityChanged: onSecuritySettingsChanged,
      ),
    ),
  };

  Widget _railBody(BuildContext context, double railWidth) {
    if (selectedDestination != VaultDestination.vault) {
      // A pane surface opened from a non-vault destination (Health category
      // list, entry detail from it) pushes over the destination body, as on
      // mobile — before this the pane opened invisibly and the tap read as
      // dead.
      return KeyedSubtree(
        key: ValueKey('vault-${selectedDestination.name}-root'),
        child: activePane == null
            ? _destinationBody()
            : _VaultPaneHost(
                pane: activePane!,
                onBack: onBackFromPane,
                requiresBack: true,
              ),
      );
    }
    // spec-018 FR-002d: below the derived pane threshold the rail is shown
    // but the detail still pushes, because the design's own columns do not
    // fit. This replaced a bare `708`, which was this same arithmetic done
    // with the pre-correction rail width of 76.
    if (!layout.hasDetailPane) {
      return KeyedSubtree(
        key: const ValueKey('vault-single-pane'),
        child: activePane == null
            ? vaultPane
            : _VaultPaneHost(pane: activePane!, onBack: onBackFromPane),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // The normative widths are minimums, not fixed sizes: on a wide
        // window the surplus is split between the columns (capped) instead
        // of all landing in the detail pane while titles truncate.
        final base =
            (layout.hasFolderPane
                ? VaultColumns.folders + VaultColumns.divider
                : 0) +
            VaultColumns.list +
            VaultColumns.detailMin +
            VaultColumns.divider;
        final extra = (constraints.maxWidth - base).clamp(0.0, double.infinity);
        final folderWidth = (VaultColumns.folders + extra * 0.15).clamp(
          VaultColumns.folders,
          VaultColumns.foldersMax,
        );
        final listWidth = (VaultColumns.list + extra * 0.30).clamp(
          VaultColumns.list,
          VaultColumns.listMax,
        );
        return Row(
          children: [
            if (layout.hasFolderPane) ...[
              SizedBox(
                key: const ValueKey('vault-folder-pane'),
                width: folderWidth,
                child: const _VaultFolderColumn(),
              ),
              const _VaultVerticalDivider(),
            ],
            SizedBox(
              key: const ValueKey('vault-list-pane'),
              width: listWidth,
              child: vaultPane,
            ),
            const _VaultVerticalDivider(),
            // FR-002c: the detail pane is persistent — always present, showing
            // the empty state when nothing is selected, never a pane that only
            // materialises once a surface opens.
            Expanded(
              key: const ValueKey('vault-detail-pane'),
              child: activePane == null
                  ? const _EntryDetailEmptyState()
                  : _VaultPaneHost(pane: activePane!, onBack: onBackFromPane),
            ),
          ],
        );
      },
    );
  }
}

class _VaultVerticalDivider extends StatelessWidget {
  const _VaultVerticalDivider();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 1,
    child: ColoredBox(
      color: Theme.of(context).extension<CustodeColors>()!.divider,
    ),
  );
}

class _VaultTabBar extends StatelessWidget {
  const _VaultTabBar({
    required this.selected,
    required this.onSelected,
    this.settingsNeedsAttention = false,
  });

  final VaultDestination selected;
  final ValueChanged<VaultDestination> onSelected;

  /// Auto-lock unset: the Settings tab carries an attention dot.
  final bool settingsNeedsAttention;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return ColoredBox(
      key: const ValueKey('vault-tab-bar'),
      color: colors.surface,
      child: SizedBox(
        height: 82,
        child: Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 22),
          child: Row(
            children: [
              for (final destination in VaultDestination.values)
                Expanded(
                  child: Semantics(
                    selected: destination == selected,
                    button: true,
                    label: destination.label,
                    child: InkWell(
                      onTap: () => onSelected(destination),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // FR-018: same treatment as the rail — one selected
                          // recipe for the chrome, whichever shape it takes.
                          _AttentionBadge(
                            visible:
                                settingsNeedsAttention &&
                                destination == VaultDestination.settings,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: destination == selected
                                    ? AppColors.accent200
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(
                                  AppRadii.iconSquare,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 2,
                                ),
                                child: KvIcon(
                                  glyph: destination.glyph,
                                  size: 23,
                                  color: destination == selected
                                      ? AppColors.accent800
                                      : colors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            destination.label,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: destination == selected
                                  ? AppColors.accent800
                                  : colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small attention dot pinned to the top-right of [child] — the badge the
/// Settings destination carries while auto-lock is unset.
class _AttentionBadge extends StatelessWidget {
  const _AttentionBadge({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!visible) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -1,
          right: -1,
          // The dot is decorative here — the Settings screen's disclaimer
          // carries the message for assistive tech; naming the dot would
          // merge into the destination's own label and rename it.
          child: ExcludeSemantics(
            child: Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: AppColors.accent500,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _VaultRail extends StatelessWidget {
  const _VaultRail({
    required this.selected,
    required this.onSelected,
    this.settingsNeedsAttention = false,
  });

  final VaultDestination selected;
  final ValueChanged<VaultDestination> onSelected;

  /// Auto-lock unset: the Settings tile carries an attention dot.
  final bool settingsNeedsAttention;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    Widget button(VaultDestination destination) {
      final isSelected = destination == selected;
      final showsBadge =
          settingsNeedsAttention && destination == VaultDestination.settings;
      return Semantics(
        selected: isSelected,
        button: true,
        label: destination.label,
        child: SizedBox.square(
          dimension: 36,
          child: _AttentionBadge(
            visible: showsBadge,
            child: DecoratedBox(
              // spec-019 FR-018 / C-03-14: the selected destination is a filled
              // tile, not a recoloured glyph. The `Semantics(selected:)` above
              // stays exactly as it was — the fill is in addition to it, never
              // instead of it (Constitution V).
              decoration: BoxDecoration(
                color: isSelected ? AppColors.accent200 : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.iconSquare),
              ),
              child: IconButton(
                tooltip: destination.label,
                padding: EdgeInsets.zero,
                onPressed: () => onSelected(destination),
                icon: KvIcon(
                  glyph: destination.glyph,
                  size: 22,
                  color: isSelected
                      ? AppColors.accent800
                      : colors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return ColoredBox(
      color: colors.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              // The mark carries its own colour; a filled tile behind it
              // fought the ring (orange on orange), so the rail shows the
              // mark alone at the size the tile used to occupy.
              const SizedBox(
                width: 38,
                height: 38,
                child: Center(child: _VaultAppMark(size: 30)),
              ),
              const SizedBox(height: 20),
              button(VaultDestination.vault),
              const SizedBox(height: 14),
              button(VaultDestination.health),
              const SizedBox(height: 14),
              button(VaultDestination.sync),
              const Spacer(),
              button(VaultDestination.settings),
            ],
          ),
        ),
      ),
    );
  }
}

/// Marks the subtree as living inside [_VaultPaneHost] and hands it the
/// host's back action.
///
/// 2026-08-31: the host no longer draws its own back row above the pane —
/// that stacked a second header over panes that already carry their own
/// affordance (the detail's header, the editor's Cancel, every dialog-shaped
/// pane's actions). The pane that wants a back button draws it inline and
/// calls [onBackOf]. Asking "am I in a pane?" structurally remains the fix
/// for deriving it from the window width: the presentation is chosen when
/// the surface opens, so a resize made the width answer disagree with the
/// tree that was actually mounted — and both back buttons appeared at once.
class _VaultPaneScope extends InheritedWidget {
  const _VaultPaneScope({
    required this.onBack,
    this.requiresBack = false,
    required super.child,
  });

  final Future<bool> Function() onBack;

  /// True when the pane is pushed over a body with no list beside it (a
  /// non-vault destination) — the pane content must then draw its own back
  /// even at widths where the vault's detail column would not.
  final bool requiresBack;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_VaultPaneScope>() != null;

  static Future<bool> Function()? onBackOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_VaultPaneScope>()?.onBack;

  static bool requiresBackOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_VaultPaneScope>()
          ?.requiresBack ??
      false;

  @override
  bool updateShouldNotify(_VaultPaneScope oldWidget) =>
      requiresBack != oldWidget.requiresBack;
}

class _VaultPaneHost extends StatelessWidget {
  const _VaultPaneHost({
    required this.pane,
    required this.onBack,
    this.requiresBack = false,
  });

  final Widget pane;
  final Future<bool> Function() onBack;
  final bool requiresBack;

  @override
  Widget build(BuildContext context) {
    // SizedBox.expand: the pane row centers non-stretched children, and a
    // scroll-view pane shrink-wraps — without tight constraints the detail
    // floated vertically centered instead of starting at the top.
    return SizedBox.expand(
      child: _VaultPaneScope(
        onBack: onBack,
        requiresBack: requiresBack,
        child: pane,
      ),
    );
  }
}

/// spec-005: thin wrapper giving the Health/Sync/Settings destination
/// screens the same top inset as the Vault pane (status bar clearance);
/// each screen manages its own horizontal padding/scrolling.
class _VaultDestinationScaffold extends StatelessWidget {
  const _VaultDestinationScaffold({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.only(top: topInset > 0 ? topInset : 8),
      child: child,
    );
  }
}

/// spec-019 T035 / FR-014, amended 2026-08-31 — the vault's screen header,
/// wherever there is no folder column to carry the database's name.
///
/// The database's own name is the title (the word `Vault` told the user
/// nothing), the count is the subtitle, and the only actions are sort and
/// add, drawn with the app's circle buttons. The sync and overflow controls
/// left this header — hygiene and database actions live in their own
/// destinations.
/// One line under the vault's name, everywhere the name appears: when the
/// database is linked to Drive it says how fresh the copy is, otherwise it
/// says plainly that this is a local, unsynced file.
String _vaultSyncStatusLabel(VaultState state) {
  if (!state.isDriveLinked) {
    return 'Local vault, not synced';
  }
  final lastSyncAt = state.lastSyncAt;
  if (lastSyncAt == null) {
    return 'Not synced yet';
  }
  final diff = DateTime.now().difference(lastSyncAt);
  if (diff.inMinutes < 1) {
    return 'Last sync just now';
  }
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return 'Last sync $m minute${m == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return 'Last sync $h hour${h == 1 ? '' : 's'} ago';
  }
  final d = diff.inDays;
  return 'Last sync $d day${d == 1 ? '' : 's'} ago';
}

/// spec-019 T035 / FR-014, amended 2026-08-31 — ONE widget for the vault's
/// name wherever it appears: the database file name as the title and the
/// sync status (last sync, sync errors) as the subtitle. The 3-column folder
/// column and the 1/2-column list header both render this; the item count
/// lives in the list card's own count line at every width.
class _VaultNameHeader extends StatelessWidget {
  const _VaultNameHeader({required this.titleStyle});

  final TextStyle titleStyle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return BlocBuilder<VaultBloc, VaultState>(
      buildWhen: (previous, current) =>
          previous.databasePath != current.databasePath ||
          previous.isDriveLinked != current.isDriveLinked ||
          previous.lastSyncAt != current.lastSyncAt ||
          previous.syncStatus != current.syncStatus ||
          previous.syncError != current.syncError ||
          previous.isSyncing != current.isSyncing,
      builder: (context, state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              state.databaseLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 2),
            Text(
              _vaultSyncStatusLabel(state),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.meta.copyWith(color: colors.textSecondary),
            ),
          ],
        );
      },
    );
  }
}

/// spec-019 T051 / FR-016 — the Custode mark, as artwork.
///
/// The rail used to show `AppGlyph.key`, a Lucide glyph standing in for the
/// app's own mark (C-SH-03). The mark is a real asset and this renders it,
/// tinted to the tile's foreground so it works on both themes.
class _VaultAppMark extends StatelessWidget {
  const _VaultAppMark({required this.size});

  /// The full-colour mark (verbatim copy of the design master
  /// `specs/_design/custode-mark-foreground.svg`), rendered untinted so the
  /// rail shows the app's actual identity, not a silhouette.
  static const String assetPath = 'assets/logo/custode-mark-color.svg';

  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      semanticsLabel: 'Custode',
    );
  }
}
