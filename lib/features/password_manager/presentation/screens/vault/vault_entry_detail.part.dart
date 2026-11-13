part of '../vault_screen.dart';

/// Test-only clock seam: TOTP codes and countdowns are wall-clock-real by
/// design (they must be), which makes them inherently non-deterministic for
/// pixel goldens. Golden tests set this to a fixed `DateTime.now`
/// replacement before pumping and reset it in `tearDown`; production code
/// never touches it.
@visibleForTesting
DateTime Function() debugEntryDetailNowOverride = DateTime.now;

/// FR-1/FR-2/FR-4 (spec-004): entry detail screen (mobile push) / pane
/// (tablet, via `VaultShellRouter`'s existing pane presentation — no route
/// is pushed on tablet, see `VaultShellRouter.presentationFor`).
class _EntryDetailsPage extends StatelessWidget {
  const _EntryDetailsPage({required this.entryId, this.onSelectedAction});

  final String entryId;
  final ValueChanged<_EntryAction>? onSelectedAction;

  @override
  Widget build(BuildContext context) {
    final entry = context.select((VaultBloc bloc) {
      for (final e in bloc.state.allEntries) {
        if (e.id == entryId) return e;
      }
      return null;
    });

    if (entry == null) {
      // spec-018 FR-007/FR-008 (D6): this used to call `Navigator.pop`, which
      // is only correct when the surface is a pushed route. Under the pane
      // presentation no route was pushed, so `canPop` referred to an
      // unrelated route: the pane was either left in place showing nothing,
      // or something else was popped. Completing the operation is
      // presentation-neutral — and `VaultShellRouter._finish` cancels child
      // sessions, so anything stacked on this detail goes with it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          VaultOperationScope.of(context).complete(const VaultDone());
        }
      });
      return const SizedBox.shrink();
    }

    return DecoratedBox(
      decoration: BoxDecoration(gradient: AppBackgrounds.gradient(context)),
      child: _EntryDetailPanel(
        entry: entry,
        onSelectedAction: onSelectedAction,
        // The pane host already draws the back affordance for whatever it
        // hosts, so the panel must not draw a second one. Derived from the
        // tree, not from the window width: the presentation is fixed when the
        // surface opens, so shrinking the window below the pane threshold
        // with a record open used to flip the width answer to `true` while
        // the pane was still mounted — two back buttons, one of which popped
        // an unrelated route.
        allowsPop: !_VaultPaneScope.of(context),
      ),
    );
  }
}

class _EntryDetailPanel extends StatefulWidget {
  const _EntryDetailPanel({
    required this.entry,
    this.onSelectedAction,
    this.allowsPop = false,
  });

  final VaultEntry entry;
  final ValueChanged<_EntryAction>? onSelectedAction;

  /// True when hosted as a pushed route (mobile): the header's back chevron
  /// pops. False when hosted inline (tablet list column, or the tablet
  /// detail pane, which already has its own generic back affordance) — the
  /// chevron is hidden rather than risk popping an unrelated route.
  final bool allowsPop;

  @override
  State<_EntryDetailPanel> createState() => _EntryDetailPanelState();
}

class _EntryDetailPanelState extends State<_EntryDetailPanel> {
  // Single shared 1s ticker driving both the TOTP countdown and the reveal
  // countdown bar (spec-004 "TOTP + reveal" non-negotiable) — not two
  // independent timers.
  Timer? _ticker;
  DateTime _nowUtc = debugEntryDetailNowOverride().toUtc();
  late final RevealController _revealController;
  bool _isCheckingBiometrics = false;

  /// spec 023 US1b: what the one reveal countdown is showing — `null` for
  /// the password, otherwise a secret custom field's position in the
  /// entry's list. Position, not key: the editor keeps keys unique, but a
  /// vault written elsewhere may carry two fields with the same name, and
  /// one gate must never uncover both. One secret at a time: revealing a
  /// field hides whatever else was revealed.
  int? _revealedFieldIndex;

  @override
  void initState() {
    super.initState();
    _revealController = RevealController()..addListener(_onRevealChanged);
    _configureTicker();
  }

