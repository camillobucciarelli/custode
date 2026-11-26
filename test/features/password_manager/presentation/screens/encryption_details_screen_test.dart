// The read-only Encryption page opened from Settings.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_manager/core/theme/app_theme.dart';
import 'package:password_manager/features/password_manager/domain/models/vault_encryption.dart';
import 'package:password_manager/features/password_manager/presentation/screens/encryption_details_screen.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester, VaultEncryption encryption) =>
      tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: EncryptionDetailsScreen(
            encryption: encryption,
            databaseName: 'Personal.kdbx',
          ),
        ),
      );

  const footer =
      'Set when the database was created. New databases use '
      'AES-256 · Argon2id.';

  testWidgets('Argon2: cipher, KDF, memory/iterations/parallelism, format', (
    tester,
  ) async {
    await pumpPage(
      tester,
      const VaultEncryption(
        cipher: VaultCipher.chaCha20,
        kdf: VaultKdf.argon2d,
        kdbxVersion: '4.1',
        iterations: 10,
        memoryBytes: 64 * 1024 * 1024,
        parallelism: 4,
      ),
    );

    expect(find.text('Encryption'), findsOneWidget);
    expect(find.text('Personal.kdbx'), findsOneWidget);
    expect(find.text('ALGORITHM'), findsOneWidget);
    expect(find.text('ChaCha20'), findsOneWidget);
    expect(find.text('Argon2d'), findsOneWidget);
    expect(
      find.text('64 MiB memory · 10 iterations · parallelism 4'),
      findsOneWidget,
    );
    expect(find.text('FILE'), findsOneWidget);
    expect(find.text('KDBX 4.1'), findsOneWidget);
    expect(find.text(footer), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
  });

  testWidgets('AES-KDF: rounds with thousands separators', (tester) async {
    await pumpPage(
      tester,
      const VaultEncryption(
        cipher: VaultCipher.aes256,
        kdf: VaultKdf.aesKdf,
        kdbxVersion: '4.0',
        rounds: 1000000,
      ),
    );

    expect(find.text('AES-KDF'), findsOneWidget);
    expect(find.text('1,000,000 rounds'), findsOneWidget);
    expect(find.text('KDBX 4.0'), findsOneWidget);
  });

  testWidgets('unknown cost and version leave their rows out', (tester) async {
    await pumpPage(tester, VaultEncryption.defaults);

    expect(find.text('Key derivation settings'), findsNothing);
    expect(find.text('FILE'), findsNothing);
    expect(find.text(footer), findsOneWidget);
  });
}
