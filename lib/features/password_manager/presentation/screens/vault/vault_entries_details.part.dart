part of '../vault_screen.dart';

// spec-004: the entry-detail screen/pane itself moved to
// vault_entry_detail.part.dart (_EntryDetailsPage, _EntryDetailPanel and
// their supporting widgets). This file keeps the list-row ↔ detail "glue":
// folder/record list rows, the empty states, and the background lock
// overlays — none of which are in spec-004's scope.

// spec-019 T026: `_FolderListItem` lived here — the folder row of the records
// list, with its `Add record · Add subfolder · Rename · Move · Delete` menu.
// Folders left the list for their own column, so the row left with them. Its
// three surviving actions moved verbatim into `KvFolderTree`'s `manage` mode
// (FR-006d); `Add record` became the list's add affordance (T045) and
// `Add subfolder` was retired in favour of `New folder` + `Move…` (FR-006e).

class _RecordListItem extends StatelessWidget {
  const _RecordListItem({
    required this.entry,
    required this.onOpen,
    required this.onSelectedAction,
    this.isSelected = false,
    this.folderSuffix,
  });

  final VaultEntry entry;
  final VoidCallback onOpen;
  final ValueChanged<_EntryAction> onSelectedAction;
  final bool isSelected;

  /// spec-019 FR-006j — the folder this record actually lives in, when that is
  /// not the folder the user selected. Null when it is.
  final String? folderSuffix;

