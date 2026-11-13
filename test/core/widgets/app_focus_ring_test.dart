import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_colors.dart';
import 'package:password_manager/core/widgets/app_focus_ring.dart';

void main() {
  testWidgets('geometrically paints exact 2 px gap and 2 px outer ring', (
    tester,
  ) async {
    final focusNode = _AlwaysFocusedNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(focusColor: AppColors.accent400),
        home: Center(
          child: AppFocusRing(
            key: const ValueKey('geometry-ring'),
            focusNode: focusNode,
            borderRadius: BorderRadius.zero,
            child: const SizedBox.square(dimension: 20),
          ),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('geometry-ring')),
        matching: find.byType(CustomPaint),
      ),
      paints..rrect(
        rrect: RRect.fromRectAndRadius(
          const Rect.fromLTWH(-3, -3, 26, 26),
          const Radius.circular(3),
        ),
        color: AppColors.accent400,
        strokeWidth: 2,
        style: PaintingStyle.stroke,
      ),
    );
  });

  testWidgets(
    'preserves child semantics, hit testing, and FocusNode ownership',
    (tester) async {
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: AppFocusRing(
              focusNode: focusNode,
              borderRadius: BorderRadius.circular(8),
              child: Focus(
                focusNode: focusNode,
                child: Semantics(
                  button: true,
                  label: 'Focus target',
                  child: GestureDetector(
                    key: const ValueKey('tap-target'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: const SizedBox.square(dimension: 44),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();

      expect(find.bySemanticsLabel('Focus target'), findsOneWidget);

      final target = tester.renderObject(
        find.byKey(const ValueKey('tap-target')),
      );
      final hitTest = tester.hitTestOnBinding(
        tester.getCenter(find.byKey(const ValueKey('tap-target'))),
      );
      expect(hitTest.path.any((entry) => entry.target == target), isTrue);
      focusNode.unfocus();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      void listener() {}

      expect(() => focusNode.addListener(listener), returnsNormally);
      focusNode.removeListener(listener);
      focusNode.dispose();
    },
  );

  for (final control in <String>['Switch', 'Checkbox']) {
    testWidgets('$control uses shared FocusNode without duplicate semantics', (
      tester,
    ) async {
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      final label = '$control focused';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppFocusRing(
                key: const ValueKey('ring'),
                focusNode: focusNode,
                borderRadius: BorderRadius.circular(
                  control == 'Switch' ? 999 : 14,
                ),
                child: control == 'Switch'
                    ? MergeSemantics(
                        child: Semantics(
                          label: label,
                          child: Switch(
                            focusNode: focusNode,
                            value: true,
                            onChanged: (_) {},
                          ),
                        ),
                      )
                    : Checkbox(
                        focusNode: focusNode,
                        semanticLabel: label,
                        value: true,
                        onChanged: (_) {},
                      ),
              ),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(find.bySemanticsLabel(label), findsOneWidget);
      final stack = tester.widget<Stack>(
        find
            .descendant(
              of: find.byKey(const ValueKey('ring')),
              matching: find.byType(Stack),
            )
            .first,
      );
      expect(stack.clipBehavior, Clip.none);
      expect(stack.children, hasLength(2));
    });
  }
}

class _AlwaysFocusedNode extends FocusNode {
  @override
  bool get hasFocus => true;
}
