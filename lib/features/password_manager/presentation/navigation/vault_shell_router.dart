import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/responsive/breakpoints.dart';
import '../../../../core/widgets/kv_bottom_sheet.dart';
import 'vault_shell_session_scope.dart';
import '../../domain/models/sync_conflict.dart';
import '../../domain/models/vault_custom_field.dart';

sealed class VaultRouteResult extends Equatable {
  const VaultRouteResult();

  @override
  bool? get stringify => false;
}

final class EntryEditResult extends VaultRouteResult {
  const EntryEditResult({
    required this.title,
    required this.username,
    required this.password,
    required this.url,
    required this.notes,
    required this.otpUri,
    required this.customFields,
    required this.attachmentPaths,
    this.removedAttachmentKeys = const [],
  });

  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;
  final String otpUri;
  final List<VaultCustomField> customFields;

  /// Files picked in the editor, to attach when the record is saved.
  final List<String> attachmentPaths;

  /// Keys of attachments the record already held that the user removed in
  /// the editor. Always empty for a new record.
  final List<String> removedAttachmentKeys;

  @override
  List<Object?> get props => [
    title,
    username,
    const _RedactedRouteValue(),
    url,
    const _RedactedRouteValue(),
    const _RedactedRouteValue(),
    customFields,
    attachmentPaths,
    removedAttachmentKeys,
  ];

  @override
  String toString() =>
      'EntryEditResult(title: $title, username: $username, password: <redacted>, '
      'url: $url, notes: <redacted>, otpUri: <redacted>, '
      'customFields: $customFields, attachmentPaths: $attachmentPaths, '
      'removedAttachmentKeys: $removedAttachmentKeys)';
}

final class GeneratedPasswordResult extends VaultRouteResult {
  const GeneratedPasswordResult(this.password);

  final String password;

  @override
  List<Object?> get props => const [_RedactedRouteValue()];

  @override
  String toString() => 'GeneratedPasswordResult(password: <redacted>)';
}

final class OtpScanResult extends VaultRouteResult {
  const OtpScanResult(this.otpUri);

  final String otpUri;

  @override
  List<Object?> get props => const [_RedactedRouteValue()];

  @override
  String toString() => 'OtpScanResult(otpUri: <redacted>)';
}

final class GroupEditResult extends VaultRouteResult {
  const GroupEditResult(this.name);

  final String name;

  @override
  List<Object?> get props => [name];
}

final class MoveTargetResult extends VaultRouteResult {
  const MoveTargetResult(this.groupId);

  final String groupId;

  @override
  List<Object?> get props => [groupId];
}

sealed class DriveLinkResult extends VaultRouteResult {
  const DriveLinkResult();

  const factory DriveLinkResult.existing(String remoteFileId) =
      ExistingDriveLinkResult;
  const factory DriveLinkResult.newFile(String remoteFileName) =
      NewDriveLinkResult;
}

final class ExistingDriveLinkResult extends DriveLinkResult {
  const ExistingDriveLinkResult(this.remoteFileId);

  final String remoteFileId;

  @override
  List<Object?> get props => [remoteFileId];
}

final class NewDriveLinkResult extends DriveLinkResult {
  const NewDriveLinkResult(this.remoteFileName);

  final String remoteFileName;

  @override
  List<Object?> get props => [remoteFileName];
}

final class SyncConflictRouteResult extends VaultRouteResult {
  const SyncConflictRouteResult(this.resolution, {this.openMerge = false});

  final SyncConflictResolution resolution;

  /// spec-008 T601: the user chose the per-field review instead of a side.
  final bool openMerge;

  @override
  List<Object?> get props => [resolution, openMerge];
}

final class ConfirmDecision extends VaultRouteResult {
  const ConfirmDecision._(this.isConfirmed);

  static const confirm = ConfirmDecision._(true);
  static const cancel = ConfirmDecision._(false);

  final bool isConfirmed;

  @override
  List<Object?> get props => [isConfirmed];
}

final class VaultDone extends VaultRouteResult {
  const VaultDone();

  @override
  List<Object?> get props => const [];
}

final class DatabaseSettingsResult extends VaultRouteResult {
  const DatabaseSettingsResult({
    required this.fileName,
    required this.keyFilePath,
    required this.biometricProtectionEnabled,
    required this.changePassword,
    required this.inactivityLockTimeoutSeconds,
    required this.currentPassword,
    required this.newPassword,
  });

