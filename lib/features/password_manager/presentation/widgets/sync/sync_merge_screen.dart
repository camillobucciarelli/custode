// spec-008 Gate 6 (T601-T605) — the per-field merge review UI.
//
// Everything on screen comes from `VaultState.mergeReview` (redacted ids,
// choices, counts) and `VaultState.mergeCommitOutcome`. The only plaintext —
// a field's two values — is loaded by `SyncMergeFieldDisplayView` and lives in
// that widget's State alone (T503).
//
// Layout: one pane below [SyncMergeScreen.twoPaneMinWidth], two panes (decision
// list on the left, field detail on the right) at or above it. Every phase
// keeps the two facts the review must never hide: one-sided data is preserved
// automatically, and nothing is written until "Merge and sync".
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_circle_icon_button.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../domain/models/sync_merge_models.dart';
import '../../../domain/services/sync_merge_policy.dart';
import '../../../domain/usecases/load_sync_merge_field_display_usecase.dart';
import '../../bloc/vault/vault_bloc.dart';
import '../../bloc/vault/vault_event.dart';
import '../../bloc/vault/vault_state.dart';
import '../sync_merge_field_display_view.dart';

class SyncMergeScreen extends StatefulWidget {
  const SyncMergeScreen({
    super.key,
    required this.loadFieldDisplay,
    required this.onClose,
  });

  /// Width from which the decision list and the field detail sit side by side.
  static const double twoPaneMinWidth = 840;

  final LoadSyncMergeFieldDisplayUseCase loadFieldDisplay;
  final VoidCallback onClose;

  @override
  State<SyncMergeScreen> createState() => _SyncMergeScreenState();
}

class _SyncMergeScreenState extends State<SyncMergeScreen> {
  MergeDecisionId? _selected;

  /// Set when the user taps "Merge and sync": from here on a busy state is a
  /// commit in flight, and cancel is gone (T604 — the atomic boundary).
  bool _committing = false;

