part of '../vault_screen.dart';

String? _validateCustomFieldRows(List<_CustomFieldFormRow> rows) {
  final seen = <String>{};
  for (final row in rows) {
    final key = row.key.trim();
    final value = row.value.trim();
    if (key.isEmpty && value.isEmpty) {
      continue;
    }

    if (key.isEmpty) {
      return 'Custom field key cannot be empty.';
    }

    final normalized = key.toLowerCase();
    if (seen.contains(normalized)) {
      return 'Custom field keys must be unique.';
    }
    seen.add(normalized);
  }

  return null;
}

String? _validateOtpUri(String otpUri) {
  final trimmed = otpUri.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || !trimmed.startsWith('otpauth://')) {
    return 'OTP URI must start with otpauth://';
  }

  return null;
}

bool _isOtpFieldKey(String key) {
  final normalized = key.toLowerCase().trim();
  return normalized == 'otp' ||
      normalized == 'totp' ||
      normalized == 'otpauth' ||
      normalized.contains('otp');
}

List<VaultCustomField> _buildCustomFields({
  required List<_CustomFieldFormRow> customFieldRows,
  required String otpUri,
  List<String> extraUrls = const [],
  bool otpProtected = false,
}) {
  final fields = customFieldRows
      .map(
        (row) => VaultCustomField(
          key: row.key.trim(),
          value: row.value.trim(),
          isProtected: row.isProtected,
        ),
      )
      .where((field) => field.key.isNotEmpty)
      .where((field) => !_isOtpFieldKey(field.key))
      .toList(growable: true);

  // Additional websites travel as `KP2A_URL_n` custom strings — the
  // KeePass2Android/KeePassXC convention, so other clients and our own
  // autofill matchers (isUrlFieldKey) pick them up. Renumbered on every
  // save so removals leave no gaps.
  //
  // A protected URL-keyed string stays a custom field row (it keeps its
  // Secret switch there rather than being rebuilt as plain text), so it is
  // already in `fields` under its original name. Renumbering steps over any
  // name it holds, or the save would emit two fields called `KP2A_URL_1`.
  final takenKeys = fields.map((field) => field.key.toLowerCase()).toSet();
  var urlIndex = 0;
  for (final url in extraUrls) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    String key;
    do {
      urlIndex++;
      key = '$kp2aUrlKeyPrefix$urlIndex';
    } while (takenKeys.contains(key.toLowerCase()));
    fields.add(VaultCustomField(key: key, value: trimmed));
  }

  final trimmedOtpUri = otpUri.trim();
  if (trimmedOtpUri.isNotEmpty) {
    fields.add(
      VaultCustomField(
        key: 'otp',
        value: trimmedOtpUri,
        isProtected: otpProtected,
      ),
    );
  }

  return fields;
}

double _dialogContentWidth(BuildContext context, double preferredWidth) {
  final viewport = MediaQuery.sizeOf(context).width;
  final availableWidth = viewport - 56;
  if (availableWidth < 280) {
    return viewport - 24;
  }
  return math.min(preferredWidth, availableWidth);
}

bool _isVeryCompactDialogWidth(BuildContext context) {
  return MediaQuery.sizeOf(context).width < 340;
}

EdgeInsets _dialogInsetPadding(BuildContext context) {
  if (_isVeryCompactDialogWidth(context)) {
    return const EdgeInsets.symmetric(horizontal: 12, vertical: 20);
  }
  return const EdgeInsets.symmetric(horizontal: 20, vertical: 24);
}

EdgeInsets _dialogContentPadding(BuildContext context) {
  if (_isVeryCompactDialogWidth(context)) {
    return const EdgeInsets.fromLTRB(12, 10, 12, 6);
  }
  return const EdgeInsets.fromLTRB(20, 18, 20, 12);
}

List<Widget> _adaptiveDialogActions(
  BuildContext context,
  List<Widget> actions,
) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 360) {
    return actions;
  }

  return actions
      .map((action) => SizedBox(width: double.infinity, child: action))
      .toList(growable: false);
}

