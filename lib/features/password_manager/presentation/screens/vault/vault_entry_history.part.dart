part of '../vault_screen.dart';

/// spec 017 T202/T203 — an entry's previous versions.
///
/// Opened from the record the user is already looking at (spec 017
/// "Assumptions"), read-only, and never loaded until asked for (FR-015/D6).
/// A plain `showDialog`, like `_showRecordInfoDialog`: this is the same kind
/// of read-only look at one record, and it owns no vault operation the shell
/// router would have to cancel.
///
/// The dialog is a route, so it renders above `_LockOverlay`, which is a
/// widget in the shell's body — and outside the shell's pointer `Listener`,
/// so taps in it never reached the inactivity timer. Both are bridged here
/// from `VaultShellSessionScope`: the history is under exactly the session
/// rules of the current password, with no second lock (FR-003).
Future<void> _showEntryHistoryDialog(BuildContext context, String entryId) {
  // Both captured before the dialog's own context exists: the dialog is
  // hosted by the root navigator, below neither the `BlocProvider.value`
  // that hosts the detail nor the shell's session scope.
  //
  // Resolved through the scope, never `findAncestorStateOfType`: under
  // `VaultLayoutWidths.detailPane` the detail is itself a route pushed on the
  // shared Navigator, i.e. a *sibling* of the shell's content, so the shell
  // is not an ancestor of this context at all and the search answered null
  // — on every phone.
  final bloc = context.read<VaultBloc>();
  final session = VaultShellSessionScope.of(context);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Listener(
      onPointerDown: (_) => session.reportActivity(),
      child: VaultShellSessionScope(
        session: session,
        child: BlocProvider<VaultBloc>.value(
          value: bloc,
          child: _EntryHistoryDialog(entryId: entryId, locked: session.locked),
        ),
      ),
    ),
  );
}

class _EntryHistoryDialog extends StatefulWidget {
  const _EntryHistoryDialog({required this.entryId, required this.locked});

  final String entryId;

  /// The shell's lock state. When it turns true this dialog closes itself:
  /// the overlay that hides the vault behind it cannot cover a route.
  final ValueListenable<bool> locked;

  @override
  State<_EntryHistoryDialog> createState() => _EntryHistoryDialogState();
}

class _EntryHistoryDialogState extends State<_EntryHistoryDialog> {
  /// The same 1 s ticker the entry detail runs, for the same reason: the
  /// reveal's auto-hide is counted in ticks, not by a timer of its own
  /// (see `RevealController`).
  Timer? _ticker;
  late final RevealController _revealController;

  /// The bloc, captured here rather than resolved in `dispose` — teardown
  /// must not require a locator or an ancestor to still be there.
  late final VaultBloc _bloc;

  /// Which revision the reveal belongs to, as its position in the list.
  /// Not `replacedAt`: KDBX timestamps are second-precision, so two edits in
  /// the same second share one, and keying the reveal by it unmasked every
  /// revision of that second at once.
  int? _revealedIndex;
  bool _isCheckingBiometrics = false;

