part of '../vault_screen.dart';

// FR-6 / T13/AC7: Recycle bin destination (screen 13) + empty state and
// empty-bin confirm sheet (screen 14). Restore inline on the row; Delete
// permanently in the row overflow; `Empty bin (n)` as the screen action —
// every literal string below is byte-identical to the pre-spec-005 dialog
// (see test/fixtures/strings_005_before.txt + the diff test).

Future<VaultDone?> _showRecycleBinDialog(BuildContext context) async {
  final bloc = context.read<VaultBloc>();
  bloc.add(const LoadRecycleBinEntries());

  return VaultShellRouterScope.of(context).open<VaultDone>(
    context: context,
    surface: RecycleBinSurface<VaultDone>(
      builder: (dialogContext) {
        return BlocProvider.value(
          value: bloc,
          child: const _RecycleBinScreen(),
        );
      },
    ),
  );
}

class _RecycleBinScreen extends StatelessWidget {
  const _RecycleBinScreen();

  Future<void> _handleRecycleEntryAction(
    BuildContext context,
    VaultEntry entry,
    _RecycleBinEntryAction action,
  ) async {
    switch (action) {
      case _RecycleBinEntryAction.restore:
        context.read<VaultBloc>().add(RestoreVaultEntry(entry.id));
        break;
      case _RecycleBinEntryAction.deletePermanently:
        final confirmed = await _showDeleteConfirm(
          context,
          label:
              'Permanently delete this record? This action cannot be undone.',
          actionLabel: 'Delete forever',
        );
        if (confirmed && context.mounted) {
          context.read<VaultBloc>().add(DeleteVaultEntryPermanently(entry.id));
        }
        break;
    }
  }

