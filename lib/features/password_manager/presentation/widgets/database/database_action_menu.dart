import 'package:flutter/material.dart';

import '../../../../../../core/theme/app_glyph.dart';
import '../../../../../../core/theme/custode_colors.dart';
import '../../../../../../core/widgets/kv_context_menu.dart';
import '../../../../../../core/widgets/kv_icon.dart';

/// 2026-08-31: restyled onto the design system's [KvContextMenu] — the same
/// surface, hover and destructive cue the vault's row menus use — instead of
/// the stock `PopupMenuButton`.
class DatabaseActionMenu extends StatelessWidget {
  const DatabaseActionMenu({
    super.key,
    required this.onOpen,
    required this.onExport,
    required this.onRemove,
    this.onLocate,
  });

  final VoidCallback onOpen;
  final VoidCallback onExport;
  final VoidCallback onRemove;

  /// Only present for `isMissing` items (FR-1 Locate).
  final VoidCallback? onLocate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return SizedBox(
      width: 44,
      height: 44,
      child: KvContextMenu(
        tooltip: 'More actions',
        icon: KvIcon(glyph: AppGlyph.more, size: 17, color: colors.iconNeutral),
        items: [
          if (onLocate != null)
            KvContextMenuItem(label: 'Locate', onSelected: onLocate!),
          KvContextMenuItem(label: 'Open', onSelected: onOpen),
          KvContextMenuItem(label: 'Export', onSelected: onExport),
          KvContextMenuItem(
            label: 'Remove',
            destructive: true,
            onSelected: onRemove,
          ),
        ],
      ),
    );
  }
}
