import 'package:flutter/material.dart';

import '../../../../../core/theme/app_icons.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../domain/models/database_selection_item.dart';
import 'database_item_tile.dart';

/// FR-1: reused as the metadata/missing row list. Accepts C-1
/// [DatabaseSelectionItem]s instead of the former path-only list.
class RecentDatabasesSection extends StatefulWidget {
  const RecentDatabasesSection({
    super.key,
    required this.items,
    required this.onOpen,
    required this.onExport,
    required this.onRemove,
    required this.onLocate,
  });

  final List<DatabaseSelectionItem> items;
  final Future<void> Function(DatabaseSelectionItem item) onOpen;
  final Future<void> Function(DatabaseSelectionItem item) onExport;
  final Future<void> Function(DatabaseSelectionItem item) onRemove;
  final Future<void> Function(DatabaseSelectionItem item) onLocate;

  @override
  State<RecentDatabasesSection> createState() => _RecentDatabasesSectionState();
}

class _RecentDatabasesSectionState extends State<RecentDatabasesSection> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = Theme.of(context).extension<CustodeColors>()!;
    final normalizedQuery = _query.trim().toLowerCase();
    final filtered = widget.items
        .where((item) {
          if (normalizedQuery.isEmpty) {
            return true;
          }
          return item.displayName.toLowerCase().contains(normalizedQuery) ||
              item.canonicalPath.toLowerCase().contains(normalizedQuery);
        })
        .toList(growable: false);
    final showSearch = widget.items.length > 5;

    // No section title: the screen header already reads "Databases" and the
    // list is every registered database, not a recency subset.
    return Semantics(
      hint: widget.items.length > 1
          ? 'Multiple databases are available. Pick one from the list or open another file.'
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showSearch) ...[
            TextFormField(
              decoration: const InputDecoration(
                labelText: 'Search databases',
                prefixIcon: Icon(AppIcons.search),
              ),
              onChanged: (value) {
                setState(() {
                  _query = value;
                });
              },
            ),
            const SizedBox(height: 8),
          ],
          ...filtered.map((item) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DatabaseItemTile(
                item: item,
                onOpen: () => widget.onOpen(item),
                onExport: () => widget.onExport(item),
                onRemove: () => widget.onRemove(item),
                onLocate: item.isMissing ? () => widget.onLocate(item) : null,
              ),
            );
          }),
          if (filtered.isEmpty)
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
