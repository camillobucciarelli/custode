part of '../vault_screen.dart';

// FR-5 / T10-T12/T20: Duplicates destination — group cards (screen 10),
// merge-preview sheet with exactly the five `MergePreview` flags (screen
// 11), no-duplicates empty state (screen 12). Replaces the old dialog-based
// `_DuplicatesDialog`/`_showMergeReviewDialog` with first-class surfaces.

Future<VaultDone?> _showDuplicatesDialog(BuildContext context) async {
  final bloc = context.read<VaultBloc>();
  bloc.add(const LoadDuplicates());

  return VaultShellRouterScope.of(context).open<VaultDone>(
    context: context,
    surface: DuplicatesSurface<VaultDone>(
      builder: (dialogContext) {
        return BlocProvider.value(
          value: bloc,
          child: const _DuplicatesScreen(),
        );
      },
    ),
  );
}

/// Site groups keep the old "username · N records" line; credentials groups
/// (same username + password across sites) say how many sites are involved.
/// A passkey pairing (spec 023 FR-011a) says what makes it one account, since
/// the two records look nothing alike: one has a password, the other a passkey.
String _duplicateGroupSubtitle(DuplicateGroup group) {
  if (group.kind == DuplicateGroupKind.passkeyPassword) {
    final account = group.sharedUsername.isEmpty
        ? 'Same account'
        : group.sharedUsername;
    return '$account · same account, one holds the passkey';
  }
  if (group.sharedUrl == null) {
    final sites = group.urls.length;
    return '${group.entries.length} records · '
        '$sites ${sites == 1 ? 'site' : 'sites'}';
  }
  return group.sharedUsername.isEmpty
      ? '${group.entries.length} records'
      : '${group.sharedUsername} · ${group.entries.length} records';
}

