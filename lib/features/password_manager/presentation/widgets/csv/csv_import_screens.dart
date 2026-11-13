import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/utils/format_bytes.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_list_row.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../../../core/widgets/kv_switch.dart';
import '../../../data/services/vault_csv_import_service.dart';

/// FR-7 / T14: CSV import preview (screen 15). Public (unlike most vault
/// screens, which are `part of vault_screen.dart`) so it can be pumped
/// directly in a widget/golden test with a synthetic [VaultCsvParseResult]
/// — `FilePicker.pickFiles` has no test platform-channel handler in this
/// repo (see database_selection_screen_test.dart's header comment for the
/// established precedent of testing the screen, not the picker plugin).
///
/// [onCancel] fires on the close button / Cancel action; [onImport] fires
/// with the confirmed avoid-duplicates choice when "Import N" is pressed
/// (disabled when there are zero valid records).
class CsvImportPreviewScreen extends StatefulWidget {
  const CsvImportPreviewScreen({
    super.key,
    required this.filePath,
    required this.fileSizeBytes,
    required this.preview,
    this.onCancel,
    this.onImport,
  });

  final String filePath;
  final int fileSizeBytes;
  final VaultCsvParseResult preview;
  final VoidCallback? onCancel;
  final ValueChanged<bool>? onImport;

  @override
  State<CsvImportPreviewScreen> createState() => _CsvImportPreviewScreenState();
}

class _CsvImportPreviewScreenState extends State<CsvImportPreviewScreen> {
  bool _avoidDuplicates = true;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final preview = widget.preview;
    final formatLabel = _csvSourceFormatLabel(preview.format);
    final valid = preview.items.length;

    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onCancel,
                    icon: KvIcon(
                      glyph: AppGlyph.close,
                      size: 19,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Import CSV',
                    style: AppTextStyles.panelTitleLarge.copyWith(
                      fontSize: 19,
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KvListRow(
                      title: path.basename(widget.filePath),
                      subtitle:
                          '${formatBytes(widget.fileSizeBytes)} · picked from Files',
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: colors.surfaceNested,
                          borderRadius: BorderRadius.circular(
                            AppRadii.iconSquare,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: KvIcon(
                          glyph: AppGlyph.fileText,
                          size: 19,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Column(
                        children: [
                          _summaryRow(colors, 'Detected format', formatLabel),
                          const SizedBox(height: 9),
                          _summaryRow(
                            colors,
                            'Rows found',
                            '${preview.totalRows}',
                          ),
                          const SizedBox(height: 9),
                          _summaryRow(
                            colors,
                            'Valid records',
                            '$valid',
                            valueColor: colors.positiveText,
                          ),
                          const SizedBox(height: 9),
                          _summaryRow(
                            colors,
                            'Skipped rows',
                            '${preview.skippedRows}',
                            valueColor: colors.attentionText,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Avoid duplicates',
                                  style: AppTextStyles.rowTitle.copyWith(
                                    color: colors.textPrimary,
                                  ),
                                ),
                                Text(
                                  'Skip rows that match a record already in this vault',
                                  style: AppTextStyles.meta.copyWith(
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          KvSwitch(
                            value: _avoidDuplicates,
                            onChanged: preview.items.isEmpty
                                ? null
                                : (value) =>
                                      setState(() => _avoidDuplicates = value),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Imported records land in All items. Delete the CSV '
                        'afterwards — it holds your passwords in clear text.',
                        style: AppTextStyles.secondary.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Row(
                children: [
                  Expanded(
                    child: KvSecondaryPillButton(
                      label: 'Cancel',
                      onPressed: widget.onCancel,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: KvPillButton(
                      label: 'Import $valid',
                      onPressed: valid == 0 || widget.onImport == null
                          ? null
                          : () => widget.onImport!(_avoidDuplicates),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(
    CustodeColors colors,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: AppTextStyles.body.copyWith(color: colors.textSecondary),
        ),
        Text(
          value,
          style: AppTextStyles.body.copyWith(
            fontWeight: FontWeight.w700,
            color: valueColor ?? colors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// T16/AC8: lists a reason for every skipped row — not a bare count. Public
/// for the same testability reason as [CsvImportPreviewScreen].
class CsvImportOutcomeScreen extends StatelessWidget {
  const CsvImportOutcomeScreen({super.key, required this.outcome, this.onDone});

  final CsvImportOutcome outcome;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onDone,
                    icon: KvIcon(
                      glyph: AppGlyph.close,
                      size: 19,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Import finished',
                    style: AppTextStyles.panelTitleLarge.copyWith(
                      fontSize: 19,
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: colors.positiveTint,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: colors.positiveFill,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: KvIcon(
                              glyph: AppGlyph.check,
                              size: 24,
                              color: colors.positiveText,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${outcome.importedCount} records added',
                                  style: AppTextStyles.panelTitleLarge.copyWith(
                                    color: colors.positiveText,
                                  ),
                                ),
                                if (outcome.duplicateSkippedCount > 0)
                                  Text(
                                    '${outcome.duplicateSkippedCount} skipped as duplicates',
                                    style: AppTextStyles.secondary.copyWith(
                                      color: colors.positiveText,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (outcome.skippedRows.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        outcome.skippedRows.length == 1
                            ? '1 row could not be read'
                            : '${outcome.skippedRows.length} rows could not be read',
                        style: AppTextStyles.labelUpper.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final row in outcome.skippedRows) ...[
                        _SkippedRowTile(row: row),
                        const SizedBox(height: 8),
                      ],
                    ],
                    // spec 023 T208 — a refused column is not a refused row,
                    // so it gets its own block rather than a fake row number.
                    if (outcome.ignoredColumns.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        outcome.ignoredColumns.length == 1
                            ? '1 column was not imported'
                            : '${outcome.ignoredColumns.length} columns were not imported',
                        style: AppTextStyles.labelUpper.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final column in outcome.ignoredColumns) ...[
                        _IgnoredColumnTile(column: column),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: KvPillButton(label: 'Done', onPressed: onDone),
            ),
          ],
        ),
      ),
    );
  }
}

class _IgnoredColumnTile extends StatelessWidget {
  const _IgnoredColumnTile({required this.column});

  final IgnoredColumn column;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.row),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            column.header,
            style: AppTextStyles.secret.copyWith(
              fontSize: 12,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            column.reason,
            style: AppTextStyles.body.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _SkippedRowTile extends StatelessWidget {
  const _SkippedRowTile({required this.row});

  final SkippedRow row;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.row),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(
              '${row.index}',
              style: AppTextStyles.secret.copyWith(
                fontSize: 12,
                color: colors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              row.reason,
              style: AppTextStyles.body.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

String _csvSourceFormatLabel(VaultCsvSourceFormat format) {
  return switch (format) {
    VaultCsvSourceFormat.bitwarden => 'Bitwarden',
    VaultCsvSourceFormat.onePassword => '1Password',
    VaultCsvSourceFormat.lastPass => 'LastPass',
    VaultCsvSourceFormat.chrome => 'Chrome',
    VaultCsvSourceFormat.applePasswords => 'Apple Passwords',
    VaultCsvSourceFormat.generic => 'Generic CSV',
  };
}
