part of '../vault_screen.dart';

// spec-019 T022-T024 — the desktop folder column, the phone chip row and the
// phone `Folders` sheet: the three hosts of one tree.
//
// What used to stand here was a `ListView` of raw `ListTile`s under a literal
// `Folders` title, flat, uncounted and unstyled (C-03-07, C-03-11), while the
// real folder navigation was mixed into the records list. The column is now
// the folder surface, and the list is a list of records.

/// Fallback label for the vault's own root, shown first and selected by
/// default, when the root group is somehow absent from `state.groups`.
///
/// The row is not a pseudo-folder with a null id: it IS the root group —
/// shown under its real name — so `CreateVaultEntry` has a group to file into
/// and the count it shows is the root's own inclusive count (FR-002a,
/// FR-002).
const _kAllItemsLabel = 'All items';

/// spec-019 FR-001/FR-002/FR-003/FR-004/FR-006a — the folder column.
class _VaultFolderColumn extends StatelessWidget {
  const _VaultFolderColumn();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<VaultBloc, VaultState>(
      buildWhen: _folderSurfaceBuildWhen,
      builder: (context, state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              // 2026-08-31: 26 aligns the column's first element with the
              // list card's search field and the detail's header row — the
              // three sections share one visual top.
              padding: const EdgeInsets.fromLTRB(14, 26, 14, 4),
              // FR-001, amended 2026-08-31: one widget for the vault's name
              // and sync status, shared with the 1/2-column list header.
              child: _VaultNameHeader(titleStyle: AppTextStyles.panelTitle),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _VaultFolderTreeSection(state: state),
              ),
            ),
            const _VaultVerticalSpacer(),
            _VaultHygieneShortcuts(state: state),
          ],
        );
      },
    );
  }
}

class _VaultVerticalSpacer extends StatelessWidget {
  const _VaultVerticalSpacer();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Divider(
      height: 17,
      thickness: 1,
      color: Theme.of(context).extension<CustodeColors>()!.divider,
    ),
  );
}

/// `All items` plus the tree, in one [KvFolderTree] so the first row obeys the
/// same selected-row recipe as every other (FR-006k).
class _VaultFolderTreeSection extends StatelessWidget {
  const _VaultFolderTreeSection({required this.state});

  final VaultState state;

  @override
  Widget build(BuildContext context) {
    final rootGroupId = state.rootGroupId;
    if (rootGroupId == null) {
      return const SizedBox.shrink();
    }

    final rootName = state.groups
        .where((group) => group.id == rootGroupId)
        .map((group) => group.name)
        .firstOrNull;

    final nodes = <KvFolderNode>[
      KvFolderNode(
        id: rootGroupId,
        name: rootName ?? _kAllItemsLabel,
        count: state.totalCount,
        depth: 0,
        // The vault's own root: renamable, but there is nowhere to move it
        // to and deleting it would delete the vault's contents.
        canReparent: false,
      ),
      // One level under the root row, so the root reads as what it is: the
      // parent of every other folder.
      ..._flattenFolderNodes(
        groups: state.groups,
        rootGroupId: rootGroupId,
        counts: state.folderCounts,
        expandedIds: state.expandedGroupIds.toSet(),
        startDepth: 1,
      ),
    ];

    return KvFolderTree(
      nodes: nodes,
      // FR-002a: never null. An unknown or deleted folder falls back to the
      // root, which is `All items`.
      selectedId: state.currentGroupId ?? rootGroupId,
      onSelect: (id) => context.read<VaultBloc>().add(SelectVaultFolder(id)),
      onToggleExpanded: (id, expanded) => context.read<VaultBloc>().add(
        SetVaultFolderExpanded(id, expanded: expanded),
      ),
      // 2026-08-30: `Manage folders` retired — the tree carries its own row
      // actions, same handlers, same dialogs.
      onRowAction: (id, action) => unawaited(
        _handleFolderAction(
          context,
          groups: state.groups,
          groupId: id,
          action: action,
        ),
      ),
    );
  }
}

/// FR-004 — the two hygiene shortcuts, at the foot of the column where the
/// design puts them, carrying the counts the state already holds.
class _VaultHygieneShortcuts extends StatelessWidget {
  const _VaultHygieneShortcuts({required this.state});

  final VaultState state;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    Widget shortcut({
      required String label,
      required AppGlyph glyph,
      required int count,
      required VoidCallback onTap,
    }) {
      return Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            // Same stuck-focus guard as the folder tree rows: the dialogs
            // these open hand focus back here on close.
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.iconSquare),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  KvIcon(glyph: glyph, size: 17, color: colors.iconNeutral),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.rowTitle.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    '$count',
                    style: AppTextStyles.meta.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          shortcut(
            label: 'Recycle bin',
            glyph: AppGlyph.delete,
            count: state.recycleBinEntries.length,
            onTap: () => unawaited(_showRecycleBinDialog(context)),
          ),
          shortcut(
            label: 'Duplicates',
            glyph: AppGlyph.duplicates,
            count: state.duplicateGroups.length,
            onTap: () => unawaited(_showDuplicatesDialog(context)),
          ),
        ],
      ),
    );
  }
}