  final String fileName;
  final String? keyFilePath;
  final bool biometricProtectionEnabled;
  final bool changePassword;
  final int? inactivityLockTimeoutSeconds;
  final String currentPassword;
  final String newPassword;

  @override
  List<Object?> get props => [
    fileName,
    const _RedactedRouteValue(),
    biometricProtectionEnabled,
    changePassword,
    inactivityLockTimeoutSeconds,
    const _RedactedRouteValue(),
    const _RedactedRouteValue(),
  ];

  @override
  String toString() =>
      'DatabaseSettingsResult(fileName: $fileName, keyFilePath: <redacted>, '
      'biometricProtectionEnabled: $biometricProtectionEnabled, '
      'changePassword: $changePassword, '
      'inactivityLockTimeoutSeconds: $inactivityLockTimeoutSeconds, '
      'currentPassword: <redacted>, newPassword: <redacted>)';
}

final class CsvImportResult extends VaultRouteResult {
  const CsvImportResult({
    required this.filePath,
    required this.avoidDuplicates,
  });

  final String filePath;
  final bool avoidDuplicates;

  @override
  List<Object?> get props => [filePath, avoidDuplicates];
}

final class _RedactedRouteValue {
  const _RedactedRouteValue();

  @override
  bool operator ==(Object other) => other is _RedactedRouteValue;

  @override
  int get hashCode => 0;

  @override
  String toString() => '<redacted>';
}

@immutable
final class VaultOperationId {
  const VaultOperationId._(this._value);

  final int _value;

  @override
  bool operator ==(Object other) =>
      other is VaultOperationId && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => 'VaultOperationId(<redacted>)';
}

typedef VaultSurfaceBuilder = Widget Function(BuildContext context);

sealed class VaultSurface<R extends VaultRouteResult> {
  const VaultSurface({required this.builder});

  final VaultSurfaceBuilder builder;
}

final class EntrySurface<R extends VaultRouteResult> extends VaultSurface<R> {
  const EntrySurface({required super.builder});
}

final class OtpScannerSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const OtpScannerSurface({required super.builder});
}

final class PasswordGeneratorSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const PasswordGeneratorSurface({required super.builder});
}

final class GroupEditSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const GroupEditSurface({required super.builder});
}

final class MoveTargetSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const MoveTargetSurface({required super.builder});
}

final class RecycleBinSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const RecycleBinSurface({required super.builder});
}

final class DuplicatesSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const DuplicatesSurface({required super.builder});
}

final class HealthCategorySurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const HealthCategorySurface({required super.builder});
}

final class SyncLinkSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const SyncLinkSurface({required super.builder});
}

final class SyncConflictSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const SyncConflictSurface({required super.builder});
}

/// spec-005 T11/FR-5: the "What the merge does" review — amended
/// 2026-08-31 (user-directed): a full-screen pushed route at every width,
/// like the Duplicates destination it opens from
/// screens (same rule as every other surface).
final class MergePreviewSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const MergePreviewSurface({required super.builder});
}

/// spec-008 T601: the per-field sync merge review. A full-screen route at
/// every width; the screen lays out its own two panes when wide.
final class SyncMergeSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const SyncMergeSurface({required super.builder});
}

final class DatabaseSettingsSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const DatabaseSettingsSurface({required super.builder});
}

final class KeyFileManagerSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const KeyFileManagerSurface({required super.builder});
}

final class ConfirmationSurface<R extends VaultRouteResult>
    extends VaultSurface<R> {
  const ConfirmationSurface({required super.builder});
}

sealed class VaultSurfacePresentation {
  const VaultSurfacePresentation();
}

final class VaultRoutePresentation extends VaultSurfacePresentation {
  const VaultRoutePresentation();
}

final class VaultSheetPresentation extends VaultSurfacePresentation {
  const VaultSheetPresentation();
}

final class VaultPanePresentation extends VaultSurfacePresentation {
  const VaultPanePresentation();
}