  Future<void> _handleEmptyBin(BuildContext context) async {
    final confirmed = await _showEmptyBinConfirmDialog(context);
    if (confirmed == ConfirmDecision.confirm && context.mounted) {
      context.read<VaultBloc>().add(const EmptyRecycleBin());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              // 2026-08-31 (user-directed): a pushed screen at every width —
              // back button on the left, same rule as `Manage duplicates`.
              padding: const EdgeInsets.fromLTRB(18, 12, 14, 0),
              child: Row(
                children: [
                  KvCircleIconButton(
                    glyph: AppGlyph.back,
                    tooltip: 'Back',
                    onPressed: () =>
                        VaultOperationScope.of(context)
                            .complete(const VaultDone()),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: BlocBuilder<VaultBloc, VaultState>(
                      buildWhen: (p, n) =>
                          p.recycleBinEntries != n.recycleBinEntries,
                      builder: (context, state) {
                        final count = state.recycleBinEntries.length;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Recycle bin',
                              style: AppTextStyles.panelTitleLarge.copyWith(
                                fontSize: 19,
                                color: colors.textPrimary,
                              ),
                            ),
                            Text(
                              count == 1 ? '1 record' : '$count records',
                              style: AppTextStyles.meta.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  KvCircleIconButton(
                    glyph: AppGlyph.refresh,
                    tooltip: 'Refresh recycle bin',
                    iconSize: 18,
                    onPressed: () => context.read<VaultBloc>().add(
                      const LoadRecycleBinEntries(),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: BlocBuilder<VaultBloc, VaultState>(
                buildWhen: (p, n) =>
                    p.isRecycleBinLoading != n.isRecycleBinLoading ||
                    p.recycleBinEntries != n.recycleBinEntries,
                builder: (context, state) {
                  if (state.isRecycleBinLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (state.recycleBinEntries.isEmpty) {
                    return const _RecycleBinEmptyState();
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    itemCount: state.recycleBinEntries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 9),
                    itemBuilder: (context, index) {
                      final entry = state.recycleBinEntries[index];
                      return _RecycleBinEntryListItem(
                        entry: entry,
                        onSelectedAction: (action) =>
                            _handleRecycleEntryAction(context, entry, action),
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Deleted records stay here until you restore or remove '
                    'them. They are still inside the .kdbx file.',
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  BlocBuilder<VaultBloc, VaultState>(
                    buildWhen: (p, n) =>
                        p.recycleBinEntries != n.recycleBinEntries ||
                        p.isSaving != n.isSaving,
                    builder: (context, state) {
                      final isDisabled =
                          state.isSaving || state.recycleBinEntries.isEmpty;
                      return KvPillButton(
                        icon: AppIcons.deleteSweep,
                        label: state.recycleBinEntries.isEmpty
                            ? 'Empty bin'
                            : 'Empty bin (${state.recycleBinEntries.length})',
                        onPressed: isDisabled
                            ? null
                            : () => _handleEmptyBin(context),
                      );
                    },
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

enum _RecycleBinEntryAction { restore, deletePermanently }

// Kept here (its original home) though this file no longer uses it itself
// (T13 restyled recycle bin rows onto `KvListRow`) — still used by
// vault_entries_details.part.dart (spec-003/004, out of scope for this
// spec) for the folder/record list hover surface.
class _InteractiveItemSurface extends StatefulWidget {
  const _InteractiveItemSurface({
    required this.radius,
    required this.child,
    this.minHeight,
    this.onTap,
    this.baseColor,
    this.hoveredColor,
    this.baseBorderColor,
    this.hoveredBorderColor,
  });

  final double radius;
  final double? minHeight;
  final VoidCallback? onTap;
  final Color? baseColor;
  final Color? hoveredColor;
  final Color? baseBorderColor;
  final Color? hoveredBorderColor;
  final Widget child;

  @override
  State<_InteractiveItemSurface> createState() =>
      _InteractiveItemSurfaceState();
}

class _InteractiveItemSurfaceState extends State<_InteractiveItemSurface> {
  bool _isHovered = false;
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final itemAnimationDuration = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : _VaultUiTokens.itemTransitionDuration;
    final highlight = _isHovered || _isFocused;
    final backgroundColor = highlight
        ? (widget.hoveredColor ??
              colorScheme.surface.withValues(alpha: isDark ? 0.82 : 0.97))
        : (widget.baseColor ??
              colorScheme.surface.withValues(alpha: isDark ? 0.74 : 0.91));
    final borderColor = highlight
        ? (widget.hoveredBorderColor ??
              colorScheme.primary.withValues(alpha: isDark ? 0.32 : 0.4))
        : (widget.baseBorderColor ??
              colorScheme.outlineVariant.withValues(
                alpha: isDark ? 0.7 : 0.88,
              ));

    final body = AnimatedContainer(
      duration: itemAnimationDuration,
      curve: Curves.easeOutCubic,
      constraints: widget.minHeight == null
          ? null
          : BoxConstraints(minHeight: widget.minHeight!),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(color: borderColor),
      ),
      child: widget.child,
    );

    return FocusableActionDetector(
      onShowFocusHighlight: (value) {
        if (_isFocused != value) {
          setState(() {
            _isFocused = value;
          });
        }
      },
      child: MouseRegion(
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) {
          setState(() {
            _isHovered = true;
          });
        },
        onExit: (_) {
          setState(() {
            _isHovered = false;
          });
        },
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(widget.radius),
            child: body,
          ),
        ),
      ),
    );
  }
}

class _RecycleBinEntryListItem extends StatelessWidget {
  const _RecycleBinEntryListItem({
    required this.entry,
    required this.onSelectedAction,
  });

  final VaultEntry entry;
  final ValueChanged<_RecycleBinEntryAction> onSelectedAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return KvListRow(
      title: entry.title.isEmpty ? '(Untitled)' : entry.title,
      subtitle: entry.username.isNotEmpty
          ? entry.username
          : (entry.url.isNotEmpty ? entry.url : 'No username'),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colors.attentionTint,
          borderRadius: BorderRadius.circular(AppRadii.iconSquare),
        ),
        alignment: Alignment.center,
        child: KvIcon(
          glyph: AppGlyph.delete,
          size: 18,
          color: colors.attentionText,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => onSelectedAction(_RecycleBinEntryAction.restore),
            child: Text(
              'Restore',
              style: AppTextStyles.secondary.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.linkText,
              ),
            ),
          ),
          PopupMenuButton<_RecycleBinEntryAction>(
            onSelected: onSelectedAction,
            icon: KvIcon(
              glyph: AppGlyph.more,
              size: 17,
              color: colors.textSecondary,
            ),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _RecycleBinEntryAction.deletePermanently,
                child: Text('Delete permanently'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecycleBinEmptyState extends StatelessWidget {
  const _RecycleBinEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
                glyph: AppGlyph.delete,
                size: 34,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Recycle bin is empty',
              style: AppTextStyles.screenTitle.copyWith(
                fontSize: 24,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Deleted records will appear here until they are restored or removed.',
              style: AppTextStyles.body.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

Future<ConfirmDecision?> _showEmptyBinConfirmDialog(BuildContext context) {
  return VaultShellRouterScope.of(context).confirm(
    context: context,
    title: 'Empty the bin?',
    body: 'This will permanently remove all items from recycle bin. This action cannot be undone.',
    confirmLabel: 'Empty bin',
  );
}
