import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../../../core/theme/app_glyph.dart';
import '../../../../core/theme/custode_colors.dart';
import '../../../../core/utils/mobile_file_storage.dart';
import '../../../../core/widgets/kv_circle_icon_button.dart';
import '../../../../core/widgets/kv_icon.dart';
import '../../../../core/widgets/kv_list_row.dart';
import '../../../../injection_container.dart' as di;
import '../../data/datasources/biometric_data_source.dart';
import '../coordinators/database_session_coordinator.dart';
import 'internal_key_file_manager_sheet.dart';
import 'managed_key_picker_gate.dart';

/// What [pickKeyFile] hands back: [path] is a file already copied into app
/// storage. A result without one means the key that was selected is gone.
class PickedKeyFile {
  const PickedKeyFile({this.path, this.name});

  final String? path;
  final String? name;

  bool get isCleared => path == null;
}

/// The key manager's listing seam: real listing is `dart:io`, which never
/// resolves inside a widget test. Reset to null in `tearDown`.
@visibleForTesting
KeyFileLister? debugKeyFileLister;

/// The only entry point for choosing a key file (spec 025 FR-X5). Runs the
/// spec 015 FR-12 device-auth gate and the internal key manager sheet.
/// Returns null when the user backs out or the gate refuses, so callers keep
/// whatever they had.
Future<PickedKeyFile?> pickKeyFile(
  BuildContext context, {
  String? current,
}) async {
  final biometrics = di.sl<BiometricDataSource>();
  final coordinator = di.sl<DatabaseSessionCoordinator>();
  // spec 015 FR-12: managed keys list only after device auth.
  if (!await authorizeManagedKeyPickerAccess(biometrics)) {
    return null;
  }
  final protectedPaths = await coordinator.getProtectedKeyFilePaths();
  if (!context.mounted) {
    return null;
  }
  final result = await showInternalKeyFileManagerSheet(
    context,
    initiallySelectedPath: current,
    protectedPaths: {...protectedPaths, ?current},
    listKeyFiles:
        debugKeyFileLister ?? MobileFileStorage.listFilesInAppDirectory,
  );
  if (result == null) {
    return null;
  }
  final selected = result.selectedPath;
  if (selected != null) {
    return PickedKeyFile(path: selected, name: p.basename(selected));
  }
  if (result.currentSelectionDeleted && (current?.trim().isNotEmpty ?? false)) {
    return const PickedKeyFile();
  }
  return null;
}

/// The key-file slot shared by unlock, create and settings: an empty row that
/// opens the picker, or the selected key with a remove button. Pass the stored
/// [path] (its display name is looked up, since managed names are opaque) or an
/// in-memory [name] where there is no path.
class KeyFileRow extends StatefulWidget {
  const KeyFileRow({
    super.key,
    this.path,
    this.name,
    this.emptySubtitle = 'Needed only if this database uses one',
    required this.onPick,
    required this.onClear,
  });

  final String? path;
  final String? name;

  /// What the empty row says: unlock asks for the key the database needs,
  /// create offers one as an optional second factor.
  final String emptySubtitle;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  State<KeyFileRow> createState() => _KeyFileRowState();
}

class _KeyFileRowState extends State<KeyFileRow> {
  /// Held in state: a future built in `build` restarts the name lookup (and
  /// flashes the placeholder) on every rebuild of the form around it.
  late Future<String>? _storedName = _lookUpStoredName();

  // spec 014 FR-3: a managed key rests under an opaque identifier; the real
  // name is recorded by `MobileFileStorage` and looked up here.
  Future<String>? _lookUpStoredName() {
    final stored = widget.path;
    return stored != null &&
            MobileFileStorage.isOpaqueFileName(p.basename(stored))
        ? MobileFileStorage.keyFileDisplayName(stored)
        : null;
  }

  @override
  void didUpdateWidget(KeyFileRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _storedName = _lookUpStoredName();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final leading = Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.ground, shape: BoxShape.circle),
      child: KvIcon(glyph: AppGlyph.key, size: 18, color: colors.textSecondary),
    );

    final stored = widget.path;
    final hasKey = (stored?.trim().isNotEmpty ?? false) || widget.name != null;
    if (!hasKey) {
      return KvListRow(
        title: 'Add a key file',
        subtitle: widget.emptySubtitle,
        leading: leading,
        onTap: widget.onPick,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      );
    }

    Widget row(String title) => KvListRow(
      title: title,
      subtitle: 'Stored in Custode',
      semanticLabel: 'Change key file',
      leading: leading,
      onTap: widget.onPick,
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      trailing: KvCircleIconButton(
        glyph: AppGlyph.close,
        tooltip: 'Remove key file',
        nested: true,
        size: 44,
        iconSize: 16,
        onPressed: widget.onClear,
      ),
    );

    final storedName = _storedName;
    if (storedName == null) {
      return row(widget.name ?? p.basename(stored!));
    }
    return FutureBuilder<String>(
      future: storedName,
      initialData: 'Key file',
      builder: (context, snapshot) => row(snapshot.data!),
    );
  }
}