/// spec-019 T017 — a centred dialog over the vault.
///
/// Distinct from a pane: a pane is a column of the layout and changes the
/// width arithmetic, and `Manage folders` must not (contract S2). Distinct
/// from a sheet: `KvBottomSheet` stays bottom-anchored however narrow its
/// content, which reads as a phone surface on a 1024 px window (research R4).
final class VaultDialogPresentation extends VaultSurfacePresentation {
  const VaultDialogPresentation({this.bare = false});

  /// When true the surface's builder supplies its own dialog chrome (an
  /// `AlertDialog`); the host must not wrap it in a second `Dialog`, which
  /// would render card-in-card.
  final bool bare;
}

/// spec-018 FR-002a: the presentation of a surface is decided by the single
/// width authority [VaultLayoutClass], not by a literal compared against the
/// window width. `width` is the **window** width supplied by the shell; no
/// caller may substitute its own `BoxConstraints`.
///
/// This changed behaviour in the 600–703 band (FR-002d): a pane needs
/// `VaultLayoutWidths.detailPane` (704) of room, so between the mobile break
/// and 704 the icon rail replaces the tab bar but the detail still *pushes*.
/// Previously anything at or above 600 became a pane, in a band where the
/// design's own columns do not fit.
VaultSurfacePresentation presentationFor<R extends VaultRouteResult>(
  VaultSurface<R> surface,
  double width,
) {
  final layout = VaultLayoutClass.fromWidth(width);
  final mobile = !layout.hasDetailPane;
  return switch (surface) {
    EntrySurface() ||
    OtpScannerSurface() ||
    HealthCategorySurface() ||
    SyncLinkSurface() ||
    DatabaseSettingsSurface() =>
      mobile ? const VaultRoutePresentation() : const VaultPanePresentation(),
    // Amended 2026-08-31 (user-directed): the hygiene destinations and the
    // merge preview are full-screen pushed routes at every width — the
    // 2026-08-30 dialog experiment stacked a dialog plus a sheet on wide
    // layouts and the flow got hard to read. One navigation model, as on
    // the phone.
    RecycleBinSurface() ||
    DuplicatesSurface() ||
    MergePreviewSurface() ||
    SyncMergeSurface() => const VaultRoutePresentation(),
    // spec-018 FR-002e: the generator is the one surface whose presentation
    // needs a width beyond the layout class. It becomes a 290 px column only
    // where that column fits; below 995 the sheet is a declared fallback.
    PasswordGeneratorSurface() =>
      width >= VaultLayoutWidths.generatorColumn
          ? const VaultPanePresentation()
          : const VaultSheetPresentation(),
    // Amended with spec 019's Manage dialog: a folder create/rename or a
    // move-target picker hosted in the detail *pane* renders behind any open
    // dialog (Manage) and replaces the record detail with a floating card —
    // the defect the 2026-08-30 walk caught. On wide layouts they are true
    // modal dialogs; their builders already return `AlertDialog`s, hence
    // `bare`. Contract vault_navigation_contract.md §presentations amended
    // in the same change.
    GroupEditSurface() || MoveTargetSurface() =>
      mobile
          ? const VaultSheetPresentation()
          : const VaultDialogPresentation(bare: true),
    SyncConflictSurface() =>
      mobile ? const VaultSheetPresentation() : const VaultPanePresentation(),
    KeyFileManagerSurface() => const VaultSheetPresentation(),
    // 2026-09-05 (user-directed): a yes/no confirmation is a modal dialog at
    // every width; its builder supplies the `AlertDialog`, hence `bare`.
    ConfirmationSurface() => const VaultDialogPresentation(bare: true),
  };
}

typedef VaultOperationIdFactory = VaultOperationId Function();
typedef VaultPaneChanged = void Function(Widget? pane);
typedef VaultModalHost = Future<void> Function(
  BuildContext context,
  WidgetBuilder builder,
  void Function(VoidCallback dismiss) mounted,
);

final class VaultShellRouter {
  VaultShellRouter({
    this._onPaneChanged,
    this._operationIdFactory,
    this._routeHost,
    this._sheetHost,
    this._dialogHost,
  });

  final VaultPaneChanged? _onPaneChanged;
  final VaultOperationIdFactory? _operationIdFactory;
  final VaultModalHost? _routeHost;
  final VaultModalHost? _sheetHost;
  final VaultModalHost? _dialogHost;
  final Map<VaultOperationId, _VaultOperationSession> _sessions = {};