  /// Set by "Edit decisions" on the ready pane.
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: BlocConsumer<VaultBloc, VaultState>(
          listenWhen: (p, n) =>
              p.mergeReview != n.mergeReview || p.isMergeBusy != n.isMergeBusy,
          listener: (context, state) {
            setState(() {
              // PR #188 review: a commit that ends in MergeNeedsReview (or a
              // rejection) returns to editing — the flag must not survive it,
              // or the next brief busy state flashes the progress pane.
              if (!state.isMergeBusy) _committing = false;
              final review = state.mergeReview;
              if (review == null ||
                  !review.decisions.any((d) => d.decisionId == _selected)) {
                _selected = null;
              }
            });
          },
          buildWhen: (p, n) =>
              p.mergeReview != n.mergeReview ||
              p.mergeCommitOutcome != n.mergeCommitOutcome ||
              p.mergeFailureCode != n.mergeFailureCode ||
              p.isMergeBusy != n.isMergeBusy,
          builder: (context, state) {
            final review = state.mergeReview;
            final outcome = state.mergeCommitOutcome;
            final bloc = context.read<VaultBloc>();

            if (outcome is MergeApplied) {
              return _DonePane(outcome: outcome, onClose: widget.onClose);
            }
            if (outcome is MergeRejected && outcome.localCommitCompleted) {
              return _RecoveryPane(
                code: outcome.code,
                onRetry: () => bloc.add(const SyncCurrentDatabaseNow()),
                onClose: widget.onClose,
              );
            }
            if (_committing && state.isMergeBusy) {
              return const _ProgressPane();
            }
            if (review == null) {
              return _EmptyPane(
                code: state.mergeFailureCode,
                busy: state.isMergeBusy,
                onClose: widget.onClose,
              );
            }
            if (review.exceedsPerDecisionReviewLimit) {
              return _ScalePane(
                review: review,
                busy: state.isMergeBusy,
                onShortcut: (s) => bloc.add(ApplySyncMergeShortcut(s)),
                onCommit: _commit,
                onCancel: _cancel,
              );
            }

            final ready = review.phase == MergeReviewPhase.ready && !_editing;
            final list = ready
                ? _ReadyPane(
                    review: review,
                    busy: state.isMergeBusy,
                    onEdit: () => setState(() => _editing = true),
                    onCommit: _commit,
                    onCancel: _cancel,
                  )
                : _ReviewPane(
                    review: review,
                    busy: state.isMergeBusy,
                    selected: _selected,
                    failure: state.mergeFailureCode,
                    onSelect: (id) => setState(() => _selected = id),
                    onShortcut: (s) {
                      setState(() => _editing = false);
                      bloc.add(ApplySyncMergeShortcut(s));
                    },
                    onContinue: review.phase == MergeReviewPhase.ready
                        ? () => setState(() => _editing = false)
                        : null,
                    onCancel: _cancel,
                  );

            final selectedDecision = _selected == null
                ? null
                : review.decisions.firstWhere((d) => d.decisionId == _selected);
            Widget? detail;
            if (selectedDecision != null) {
              detail = _FieldPane(
                key: ValueKey(selectedDecision.decisionId),
                sessionId: review.sessionId,
                decision: selectedDecision,
                loadFieldDisplay: widget.loadFieldDisplay,
                busy: state.isMergeBusy,
                onChoice: (choice) => bloc.add(
                  UpdateSyncMergeDecision(
                    decisionId: selectedDecision.decisionId,
                    choice: choice,
                  ),
                ),
                onBack: () => setState(() => _selected = null),
              );
            }

            final width = MediaQuery.sizeOf(context).width;
            if (width < SyncMergeScreen.twoPaneMinWidth) {
              return detail ?? list;
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 380,
                  child: Semantics(
                    container: true,
                    label: 'Merge decisions',
                    child: list,
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: colors.divider),
                Expanded(
                  child: Semantics(
                    container: true,
                    label: 'Merge detail',
                    child: detail ?? const _DetailPlaceholder(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _commit() {
    setState(() {
      _committing = true;
      _selected = null;
    });
    context.read<VaultBloc>().add(const CommitSyncMerge());
  }

  void _cancel() {
    context.read<VaultBloc>().add(const CancelSyncMerge());
    widget.onClose();
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    this.subtitle,
    this.onBack,
    this.backTooltip = 'Back',
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final String backTooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 14, 0),
      child: Row(
        children: [
          if (onBack != null) ...[
            KvCircleIconButton(
              glyph: AppGlyph.back,
              tooltip: backTooltip,
              onPressed: onBack,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  label: title,
                  excludeSemantics: true,
                  child: Text(
                    title,
                    style: AppTextStyles.panelTitleLarge.copyWith(
                      fontSize: 19,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
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
}

/// A labeled, read-only status line. `liveRegion` only for changing progress.
class _Status extends StatelessWidget {
  const _Status({
    required this.glyph,
    required this.text,
    required this.semanticLabel,
    this.emphasis = false,
    this.liveRegion = false,
  });

  final AppGlyph glyph;
  final String text;
  final String semanticLabel;
  final bool emphasis;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Semantics(
      readOnly: true,
      liveRegion: liveRegion,
      label: semanticLabel,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: emphasis ? colors.positiveTint : colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.rowCompact),
        ),
        child: Row(
          children: [
            KvIcon(
              glyph: glyph,
              size: 16,
              color: emphasis ? colors.positiveText : colors.iconNeutral,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: AppTextStyles.secondary.copyWith(
                  color: emphasis ? colors.positiveText : colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {required this.count});

  final String text;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Semantics(
        header: true,
        label: '$text · $count',
        excludeSemantics: true,
        child: Text(
          '${text.toUpperCase()} · $count',
          style: AppTextStyles.labelUpper.copyWith(color: colors.textTertiary),
        ),
      ),
    );
  }
}

String _preservedCopy(MergeReviewSummary review) {
  final records = review.localOnlyRecordCount + review.remoteOnlyRecordCount;
  return 'Unique data preserved: $records records and '
      '${review.oneSidedFieldCount} fields that exist on one side only are '
      'kept automatically.';
}

String _categoryLabel(RedactedMergeDecision d) => switch (d.category) {
  MergeFieldCategory.title => 'Title',
  MergeFieldCategory.username => 'Username',
  MergeFieldCategory.password => 'Password',
  MergeFieldCategory.url => 'Website',
  MergeFieldCategory.notes => 'Notes',
  MergeFieldCategory.otp => 'One-time code',
  MergeFieldCategory.customField => 'Custom field',
  MergeFieldCategory.attachment => 'Attachment',
  MergeFieldCategory.parentGroup => 'Folder',
  MergeFieldCategory.groupMetadata => 'Folder details',
  MergeFieldCategory.other => 'Field',
};

bool _isDeletion(RedactedMergeDecision d) =>
    d.kind == MergeDecisionKind.fieldDeletionConflict ||
    d.kind == MergeDecisionKind.recordDeletionConflict;

/// FR-3a: the credential block is one row; the copy must say the answer
/// moves the entry's other credential fields with it.
bool _isCredentialBlock(RedactedMergeDecision d) =>
    d.kind == MergeDecisionKind.fieldConflict &&
    (d.category == MergeFieldCategory.username ||
        d.category == MergeFieldCategory.password ||
        d.category == MergeFieldCategory.url);

String _rowTitle(RedactedMergeDecision d) {
  if (_isCredentialBlock(d)) return 'Credentials (username, password, website)';
  if (d.kind == MergeDecisionKind.recordDeletionConflict) {
    return 'Record deleted on one side';
  }
  return _categoryLabel(d);
}

String _choiceLabel(RedactedMergeDecision d) {
  final base = switch (d.choice) {
    MergeChoice.local => 'This device',
    MergeChoice.remote => 'Drive',
    MergeChoice.bothNotes => 'Both notes',
    MergeChoice.keep => 'Keep',
    MergeChoice.delete => 'Delete',
  };
  final when = switch (d.timestampRelation) {
    TimestampRelation.localNewer => 'this device is newer',
    TimestampRelation.remoteNewer => 'Drive is newer',
    TimestampRelation.tie => 'same time',
    _ => null,
  };
  final parts = [base, if (d.isDefault) 'suggested', ?when];
  return parts.join(' · ');
}

// ---------------------------------------------------------------------------
// Review
// ---------------------------------------------------------------------------

class _ReviewPane extends StatelessWidget {
  const _ReviewPane({
    required this.review,
    required this.busy,
    required this.selected,
    required this.failure,
    required this.onSelect,
    required this.onShortcut,
    required this.onContinue,
    required this.onCancel,
  });

  final MergeReviewSummary review;
  final bool busy;
  final MergeDecisionId? selected;
  final MergeFailureCode? failure;
  final ValueChanged<MergeDecisionId> onSelect;
  final ValueChanged<MergeShortcut> onShortcut;
  final VoidCallback? onContinue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final conflicts = review.decisions
        .where((d) => d.kind == MergeDecisionKind.fieldConflict)
        .toList();
    final deletions = review.decisions.where(_isDeletion).toList();
    final groups = review.decisions
        .where((d) => d.kind == MergeDecisionKind.groupConflict)
        .toList();
    final undecided = review.decisions.where((d) => d.isDefault).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Review merge',
          subtitle:
              '${review.decisions.length} decisions · $undecided suggested',
          onBack: onCancel,
          backTooltip: 'Cancel merge',
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              _Status(
                glyph: AppGlyph.shieldCheck,
                text: _preservedCopy(review),
                semanticLabel: 'Unique data preserved',
                emphasis: true,
              ),
              const SizedBox(height: 8),
              const _Status(
                glyph: AppGlyph.info,
                text:
                    'Nothing written yet. Your vault and Drive stay as they '
                    'are until you confirm.',
                semanticLabel: 'Nothing written yet',
              ),
              if (failure != null) ...[
                const SizedBox(height: 8),
                _Status(
                  glyph: AppGlyph.warning,
                  text: _failureCopy(failure!),
                  semanticLabel: 'Merge problem',
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: KvPillButton(
                      label: 'Prefer local',
                      compact: true,
                      onPressed: busy
                          ? null
                          : () => onShortcut(MergeShortcut.preferLocal),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: KvPillButton(
                      label: 'Prefer remote',
                      compact: true,
                      onPressed: busy
                          ? null
                          : () => onShortcut(MergeShortcut.preferRemote),
                    ),
                  ),
                ],
              ),
              if (conflicts.isNotEmpty)
                _DecisionSection(
                  title: 'Field conflicts',
                  decisions: conflicts,
                  selected: selected,
                  onSelect: onSelect,
                ),
              if (deletions.isNotEmpty)
                _DecisionSection(
                  title: 'Deletions',
                  decisions: deletions,
                  selected: selected,
                  onSelect: onSelect,
                ),
              if (groups.isNotEmpty)
                _DecisionSection(
                  title: 'Folders',
                  decisions: groups,
                  selected: selected,
                  onSelect: onSelect,
                ),
              if (onContinue != null) ...[
                const SizedBox(height: 18),
                KvPillButton(
                  label: 'Continue',
                  onPressed: busy ? null : onContinue,
                ),
              ],
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: busy ? null : onCancel,
                  child: Text(
                    'Cancel',
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DecisionSection extends StatelessWidget {
  const _DecisionSection({
    required this.title,
    required this.decisions,
    required this.selected,
    required this.onSelect,
  });

  final String title;
  final List<RedactedMergeDecision> decisions;
  final MergeDecisionId? selected;
  final ValueChanged<MergeDecisionId> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Semantics(
      container: true,
      label: 'Conflict section: $title',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(title, count: decisions.length),
          for (final decision in decisions) ...[
            _DecisionRow(
              decision: decision,
              selected: decision.decisionId == selected,
              onTap: () => onSelect(decision.decisionId),
              colors: colors,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _DecisionRow extends StatelessWidget {
  const _DecisionRow({
    required this.decision,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final RedactedMergeDecision decision;
  final bool selected;
  final VoidCallback onTap;
  final CustodeColors colors;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      _choiceLabel(decision),
      if (_isCredentialBlock(decision))
        'Choosing a side moves the other credential fields with it',
      if (_isDeletion(decision))
        decision.presence == MergePresence.localOnly
            ? 'Deleted on Drive · still on this device'
            : 'Deleted on this device · still on Drive',
    ].join('\n');
    return Material(
      color: selected ? colors.surfaceNested : colors.surface,
      borderRadius: BorderRadius.circular(AppRadii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.row),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              KvIcon(
                glyph: _isDeletion(decision)
                    ? AppGlyph.delete
                    : AppGlyph.rowsDiff,
                size: 18,
                color: colors.iconNeutral,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _rowTitle(decision),
                      style: AppTextStyles.rowTitle.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppTextStyles.meta.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              KvIcon(
                glyph: AppGlyph.chevronRight,
                size: 16,
                color: colors.iconNeutral,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Field detail
// ---------------------------------------------------------------------------

class _FieldPane extends StatefulWidget {
  const _FieldPane({
    super.key,
    required this.sessionId,
    required this.decision,
    required this.loadFieldDisplay,
    required this.busy,
    required this.onChoice,
    required this.onBack,
  });

  final MergeSessionId sessionId;
  final RedactedMergeDecision decision;
  final LoadSyncMergeFieldDisplayUseCase loadFieldDisplay;
  final bool busy;
  final ValueChanged<MergeChoice> onChoice;
  final VoidCallback onBack;

  @override
  State<_FieldPane> createState() => _FieldPaneState();
}

class _FieldPaneState extends State<_FieldPane> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final d = widget.decision;
    final deletion = _isDeletion(d);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: _rowTitle(d),
          subtitle: deletion ? 'Deletion decision' : 'Field decision',
          onBack: widget.onBack,
        ),
        Expanded(
          child: SyncMergeFieldDisplayView(
            loadFieldDisplay: widget.loadFieldDisplay,
            sessionId: widget.sessionId,
            decisionId: d.decisionId,
            builder: (context, display) {
              final protected = display?.protected ?? true;
              return RadioGroup<MergeChoice>(
                groupValue: d.choice,
                onChanged: (choice) {
                  if (choice != null) widget.onChoice(choice);
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  children: [
                    if (_isCredentialBlock(d)) ...[
                      const _Status(
                        glyph: AppGlyph.key,
                        text:
                            'Username, password and website move together: '
                            'the side you pick here is used for all three.',
                        semanticLabel: 'Credential block',
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (deletion)
                      _Status(
                        glyph: AppGlyph.delete,
                        text: d.presence == MergePresence.localOnly
                            ? 'Drive deleted this; this device still has it. '
                                  'Keeping is suggested — deleting needs your '
                                  'explicit choice.'
                            : 'This device deleted this; Drive still has it. '
                                  'Keeping is suggested — deleting needs your '
                                  'explicit choice.',
                        semanticLabel: 'Deletion evidence',
                      )
                    else
                      _Status(
                        glyph: AppGlyph.info,
                        text:
                            'Values present on one side only are preserved '
                            'automatically and never offered for deletion.',
                        semanticLabel: 'Missing values are preserved',
                      ),
                    const SizedBox(height: 14),
                    if (protected && !deletion)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: display == null
                              ? null
                              : () => setState(() => _revealed = !_revealed),
                          icon: KvIcon(
                            glyph: _revealed ? AppGlyph.eyeOff : AppGlyph.eye,
                            size: 16,
                            color: colors.linkText,
                          ),
                          label: Text(
                            _revealed ? 'Hide values' : 'Reveal values',
                            style: AppTextStyles.secondary.copyWith(
                              color: colors.linkText,
                            ),
                          ),
                        ),
                      ),
                    if (deletion) ...[
                      _ChoiceTile(
                        title: 'Keep',
                        body: 'Keep it on both sides',
                        value: MergeChoice.keep,
                        enabled: !widget.busy,
                      ),
                      const SizedBox(height: 8),
                      _ChoiceTile(
                        title: 'Delete',
                        body: 'Remove it from both sides',
                        value: MergeChoice.delete,
                        enabled: !widget.busy,
                      ),
                    ] else ...[
                      _SideTile(
                        title: 'This device',
                        loading: display == null,
                        present: display?.local.isPresent ?? true,
                        // Read at build time only; never stored (F6).
                        text: display?.local.isPresent == true
                            ? display!.local.value
                            : null,
                        sizeBytes: display?.local.sizeBytes,
                        changedAt: display?.local.changedAt,
                        protected: protected,
                        revealed: _revealed,
                        value: MergeChoice.local,
                        enabled:
                            !widget.busy &&
                            d.presence != MergePresence.remoteOnly,
                      ),
                      const SizedBox(height: 8),
                      _SideTile(
                        title: 'Drive',
                        loading: display == null,
                        present: display?.remote.isPresent ?? true,
                        text: display?.remote.isPresent == true
                            ? display!.remote.value
                            : null,
                        sizeBytes: display?.remote.sizeBytes,
                        changedAt: display?.remote.changedAt,
                        protected: protected,
                        revealed: _revealed,
                        value: MergeChoice.remote,
                        enabled:
                            !widget.busy &&
                            d.presence != MergePresence.localOnly,
                      ),
                      if (d.category == MergeFieldCategory.notes) ...[
                        const SizedBox(height: 8),
                        _ChoiceTile(
                          title: 'Both',
                          body: 'Keep both notes, one after the other',
                          value: MergeChoice.bothNotes,
                          enabled: !widget.busy,
                        ),
                      ],
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.body,
    required this.value,
    required this.enabled,
  });

  final String title;
  final String body;
  final MergeChoice value;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final group = RadioGroup.maybeOf<MergeChoice>(context)?.groupValue;
    return Material(
      color: value == group ? colors.surfaceNested : colors.surface,
      borderRadius: BorderRadius.circular(AppRadii.row),
      child: RadioListTile<MergeChoice>(
        value: value,
        enabled: enabled,
        title: Text(
          title,
          style: AppTextStyles.rowTitle.copyWith(color: colors.textPrimary),
        ),
        subtitle: Text(
          body,
          style: AppTextStyles.meta.copyWith(color: colors.textSecondary),
        ),
      ),
    );
  }
}

class _SideTile extends StatelessWidget {
  const _SideTile({
    required this.title,
    required this.loading,
    required this.present,
    required this.text,
    required this.sizeBytes,
    required this.changedAt,
    required this.protected,
    required this.revealed,
    required this.value,
    required this.enabled,
  });

  final String title;
  final bool loading;
  final bool present;
  final String? text;
  final int? sizeBytes;
  final DateTime? changedAt;
  final bool protected;
  final bool revealed;
  final MergeChoice value;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final group = RadioGroup.maybeOf<MergeChoice>(context)?.groupValue;
    final String body;
    final bool mono;
    if (loading) {
      body = 'Loading…';
      mono = false;
    } else if (!present) {
      body = 'Missing here · preserved from the other side';
      mono = false;
    } else if (protected && !revealed) {
      body = '••••••••••••';
      mono = true;
    } else {
      final value = text ?? '';
      body = value.isEmpty && sizeBytes != null ? '$sizeBytes bytes' : value;
      mono = protected;
    }
    return Material(
      color: value == group ? colors.surfaceNested : colors.surface,
      borderRadius: BorderRadius.circular(AppRadii.row),
      child: RadioListTile<MergeChoice>(
        value: value,
        enabled: enabled && present,
        title: Text(
          title,
          style: AppTextStyles.rowTitle.copyWith(color: colors.textPrimary),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              body,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: (mono ? AppTextStyles.secret : AppTextStyles.fieldValue)
                  .copyWith(color: colors.textSecondary),
            ),
            if (changedAt != null)
              Text(
                'Changed ${changedAt!.toIso8601String().substring(0, 10)}',
                style: AppTextStyles.meta.copyWith(color: colors.textTertiary),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailPlaceholder extends StatelessWidget {
  const _DetailPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Center(
      child: Text(
        'Select a decision to compare both sides',
        style: AppTextStyles.secondary.copyWith(color: colors.textTertiary),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ready / progress / recovery / done / scale / empty
// ---------------------------------------------------------------------------

class _ReadyPane extends StatelessWidget {
  const _ReadyPane({
    required this.review,
    required this.busy,
    required this.onEdit,
    required this.onCommit,
    required this.onCancel,
  });

  final MergeReviewSummary review;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onCommit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final local = review.decisions
        .where((d) => d.choice == MergeChoice.local)
        .length;
    final remote = review.decisions
        .where((d) => d.choice == MergeChoice.remote)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Ready to merge',
          subtitle: '${review.decisions.length} decisions confirmed',
          onBack: onCancel,
          backTooltip: 'Cancel merge',
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              _Status(
                glyph: AppGlyph.shieldCheck,
                text:
                    '${review.localOnlyRecordCount} records only on this device, '
                    '${review.remoteOnlyRecordCount} only on Drive and '
                    '${review.oneSidedFieldCount} one-sided fields are kept. '
                    '$local decisions take this device, $remote take Drive.',
                semanticLabel: 'Union summary',
                emphasis: true,
              ),
              const SizedBox(height: 8),
              const _Status(
                glyph: AppGlyph.export,
                text:
                    'A dated backup of your vault is created before anything '
                    'is written.',
                semanticLabel: 'Backup before write',
              ),
              const SizedBox(height: 8),
              const _Status(
                glyph: AppGlyph.cloudDone,
                text:
                    'The upload is read back and verified before this vault '
                    'is marked as synced.',
                semanticLabel: 'Remote write verification',
              ),
              const SizedBox(height: 8),
              const _Status(
                glyph: AppGlyph.info,
                text: 'Nothing written yet.',
                semanticLabel: 'Nothing written yet',
              ),
              const SizedBox(height: 18),
              KvPillButton(
                label: 'Merge and sync',
                onPressed: busy ? null : onCommit,
              ),
              const SizedBox(height: 10),
              KvPillButton(
                label: 'Edit decisions',
                compact: true,
                onPressed: busy ? null : onEdit,
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: busy ? null : onCancel,
                  child: Text(
                    'Cancel',
                    style: AppTextStyles.secondary.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// T604: after the atomic boundary there is nothing to cancel, so nothing
/// cancellable is shown.
class _ProgressPane extends StatelessWidget {
  const _ProgressPane();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(title: 'Merging'),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 18),
                const _Status(
                  glyph: AppGlyph.sync,
                  text:
                      'Backing up, writing the merged vault and verifying the '
                      'upload. Do not close the app.',
                  semanticLabel: 'Merge in progress',
                  liveRegion: true,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// T604: an ambiguous upload is a recovery status, never a success.
class _RecoveryPane extends StatelessWidget {
  const _RecoveryPane({
    required this.code,
    required this.onRetry,
    required this.onClose,
  });

  final MergeFailureCode code;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ambiguous = code == MergeFailureCode.uploadOutcomeAmbiguous;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: ambiguous ? 'Upload not confirmed' : 'Merge saved locally',
          onBack: onClose,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              const _Status(
                glyph: AppGlyph.shieldCheck,
                text:
                    'The merged vault is saved on this device, with a dated '
                    'backup of the previous version.',
                semanticLabel: 'Local merge saved',
                emphasis: true,
              ),
              const SizedBox(height: 8),
              _Status(
                glyph: AppGlyph.warning,
                text: ambiguous
                    ? 'Drive did not confirm the upload. It is not marked as '
                          'synced: the next sync checks what Drive holds and '
                          'finishes safely.'
                    : _failureCopy(code),
                semanticLabel: 'Recovery pending',
              ),
              const SizedBox(height: 18),
              KvPillButton(label: 'Check now', onPressed: onRetry),
              const SizedBox(height: 10),
              KvPillButton(label: 'Close', compact: true, onPressed: onClose),
            ],
          ),
        ),
      ],
    );
  }
}

class _DonePane extends StatelessWidget {
  const _DonePane({required this.outcome, required this.onClose});

  final MergeApplied outcome;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(title: 'Merge complete'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              _Status(
                glyph: AppGlyph.cloudDone,
                text:
                    '${outcome.entryCount} records merged and verified on '
                    'Drive.${outcome.backupCreated ? ' A backup was kept.' : ''}',
                semanticLabel: 'Merge verified',
                emphasis: true,
              ),
              const SizedBox(height: 18),
              KvPillButton(label: 'Done', onPressed: onClose),
            ],
          ),
        ),
      ],
    );
  }
}

/// T605: above the per-decision limit only the shortcuts are offered.
class _ScalePane extends StatelessWidget {
  const _ScalePane({
    required this.review,
    required this.busy,
    required this.onShortcut,
    required this.onCommit,
    required this.onCancel,
  });

  final MergeReviewSummary review;
  final bool busy;
  final ValueChanged<MergeShortcut> onShortcut;
  final VoidCallback onCommit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Too many conflicts to review one by one',
          subtitle: '${review.decisions.length} conflicts',
          onBack: onCancel,
          backTooltip: 'Cancel merge',
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              _Status(
                glyph: AppGlyph.shieldCheck,
                text: _preservedCopy(review),
                semanticLabel: 'Unique data preserved',
                emphasis: true,
              ),
              const SizedBox(height: 8),
              const _Status(
                glyph: AppGlyph.info,
                text:
                    'Nothing written yet. Pick a side for every conflict, '
                    'then merge.',
                semanticLabel: 'Nothing written yet',
              ),
              const SizedBox(height: 18),
              KvPillButton(
                label: 'Prefer local',
                onPressed: busy
                    ? null
                    : () => onShortcut(MergeShortcut.preferLocal),
              ),
              const SizedBox(height: 10),
              KvPillButton(
                label: 'Prefer remote',
                onPressed: busy
                    ? null
                    : () => onShortcut(MergeShortcut.preferRemote),
              ),
              if (review.phase == MergeReviewPhase.ready) ...[
                const SizedBox(height: 18),
                KvPillButton(
                  label: 'Merge and sync',
                  onPressed: busy ? null : onCommit,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane({
    required this.code,
    required this.busy,
    required this.onClose,
  });

  final MergeFailureCode? code;
  final bool busy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(title: 'Review merge', onBack: onClose),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: busy
                ? const Center(child: CircularProgressIndicator())
                : _Status(
                    glyph: AppGlyph.warning,
                    text: code == null
                        ? 'No merge review is open.'
                        : _failureCopy(code!),
                    semanticLabel: 'Merge problem',
                  ),
          ),
        ),
      ],
    );
  }
}

String _failureCopy(MergeFailureCode code) => switch (code) {
  MergeFailureCode.wrongLineage =>
    'The Drive file is not a copy of this vault, so they cannot be merged.',
  MergeFailureCode.unsupportedKdbxData ||
  MergeFailureCode.unsupportedKdbxConstruct =>
    'This vault uses data the merge cannot handle safely.',
  MergeFailureCode.credentialsRevoked =>
    'Unlock the vault again to continue the merge.',
  MergeFailureCode.staleLocal =>
    'This vault changed while reviewing. Start the review again.',
  MergeFailureCode.staleRemote || MergeFailureCode.uploadConflict =>
    'Drive changed while reviewing. Start the review again.',
  MergeFailureCode.staleRecoveryLocal =>
    'This vault changed since the merge was saved. A new review is needed.',
  MergeFailureCode.backupFailed =>
    'The backup could not be created, so nothing was written.',
  MergeFailureCode.serializationParityFailed ||
  MergeFailureCode.atomicReplaceFailed =>
    'The merged vault could not be written safely. Nothing was changed.',
  MergeFailureCode.uploadRejected =>
    'Drive rejected the upload. Nothing is marked as synced.',
  MergeFailureCode.uploadOutcomeAmbiguous =>
    'Drive did not confirm the upload.',
  MergeFailureCode.unresolvedConflict =>
    'Drive kept changing during the merge. Review the new conflicts.',
  MergeFailureCode.cancelled => 'The merge was cancelled.',
  MergeFailureCode.mergePreconditionFailed =>
    'This vault is not linked to a Drive file that can be merged.',
  MergeFailureCode.sessionInvalidated =>
    'The review is no longer valid. Start it again.',
  MergeFailureCode.platformDisabled =>
    'Merging is not available on this platform.',
};
