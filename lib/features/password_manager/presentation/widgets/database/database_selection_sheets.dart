import 'package:flutter/material.dart';

import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../../core/widgets/kv_confirm_dialog.dart';
import '../../../domain/models/database_dedup_result.dart';

/// FR-3: invalid-file message. Names only the basename, never the full path
/// (C-3) and never offers CSV import (that requires an open vault).
Future<void> showInvalidDatabaseFileDialog(
  BuildContext context, {
  required String basename,
}) {
  return showKvConfirmDialog(
    context,
    title: 'Invalid database file',
    body: '"$basename" is not a valid Custode database file.',
    confirmLabel: 'OK',
    cancelLabel: null,
  );
}

/// FR-3/C-3: corrupt-file message. Never phrased as "wrong password".
Future<void> showCorruptDatabaseFileDialog(
  BuildContext context, {
  required String basename,
}) {
  return showKvConfirmDialog(
    context,
    title: 'Database file is corrupted',
    body: '"$basename" could not be read. The file may be corrupted.',
    confirmLabel: 'OK',
    cancelLabel: null,
  );
}

/// FR-4 duplicate sheet: the three real resolutions plus their consequence
/// copy (approved additions), cancel/back discards nothing. No CSV action.
Future<DatabaseDuplicateResolution?> showDuplicateDatabaseSheet(
  BuildContext context, {
  required String importedName,
  required String existingName,
}) {
  return KvBottomSheet.show<DatabaseDuplicateResolution>(
    context: context,
    builder: (sheetContext) =>
        _DuplicateSheet(importedName: importedName, existingName: existingName),
  );
}

class _DuplicateSheet extends StatelessWidget {
  const _DuplicateSheet({
    required this.importedName,
    required this.existingName,
  });

  final String importedName;
  final String existingName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    Widget option({
      required String title,
      required String consequence,
      required DatabaseDuplicateResolution resolution,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.of(context).pop(resolution),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceNested,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.rowTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  consequence,
                  style: AppTextStyles.secondary.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Duplicate database detected',
            textAlign: TextAlign.center,
            style: AppTextStyles.sheetTitleLarge.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Imported: $importedName\nExisting: $existingName\n\nChoose how to continue.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          option(
            title: 'Keep both',
            consequence: 'Save this file as another database.',
            resolution: DatabaseDuplicateResolution.keepBoth,
          ),
          option(
            title: 'Replace existing',
            consequence: 'Back up, then replace the existing file.',
            resolution: DatabaseDuplicateResolution.replaceExisting,
          ),
          option(
            title: 'Use existing',
            consequence: 'Discard this import and open the existing database.',
            resolution: DatabaseDuplicateResolution.useExisting,
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(DatabaseDuplicateResolution.cancel),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