  /// spec-018 FR-002e: true while the editor is showing its generator as a
  /// column rather than a sheet. The shell listens so it can drop the folder
  /// column, which is what makes room for it — the design's rule is that the
  /// generator collapses the FOLDERS, never the records list.
  final ValueNotifier<bool> generatorColumnOpen = ValueNotifier<bool>(false);
  final Set<VaultOperationId> _issuedIds = {};
  int _nextId = 0;
  int _nextSequence = 0;
  bool _disposed = false;

  @visibleForTesting
  int get debugLiveSessionCount => _sessions.length;

  @visibleForTesting
  bool debugRetainsOperation(VaultOperationId id) => _sessions.containsKey(id);

  Future<R?> open<R extends VaultRouteResult>({
    required BuildContext context,
    required VaultSurface<R> surface,
    double? width,
  }) {
    if (_disposed) {
      return Future<R?>.value();
    }

    final id = _newId();
    final parentId = VaultOperationScope.maybeOf(context)?.operationId;
    final presentation = presentationFor(
      surface,
      width ?? MediaQuery.sizeOf(context).width,
    );
    final session = _TypedVaultOperationSession<R>(
      id: id,
      parentId: parentId,
      sequence: _nextSequence++,
      presentation: presentation,
      surface: surface,
    );
    _sessions[id] = session;

    switch (presentation) {
      case VaultRoutePresentation():
        unawaited(_hostRoute(context, session));
      case VaultSheetPresentation():
        unawaited(_hostSheet(context, session));
      case VaultPanePresentation():
        _hostPane(session);
      case VaultDialogPresentation():
        unawaited(_hostDialog(context, session));
    }

    return session.future;
  }

  Future<ConfirmDecision?> confirm({
    required BuildContext context,
    required String title,
    required String body,
    String cancelLabel = 'Cancel',
    String confirmLabel = 'Confirm',
  }) {
    return open<ConfirmDecision>(
      context: context,
      surface: ConfirmationSurface<ConfirmDecision>(
        builder: (surfaceContext) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () =>
                  VaultOperationScope.of(surfaceContext)
                      .complete(ConfirmDecision.cancel),
              child: Text(cancelLabel),
            ),
            FilledButton(
              onPressed: () =>
                  VaultOperationScope.of(surfaceContext)
                      .complete(ConfirmDecision.confirm),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
  }

  void complete<R extends VaultRouteResult>(VaultOperationId id, R result) {
    final session = _sessions[id];
    if (session == null || !session.accepts(result)) {
      return;
    }
    _finish(id, result);
  }

  void cancel(VaultOperationId id) => _finish(id, null);

  Future<bool> requestCancel(VaultOperationId id) async {
    final session = _sessions[id];
    if (session == null) {
      return true;
    }
    final guard = session.discardGuard;
    if (guard != null && !await guard()) {
      return false;
    }
    cancel(id);
    return true;
  }

  Future<bool> cancelForDestinationChange() async {
    if (_sessions.isEmpty) {
      return true;
    }
    final latest = _sessions.values.reduce(
      (left, right) => left.sequence > right.sequence ? left : right,
    );
    final guard = latest.discardGuard;
    if (guard != null && !await guard()) {
      return false;
    }
    _cancelAll();
    return true;
  }

  Future<bool> requestCancelCurrentPane() async {
    final panes = _sessions.values
        .where((session) => session.presentation is VaultPanePresentation)
        .toList(growable: false);
    if (panes.isEmpty) {
      return false;
    }
    panes.sort((left, right) => right.sequence.compareTo(left.sequence));
    return requestCancel(panes.first.id);
  }

  void registerDiscardGuard(
    VaultOperationId id,
    Future<bool> Function()? guard,
  ) {
    _sessions[id]?.discardGuard = guard;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancelAll();
    generatorColumnOpen.dispose();
  }

  VaultOperationId _newId() {
    final id = _operationIdFactory?.call() ?? VaultOperationId._(_nextId++);
    if (!_issuedIds.add(id)) {
      throw StateError('Vault operation IDs must never be reused.');
    }
    return id;
  }

  Widget _buildScoped(_VaultOperationSession session) {
    // The session's own content must be built with a BuildContext that is
    // already a descendant of VaultOperationScope: content calls
    // `VaultOperationScope.of(context)` synchronously (e.g. Cancel/Confirm
    // button callbacks), and `context.dependOnInheritedWidgetOfExactType`
    // only finds ancestors of the context it is called with. Building
    // `session.build` from a context ABOVE the scope (the previous shape)
    // means every callback captured from that build sees no scope at all.
    return VaultOperationScope(
      operationId: session.id,
      completeOperation: (result) => complete(session.id, result),
      cancelOperation: () => requestCancel(session.id),
      registerDiscardGuard: (guard) => registerDiscardGuard(session.id, guard),
      child: PopScope(
        canPop: session.allowHostRemoval,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            unawaited(requestCancel(session.id));
          }
        },
        child: Builder(
          builder: (scopedContext) {
            if (!_sessions.containsKey(session.id)) {
              return const SizedBox.shrink();
            }
            try {
              return session.build(scopedContext);
            } catch (_) {
              cancel(session.id);
              return const SizedBox.shrink();
            }
          },
        ),
      ),
    );
  }