  String _subtitle() {
    final base = entry.username.isEmpty
        ? (entry.url.isEmpty ? 'No username' : entry.url)
        : entry.username;
    return folderSuffix == null ? base : '$base · in $folderSuffix';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    final isPasswordWarning = _isPasswordUpdateOverdue(entry, DateTime.now());

    // spec-018 FR-004/FR-016: the accent-200 fill and accent-400 border below
    // already carried the design's selected treatment — the defect was that
    // `isSelected` was only ever true inside the records card's own inline
    // split, so in the real three-column layout no row was ever marked (D3).
    // Colour alone is not a signal (Constitution V), so the selected state is
    // also published to semantics: a screen reader announces the row as
    // selected, and it is what the a11y test asserts rather than a pixel.
    return Semantics(
      selected: isSelected,
      child: _InteractiveItemSurface(
        radius: AppRadii.row,
        minHeight: 62,
        onTap: onOpen,
        baseColor: isSelected ? AppColors.accent200 : colors.surface,
        hoveredColor: isSelected ? AppColors.accent200 : colors.surface,
        baseBorderColor: isSelected ? AppColors.accent400 : Colors.transparent,
        hoveredBorderColor: colors.selectionBorder.withValues(alpha: 0.5),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              KvLetterAvatar(
                letter: entry.title,
                size: 38,
                selected: isSelected,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title.isEmpty ? '(Untitled)' : entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.rowTitle.copyWith(
                        color: isSelected
                            ? AppColors.accent900
                            : colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _subtitle(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.secondary.copyWith(
                        color: isSelected
                            ? AppColors.accent900
                            : colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              // spec 023 T201 (FR-011): a record that holds a passkey says so
              // in the list, with a glyph *and* a semantic label — never the
              // glyph's colour alone (Constitution V).
              if (entry.hasPasskey) ...[
                Semantics(
                  label: 'Passkey',
                  child: KvIcon(
                    glyph: AppGlyph.fingerprint,
                    size: 15,
                    color: isSelected
                        ? AppColors.accent900
                        : colors.iconNeutral,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              KvHealthDot(
                state: isPasswordWarning
                    ? KvHealthState.warning
                    : KvHealthState.good,
                semanticsLabel: isPasswordWarning
                    ? 'Password needs attention'
                    : 'Password healthy',
              ),
              const SizedBox(width: 2),
              // spec-019 T039 / FR-010, C-03-04: the password of the row you
              // can see, in one interaction, without opening the record.
              //
              // Same path as the detail's own copy — the same `ClipboardGuard`
              // (so the same 30 s clear applies) and the same confirmation
              // string. Nothing here widens or lengthens the window in which
              // the plaintext exists: the value is read at the moment of the
              // copy, exactly as the detail reads it (Constitution I).
              SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  tooltip: 'Copy password',
                  padding: EdgeInsets.zero,
                  onPressed: entry.password.isEmpty
                      ? null
                      : () => _copyEntryPassword(context, entry),
                  icon: KvIcon(
                    glyph: AppGlyph.copy,
                    size: 17,
                    color: colors.iconNeutral,
                  ),
                ),
              ),
              PopupMenuButton<_EntryAction>(
                tooltip: 'Record actions',
                onSelected: onSelectedAction,
                // Explicit glyph: the default is Icons.adaptive.more, which
                // renders HORIZONTAL dots on Apple platforms while every
                // other `•••` in the app is vertical.
                icon: KvIcon(
                  glyph: AppGlyph.more,
                  size: 17,
                  color: colors.iconNeutral,
                ),
                itemBuilder: (context) => const [
                  _RoundedPopupItem(
                    value: _EntryAction.edit,
                    child: _MenuItemContent(icon: AppIcons.edit, label: 'Edit'),
                  ),
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
                    value: _EntryAction.delete,
                    child: _MenuItemContent(
                      icon: AppIcons.delete,
                      label: 'Delete',
                      isDestructive: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _isPasswordUpdateOverdue(VaultEntry entry, DateTime now) {
  final reference = entry.lastPasswordChangedAt ?? entry.updatedAt;
  if (reference == null) {
    return false;
  }

  final cutoff = DateTime(
    now.year,
    now.month - 3,
    now.day,
    now.hour,
    now.minute,
    now.second,
    now.millisecond,
    now.microsecond,
  );

  return reference.isBefore(cutoff);
}

// spec-006 T4/T5: `_LockOverlay` / `_PrivacyOverlay` moved to
// `vault_lock_overlay.part.dart` (their own file per plan.md), restyled to
// FR-3 — dark ground, app mark, "locked for <duration>" copy, and a
// zero-`Text`-widget privacy overlay (AC3).

class _MenuItemContent extends StatelessWidget {
  const _MenuItemContent({
    required this.icon,
    required this.label,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = isDestructive ? colorScheme.error : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 10),
        Text(label, style: color != null ? TextStyle(color: color) : null),
      ],
    );
  }
}

/// [PopupMenuItem] with rounded hover/splash ink instead of a full-width
/// rectangle. Replaces the default [InkWell] with one that has [borderRadius].
class _RoundedPopupItem<T> extends PopupMenuItem<T> {
  const _RoundedPopupItem({
    super.key,
    super.value,
    super.enabled,
    required super.child,
  }) : super(padding: EdgeInsets.zero);

  @override
  PopupMenuItemState<T, PopupMenuItem<T>> createState() =>
      _RoundedPopupItemState<T>();
}

class _RoundedPopupItemState<T>
    extends PopupMenuItemState<T, _RoundedPopupItem<T>> {
  static const _kRadius = 10.0;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        enabled: widget.enabled,
        button: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(_kRadius),
            child: InkWell(
              borderRadius: BorderRadius.circular(_kRadius),
              onTap: widget.enabled ? handleTap : null,
              canRequestFocus: widget.enabled,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: buildChild(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordsEmptyState extends StatelessWidget {
  const _RecordsEmptyState({required this.searchQuery, this.onClearSearch});

  final String searchQuery;
  final VoidCallback? onClearSearch;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSearchActive = searchQuery.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isSearchActive ? AppIcons.searchOff : AppIcons.key,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            // spec-019: the list holds records only, and the folder menu it
            // used to point at was deleted with the folder rows (C-03-03).
            isSearchActive ? 'No records found' : 'No records yet',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            isSearchActive
                ? 'Try a different keyword or clear the search.'
                : 'Use the add button to create your first record.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          if (isSearchActive && onClearSearch != null)
            OutlinedButton.icon(
              onPressed: onClearSearch,
              style: OutlinedButton.styleFrom(
                animationDuration: _VaultUiTokens.buttonTransitionDuration,
              ),
              icon: const Icon(AppIcons.close),
              label: const Text('Clear search'),
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// Fallback shown in the tablet detail pane when no entry is selected yet.
class _EntryDetailEmptyState extends StatelessWidget {
  const _EntryDetailEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;

    // spec-019 C-04-01: this state had no artboard and had drifted into its
    // own shape — a bare 46 px glyph and a panel title. The design's empty
    // states are a 74 px feature circle, a Caprasimo title and 13.5 body; the
    // recycle bin's is the reference. The copy is unchanged.
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: colors.surface,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: KvIcon(
                glyph: AppGlyph.key,
                size: 34,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No item selected',
              textAlign: TextAlign.center,
              style: AppTextStyles.screenTitle.copyWith(
                fontSize: 24,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Select a record from the list to view all details and copy fields.',
              textAlign: TextAlign.center,
              style: AppTextStyles.body.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// spec-019 FR-010 — the row's one-tap password copy.
Future<void> _copyEntryPassword(BuildContext context, VaultEntry entry) async {
  if (entry.password.isEmpty) {
    return;
  }
  await di.sl<ClipboardGuard>().copy(entry.password);
  if (!context.mounted) {
    return;
  }
  _showCenteredCopyToast(context, 'Copied password.');
}
