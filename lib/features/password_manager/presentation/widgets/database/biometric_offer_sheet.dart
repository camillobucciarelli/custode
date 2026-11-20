import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_pill_button.dart';

/// Spec 025 FR-U6: the one-time biometric offer, shown after a successful
/// manual unlock for every source. Generic on purpose: the OS prompt names
/// Face ID, Touch ID or fingerprint. Returns true for Enable, false for Not
/// now, null when dismissed (callers treat null as Not now).
Future<bool?> showBiometricOfferSheet(
  BuildContext context, {
  required String databaseName,
}) {
  return KvBottomSheet.show<bool>(
    context: context,
    builder: (sheetContext) => _BiometricOfferSheet(databaseName: databaseName),
  );
}

class _BiometricOfferSheet extends StatelessWidget {
  const _BiometricOfferSheet({required this.databaseName});

  final String databaseName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 66,
              height: 66,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceNested,
                borderRadius: BorderRadius.circular(20),
              ),
              child: ExcludeSemantics(
                child: KvIcon(
                  glyph: AppGlyph.fingerprint,
                  size: 28,
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Semantics(
            header: true,
            child: Text(
              'Unlock $databaseName with biometrics?',
              style: AppTextStyles.sheetTitleLarge.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'You can change this anytime in Settings.',
            style: AppTextStyles.body.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 20),
          KvPillButton(
            label: 'Enable',
            onPressed: () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: 10),
          KvSecondaryPillButton(
            label: 'Not now',
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}