  Future<void> _hostRoute(
    BuildContext context,
    _VaultOperationSession session,
  ) async {
    try {
      await (_routeHost ?? _defaultRouteHost)(
        context,
        (_) => _buildScoped(session),
        (dismiss) => session.dismissHost = dismiss,
      );
    } finally {
      cancel(session.id);
    }
  }

  Future<void> _hostSheet(
    BuildContext context,
    _VaultOperationSession session,
  ) async {
    try {
      await (_sheetHost ?? _defaultSheetHost)(
        context,
        (_) => _buildScoped(session),
        (dismiss) => session.dismissHost = dismiss,
      );
    } finally {
      cancel(session.id);
    }
  }

  /// spec-019 T018 / contract S3 — the dialog is hosted here, beside the route
  /// and sheet hosts, so dialog surfaces get the same session,
  /// cancellation and result handling as everything else. A bare `showDialog`
  /// would get none of it.
  Future<void> _hostDialog(
    BuildContext context,
    _VaultOperationSession session,
  ) async {
    final presentation = session.presentation;
    final bare = presentation is VaultDialogPresentation && presentation.bare;
    try {
      await (_dialogHost ?? _defaultDialogHost)(
        context,
        (_) => bare
            ? _buildScoped(session)
            : Dialog(
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 520,
                    maxHeight: 620,
                  ),
                  child: _buildScoped(session),
                ),
              ),
        (dismiss) => session.dismissHost = dismiss,
      );
    } finally {
      cancel(session.id);
    }
  }

  void _hostPane(_VaultOperationSession session) {
    session.hostedWidget = KeyedSubtree(
      key: session.paneKey,
      child: _buildScoped(session),
    );
    _publishTopPane();
  }

  Future<void> _defaultRouteHost(
    BuildContext context,
    WidgetBuilder builder,
    void Function(VoidCallback dismiss) mounted,
  ) async {
    final navigator = Navigator.of(context);
    // Read now, synchronously, while `context` is certainly still mounted.
    final session = VaultShellSessionScope.maybeOf(context);
    late final MaterialPageRoute<void> route;
    route = MaterialPageRoute<void>(
      // Re-provide VaultShellRouterScope inside the pushed route: routes on
      // the shared app Navigator are siblings of the vault shell's own
      // content, not descendants of it, so `VaultShellRouterScope` (mounted
      // inside the shell, above this Navigator's routes but not above the
      // Navigator itself) is otherwise invisible to anything the pushed
      // surface tries to `.open()` on top of itself — e.g. the editor
      // (spec-004) opening its generator sheet on mobile, where the editor
      // itself is a pushed EntrySurface route.
      builder: (routeContext) {
        Widget hosted = VaultShellRouterScope(
          router: this,
          child: Scaffold(body: builder(routeContext)),
        );
        // Same rationale, same sibling problem: the shell's session (lock
        // state, activity, re-authentication) is published inside the shell,
        // so a pushed route cannot see it either — and below
        // `VaultLayoutWidths.detailPane` the entry detail *is* a pushed
        // route, which is where the history and the reveal gate are opened
        // from.
        if (session != null) {
          hosted = VaultShellSessionScope(
            session: session,
            // The shell's own pointer `Listener` is inside its body, which a
            // pushed route is not below — so on mobile, where every one of
            // these surfaces (detail, editor, attachments, OTP scanner, merge
            // preview) is a route, using them read as being idle and the
            // inactivity timer locked the vault mid-use. Default
            // `deferToChild` behaviour: this observes pointers, it does not
            // take them from the children.
            child: Listener(
              onPointerDown: (_) => session.reportActivity(),
              child: hosted,
            ),
          );
        }
        return hosted;
      },
    );
    mounted(() {
      // If the router itself is being disposed (whole shell teardown, not
      // just this one session ending), the Navigator/route Elements may
      // already be mid-unmount by the time this fires — let the natural
      // tree teardown remove them instead of touching a possibly-defunct
      // Navigator. `_disposed` is set before `_cancelAll()` triggers this
      // callback, so it reliably distinguishes the two cases (unlike
      // `context.mounted`, which can still read true mid-teardown).
      if (_disposed) {
        return;
      }
      if (route.isActive) {
        navigator.removeRoute(route);
      }
    });
    await navigator.push<void>(route);
  }

  // Activity reporting is asymmetric across the three default hosts, on
  // purpose and for now only: `_defaultRouteHost` re-publishes
  // `VaultShellSessionScope` and wraps its route in a pointer `Listener`, so
  // pointers in a pushed surface feed the shell's inactivity timer. The sheet
  // and dialog hosts below re-publish `VaultShellRouterScope` only — they do
  // neither. Surfaces opened through them (password generator below
  // `VaultLayoutWidths.generatorColumn`, key file manager, group edit, move
  // target, sync conflict, confirmation, and the plain `showDialog` callers)
  // therefore still read as idle while in use. Pre-existing; extending the
  // route host's treatment to sheets and dialogs is separate work, not a
  // property of these hosts that anyone should rely on.
  Future<void> _defaultSheetHost(
    BuildContext context,
    WidgetBuilder builder,
    void Function(VoidCallback dismiss) mounted,
  ) async {
    final width = MediaQuery.sizeOf(context).width;
    BuildContext? sheetContext;
    mounted(() {
      // See the matching comment in _defaultRouteHost: skip Navigator
      // manipulation during whole-router teardown.
      if (_disposed) {
        return;
      }
      final current = sheetContext;
      if (current != null &&
          current.mounted &&
          Navigator.of(current).canPop()) {
        Navigator.of(current).pop();
      }
    });
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      constraints: width < 600 ? null : const BoxConstraints(maxWidth: 560),
      builder: (modalContext) {
        sheetContext = modalContext;
        // Same rationale as _defaultRouteHost: `useRootNavigator: true`
        // hosts the sheet on the root Navigator's Overlay, detached from
        // VaultShellRouterScope's ancestor chain.
        return VaultShellRouterScope(
          router: this,
          child: KvSheetFrame(child: builder(modalContext)),
        );
      },
    );
  }

  Future<void> _defaultDialogHost(
    BuildContext context,
    WidgetBuilder builder,
    void Function(VoidCallback dismiss) mounted,
  ) async {
    BuildContext? dialogContext;
    mounted(() {
      // See the matching comment in _defaultRouteHost: skip Navigator
      // manipulation during whole-router teardown.
      if (_disposed) {
        return;
      }
      final current = dialogContext;
      if (current != null &&
          current.mounted &&
          Navigator.of(current).canPop()) {
        Navigator.of(current).pop();
      }
    });
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (modalContext) {
        dialogContext = modalContext;
        // Same rationale as the route and sheet hosts: the root Navigator's
        // Overlay is outside `VaultShellRouterScope`'s ancestor chain.
        // The Dialog chrome (or its absence, for `bare` surfaces) is decided
        // by `_hostDialog`, which knows the presentation; this host only
        // re-provides the scope.
        return VaultShellRouterScope(
          router: this,
          child: builder(modalContext),
        );
      },
    );
  }

  void _finish(VaultOperationId id, VaultRouteResult? result) {
    final session = _sessions.remove(id);
    if (session == null) {
      return;
    }

    final childIds = _sessions.values
        .where((candidate) => candidate.parentId == id)
        .map((candidate) => candidate.id)
        .toList(growable: false);
    for (final childId in childIds) {
      cancel(childId);
    }

    try {
      session.pendingResult = result;
      session.complete(result);
      session.allowHostRemoval = true;
      session.dismissHost?.call();
    } finally {
      session.clear();
      _publishTopPane();
    }
  }

  void _cancelAll() {
    final ids = _sessions.keys.toList(growable: false).reversed;
    for (final id in ids) {
      cancel(id);
    }
  }

  void _publishTopPane() {
    if (_onPaneChanged == null) {
      return;
    }
    final panes = _sessions.values
        .where(
          (session) =>
              session.presentation is VaultPanePresentation &&
              session.hostedWidget != null,
        )
        .toList(growable: false);
    if (panes.isEmpty) {
      _onPaneChanged(null);
      return;
    }
    panes.sort((left, right) => right.sequence.compareTo(left.sequence));
    _onPaneChanged(panes.first.hostedWidget);
  }
}

