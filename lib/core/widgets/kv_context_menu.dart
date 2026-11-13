import 'package:flutter/material.dart';

import '../theme/app_radii.dart';
import '../theme/app_text_styles.dart';
import '../theme/custode_colors.dart';

/// One entry of a [KvContextMenu].
@immutable
class KvContextMenuItem {
  const KvContextMenuItem({
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onSelected;

  /// Rendered in the error colour (the vault's one destructive-action cue).
  final bool destructive;
}

/// The design system's context menu: same surface recipe as
/// `popupMenuTheme` (surface fill, divider border, [AppRadii.rowNested]
/// corners), but with rounded hover on each item — `PopupMenuItem` paints
/// its hover as a full-width rectangle and offers no way to shape it, which
/// is why this exists instead of a theme tweak.
class KvContextMenu extends StatelessWidget {
  const KvContextMenu({
    super.key,
    required this.items,
    required this.icon,
    required this.tooltip,
  });

  final List<KvContextMenuItem> items;
  final Widget icon;
  final String tooltip;

  /// The item hover sits 4px inside the 16px menu surface, so its own radius
  /// is the difference — concentric corners, not a second arbitrary value.
  static const double _itemRadius = AppRadii.rowNested - 4;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return MenuAnchor(
      // A tap outside closes the menu and stops there — without this the
      // same tap falls through to whatever is behind (a dialog barrier,
      // another row) and does a second thing the user did not aim at.
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        side: WidgetStatePropertyAll(BorderSide(color: colors.divider)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.rowNested),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        ),
      ),
      menuChildren: [
        for (final item in items)
          MenuItemButton(
            onPressed: item.onSelected,
            // Hover lives on the button's background, not its ink overlay:
            // the background is painted by the button's own Material with
            // this shape, so the rounded corners are guaranteed — the ink
            // overlay ignores the shape and paints a full rectangle.
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(160, 40)),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 12),
              ),
              alignment: Alignment.centerLeft,
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_itemRadius),
                ),
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused) ||
                        states.contains(WidgetState.pressed)
                    ? colors.actionFill
                    : Colors.transparent,
              ),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              textStyle: const WidgetStatePropertyAll(AppTextStyles.body),
              foregroundColor: WidgetStatePropertyAll(
                item.destructive
                    ? Theme.of(context).colorScheme.error
                    : colors.textPrimary,
              ),
            ),
            child: Text(item.label),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tooltip,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        padding: EdgeInsets.zero,
        icon: icon,
      ),
    );
  }
}
