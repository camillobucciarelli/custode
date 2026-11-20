import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../domain/models/storage_account_summary.dart';

/// FR-X1: the one place that words where a database lives. The literal
/// `Google Drive` is display copy only; grouping and linking are keyed by the
/// sync mapping's provider id elsewhere.
String databaseSourceLabel({
  required bool remote,
  StorageAccountSummary? account,
}) {
  if (!remote) {
    return 'This device';
  }
  // Desktop OAuth asserts no identity; its summary only carries a generic
  // label, so the email is the one thing worth appending (spec 025 D1).
  final email = account?.email;
  return email == null || email.isEmpty
      ? 'Google Drive'
      : 'Google Drive · $email';
}

/// The one glyph per source, on every platform: "This device" is a phone as
/// often as a computer, so it is a folder, never a monitor.
AppGlyph databaseSourceGlyph({required bool remote}) =>
    remote ? AppGlyph.cloud : AppGlyph.folder;

/// Source line shown above a database name: icon + [databaseSourceLabel].
class SourceChip extends StatelessWidget {
  const SourceChip({super.key, required this.remote, this.account});

  final bool remote;
  final StorageAccountSummary? account;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvIcon(
            glyph: databaseSourceGlyph(remote: remote),
            size: 14,
            color: colors.textSecondary,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              databaseSourceLabel(remote: remote, account: account),
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.secondary.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
