import 'package:material_ui/material_ui.dart';

import '../../../../../../core/theme/app_glyph.dart';
import '../../../../../../core/theme/app_radii.dart';
import '../../../../../../core/widgets/kv_icon.dart';
import '../../../../../../core/theme/app_text_styles.dart';
import '../../../../../../core/theme/custode_colors.dart';
import '../../../../../../core/widgets/kv_tag.dart';
import '../../../domain/models/database_selection_item.dart';
import '../entry/strength_strip.dart' show describeTimeAgo;
import 'database_action_menu.dart';

/// FR-L3 status line: `Synced <relative>` or the existing sync error for a
/// remote database, nothing for a local one. Where the database lives is the
/// group header's job, and credentials are tags.
String? databaseStatusLine(DatabaseSelectionItem item, {DateTime? now}) {
  if (item.remoteProviderId == null) return null;
  final error = item.lastSyncError?.trim();
  if (error != null && error.isNotEmpty) return error;
  final lastSyncAt = item.lastSyncAt;
  if (lastSyncAt == null) return null;
  // `describeTimeAgo` words an entry's password age ("changed today").
  final ago = describeTimeAgo(lastSyncAt, now ?? DateTime.now());
  return 'Synced ${ago.replaceFirst('changed ', '')}';
}

class DatabaseItemTile extends StatelessWidget {
  const DatabaseItemTile({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onExport,
    required this.onRemove,
    this.onLocate,
  });

  final DatabaseSelectionItem item;
  final Future<void> Function() onOpen;
  final Future<void> Function() onExport;
  final Future<void> Function() onRemove;

  /// The `Locate` action of a missing row (FR-L4). Tapping the row itself
  /// still calls [onOpen]: Unlock owns the full repair state.
  final Future<void> Function()? onLocate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final missing = item.isMissing;
    final active = item.isActive && !missing;
    final status = missing ? 'File not found' : databaseStatusLine(item);
    final tagVariant = active ? KvTagVariant.accent : KvTagVariant.nested;
    final tags = [
      if (!missing && item.biometricProtectionEnabled)
        KvTag(label: 'Biometrics', variant: tagVariant),
      if (!missing && item.keyFileConfigured)
        KvTag(label: 'Key file', variant: tagVariant),
    ];

    return Semantics(
      button: true,
      label: item.displayName,
      value: item.canonicalPath,
      child: _HoverSurface(
        onTap: () => onOpen(),
        baseColor: active ? colors.attentionTint : colors.surface,
        // Active row: tint alone is too close to the background, so the
        // selection border is always on (not just hover/focus).
        borderColor: active ? colors.selectionBorder : Colors.transparent,
        hoveredBorderColor: colors.selectionBorder.withValues(alpha: 0.5),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 6, 11),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: missing
                      ? colors.attentionTint
                      : active
                      ? colors.actionFill
                      : colors.surfaceNested,
                  shape: BoxShape.circle,
                ),
                child: KvIcon(
                  glyph: missing
                      ? AppGlyph.warning
                      : item.remoteProviderId != null
                      ? AppGlyph.cloud
                      : AppGlyph.file,
                  size: 18,
                  color: missing
                      ? colors.attentionText
                      : active
                      ? colors.actionText
                      : colors.iconNeutral,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.rowTitle.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    if (status != null || tags.isNotEmpty) ...[
                      SizedBox(height: missing ? 2 : 5),
                      // Wraps instead of clipping when a long sync error
                      // meets two tags on a narrow phone.
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (status != null)
                            Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.secondary.copyWith(
                                fontWeight: missing ? FontWeight.w600 : null,
                                color: missing
                                    ? colors.attentionText
                                    : colors.textSecondary,
                              ),
                            ),
                          ...tags,
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (missing && onLocate != null)
                TextButton(
                  onPressed: onLocate,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Locate'),
                ),
              DatabaseActionMenu(
                name: item.displayName,
                onOpen: () => onOpen(),
                onExport: () => onExport(),
                onRemove: () => onRemove(),
                onLocate: missing ? onLocate : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-08-31: the vault list's surface/hover recipe (spec 019) applied to a
/// recent-database card — same [AppRadii.row] corners, transparent border at
/// rest, `selectionBorder` on hover/focus, click cursor.
class _HoverSurface extends StatefulWidget {
  const _HoverSurface({
    required this.child,
    required this.baseColor,
    required this.borderColor,
    required this.hoveredBorderColor,
    this.onTap,
  });

  final Widget child;
  final Color baseColor;
  final Color borderColor;
  final Color hoveredBorderColor;
  final VoidCallback? onTap;

  @override
  State<_HoverSurface> createState() => _HoverSurfaceState();
}

class _HoverSurfaceState extends State<_HoverSurface> {
  bool _isHovered = false;
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final highlight = _isHovered || _isFocused;
    final duration = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 120);
    return FocusableActionDetector(
      enabled: widget.onTap != null,
      // PR #188 review: focus alone is not activation — Enter/Space must
      // invoke the same tap handler, as the InkWell this surface replaced did.
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (value) {
        if (_isFocused != value) setState(() => _isFocused = value);
      },
      child: MouseRegion(
        cursor: widget.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: 68),
            decoration: BoxDecoration(
              color: widget.baseColor,
              borderRadius: BorderRadius.circular(AppRadii.row),
              border: Border.all(
                color: highlight
                    ? widget.hoveredBorderColor
                    : widget.borderColor,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
