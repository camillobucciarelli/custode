import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../../injection_container.dart' as di;
import '../../../domain/models/storage_account_summary.dart';
import '../../coordinators/database_session_coordinator.dart';
import '../../utils/platform_utils.dart';
import 'source_chip.dart';
import 'source_option_card.dart';

enum DatabaseSource { device, remote }

/// Spec 025 FR-O2: "Where is your database?" for the Open path only (Create
/// picks its source inside the wizard). Null when dismissed.
Future<DatabaseSource?> showDatabaseSourceSheet(BuildContext context) {
  final coordinator = di.sl<DatabaseSessionCoordinator>();
  return KvBottomSheet.show<DatabaseSource>(
    context: context,
    builder: (_) => _DatabaseSourceSheet(
      // Never opens a sign-in: only reads an account that is already connected.
      loadAccount: coordinator.connectedAccountOrNull,
    ),
  );
}

class _DatabaseSourceSheet extends StatefulWidget {
  const _DatabaseSourceSheet({required this.loadAccount});

  final Future<StorageAccountSummary?> Function() loadAccount;

  @override
  State<_DatabaseSourceSheet> createState() => _DatabaseSourceSheetState();
}

class _DatabaseSourceSheetState extends State<_DatabaseSourceSheet> {
  StorageAccountSummary? _account;

  @override
  void initState() {
    super.initState();
    if (supportsRemoteSource) {
      widget.loadAccount().then((account) {
        if (mounted) setState(() => _account = account);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final account = _account;
    final remoteSubtitle = !supportsRemoteSource
        ? 'Not available in the browser'
        : account == null
        ? 'Not connected'
        : account.email ?? account.displayLabel;

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
                'Where is your database?',
                style: AppTextStyles.sheetTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SourceOptionCard(
            glyph: databaseSourceGlyph(remote: false),
            title: 'This device',
            subtitle: 'Pick a .kdbx file',
            onTap: () => Navigator.of(context).pop(DatabaseSource.device),
          ),
          const SizedBox(height: 8),
          SourceOptionCard(
            glyph: databaseSourceGlyph(remote: true),
            title: 'Google Drive',
            subtitle: remoteSubtitle,
            actionLabel: supportsRemoteSource && account == null
                ? 'Connect'
                : null,
            onTap: supportsRemoteSource
                ? () => Navigator.of(context).pop(DatabaseSource.remote)
                : null,
          ),
          const SizedBox(height: 14),
          const SourcePrivacyLine(),
        ],
      ),
    );
  }
}
