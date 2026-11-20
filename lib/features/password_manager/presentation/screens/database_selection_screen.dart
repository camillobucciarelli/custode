import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

import '../../../../../core/navigation/app_navigation.dart';
import '../../../../../core/responsive/breakpoints.dart';
import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../../core/widgets/kv_circle_icon_button.dart';
import '../../../../../core/widgets/kv_confirm_dialog.dart';
import '../../../../../core/widgets/kv_spinner.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../../../injection_container.dart' as di;
import '../../domain/errors/database_access_failure.dart';
import '../../domain/models/database_dedup_result.dart';
import '../../domain/repositories/database_file_repository.dart';
import '../../domain/entities/database_record.dart';
import '../../domain/models/database_selection_item.dart';
import '../bloc/database_selection/database_selection_bloc.dart';
import '../bloc/database_selection/database_selection_event.dart';
import '../bloc/database_selection/database_selection_state.dart';
import 'create_database_screen.dart';
import 'database_unlock_screen.dart';
import 'vault_screen.dart';
import 'welcome_screen.dart';
import '../widgets/database/database_selection_sheets.dart';
import '../widgets/database/database_conflict_sheet.dart';
import '../widgets/database/database_source_sheet.dart';
import '../widgets/database/add_database_sheet.dart';
import '../widgets/database/database_grouped_list.dart';
import '../widgets/sync/remote_file_picker.dart';
import '../utils/platform_utils.dart';

class DatabaseSelectionScreen extends StatelessWidget {
  const DatabaseSelectionScreen({super.key, this.debugVaultBuilder});

  /// `VaultScreen` needs the whole vault DI graph; tests stub it here, like
  /// `DatabaseUnlockScreen.debugVaultBuilder`.
  @visibleForTesting
  final Widget Function(String databasePath)? debugVaultBuilder;

  /// Spec 025 FR-O1/FR-O2: one entry for every source. The source sheet
  /// decides between the system picker and the remote list; both end in the
  /// same staging, conflict detection and conflict sheet.
  Future<void> _onOpenDatabase(BuildContext context) async {
    final source = await showDatabaseSourceSheet(context);
    if (source == null || !context.mounted) return;
    switch (source) {
      case DatabaseSource.device:
        await _pickLocalDatabase(context);
      case DatabaseSource.remote:
        final file = await pickRemoteFile(context);
        if (file == null || !context.mounted) return;
        context.read<DatabaseSelectionBloc>().add(
          SelectDriveDatabase(
            remoteProviderId: file.providerId,
            remoteFileId: file.id,
            remoteFileName: file.name,
          ),
        );
    }
  }

  /// Spec 025 FR-L1: the header "+" offers the same two actions as Welcome.
  Future<void> _onAddDatabase(BuildContext context) async {
    final action = await showAddDatabaseSheet(context);
    if (action == null || !context.mounted) return;
    switch (action) {
      case AddDatabaseAction.create:
        await _onCreateDatabase(context);
      case AddDatabaseAction.open:
        await _onOpenDatabase(context);
    }
  }

