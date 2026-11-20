import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_field_decoration.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../domain/models/database_selection_item.dart';
import '../../../domain/models/storage_account_summary.dart';
import 'database_item_tile.dart';
import 'source_chip.dart';

/// Spec 025 FR-L2: every registered database, grouped by where it lives.
/// `On this device` first, then one group per sync provider id, each headed
/// by [databaseSourceLabel]. [items] arrive most-recently-opened first and
/// keep that order inside their group.
class DatabaseGroupedList extends StatefulWidget {
  const DatabaseGroupedList({
    super.key,
    required this.items,
    this.remoteAccount,
    required this.onOpen,
    required this.onExport,
    required this.onRemove,
    required this.onLocate,
  });

  final List<DatabaseSelectionItem> items;

  /// Connected account for the remote header; null gives the bare label.
  final StorageAccountSummary? remoteAccount;
  final Future<void> Function(DatabaseSelectionItem item) onOpen;
  final Future<void> Function(DatabaseSelectionItem item) onExport;
  final Future<void> Function(DatabaseSelectionItem item) onRemove;
  final Future<void> Function(DatabaseSelectionItem item) onLocate;

  @override
  State<DatabaseGroupedList> createState() => _DatabaseGroupedListState();
}

class _DatabaseGroupedListState extends State<DatabaseGroupedList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = Theme.of(context).extension<CustodeColors>()!;
    final normalizedQuery = _query.trim().toLowerCase();
    // Insertion order: the local group (null key) is seeded first.
    final groups = <String?, List<DatabaseSelectionItem>>{null: []};
    for (final item in widget.items) {
      if (normalizedQuery.isEmpty ||
          item.displayName.toLowerCase().contains(normalizedQuery) ||
          item.canonicalPath.toLowerCase().contains(normalizedQuery)) {
        groups.putIfAbsent(item.remoteProviderId, () => []).add(item);
      }
    }
    groups.removeWhere((_, items) => items.isEmpty);

    return Semantics(
      hint: widget.items.length > 1
          ? 'Multiple databases are available. Pick one from the list or open another file.'
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.items.length > 5) ...[
            Semantics(
              label: 'Search databases',
              child: TextField(
                style: AppTextStyles.fieldValue.copyWith(
                  color: colors.textPrimary,
                ),
                decoration: kvFieldDecoration(colors, hint: 'Search databases'),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(height: 14),
          ],
          for (final group in groups.entries) ...[
            _GroupHeader(
              remote: group.key != null,
              label: group.key == null
                  ? 'On this device'
                  : databaseSourceLabel(
                      remote: true,
                      account: widget.remoteAccount,
                    ),
            ),
            for (final item in group.value)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DatabaseItemTile(
                  item: item,
                  onOpen: () => widget.onOpen(item),
                  onExport: () => widget.onExport(item),
                  onRemove: () => widget.onRemove(item),
                  onLocate: item.isMissing ? () => widget.onLocate(item) : null,
                ),
              ),
            const SizedBox(height: 14),
          ],
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'No database matches your search.',
                style: AppTextStyles.secondary.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.remote, required this.label});

  final bool remote;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            ExcludeSemantics(
              child: KvIcon(
                glyph: databaseSourceGlyph(remote: remote),
                size: 14,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.labelUpper.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
