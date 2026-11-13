import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

import '../../../../../core/navigation/app_navigation.dart';
import '../../../../../core/responsive/breakpoints.dart';
import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/utils/mobile_file_storage.dart';
import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../../core/widgets/kv_confirm_dialog.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../../../injection_container.dart' as di;
import '../../domain/errors/database_access_failure.dart';
import '../../domain/repositories/database_file_repository.dart';
import '../../domain/models/database_selection_item.dart';
import '../bloc/database_selection/database_selection_bloc.dart';
import '../bloc/database_selection/database_selection_event.dart';
import '../bloc/database_selection/database_selection_state.dart';
import '../coordinators/database_session_coordinator.dart';
import 'create_database_screen.dart';
import 'database_unlock_screen.dart';
import 'welcome_screen.dart';
import '../widgets/database/database_selection_sheets.dart';
import '../widgets/database/drive_picker_sheet.dart';
import '../widgets/database/recent_databases_section.dart';
import '../utils/platform_utils.dart';

class DatabaseSelectionScreen extends StatelessWidget {
  const DatabaseSelectionScreen({super.key});

  Future<void> _openFromGoogleDrive(BuildContext context) async {
    if (kIsWeb) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Open from Google Drive is currently desktop/mobile only.',
          ),
        ),
      );
      return;
    }

    final coordinator = di.sl<DatabaseSessionCoordinator>();
    final result = await showDrivePickerSheet(
      context,
      loadPickerData: coordinator.getRemoteFileSelectionData,
      reconnectPickerData: coordinator.reconnectRemoteFileSelectionData,
    );
    if (result == null || !context.mounted) {
      return;
    }

    if (result.switchAccount) {
      // Reconnect flow: force a fresh connect on next open by disconnecting
      // implicitly through the coordinator's normal connect-if-needed path.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Choose "Open from Google Drive" again to switch account.',
          ),
        ),
      );
      return;
    }

    if (result.createAndUpload) {
      await _onCreateDatabase(context);
      return;
    }

    final selected = result.file;
    if (selected == null) {
      return;
    }

    var overwriteExisting = false;
    if (isManagedStoragePlatform) {
      final exists = await coordinator.hasManagedDatabaseNamed(selected.name);
      if (!context.mounted) return;
      if (exists) {
        final confirm = await _showOverwriteDatabaseSheet(
          context,
          selected.name,
        );
        if (confirm != true || !context.mounted) return;
        overwriteExisting = true;
      }
    }

    if (!context.mounted) return;
    context.read<DatabaseSelectionBloc>().add(
      SelectDriveDatabase(
        remoteFileId: selected.id,
        remoteFileName: selected.name,
        overwriteExisting: overwriteExisting,
      ),
    );
  }

  Future<void> _onOpenRecentDatabase(
    BuildContext context,
    DatabaseSelectionItem item,
  ) async {
    context.read<DatabaseSelectionBloc>().add(
      OpenRecentDatabase(item.canonicalPath),
    );
  }

  Future<void> _onLocateDatabase(
    BuildContext context,
    DatabaseSelectionItem item,
  ) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['kdbx'],
    );
    if (result == null || !context.mounted) return;
    final selectedPath = result.files.single.path;
    if (selectedPath == null || selectedPath.trim().isEmpty) return;

    context.read<DatabaseSelectionBloc>().add(
      LocateMissingDatabase(
        databaseId: item.databaseId,
        selectedPath: selectedPath,
      ),
    );
  }

  Future<void> _onExportRecentDatabase(
    BuildContext context,
    DatabaseSelectionItem item,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = item.canonicalPath;

    if (kIsWeb) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Export is currently available on desktop/mobile only.',
          ),
        ),
      );
      return;
    }

    final source = File(path);
    if (!await source.exists()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Selected database file was not found.')),
      );
      return;
    }

    // spec 014 FR-3: the on-disk name is opaque, so export suggests the
    // human-readable registry name. Passed WITHOUT the extension: macOS's
    // save panel appends the allowed extension itself (passing "config.kdbx"
    // showed "config.kdbx.kdbx"); the resolvedPath guard below still
    // restores ".kdbx" on platforms that don't append it.
    final displayName = item.displayName.trim();
    final defaultName = displayName.isEmpty
        ? 'database'
        : p.basenameWithoutExtension(displayName);
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Export database backup',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: const ['kdbx'],
    );
    if (savePath == null || savePath.trim().isEmpty) return;

    final resolvedPath = savePath.toLowerCase().endsWith('.kdbx')
        ? savePath
        : '$savePath.kdbx';

    try {
      // spec 008 T102: exports go through the domain port, never dart:io.
      await di.sl<DatabaseFileRepository>().copyFile(
        sourcePath: path,
        targetPath: resolvedPath,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Database backup exported.')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Unable to export selected database.')),
      );
    }
  }

  Future<void> _onSelectExistingDatabase(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['kdbx'],
      withData: kIsWeb || isManagedStoragePlatform,
    );

    if (result == null || !context.mounted) return;

    final selectedFile = result.files.single;
    final selectedPath = selectedFile.path;
    final fallbackName = selectedPath == null || selectedPath.trim().isEmpty
        ? 'database.kdbx'
        : p.basename(selectedPath);
    final fileName = selectedFile.name.trim().isEmpty
        ? fallbackName
        : selectedFile.name;

    var overwriteExisting = false;
    if (isManagedStoragePlatform) {
      final exists = await MobileFileStorage.fileExistsInAppDirectory(
        fileName: fileName,
        subdirectory: 'databases',
      );
      if (!context.mounted) return;
      if (exists) {
        final confirm = await _showOverwriteDatabaseSheet(context, fileName);
        if (confirm != true || !context.mounted) return;
        overwriteExisting = true;
      }
    }

    if (!context.mounted) return;
    context.read<DatabaseSelectionBloc>().add(
      SelectExistingDatabase(
        fileName: fileName,
        selectedPath: selectedPath,
        selectedBytes: selectedFile.bytes,
        overwriteExisting: overwriteExisting,
      ),
    );
  }

  Future<void> _onCreateDatabase(BuildContext context) async {
    // spec 015 FR-10: the wizard dispatches `CreateNewDatabase` itself and
    // stays mounted across submission; no route result to handle here.
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const CreateDatabaseScreen()),
    );
  }

  Future<void> _onRemoveRecentDatabase(
    BuildContext context,
    DatabaseSelectionItem item,
  ) async {
    final mode = await _showRecentDatabaseRemovalSheet(
      context,
      item.displayName,
    );
    if (mode == null || !context.mounted) return;

    if (mode == RecentDatabaseRemovalMode.removeAndDeleteFile) {
      final confirmed = await _showDeleteFileConfirmationSheet(
        context,
        item.displayName,
      );
      if (confirmed != true || !context.mounted) return;
    }

    context.read<DatabaseSelectionBloc>().add(
      RemoveRecentDatabase(path: item.canonicalPath, mode: mode),
    );
  }

  Future<RecentDatabaseRemovalMode?> _showRecentDatabaseRemovalSheet(
    BuildContext context,
    String fileName,
  ) {
    return KvBottomSheet.show<RecentDatabaseRemovalMode>(
      context: context,
      builder: (sheetContext) {
        final colors = Theme.of(sheetContext).extension<CustodeColors>()!;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Remove recent database',
                style: AppTextStyles.sheetTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose how to remove "$fileName".',
                style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () =>
                    Navigator.of(sheetContext)
                        .pop(RecentDatabaseRemovalMode.removeOnly),
                child: const Text('Remove from list'),
              ),
              KvSecondaryPillButton(
                label: 'Remove and delete file',
                onPressed: kIsWeb
                    ? null
                    : () => Navigator.of(sheetContext)
                          .pop(RecentDatabaseRemovalMode.removeAndDeleteFile),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<bool?> _showDeleteFileConfirmationSheet(
    BuildContext context,
    String fileName,
  ) {
    return showKvConfirmDialog(
      context,
      title: 'Delete file?',
      body: 'This will try to permanently delete "$fileName" from disk.',
      confirmLabel: 'Delete file',
    );
  }

  Future<bool?> _showOverwriteDatabaseSheet(
    BuildContext context,
    String fileName,
  ) {
    return showKvConfirmDialog(
      context,
      title: 'Replace existing database?',
      body:
          'A database named "$fileName" already exists in app storage. Do you want to replace it?',
      confirmLabel: 'Replace',
    );
  }

  Future<void> _handleDuplicateDecisionPrompt(
    BuildContext context,
    DatabaseSelectionDuplicateDecisionRequired state,
  ) async {
    final decision = await showDuplicateDatabaseSheet(
      context,
      importedName: state.duplicatePrompt.imported.fileName,
      existingName: state.duplicatePrompt.existingRecord.displayName,
    );
    if (!context.mounted || decision == null) return;

    context.read<DatabaseSelectionBloc>().add(
      ResolveDuplicateDecision(decision),
    );
  }

  Future<void> _handleTypedFailure(
    BuildContext context,
    DatabaseSelectionError state,
  ) async {
    final failure = state.failure;
    if (failure is InvalidDatabaseFileFailure) {
      await showInvalidDatabaseFileDialog(context, basename: failure.basename);
      return;
    }
    if (failure is CorruptDatabaseFailure) {
      await showCorruptDatabaseFileDialog(context, basename: failure.basename);
      return;
    }
    if (failure is MetadataStorageUnreadableFailure) {
      // spec 014 FR-5: discarding metadata is the user's call, never the
      // app's — a refused write stays refused until they confirm here.
      final bloc = context.read<DatabaseSelectionBloc>();
      final confirmed = await showKvConfirmDialog(
        context,
        title: 'Saved database details unreadable',
        body:
            'This device can no longer read the list of databases and their '
            'sync settings. Your database files and their passwords are '
            'untouched. Reset the saved details to continue, then add your '
            'databases again.',
        confirmLabel: 'Reset',
      );
      if (confirmed != true) {
        return;
      }
      bloc.add(const DiscardUnreadableMetadata());
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(state.message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: BlocConsumer<DatabaseSelectionBloc, DatabaseSelectionState>(
          listener: (context, state) {
            if (state is DatabaseSelectionDuplicateDecisionRequired) {
              _handleDuplicateDecisionPrompt(context, state);
              return;
            }
            if (state is DatabaseSelectionSuccess) {
              if (state.userMessage != null && state.userMessage!.isNotEmpty) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(state.userMessage!)));
              }
              AppNavigation.pushFadeReplacement(
                context,
                DatabaseUnlockScreen(
                  databasePath: state.path,
                  promptBiometricSetup: state.promptBiometricSetup,
                ),
              );
              return;
            }
            if (state is DatabaseSelectionError) {
              _handleTypedFailure(context, state);
            }
            if (state is DatabaseSelectionInfo) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(state.message)));
            }
          },
          builder: (context, state) {
            if (state is DatabaseSelectionLoading ||
                state is DatabaseSelectionInitial) {
              return const Center(child: CircularProgressIndicator());
            }

            if (state.items.isEmpty) {
              return WelcomeScreen(
                onCreateDatabase: () => _onCreateDatabase(context),
                onOpenExistingDatabase: () =>
                    _onSelectExistingDatabase(context),
                onOpenFromGoogleDrive: () => _openFromGoogleDrive(context),
              );
            }

            final viewportWidth = MediaQuery.sizeOf(context).width;
            final isTablet = viewportWidth >= Breakpoints.mobile;

            const header = _RecentHeader();
            final list = RecentDatabasesSection(
              items: state.items,
              onOpen: (item) => _onOpenRecentDatabase(context, item),
              onExport: (item) => _onExportRecentDatabase(context, item),
              onRemove: (item) => _onRemoveRecentDatabase(context, item),
              onLocate: (item) => _onLocateDatabase(context, item),
            );
            final addSection = _AddSection(
              onCreate: () => _onCreateDatabase(context),
              onOpenExisting: () => _onSelectExistingDatabase(context),
              onOpenFromDrive: () => _openFromGoogleDrive(context),
            );

            if (!isTablet) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    const SizedBox(height: 18),
                    list,
                    const SizedBox(height: 16),
                    addSection,
                  ],
                ),
              );
            }

            // Tablet ≥600: identity/actions left, database cards right.
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                key: const ValueKey('selection-two-column-row'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 260,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          header,
                          const SizedBox(height: 18),
                          addSection,
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(child: SingleChildScrollView(child: list)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RecentHeader extends StatelessWidget {
  const _RecentHeader();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset(
            'assets/logo/app_icon_family/custode-source-1024.png',
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            cacheWidth: (40 * MediaQuery.devicePixelRatioOf(context)).round(),
            cacheHeight: (40 * MediaQuery.devicePixelRatioOf(context)).round(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Tooltip(
            message: 'Choose a database to continue',
            child: Text(
              'Databases',
              style: AppTextStyles.screenTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddSection extends StatelessWidget {
  const _AddSection({
    required this.onCreate,
    required this.onOpenExisting,
    required this.onOpenFromDrive,
  });

  final VoidCallback onCreate;
  final VoidCallback onOpenExisting;
  final VoidCallback onOpenFromDrive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    Widget row({
      required AppGlyph icon,
      required String label,
      required VoidCallback onTap,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(AppRadii.rowNested),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              KvIcon(glyph: icon, size: 18, color: colors.iconNeutral),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.rowTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              KvIcon(
                glyph: AppGlyph.chevronRight,
                size: 17,
                color: colors.iconNeutral,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(icon: AppGlyph.add, label: 'Create new database', onTap: onCreate),
        row(
          icon: AppGlyph.folderOpen,
          label: 'Open existing database',
          onTap: onOpenExisting,
        ),
        row(
          icon: AppGlyph.cloud,
          label: 'Open from Google Drive',
          onTap: onOpenFromDrive,
        ),
      ],
    );
  }
}
