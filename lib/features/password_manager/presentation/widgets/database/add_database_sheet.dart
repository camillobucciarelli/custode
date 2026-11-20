import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import 'source_option_card.dart';

enum AddDatabaseAction { create, open }

/// Spec 025 FR-L1: the two entry actions behind the Databases "+". Null when
/// dismissed.
Future<AddDatabaseAction?> showAddDatabaseSheet(BuildContext context) {
  return KvBottomSheet.show<AddDatabaseAction>(
    context: context,
    builder: (sheetContext) {
      final colors = Theme.of(sheetContext).extension<CustodeColors>()!;
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Semantics(
                header: true,
                child: Text(
                  'Add a database',
                  style: AppTextStyles.sheetTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SourceOptionCard(
              glyph: AppGlyph.add,
              title: 'Create new database',
              subtitle: 'Start an empty vault',
              onTap: () =>
                  Navigator.of(sheetContext).pop(AddDatabaseAction.create),
            ),
            const SizedBox(height: 8),
            SourceOptionCard(
              glyph: AppGlyph.folderOpen,
              title: 'Open a database',
              subtitle: 'From this device or Google Drive',
              onTap: () =>
                  Navigator.of(sheetContext).pop(AddDatabaseAction.open),
            ),
          ],
        ),
      );
    },
  );
}