void _showSyncSnackBar(
  BuildContext context,
  String message, {
  required DatabaseSyncStatus status,
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  final background = switch (status) {
    DatabaseSyncStatus.success => AppColors.success,
    DatabaseSyncStatus.conflict => AppColors.warning,
    DatabaseSyncStatus.error => theme.colorScheme.error,
    DatabaseSyncStatus.syncing => theme.colorScheme.primary,
    DatabaseSyncStatus.idle => theme.colorScheme.surfaceContainerHighest,
    DatabaseSyncStatus.disconnected =>
      theme.colorScheme.surfaceContainerHighest,
  };
  final useLightForeground =
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark;

  final foreground = switch (status) {
    DatabaseSyncStatus.error => theme.colorScheme.onError,
    DatabaseSyncStatus.syncing =>
      useLightForeground ? Colors.white : Colors.black87,
    DatabaseSyncStatus.success =>
      useLightForeground ? Colors.white : Colors.black87,
    DatabaseSyncStatus.conflict =>
      useLightForeground ? Colors.white : Colors.black87,
    DatabaseSyncStatus.idle => theme.colorScheme.onSurface,
    DatabaseSyncStatus.disconnected => theme.colorScheme.onSurface,
  };

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(color: foreground)),
        backgroundColor: background,
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        closeIconColor: foreground,
        action: action,
      ),
    );
}

// spec-005: the combined create/pick dialog (`_showLinkDatabaseDialog`) is
// gone — the Sync hero now offers "Create a new file" and "Pick an
// existing .kdbx" as two independent one-tap actions (see
// vault_sync.part.dart). This helper (still used by the Vault-tab overflow
// menu's "Link" item) now goes straight to the existing-file picker, which
// is the only ambiguous choice left; connecting first is still required.
String _formatSyncDateTime(DateTime value) {
  final local = value.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$d-$m-$y $hh:$mm';
}

String _formatEntryDateTime(DateTime? value) {
  if (value == null) {
    return 'Not available';
  }
  return _formatSyncDateTime(value);
}

// FR-8/T17: shared with the legacy sync-strip overflow menu
// (`_SyncStripMenuButton`) and the new Backups destination — one
// implementation, "unchanged in behaviour" per FR-8.
Future<void> _exportDatabaseBackup(
  BuildContext context,
  String databasePath, {
  String? databaseLabel,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (databasePath.trim().isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No active database to export.')),
    );
    return;
  }

  final source = File(databasePath);
  if (!await source.exists()) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Current database file not found.')),
    );
    return;
  }

  // The macOS save panel appends the allowed extension itself, so a full
  // basename showed "name.kdbx.kdbx". The resolvedPath guard below restores
  // ".kdbx" where the platform does not append it.
  // spec 014 FR-3: on mobile the stored file is an opaque identifier, so the
  // suggested name comes from the registry, not from the path.
  final defaultName = path.basenameWithoutExtension(
    databaseLabel ?? path.basename(databasePath),
  );
  final savePath = await FilePicker.saveFile(
    dialogTitle: 'Export database backup',
    fileName: defaultName,
    type: FileType.custom,
    allowedExtensions: const ['kdbx'],
  );
  if (savePath == null || savePath.trim().isEmpty) {
    return;
  }

  final resolvedPath = savePath.toLowerCase().endsWith('.kdbx')
      ? savePath
      : '$savePath.kdbx';
  // spec 008 T102: exports go through the domain port, never dart:io.
  await di.sl<DatabaseFileRepository>().copyFile(
    sourcePath: databasePath,
    targetPath: resolvedPath,
  );
  messenger.showSnackBar(
    const SnackBar(content: Text('Database backup exported.')),
  );
}

