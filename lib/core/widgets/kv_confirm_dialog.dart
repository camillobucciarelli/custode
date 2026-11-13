import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

/// Title/body confirmation with one positive and (optionally) one negative
/// action. A modal `AlertDialog` on every width (2026-09-05, user-directed):
/// only choosers with lists adapt to a bottom sheet on phones
/// (`KvBottomSheet`). Resolves `true` on confirm, `false` on cancel, `null`
/// when dismissed. `cancelLabel: null` makes it a single-action message.
Future<bool?> showKvConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  String? cancelLabel = 'Cancel',
  bool dismissible = true,
  ValueListenable<bool>? closeWhen,
}) {
  return showDialog<bool>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: dismissible,
    builder: (dialogContext) => _KvClosableDialog(
      closeWhen: closeWhen,
      child: AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          if (cancelLabel != null)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(cancelLabel),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
}

/// Closes its dialog, resolving `null`, when [closeWhen] turns true.
///
/// For a confirmation about something that has stopped being true while the
/// user was reading it — spec 023's passkey prompts, where the request behind
/// the dialog has its own deadline. A dead dialog is worse than no dialog: the
/// user presses the positive action and nothing happens.
///
/// Pops through the dialog's own context, so it can only ever close this route
/// and never something pushed over it.
class _KvClosableDialog extends StatefulWidget {
  const _KvClosableDialog({required this.child, this.closeWhen});

  final Widget child;
  final ValueListenable<bool>? closeWhen;

  @override
  State<_KvClosableDialog> createState() => _KvClosableDialogState();
}

class _KvClosableDialogState extends State<_KvClosableDialog> {
  @override
  void initState() {
    super.initState();
    widget.closeWhen?.addListener(_onCloseWhen);
  }

  @override
  void dispose() {
    widget.closeWhen?.removeListener(_onCloseWhen);
    super.dispose();
  }

  void _onCloseWhen() {
    if (widget.closeWhen?.value != true || !mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
