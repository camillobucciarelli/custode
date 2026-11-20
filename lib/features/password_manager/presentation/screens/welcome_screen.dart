import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/custode_colors.dart';
import '../../../../core/widgets/kv_pill_button.dart';

/// FR-1 "Welcome / no database" — shown when the selection list is empty.
/// Mark 88/radius 26; hero headline 38; two stacked pills gap 10 (spec 025
/// FR-O1), pinned to the bottom with padding 34.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({
    super.key,
    required this.onCreateDatabase,
    required this.onOpenDatabase,
  });

  final VoidCallback onCreateDatabase;
  final VoidCallback onOpenDatabase;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    // Spec 025 `Main` mockup: the identity block is centred in the free
    // space and the two actions sit at the bottom; a scroll view keeps both
    // reachable on a short window.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 34),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 480,
              minHeight: constraints.maxHeight - 34,
            ),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
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
                              cacheWidth:
                                  (88 * MediaQuery.devicePixelRatioOf(context))
                                      .round(),
                              cacheHeight:
                                  (88 * MediaQuery.devicePixelRatioOf(context))
                                      .round(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Your vault, in a file you own.',
                          style: AppTextStyles.heroHeadline.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Custode keeps your passwords in a KeePass database. Keep it on this device or in your own cloud.',
                          style: AppTextStyles.body.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
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
                    hint:
                        'Choose a .kdbx file from this device or Google Drive',
                    child: KvSecondaryPillButton(
                      label: 'Open a database',
                      onPressed: onOpenDatabase,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
