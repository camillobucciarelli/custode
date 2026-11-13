import 'package:flutter/material.dart';

import '../../../../../../core/theme/app_glyph.dart';
import '../../../../../../core/theme/app_radii.dart';
import '../../../../../../core/widgets/kv_icon.dart';
import '../../../../../../core/theme/app_text_styles.dart';
import '../../../../../../core/theme/custode_colors.dart';
import '../../../domain/entities/database_record.dart';
import '../../../domain/models/database_selection_item.dart';
import 'database_action_menu.dart';

/// C-1 metadata subtitle: "On this device · biometrics on/off" for local
/// databases, "Google Drive · synced `<relative time>`" (or the existing
/// sync error) for Drive ones. `canonicalPath` is deliberately not part of
/// this subtitle — it stays available via semantics/overflow only.
String databaseSubtitle(DatabaseSelectionItem item, {DateTime? now}) {
  if (item.sourceType == DatabaseSourceType.drive) {
    if (item.lastSyncError != null && item.lastSyncError!.trim().isNotEmpty) {
      return 'Google Drive · ${item.lastSyncError}';
    }
    final lastSyncAt = item.lastSyncAt;
    if (lastSyncAt == null) {
      return 'Google Drive · not synced yet';
    }
    return 'Google Drive · synced ${_relativeTime(lastSyncAt, now ?? DateTime.now())}';
  }
  final biometrics = item.biometricProtectionEnabled ? 'on' : 'off';
  return 'On this device · biometrics $biometrics';
}

String _relativeTime(DateTime value, DateTime now) {
  final diff = now.difference(value);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays < 7) return '${diff.inDays} d ago';
  return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
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

  /// Only invoked for `item.isMissing` (FR-1). Coordinator validates hash
  /// match before rebinding the record — see `LocateMissingDatabase`.
  final Future<void> Function()? onLocate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final active = item.isActive && !item.isMissing;

    return Semantics(
      button: true,
      label: item.displayName,
      value: item.canonicalPath,
      child: _HoverSurface(
        onTap: item.isMissing ? onLocate : () => onOpen(),
        baseColor: active ? colors.attentionTint : colors.surface,
        // Active row: tint alone is too close to the background, so the
        // selection border is always on (not just hover/focus).
        borderColor: active ? colors.selectionBorder : Colors.transparent,
        hoveredBorderColor: colors.selectionBorder.withValues(alpha: 0.5),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: item.isMissing
                      ? colors.attentionTint
                      : colors.surfaceNested,
                  shape: BoxShape.circle,
                ),
                child: KvIcon(
                  glyph: item.isMissing
                      ? AppGlyph.warning
                      : item.sourceType == DatabaseSourceType.drive
                      ? AppGlyph.cloud
                      : AppGlyph.file,
                  size: 18,
                  color: item.isMissing
                      ? colors.attentionText
                      : colors.iconNeutral,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.rowTitle.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.isMissing
                          ? 'File not found on this device'
                          : databaseSubtitle(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.secondary.copyWith(
                        color: item.isMissing
                            ? colors.attentionText
                            : colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (item.isMissing)
                TextButton(onPressed: onLocate, child: const Text('Locate')),
              DatabaseActionMenu(
                onOpen: () => onOpen(),
                onExport: () => onExport(),
                onRemove: () => onRemove(),
                onLocate: item.isMissing ? onLocate : null,
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
            constraints: const BoxConstraints(minHeight: 62),
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
