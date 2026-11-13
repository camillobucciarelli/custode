import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../../core/theme/app_icons.dart';
import '../../../../core/theme/app_radii.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/custode_colors.dart';
import '../../../../core/utils/mobile_file_storage.dart';
import '../../../../injection_container.dart' as di;
import '../../domain/repositories/database_file_repository.dart';
import '../../../../core/widgets/kv_bottom_sheet.dart';
import '../../../../core/widgets/kv_confirm_dialog.dart';

class InternalKeyFileManagerResult {
  const InternalKeyFileManagerResult({
    this.selectedPath,
    this.currentSelectionDeleted = false,
  });

  final String? selectedPath;
  final bool currentSelectionDeleted;
}

/// Listing seam so tests can inject a synchronous fake instead of exercising
/// real `dart:io` directory listing (which does not resolve inside
/// `testWidgets`'s fake-async zone without `tester.runAsync`). Defaults to
/// the real implementation for production use.
typedef KeyFileLister = Future<List<AppStorageFileEntry>> Function({
  required String subdirectory,
});

/// T18: typed sheet replacement for the former dialog — same
/// [InternalKeyFileManagerResult] contract and actions, moved to
/// `KvBottomSheet.show<T>` (C-6: selection/unlock surfaces never use
/// `showDialog`).
Future<InternalKeyFileManagerResult?> showInternalKeyFileManagerSheet(
  BuildContext context, {
  String? initiallySelectedPath,
  Set<String> protectedPaths = const {},
  KeyFileLister listKeyFiles = MobileFileStorage.listFilesInAppDirectory,
}) {
  return KvBottomSheet.show<InternalKeyFileManagerResult>(
    context: context,
    builder: (sheetContext) => _InternalKeyFileManagerSheet(
      initiallySelectedPath: initiallySelectedPath,
      protectedPaths: protectedPaths,
      listKeyFiles: listKeyFiles,
    ),
  );
}

bool isProtectedKeyFilePath(String filePath, Iterable<String> protectedPaths) {
  final normalizedPath = p.normalize(filePath.trim());
  return protectedPaths.any(
    (path) => p.equals(p.normalize(path.trim()), normalizedPath),
  );
}

class _InternalKeyFileManagerSheet extends StatefulWidget {
  const _InternalKeyFileManagerSheet({
    this.initiallySelectedPath,
    required this.protectedPaths,
    required this.listKeyFiles,
  });

  final String? initiallySelectedPath;
  final Set<String> protectedPaths;
  final KeyFileLister listKeyFiles;

  @override
  State<_InternalKeyFileManagerSheet> createState() =>
      _InternalKeyFileManagerSheetState();
}

