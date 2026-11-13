// spec-002 T1-T3: VaultShellRouter contract tests.
//
// Tests the real, concrete `VaultShellRouter` through a widget harness (per
// plan.md: "no VaultShellRouterContract, mock subclass or second
// implementation"). Uses the existing sealed `VaultSurface`/`VaultRouteResult`
// subtypes since both hierarchies are sealed to their declaring library.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/navigation/vault_shell_router.dart';

Widget _noop(BuildContext context) =>
    const SizedBox.shrink(key: ValueKey('surface-child'));

void main() {
  group('presentationFor — FR-6 exhaustive dispatch at 390 and 1024', () {
    const mobileWidth = 390.0;
    const railWidth = 1024.0;

    void expectRouteThenPane(VaultSurface<VaultDone> surface) {
      expect(
        presentationFor(surface, mobileWidth),
        isA<VaultRoutePresentation>(),
      );
      expect(presentationFor(surface, railWidth), isA<VaultPanePresentation>());
    }

    void expectSheetThenPane(VaultSurface<VaultDone> surface) {
      expect(
        presentationFor(surface, mobileWidth),
        isA<VaultSheetPresentation>(),
      );
      expect(presentationFor(surface, railWidth), isA<VaultPanePresentation>());
    }

    void expectSheetThenBareDialog(VaultSurface<VaultDone> surface) {
      expect(
        presentationFor(surface, mobileWidth),
        isA<VaultSheetPresentation>(),
      );
      final wide = presentationFor(surface, railWidth);
      expect(wide, isA<VaultDialogPresentation>());
      expect((wide as VaultDialogPresentation).bare, isTrue);
    }

    void expectAlwaysRoute(VaultSurface<VaultDone> surface) {
      expect(
        presentationFor(surface, mobileWidth),
        isA<VaultRoutePresentation>(),
      );
      expect(
        presentationFor(surface, railWidth),
        isA<VaultRoutePresentation>(),
      );
    }

    void expectAlwaysSheet(VaultSurface<VaultDone> surface) {
      expect(
        presentationFor(surface, mobileWidth),
        isA<VaultSheetPresentation>(),
      );
      expect(
        presentationFor(surface, railWidth),
        isA<VaultSheetPresentation>(),
      );
    }

    test('Entry detail/editor: route / pane', () {
      expectRouteThenPane(EntrySurface<VaultDone>(builder: _noop));
    });
    test('OTP QR scanner: route / pane', () {
      expectRouteThenPane(OtpScannerSurface<VaultDone>(builder: _noop));
    });
    // 2026-08-31 (user-directed): hygiene destinations and the merge
    // preview are full-screen pushed routes at every width.
    test('Recycle bin: route / route', () {
      expectAlwaysRoute(RecycleBinSurface<VaultDone>(builder: _noop));
    });
    test('Duplicates: route / route', () {
      expectAlwaysRoute(DuplicatesSurface<VaultDone>(builder: _noop));
    });
    test('Merge preview: route / route', () {
      expectAlwaysRoute(MergePreviewSurface<VaultDone>(builder: _noop));
    });
    test('Sync link/remote picker: route / pane', () {
      expectRouteThenPane(SyncLinkSurface<VaultDone>(builder: _noop));
    });
    test('Database settings/CSV import: route / pane', () {
      expectRouteThenPane(DatabaseSettingsSurface<VaultDone>(builder: _noop));
    });
    test('Password generator: sheet / pane', () {
      expectSheetThenPane(PasswordGeneratorSurface<VaultDone>(builder: _noop));
    });
    // Amended 2026-08-30: on wide these are bare dialogs, not panes — see
    // vault_navigation_contract.md §presentations.
    test('Group create/rename: sheet / dialog', () {
      expectSheetThenBareDialog(GroupEditSurface<VaultDone>(builder: _noop));
    });
    test('Move target: sheet / dialog', () {
      expectSheetThenBareDialog(MoveTargetSurface<VaultDone>(builder: _noop));
    });
    test('Sync conflict: sheet / pane', () {
      expectSheetThenPane(SyncConflictSurface<VaultDone>(builder: _noop));
    });
    test('Key-file manager: sheet / sheet', () {
      expectAlwaysSheet(KeyFileManagerSurface<VaultDone>(builder: _noop));
    });
    // 2026-09-05 (user-directed): yes/no confirmations are dialogs at every
    // width.
    test('Confirmations: bare dialog / bare dialog', () {
      final surface = ConfirmationSurface<VaultDone>(builder: _noop);
      for (final width in [mobileWidth, railWidth]) {
        final got = presentationFor(surface, width);
        expect(got, isA<VaultDialogPresentation>());
        expect((got as VaultDialogPresentation).bare, isTrue);
      }
    });
  });

  group('Redacted DTO diagnostics', () {
    test('EntryEditResult redacts secret fields', () {
      const result = EntryEditResult(
        title: 't',
        username: 'u',
        password: 'super-secret',
        url: 'https://example.com',
        notes: 'private-note-body',
        otpUri: 'otpauth://x',
        customFields: [],
        attachmentPaths: [],
      );
      expect(result.toString(), isNot(contains('super-secret')));
      expect(result.toString(), isNot(contains('private-note-body')));
      expect(result.toString(), isNot(contains('otpauth://x')));
      expect(result.props, isNot(contains('super-secret')));
    });

    test('GeneratedPasswordResult redacts the password', () {
      const result = GeneratedPasswordResult('super-secret');
      expect(result.toString(), isNot(contains('super-secret')));
      expect(result.props, isNot(contains('super-secret')));
    });

    test('DatabaseSettingsResult redacts credentials', () {
      const result = DatabaseSettingsResult(
        fileName: 'db.kdbx',
        keyFilePath: '/keys/a.key',
        biometricProtectionEnabled: true,
        changePassword: true,
        inactivityLockTimeoutSeconds: 30,
        currentPassword: 'old-secret',
        newPassword: 'new-secret',
      );
      expect(result.toString(), isNot(contains('old-secret')));
      expect(result.toString(), isNot(contains('new-secret')));
      expect(result.toString(), isNot(contains('/keys/a.key')));
    });
  });

  group('router mechanics via widget harness', () {
    testWidgets('open()/complete() resolves the exact typed result once', (
      tester,
    ) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final future = router.open<VaultDone>(
        context: ctx,
        width: 1024, // pane presentation: hosted synchronously, no Navigator
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();

      expect(router.debugLiveSessionCount, 1);
      final scope = _findOperationScope(tester);
      scope.complete(const VaultDone());
      await tester.pump();

      expect(await future, const VaultDone());
      expect(router.debugLiveSessionCount, 0);
    });

    testWidgets('duplicate/stale completion after terminal is a no-op', (
      tester,
    ) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final future = router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();
      final scope = _findOperationScope(tester);
      final id = scope.operationId;

      router.complete(id, const VaultDone());
      await tester.pump();
      expect(await future, const VaultDone());

      // Stale/duplicate completion on the now-terminal id must be a no-op:
      // no exception, no change, and it must not resolve a later operation.
      expect(() => router.complete(id, const VaultDone()), returnsNormally);
      expect(router.debugRetainsOperation(id), isFalse);
    });

    testWidgets('cancel()/back resolves null exactly once', (tester) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final future = router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();
      final scope = _findOperationScope(tester);
      final id = scope.operationId;

      router.cancel(id);
      await tester.pump();

      expect(await future, isNull);
      expect(router.debugRetainsOperation(id), isFalse);
    });

    testWidgets('sequential opens issue distinct, never-reused ids', (
      tester,
    ) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final firstFuture = router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();
      final firstId = _findOperationScope(tester).operationId;
      router.cancel(firstId);
      await firstFuture;
      await tester.pump();

      final secondFuture = router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();
      final secondId = _findOperationScope(tester).operationId;

      expect(secondId, isNot(equals(firstId)));
      router.cancel(secondId);
      await secondFuture;
    });

    testWidgets('nested confirmation gets its own id and does not replace '
        'the parent session', (tester) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final parentFuture = router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();
      final parentScope = _findOperationScope(tester);
      final parentId = parentScope.operationId;

      final childFuture = router.confirm(
        context: tester.element(find.byKey(const ValueKey('surface-child'))),
        title: 'Nested?',
        body: 'body',
      );
      await tester.pump();

      expect(router.debugLiveSessionCount, 2);
      expect(router.debugRetainsOperation(parentId), isTrue);

      // Closing the parent terminally cancels the still-open child.
      router.cancel(parentId);
      await tester.pump();

      expect(await parentFuture, isNull);
      expect(await childFuture, isNull);
      expect(router.debugLiveSessionCount, 0);
    });

    testWidgets('router dispose() cancels every live operation', (
      tester,
    ) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final future = router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();
      expect(router.debugLiveSessionCount, 1);

      router.dispose();
      await tester.pump();

      expect(await future, isNull);
      expect(router.debugLiveSessionCount, 0);

      // A disposed router refuses new operations rather than throwing.
      final afterDispose = await router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      expect(afterDispose, isNull);
    });

    testWidgets('confirm() drives the ConfirmDecision contract', (
      tester,
    ) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final future = router.confirm(
        context: ctx,
        title: 'Confirm delete',
        body: 'Delete this entry?',
      );
      await tester.pump();

      expect(find.text('Confirm delete'), findsOneWidget);
      expect(find.text('Delete this entry?'), findsOneWidget);

      final scope = VaultOperationScope.of(
        tester.element(find.byType(AlertDialog)),
      );
      scope.complete(ConfirmDecision.confirm);
      await tester.pump();

      expect(await future, ConfirmDecision.confirm);
    });
  });

  group('T6: cancelForDestinationChange()', () {
    testWidgets('cancels every open session when no discard guard is set', (
      tester,
    ) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final future = router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();
      expect(router.debugLiveSessionCount, 1);

      final accepted = await router.cancelForDestinationChange();
      await tester.pump();

      expect(accepted, isTrue);
      expect(router.debugLiveSessionCount, 0);
      expect(await future, isNull);
    });

    testWidgets(
      'a rejecting discard guard keeps the session open and reports false',
      (tester) async {
        late VaultShellRouter router;
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
          ),
        );
        await tester.pump();

        final future = router.open<VaultDone>(
          context: ctx,
          width: 1024,
          surface: EntrySurface<VaultDone>(builder: _noop),
        );
        await tester.pump();
        final id = _findOperationScope(tester).operationId;
        router.registerDiscardGuard(id, () async => false);

        final accepted = await router.cancelForDestinationChange();
        await tester.pump();

        expect(accepted, isFalse);
        expect(router.debugLiveSessionCount, 1);
        expect(router.debugRetainsOperation(id), isTrue);

        // Clean up: the still-open session must not leak into other tests.
        router.cancel(id);
        expect(await future, isNull);
      },
    );

    testWidgets('an accepting discard guard cancels the session', (
      tester,
    ) async {
      late VaultShellRouter router;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: _RouterHarness(onReady: (r, c) => (router = r, ctx = c)),
        ),
      );
      await tester.pump();

      final future = router.open<VaultDone>(
        context: ctx,
        width: 1024,
        surface: EntrySurface<VaultDone>(builder: _noop),
      );
      await tester.pump();
      final id = _findOperationScope(tester).operationId;
      router.registerDiscardGuard(id, () async => true);

      final accepted = await router.cancelForDestinationChange();
      await tester.pump();

      expect(accepted, isTrue);
      expect(router.debugLiveSessionCount, 0);
      expect(await future, isNull);
    });
  });

  group('T6: latched presentation survives resize', () {
    testWidgets(
      'a pane opened at desktop width keeps its state and stays unresolved '
      'across every FR-3 layout-shape boundary down to mobile',
      (tester) async {
        late VaultShellRouter router;
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: _ResizableShapeHarness(
              initialWidth: 1024,
              onReady: (r, c) => (router = r, ctx = c),
            ),
          ),
        );
        await tester.pump();

        final future = router.open<VaultDone>(
          context: ctx,
          width: 1024,
          surface: EntrySurface<VaultDone>(
            builder: (_) => const _StatefulCounter(),
          ),
        );
        var resolved = false;
        unawaited(future.then((_) => resolved = true));
        await tester.pump();
        expect(router.debugLiveSessionCount, 1);

        // Establish dirty state inside the hosted pane.
        await tester.tap(find.byKey(const ValueKey('counter-increment')));
        await tester.pump();
        expect(find.text('count: 1'), findsOneWidget);

        // >=1024 (folder+list+detail) -> 708-1023 (list+detail): still a
        // desktop shape, but a structurally different Row.
        _ResizableShapeHarnessState.of(tester).setWidth(800);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('count: 1'), findsOneWidget);
        expect(router.debugLiveSessionCount, 1);

        // 708-1023 -> 600-707 (single content pane): another shape change.
        _ResizableShapeHarnessState.of(tester).setWidth(650);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('count: 1'), findsOneWidget);
        expect(router.debugLiveSessionCount, 1);

        // Cross the mobile/rail boundary (600): Column replaces Row as the
        // root of the shape — the most drastic structural change. FR-5:
        // "a pane opened at desktop remains shell-owned after shrink ...
        // Draft state and pending future are not remounted or completed."
        _ResizableShapeHarnessState.of(tester).setWidth(390);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('count: 1'), findsOneWidget);
        expect(router.debugLiveSessionCount, 1);
        expect(resolved, isFalse);

        // Grow back to desktop: still the same live, unresolved session.
        _ResizableShapeHarnessState.of(tester).setWidth(1024);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('count: 1'), findsOneWidget);
        expect(router.debugLiveSessionCount, 1);

        final scope = _findOperationScope(tester);
        scope.complete(const VaultDone());
        await tester.pump();
        expect(await future, const VaultDone());
      },
    );

    testWidgets(
      'a mobile-pushed route stays a route (and unresolved) after the '
      'window grows past the rail breakpoint',
      (tester) async {
        late VaultShellRouter router;
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: _ResizableShapeHarness(
              initialWidth: 390,
              onReady: (r, c) => (router = r, ctx = c),
            ),
          ),
        );
        await tester.pump();

        final future = router.open<VaultDone>(
          context: ctx,
          width: 390, // mobile: EntrySurface dispatches to a route.
          surface: EntrySurface<VaultDone>(builder: _noop),
        );
        var resolved = false;
        unawaited(future.then((_) => resolved = true));
        await tester.pumpAndSettle();
        expect(router.debugLiveSessionCount, 1);
        expect(find.byKey(const ValueKey('surface-child')), findsOneWidget);

        // Growing the ambient width must not force the still-pushed route
        // to complete/close or be reinterpreted as a pane (FR-5: "A
        // mobile-pushed route remains a route after window growth until it
        // closes").
        _ResizableShapeHarnessState.of(tester).setWidth(1024);
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(router.debugLiveSessionCount, 1);
        expect(resolved, isFalse);
        expect(find.byKey(const ValueKey('surface-child')), findsOneWidget);

        router.cancel(_findOperationScope(tester).operationId);
        expect(await future, isNull);
      },
    );
  });
}