  Future<void> _onOpenRecentDatabase(
    BuildContext context,
    DatabaseSelectionItem item,
  ) async {
    if (item.isMissing) {
      // FR-L4: nothing to open; Unlock owns the repair state (locate,
      // download again, remove).
      AppNavigation.pushFadeReplacement(
        context,
        DatabaseUnlockScreen(databasePath: item.canonicalPath),
      );
      return;
    }
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

    if (!persistsDatabases) {
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

  Future<void> _pickLocalDatabase(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['kdbx'],
      // Bytes on every platform: managed storage and the browser both stage
      // from memory, desktop simply also has a path.
      withData: true,
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

    context.read<DatabaseSelectionBloc>().add(
      SelectExistingDatabase(
        fileName: fileName,
        selectedPath: selectedPath,
        selectedBytes: selectedFile.bytes,
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
                onPressed: !persistsDatabases
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

  Future<void> _handleDuplicateDecisionPrompt(
    BuildContext context,
    DatabaseSelectionDuplicateDecisionRequired state,
  ) async {
    final bloc = context.read<DatabaseSelectionBloc>();
    final prompt = state.duplicatePrompt;
    final decision = await showDatabaseConflictSheet(
      context,
      importedName: prompt.imported.fileName,
      importedRemote: prompt.imported.sourceType == DatabaseSourceType.drive,
      existingName: prompt.existingRecord.displayName,
      // Remote means "has a sync mapping" (FR-X4), not the record's origin.
      existingRemote: state.items.any(
        (item) =>
            item.databaseId == prompt.existingRecord.databaseId &&
            item.remoteProviderId != null,
      ),
      recommendExisting: prompt.matchType != DatabaseDuplicateMatchType.name,
      allowReplace: prompt.canReplaceExisting,
    );
    // Any dismissal is a cancel (spec 025 FR-O7): the staged import must
    // never outlive the question.
    if (bloc.isClosed) return;
    bloc.add(
      ResolveDuplicateDecision(decision ?? DatabaseDuplicateResolution.cancel),
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
              // The wizard does not pop itself on success (FR-C6), so exactly
              // one navigation happens: close it, then replace this screen.
              final route = ModalRoute.of(context);
              Navigator.of(context).popUntil((r) => r == route);
              AppNavigation.pushFadeReplacement(
                context,
                state.openVault
                    ? debugVaultBuilder?.call(state.path) ??
                          VaultScreen(databasePath: state.path)
                    : DatabaseUnlockScreen(databasePath: state.path),
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
            if (state is DatabaseSelectionInitial) {
              return const Center(child: CircularProgressIndicator());
            }
            // Spec 025 FR-X6: a running action keeps the screen mounted and
            // puts the spinner over it, so the user never loses their place.
            return Stack(
              children: [
                _content(context, state),
                if (state is DatabaseSelectionLoading)
                  _BusyOverlay(label: state.label),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _content(BuildContext context, DatabaseSelectionState state) {
    if (state.items.isEmpty) {
      return WelcomeScreen(
        onCreateDatabase: () => _onCreateDatabase(context),
        onOpenDatabase: () => _onOpenDatabase(context),
      );
    }

    final viewportWidth = MediaQuery.sizeOf(context).width;
    final isTablet = viewportWidth >= Breakpoints.mobile;

    final header = _RecentHeader(onAdd: () => _onAddDatabase(context));
    final list = DatabaseGroupedList(
      items: state.items,
      remoteAccount: state.remoteAccount,
      onOpen: (item) => _onOpenRecentDatabase(context, item),
      onExport: (item) => _onExportRecentDatabase(context, item),
      onRemove: (item) => _onRemoveRecentDatabase(context, item),
      onLocate: (item) => _onLocateDatabase(context, item),
    );

    if (!isTablet) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, const SizedBox(height: 22), list],
        ),
      );
    }

    // Tablet >=600: identity and "+" left, database groups right.
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        key: const ValueKey('selection-two-column-row'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 260, child: header),
          const SizedBox(width: 24),
          Expanded(child: SingleChildScrollView(child: list)),
        ],
      ),
    );
  }
}

/// The labelled, non-destructive busy state (spec 025 FR-X6).
class _BusyOverlay extends StatelessWidget {
  const _BusyOverlay({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Positioned.fill(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: label ?? 'Working',
        child: ColoredBox(
          color: colors.ground.withValues(alpha: 0.72),
          child: Center(
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const KvSpinner(),
                  if (label != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      label!,
                      textAlign: TextAlign.center,
                      style: AppTextStyles.body.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentHeader extends StatelessWidget {
  const _RecentHeader({required this.onAdd});

  final VoidCallback onAdd;

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
            child: Semantics(
              header: true,
              child: Text(
                'Databases',
                style: AppTextStyles.screenTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        KvCircleIconButton(
          glyph: AppGlyph.add,
          tooltip: 'Add database',
          filled: true,
          size: 44,
          iconSize: 20,
          onPressed: onAdd,
        ),
      ],
    );
  }
}
