part of '../vault_screen.dart';

/// spec 023 T502 / FR-015 — the in-app confirmation for a passkey sign-in a
/// desktop browser asked for.
///
/// Invisible until the bridge has a question. It mounts inside the vault
/// shell, so it exists exactly while a vault is open and unlocked: the
/// window where a signature is possible at all.
///
/// The prompt names the site the page is on, the record and the account, and
/// nothing else. A signature is not a secret the user reads, so there is
/// nothing here to reveal or copy.
class _PasskeyApprovalListener extends StatefulWidget {
  const _PasskeyApprovalListener();

  @override
  State<_PasskeyApprovalListener> createState() =>
      _PasskeyApprovalListenerState();
}

class _PasskeyApprovalListenerState extends State<_PasskeyApprovalListener> {
  // Captured in initState, never resolved from the locator in dispose: a
  // teardown must not require the registration to still be there (the golden
  // ordering rule in AGENTS.md).
  //
  // Nullable because the service is desktop-only and the shell is not: a
  // host that never registered it — a widget test, a mobile build — mounts
  // this widget and it simply does nothing. Resolving unconditionally would
  // make every vault-shell test depend on a desktop bridge.
  DesktopPasskeyApprovalService? _approvals;
  bool _isAsking = false;

  @override
  void initState() {
    super.initState();
    if (di.sl.isRegistered<DesktopPasskeyApprovalService>()) {
      final approvals = di.sl<DesktopPasskeyApprovalService>();
      _approvals = approvals;
      approvals.pendingListenable.addListener(_onPendingChanged);
      approvals.pendingCreationListenable.addListener(_onPendingCreation);
      approvals.writtenListenable.addListener(_onPasskeyWritten);
    }
  }

  @override
  void dispose() {
    final approvals = _approvals;
    if (approvals != null) {
      approvals.pendingListenable.removeListener(_onPendingChanged);
      approvals.pendingCreationListenable.removeListener(_onPendingCreation);
      approvals.writtenListenable.removeListener(_onPasskeyWritten);
      // The shell is going away — a lock, a database switch, a close.
      // Whatever was waiting on this window gets its no rather than a
      // signature nobody is left to approve.
      approvals.declineAll();
    }
    super.dispose();
  }

  void _onPendingChanged() {
    final prompt = _approvals?.pendingListenable.value;
    if (prompt == null || _isAsking || !mounted) return;
    unawaited(_ask(prompt));
  }

  /// True once [prompt] is no longer the question the service is waiting on —
  /// it expired, the vault locked, or the bridge was torn down.
  ///
  /// Drives the dialog's own dismissal. Without it the user reads a
  /// confirmation whose request has already been answered no, presses the
  /// positive action, and nothing happens. The service refuses to apply a late
  /// answer to anything, so this is about not leaving a dead question on
  /// screen, not about safety.
  ValueNotifier<bool> _staleWhenNotPending<T>(
    ValueListenable<T?> pending,
    T prompt,
  ) {
    final stale = ValueNotifier<bool>(false);
    void check() {
      if (!identical(pending.value, prompt)) stale.value = true;
    }

    pending.addListener(check);
    _detachStale = () => pending.removeListener(check);
    return stale;
  }

  VoidCallback? _detachStale;

  Future<void> _ask(PasskeyAssertionPrompt prompt) async {
    _isAsking = true;
    final stale = _staleWhenNotPending(_approvals!.pendingListenable, prompt);
    try {
      final account = prompt.username.trim().isEmpty
          ? 'the account with no username'
          : '“${prompt.username.trim()}”';
      final record = prompt.entryTitle.trim().isEmpty
          ? 'a record in this vault'
          : '“${prompt.entryTitle.trim()}”';
      final approved = await showKvConfirmDialog(
        context,
        title: 'Sign in to ${prompt.relyingPartyId}?',
        body:
            '${prompt.origin} is asking to sign in with the passkey on '
            '$record, for $account.\n\n'
            'Approving signs one challenge from that page. It does not give '
            'the page your passkey, your password or anything else from this '
            'vault.',
        confirmLabel: 'Sign in',
        closeWhen: stale,
      );
      _approvals?.resolve(approved: approved == true);
    } finally {
      _detachStale?.call();
      _detachStale = null;
      stale.dispose();
      _isAsking = false;
    }
  }

  /// A browser just had a passkey written into the open vault.
  ///
  /// The vault on disk is ahead of everything in memory: this record shows no
  /// passkey, and the reveal bridge's own credential map and advertised
  /// capabilities still describe the vault as it was before, so a sign-in
  /// straight after registering would find nothing and fall back to the
  /// browser. Reloading rebuilds the screen and republishes the bridge, which
  /// is where both come from.
  void _onPasskeyWritten() {
    if (!mounted) return;
    context.read<VaultBloc>().add(const RefreshVault());
  }

  void _onPendingCreation() {
    final prompt = _approvals?.pendingCreationListenable.value;
    if (prompt == null || _isAsking || !mounted) return;
    unawaited(_askCreation(prompt));
  }