bool _folderSurfaceBuildWhen(VaultState previous, VaultState current) {
  return previous.isDriveLinked != current.isDriveLinked ||
      previous.lastSyncAt != current.lastSyncAt ||
      previous.groups != current.groups ||
      previous.currentGroupId != current.currentGroupId ||
      previous.expandedGroupIds != current.expandedGroupIds ||
      previous.folderCounts != current.folderCounts ||
      previous.databasePath != current.databasePath ||
      previous.recycleBinEntries != current.recycleBinEntries ||
      previous.duplicateGroups != current.duplicateGroups;
}

/// Flattens the group tree into the rows [KvFolderTree] renders.
///
/// Shared by the desktop folder column and the phone `Folders` sheet, so the
/// hosts cannot disagree about order, depth or counts. The recycle bin is
/// never a row here: it is one of the hygiene shortcuts at the foot of the
/// column, not a folder you file things in.
List<KvFolderNode> _flattenFolderNodes({
  required List<VaultGroup> groups,
  required String rootGroupId,
  required Map<String, int> counts,
  required Set<String> expandedIds,
  int startDepth = 0,
}) {
  final bin = <String>{};
  for (final group in groups) {
    if (group.isRecycleBin) {
      bin.add(group.id);
    }
  }
  // Descendants of the bin are in the bin.
  var grew = true;
  while (grew) {
    grew = false;
    for (final group in groups) {
      final parentId = group.parentId;
      if (parentId != null && bin.contains(parentId) && bin.add(group.id)) {
        grew = true;
      }
    }
  }

  final children = <String, List<VaultGroup>>{};
  for (final group in groups) {
    if (bin.contains(group.id) || group.parentId == null) {
      continue;
    }
    (children[group.parentId!] ??= <VaultGroup>[]).add(group);
  }
  for (final siblings in children.values) {
    siblings.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  final nodes = <KvFolderNode>[];
  void walk(String parentId, int depth) {
    for (final group in children[parentId] ?? const <VaultGroup>[]) {
      final hasChildren = (children[group.id] ?? const []).isNotEmpty;
      final isExpanded = expandedIds.contains(group.id);
      nodes.add(
        KvFolderNode(
          id: group.id,
          name: group.name,
          count: counts[group.id] ?? 0,
          depth: depth,
          hasChildren: hasChildren,
          isExpanded: isExpanded,
        ),
      );
      // A collapsed node's children are not rows at all, which is what keeps
      // the chevron meaningful rather than decorative.
      if (hasChildren && isExpanded) {
        walk(group.id, depth + 1);
      }
    }
  }

  walk(rootGroupId, startDepth);
  return nodes;
}

/// `New folder` from a row's `•••`: the new folder is created inside that
/// row, named explicitly, instead of inheriting whatever folder happened to
/// be selected.
Future<void> _createFolderInside(
  BuildContext context, {
  required String parentGroupId,
}) async {
  final name = await _showGroupDialog(context);
  if (name == null || name.name.trim().isEmpty || !context.mounted) {
    return;
  }
  context.read<VaultBloc>().add(
    CreateVaultGroup(name.name.trim(), parentGroupId: parentGroupId),
  );
}

/// Routes the tree's row actions to the handlers the vault already has, so
/// `Rename`, `Move` and `Delete` keep their existing dialogs, their existing
/// confirmations and their existing strings (FR-006d, Constitution VI and
/// VII). The root row reaches here too: it is in `groups` like any other, and
/// its `canReparent: false` already stripped `Move` and `Delete` from its
/// menu.
Future<void> _handleFolderAction(
  BuildContext context, {
  required List<VaultGroup> groups,
  required String groupId,
  required KvFolderAction action,
}) async {
  final group = groups.where((candidate) => candidate.id == groupId);
  if (group.isEmpty) {
    return;
  }

  if (action == KvFolderAction.newFolder) {
    await _createFolderInside(context, parentGroupId: groupId);
    return;
  }

  await _handleChildGroupAction(
    context,
    group: group.first,
    action: switch (action) {
      KvFolderAction.newFolder => throw StateError('handled above'),
      KvFolderAction.rename => _ChildGroupAction.rename,
      KvFolderAction.move => _ChildGroupAction.move,
      KvFolderAction.delete => _ChildGroupAction.delete,
    },
    allGroups: groups,
  );
}