Future<void> _exportKeyFileBackup(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final keyPath = await di
      .sl<VaultSessionCoordinator>()
      .getSelectedKeyFilePath();
  if (keyPath == null || keyPath.trim().isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No key file configured for this vault.')),
    );
    return;
  }

  final source = File(keyPath);
  if (!await source.exists()) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Configured key file was not found.')),
    );
    return;
  }

  // Same double-extension fix as the database export above.
  final defaultName = path.basenameWithoutExtension(keyPath);
  final savePath = await FilePicker.saveFile(
    dialogTitle: 'Export key file backup',
    fileName: defaultName,
    type: FileType.custom,
    allowedExtensions: const ['key'],
  );
  if (savePath == null || savePath.trim().isEmpty) {
    return;
  }

  final resolvedPath = savePath.toLowerCase().endsWith('.key')
      ? savePath
      : '$savePath.key';
  await di.sl<DatabaseFileRepository>().copyFile(
    sourcePath: keyPath,
    targetPath: resolvedPath,
  );
  messenger.showSnackBar(
    const SnackBar(content: Text('Key file backup exported.')),
  );
}

// FR-7 / T14/T16: CSV import preview (screen 15) and outcome (screen 16).
// Both screen widgets live in the public `csv_import_screens.dart` (not
// this part-family) so they can be pumped directly in tests without
// fighting the unmockable `FilePicker` plugin — this function is the only
// thing that touches `FilePicker`.
Future<void> _startCsvImportFlow(BuildContext context) async {
  final picked = await FilePicker.pickFiles(
    allowMultiple: false,
    type: FileType.custom,
    allowedExtensions: const ['csv'],
    withData: false,
  );
  final pickedFile = picked?.files.single;
  final filePath = pickedFile?.path;
  if (pickedFile == null || filePath == null || !context.mounted) {
    return;
  }

  final importService = di.sl<VaultCsvImportService>();
  final messenger = ScaffoldMessenger.of(context);

  VaultCsvParseResult preview;
  try {
    preview = await importService.parseFile(filePath);
  } catch (e) {
    if (!context.mounted) {
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    return;
  }

  if (!context.mounted) {
    return;
  }

  final importResult = await VaultShellRouterScope.of(context)
      .open<CsvImportResult>(
        context: context,
        surface: DatabaseSettingsSurface<CsvImportResult>(
          builder: (dialogContext) => CsvImportPreviewScreen(
            filePath: filePath,
            fileSizeBytes: pickedFile.size,
            preview: preview,
            onCancel: () => VaultOperationScope.of(dialogContext).cancel(),
            onImport: (avoidDuplicates) => VaultOperationScope.of(dialogContext)
                .complete(
                  CsvImportResult(
                    filePath: filePath,
                    avoidDuplicates: avoidDuplicates,
                  ),
                ),
          ),
        ),
      );

  if (importResult == null || !context.mounted) {
    return;
  }

  final bloc = context.read<VaultBloc>();
  bloc.add(
    ImportVaultEntriesFromCsv(
      filePath: importResult.filePath,
      avoidDuplicates: importResult.avoidDuplicates,
    ),
  );

  // AC8: wait for the import to finish so the outcome screen can read the
  // per-row skip reasons `VaultBloc` just computed, then show it.
  await bloc.stream.firstWhere((state) => !state.isSaving);
  if (!context.mounted) {
    return;
  }
  final outcome = bloc.state.lastCsvImportOutcome;
  if (outcome == null) {
    return;
  }

  await VaultShellRouterScope.of(context).open<VaultDone>(
    context: context,
    surface: DatabaseSettingsSurface<VaultDone>(
      builder: (dialogContext) => CsvImportOutcomeScreen(
        outcome: outcome,
        onDone: () =>
            VaultOperationScope.of(dialogContext).complete(const VaultDone()),
      ),
    ),
  );
  bloc.add(const ClearCsvImportOutcome());
}

/// Shown wherever a record has no attachment, in the detail and the editor.
const _kNoAttachmentsLabel = 'No attachments';

/// One attachment, drawn the same in a record's detail and in its editor.
///
/// Only the trailing action differs: export where the record is read, remove
/// where it is edited. Two different looks for the same file is what made the
/// two screens read as unrelated features.
class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    super.key,
    required this.name,
    required this.caption,
    required this.trailing,
  });

  final String name;

  /// The file's size, or a note that it is not saved yet.
  final String caption;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<KeyVaultColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.row),
      ),
      child: Row(
        children: [
          KvIcon(
            glyph: AppGlyph.attachment,
            size: 18,
            color: colors.iconNeutral,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.fieldValue.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.secondary.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}
