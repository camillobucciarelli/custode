// 009 / B002 — generator settings UI semantics: initialize from repository,
// draft-local edits, Apply/Cancel/Reset, clean-follows-watch,
// dirty-keeps-edits, stale-revision Apply rejected until reload.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/core/widgets/kv_checkbox.dart';
import 'package:password_manager/features/password_manager/domain/repositories/password_generator_settings_repository.dart';
import 'package:password_manager/features/password_manager/presentation/screens/vault/password_generator_settings.dart';

class _FakeSettingsRepository implements PasswordGeneratorSettingsRepository {
  _FakeSettingsRepository([GeneratorSettingsSnapshot? initial])
    : committed = initial ?? const GeneratorSettingsSnapshot.defaults();

  GeneratorSettingsSnapshot committed;
  final _updates = StreamController<GeneratorSettingsSnapshot>.broadcast();
  final savedDrafts = <(GeneratorSettingsSnapshot, int)>[];
  int readCount = 0;
  int resetCount = 0;

  /// Simulates a commit from another consumer (a second open settings UI).
  void externalCommit(GeneratorSettingsSnapshot snapshot) {
    committed = snapshot;
    _updates.add(snapshot);
  }

  @override
  Future<GeneratorSettingsSnapshot> read() async {
    readCount++;
    return committed;
  }

  @override
  Future<GeneratorSettingsSnapshot> save(
    GeneratorSettingsSnapshot draft, {
    required int expectedRevision,
  }) async {
    savedDrafts.add((draft, expectedRevision));
    if (expectedRevision != committed.revision) {
      throw const GeneratorSettingsStaleRevisionException();
    }
    committed = draft.copyWith(revision: expectedRevision + 1);
    _updates.add(committed);
    return committed;
  }

  @override
  Future<GeneratorSettingsSnapshot> reset() async {
    resetCount++;
    committed = GeneratorSettingsSnapshot.defaults().copyWith(
      revision: committed.revision + 1,
    );
    _updates.add(committed);
    return committed;
  }

  @override
  Stream<GeneratorSettingsSnapshot> watch() => _updates.stream;
}