  /// spec 023 US3 / FR-018–FR-019 — where should the new passkey go, and may
  /// an existing one be replaced?
  ///
  /// Two decisions, so two steps rather than one crowded sheet: first the
  /// record, then — only when it already holds a passkey for this site — the
  /// replacement. A user who declines the second has declined the whole thing;
  /// nothing is written either way until the coordinator runs.
  Future<void> _askCreation(PasskeyCreationPrompt prompt) async {
    _isAsking = true;
    final stale = _staleWhenNotPending(
      _approvals!.pendingCreationListenable,
      prompt,
    );
    try {
      final target = await _chooseCreationTarget(prompt, stale: stale);
      if (target == null || !mounted) {
        _approvals?.resolveCreation(null);
        return;
      }

      if (target.holdsPasskeyForThisSite) {
        final replace = await showKvConfirmDialog(
          context,
          title: 'Replace the passkey on “${target.title}”?',
          body:
              '“${target.title}” already holds a passkey for '
              '${prompt.relyingPartyId}. Creating this one replaces it, and '
              'the old passkey cannot be recovered — you would have to remove '
              'it at ${prompt.relyingPartyId} as well.\n\n'
              'A dated copy of the vault is saved on this device first.',
          confirmLabel: 'Replace passkey',
          closeWhen: stale,
        );
        if (replace != true) {
          _approvals?.resolveCreation(null);
          return;
        }
      }

      _approvals?.resolveCreation(
        PasskeyCreationDecision(
          entryId: target.entryId,
          replaceExisting: target.holdsPasskeyForThisSite,
        ),
      );
    } finally {
      _detachStale?.call();
      _detachStale = null;
      stale.dispose();
      _isAsking = false;
    }
  }

  /// The record the passkey lands on.
  ///
  /// There is deliberately no "create a new record" option: this flow can only
  /// add a passkey to an entry that already exists, because a brand-new record
  /// needs a title, a folder and the user's attention, and asking for those
  /// while a site waits on `navigator.credentials.create` is how a
  /// half-considered record gets made. With no candidate the request is
  /// declined and the page falls back to the browser, and the copy says why.
  Future<PasskeyCreationCandidate?> _chooseCreationTarget(
    PasskeyCreationPrompt prompt, {
    required ValueListenable<bool> stale,
  }) async {
    final candidates = prompt.candidateEntries;
    if (candidates.isEmpty) {
      await showKvConfirmDialog(
        context,
        title: 'No record for ${prompt.relyingPartyId}',
        body:
            '${prompt.origin} asked to create a passkey, but this vault has no '
            'record for that site yet. Add one with its website set to '
            '${prompt.relyingPartyId}, then try again.',
        confirmLabel: 'OK',
        cancelLabel: null,
        closeWhen: stale,
      );
      return null;
    }
    if (candidates.length == 1) {
      final only = candidates.single;
      final confirmed = await showKvConfirmDialog(
        context,
        title: 'Create a passkey for ${prompt.relyingPartyId}?',
        body:
            '${prompt.origin} is asking to create a passkey. It will be saved '
            'on “${only.title}”'
            '${only.username.isEmpty ? '' : ' (${only.username})'}, in this '
            'vault, protected by your master password — not by hardware key '
            'isolation.',
        confirmLabel: 'Create passkey',
        closeWhen: stale,
      );
      return confirmed == true ? only : null;
    }
    return _showCreationTargetSheet(context, prompt);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// spec 023 US3 — which of several matching records the new passkey goes on.
///
/// A chooser with a list, so a bottom sheet on a phone and a dialog elsewhere,
/// which is this app's rule for exactly this shape (`KvBottomSheet`). Each row
/// says whether it already holds a passkey for the site, because that is the
/// choice that leads to a replacement.
Future<PasskeyCreationCandidate?> _showCreationTargetSheet(
  BuildContext context,
  PasskeyCreationPrompt prompt,
) {
  return KvBottomSheet.show<PasskeyCreationCandidate>(
    context: context,
    builder: (sheetContext) {
      final colors = Theme.of(sheetContext).extension<CustodeColors>()!;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Create a passkey for ${prompt.relyingPartyId}?',
            style: AppTextStyles.screenTitle.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            '${prompt.origin} is asking to create a passkey. Choose the record '
            'it should be saved on.',
            style: AppTextStyles.secondary.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          for (final candidate in prompt.candidateEntries) ...[
            KvListRow(
              title: candidate.title.isEmpty ? '(Untitled)' : candidate.title,
              subtitle: [
                if (candidate.username.isNotEmpty) candidate.username,
                if (candidate.holdsPasskeyForThisSite)
                  'already has a passkey for this site',
              ].join(' · '),
              onTap: () => Navigator.of(sheetContext).pop(candidate),
            ),
            const SizedBox(height: AppSpacing.s1),
          ],
          const SizedBox(height: AppSpacing.s1),
          Text(
            _kPasskeySecurityNote,
            style: AppTextStyles.meta.copyWith(color: colors.textSecondary),
          ),
        ],
      );
    },
  );
}
