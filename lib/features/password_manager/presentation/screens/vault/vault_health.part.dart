part of '../vault_screen.dart';

// FR-4 / T4: Health destination (screen 9). Score circle 64 (Caprasimo 22);
// five `KvListRow`-style category rows, each with a Caprasimo 18 count
// before the chevron. Every category is tappable: "Duplicates" opens the
// full Duplicates screen (T10); the other four (weak/reused/old/unmatchable)
// open a generic flat filtered-entries list (`_HealthCategoryListScreen`)
// scoped to that category's `entryIds`.

class _VaultHealthDestination extends StatelessWidget {
  const _VaultHealthDestination();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return BlocBuilder<VaultBloc, VaultState>(
      // Compare score + per-category counts only, not `healthReport` itself
      // — its `HealthCategory.entryIds` lists make `Equatable.==` O(entries)
      // per comparison, and this buildWhen runs on every VaultState change
      // in the whole app (every search keystroke, every tick). Same
      // lightweight-comparison rule as `VaultState.props` — see its
      // comment. The row builder below only renders score + count per
      // category, never entryIds, so this can't miss a visible change.
      buildWhen: (previous, current) =>
          previous.healthReport.score != current.healthReport.score ||
          !_sameCategoryCounts(
            previous.healthReport.categories,
            current.healthReport.categories,
          ) ||
          previous.allEntries.length != current.allEntries.length ||
          previous.databasePath != current.databasePath,
      builder: (context, state) {
        final report = state.healthReport;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Health',
                style: AppTextStyles.screenTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              Text(
                '${state.allEntries.length} records in '
                '${state.databaseLabel}',
                style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: 18),
              _ScoreCard(report: report),
              const SizedBox(height: 10),
              for (final kind in HealthCategoryKind.values) ...[
                _HealthCategoryRow(
                  category: report.category(kind),
                  onTap: () => switch (kind) {
                    HealthCategoryKind.duplicates => _showDuplicatesDialog(
                      context,
                    ),
                    _ => _showHealthCategoryList(
                      context,
                      category: report.category(kind),
                    ),
                  },
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }
}

bool _sameCategoryCounts(
  List<HealthCategory> previous,
  List<HealthCategory> current,
) {
  if (previous.length != current.length) {
    return false;
  }
  for (var i = 0; i < previous.length; i++) {
    if (previous[i].kind != current[i].kind ||
        previous[i].count != current[i].count) {
      return false;
    }
  }
  return true;
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.report});

  final VaultHealthReport report;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final needsAttention = report.categories
        .where((c) => c.kind != HealthCategoryKind.duplicates)
        .fold<int>(0, (sum, c) => sum + c.count);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.card + 2),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: colors.positiveTint,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '${report.score}',
              style: AppTextStyles.numericLarge.copyWith(
                fontFamily: AppTextStyles.headingFamily,
                fontWeight: FontWeight.w400,
                color: colors.positiveText,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _statusLabel(report.score),
                  style: AppTextStyles.panelTitleLarge.copyWith(
                    fontSize: 18,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  needsAttention == 0
                      ? 'No records need attention'
                      : needsAttention == 1
                      ? '1 record needs attention'
                      : '$needsAttention records need attention',
                  style: AppTextStyles.secondary.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _statusLabel(int score) {
    if (score >= 90) return 'Looking great';
    if (score >= 70) return 'Mostly healthy';
    if (score >= 40) return 'Needs attention';
    return 'At risk';
  }
}

class _HealthCategoryInfo {
  const _HealthCategoryInfo({
    required this.title,
    required this.subtitle,
    required this.glyph,
    required this.variant,
  });

  final String title;
  final String subtitle;
  final AppGlyph glyph;
  final KvTagVariant variant;
}

const _healthCategoryInfo = <HealthCategoryKind, _HealthCategoryInfo>{
  HealthCategoryKind.weak: _HealthCategoryInfo(
    title: 'Weak passwords',
    subtitle: 'Under 40 bits of entropy',
    glyph: AppGlyph.warning,
    variant: KvTagVariant.attention,
  ),
  HealthCategoryKind.reused: _HealthCategoryInfo(
    title: 'Reused passwords',
    subtitle: 'Same password in 2+ records',
    glyph: AppGlyph.copy,
    variant: KvTagVariant.attention,
  ),
  HealthCategoryKind.old: _HealthCategoryInfo(
    title: 'Old passwords',
    subtitle: 'Not changed in over 2 years',
    glyph: AppGlyph.clock,
    variant: KvTagVariant.neutral,
  ),
  HealthCategoryKind.duplicates: _HealthCategoryInfo(
    title: 'Duplicates',
    subtitle: 'Same site and username',
    glyph: AppGlyph.duplicates,
    variant: KvTagVariant.positive,
  ),
  HealthCategoryKind.unmatchable: _HealthCategoryInfo(
    title: 'Missing URL or username',
    subtitle: "Autofill can't match these",
    glyph: AppGlyph.searchOff,
    variant: KvTagVariant.positive,
  ),
};

class _HealthCategoryRow extends StatelessWidget {
  const _HealthCategoryRow({required this.category, this.onTap});

  final HealthCategory category;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final info = _healthCategoryInfo[category.kind]!;
    final (background, foreground) = switch (info.variant) {
      KvTagVariant.attention => (colors.attentionTint, colors.attentionText),
      KvTagVariant.positive => (colors.positiveTint, colors.positiveText),
      _ => (colors.surfaceNested, colors.textSecondary),
    };

    return KvListRow(
      title: info.title,
      subtitle: info.subtitle,
      onTap: onTap,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppRadii.iconSquare),
        ),
        alignment: Alignment.center,
        child: KvIcon(glyph: info.glyph, size: 19, color: foreground),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${category.count}',
            style: AppTextStyles.panelTitleLarge.copyWith(
              fontSize: 18,
              color: colors.textPrimary,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            KvIcon(
              glyph: AppGlyph.chevronRight,
              size: 17,
              color: colors.textTertiary,
            ),
          ],
        ],
      ),
    );
  }
}