Future<void> _pumpPanel(
  WidgetTester tester,
  PasswordGeneratorSettingsRepository repository, {
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: PasswordGeneratorSettingsPanel(
            repository: repository,
            onClose: onClose,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _checkboxRow(String label) {
  return find.widgetWithText(KvCheckboxRow, label);
}

void main() {
  testWidgets('initializes from the repository snapshot', (tester) async {
    final repository = _FakeSettingsRepository(
      const GeneratorSettingsSnapshot(
        revision: 3,
        length: 24,
        includeLowercase: true,
        includeUppercase: false,
        includeDigits: true,
        includeSymbols: false,
      ),
    );

    await _pumpPanel(tester, repository);

    expect(repository.readCount, 1);
    expect(find.text('24'), findsOneWidget);
    expect(
      tester
          .widget<KvCheckboxRow>(_checkboxRow('Uppercase letters (A-Z)'))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<KvCheckboxRow>(_checkboxRow('Lowercase letters (a-z)'))
          .value,
      isTrue,
    );
    // Clean panel: nothing to apply yet.
    expect(
      tester
          .widget<ElevatedButton>(
            find.descendant(
              of: find.byKey(const ValueKey('generator-settings-apply')),
              matching: find.byType(ElevatedButton),
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('Apply commits the draft with the loaded revision', (
    tester,
  ) async {
    final repository = _FakeSettingsRepository();
    await _pumpPanel(tester, repository);

    await tester.tap(_checkboxRow('Special characters (!@#...)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('generator-settings-apply')));
    await tester.pumpAndSettle();

    expect(repository.savedDrafts, hasLength(1));
    final (draft, expectedRevision) = repository.savedDrafts.single;
    expect(draft.includeSymbols, isFalse);
    expect(expectedRevision, 1);
    expect(repository.committed.revision, 2);
    expect(repository.committed.includeSymbols, isFalse);
  });

  testWidgets('Cancel is a no-op: closes without any repository commit', (
    tester,
  ) async {
    final repository = _FakeSettingsRepository();
    var closed = false;
    await _pumpPanel(tester, repository, onClose: () => closed = true);

    await tester.tap(_checkboxRow('Numbers (0-9)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('generator-settings-cancel')));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(repository.savedDrafts, isEmpty);
    expect(repository.resetCount, 0);
    expect(repository.committed.includeDigits, isTrue);
  });

  testWidgets('explicit Reset commits defaults through the repository', (
    tester,
  ) async {
    final repository = _FakeSettingsRepository(
      const GeneratorSettingsSnapshot(
        revision: 5,
        length: 40,
        includeLowercase: true,
        includeUppercase: true,
        includeDigits: true,
        includeSymbols: false,
      ),
    );
    await _pumpPanel(tester, repository);

    await tester.tap(find.byKey(const ValueKey('generator-settings-reset')));
    await tester.pumpAndSettle();

    expect(repository.resetCount, 1);
    expect(repository.committed.length, 16);
    expect(repository.committed.revision, 6);
    // UI adopted the committed defaults.
    expect(find.text('16'), findsOneWidget);
  });

  testWidgets('clean open UI follows repository watch() updates immediately', (
    tester,
  ) async {
    final repository = _FakeSettingsRepository();
    await _pumpPanel(tester, repository);

    repository.externalCommit(
      const GeneratorSettingsSnapshot(
        revision: 2,
        length: 48,
        includeLowercase: true,
        includeUppercase: true,
        includeDigits: true,
        includeSymbols: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('48'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('generator-settings-external-change')),
      findsNothing,
    );
  });

  testWidgets('dirty draft keeps local edits, marks external change, rejects '
      'stale Apply until reload', (tester) async {
    final repository = _FakeSettingsRepository();
    await _pumpPanel(tester, repository);

    // Dirty the draft.
    await tester.tap(_checkboxRow('Special characters (!@#...)'));
    await tester.pumpAndSettle();

    // A concurrent consumer commits revision 2.
    repository.externalCommit(
      const GeneratorSettingsSnapshot(
        revision: 2,
        length: 48,
        includeLowercase: true,
        includeUppercase: true,
        includeDigits: true,
        includeSymbols: true,
      ),
    );
    await tester.pumpAndSettle();

    // Draft edits are retained; the external change is surfaced.
    expect(find.text('16'), findsOneWidget);
    expect(find.text('48'), findsNothing);
    expect(
      tester
          .widget<KvCheckboxRow>(_checkboxRow('Special characters (!@#...)'))
          .value,
      isFalse,
    );
    expect(
      find.byKey(const ValueKey('generator-settings-external-change')),
      findsOneWidget,
    );

    // Stale Apply (still carrying revision 1) is rejected.
    await tester.tap(find.byKey(const ValueKey('generator-settings-apply')));
    await tester.pumpAndSettle();
    expect(repository.committed.revision, 2);
    expect(repository.committed.length, 48);
    expect(
      find.byKey(const ValueKey('generator-settings-error')),
      findsOneWidget,
    );

    // Reload adopts the latest committed snapshot; a fresh edit then applies.
    await tester.tap(find.byKey(const ValueKey('generator-settings-reload')));
    await tester.pumpAndSettle();
    expect(find.text('48'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('generator-settings-external-change')),
      findsNothing,
    );

    await tester.tap(_checkboxRow('Special characters (!@#...)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('generator-settings-apply')));
    await tester.pumpAndSettle();

    expect(repository.committed.revision, 3);
    expect(repository.committed.includeSymbols, isFalse);
    expect(
      find.byKey(const ValueKey('generator-settings-error')),
      findsNothing,
    );
  });
}
