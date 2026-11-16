// spec-003 C-7 / T2: executable architecture gate for
// `database_session_coordinator.dart`.
//
// This is not a grep. It parses the coordinator file with the real Dart
// analyzer and inspects every `ImportDirective` URI (resolving relative and
// `package:password_manager/...` forms to project-relative paths) so the
// gate cannot be fooled by import styles a text search would miss.
//
// Rejects:
//  - any import whose resolved path contains a `data` path segment,
//  - `dart:io`,
//  - Flutter itself or a picker/crypto/KDBX/platform package,
//  - any import that does not resolve into
//    `lib/features/password_manager/domain/` or
//    `lib/features/password_manager/presentation/coordinators/`
//    (internal imports), unless it is in `approvedCoreUris` (core imports),
//  - external packages outside the explicit allowlist,
//  - Dart SDK imports outside the explicit non-platform allowlist.
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Approved `package:password_manager/core/...` URIs. Empty by default per
/// spec-003 C-7 — any addition here requires explicit review.
const approvedCoreUris = <String>{};

/// External (pub.dev) packages the coordinator may import.
const approvedExternalPackages = <String>{'loggy', 'path'};

/// Dart SDK libraries the coordinator may import. Deliberately excludes any
/// platform-flag or I/O library (`dart:io`, `dart:ui`, `dart:html`, ...).
const approvedDartSdkUris = <String>{
  'dart:async',
  'dart:math',
  'dart:typed_data',
};

const disallowedExternalPackages = <String>{
  'file_picker',
  'flutter',
  'crypto',
  'kdbx',
  'flutter_secure_storage',
  'path_provider',
  'local_auth',
  'google_sign_in',
  'flutter_bloc',
  'flutter_svg',
  'google_fonts',
  'camera',
  'shared_preferences',
};

void main() {
  test('database_session_coordinator.dart imports only domain ports/use cases, '
      'presentation coordinator contracts and the approved core/package/SDK '
      'allowlists (C-7)', () async {
    final projectRoot = _findProjectRoot();
    final coordinatorPath = p.join(
      projectRoot,
      'lib',
      'features',
      'password_manager',
      'presentation',
      'coordinators',
      'database_session_coordinator.dart',
    );
    final file = File(coordinatorPath);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'Expected coordinator at $coordinatorPath',
    );

    final content = file.readAsStringSync();
    final parseResult = parseString(content: content, path: coordinatorPath);

    final rejected = <String>[];

    for (final directive in parseResult.unit.directives) {
      if (directive is! ImportDirective) {
        continue;
      }
      final rawUri = directive.uri.stringValue;
      if (rawUri == null) {
        rejected.add('<unresolvable import URI>');
        continue;
      }

      final resolved = _resolveImportUri(
        rawUri: rawUri,
        coordinatorPath: coordinatorPath,
        projectRoot: projectRoot,
      );

      final violation = _violationFor(resolved);
      if (violation != null) {
        rejected.add('$rawUri -> ${resolved.description} ($violation)');
      }
    }

    if (rejected.isNotEmpty) {
      fail(
        'database_session_coordinator.dart has disallowed imports:\n'
        '${rejected.map((line) => '  - $line').join('\n')}',
      );
    }
  });
}

class _ResolvedImport {
  const _ResolvedImport.dartSdk(this.value) : kind = _ImportKind.dartSdk;
  const _ResolvedImport.package(this.value) : kind = _ImportKind.package;
  const _ResolvedImport.internalPath(this.value)
    : kind = _ImportKind.internalPath;

  final _ImportKind kind;
  final String value;

  String get description => switch (kind) {
    _ImportKind.dartSdk => 'dart-sdk:$value',
    _ImportKind.package => 'package:$value',
    _ImportKind.internalPath => 'path:$value',
  };
}

enum _ImportKind { dartSdk, package, internalPath }

_ResolvedImport _resolveImportUri({
  required String rawUri,
  required String coordinatorPath,
  required String projectRoot,
}) {
  if (rawUri.startsWith('dart:')) {
    return _ResolvedImport.dartSdk(rawUri);
  }

  if (rawUri.startsWith('package:')) {
    final withoutScheme = rawUri.substring('package:'.length);
    final segments = withoutScheme.split('/');
    final packageName = segments.first;
    if (packageName != 'password_manager') {
      return _ResolvedImport.package(packageName);
    }
    // package:password_manager/x/y.dart -> lib/x/y.dart
    final libRelative = segments.skip(1).join('/');
    final absolute = p.normalize(p.join(projectRoot, 'lib', libRelative));
    return _ResolvedImport.internalPath(
      p.relative(absolute, from: projectRoot),
    );
  }

  // Relative import.
  final absolute = p.normalize(p.join(p.dirname(coordinatorPath), rawUri));
  return _ResolvedImport.internalPath(p.relative(absolute, from: projectRoot));
}

String? _violationFor(_ResolvedImport resolved) {
  switch (resolved.kind) {
    case _ImportKind.dartSdk:
      if (resolved.value == 'dart:io') {
        return 'dart:io is not allowed';
      }
      if (!approvedDartSdkUris.contains(resolved.value)) {
        return 'not in approvedDartSdkUris allowlist';
      }
      return null;
    case _ImportKind.package:
      if (disallowedExternalPackages.contains(resolved.value)) {
        return 'Flutter/picker/crypto/kdbx/platform package is not allowed';
      }
      if (!approvedExternalPackages.contains(resolved.value)) {
        return 'not in approvedExternalPackages allowlist';
      }
      return null;
    case _ImportKind.internalPath:
      final segments = p.split(resolved.value);
      if (segments.contains('data')) {
        return 'contains a "data" path segment';
      }
      if (resolved.value.endsWith('mobile_file_storage.dart')) {
        return 'platform utility (mobile_file_storage.dart) is not allowed';
      }
      final normalized = resolved.value.replaceAll('\\', '/');
      final isDomain = normalized.startsWith(
        'lib/features/password_manager/domain/',
      );
      final isCoordinatorContract = normalized.startsWith(
        'lib/features/password_manager/presentation/coordinators/',
      );
      final isApprovedCore =
          normalized.startsWith('lib/core/') &&
          approvedCoreUris.contains(normalized);
      if (isDomain || isCoordinatorContract || isApprovedCore) {
        return null;
      }
      return 'outside domain/, presentation/coordinators/ and approvedCoreUris';
  }
}

String _findProjectRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate project root (pubspec.yaml).');
    }
    dir = parent;
  }
}
