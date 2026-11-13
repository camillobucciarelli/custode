part of '../vault_screen.dart';

/// spec-018 FR-010/FR-001a: the ONE way a record detail is opened, from every
/// origin — the records list, the health-category list, duplicates, search.
///
/// It opens an `EntrySurface`, so the shell router decides the presentation
/// (pushed screen when narrow, the persistent detail pane when wide) and owns
/// dismissal and nesting. Callers do not choose, and do not supply their own
/// action wiring: the actions are attached here so two origins cannot offer
/// different menus for the same record, which is exactly what D9 was.
///
/// The action callback receives the hosted surface's own (descendant)
/// context, never the caller's: the caller's context can be deactivated by
/// the time an action is picked from a menu inside the surface, which made
/// every dialog opened from here (Delete, Move) throw "Looking
/// up a deactivated widget's ancestor" once the entries list rebuilt.
Future<void> _openEntryDetailsSurface(
  BuildContext context, {
  required String entryId,
}) {
  final bloc = context.read<VaultBloc>();
  return VaultShellRouterScope.of(context).open<VaultDone>(
    context: context,
    surface: EntrySurface<VaultDone>(
      builder: (surfaceContext) => BlocProvider.value(
        value: bloc,
        child: _EntryDetailsPage(
          entryId: entryId,
          onSelectedAction: (action) => unawaited(
            _EntriesCardState._handleEntryActionOn(
              surfaceContext,
              bloc,
              entryId,
              action,
              bloc.state.groups,
            ),
          ),
        ),
      ),
    ),
  );
}

class _EntriesCard extends StatefulWidget {
  const _EntriesCard({
    required this.showSortControl,
    required this.onAddRecord,
    required this.entries,
    required this.groups,
    required this.currentGroupId,
    required this.rootGroupId,
    required this.folderCounts,
    required this.folderBrowser,
    required this.searchQuery,
    required this.sortBy,
    required this.selectedEntryId,
    required this.onSelectEntry,
    this.subfolderIds = const {},
  });

  /// FR-009 vs FR-009a: the inline sort control belongs to the width that has
  /// a folder column. Narrower than that, the header's sort affordance opens
  /// the `Sort` sheet instead, and rendering both would be two controls for
  /// one setting.
  final bool showSortControl;
  final VoidCallback onAddRecord;

  final List<VaultEntry> entries;
  final List<VaultGroup> groups;

  /// The selected folder. The card does not filter by it — the BLoC already
  /// did (FR-006h) — it only needs it to say which records are on loan from a
  /// subfolder (FR-006j).
  final String? currentGroupId;

  /// The vault's root group id; the folder browser treats it as `/`.
  final String? rootGroupId;

  /// Inclusive per-folder record counts (same numbers the folder tree shows).
  final Map<String, int> folderCounts;

  /// 2026-08-31 — the 1/2-column layouts browse like a file system: the
  /// list shows the current folder's subfolders and its own records, and
  /// tapping a folder descends into it. The 3-column layout keeps the pure
  /// records list (the folder column is the navigation there).
  final bool folderBrowser;

  final String searchQuery;
  final VaultEntrySort sortBy;

  /// The descendants of the selected folder, empty when it is a leaf. Non-empty
  /// is what makes the count line say `· incl. subfolders` (FR-006i).
  final Set<String> subfolderIds;

  /// spec-018 FR-001a/FR-003: selection is shell-owned. This card renders no
  /// detail of its own and keeps no selection state — it marks the row the
  /// shell says is selected and reports activations back.
  final String? selectedEntryId;
  final ValueChanged<String> onSelectEntry;

  @override
  State<_EntriesCard> createState() => _EntriesCardState();
}

class _EntriesCardState extends State<_EntriesCard> {
  late final ScrollController _entriesScrollController;
  late final TextEditingController _searchController;
  @override
  void initState() {
    super.initState();
    _entriesScrollController = ScrollController();
    _searchController = TextEditingController(text: widget.searchQuery);
  }

