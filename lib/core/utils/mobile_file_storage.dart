import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'managed_storage_root.dart';

import 'portable_path.dart';

class AppStorageFileEntry {
  const AppStorageFileEntry({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;
}

/// spec 014 FR-3: key files rest under an opaque identifier, so their
/// human-readable name has to live somewhere encrypted. This is that
/// somewhere's contract; the data layer implements it and installs it on
/// [MobileFileStorage.keyFileNames]. Keys are the at-rest basename.
abstract class ManagedKeyFileNames {
  Future<Map<String, String>> getAll();
  Future<void> set(String opaqueName, String displayName);
  Future<void> remove(String opaqueName);
}

/// File helpers for the app-managed storage directory.
///
/// ## Path preconditions
///
/// Every path passed to the containment-checked members
/// ([isPathInAppDirectory], [deleteFileFromAppDirectory]) must be
/// **pre-normalized and free of `..` segments**. Traversal is refused
/// permanently rather than resolved: see `_containsTraversal`.
///
/// This holds for every caller today — paths originate from `p.join` or from
/// the file picker, and neither emits `..`. A future caller handing over a
/// user-typed or externally-supplied path must normalize it first
/// (`p.normalize`, or `p.canonicalize` when the file exists), otherwise it
/// will be rejected even when it points inside app storage.
class MobileFileStorage {
  /// Where the human-readable name of every managed key file is kept.
  ///
  /// ponytail: a static seam rather than a constructor dependency, because
  /// every key-file writer in the app (import service, session coordinator,
  /// both key-file managers) already funnels through this class — one hook
  /// here covers them all. `null` (tests, before DI) means names are simply
  /// not recorded and the listing falls back to the basename.
  static ManagedKeyFileNames? keyFileNames;

  static const _keysSubdirectory = 'keys';

  /// The name to show for a managed key file at [filePath].
  ///
  /// The recorded name, else a neutral label when the basename is opaque
  /// (a key imported before names were recorded), else the basename itself
  /// (desktop, where the file name is the name).
  static Future<String> keyFileDisplayName(String filePath) async {
    final basename = p.basename(filePath);
    final names = await _keyFileNamesOrEmpty();
    return _keyFileLabel(basename, names);
  }

  static String _keyFileLabel(String basename, Map<String, String> names) =>
      names[basename] ??
      (isOpaqueFileName(basename) ? 'Unnamed key file' : basename);

  static Future<Map<String, String>> _keyFileNamesOrEmpty() async {
    try {
      return await keyFileNames?.getAll() ?? const {};
    } catch (_) {
      // An unreadable name store must not hide the files themselves.
      return const {};
    }
  }

  static bool get isMobilePlatform {
    if (kIsWeb) {
      return false;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => false,
    };
  }

  static Future<String> saveBytesToAppDirectory({
    required Uint8List bytes,
    required String fileName,
    required String subdirectory,
    bool overwriteIfExists = false,
  }) async {
    final directory = await _ensureSubdirectory(subdirectory);
    // spec 014 FR-3: databases and key files rest under an opaque random
    // identifier with no extension. The caller's [fileName] is ignored for
    // those subdirectories — the human-readable name lives only in the
    // encrypted registry. The database name and its key file's name are
    // independent draws, so the association between them is not
    // reconstructable from a directory listing.
    final normalized = _opaqueSubdirectories.contains(subdirectory)
        ? allocateOpaqueFileName()
        : _normalizeFileName(fileName);
    final filePath = overwriteIfExists
        ? p.join(directory.path, normalized)
        : await _buildUniquePath(directory.path, normalized);
    // spec 008 T109 follow-up (LOW): never write the final name in place.
    // Exclusive-created same-directory temp + flush(fsync) + read-back
    // verify + atomic rename, so a crash leaves either no file or the
    // complete file at [filePath].
    //
    // Inlined rather than reusing `SafeVaultFileWriter`: core/ must not
    // depend on features/. Delta of guarantees vs that writer, deliberate:
    //   * NO symlink write-through. The writer resolves a leaf symlink so a
    //     `~/vault.kdbx -> ~/Dropbox/vault.kdbx` setup keeps working; here
    //     the opposite is wanted. This directory is app-private and an entry
    //     in it may have been planted (#45/#46), so the rename REPLACES a
    //     symlink entry instead of following it outside app storage.
    //     Since the T109 HIGH-4 follow-up the two layers agree rather than
    //     contradict: that writer gates its resolution on the app-private
    //     perimeter — which on the mobile targets IS this directory — so it
    //     also declines to follow a link here, and it refuses a `..` path
    //     outright just as _containsTraversal does below. It is
    //     unconditional here because this method only ever writes paths it
    //     built itself, inside this directory.
    //   * NO permission preservation. Every file here is created by this
    //     method inside an app-private directory; there is no user-chosen
    //     `chmod 600` to carry over, and `overwriteIfExists` has no caller.
    //   * NO collision retry. `_buildUniquePath` already picked a free name,
    //     and the temp carries a microsecond suffix; exclusive-create turns
    //     a residual clash into a loud failure rather than an overwrite.
    //   * NO sandbox fallback. This path is always inside the app container,
    //     which is writable by construction on every mobile target.
    final tempFile = File(
      '$filePath.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    await tempFile.create(exclusive: true);
    try {
      await tempFile.writeAsBytes(bytes, flush: true);
      // Full byte compare, not just a length check: a short write and a
      // corrupt write are both "not what we asked for", and the comment
      // above promises a read-back verify.
      if (!listEquals(await tempFile.readAsBytes(), bytes)) {
        throw FileSystemException(
          'read-back verify failed: short or corrupt write',
          tempFile.path,
        );
      }
      await tempFile.rename(filePath);
      if (subdirectory == _keysSubdirectory && isOpaqueFileName(normalized)) {
        // Best-effort: a name that fails to record leaves a working key file
        // labelled "Unnamed key file", never a lost key file.
        try {
          await keyFileNames?.set(normalized, _normalizeFileName(fileName));
        } catch (_) {}
      }
      await _enforceOwnerOnly(filePath, subdirectory);
    } catch (_) {
      try {
        await tempFile.delete();
      } catch (_) {
        // Best effort: cleanup must not mask the write failure.
      }
      rethrow;
    }
    return filePath;
  }

  static Future<String> copyFileToAppDirectory({
    required String sourcePath,
    required String fallbackFileName,
    required String subdirectory,
    bool overwriteIfExists = false,
  }) async {
    final source = File(sourcePath);
    final bytes = await source.readAsBytes();
    return saveBytesToAppDirectory(
      bytes: bytes,
      fileName: p.basename(sourcePath).isEmpty
          ? fallbackFileName
          : p.basename(sourcePath),
      subdirectory: subdirectory,
      overwriteIfExists: overwriteIfExists,
    );
  }

  static Future<String> getPathInAppDirectory({
    required String fileName,
    required String subdirectory,
  }) async {
    final directory = await _ensureSubdirectory(subdirectory);
    final normalized = _normalizeFileName(fileName);
    return p.join(directory.path, normalized);
  }

  static Future<List<AppStorageFileEntry>> listFilesInAppDirectory({
    required String subdirectory,
  }) async {
    final directory = await _ensureSubdirectory(subdirectory);
    final entries = await directory.list(followLinks: false).toList();
    final files = <AppStorageFileEntry>[];
    final names = subdirectory == _keysSubdirectory
        ? await _keyFileNamesOrEmpty()
        : const <String, String>{};

    for (final entry in entries) {
      if (entry is! File) {
        continue;
      }
      final stat = await entry.stat();
      final basename = p.basename(entry.path);
      files.add(
        AppStorageFileEntry(
          name: subdirectory == _keysSubdirectory
              ? _keyFileLabel(basename, names)
              : basename,
          path: entry.path,
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }

    files.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return files;
  }

  /// Whether [filePath] is a file this app manages inside [subdirectory].
  ///
  /// Precondition: [filePath] must be pre-normalized and contain no `..`
  /// segment (see the class doc). A path with traversal returns `false`
  /// instead of throwing — this is a predicate, and `false` is the safe answer
  /// at both current call sites. `VaultSessionCoordinator`
  /// (`_ensureManagedKeyFilePath`) and `DatabaseImportService`
  /// (`ensureManagedKeyFilePath`) both ask the same question — "is this key
  /// file already managed, or must I copy it in?" — so a spurious `false`
  /// re-copies a file that was already inside. Redundant, never destructive.
  ///
  /// Contrast [deleteFileFromAppDirectory], which **throws** on the same
  /// input: there the unsafe direction is the one that acts, so an unmet
  /// precondition has to be loud instead of falling through to a default.
  static Future<bool> isPathInAppDirectory({
    required String filePath,
    required String subdirectory,
  }) async {
    if (_containsTraversal(filePath)) {
      return false;
    }

    final directory = await _ensureSubdirectory(subdirectory);
    // Resolved comparison: the file picker hands back `/private/var/...` for
    // files this directory spells as `/var/...`. Same two-condition rule as
    // deleteFileFromAppDirectory — a file counts as app-managed only if both
    // the entry and what it points at live inside.
    final normalizedDirectoryPath = PortablePath.resolveForComparison(
      directory.path,
    );

    bool isInside(String candidate) =>
        p.isWithin(normalizedDirectoryPath, candidate) ||
        normalizedDirectoryPath == candidate;

    return isInside(PortablePath.resolveParentForComparison(filePath)) &&
        isInside(PortablePath.resolveForComparison(filePath));
  }

  /// Whether [path] contains a `..` segment.
  ///
  /// Containment checks compare *textually normalized* paths, which collapse
  /// `<dir>/link/../x` to `<dir>/x` and report "inside". The kernel instead
  /// follows `link` first, so `..` lands wherever the link pointed — outside.
  /// Rejecting traversal outright closes that gap without trying to
  /// out-guess the resolver.
  static bool _containsTraversal(String path) => p.split(path).contains('..');

  /// Deletes [filePath], which must live inside app storage [subdirectory].
  ///
  /// Precondition: [filePath] must be pre-normalized and contain no `..`
  /// segment (see the class doc). Unlike [isPathInAppDirectory], which merely
  /// answers `false`, this **throws** on traversal or on any path that fails
  /// the containment guard: deletion is destructive, so an unmet precondition
  /// has to be loud rather than silently skipped.
  static Future<void> deleteFileFromAppDirectory({
    required String filePath,
    required String subdirectory,
  }) async {
    final directory = await _ensureSubdirectory(subdirectory);
    final target = File(filePath);
    final normalizedDirectoryPath = PortablePath.resolveForComparison(
      directory.path,
    );

    // Two independent conditions, both required.
    //
    // 1. Where the entry itself lives, with the leaf NOT followed. `delete()`
    //    unlinks the entry at `filePath`, so a symlink sitting outside app
    //    storage must not pass the guard merely by pointing inside.
    // 2. Where the entry ultimately points. A symlink inside app storage must
    //    not be usable to reach a file outside it.
    // 3. No `..` traversal: see _containsTraversal. A textually-inside path
    //    can still land outside once the kernel follows an intermediate
    //    symlink, so traversal is refused before the containment check.
    //
    // Hardlinks are deliberately out of scope. `realpath` resolves symlinks,
    // but it cannot tell that an inode has a second name outside app storage,
    // so a hardlink created inside the app directory onto an external file
    // does pass this guard. That is safe: `File.delete` is `unlink`, so it
    // only drops the in-app name. The external file keeps its own link and
    // survives — QA confirmed `victim.exists() == true` afterwards. Nothing to
    // defend here unless a caller ever gains a truncate/overwrite path, which
    // would follow the link and would need its own guard.
    final entryPath = PortablePath.resolveParentForComparison(target.path);
    final resolvedTargetPath = PortablePath.resolveForComparison(target.path);

    bool isInside(String candidate) =>
        p.isWithin(normalizedDirectoryPath, candidate) ||
        normalizedDirectoryPath == candidate;

    if (_containsTraversal(filePath) ||
        !isInside(entryPath) ||
        !isInside(resolvedTargetPath)) {
      throw Exception('Cannot delete file outside app storage directory.');
    }

    if (await target.exists()) {
      await target.delete();
    }
    if (subdirectory == _keysSubdirectory) {
      try {
        await keyFileNames?.remove(p.basename(filePath));
      } catch (_) {}
    }
  }

  /// Managed subdirectories whose at-rest file names are opaque
  /// (spec 014 FR-3).
  static const _opaqueSubdirectories = {'databases', 'keys'};

  /// A fresh 128-bit random identifier, lowercase hex, no extension.
  ///
  /// Not derived from the database identifier, the display name, or any
  /// value stored in the metadata files (spec 014 FR-3 / AC-1).
  static String allocateOpaqueFileName() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Whether [fileName] has the at-rest shape [allocateOpaqueFileName]
  /// produces: 32 lowercase hex characters and no extension.
  ///
  /// Pure by design — the callers that need it (a rename, a name shown in
  /// the UI) must not have to reach the filesystem to learn that the name on
  /// disk carries no meaning.
  static bool isOpaqueFileName(String fileName) =>
      _opaqueFileNamePattern.hasMatch(fileName);

  static final _opaqueFileNamePattern = RegExp(r'^[0-9a-f]{32}$');

  /// spec 014 FR-7 (T012): databases and key files in managed storage are
  /// owner-only on desktop POSIX platforms. Windows has no `chmod` in
  /// `dart:io` (its owner-only outcome is an ACL property of the per-user
  /// app-data directory); iOS/Android containers are already app-private,
  /// and the iOS sandbox forbids spawning a process at all.
  static Future<void> _enforceOwnerOnly(
    String filePath,
    String subdirectory,
  ) async {
    if (!_opaqueSubdirectories.contains(subdirectory)) {
      return;
    }
    if (!Platform.isMacOS && !Platform.isLinux) {
      return;
    }
    final result = await Process.run('chmod', ['600', filePath]);
    if (result.exitCode != 0) {
      throw FileSystemException('chmod 600 failed: ${result.stderr}', filePath);
    }
  }

  static Future<Directory> _ensureSubdirectory(String subdirectory) async {
    final root = await ManagedStorageRoot.resolveDirectory();
    final dir = Directory(p.join(root.path, subdirectory));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _normalizeFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty) {
      return 'file';
    }
    return trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  static Future<String> _buildUniquePath(
    String dirPath,
    String fileName,
  ) async {
    final extension = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);

    var candidate = p.join(dirPath, fileName);
    var index = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(dirPath, '$base-$index$extension');
      index++;
    }
    return candidate;
  }
}
