import 'package:flutter/material.dart';

import '../../../../../core/theme/app_glyph.dart';
import '../../../../../core/theme/app_radii.dart';
import '../../../../../core/theme/app_text_styles.dart';
import '../../../../../core/theme/custode_colors.dart';
import '../../../../../core/widgets/kv_icon.dart';
import '../../../../../core/widgets/kv_circle_icon_button.dart';
import '../../../../../core/widgets/kv_list_row.dart';
import '../../../../../core/widgets/kv_pill_button.dart';
import '../../../../../core/widgets/kv_spinner.dart';
import '../../../../../core/widgets/kv_switch.dart';
import '../../../domain/models/database_sync_status.dart';

/// One row in the `success` hero's "Recent activity" list (spec-005 FR-1
/// adopted proposal). The app does not persist a real sync history today
/// (only `lastSyncAt` + checksums), so callers derive at most a single row
/// from what `DatabaseSyncMapping` already stores — see
/// `SyncDestination._recentActivity`.
class SyncActivityItem {
  const SyncActivityItem({
    required this.icon,
    required this.title,
    required this.meta,
  });

  final AppGlyph icon;
  final String title;
  final String meta;
}

/// Presentation descriptor for one cloud sync provider.
///
/// UI predisposition for spec-010 (multi-cloud): the setup heroes render a
/// provider list instead of a hard-coded "Connect Google account" button, so
/// adding a provider is adding an entry here plus its `onConnect` wiring.
/// The data layer is still Google-only — this changes nothing below the UI.
class SyncProviderPresentation {
  const SyncProviderPresentation({
    required this.id,
    required this.name,
    required this.tagline,
    required this.glyph,
  });

  final String id;
  final String name;
  final String tagline;
  final AppGlyph glyph;
}

/// The providers the UI offers. One today; spec-010 adds more.
const List<SyncProviderPresentation> kSyncProviders = [
  SyncProviderPresentation(
    id: 'google_drive',
    name: 'Google Drive',
    tagline: 'Sync via your Google account',
    glyph: AppGlyph.cloud,
  ),
];

/// FR-1 / T5: one widget, one rendered state per `DatabaseSyncStatus` value
/// (`idle`, `syncing`, `success`, `error`, `conflict`, `disconnected`) —
/// none of them a snackbar-only state (AC2).
///
/// `disconnected` non-negotiable (T5/AC3): this widget explains the
/// security model in its `build()` return value — a pure, side-effect-free
/// render — and never calls any auth/Drive method itself. [onConnect] is
/// only ever invoked from the "Connect Google account" button's `onTap`,
/// i.e. strictly after the user has read the explanation and acted. A
/// `SyncStatusHero` can be built and pumped a hundred times with a spy auth
/// service behind [onConnect]; it will record zero calls until tapped.
class SyncStatusHero extends StatelessWidget {
  /// Test-only clock override for the "Last sync X ago" relative-time text
  /// (golden determinism — this widget is reached through the full
  /// `VaultScreen` shell, several layers above where a `now` constructor
  /// param could otherwise be threaded through). Never set in production.
  @visibleForTesting
  static DateTime? debugNowOverride;

  const SyncStatusHero({
    super.key,
    required this.status,
    this.isDriveConnected = false,
    this.isDriveLinked = false,
    this.linkedRemoteFileName,
    this.lastSyncAt,
    this.localChecksum,
    this.autoSyncEnabled = true,
    this.syncError,
    this.reconnectRequired = false,
    this.isReconnecting = false,
    this.recentActivity = const [],
    this.isOffline = false,
    this.offlineChangeCount = 0,
    this.onConnect,
    this.onExportBackup,
    this.onCreateNewFile,
    this.onPickExisting,
    this.onToggleAutoSync,
    this.onSyncNow,
    this.onUnlink,
    this.onReconnect,
    this.onRetryOffline,
    this.onOpenConflict,
    this.now,
  });