abstract class _VaultOperationSession {
  _VaultOperationSession({
    required this.id,
    required this.parentId,
    required this.sequence,
    required this.presentation,
  });

  final VaultOperationId id;
  final VaultOperationId? parentId;
  final int sequence;
  final VaultSurfacePresentation presentation;
  // FR-5 latching: a pane can be relocated to a structurally different
  // parent across a resize (e.g. mobile Column <-> desktop Row, or between
  // the single-pane/list+detail/folder+list+detail rail shapes). A plain
  // `ValueKey` only lets Flutter match children within the *same* parent;
  // once the parent Element itself differs, the old subtree — and any
  // in-progress form state inside it — is torn down. A `GlobalKey` lets the
  // framework find and reparent the existing Element wherever it moves in
  // the same frame, which is what "draft state ... not remounted ... by
  // resize" requires.
  final GlobalKey paneKey = GlobalKey();
  Widget? hostedWidget;
  VoidCallback? dismissHost;
  Future<bool> Function()? discardGuard;
  VaultRouteResult? pendingResult;
  bool allowHostRemoval = false;

  Future<VaultRouteResult?> get future;
  bool accepts(VaultRouteResult result);
  Widget build(BuildContext context);
  void complete(VaultRouteResult? result);

  void clear() {
    hostedWidget = null;
    dismissHost = null;
    discardGuard = null;
    pendingResult = null;
    clearSurface();
  }