  @override
  void didUpdateWidget(covariant _EntryDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The revealed field is identified by position, so any change to the
    // custom-field list invalidates it: an insert, a removal or a reorder
    // would otherwise leave a *different* field rendered revealed without its
    // own biometric gate. Same entry id is not enough — editing an entry
    // rebuilds its fields in place.
    if (oldWidget.entry.id != widget.entry.id ||
        !_sameCustomFieldShape(oldWidget.entry, widget.entry)) {
      _revealController.hide();
      _revealedFieldIndex = null;
    }
    _configureTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _revealController.removeListener(_onRevealChanged);
    _revealController.dispose();
    super.dispose();
  }

  /// Whether two versions of an entry lay their custom fields out the same
  /// way, so a reveal held by position still points at the field the user
  /// gated. Keys and protection flags are compared, not values: editing a
  /// revealed field's text leaves it the same field.
  static bool _sameCustomFieldShape(VaultEntry before, VaultEntry after) {
    if (before.customFields.length != after.customFields.length) return false;
    for (var i = 0; i < before.customFields.length; i++) {
      if (before.customFields[i].key != after.customFields[i].key ||
          before.customFields[i].isProtected !=
              after.customFields[i].isProtected) {
        return false;
      }
    }
    return true;
  }

  void _onRevealChanged() {
    if (mounted) setState(() {});
  }