class _DuplicatesScreen extends StatelessWidget {
  const _DuplicatesScreen();

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
              // 2026-08-31 (user-directed): a pushed screen at every width —
              // back button on the left, refresh on the right.
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
                  const SizedBox(width: 8),
                  Expanded(
                    child: BlocBuilder<VaultBloc, VaultState>(
                      buildWhen: (p, n) =>
                          p.duplicateGroups != n.duplicateGroups,
                      builder: (context, state) {
                        final entryCount = state.duplicateGroups.fold<int>(
                          0,
                          (sum, group) => sum + group.entries.length,
                        );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Manage duplicates',
                              style: AppTextStyles.panelTitleLarge.copyWith(
                                fontSize: 19,
                                color: colors.textPrimary,
                              ),
                            ),
                            Text(
                              '${state.duplicateGroups.length} groups · $entryCount records',
                              style: AppTextStyles.meta.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  KvCircleIconButton(
                    glyph: AppGlyph.refresh,
                    tooltip: 'Check again',
                    iconSize: 18,
                    onPressed: () =>
                        context.read<VaultBloc>().add(const LoadDuplicates()),
                  ),
                ],
              ),
            ),
            Expanded(
              child: BlocBuilder<VaultBloc, VaultState>(
                buildWhen: (p, n) =>
                    p.isDuplicatesLoading != n.isDuplicatesLoading ||
                    p.duplicateGroups != n.duplicateGroups ||
                    p.isSaving != n.isSaving,
                builder: (context, state) {
                  if (state.isDuplicatesLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (state.duplicateGroups.isEmpty) {
                    return const _DuplicatesEmptyState();
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    itemCount: state.duplicateGroups.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) => _DuplicateGroupCard(
                      group: state.duplicateGroups[index],
                      isBusy: state.isSaving,
                    ),
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

class _DuplicateGroupCard extends StatelessWidget {
  const _DuplicateGroupCard({required this.group, required this.isBusy});

  final DuplicateGroup group;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final primary = group.entries.first;
    final secondaries = group.entries.skip(1).toList(growable: false);
    final service = di.sl<VaultDuplicateService>();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              KvLetterAvatar(
                letter: group.sharedUrl ?? group.sharedUsername,
                size: 34,
                fontSize: 14,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      group.sharedUrl ?? group.sharedUsername,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.rowTitle.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      _duplicateGroupSubtitle(group),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.secondary.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _DuplicateEntryRow(entry: primary, tagLabel: 'Keep'),
          for (final secondary in secondaries) ...[
            const SizedBox(height: 7),
            _DuplicateEntryRow(entry: secondary, tagLabel: 'Merge'),
          ],
          if (secondaries.any(
            (secondary) =>
                service.previewMerge(primary, secondary).hasAnythingToCopy,
          )) ...[
            const SizedBox(height: 8),
            _CopyNoticeStrip(colors: colors),
          ],
          const SizedBox(height: 8),
          KvPillButton(
            label: secondaries.length == 1
                ? 'Merge and move duplicate'
                : 'Merge and move ${secondaries.length} duplicates',
            compact: true,
            onPressed: isBusy
                ? null
                : () => _handleMerge(context, primary, secondaries),
          ),
        ],
      ),
    );
  }

  Future<void> _handleMerge(
    BuildContext context,
    VaultEntry primary,
    List<VaultEntry> secondaries,
  ) async {
    final service = di.sl<VaultDuplicateService>();
    final previews = [
      for (final secondary in secondaries)
        service.previewMerge(primary, secondary),
    ];
    final confirmed = await _showMergePreviewSheet(context, previews);
    if (confirmed == ConfirmDecision.confirm && context.mounted) {
      context.read<VaultBloc>().add(
        MergeDuplicateEntries(
          primaryId: primary.id,
          secondaryIds: [for (final s in secondaries) s.id],
        ),
      );
    }
  }
}

class _CopyNoticeStrip extends StatelessWidget {
  const _CopyNoticeStrip({required this.colors});

  final CustodeColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: colors.attentionTint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          KvIcon(glyph: AppGlyph.info, size: 15, color: colors.attentionText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Some data will be copied',
              style: AppTextStyles.meta.copyWith(
                fontSize: 12,
                color: colors.attentionText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DuplicateEntryRow extends StatelessWidget {
  const _DuplicateEntryRow({required this.entry, required this.tagLabel});

  final VaultEntry entry;
  final String tagLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final modifiedAt = entry.updatedAt ?? entry.createdAt;
    final meta = <String>[
      if (modifiedAt != null) 'Modified ${_formatEntryDateTime(modifiedAt)}',
      ..._extraDataDescriptors(entry),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: colors.surfaceNested,
        borderRadius: BorderRadius.circular(AppRadii.rowNested),
      ),
      child: Row(
        children: [
          KvTag(
            label: tagLabel,
            variant: tagLabel == 'Keep'
                ? KvTagVariant.positive
                : KvTagVariant.neutral,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.title.isEmpty ? '(Untitled)' : entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.rowTitle.copyWith(
                    fontSize: 13.5,
                    color: colors.textPrimary,
                  ),
                ),
                if (meta.isNotEmpty)
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.meta.copyWith(
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

  List<String> _extraDataDescriptors(VaultEntry entry) {
    final has = <String>[
      if (entry.notes.trim().isNotEmpty) 'notes',
      if (entry.otpUri != null && entry.otpUri!.isNotEmpty) 'OTP',
    ];
    final descriptors = <String>[];
    if (has.isNotEmpty) {
      descriptors.add('has ${has.join(', ')}');
    }
    if (entry.attachments.isNotEmpty) {
      descriptors.add(
        entry.attachments.length == 1
            ? '1 attachment'
            : '${entry.attachments.length} attachments',
      );
    }
    return descriptors;
  }
}

/// FR-5/AC5/T11/T20: exactly the five `MergePreview` flags — no more, no
/// fewer. `customFieldKeysToCopy` (a list) collapses into a single row.
/// 2026-08-31 (user-directed): a full-screen pushed route, not a sheet.
Future<ConfirmDecision?> _showMergePreviewSheet(
  BuildContext context,
  List<MergePreview> previews,
) {
  return VaultShellRouterScope.of(context).open<ConfirmDecision>(
    context: context,
    surface: MergePreviewSurface<ConfirmDecision>(
      builder: (screenContext) => _MergePreviewScreen(previews: previews),
    ),
  );
}

class _MergePreviewScreen extends StatelessWidget {
  const _MergePreviewScreen({required this.previews});

  /// One per duplicate being folded into the kept entry; the sheet shows
  /// the union of what would be copied.
  final List<MergePreview> previews;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final primary = previews.first.primary;
    final primaryLabel = primary.title.isEmpty ? 'Untitled' : primary.title;
    final secondaryLabel = previews.length == 1
        ? (previews.first.secondary.title.isEmpty
              ? 'Untitled'
              : previews.first.secondary.title)
        : '${previews.length} duplicates';
    final willCopyNotes = previews.any((p) => p.willCopyNotes);
    final willCopyOtp = previews.any((p) => p.willCopyOtp);
    final willCopyAttachments = previews.any((p) => p.willCopyAttachments);
    final customFieldKeysToCopy = <String>{
      for (final p in previews) ...p.customFieldKeysToCopy,
    }.toList(growable: false);
    final urlsToCopy = <String>{for (final p in previews) ...p.urlsToCopy}
        .toList(growable: false);
    // spec 023 FR-008 — one row for the whole credential, named by its
    // relying party. No field of it is ever listed or displayed.
    final passkeySites = <String>{
      for (final p in previews)
        for (final passkey in p.passkeysToCopy) passkey.relyingPartyId,
    }.toList(growable: false);
    final passkeyConflict = previews.any((p) => p.passkeyConflict);

    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
              children: [
                Row(
                  children: [
                    KvCircleIconButton(
                      glyph: AppGlyph.back,
                      tooltip: 'Back',
                      onPressed: () =>
                          VaultOperationScope.of(context)
                              .complete(ConfirmDecision.cancel),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'What the merge does',
                      style: AppTextStyles.panelTitleLarge.copyWith(
                        fontSize: 19,
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Keeps $primaryLabel and moves $secondaryLabel to the recycle '
                  "bin, after copying what's missing into it. A dated copy of "
                  'the vault is saved first.',
                  style: AppTextStyles.body.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                // Exactly five rows — one per `MergePreview` flag (T20 counts
                // these via the `merge-flag-row-*` key prefix, since the row
                // widget itself is private to this library).
                _MergePreviewFlagRow(
                  key: const ValueKey('merge-flag-row-notes'),
                  active: willCopyNotes,
                  label: willCopyNotes
                      ? 'Notes — will be copied'
                      : 'Notes — kept item already has some',
                ),
                const SizedBox(height: 8),
                _MergePreviewFlagRow(
                  key: const ValueKey('merge-flag-row-attachments'),
                  active: willCopyAttachments,
                  label: willCopyAttachments
                      ? 'Attachments — missing ones will be copied'
                      : 'Attachments — nothing missing to copy',
                ),
                const SizedBox(height: 8),
                _MergePreviewFlagRow(
                  key: const ValueKey('merge-flag-row-customFields'),
                  active: customFieldKeysToCopy.isNotEmpty,
                  label: customFieldKeysToCopy.isEmpty
                      ? 'Custom fields — nothing missing to copy'
                      : 'Custom fields — ${customFieldKeysToCopy.join(', ')}',
                ),
                const SizedBox(height: 8),
                _MergePreviewFlagRow(
                  key: const ValueKey('merge-flag-row-urls'),
                  active: urlsToCopy.isNotEmpty,
                  label: urlsToCopy.isEmpty
                      ? 'Websites — nothing missing to copy'
                      : 'Websites — ${urlsToCopy.join(', ')}',
                ),
                const SizedBox(height: 8),
                _MergePreviewFlagRow(
                  key: const ValueKey('merge-flag-row-otp'),
                  active: willCopyOtp,
                  label: willCopyOtp
                      ? 'One-time code — will be copied'
                      : 'One-time code — kept item already has one',
                ),
                if (passkeySites.isNotEmpty || passkeyConflict) ...[
                  const SizedBox(height: 8),
                  _MergePreviewFlagRow(
                    key: const ValueKey('merge-flag-row-passkey'),
                    active: !passkeyConflict && passkeySites.isNotEmpty,
                    label: passkeyConflict
                        ? 'Passkey — cannot be merged: both records hold one '
                              'for the same account'
                        : 'Passkey — ${passkeySites.join(', ')} will move to '
                              'the kept record',
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  'Passwords are never merged: the kept record keeps its own.',
                  style: AppTextStyles.secondary.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                if (passkeyConflict) ...[
                  Text(
                    'Only the site knows which of the two passkeys it still '
                    'accepts, so this merge cannot run. Delete the passkey you '
                    'no longer use, then merge.',
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 9),
                ],
                KvPillButton(
                  label: previews.length == 1
                      ? 'Merge and move duplicate'
                      : 'Merge and move ${previews.length} duplicates',
                  onPressed: passkeyConflict
                      ? null
                      : () =>
                            VaultOperationScope.of(context)
                                .complete(ConfirmDecision.confirm),
                ),
                const SizedBox(height: 9),
                KvSecondaryPillButton(
                  label: 'Cancel',
                  onPressed: () =>
                      VaultOperationScope.of(context)
                          .complete(ConfirmDecision.cancel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MergePreviewFlagRow extends StatelessWidget {
  const _MergePreviewFlagRow({
    super.key,
    required this.active,
    required this.label,
  });

  final bool active;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.row),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: active ? colors.positiveTint : Colors.transparent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: KvIcon(
                glyph: active ? AppGlyph.check : AppGlyph.close,
                size: 16,
                color: active ? colors.positiveText : colors.textTertiary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: AppTextStyles.body.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DuplicatesEmptyState extends StatelessWidget {
  const _DuplicatesEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: colors.positiveTint,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: KvIcon(
                glyph: AppGlyph.check,
                size: 34,
                color: colors.positiveText,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No duplicates found',
              style: AppTextStyles.screenTitle.copyWith(
                fontSize: 24,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'No two records share the same credentials, or the same site '
              'and username. Custode checks again every time you open the '
              'vault.',
              style: AppTextStyles.body.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: 16),
            KvSecondaryPillButton(
              label: 'Check again',
              expand: false,
              onPressed: () =>
                  context.read<VaultBloc>().add(const LoadDuplicates()),
            ),
          ],
        ),
      ),
    );
  }
}