  void clearSurface();
}

final class _TypedVaultOperationSession<R extends VaultRouteResult>
    extends _VaultOperationSession {
  _TypedVaultOperationSession({
    required super.id,
    required super.parentId,
    required super.sequence,
    required super.presentation,
    required VaultSurface<R> this._surface,
  });

  final Completer<R?> _completer = Completer<R?>();
  VaultSurface<R>? _surface;

  @override
  Future<R?> get future => _completer.future;

  @override
  bool accepts(VaultRouteResult result) => result is R;

  @override
  Widget build(BuildContext context) => _surface!.builder(context);

  @override
  void complete(VaultRouteResult? result) {
    if (!_completer.isCompleted) {
      _completer.complete(result as R?);
    }
  }

  @override
  void clearSurface() => _surface = null;
}

final class VaultOperationScope extends InheritedWidget {
  const VaultOperationScope({
    super.key,
    required this.operationId,
    required this.completeOperation,
    required this.cancelOperation,
    required this.registerDiscardGuard,
    required super.child,
  });

  final VaultOperationId operationId;
  final ValueChanged<VaultRouteResult> completeOperation;
  final Future<void> Function() cancelOperation;
  final ValueChanged<Future<bool> Function()?> registerDiscardGuard;

  void complete<R extends VaultRouteResult>(R result) =>
      completeOperation(result);

  Future<void> cancel() => cancelOperation();

  static VaultOperationScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'No VaultOperationScope found in context.');
    return scope!;
  }

  static VaultOperationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VaultOperationScope>();

  @override
  bool updateShouldNotify(VaultOperationScope oldWidget) =>
      operationId != oldWidget.operationId;
}

final class VaultShellRouterScope extends InheritedWidget {
  const VaultShellRouterScope({
    super.key,
    required this.router,
    required super.child,
  });

  final VaultShellRouter router;

  static VaultShellRouter of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<VaultShellRouterScope>();
    assert(scope != null, 'No VaultShellRouterScope found in context.');
    return scope!.router;
  }

  @override
  bool updateShouldNotify(VaultShellRouterScope oldWidget) =>
      router != oldWidget.router;
}