  @override
  void dispose() {
    _entriesScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _EntriesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchQuery != _searchController.text) {
      _searchController.value = TextEditingValue(
        text: widget.searchQuery,
        selection: TextSelection.collapsed(offset: widget.searchQuery.length),
      );
    }
    // spec-018: the "selection no longer exists" cleanup that used to live
    // here moved to the shell, which is now the single owner (FR-003). A
    // second copy here is what let the highlight and the detail disagree.
  }

  /// spec-018 FR-005/FR-006 (D4, D5) — the record-action contract, C5.
  ///
  /// Two bugs lived in the previous shape and both are structural:
  ///
  ///  * It took a `VaultEntry` **value**, captured when the surface opened.
  ///    An edit therefore wrote fields as they were before any earlier edit
  ///    landed, so a second save silently reverted the first (D4). It now
  ///    takes an **id** and resolves the entry at confirmation time.
  ///  * It guarded on `_EntriesCardState.mounted` and dispatched through
  ///    `this.context`. When the action ran from a pushed surface and the
  ///    list rebuilt underneath, the guard was false: the user confirmed and
  ///    the event was never sent, with no error (D5). The bloc is now
  ///    captured *before* the first await — it outlives every surface — and
  ///    liveness is judged on the surface's own context.
  static Future<void> _handleEntryActionOn(
    BuildContext surfaceContext,
    VaultBloc bloc,
    String entryId,
    _EntryAction action,
    List<VaultGroup> groups,
  ) async {
    // `bloc` is passed in, already resolved, rather than read from
    // `surfaceContext`: the surface context is the ancestor of the
    // `BlocProvider.value` that hosts the detail, so a `read` here finds
    // nothing. Passing it also satisfies G5.2 by construction — the handle
    // is captured before any await and outlives every surface in the stack.
    VaultEntry? currentEntry() {
      for (final entry in bloc.state.allEntries) {
        if (entry.id == entryId) return entry;
      }
      return null;
    }

    final entry = currentEntry();
    if (entry == null) {
      // G5.7: the record went away before the action started.
      bloc.add(const ReportVaultActionAbandoned());
      return;
    }

    switch (action) {
      case _EntryAction.edit:
        final payload = await _showEntryDialog(surfaceContext, initial: entry);
        if (payload == null) {
          return;
        }
        if (currentEntry() == null) {
          bloc.add(const ReportVaultActionAbandoned());
          return;
        }
        bloc.add(
          UpdateVaultEntry(
            entryId: entryId,
            title: payload.title,
            username: payload.username,
            password: payload.password,
            url: payload.url,
            notes: payload.notes,
            customFields: payload.customFields,
            attachmentPaths: payload.attachmentPaths,
            removedAttachmentKeys: payload.removedAttachmentKeys,
          ),
        );
      case _EntryAction.move:
        final target = await _showMoveTargetDialog(surfaceContext, groups);
        if (target == null) {
          return;
        }
        if (currentEntry() == null) {
          bloc.add(const ReportVaultActionAbandoned());
          return;
        }
        bloc.add(
          MoveVaultEntry(entryId: entryId, targetGroupId: target.groupId),
        );
      case _EntryAction.info:
        // Read-only: a stale copy could show stale timestamps, so re-read.
        final freshInfo = currentEntry();
        if (freshInfo == null) {
          bloc.add(const ReportVaultActionAbandoned());
          return;
        }
        await _showRecordInfoDialog(surfaceContext, freshInfo);
      case _EntryAction.duplicate:
        // No confirmation: duplicating creates, it never destroys, and the
        // result is visible in the list the user is already looking at
        // (Constitution VII asks first only before losing something).
        bloc.add(DuplicateVaultEntry(entryId));
      case _EntryAction.delete:
        final confirmed = await _showDeleteConfirm(
          surfaceContext,
          label: 'Move this record to recycle bin?',
        );
        if (!confirmed) {
          return;
        }
        if (currentEntry() == null) {
          bloc.add(const ReportVaultActionAbandoned());
          return;
        }
        bloc.add(DeleteVaultEntry(entryId));
    }
  }

  Future<void> _handleEntryAction(
    BuildContext context,
    String entryId,
    _EntryAction action,
  ) => _handleEntryActionOn(
    context,
    context.read<VaultBloc>(),
    entryId,
    action,
    widget.groups,
  );

  /// spec-018 FR-001a: activating a row reports the id upward. The card no
  /// longer decides how — or whether — a detail is shown; that is the
  /// shell's single decision, so push and pane cannot diverge (D1, D9).
  void _openEntry(VaultEntry entry) => widget.onSelectEntry(entry.id);

  /// spec-019 T026 / FR-007 — the records list renders records.
  ///
  /// It used to render the group tree too: folder rows, a grouping walk, an
  /// auto-expanding search and per-folder action menus, all inside the card
  /// that is supposed to be a list of records (C-03-03). Folders now have
  /// their own column; `state.visibleEntries` arrives already filtered by the
  /// selected subtree, already searched and already sorted, and this method
  /// lays it out.
  Widget _buildEntriesList(BuildContext context) {
    // File-system mode: subfolders of the current folder first, then the
    // folder's own records. A live search stays flat over the subtree —
    // folder rows in search results would be noise.
    final browsing = widget.folderBrowser && widget.searchQuery.isEmpty;
    final effectiveGroupId = widget.currentGroupId ?? widget.rootGroupId;

    var childFolders = const <VaultGroup>[];
    var records = widget.entries;
    if (browsing && effectiveGroupId != null) {
      childFolders =
          widget.groups
              .where(
                (group) =>
                    group.parentId == effectiveGroupId && !group.isRecycleBin,
              )
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
      records = widget.entries
          .where((entry) => entry.groupId == effectiveGroupId)
          .toList(growable: false);
    }

    // A folder with no subfolders and no direct records must show the empty
    // state too, not a zero-item ListView (PR #180 review finding).
    final showEmpty = browsing
        ? (effectiveGroupId == null ||
              (childFolders.isEmpty && records.isEmpty))
        : widget.entries.isEmpty;
    if (showEmpty) {
      final emptyState = _RecordsEmptyState(
        searchQuery: widget.searchQuery,
        onClearSearch: widget.searchQuery.isNotEmpty
            ? () {
                context.read<VaultBloc>().add(const ClearVaultSearchQuery());
              }
            : null,
      );

      return LayoutBuilder(
        builder: (context, constraints) {
          final minHeight = constraints.maxHeight > 32
              ? constraints.maxHeight - 32
              : 0.0;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Center(child: emptyState),
            ),
          );
        },
      );
    }

    final groupNames = <String, String>{
      for (final group in widget.groups) group.id: group.name,
    };

    final bottomInset = MediaQuery.viewPaddingOf(context).bottom + 12;
    final list = ListView.separated(
      controller: _entriesScrollController,
      padding: EdgeInsets.only(bottom: bottomInset),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: browsing
          ? childFolders.length + records.length
          : widget.entries.length,
      separatorBuilder: (_, _) =>
          const SizedBox(height: _VaultUiTokens.recordListSpacing),
      itemBuilder: (context, index) {
        if (browsing) {
          final folderIndex = index;
          if (folderIndex < childFolders.length) {
            final folder = childFolders[folderIndex];
            return _FolderListItem(
              folder: folder,
              count: widget.folderCounts[folder.id] ?? 0,
              onOpen: () =>
                  context.read<VaultBloc>().add(SelectVaultFolder(folder.id)),
              onAction: (action) => unawaited(
                _handleFolderAction(
                  context,
                  groups: widget.groups,
                  groupId: folder.id,
                  action: action,
                ),
              ),
            );
          }
          final entry = records[folderIndex - childFolders.length];
          return _RecordListItem(
            entry: entry,
            isSelected: widget.selectedEntryId == entry.id,
            folderSuffix: null,
            onOpen: () => _openEntry(entry),
            onSelectedAction: (action) {
              _handleEntryAction(context, entry.id, action);
            },
          );
        }
        final entry = widget.entries[index];
        return _RecordListItem(
          entry: entry,
          isSelected: widget.selectedEntryId == entry.id,
          // FR-006j: a record shown because it lives *below* the selected
          // folder says where it actually lives. Without this the subtree
          // filter silently mixes two folders' records into one list.
          folderSuffix: widget.subfolderIds.contains(entry.groupId)
              ? groupNames[entry.groupId]
              : null,
          onOpen: () => _openEntry(entry),
          onSelectedAction: (action) {
            _handleEntryAction(context, entry.id, action);
          },
        );
      },
    );

    return NotificationListener<ScrollStartNotification>(
      onNotification: (_) {
        FocusScope.of(context).unfocus();
        return false;
      },
      child: Scrollbar(controller: _entriesScrollController, child: list),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(_VaultUiTokens.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final searchField = TextFormField(
                controller: _searchController,
                decoration: InputDecoration(
                  // FR-008 / C-03-05: the field says how much it is searching.
                  labelText: 'Search ${widget.entries.length} items',
                  prefixIcon: const Icon(AppIcons.search),
                  suffixIcon: widget.searchQuery.isNotEmpty
                      ? Tooltip(
                          message: 'Clear search',
                          ignorePointer: true,
                          child: IconButton(
                            onPressed: () {
                              context.read<VaultBloc>().add(
                                const ClearVaultSearchQuery(),
                              );
                            },
                            icon: const Icon(AppIcons.close),
                          ),
                        )
                      : null,
                ),
                onChanged: (value) {
                  context.read<VaultBloc>().add(UpdateVaultSearchQuery(value));
                },
              );

              // 2026-08-31: sort and add sit beside the search at EVERY
              // width — the count line lost its inline sort control and the
              // narrow list header its buttons.
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: searchField),
                  const SizedBox(width: 8),
                  _SortMenuButton(sortBy: widget.sortBy),
                  const SizedBox(width: 8),
                  KvCircleIconButton(
                    glyph: AppGlyph.add,
                    tooltip: 'Add record',
                    filled: true,
                    size: 32,
                    iconSize: 17,
                    onPressed: widget.onAddRecord,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          // 2026-08-31: the browser's location header — back, the current
          // folder's name as the title, and the folder's own `•••` — instead
          // of an up-row and a name squeezed into the count line.
          if (widget.folderBrowser && widget.searchQuery.isEmpty)
            Builder(
              builder: (context) {
                final effectiveGroupId =
                    widget.currentGroupId ?? widget.rootGroupId;
                final current = widget.groups
                    .where((group) => group.id == effectiveGroupId)
                    .firstOrNull;
                if (current == null) return const SizedBox.shrink();
                final isRoot = effectiveGroupId == widget.rootGroupId;
                final parentId = current.parentId ?? widget.rootGroupId;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _BrowserFolderTitle(
                    name: current.name,
                    count: widget.folderCounts[effectiveGroupId] ?? 0,
                    isRoot: isRoot,
                    onBack: isRoot
                        ? null
                        : () => context.read<VaultBloc>().add(
                            SelectVaultFolder(parentId!),
                          ),
                    onAction: (action) => unawaited(
                      _handleFolderAction(
                        context,
                        groups: widget.groups,
                        groupId: effectiveGroupId!,
                        action: action,
                      ),
                    ),
                  ),
                );
              },
            ),
          // 2026-08-31: no count line anywhere — the search field's own
          // label carries the count, and the browser's location header
          // carries the current folder's.

          // spec-018 D1/FR-001a: this used to branch on the card's OWN
          // constraints and render a second, router-unaware detail beside
          // the list. That second mechanism is why selection, dismissal and
          // nesting drifted apart on wide windows. The card now renders the
          // list and nothing else; the shell owns the detail.
          Expanded(child: _buildEntriesList(context)),
        ],
      ),
    );

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_VaultUiTokens.cardRadius),
      ),
      child: content,
    );
  }
}

