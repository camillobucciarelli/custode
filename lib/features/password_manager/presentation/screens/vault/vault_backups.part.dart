part of '../vault_screen.dart';

// FR-8 / T17: Backups destination (screen 17, reached from the Settings
// tab) — the three existing export actions, behaviour unchanged (bodies
// live in vault_shared.part.dart, shared with the legacy sync-strip
// overflow menu). "Last exports" history is not persisted anywhere in the
// app today, so it is intentionally omitted rather than fabricated — see
// the final report.

class _VaultBackupsDestination extends StatelessWidget {
  const _VaultBackupsDestination();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return BlocBuilder<VaultBloc, VaultState>(
      buildWhen: (previous, current) =>
          previous.databasePath != current.databasePath,
      builder: (context, state) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Backups',
                style: AppTextStyles.screenTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              Text(
                state.databaseLabel,
                style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: 18),
              KvListRow(
                title: 'Export the database',
                subtitle: 'A copy of the encrypted .kdbx file',
                leading: _actionIcon(colors, AppGlyph.export),
                onTap: () => _exportDatabaseBackup(
                  context,
                  state.databasePath,
                  databaseLabel: state.databaseLabel,
                ),
              ),
              const SizedBox(height: 8),
              KvListRow(
                title: 'Export the key file',
                subtitle: 'Keep it apart from the database',
                leading: _actionIcon(colors, AppGlyph.key),
                onTap: () => _exportKeyFileBackup(context),
              ),
              const SizedBox(height: 8),
              KvListRow(
                title: 'Import from CSV',
                subtitle: 'Chrome, Bitwarden, 1Password exports',
                leading: _actionIcon(colors, AppGlyph.fileText),
                onTap: () => _startCsvImportFlow(context),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: colors.attentionTint,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KvIcon(
                      glyph: AppGlyph.info,
                      size: 17,
                      color: colors.attentionText,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'On mobile the database lives in app storage: if you '
                        'delete Custode without a backup, the file goes '
                        'with it.',
                        style: AppTextStyles.secondary.copyWith(
                          color: colors.attentionText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _actionIcon(CustodeColors colors, AppGlyph glyph) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: colors.attentionTint,
        borderRadius: BorderRadius.circular(AppRadii.iconSquare),
      ),
      alignment: Alignment.center,
      child: KvIcon(glyph: glyph, size: 19, color: colors.attentionText),
    );
  }
}
