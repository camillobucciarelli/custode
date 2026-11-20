import 'package:flutter_test/flutter_test.dart';
import 'package:password_manager/features/password_manager/presentation/widgets/internal_key_file_manager_sheet.dart';

void main() {
  test('protects current, pending, and shared key file paths', () {
    const current = '/keys/current.key';
    const pending = '/keys/pending.key';
    const shared = '/keys/shared.key';
    const protectedPaths = {current, pending, shared};

    expect(isProtectedKeyFilePath(current, protectedPaths), isTrue);
    expect(
      isProtectedKeyFilePath('/keys/./pending.key', protectedPaths),
      isTrue,
    );
    expect(isProtectedKeyFilePath(shared, protectedPaths), isTrue);
    expect(
      isProtectedKeyFilePath('/keys/unreferenced.key', protectedPaths),
      isFalse,
    );
  });
}