class _InternalKeyFileManagerSheetState
    extends State<_InternalKeyFileManagerSheet> {
  static const _keysSubdirectory = 'keys';

  var _entries = const <AppStorageFileEntry>[];
  var _isLoading = true;
  var _currentSelectionDeleted = false;

  @override
  void initState() {
    super.initState();
    _reloadEntries();
  }

  Future<void> _reloadEntries() async {
    setState(() => _isLoading = true);

    final entries = await widget.listKeyFiles(subdirectory: _keysSubdirectory);
    if (!mounted) return;

    setState(() {
      _entries = entries;
      _isLoading = false;
    });
  }

  Future<void> _importKeyFile() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: false,
      withData: true,
      dialogTitle: 'Import key file',
    );
    if (!mounted || result == null) return;

    final selected = result.files.single;
    final fallbackName = selected.name.trim().isEmpty
        ? 'imported-key'
        : selected.name;
    String? importedPath = selected.path;

    if (importedPath != null && importedPath.trim().isNotEmpty) {
      importedPath = await MobileFileStorage.copyFileToAppDirectory(
        sourcePath: importedPath,
        fallbackFileName: fallbackName,
        subdirectory: _keysSubdirectory,
      );
    } else if (selected.bytes != null) {
      importedPath = await MobileFileStorage.saveBytesToAppDirectory(
        bytes: selected.bytes!,
        fileName: fallbackName,
        subdirectory: _keysSubdirectory,
      );
    }

    if (!mounted || importedPath == null || importedPath.trim().isEmpty) {
      return;
    }

    Navigator.of(context).pop(
      InternalKeyFileManagerResult(
        selectedPath: importedPath,
        currentSelectionDeleted: _currentSelectionDeleted,
      ),
    );
  }

  Future<void> _exportKeyFile(AppStorageFileEntry entry) async {
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Export key file',
      fileName: entry.name,
      type: FileType.any,
    );
    if (!mounted || savePath == null || savePath.trim().isEmpty) return;

    final source = File(entry.path);
    if (!await source.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selected key file was not found.')),
      );
      await _reloadEntries();
      return;
    }

    // spec 008 T102: exports go through the domain port, never dart:io.
    await di.sl<DatabaseFileRepository>().copyFile(
      sourcePath: entry.path,
      targetPath: savePath,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Key file exported.')));
  }

  Future<void> _deleteKeyFile(AppStorageFileEntry entry) async {
    if (isProtectedKeyFilePath(entry.path, widget.protectedPaths)) {
      return;
    }
    final confirmed = await showKvConfirmDialog(
      context,
      title: 'Delete key file?',
      body: 'Delete "${entry.name}" from app storage?',
      confirmLabel: 'Delete',
    );

    if (!mounted || confirmed != true) return;

    await MobileFileStorage.deleteFileFromAppDirectory(
      filePath: entry.path,
      subdirectory: _keysSubdirectory,
    );

    final selected = widget.initiallySelectedPath;
    if (selected != null && selected.trim() == entry.path.trim()) {
      _currentSelectionDeleted = true;
    }

    await _reloadEntries();
  }

  String _formatFileMeta(AppStorageFileEntry entry) {
    final sizeKb = entry.sizeBytes / 1024;
    final date = entry.modifiedAt;
    final dateLabel =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return '${sizeKb.toStringAsFixed(1)} KB • $dateLabel';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Internal key files',
            textAlign: TextAlign.center,
            style: AppTextStyles.sheetTitleLarge.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: _isLoading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : _entries.isEmpty
                ? Text(
                    'No key files in app storage. Import one to use it.',
                    style: AppTextStyles.body.copyWith(
                      color: colors.textSecondary,
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      final isCurrent =
                          widget.initiallySelectedPath?.trim() ==
                          entry.path.trim();
                      final isProtected = isProtectedKeyFilePath(
                        entry.path,
                        widget.protectedPaths,
                      );
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.surfaceNested,
                          borderRadius: BorderRadius.circular(
                            AppRadii.rowNested,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isCurrent ? AppIcons.check : AppIcons.fileKey,
                              size: 20,
                              color: colors.iconNeutral,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.name,
                                    style: AppTextStyles.rowTitle.copyWith(
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    _formatFileMeta(entry),
                                    style: AppTextStyles.secondary.copyWith(
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(
                                InternalKeyFileManagerResult(
                                  selectedPath: entry.path,
                                  currentSelectionDeleted:
                                      _currentSelectionDeleted,
                                ),
                              ),
                              child: const Text('Select'),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (value) async {
                                switch (value) {
                                  case 'export':
                                    await _exportKeyFile(entry);
                                    break;
                                  case 'delete':
                                    await _deleteKeyFile(entry);
                                    break;
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem<String>(
                                  value: 'export',
                                  child: Text('Export'),
                                ),
                                PopupMenuItem<String>(
                                  value: 'delete',
                                  enabled: !isProtected,
                                  child: Text(
                                    isProtected
                                        ? 'Delete (remove from vault first)'
                                        : 'Delete',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _importKeyFile,
                  icon: const Icon(AppIcons.attachment),
                  label: const Text('Import'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    InternalKeyFileManagerResult(
                      currentSelectionDeleted: _currentSelectionDeleted,
                    ),
                  ),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
