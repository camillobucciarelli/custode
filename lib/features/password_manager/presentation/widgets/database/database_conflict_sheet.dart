import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../../core/widgets/kv_tag.dart';
import '../../../domain/models/database_dedup_result.dart';
import 'source_chip.dart';
import 'source_option_card.dart';

/// Spec 025 FR-O7: the one conflict sheet for an import that matches a
/// database already on the device, whether by source, content or name.
///
/// Returns the chosen resolution. A null result means the sheet was
/// dismissed by any means (barrier, back, drag); callers treat it as
/// [DatabaseDuplicateResolution.cancel] so the staged import is discarded.
///
/// [recommendExisting] is true for a source or hash match only: a name-only
/// match is a different file and gets no recommendation. [allowReplace] is
/// false when replacing would put a different database on a path that is
/// linked to a remote file (spec 025 D11); the option is then not offered.
Future<DatabaseDuplicateResolution?> showDatabaseConflictSheet(
  BuildContext context, {
  required String importedName,
  required bool importedRemote,
  required String existingName,
  required bool existingRemote,
  required bool recommendExisting,
  bool allowReplace = true,
}) {
  return KvBottomSheet.show<DatabaseDuplicateResolution>(
    context: context,
    builder: (sheetContext) {
      final colors = Theme.of(sheetContext).extension<CustodeColors>()!;

      Widget option({
        required AppGlyph glyph,
        required String title,
        required String subtitle,
        required DatabaseDuplicateResolution resolution,
        bool recommended = false,
      }) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SourceOptionCard(
            glyph: glyph,
            title: title,
            subtitle: subtitle,
            selected: recommended,
            trailing: recommended
                ? const KvTag(
                    label: 'Recommended',
                    variant: KvTagVariant.accent,
                  )
                : const SizedBox.shrink(),
            onTap: () => Navigator.of(sheetContext).pop(resolution),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Semantics(
                header: true,
                child: Text(
                  'This database is already here',
                  style: AppTextStyles.sheetTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _SourceLine(
              role: 'Importing',
              name: importedName,
              remote: importedRemote,
            ),
            const SizedBox(height: 6),
            _SourceLine(
              role: 'Existing',
              name: existingName,
              remote: existingRemote,
            ),
            const SizedBox(height: 14),
            option(
              glyph: AppGlyph.check,
              title: 'Open the existing one',
              subtitle: 'Nothing is imported or changed.',
              resolution: DatabaseDuplicateResolution.useExisting,
              recommended: recommendExisting,
            ),
            option(
              glyph: AppGlyph.copy,
              title: 'Keep both',
              subtitle: 'Add this file as a separate database.',
              resolution: DatabaseDuplicateResolution.keepBoth,
            ),
            if (allowReplace)
              option(
                glyph: AppGlyph.refresh,
                title: 'Replace existing',
                subtitle: 'Custode backs up the existing file first.',
                resolution: DatabaseDuplicateResolution.replaceExisting,
              ),
            Center(
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  foregroundColor: colors.linkText,
                  textStyle: AppTextStyles.rowTitle,
                ),
                onPressed: () =>
                    Navigator.of(sheetContext)
                        .pop(DatabaseDuplicateResolution.cancel),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _SourceLine extends StatelessWidget {
  const _SourceLine({
    required this.role,
    required this.name,
    required this.remote,
  });

  final String role;
  final String name;
  final bool remote;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final secondary = AppTextStyles.body.copyWith(color: colors.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 86, child: Text(role, style: secondary)),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: name,
                    style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  TextSpan(
                    text: ' (${databaseSourceLabel(remote: remote)})',
                    style: secondary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
