import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_glyph.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/custode_colors.dart';
import '../../../../core/widgets/kv_icon.dart';
import '../../../../core/widgets/kv_list_row.dart';
import '../../domain/models/vault_encryption.dart';
import '../utils/vault_encryption_format.dart';

/// Read-only: how the open database is encrypted. Opened from Settings;
/// nothing here changes the file.
class EncryptionDetailsScreen extends StatelessWidget {
  const EncryptionDetailsScreen({
    super.key,
    required this.encryption,
    required this.databaseName,
  });

  final VaultEncryption encryption;
  final String databaseName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final kdfSettings = encryption.kdfSettings;
    final format = encryption.formatLabel;

    Widget group(String label) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: AppTextStyles.labelUpper.copyWith(color: colors.textSecondary),
      ),
    );
    Widget row(String title, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: KvListRow(title: title, subtitle: value),
    );

    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Same header as Change master password.
              Row(
                children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.maybePop(context),
                      style: IconButton.styleFrom(
                        backgroundColor: colors.surface,
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                      ),
                      icon: KvIcon(
                        glyph: AppGlyph.back,
                        size: 18,
                        color: colors.iconNeutral,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Encryption',
                          style: AppTextStyles.panelTitle.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          databaseName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.secondary.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              group('ALGORITHM'),
              row('Cipher', encryption.cipher.label),
              row('Key derivation', encryption.kdf.label),
              if (kdfSettings != null)
                row('Key derivation settings', kdfSettings),
              if (format != null) ...[
                const SizedBox(height: 10),
                group('FILE'),
                row('Format', format),
              ],
              const SizedBox(height: 10),
              Text(
                'Set when the database was created. New databases use '
                '${VaultEncryption.defaults.summary}.',
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
}
