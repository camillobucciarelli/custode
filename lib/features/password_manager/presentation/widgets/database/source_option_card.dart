import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_icon.dart';

/// One tappable choice in a database flow: circular glyph, title, one-line
/// subtitle, then [trailing], a text [actionLabel] or a chevron. Shared by the
/// Source sheet, the Create wizard's "Where it lives" and the Conflict sheet.
///
/// A null [onTap] is the disabled state; the caller passes the reason as
/// [subtitle], so the widget tree is the same whether or not a capability is
/// available (spec 025 FR-X3). [selected] draws the highlighted recipe.
class SourceOptionCard extends StatelessWidget {
  const SourceOptionCard({
    super.key,
    required this.glyph,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.actionLabel,
    this.trailing,
    this.selected = false,
    this.onSheet = true,
  });

  final AppGlyph glyph;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  /// Text action drawn in place of the chevron (`Connect`).
  final String? actionLabel;

  /// Overrides the chevron and [actionLabel] (a `KvTag`, a check mark).
  final Widget? trailing;
  final bool selected;

  /// Sheets are drawn on `surface`, so their cards step to `surfaceNested`;
  /// on a plain screen (`ground`) the card is `surface` instead.
  final bool onSheet;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final enabled = onTap != null;
    final fill = onSheet ? colors.surfaceNested : colors.surface;
    final bubble = onSheet ? colors.surface : colors.surfaceNested;
    final foreground = selected ? colors.attentionText : colors.textPrimary;
    final secondary = selected ? colors.attentionText : colors.textSecondary;
    final end =
        trailing ??
        (actionLabel != null
            ? Text(
                actionLabel!,
                style: AppTextStyles.rowTitle.copyWith(
                  fontSize: 13.5,
                  color: colors.linkText,
                ),
              )
            : KvIcon(
                glyph: AppGlyph.chevronRight,
                size: 18,
                color: colors.textSecondary,
              ));

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: selected,
      label: '$title, $subtitle',
      excludeSemantics: true,
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: Material(
          color: selected ? colors.attentionTint : fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.rowCompact),
            side: selected
                ? BorderSide(color: colors.selectionBorder, width: 1.5)
                : BorderSide.none,
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadii.rowCompact),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected ? AppColors.accent300 : bubble,
                        shape: BoxShape.circle,
                      ),
                      child: KvIcon(
                        glyph: glyph,
                        size: 18,
                        color: selected
                            ? AppColors.accent900
                            : colors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: AppTextStyles.rowTitle.copyWith(
                              color: foreground,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: AppTextStyles.secondary.copyWith(
                              color: secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    end,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The reassurance line closing the Source sheet and the Drive file list.
class SourcePrivacyLine extends StatelessWidget {
  const SourcePrivacyLine({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ExcludeSemantics(
              child: KvIcon(
                glyph: AppGlyph.lock,
                size: 14,
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Custode only reads the file you pick. Your master password '
              'never leaves this device.',
              style: AppTextStyles.secondary.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
