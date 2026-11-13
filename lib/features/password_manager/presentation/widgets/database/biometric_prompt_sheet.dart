import 'package:material_ui/material_ui.dart';

import '../../../../../core/widgets/kv_confirm_dialog.dart';

/// FR-5 post-Drive prompt: "Use biometric unlock for `<basename>`?".
/// Generic on purpose — Face ID, Touch ID, fingerprint or face unlock is the
/// device's call, and the OS prompt names it. Preserves the former dialog's
/// exact "Not now"/"Enable" action labels.
Future<bool?> showBiometricPromptDialog(
  BuildContext context, {
  required String basename,
}) {
  return showKvConfirmDialog(
    context,
    title: 'Use biometric unlock for $basename?',
    body:
        'This database came from Google Drive. Do you want to require '
        'biometric authentication before unlock when available?',
    confirmLabel: 'Enable',
    cancelLabel: 'Not now',
    dismissible: false,
  );
}