/// T4: the flat filtered-entries destination for the four non-duplicate
/// health categories (weak/reused/old/unmatchable). Deliberately not one of
/// spec.md's 17 numbered design screens, so it skips grouping/search and the
/// illustrated empty state `_DuplicatesEmptyState` uses — a one-line message
/// is enough here.
Future<VaultDone?> _showHealthCategoryList(
  BuildContext context, {
  required HealthCategory category,
}) {
  final bloc = context.read<VaultBloc>();
  final title = _healthCategoryInfo[category.kind]!.title;
  final entryIds = category.entryIds.toSet();

  return VaultShellRouterScope.of(context).open<VaultDone>(
    context: context,
    surface: HealthCategorySurface<VaultDone>(
      builder: (surfaceContext) => BlocProvider.value(
        value: bloc,
        child: _HealthCategoryListScreen(title: title, entryIds: entryIds),
      ),
    ),
  );
}

class _HealthCategoryListScreen extends StatelessWidget {
  const _HealthCategoryListScreen({
    required this.title,
    required this.entryIds,
  });

  final String title;
  final Set<String> entryIds;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 14, 0),
              child: Row(
                children: [
                  KvCircleIconButton(
                    glyph: AppGlyph.back,
                    tooltip: 'Back',
                    onPressed: () =>
                        VaultOperationScope.of(context)
                            .complete(const VaultDone()),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: BlocBuilder<VaultBloc, VaultState>(
                      buildWhen: (p, n) =>
                          p.allEntries.length != n.allEntries.length,
                      builder: (context, state) {
                        final count = state.allEntries
                            .where((entry) => entryIds.contains(entry.id))
                            .length;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: AppTextStyles.panelTitleLarge.copyWith(
                                fontSize: 19,
                                color: colors.textPrimary,
                              ),
                            ),
                            Text(
                              '$count records',
                              style: AppTextStyles.meta.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: BlocBuilder<VaultBloc, VaultState>(
                buildWhen: (p, n) => p.allEntries != n.allEntries,
                builder: (context, state) {
                  final entries = state.allEntries
                      .where((entry) => entryIds.contains(entry.id))
                      .toList(growable: false);

                  if (entries.isEmpty) {
                    return Center(
                      child: Text(
                        'No records in this category',
                        style: AppTextStyles.body.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final subtitle = entry.username.isNotEmpty
                          ? entry.username
                          : (entry.url.isNotEmpty ? entry.url : null);
                      return KvListRow(
                        title: entry.title.isEmpty ? '(Untitled)' : entry.title,
                        subtitle: subtitle,
                        onTap: () => _openEntryDetailsSurface(
                          context,
                          entryId: entry.id,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
