part of '../vault_screen.dart';

/// Passkeys-all-platforms T014 / FR-8, FR-9 — the questions adoption cannot
/// answer alone: a passkey for an account that already has one, and a passkey
/// created for another vault.
///
/// Invisible until the bloc holds a question. It mounts once in the vault
/// shell, for every destination, so it exists only while a vault is open. It
/// sends the user's answer to the bloc and nothing else: sequencing, backup
/// and deletion live in the coordinator. Closing a dialog without answering
/// defers the record; it stays in the queue (FR-9).
///
/// The dialogs are root-navigator routes, so they render above the shell's
/// lock overlay. While the shell session is locked nothing is asked, an open
/// dialog closes, and no answer is sent: the inactivity lock keeps the
/// session secret, so an answer given over the overlay would still write.
/// The question stays in state and is asked again after the unlock.
class _PasskeyAdoptionListener extends StatefulWidget {
  const _PasskeyAdoptionListener();

  @override
  State<_PasskeyAdoptionListener> createState() =>
      _PasskeyAdoptionListenerState();
}

class _PasskeyAdoptionListenerState extends State<_PasskeyAdoptionListener> {
  bool _isAsking = false;
  // Captured in initState (a read, not a dependency): the shell owns one
  // session for its whole life. Null only where there is no shell.
  VaultShellSession? _session;

  bool get _isLocked => _session?.isLocked ?? false;

  @override
  void initState() {
    super.initState();
    _session = VaultShellSessionScope.maybeOf(context);
    _session?.locked.addListener(_onLockChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _askNext());
  }

  @override
  void dispose() {
    _session?.locked.removeListener(_onLockChanged);
    super.dispose();
  }

  /// Closing on lock is the dialogs' own job (`closeWhen`); this brings the
  /// unanswered question back once the vault is unlocked again.
  void _onLockChanged() {
    if (!_isLocked) _askNext();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<VaultBloc, VaultState>(
      listenWhen: (previous, current) =>
          previous.passkeyClashes != current.passkeyClashes ||
          previous.passkeyOtherVault != current.passkeyOtherVault,
      listener: (_, _) => _askNext(),
      child: const SizedBox.shrink(),
    );
  }

  void _askNext() {
    if (_isAsking || !mounted || _isLocked) return;
    final state = context.read<VaultBloc>().state;
    if (state.passkeyClashes.isNotEmpty) {
      unawaited(_askClash(state, state.passkeyClashes.first));
    } else if (state.passkeyOtherVault.isNotEmpty) {
      unawaited(_askOtherVault(state.passkeyOtherVault.first));
    }
  }

  static String _account(PendingPasskeyRef ref) {
    final user = ref.username.trim();
    return user.isEmpty ? 'the account with no username' : '“$user”';
  }

  Future<void> _askClash(VaultState state, PasskeyClashRequest clash) async {
    _isAsking = true;
    final bloc = context.read<VaultBloc>();
    try {
      final candidates = [
        for (final id in clash.candidateEntryIds)
          for (final entry in state.allEntries)
            if (entry.id == id) entry,
      ];
      final answer = await showDialog<_ClashAnswer>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => KvClosableDialog(
          closeWhen: _session?.locked,
          child: AlertDialog(
            semanticLabel: 'Passkey waiting for ${clash.rpId}: replace or keep',
            title: Text('Replace the passkey for ${clash.rpId}?'),
            content: Text(
              'A new passkey for ${_account(clash)} on ${clash.rpId} is '
              'waiting, but this vault already holds a passkey for that '
              'account.\n\n'
              'Keep both saves the new passkey on a new record and leaves the '
              'old one as it is. Replace removes the old passkey, and it cannot '
              'be recovered: remove it at ${clash.rpId} as well.\n\n'
              'A dated backup of the vault is saved first either way.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Decide later'),
              ),
              for (final entry in candidates)
                TextButton(
                  onPressed: () => Navigator.of(
                    dialogContext,
                  ).pop(_ClashAnswer(PasskeyClashDecision.replace, entry.id)),
                  child: Text(
                    candidates.length == 1
                        ? 'Replace old passkey'
                        : 'Replace the one on “${entry.title}”',
                  ),
                ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext)
                        .pop(const _ClashAnswer(PasskeyClashDecision.keepBoth)),
                child: const Text('Keep both'),
              ),
            ],
          ),
        ),
      );
      // Locked while the dialog was up: no answer counts, not even "later".
      if (!mounted || _isLocked) return;
      bloc.add(
        answer == null
            ? DeferPasskeyAdoptionPrompt(clash.recordId)
            : ResolvePasskeyClash(
                recordId: clash.recordId,
                decision: answer.decision,
                replaceEntryId: answer.entryId,
              ),
      );
    } finally {
      _isAsking = false;
    }
  }

  Future<void> _askOtherVault(PendingPasskeyOtherVault other) async {
    _isAsking = true;
    final bloc = context.read<VaultBloc>();
    try {
      final choice = await showDialog<_OtherVaultChoice>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => KvClosableDialog(
          closeWhen: _session?.locked,
          child: AlertDialog(
            semanticLabel: 'Passkey for ${other.rpId} belongs to another vault',
            title: Text(
              other.vaultName == null
                  ? 'A passkey for ${other.rpId} belongs to another vault'
                  : 'A passkey for ${other.rpId} belongs to the vault '
                        '“${other.vaultName}”',
            ),
            content: Text(
              'The passkey for ${_account(other)} on ${other.rpId} was created '
              '${other.vaultName == null ? 'for a different vault than this one' : 'for the vault “${other.vaultName}”, not this one'}, '
              'so it was not added here.\n\n'
              'Move it to this vault, or discard it. Until then it stays '
              'waiting on this device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Decide later'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_OtherVaultChoice.discard),
                child: const Text('Discard'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_OtherVaultChoice.move),
                child: const Text('Move to this vault'),
              ),
            ],
          ),
        ),
      );
      if (!mounted || _isLocked) return;
      if (choice == null) {
        bloc.add(DeferPasskeyAdoptionPrompt(other.recordId));
        return;
      }
      final isMove = choice == _OtherVaultChoice.move;
      final confirmed = await showKvConfirmDialog(
        context,
        title: isMove
            ? 'Move this passkey to this vault?'
            : 'Discard this passkey?',
        body: isMove
            ? 'The passkey for ${_account(other)} on ${other.rpId} will be '
                  'saved in this vault. A dated backup of the vault is saved '
                  'first.'
            : 'This is permanent. The passkey for ${_account(other)} on '
                  '${other.rpId} is deleted from this device and will stop '
                  'working. You would have to create a new one at '
                  '${other.rpId}.',
        confirmLabel: isMove ? 'Move to this vault' : 'Discard passkey',
        closeWhen: _session?.locked,
      );
      if (!mounted || _isLocked) return;
      if (confirmed != true) {
        bloc.add(DeferPasskeyAdoptionPrompt(other.recordId));
        return;
      }
      bloc.add(
        isMove
            ? MovePendingPasskeyToThisVault(other.recordId)
            : DiscardPendingPasskey(other.recordId),
      );
    } finally {
      _isAsking = false;
    }
  }
}

enum _OtherVaultChoice { move, discard }

class _ClashAnswer {
  const _ClashAnswer(this.decision, [this.entryId]);

  final PasskeyClashDecision decision;
  final String? entryId;
}