  /// This dialog's own route and its navigator, captured while the context is
  /// live — neither teardown nor the lock path may have to look them up.
  ModalRoute<Object?>? _route;
  NavigatorState? _navigator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _navigator = Navigator.maybeOf(context);
  }

  @override
  void initState() {
    super.initState();
    _bloc = context.read<VaultBloc>();
    widget.locked.addListener(_onLockChanged);
    _revealController = RevealController()..addListener(_onRevealChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _revealController.tick();
    });
    _bloc.add(LoadEntryHistory(widget.entryId));
  }

  @override
  void dispose() {
    widget.locked.removeListener(_onLockChanged);
    _ticker?.cancel();
    _revealController.removeListener(_onRevealChanged);
    _revealController.dispose();
    // D6: the revisions do not outlive the surface that showed them.
    if (!_bloc.isClosed) {
      _bloc.add(const ClearEntryHistory());
    }
    super.dispose();
  }

  void _onRevealChanged() {
    if (mounted) setState(() {});
  }

  /// The vault locked while this route was on top of the overlay: the
  /// revisions go with it, revealed or not.
  ///
  /// Aimed at *this* route rather than `pop()`, which removes whatever is on
  /// top: with biometric protection on, the reveal gate sheet sits above this
  /// dialog, so the pop ate the sheet and left the history live over a locked
  /// vault — and the notifier, already true, never fired again.
  void _onLockChanged() {
    if (!widget.locked.value || !mounted) return;
    _revealController.hide();
    final route = _route;
    final navigator = _navigator;
    if (route == null || navigator == null || !route.isActive) return;
    navigator.popUntil((candidate) => candidate == route);
    navigator.pop();
  }

  bool _isRevealed(int index) =>
      _revealController.isRevealed && _revealedIndex == index;

  /// FR-005: the same guard, toast and clearing as the current password.
  Future<void> _copyPassword(String password) async {
    if (password.isEmpty) return;
    await di.sl<ClipboardGuard>().copy(password);
    if (!mounted) return;
    _showCenteredCopyToast(context, 'Copied password.');
  }

  /// FR-008: confirmed first, naming what is replaced; FR-006a: says when
  /// the attachments stay as they are. Then one event — the bloc reloads and
  /// tells the user.
  Future<void> _restore(
    VaultEntryRevision revision,
    VaultEntry currentEntry,
  ) async {
    // Names only, as the diff computes them (VaultEntryField.attachments).
    final attachmentsDiffer = changedFieldsForRevision(
      revision: revision,
      currentEntry: currentEntry,
    ).contains(VaultEntryField.attachments);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore this version?'),
        insetPadding: _dialogInsetPadding(dialogContext),
        contentPadding: _dialogContentPadding(dialogContext),
        content: Text(
          'The title, username, password, website, notes and custom fields '
          'of “${currentEntry.title}” will be replaced with the version '
          'saved ${_formatEntryDateTime(revision.replacedAt)}. The version '
          'you have now is kept in the history.'
          '${attachmentsDiffer ? '\n\nAttachments are not restored: the '
                    'record keeps the attachments it has now.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _revealController.hide();
    _bloc.add(
      RestoreEntryRevision(
        entryId: widget.entryId,
        replacedAt: revision.replacedAt,
        ordinal: revision.ordinal,
      ),
    );
  }

  /// FR-009: confirmed, no backup — the confirmation is the safeguard.
  Future<void> _delete(VaultEntryRevision revision) async {
    final confirmed = await _confirmDestructive(
      title: 'Delete this version?',
      body:
          'The version saved ${_formatEntryDateTime(revision.replacedAt)} '
          'will be removed from this record’s history. The other versions '
          'and the record itself are not changed. This cannot be undone.',
      confirmLabel: 'Delete version',
    );
    if (!confirmed || !mounted) return;
    _revealController.hide();
    _bloc.add(
      DeleteEntryRevision(
        entryId: widget.entryId,
        replacedAt: revision.replacedAt,
        ordinal: revision.ordinal,
      ),
    );
  }

  /// FR-010: names what is destroyed and says a backup will be written.
  Future<void> _clearAll(int count, VaultEntry currentEntry) async {
    final confirmed = await _confirmDestructive(
      title: 'Clear this record’s history?',
      body:
          'All $count previous ${count == 1 ? 'version' : 'versions'} of '
          '“${currentEntry.title}” — every earlier password, username, '
          'website, notes and custom field — will be removed from the vault. '
          'The record as it stands now is not changed.\n\n'
          'A dated backup of the vault file is written before anything is '
          'removed, next to the vault.',
      confirmLabel: 'Clear history',
    );
    if (!confirmed || !mounted) return;
    _revealController.hide();
    _bloc.add(ClearEntryHistoryInFile(widget.entryId));
  }

  /// SC-005 / Constitution V: every path that destroys history warns first,
  /// and the warning is carried by a glyph and its label, not by colour.
  Future<bool> _confirmDestructive({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).extension<CustodeColors>()!;
        return AlertDialog(
          title: Row(
            children: [
              KvIcon(
                glyph: AppGlyph.warning,
                size: 22,
                color: colors.attentionText,
                semanticLabel: 'Warning',
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(child: Text(title)),
            ],
          ),
          insetPadding: _dialogInsetPadding(dialogContext),
          contentPadding: _dialogContentPadding(dialogContext),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.attentionText,
                foregroundColor: colors.surface,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _toggleReveal(int index, String databasePath) async {
    if (_isRevealed(index)) {
      _revealController.hide();
      return;
    }
    if (_isCheckingBiometrics) return;
    setState(() => _isCheckingBiometrics = true);
    // The same gate as the current password — no second authentication
    // concept (FR-003/D3).
    final allowed = await _resolveRevealPermission(context, databasePath);
    if (!mounted) return;
    setState(() => _isCheckingBiometrics = false);
    if (!allowed) return;
    setState(() => _revealedIndex = index);
    _revealController.reveal();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<VaultBloc>().state;
    final history = state.entryHistoryEntryId == widget.entryId
        ? state.entryHistory
        : null;

    VaultEntry? currentEntry;
    for (final candidate in state.allEntries) {
      if (candidate.id == widget.entryId) {
        currentEntry = candidate;
        break;
      }
    }

    return AlertDialog(
      title: const Text('Password history'),
      insetPadding: _dialogInsetPadding(context),
      contentPadding: _dialogContentPadding(context),
      actionsOverflowDirection: VerticalDirection.down,
      actionsOverflowButtonSpacing: 8,
      content: SizedBox(
        width: _dialogContentWidth(context, 520),
        child: _body(context, state, history, currentEntry),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    VaultState state,
    VaultEntryHistory? history,
    VaultEntry? currentEntry,
  ) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    if (state.entryHistoryError != null &&
        state.entryHistoryEntryId == widget.entryId) {
      return Text(
        state.entryHistoryError!,
        style: AppTextStyles.body.copyWith(color: colors.textPrimary),
      );
    }
    if (history == null || currentEntry == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.s6),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final revisions = history.revisions;
    if (revisions.isEmpty) {
      // FR-013: an explanation, not a blank panel and not an error.
      return Column(
        key: const ValueKey('entry-history-empty'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No previous versions',
            style: AppTextStyles.rowTitle.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            'This record has not been changed since it was created, so there '
            'is nothing earlier to show.',
            style: AppTextStyles.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s3),
          _retentionLine(context, history.retention),
        ],
      );
    }

    final databasePath = state.databasePath;

    return Column(
      key: const ValueKey('entry-history-list'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: revisions.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s2),
            itemBuilder: (context, index) {
              final revision = revisions[index];
              return _RevisionCard(
                revision: revision,
                // Newest first (FR-001), so the version that replaced
                // `revisions[index]` is the one before it in the list — and
                // for the newest, the record as it stands now.
                changedFields: changedFieldsForRevision(
                  revision: revision,
                  currentEntry: currentEntry,
                  replacedBy: index == 0 ? null : revisions[index - 1],
                ),
                isRevealed: _isRevealed(index),
                remainingFraction: _revealController.remainingFraction,
                onToggleReveal: _isCheckingBiometrics
                    ? null
                    : () => _toggleReveal(index, databasePath),
                onCopy: () => _copyPassword(revision.password),
                onRestore: state.isSaving
                    ? null
                    : () => _restore(revision, currentEntry),
                onDelete: state.isSaving ? null : () => _delete(revision),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        _retentionLine(context, history.retention),
        const SizedBox(height: AppSpacing.s2),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('entry-history-clear'),
            onPressed: state.isSaving
                ? null
                : () => _clearAll(revisions.length, currentEntry),
            icon: const KvIcon(glyph: AppGlyph.deleteSweep, size: 18),
            label: const Text('Clear history'),
          ),
        ),
      ],
    );
  }

  Widget _retentionLine(BuildContext context, VaultHistoryRetention retention) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Text(
      _retentionLabel(retention),
      key: const ValueKey('entry-history-retention'),
      style: AppTextStyles.secondary.copyWith(color: colors.textSecondary),
    );
  }
}

/// FR-012: what the file says it keeps, so a missing revision is explained
/// rather than mysterious. Reported, never set (D7).
String _retentionLabel(VaultHistoryRetention retention) {
  final maxItems = retention.maxItems;
  if (maxItems == null) {
    return 'This vault states no limit on how many previous versions it '
        'keeps per record.';
  }
  if (maxItems < 0) {
    return 'This vault keeps every previous version of a record.';
  }
  if (maxItems == 0) {
    return 'This vault keeps no previous versions of a record.';
  }
  return 'This vault keeps up to $maxItems previous versions per record.';
}

/// One revision: when it was saved, what changed, and its password —
/// masked until asked for (FR-003).
class _RevisionCard extends StatelessWidget {
  const _RevisionCard({
    required this.revision,
    required this.changedFields,
    required this.isRevealed,
    required this.remainingFraction,
    required this.onToggleReveal,
    required this.onCopy,
    required this.onRestore,
    required this.onDelete,
  });

  final VaultEntryRevision revision;
  final Set<VaultEntryField> changedFields;
  final bool isRevealed;
  final double remainingFraction;
  final VoidCallback? onToggleReveal;
  final VoidCallback onCopy;
  final VoidCallback? onRestore;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final hasSecretChange =
        changedFields.contains(VaultEntryField.password) ||
        changedFields.contains(VaultEntryField.otpUri);

    return ConstrainedBox(
      // Constitution V: a row is at least 44 dp tall.
      constraints: const BoxConstraints(minHeight: 44),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s3,
          vertical: AppSpacing.s2,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.row),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    // Phase 1 note: in KDBX this timestamp is the revision's
                    // own last-modification time — when it was saved, not the
                    // instant it stopped being current. The copy says so.
                    'Saved ${_formatEntryDateTime(revision.replacedAt)}',
                    style: AppTextStyles.rowTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (hasSecretChange) ...[
                  const SizedBox(width: AppSpacing.s2),
                  // Constitution V: the signal is a label. Nothing here is
                  // carried by colour alone.
                  const KvTag(
                    label: 'Password changed',
                    variant: KvTagVariant.attention,
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              _changedFieldsLabel(changedFields),
              style: AppTextStyles.secondary.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            if (revision.password.isEmpty)
              const KvFieldRow(label: 'Password', value: 'Password not set')
            else if (isRevealed)
              RevealedPasswordRow(
                password: revision.password,
                remainingFraction: remainingFraction,
                remainingSeconds:
                    (RevealController.revealSeconds * remainingFraction).ceil(),
                onHide: onToggleReveal ?? () {},
                onCopy: onCopy,
              )
            else
              KvFieldRow(
                label: 'Password',
                value: '•' * 12,
                backgroundColor: colors.surfaceNested,
                showCopyButton: false,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KvCircleIconButton(
                      glyph: AppGlyph.copy,
                      tooltip: 'Copy this version’s password',
                      nested: true,
                      iconSize: 17,
                      onPressed: onCopy,
                    ),
                    const SizedBox(width: AppSpacing.s1),
                    KvCircleIconButton(
                      glyph: AppGlyph.eye,
                      tooltip: 'Show this version’s password',
                      nested: true,
                      iconSize: 17,
                      onPressed: onToggleReveal,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.s2),
            // Wrap, not Row: the two labels do not fit side by side on a
            // phone, and a second line beats an overflow.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.s1,
              children: [
                TextButton(
                  onPressed: onDelete,
                  child: const Text('Delete this version'),
                ),
                TextButton(
                  onPressed: onRestore,
                  child: const Text('Restore this version'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// FR-002: what differs from the version that replaced this one — names
/// only, never values (FR-004).
String _changedFieldsLabel(Set<VaultEntryField> fields) {
  if (fields.isEmpty) {
    return 'No field changed';
  }
  final names = [
    for (final field in VaultEntryField.values)
      if (fields.contains(field)) _fieldLabel(field),
  ];
  return 'Changed: ${names.join(', ')}';
}

String _fieldLabel(VaultEntryField field) => switch (field) {
  VaultEntryField.title => 'title',
  VaultEntryField.username => 'username',
  VaultEntryField.password => 'password',
  VaultEntryField.url => 'website',
  VaultEntryField.notes => 'notes',
  VaultEntryField.customFields => 'custom fields',
  VaultEntryField.attachments => 'attachments',
  VaultEntryField.otpUri => 'one-time code',
  VaultEntryField.passkey => 'passkey',
};