  final DatabaseSyncStatus status;
  final bool isDriveConnected;
  final bool isDriveLinked;
  final String? linkedRemoteFileName;
  final DateTime? lastSyncAt;
  final String? localChecksum;
  final bool autoSyncEnabled;
  final String? syncError;
  final bool reconnectRequired;
  final bool isReconnecting;
  final List<SyncActivityItem> recentActivity;

  /// T7 non-negotiable: true only for connection-level failures
  /// (`SocketException` or equivalent) — never for an HTTP error status.
  /// Callers classify the failure; this widget only renders the flag.
  final bool isOffline;
  final int offlineChangeCount;

  final VoidCallback? onConnect;
  final VoidCallback? onExportBackup;
  final VoidCallback? onCreateNewFile;
  final VoidCallback? onPickExisting;
  final ValueChanged<bool>? onToggleAutoSync;
  final VoidCallback? onSyncNow;
  final VoidCallback? onUnlink;
  final VoidCallback? onReconnect;
  final VoidCallback? onRetryOffline;
  final VoidCallback? onOpenConflict;

  /// Injected clock for the "Last sync X ago" relative-time text — defaults
  /// to `DateTime.now()` in production. Tests (goldens especially) pass a
  /// fixed value so the rendered text never depends on wall-clock time at
  /// the moment the test happens to run.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[_primaryHero(context)];
    if (isOffline) {
      children.add(const SizedBox(height: 12));
      children.add(_offlineCard(context));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _primaryHero(BuildContext context) {
    if (reconnectRequired) {
      return _errorHero(context);
    }
    // `isDriveConnected` (not `status`) is authoritative here: background
    // Drive checks (`VaultBloc._onBackgroundDriveSync`) deliberately update
    // `isDriveConnected`/`isDriveLinked` without touching `syncStatus` (its
    // own comment: "no UI flash") — `status` can legitimately still read
    // its `disconnected` default while the account is, in fact, connected.
    if (!isDriveConnected) {
      return _disconnectedHero(context);
    }
    if (!isDriveLinked) {
      return _notLinkedHero(context);
    }
    return switch (status) {
      DatabaseSyncStatus.syncing => _syncingHero(context),
      DatabaseSyncStatus.error => _errorHero(context),
      DatabaseSyncStatus.conflict => _conflictHero(context),
      // idle and success both render the "up to date" card — `idle` is the
      // resting state right after a successful connect/link/sync with
      // nothing new to report (see VaultBloc._refreshSyncState).
      // `disconnected` reaching this branch means the guards above are
      // already true but `syncStatus` itself hasn't caught up yet (its
      // default value, per the comment above) — treat it as the same
      // "connected and settled" resting state as idle/success, not as a
      // fresh disconnected prompt.
      DatabaseSyncStatus.idle ||
      DatabaseSyncStatus.success ||
      DatabaseSyncStatus.disconnected => _successHero(context),
    };
  }

  // ── disconnected ─────────────────────────────────────────────────────
  Widget _disconnectedHero(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return _HeroCard(
      backgroundColor: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _glyphCircle(
            context,
            glyph: AppGlyph.cloudOff,
            background: colors.surface,
            foreground: colors.textSecondary,
          ),
          const SizedBox(height: 18),
          Text(
            'This database lives only here',
            style: AppTextStyles.screenTitle.copyWith(
              fontSize: 24,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              style: AppTextStyles.body.copyWith(color: colors.textSecondary),
              children: const [
                TextSpan(
                  text:
                      'Connect a Google account to keep this database in '
                      'sync across your devices. Custode uploads the '
                      'encrypted file as-is — ',
                ),
                TextSpan(
                  text: 'the master password never leaves this device.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'CHOOSE A PROVIDER',
            style: AppTextStyles.labelUpper.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          // ponytail: single provider today, onConnect goes to it directly;
          // per-provider callbacks arrive with spec-010.
          for (final provider in kSyncProviders) ...[
            _providerTile(context, provider, onTap: onConnect),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          KvSecondaryPillButton(
            label: 'Export a backup instead',
            onPressed: onExportBackup,
          ),
        ],
      ),
    );
  }

  // ── connected, not linked ────────────────────────────────────────────
  // Redesigned 2026-08-31: the previous version painted `ground` rows on an
  // `attentionTint` card — in light theme those are neutral-100 on
  // accent-100, nearly the same value, and the whole card read as one
  // unreadable wash. Neutral `surface` card, a compact attention banner,
  // and `surfaceNested` rows carry the contrast now.
  Widget _notLinkedHero(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final provider = kSyncProviders.first;
    return _HeroCard(
      backgroundColor: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: colors.attentionTint,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KvIcon(
                  glyph: AppGlyph.warning,
                  size: 18,
                  color: colors.attentionText,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "This database isn't linked to a remote file yet. "
                    'Nothing is uploaded until you choose one.',
                    style: AppTextStyles.body.copyWith(
                      color: colors.attentionText,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'PROVIDER',
            style: AppTextStyles.labelUpper.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          _providerTile(context, provider, statusLabel: 'Connected'),
          const SizedBox(height: 14),
          Text(
            'LINK A FILE',
            style: AppTextStyles.labelUpper.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          KvListRow(
            title: 'Create a new file on ${provider.name}',
            subtitle: 'In My Drive root',
            backgroundColor: colors.surfaceNested,
            onTap: onCreateNewFile,
            leading: _squareGlyph(context, AppGlyph.add),
          ),
          const SizedBox(height: 8),
          KvListRow(
            title: 'Pick an existing .kdbx',
            subtitle: 'Browse your ${provider.name} files',
            backgroundColor: colors.surfaceNested,
            onTap: onPickExisting,
            leading: _squareGlyph(context, AppGlyph.search),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colors.surfaceNested,
              borderRadius: BorderRadius.circular(AppRadii.row),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Auto-sync',
                    style: AppTextStyles.rowTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                KvSwitch(
                  value: autoSyncEnabled,
                  onChanged: onToggleAutoSync,
                  semanticLabel: 'Auto-sync',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One provider row for the setup heroes. [onTap] connects it (the
  /// disconnected hero); [statusLabel] renders instead of a chevron when the
  /// provider is already connected (the not-linked hero).
  Widget _providerTile(
    BuildContext context,
    SyncProviderPresentation provider, {
    VoidCallback? onTap,
    String? statusLabel,
  }) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return KvListRow(
      title: provider.name,
      subtitle: provider.tagline,
      backgroundColor: colors.surfaceNested,
      onTap: onTap,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colors.actionFill,
          borderRadius: BorderRadius.circular(AppRadii.iconSquare),
        ),
        alignment: Alignment.center,
        child: KvIcon(
          glyph: provider.glyph,
          size: 19,
          color: colors.actionText,
        ),
      ),
      trailing: statusLabel == null
          ? null
          : Text(
              statusLabel,
              style: AppTextStyles.secondary.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.positiveText,
              ),
            ),
    );
  }

  Widget _squareGlyph(BuildContext context, AppGlyph glyph) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.iconSquare),
      ),
      alignment: Alignment.center,
      child: KvIcon(glyph: glyph, size: 18, color: colors.textPrimary),
    );
  }

  // ── syncing ───────────────────────────────────────────────────────────
  Widget _syncingHero(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return _HeroCard(
      backgroundColor: colors.surface,
      child: Row(
        children: [
          const KvSpinner(),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Syncing…',
                  style: AppTextStyles.panelTitleLarge.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  'Comparing checksums with Drive',
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

  // ── offline (T7 proposal) ────────────────────────────────────────────
  Widget _offlineCard(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return _HeroCard(
      backgroundColor: colors.attentionTint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _glyphCircle(
                context,
                glyph: AppGlyph.cloudOff,
                background: colors.actionFill,
                foreground: colors.actionText,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Waiting for a connection',
                      style: AppTextStyles.panelTitleLarge.copyWith(
                        color: colors.attentionText,
                      ),
                    ),
                    // No caller wires `offlineChangeCount` today — the app
                    // has no local-changes-pending counter anywhere in the
                    // bloc/domain layer (Copilot PR #9 fix 3: adding one is
                    // out of scope for spec-005). Showing a number here
                    // would always read "0 local changes", which is worse
                    // than no number. Generic copy until a real count is
                    // wired; `offlineChangeCount` stays on the widget for
                    // that future wiring.
                    Text(
                      "Your local changes will sync once you're back online.",
                      style: AppTextStyles.secondary.copyWith(
                        color: colors.attentionText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Your edits are already saved in the local file. Custode will '
            "upload them automatically as soon as you're back online.",
            style: AppTextStyles.secondary.copyWith(
              color: colors.attentionText,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: KvSecondaryPillButton(
              label: 'Retry now',
              expand: false,
              onPressed: onRetryOffline,
            ),
          ),
        ],
      ),
    );
  }

  // ── success / idle ───────────────────────────────────────────────────
  // Redesigned 2026-08-31 with the other heroes: neutral `surface` card,
  // positive status header, provider tile, readable `surfaceNested` rows —
  // the previous all-green card washed its own key/value rows out.
  Widget _successHero(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    final provider = kSyncProviders.first;
    final activity = recentActivity;
    return _HeroCard(
      backgroundColor: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _glyphCircle(
                context,
                glyph: AppGlyph.cloudDone,
                background: colors.positiveTint,
                foreground: colors.positiveText,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Up to date',
                      style: AppTextStyles.panelTitleLarge.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      lastSyncAt == null
                          ? 'No sync yet'
                          : 'Last sync ${_relativeTime(lastSyncAt!, now ?? debugNowOverride ?? DateTime.now())}',
                      style: AppTextStyles.secondary.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              KvCircleIconButton(
                glyph: AppGlyph.sync,
                tooltip: 'Sync now',
                filled: true,
                onPressed: onSyncNow,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'PROVIDER',
            style: AppTextStyles.labelUpper.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          KvListRow(
            title: provider.name,
            subtitle: linkedRemoteFileName ?? provider.tagline,
            backgroundColor: colors.surfaceNested,
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.actionFill,
                borderRadius: BorderRadius.circular(AppRadii.iconSquare),
              ),
              alignment: Alignment.center,
              child: KvIcon(
                glyph: provider.glyph,
                size: 19,
                color: colors.actionText,
              ),
            ),
            trailing: KvCircleIconButton(
              glyph: AppGlyph.cloudOff,
              tooltip: 'Unlink',
              onPressed: onUnlink,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colors.surfaceNested,
              borderRadius: BorderRadius.circular(AppRadii.row),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Auto-sync',
                    style: AppTextStyles.rowTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                KvSwitch(
                  value: autoSyncEnabled,
                  onChanged: onToggleAutoSync,
                  semanticLabel: 'Auto-sync',
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colors.surfaceNested,
              borderRadius: BorderRadius.circular(AppRadii.row),
            ),
            child: _kv(
              context,
              'Local checksum',
              _truncateChecksum(localChecksum),
              colors.textSecondary,
              mono: true,
            ),
          ),
          if (activity.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'RECENT ACTIVITY',
              style: AppTextStyles.labelUpper.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            for (final item in activity) ...[
              _activityRow(context, item),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }

  Widget _activityRow(BuildContext context, SyncActivityItem item) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: colors.ground,
        borderRadius: BorderRadius.circular(AppRadii.row),
      ),
      child: Row(
        children: [
          KvIcon(glyph: item.icon, size: 17, color: colors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  style: AppTextStyles.rowTitle.copyWith(
                    fontSize: 13.5,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  item.meta,
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

  // ── error ─────────────────────────────────────────────────────────────
  Widget _errorHero(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return _HeroCard(
      backgroundColor: colors.attentionTint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _glyphCircle(
                context,
                glyph: AppGlyph.warning,
                background: colors.actionFill,
                foreground: colors.actionText,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Reconnect Google Drive',
                      style: AppTextStyles.panelTitleLarge.copyWith(
                        color: colors.attentionText,
                      ),
                    ),
                    if (syncError != null && syncError!.isNotEmpty)
                      Text(
                        syncError!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.secondary.copyWith(
                          color: colors.attentionText,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Sync is paused, nothing was lost. Sign in again to resume '
            'uploading changes.',
            style: AppTextStyles.body.copyWith(color: colors.attentionText),
          ),
          const SizedBox(height: 14),
          // Persistent action, not a transient snackbar (FR-1 non-negotiable).
          Semantics(
            container: true,
            button: true,
            enabled: onReconnect != null && !isReconnecting,
            label: 'Reconnect Google Drive',
            child: ExcludeSemantics(
              child: KvPillButton(
                label: isReconnecting ? 'Reconnecting...' : 'Reconnect',
                compact: true,
                onPressed: isReconnecting ? null : onReconnect,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── conflict ──────────────────────────────────────────────────────────
  Widget _conflictHero(BuildContext context) {
    final colors = Theme.of(context).extension<CustodeColors>()!;
    return _HeroCard(
      backgroundColor: colors.attentionTint,
      onTap: onOpenConflict,
      child: Row(
        children: [
          _glyphCircle(
            context,
            glyph: AppGlyph.warning,
            background: colors.actionFill,
            foreground: colors.actionText,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Both versions changed',
                  style: AppTextStyles.panelTitleLarge.copyWith(
                    color: colors.attentionText,
                  ),
                ),
                Text(
                  'Tap to choose which version to keep',
                  style: AppTextStyles.secondary.copyWith(
                    color: colors.attentionText,
                  ),
                ),
              ],
            ),
          ),
          KvIcon(
            glyph: AppGlyph.chevronRight,
            size: 17,
            color: colors.attentionText,
          ),
        ],
      ),
    );
  }

  // ── shared bits ───────────────────────────────────────────────────────
  Widget _kv(
    BuildContext context,
    String key,
    String value,
    Color color, {
    bool mono = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(key, style: AppTextStyles.secondary.copyWith(color: color)),
        Text(
          value,
          style: (mono ? AppTextStyles.secret : AppTextStyles.secondary)
              .copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: mono ? 11 : 12.5,
              ),
        ),
      ],
    );
  }

  Widget _glyphCircle(
    BuildContext context, {
    required AppGlyph glyph,
    required Color background,
    required Color foreground,
    double size = 52,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: KvIcon(glyph: glyph, size: size * 0.5, color: foreground),
    );
  }

  static String _truncateChecksum(String? checksum) {
    if (checksum == null || checksum.length <= 8) {
      return checksum ?? '-';
    }
    return '${checksum.substring(0, 4)}…${checksum.substring(checksum.length - 4)}';
  }

  static String _relativeTime(DateTime value, DateTime now) {
    final diff = now.difference(value);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) {
      return diff.inMinutes == 1
          ? '1 minute ago'
          : '${diff.inMinutes} minutes ago';
    }
    if (diff.inHours < 24) {
      return diff.inHours == 1 ? '1 hour ago' : '${diff.inHours} hours ago';
    }
    return diff.inDays == 1 ? '1 day ago' : '${diff.inDays} days ago';
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.child,
    required this.backgroundColor,
    this.onTap,
  });

  final Widget child;
  final Color backgroundColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(26),
      ),
      child: child,
    );

    if (onTap == null) {
      return content;
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: content,
      ),
    );
  }
}