  void _configureTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _nowUtc = debugEntryDetailNowOverride().toUtc());
      _revealController.tick();
    });
  }

  Future<void> _copy({required String text, required String message}) async {
    if (text.isEmpty) return;
    await di.sl<ClipboardGuard>().copy(text);
    if (!mounted) return;
    _showCenteredCopyToast(context, message);
  }

  Future<void> _handleRevealTap(String databasePath, {int? fieldIndex}) async {
    if (_revealController.isRevealed && _revealedFieldIndex == fieldIndex) {
      _revealController.hide();
      return;
    }
    if (_isCheckingBiometrics) return;
    setState(() => _isCheckingBiometrics = true);
    final allowed = await _resolveRevealPermission(context, databasePath);
    if (!mounted) return;
    setState(() => _isCheckingBiometrics = false);
    if (allowed) {
      _revealedFieldIndex = fieldIndex;
      _revealController.reveal();
    }
  }

  bool _isRevealed({int? fieldIndex}) =>
      _revealController.isRevealed && _revealedFieldIndex == fieldIndex;

  Future<void> _exportAttachment(
    VaultEntry entry,
    VaultAttachment attachment,
  ) async {
    // Captured before the await: the detail can be rebuilt or replaced while
    // the system folder picker is open.
    final bloc = context.read<VaultBloc>();
    final directory = await FilePicker.getDirectoryPath();
    if (directory == null) return;
    bloc.add(
      ExportVaultAttachment(
        entryId: entry.id,
        attachmentKey: attachment.key,
        destinationDirectory: directory,
      ),
    );
  }

  /// spec 023 T205 / FR-010: deleting a passkey destroys the only copy of a
  /// private key. The confirmation names the site and the account so the user
  /// can tell two passkeys apart, says it cannot be recovered, and says the
  /// dated backup is written first — the coordinator writes it before the
  /// save, so that promise is kept even if the save then fails.
  Future<void> _confirmDeletePasskey(
    VaultEntry entry,
    VaultPasskey passkey,
  ) async {
    final site = passkey.relyingPartyId.isEmpty
        ? 'this site'
        : passkey.relyingPartyId;
    final account = passkey.username.isEmpty
        ? 'the account with no username'
        : '“${passkey.username}”';
    final bloc = context.read<VaultBloc>();
    final confirmed = await _showConfirmation(
      context,
      title: 'Delete this passkey?',
      body:
          'The passkey for $site and $account will be removed from '
          '“${entry.title}”. A passkey cannot be recovered: you would have to '
          'create a new one on $site. The record keeps its password, website '
          'and other fields, and a dated copy of the vault is saved on this '
          'device before anything is written.',
      confirmLabel: 'Delete passkey',
    );
    if (confirmed?.isConfirmed != true || !mounted) return;
    bloc.add(
      DeletePasskey(
        entryId: entry.id,
        relyingPartyId: passkey.relyingPartyId,
        credentialId: passkey.credentialId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    final databasePath = context.read<VaultBloc>().state.databasePath;

    final title = entry.title.isEmpty ? '(Untitled)' : entry.title;
    final folderName = _folderNameFor(context, entry.groupId);
    final subtitle = entry.url.isEmpty
        ? folderName
        : '$folderName · ${_hostFor(entry.url)}';

    // spec 023 FR-002a: a protected field keeps the secret treatment whatever
    // its key. A URL-keyed custom string marked protected in the file would
    // otherwise render as an ordinary Website row — plaintext on screen, with
    // un-gated open and copy actions — so it takes the masked path below
    // instead of the website list.
    final extraUrls = entry.customFields
        .where(
          (field) =>
              isUrlFieldKey(field.key) &&
              !field.isProtected &&
              field.value.trim().isNotEmpty,
        )
        .map((field) => field.value.trim())
        .toList(growable: false);
    final customFields = entry.customFields
        .where(
          (field) =>
              !_isOtpFieldKey(field.key) &&
              (!isUrlFieldKey(field.key) || field.isProtected),
        )
        .toList(growable: false);
    final totpData = entry.otpUri == null
        ? null
        : TotpUtils.fromOtpAuthUri(entry.otpUri!, _nowUtc);
    final strength = evaluatePasswordStrength(entry.password);
    final reusedByCount = entry.password.isEmpty
        ? 0
        : context.read<VaultBloc>().state.allEntries.where((other) {
            return other.id != entry.id && other.password == entry.password;
          }).length;
    final isWarning =
        entry.password.isNotEmpty &&
        (strength.level == PasswordStrengthLevel.weak || reusedByCount > 0);
    final changedAgo = describeTimeAgo(
      entry.lastPasswordChangedAt,
      debugEntryDetailNowOverride(),
    );

    return SafeArea(
      child: SingleChildScrollView(
        // Stable handle for tests: "a detail is shown" used to be asserted
        // via the `Copy password` pill, which is gone (2026-08-31).
        key: const ValueKey('entry-detail-body'),
        // Top 26: one visual top across folder column, list card and detail.
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DetailHeader(
              allowsPop: widget.allowsPop,
              onEdit: widget.onSelectedAction == null
                  ? null
                  : () => widget.onSelectedAction!(_EntryAction.edit),
              onMore: widget.onSelectedAction,
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KvLetterAvatar(letter: title, size: 56, fontSize: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.screenTitle.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.body.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            KvFieldRow(
              label: 'Username',
              value: entry.username.isEmpty
                  ? 'Username not set'
                  : entry.username,
              onCopy: entry.username.isEmpty
                  ? null
                  : () => _copy(
                      text: entry.username,
                      message: 'Copied username.',
                    ),
            ),
            const SizedBox(height: 9),
            if (entry.password.isEmpty)
              const KvFieldRow(label: 'Password', value: 'Password not set')
            else if (_isRevealed())
              RevealedPasswordRow(
                password: entry.password,
                remainingFraction: _revealController.remainingFraction,
                remainingSeconds:
                    (RevealController.revealSeconds *
                            _revealController.remainingFraction)
                        .ceil(),
                onHide: () => _handleRevealTap(databasePath),
                onCopy: () =>
                    _copy(text: entry.password, message: 'Copied password.'),
              )
            else
              KvFieldRow(
                label: 'Password',
                value: '••••••••••••',
                onCopy: () =>
                    _copy(text: entry.password, message: 'Copied password.'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KvCircleIconButton(
                      glyph: AppGlyph.eye,
                      tooltip: 'Show password',
                      nested: true,
                      iconSize: 17,
                      onPressed: _isCheckingBiometrics
                          ? null
                          : () => _handleRevealTap(databasePath),
                    ),
                    const SizedBox(width: 8),
                    KvCircleIconButton(
                      glyph: AppGlyph.copy,
                      tooltip: 'Copy',
                      nested: true,
                      iconSize: 17,
                      onPressed: () => _copy(
                        text: entry.password,
                        message: 'Copied password.',
                      ),
                    ),
                  ],
                ),
              ),
            // 2026-08-30: the password's own information sits directly under
            // the password field, not at the foot of the screen.
            if (entry.password.isNotEmpty) ...[
              const SizedBox(height: 9),
              if (isWarning)
                StrengthStrip.warning(
                  assessment: strength,
                  changedAgoLabel: changedAgo,
                  reusedByCount: reusedByCount,
                  onGenerateNew: () => _openGeneratorForEntry(context, entry),
                )
              else
                StrengthStrip.normal(
                  assessment: strength,
                  changedAgoLabel: changedAgo,
                ),
            ],
            if (totpData != null) ...[
              const SizedBox(height: 9),
              TotpRow(
                data: totpData,
                onCopy: () => _copy(
                  text: totpData.code,
                  message: 'Copied one-time code.',
                ),
              ),
            ],
            if (entry.url.isNotEmpty) ...[
              const SizedBox(height: 9),
              KvFieldRow(
                label: 'Website',
                value: entry.url,
                valueColor: colors.linkText,
                onCopy: () => _copy(text: entry.url, message: 'Copied URL.'),
                // 2026-08-30: opening the site is a button on the field
                // itself, like copy — the standalone `Open <host>` pill is
                // gone.
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KvCircleIconButton(
                      glyph: AppGlyph.linkSimple,
                      tooltip: 'Open website',
                      nested: true,
                      iconSize: 17,
                      onPressed: () => _openEntryUrl(context, entry.url),
                    ),
                    const SizedBox(width: 8),
                    KvCircleIconButton(
                      glyph: AppGlyph.copy,
                      tooltip: 'Copy',
                      nested: true,
                      iconSize: 17,
                      onPressed: () =>
                          _copy(text: entry.url, message: 'Copied URL.'),
                    ),
                  ],
                ),
              ),
            ],
            for (final url in extraUrls) ...[
              const SizedBox(height: 9),
              KvFieldRow(
                label: 'Website',
                value: url,
                valueColor: colors.linkText,
                onCopy: () => _copy(text: url, message: 'Copied URL.'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KvCircleIconButton(
                      glyph: AppGlyph.linkSimple,
                      tooltip: 'Open website',
                      nested: true,
                      iconSize: 17,
                      onPressed: () => _openEntryUrl(context, url),
                    ),
                    const SizedBox(width: 8),
                    KvCircleIconButton(
                      glyph: AppGlyph.copy,
                      tooltip: 'Copy',
                      nested: true,
                      iconSize: 17,
                      onPressed: () => _copy(text: url, message: 'Copied URL.'),
                    ),
                  ],
                ),
              ),
            ],
            if (entry.notes.isNotEmpty) ...[
              const SizedBox(height: 9),
              KvFieldRow(
                label: 'Notes',
                value: entry.notes,
                maxLines: 4,
                showCopyButton: false,
                onCopy: () =>
                    _copy(text: entry.notes, message: 'Copied notes.'),
              ),
            ],
            // 2026-08-31: custom fields are ordinary rows of the list, not a
            // count hidden behind a chip.
            for (final (index, field) in customFields.indexed) ...[
              const SizedBox(height: 9),
              // spec 023 US1b: a secret field takes the password's own
              // treatment — masked, gated reveal on one shared countdown,
              // guarded copy. The value never enters the tree while masked.
              if (field.isProtected && field.value.isNotEmpty)
                if (_isRevealed(fieldIndex: index))
                  RevealedPasswordRow(
                    label: field.key,
                    hideTooltip: 'Hide value',
                    password: field.value,
                    remainingFraction: _revealController.remainingFraction,
                    remainingSeconds:
                        (RevealController.revealSeconds *
                                _revealController.remainingFraction)
                            .ceil(),
                    onHide: () =>
                        _handleRevealTap(databasePath, fieldIndex: index),
                    onCopy: () => _copy(
                      text: field.value,
                      message: 'Copied ${field.key}.',
                    ),
                  )
                else
                  KvFieldRow(
                    label: field.key,
                    value: '••••••••••••',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        KvCircleIconButton(
                          glyph: AppGlyph.eye,
                          tooltip: 'Show value',
                          nested: true,
                          iconSize: 17,
                          onPressed: _isCheckingBiometrics
                              ? null
                              : () => _handleRevealTap(
                                  databasePath,
                                  fieldIndex: index,
                                ),
                        ),
                        const SizedBox(width: 8),
                        KvCircleIconButton(
                          glyph: AppGlyph.copy,
                          tooltip: 'Copy',
                          nested: true,
                          iconSize: 17,
                          onPressed: () => _copy(
                            text: field.value,
                            message: 'Copied ${field.key}.',
                          ),
                        ),
                      ],
                    ),
                  )
              else
                KvFieldRow(
                  label: field.key,
                  value: field.value.isEmpty ? 'Value not set' : field.value,
                  onCopy: field.value.isEmpty
                      ? null
                      : () => _copy(
                          text: field.value,
                          message: 'Copied ${field.key}.',
                        ),
                ),
            ],
            // spec 023 T202: the passkey section sits after the record's own
            // fields and before attachments — a passkey is an attribute of
            // this record (FR-011a), not a file hanging off it. Absent when
            // the record holds none: there is nothing to add here yet.
            if (entry.hasPasskey) ...[
              const SizedBox(height: 16),
              _PasskeySection(
                entry: entry,
                onDelete: (passkey) => _confirmDeletePasskey(entry, passkey),
              ),
            ],
            // Attachments are a permanent section, shown at zero too, and the
            // files are listed here like every other field of the record —
            // not counted behind a second surface. Reading is what this
            // screen does, so each row offers export; adding and removing
            // are edits and live in the editor, with the same rows.
            const SizedBox(height: 16),
            Text(
              'Attachments',
              style: AppTextStyles.labelUpper.copyWith(
                color: colors.textSecondary,
              ),
            ),
            if (entry.attachments.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _kNoAttachmentsLabel,
                style: AppTextStyles.secondary.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ] else
              for (final attachment in entry.attachments) ...[
                const SizedBox(height: 9),
                _AttachmentRow(
                  key: ValueKey('entry-attachment-${attachment.key}'),
                  name: attachment.name,
                  caption: formatBytes(attachment.size),
                  trailing: KvCircleIconButton(
                    glyph: AppGlyph.export,
                    tooltip: 'Export attachment',
                    nested: true,
                    iconSize: 17,
                    onPressed: () => _exportAttachment(entry, attachment),
                  ),
                ),
              ],
            // spec 017 T202: history is reached from the record the user is
            // already looking at, and is read only when asked for (FR-015) —
            // hence a chip and not a count, which would need the file read.
            const SizedBox(height: 16),
            Text(
              'Password history',
              style: AppTextStyles.labelUpper.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Previous versions of this record.',
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                _MoreChip(
                  icon: AppGlyph.clock,
                  label: 'View history',
                  onTap: () => _showEntryHistoryDialog(context, entry.id),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.allowsPop,
    required this.onEdit,
    required this.onMore,
  });

  final bool allowsPop;
  final VoidCallback? onEdit;
  final ValueChanged<_EntryAction>? onMore;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;

    // 2026-08-31: in the two/three-column layouts the detail carries no back
    // at all — the list beside it IS the navigation. But a pane opened wide
    // and then resized below the detail-pane threshold fills the window with
    // no list beside it, so THERE the back must reappear or the user is
    // stuck. The pushed route on the phone keeps its own.
    final paneBack = _VaultPaneScope.onBackOf(context);
    final isSoleColumn = !VaultLayoutClass.fromWidth(
      MediaQuery.sizeOf(context).width,
    ).hasDetailPane;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (allowsPop)
          KvCircleIconButton(
            glyph: AppGlyph.back,
            tooltip: 'Back',
            onPressed: () => Navigator.maybePop(context),
          )
        else if (paneBack != null &&
            (isSoleColumn || _VaultPaneScope.requiresBackOf(context)))
          KvCircleIconButton(
            glyph: AppGlyph.back,
            tooltip: 'Back',
            onPressed: () => unawaited(paneBack()),
          )
        else
          const SizedBox(width: 36, height: 36),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KvCircleIconButton(
              glyph: AppGlyph.edit,
              tooltip: 'Edit',
              onPressed: onEdit,
            ),
            const SizedBox(width: 8),
            PopupMenuButton<_EntryAction>(
              tooltip: 'Record actions',
              onSelected: onMore,
              itemBuilder: (context) => const [
                _RoundedPopupItem(
                  value: _EntryAction.move,
                  child: _MenuItemContent(icon: AppIcons.move, label: 'Move'),
                ),
                _RoundedPopupItem(
                  value: _EntryAction.duplicate,
                  child: _MenuItemContent(
                    icon: AppIcons.copy,
                    label: 'Duplicate',
                  ),
                ),
                _RoundedPopupItem(
                  value: _EntryAction.info,
                  child: _MenuItemContent(
                    icon: AppIcons.info,
                    label: 'Record info',
                  ),
                ),
                _RoundedPopupItem(
                  value: _EntryAction.delete,
                  child: _MenuItemContent(
                    icon: AppIcons.delete,
                    label: 'Delete',
                    isDestructive: true,
                  ),
                ),
              ],
              // Plain visual circle, not another `circleButton` (IconButton
              // already carries its own Tooltip): PopupMenuButton wraps
              // `child` in a Tooltip using its own `tooltip` param, and
              // double-nesting two Tooltips on the same hit-test region
              // crashes Flutter's tooltip ticker under widget-test pointer
              // synthesis (observed while adding spec-004's goldens).
              child: SizedBox(
                width: 36,
                height: 36,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: KvIcon(
                      glyph: AppGlyph.more,
                      size: 19,
                      color: colors.iconNeutral,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MoreChip extends StatelessWidget {
  const _MoreChip({required this.icon, required this.label, this.onTap});

  final AppGlyph icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              KvIcon(glyph: icon, size: 16, color: colors.iconNeutral),
              const SizedBox(width: 7),
              Text(
                label,
                style: AppTextStyles.secondary.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-08-30: the metadata grid lives in the `Record info` dialog opened
/// from the record's `•••`, at every width. Exactly three rows — Created,
/// Updated, last password change (spec-004 FR-7/AC8).
Future<void> _showRecordInfoDialog(BuildContext context, VaultEntry entry) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Record info'),
      // 2026-09-05: `_MetadataGrid` is a Column; without `min` it fills the
      // loose height the dialog's content slot hands it and the dialog stood
      // full-screen on a phone.
      content: _MetadataGrid(entry: entry),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _MetadataGrid extends StatelessWidget {
  const _MetadataGrid({required this.entry});

  final VaultEntry entry;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Created', _formatEntryDateTime(entry.createdAt)),
      ('Updated', _formatEntryDateTime(entry.updatedAt)),
      (
        'Last password change',
        _formatEntryDateTime(entry.lastPasswordChangedAt),
      ),
    ];
    assert(rows.length == 3, 'AC8: metadata grid must show exactly 3 rows.');

    return Column(
      key: const ValueKey('entry-detail-metadata-grid'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          KvFieldRow(label: rows[i].$1, value: rows[i].$2),
        ],
      ],
    );
  }
}

/// The one reveal policy: is the user allowed to see a secret of this
/// database right now?
///
/// Extracted from `_handleRevealTap` so spec 017's history view can call the
/// same path rather than restate it (FR-003/D3) — a historical password is
/// not less sensitive than the current one, and two copies of this rule
/// would be two places to get it wrong.
Future<bool> _resolveRevealPermission(
  BuildContext context,
  String databasePath,
) async {
  bool biometricEnabled;
  try {
    biometricEnabled = await di
        .sl<VaultSessionCoordinator>()
        .getBiometricProtectionEnabledForPath(databasePath: databasePath);
  } catch (_) {
    biometricEnabled = false;
  }
  if (!biometricEnabled) {
    return true;
  }

  // 2026-08-31 (user-directed): go straight to the OS biometric prompt —
  // no intermediate sheet. The sheet only appears as a fallback when the
  // prompt fails or is cancelled, offering retry and the password path.
  bool authenticated;
  try {
    authenticated = await di.sl<BiometricDataSource>().authenticate(
      reason: 'Reveal password',
    );
  } catch (_) {
    authenticated = false;
  }
  if (authenticated) {
    return true;
  }

  if (!context.mounted) return false;
  return await _showBiometricRevealGate(context, databasePath) == true;
}

Future<bool?> _showBiometricRevealGate(
  BuildContext context,
  String databasePath,
) {
  // `KvBottomSheet` hosts on the root navigator, so the sheet is a sibling of
  // whatever opened it and sees neither the shell nor the caller's scope —
  // re-provided here so "Use password" reaches the shell's own session
  // instead of the top route (see `_usePassword`).
  final session = VaultShellSessionScope.of(context);
  return KvBottomSheet.show<bool>(
    context: context,
    builder: (sheetContext) => VaultShellSessionScope(
      session: session,
      // ...and, for the same sibling reason, the gate is outside both the
      // shell's pointer `Listener` and the route host's: reading the sheet or
      // retrying biometrics read as idle and the inactivity timer locked the
      // vault out from under it. Default `deferToChild`: observes pointers,
      // does not take them.
      child: Listener(
        onPointerDown: (_) => session.reportActivity(),
        child: _BiometricRevealGateSheet(databasePath: databasePath),
      ),
    ),
  );
}

class _BiometricRevealGateSheet extends StatefulWidget {
  const _BiometricRevealGateSheet({required this.databasePath});

  final String databasePath;

  @override
  State<_BiometricRevealGateSheet> createState() =>
      _BiometricRevealGateSheetState();
}

class _BiometricRevealGateSheetState extends State<_BiometricRevealGateSheet> {
  bool _isAuthenticating = false;

  Future<void> _authenticate() async {
    if (_isAuthenticating) return;
    setState(() => _isAuthenticating = true);
    final ok = await di.sl<BiometricDataSource>().authenticate(
      reason: 'Reveal password',
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _isAuthenticating = false);
  }

  // Reuses the existing whole-vault lock+re-unlock flow — the codebase has
  // no separate "confirm just this reveal with a password" primitive, and
  // spec-004 explicitly asks not to invent new authentication logic.
  ///
  /// The lock-and-replace itself belongs to the shell: this sheet can be
  /// opened from the detail (a pane, or a pushed route) or from the history
  /// dialog, and `pushReplacement` here replaced whichever of those was on
  /// top — leaving the unlocked shell alive underneath the unlock screen.
  Future<void> _usePassword() async {
    final session = VaultShellSessionScope.of(context);
    Navigator.of(context).pop(false);
    await session.lockAndReauthenticate(widget.databasePath);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.actionFill,
              shape: BoxShape.circle,
            ),
            child: KvIcon(
              glyph: AppGlyph.fingerprint,
              size: 25,
              color: colors.actionText,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Confirm it\u2019s you',
            style: AppTextStyles.sheetTitleLarge.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Biometric check didn\u2019t complete. Try again, or unlock '
            'with your master password.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 14),
          KvPillButton(
            label: 'Unlock with biometrics',
            onPressed: _isAuthenticating ? null : _authenticate,
          ),
          const SizedBox(height: 9),
          KvSecondaryPillButton(label: 'Use password', onPressed: _usePassword),
        ],
      ),
    );
  }
}

