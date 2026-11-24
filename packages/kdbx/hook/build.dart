import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds `kdbx_native`: the Argon2 reference implementation (phc-winner-argon2)
/// and the hardware AES-KDF transform. Dart falls back to its own
/// implementations when the library or the CPU support is missing.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final os = input.config.code.targetOS;
    await CBuilder.library(
      name: 'kdbx_native',
      assetName: 'src/internal/native_kdf_ffi.dart',
      sources: [
        'src/aes_kdf.c',
        'src/argon2/argon2.c',
        'src/argon2/core.c',
        'src/argon2/encoding.c',
        'src/argon2/ref.c',
        'src/argon2/thread.c',
        'src/argon2/blake2/blake2b.c',
      ],
      includes: ['src/argon2', 'src/argon2/include'],
      // Exports only the ARGON2_PUBLIC API and kdbx_aes_kdf (MSVC exports
      // the dllexport ones).
      defines: {if (os != OS.windows) 'A2_VISCTL': null},
      flags: [if (os != OS.windows) '-fvisibility=hidden'],
      libraries: [if (os == OS.linux) 'pthread'],
    ).run(input: input, output: output);
  });
}
