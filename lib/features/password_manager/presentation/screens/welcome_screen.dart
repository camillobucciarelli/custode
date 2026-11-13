import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/custode_colors.dart';
import '../../../../core/widgets/kv_pill_button.dart';

/// FR-1 "Welcome / no database" — shown when the selection list is empty.
/// Mark 88/radius 26; hero headline 38; three stacked primary pills gap 10;
/// centred block, bottom padding 34.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({
    super.key,
    required this.onCreateDatabase,
    required this.onOpenExistingDatabase,
    required this.onOpenFromGoogleDrive,
  });

  final VoidCallback onCreateDatabase;
  final VoidCallback onOpenExistingDatabase;
  final VoidCallback onOpenFromGoogleDrive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 34),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'Welcome to your vault',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: Image.asset(
                'assets/logo/app_icon_family/custode-source-1024.png',
                width: 88,
                height: 88,
                fit: BoxFit.cover,
                cacheWidth: (88 * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                cacheHeight: (88 * MediaQuery.devicePixelRatioOf(context))
                    .round(),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Your vault, in a file you own.',
            textAlign: TextAlign.center,
            style: AppTextStyles.heroHeadline.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Open an existing KDBX database or create a new one to start securely storing your credentials.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 28),
          Semantics(
            hint: 'Create a protected vault with password and key file',
            child: KvPillButton(
              label: 'Create new database',
              onPressed: onCreateDatabase,
            ),
          ),
          const SizedBox(height: 10),
          Semantics(
            hint: 'Choose a .kdbx file from your device',
            child: KvSecondaryPillButton(
              label: 'Open existing database',
              onPressed: onOpenExistingDatabase,
            ),
          ),
          const SizedBox(height: 10),
          Semantics(
            hint: 'Download a .kdbx and open a local copy',
            child: KvSecondaryPillButton(
              label: 'Open from Google Drive',
              onPressed: onOpenFromGoogleDrive,
            ),
          ),
        ],
      ),
    );
  }
}