String _folderNameFor(BuildContext context, String groupId) {
  final groups = context.read<VaultBloc>().state.groups;
  for (final group in groups) {
    if (group.id == groupId) return group.name;
  }
  return 'Vault';
}

String _hostFor(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return '';
  final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(withScheme);
  final host = uri?.host ?? trimmed;
  return host.isEmpty ? trimmed : host;
}

Future<void> _openGeneratorForEntry(
  BuildContext context,
  VaultEntry entry,
) async {
  await _showPasswordGeneratorSheet(
    context,
    initialOptions: _optionsFromPassword(entry.password),
  );
}

/// FR-4: the weak/reused strip opens the generator "pre-filled with the
/// entry's constraints" — approximated from the current password's
/// character classes and length, clamped to the generator's 8–64 range.
PasswordGeneratorOptions _optionsFromPassword(String password) {
  if (password.isEmpty) {
    return const PasswordGeneratorOptions.defaults();
  }
  final hasLower = password.contains(RegExp('[a-z]'));
  final hasUpper = password.contains(RegExp('[A-Z]'));
  final hasDigit = password.contains(RegExp('[0-9]'));
  final hasSymbol = password.contains(RegExp(r'[^a-zA-Z0-9]'));
  final anySet = hasLower || hasUpper || hasDigit || hasSymbol;
  return PasswordGeneratorOptions(
    length: password.length.clamp(8, 64).toInt(),
    includeLowercase: anySet ? hasLower : true,
    includeUppercase: anySet ? hasUpper : true,
    includeDigits: anySet ? hasDigit : true,
    includeSymbols: anySet ? hasSymbol : true,
  );
}

/// Opens [url] in the browser, assuming `https` when the record omits the
/// scheme. Failure is reported rather than swallowed — the same shape the
/// Settings destination already uses for external links.
Future<void> _openEntryUrl(BuildContext context, String url) async {
  final trimmed = url.trim();
  final parsed = Uri.tryParse(trimmed);
  final target = (parsed != null && parsed.hasScheme)
      ? trimmed
      : 'https://$trimmed';

  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(target),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Unable to open $target')));
  }
}