VaultOperationScope _findOperationScope(WidgetTester tester) {
  // 'surface-child' is the leaf built by the surface's own builder, i.e. a
  // genuine descendant of the VaultOperationScope the router installs.
  return VaultOperationScope.of(
    tester.element(find.byKey(const ValueKey('surface-child'))),
  );
}

class _RouterHarness extends StatefulWidget {
  const _RouterHarness({required this.onReady});

  final void Function(VaultShellRouter router, BuildContext context) onReady;

  @override
  State<_RouterHarness> createState() => _RouterHarnessState();
}

class _RouterHarnessState extends State<_RouterHarness> {
  late final VaultShellRouter router;
  Widget? pane;

  @override
  void initState() {
    super.initState();
    router = VaultShellRouter(
      onPaneChanged: (p) {
        if (mounted) setState(() => pane = p);
      },
    );
  }

  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VaultShellRouterScope(
      router: router,
      child: Scaffold(
        body: Column(
          children: [
            Builder(
              builder: (innerContext) {
                widget.onReady(router, innerContext);
                return const SizedBox.shrink();
              },
            ),
            if (pane != null)
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('pane-host'),
                  child: pane!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// T6: a harness that reproduces the *shape* of `_VaultNavigationLayout`
/// (vault_shell.part.dart) — a genuinely different `Row`/`Column` Element at
/// each FR-3 width bucket, not just different constraints on one fixed
/// widget tree. [setWidth] changes only the layout bucket, never the pane
/// content itself, so it exercises exactly the scenario FR-5 constrains:
/// the *same* hosted pane widget getting relocated to a structurally
/// different parent by a resize.
class _ResizableShapeHarness extends StatefulWidget {
  const _ResizableShapeHarness({
    required this.initialWidth,
    required this.onReady,
  });

  final double initialWidth;
  final void Function(VaultShellRouter router, BuildContext context) onReady;

  @override
  State<_ResizableShapeHarness> createState() => _ResizableShapeHarnessState();
}

class _ResizableShapeHarnessState extends State<_ResizableShapeHarness> {
  late final VaultShellRouter router;
  Widget? pane;
  late double _width;

  // `skipOffstage: false`: once a route pushes on top, the Navigator marks
  // this widget's subtree offstage even though it stays mounted (FR-5: "a
  // mobile-pushed route remains a route" — the harness underneath is still
  // alive, just not painted).
  static _ResizableShapeHarnessState of(WidgetTester tester) =>
      tester.state(find.byType(_ResizableShapeHarness, skipOffstage: false));

  void setWidth(double width) => setState(() => _width = width);

  @override
  void initState() {
    super.initState();
    _width = widget.initialWidth;
    router = VaultShellRouter(
      onPaneChanged: (p) {
        if (mounted) setState(() => pane = p);
      },
    );
  }

  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hosted = pane ?? const SizedBox.shrink();
    final Widget shape;
    if (_width < 600) {
      // Mobile: Column body + tab-bar stand-in (FR-2).
      shape = Column(
        key: const ValueKey('shape-mobile'),
        children: [
          Expanded(child: hosted),
          const SizedBox(height: 8, key: ValueKey('tab-bar-stand-in')),
        ],
      );
    } else if (_width < 708) {
      // 600-707: rail + one content pane (FR-3).
      shape = Row(
        key: const ValueKey('shape-single-pane'),
        children: [
          const SizedBox(width: 76, key: ValueKey('rail-stand-in')),
          Expanded(child: hosted),
        ],
      );
    } else if (_width < 1024) {
      // 708-1023: rail + list + detail (FR-3).
      shape = Row(
        key: const ValueKey('shape-list-detail'),
        children: [
          const SizedBox(width: 76, key: ValueKey('rail-stand-in')),
          const SizedBox(width: 330, key: ValueKey('list-stand-in')),
          Expanded(child: hosted),
        ],
      );
    } else {
      // >=1024: rail + folder + list + detail (FR-3).
      shape = Row(
        key: const ValueKey('shape-folder-list-detail'),
        children: [
          const SizedBox(width: 76, key: ValueKey('rail-stand-in')),
          const SizedBox(width: 236, key: ValueKey('folder-stand-in')),
          const SizedBox(width: 330, key: ValueKey('list-stand-in')),
          Expanded(child: hosted),
        ],
      );
    }

    return VaultShellRouterScope(
      router: router,
      child: Scaffold(
        body: Column(
          children: [
            Builder(
              builder: (innerContext) {
                widget.onReady(router, innerContext);
                return const SizedBox.shrink();
              },
            ),
            Expanded(child: shape),
          ],
        ),
      ),
    );
  }
}

/// T6: minimal stateful "dirty form" stand-in — a counter proves the same
/// State survives a resize/reparent rather than being disposed and rebuilt
/// from scratch.
class _StatefulCounter extends StatefulWidget {
  const _StatefulCounter();

  @override
  State<_StatefulCounter> createState() => _StatefulCounterState();
}

class _StatefulCounterState extends State<_StatefulCounter> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('surface-child'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('count: $_count'),
        IconButton(
          key: const ValueKey('counter-increment'),
          icon: const Icon(Icons.add),
          onPressed: () => setState(() => _count++),
        ),
      ],
    );
  }
}
