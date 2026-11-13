import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_glyph.dart';
import '../theme/app_radii.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';
import 'kv_context_menu.dart';
import 'kv_icon.dart';

/// spec-019 T014 — the folder tree, in one widget, for all three of its hosts.
///
/// The desktop folder column, the phone `Folders` sheet and `Manage folders`
/// render the same tree; before this widget they were three separate builders
/// that agreed by hand, and the audit found them disagreeing (C-03-07,
/// C-03-11). Everything host-specific is a flag here, so "one selected-row
/// style, one `•••` recipe" (FR-006k) holds by construction.
///
/// The widget renders [nodes] and reports. It does not fetch, does not know
/// about the BLoC, and does not decide what selection means for the records
/// list (contract `folder-tree.md`, Non-goals).
///
/// Rows carry the `•••` action menu exactly when [KvFolderTree.onRowAction]
/// is provided — the tree IS the management surface now (2026-08-30, Manage
/// dialog retired); a host that passes no callback gets a pure filter tree.

/// The row actions offered by the `•••` menu.
///
/// Order is part of the contract (G2) and the labels are the ones the vault
/// already uses (Constitution VI). `newFolder` creates a child of the row's
/// folder — it moved here from the Manage header (2026-08-30 walk), so the
/// action names its parent instead of inheriting a hidden "current" one.
enum KvFolderAction { newFolder, rename, move, delete }

/// One row of the tree: a folder flattened out of the group graph.
@immutable
class KvFolderNode {
  const KvFolderNode({
    required this.id,
    required this.name,
    required this.count,
    required this.depth,
    this.hasChildren = false,
    this.isExpanded = false,
    this.canReparent = true,
  });

  final String id;
  final String name;

  /// Records in this folder **and all its descendants** (FR-006i).
  final int count;

  /// 0 for a top-level folder; drives indentation and nothing else (G5).
  final int depth;

  final bool hasChildren;

  /// The caller flattens only the rows it wants visible; this flag is what
  /// the chevron points at.
  final bool isExpanded;

  /// False for the vault's root group, which has no parent to move to and
  /// cannot be deleted. Its row keeps `Rename` and drops the other two —
  /// offering a user an action that cannot succeed is worse than not offering
  /// it (G2, amended).
  final bool canReparent;
}

class KvFolderTree extends StatelessWidget {
  const KvFolderTree({
    super.key,
    required this.nodes,
    required this.selectedId,
    required this.onSelect,
    required this.onToggleExpanded,
    this.onRowAction,
  });

  final List<KvFolderNode> nodes;

  /// The selected group id. `All items` is the root group's id, never null
  /// (FR-002a) — see `VaultBloc._onSelectVaultFolder`.
  final String? selectedId;

  final ValueChanged<String> onSelect;

  /// Called by the chevron only, never by the row (G3).
  final void Function(String id, bool expanded) onToggleExpanded;

  /// When non-null every row carries the `•••` action menu; when null the
  /// tree is a pure filter (G1).
  final void Function(String id, KvFolderAction action)? onRowAction;

  /// One level of indentation per depth (G5). Wide enough that the chevron of
  /// a child clears the label of its parent.
  static const double indentPerDepth = 18;

  /// Constitution V: both the chevron and the row are ≥ 44 × 44, and they do
  /// not overlap (G7) — the chevron is laid out beside the row's tap target,
  /// not on top of it.
  static const double minTarget = 44;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final node in nodes)
          _KvFolderRow(
            node: node,
            isSelected: node.id == selectedId,
            onSelect: () => onSelect(node.id),
            onToggleExpanded: () => onToggleExpanded(node.id, !node.isExpanded),
            onAction: onRowAction == null
                ? null
                : (action) => onRowAction!(node.id, action),
          ),
      ],
    );
  }
}

class _KvFolderRow extends StatefulWidget {
  const _KvFolderRow({
    required this.node,
    required this.isSelected,
    required this.onSelect,
    required this.onToggleExpanded,
    required this.onAction,
  });

  final KvFolderNode node;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onToggleExpanded;
  final ValueChanged<KvFolderAction>? onAction;

  @override
  State<_KvFolderRow> createState() => _KvFolderRowState();
}

class _KvFolderRowState extends State<_KvFolderRow> {
  bool _hovered = false;

  KvFolderNode get node => widget.node;
  bool get isSelected => widget.isSelected;
  VoidCallback get onSelect => widget.onSelect;
  VoidCallback get onToggleExpanded => widget.onToggleExpanded;
  ValueChanged<KvFolderAction>? get onAction => widget.onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final showsChevron = node.hasChildren;

