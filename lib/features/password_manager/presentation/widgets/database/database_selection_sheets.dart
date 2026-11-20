import 'package:material_ui/material_ui.dart';

import '../../../../../core/widgets/kv_confirm_dialog.dart';

/// FR-3: invalid-file message. Names only the basename, never the full path
/// (C-3) and never offers CSV import (that requires an open vault).
Future<void> showInvalidDatabaseFileDialog(
  BuildContext context, {
  required String basename,
}) {
  return showKvConfirmDialog(
    context,
    title: 'Invalid database file',
    body: '"$basename" is not a valid Custode database file.',
    confirmLabel: 'OK',
    cancelLabel: null,
  );
}

/// FR-3/C-3: corrupt-file message. Never phrased as "wrong password".
Future<void> showCorruptDatabaseFileDialog(
  BuildContext context, {
  required String basename,
}) {
  return showKvConfirmDialog(
    context,
    title: 'Database file is corrupted',
    body: '"$basename" could not be read. The file may be corrupted.',
    confirmLabel: 'OK',
    cancelLabel: null,
  );
}