// spec-019 C-04-05: `duplicate` joins the record actions. The design's
// normative overflow inventory for the detail is `Move / Delete / Duplicate`;
// the list row offers the same set it always did, plus this.
enum _EntryAction { edit, move, duplicate, delete, info }

OverlayEntry? _activeCopyToastEntry;
Timer? _activeCopyToastTimer;

void _showCenteredCopyToast(BuildContext context, String message) {
  _hideCenteredCopyToast();

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    return;
  }

  _activeCopyToastEntry = OverlayEntry(
    builder: (overlayContext) {
      final theme = Theme.of(overlayContext);
      final colorScheme = theme.colorScheme;
      final reduceMotion =
          MediaQuery.maybeOf(overlayContext)?.disableAnimations ?? false;

      return Positioned.fill(
        child: IgnorePointer(
          child: SafeArea(
            minimum: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.92, end: 1),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                builder: (animationContext, scale, child) {
                  final opacity = reduceMotion
                      ? 1.0
                      : ((scale - 0.92) / 0.08).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: opacity,
                    child: Transform.scale(scale: scale, child: child),
                  );
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh.withValues(
                        alpha: 0.96,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.58,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: colorScheme.shadow.withValues(alpha: 0.2),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: colorScheme.primary.withValues(
                                alpha: 0.14,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              AppIcons.check,
                              size: 15,
                              color: colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              message,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(_activeCopyToastEntry!);
  _activeCopyToastTimer = Timer(const Duration(milliseconds: 1600), () {
    _hideCenteredCopyToast();
  });
}

void _hideCenteredCopyToast() {
  _activeCopyToastTimer?.cancel();
  _activeCopyToastTimer = null;
  _activeCopyToastEntry?.remove();
  _activeCopyToastEntry = null;
}

/// spec-019 T027/T028 — the line between the search field and the list:
/// how many records are shown, and in what order.
///
/// The order was already in the state and already applied

/// The sort control: the design's neutral circle button (KvCircleIconButton,
/// same as every other) anchoring the checked sort menu.
class _SortMenuButton extends StatelessWidget {
  const _SortMenuButton({required this.sortBy});

  final VaultEntrySort sortBy;

  Future<void> _openMenu(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final bloc = context.read<VaultBloc>();
    final value = await showMenu<VaultEntrySort>(
      context: context,
      position: position,
      initialValue: sortBy,
      items: [
        for (final option in VaultEntrySort.values)
          CheckedPopupMenuItem<VaultEntrySort>(
            value: option,
            checked: option == sortBy,
            child: Text(vaultSortLabel(option)),
          ),
      ],
    );
    if (value != null) {
      bloc.add(SetVaultSort(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    return KvCircleIconButton(
      glyph: AppGlyph.sort,
      tooltip: 'Sort records',
      // nested: the list card's own fill IS `surface`, so the plain variant
      // disappeared into it.
      nested: true,
      size: 32,
      iconSize: 17,
      onPressed: () => unawaited(_openMenu(context)),
    );
  }
}

/// The three orders the vault has always had (research R2). Spec 019 surfaces
/// them; it adds none and renames none.
String vaultSortLabel(VaultEntrySort sort) => switch (sort) {
  VaultEntrySort.titleAsc => 'Title A→Z',
  VaultEntrySort.titleDesc => 'Title Z→A',
  VaultEntrySort.usernameAsc => 'Username A→Z',
};

/// spec-019 T045 / FR-002a — create a record in the folder that is selected.
///
/// This absorbs the `Add record` action that used to hang off a folder row in
/// the list. It needs no `OpenGroup` first: `CreateVaultEntry` files into
/// `state.currentGroupId`, and that is never null — with `All items` selected
/// it is the root group, which is exactly why FR-002a insists on the root id
/// rather than a null (`vault_bloc.dart` `_onCreateVaultEntry`).
Future<void> _createRecordInCurrentFolder(BuildContext context) async {
  final bloc = context.read<VaultBloc>();
  final payload = await _showEntryDialog(context);
  if (payload == null) {
    return;
  }
  bloc.add(
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
}

/// 2026-08-31 — a folder as a row of the 1/2-column list: same surface,
/// radius and hover recipe as [_RecordListItem], a folder-glyph avatar, the
/// inclusive count, and the same `•••` action menu the folder tree carries.
class _FolderListItem extends StatelessWidget {
  const _FolderListItem({
    required this.folder,
    required this.count,
    required this.onOpen,
    required this.onAction,
  });

  final VaultGroup folder;
  final int count;
  final VoidCallback onOpen;
  final ValueChanged<KvFolderAction> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Semantics(
      button: true,
      label: 'Folder ${folder.name}',
      child: _InteractiveItemSurface(
        radius: AppRadii.row,
        minHeight: 62,
        onTap: onOpen,
        baseColor: colors.surface,
        hoveredColor: colors.surface,
        baseBorderColor: Colors.transparent,
        hoveredBorderColor: colors.selectionBorder.withValues(alpha: 0.5),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.surfaceNested,
                  shape: BoxShape.circle,
                ),
                child: KvIcon(
                  glyph: AppGlyph.folder,
                  size: 18,
                  color: colors.iconNeutral,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.rowTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$count',
                style: AppTextStyles.meta.copyWith(color: colors.textTertiary),
              ),
              SizedBox(
                width: 44,
                height: 44,
                child: KvContextMenu(
                  tooltip: 'Folder actions',
                  icon: KvIcon(
                    glyph: AppGlyph.more,
                    size: 17,
                    color: colors.iconNeutral,
                  ),
                  items: [
                    KvContextMenuItem(
                      label: 'New folder',
                      onSelected: () => onAction(KvFolderAction.newFolder),
                    ),
                    KvContextMenuItem(
                      label: 'Rename',
                      onSelected: () => onAction(KvFolderAction.rename),
                    ),
                    KvContextMenuItem(
                      label: 'Move',
                      onSelected: () => onAction(KvFolderAction.move),
                    ),
                    KvContextMenuItem(
                      label: 'Delete',
                      destructive: true,
                      onSelected: () => onAction(KvFolderAction.delete),
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

/// The browser's location header: back to the parent, the current folder's
/// name as the title, and the folder's own `•••` action menu. The root shows
/// its name with no back and keeps only the actions that can apply to it.
class _BrowserFolderTitle extends StatelessWidget {
  const _BrowserFolderTitle({
    required this.name,
    required this.count,
    required this.isRoot,
    required this.onBack,
    required this.onAction,
  });

  final String name;

  /// The folder's inclusive record count — the same number its row in the
  /// list shows, on the same line as the name.
  final int count;

  final bool isRoot;
  final VoidCallback? onBack;
  final ValueChanged<KvFolderAction> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Row(
      children: [
        if (onBack != null) ...[
          KvCircleIconButton(
            glyph: AppGlyph.back,
            tooltip: 'Back',
            nested: true,
            size: 32,
            iconSize: 16,
            onPressed: onBack,
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.panelTitle.copyWith(color: colors.textPrimary),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count',
          style: AppTextStyles.meta.copyWith(color: colors.textTertiary),
        ),
        // Same 44 box as the list rows' `•••`, so the dots line up.
        SizedBox(
          width: 44,
          height: 44,
          child: KvContextMenu(
            tooltip: 'Folder actions',
            icon: KvIcon(
              glyph: AppGlyph.more,
              size: 17,
              color: colors.iconNeutral,
            ),
            items: [
              KvContextMenuItem(
                label: 'New folder',
                onSelected: () => onAction(KvFolderAction.newFolder),
              ),
              KvContextMenuItem(
                label: 'Rename',
                onSelected: () => onAction(KvFolderAction.rename),
              ),
              if (!isRoot) ...[
                KvContextMenuItem(
                  label: 'Move',
                  onSelected: () => onAction(KvFolderAction.move),
                ),
                KvContextMenuItem(
                  label: 'Delete',
                  destructive: true,
                  onSelected: () => onAction(KvFolderAction.delete),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