    final label = Text(
      node.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.rowTitle.copyWith(
        // G6: one selected style at every host — accent-200 fill, accent-800
        // semibold text, an inline folder glyph, no square icon tile.
        color: isSelected ? AppColors.accent800 : colors.textPrimary,
        fontWeight: isSelected ? FontWeight.w600 : null,
      ),
    );

    final row = Container(
      constraints: const BoxConstraints(minHeight: KvFolderTree.minTarget),
      padding: const EdgeInsets.fromLTRB(0, 6, 10, 6),
      child: Row(
        children: [
          KvIcon(
            glyph: AppGlyph.folder,
            size: 17,
            color: isSelected ? AppColors.accent800 : colors.iconNeutral,
          ),
          const SizedBox(width: 8),
          Expanded(child: label),
          const SizedBox(width: 8),
          Text(
            '${node.count}',
            style: AppTextStyles.meta.copyWith(
              color: isSelected ? AppColors.accent800 : colors.textTertiary,
            ),
          ),
        ],
      ),
    );

    // 2026-08-30: the chevron moved INSIDE the decorated row — hover and
    // selection paint one shape around everything the row owns, chevron and
    // `•••` included. Both buttons still win their own taps over the row's
    // InkWell, so the targets stay distinct even though the fill is one.
    final chevron = SizedBox(
      width: KvFolderTree.minTarget,
      height: KvFolderTree.minTarget,
      child: showsChevron
          ? IconButton(
              onPressed: onToggleExpanded,
              padding: EdgeInsets.zero,
              tooltip: node.isExpanded
                  ? 'Collapse ${node.name}'
                  : 'Expand ${node.name}',
              icon: KvIcon(
                glyph: node.isExpanded
                    ? AppGlyph.chevronDown
                    : AppGlyph.chevronRight,
                size: 16,
                color: colors.textTertiary,
              ),
            )
          : null,
    );

    return Padding(
      padding: EdgeInsets.only(
        left: node.depth * KvFolderTree.indentPerDepth,
        bottom: 2,
      ),
      child: Row(
        children: [
          // G6, tightened 2026-08-30: the selection fill spans the whole
          // interactive row — chevron and `•••` included — not just the label
          // span, so nothing looks detached from the row it acts on.
          Expanded(
            child: DecoratedBox(
              // 2026-08-31: same hover/selected recipe as the records list —
              // selected is accent-200 fill with an accent-400 border, hover
              // is a half-alpha selection border on a transparent fill,
              // never a solid wash.
              decoration: BoxDecoration(
                color: isSelected ? AppColors.accent200 : Colors.transparent,
                border: Border.all(
                  color: isSelected
                      ? AppColors.accent400
                      : _hovered
                      ? colors.selectionBorder.withValues(alpha: 0.5)
                      : Colors.transparent,
                ),
                borderRadius: BorderRadius.circular(AppRadii.iconSquare),
              ),
              // The InkWell spans the whole decorated row — `•••` included —
              // so hover and press read as one row, not just the label span.
              // The menu button sits inside it and wins its own taps.
              child: Semantics(
                // G8: the selection is announced, not only painted.
                // Colour alone is not a signal (Constitution V).
                selected: isSelected,
                button: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onSelect,
                    onHover: (hovered) => setState(() => _hovered = hovered),
                    // The hover state paints the border above — a solid
                    // hoverColor wash here would fight the records recipe.
                    hoverColor: Colors.transparent,
                    // When a dialog opened from this row closes, focus falls
                    // back here and the theme's focusColor (accent-400) would
                    // stay painted until the next click — a row that reads as
                    // stuck. Keyboard focus stays visible on the row's own
                    // buttons, which carry the theme's focus border.
                    focusColor: Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadii.iconSquare),
                    child: Row(
                      children: [
                        chevron,
                        Expanded(child: row),
                        if (onAction != null)
                          SizedBox(
                            width: KvFolderTree.minTarget,
                            height: KvFolderTree.minTarget,
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
                                  onSelected: () =>
                                      onAction!(KvFolderAction.newFolder),
                                ),
                                KvContextMenuItem(
                                  label: 'Rename',
                                  onSelected: () =>
                                      onAction!(KvFolderAction.rename),
                                ),
                                if (node.canReparent) ...[
                                  KvContextMenuItem(
                                    label: 'Move',
                                    onSelected: () =>
                                        onAction!(KvFolderAction.move),
                                  ),
                                  KvContextMenuItem(
                                    label: 'Delete',
                                    destructive: true,
                                    onSelected: () =>
                                        onAction!(KvFolderAction.delete),
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
