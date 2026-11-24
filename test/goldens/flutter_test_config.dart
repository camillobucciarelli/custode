import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wraps the per-file [LocalFileComparator] that `flutter test` installs for
/// every file under `test/goldens` with [HostTolerantGoldenComparator].
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final local = goldenFileComparator as LocalFileComparator;
  goldenFileComparator = HostTolerantGoldenComparator(
    local.basedir.resolve('golden_test.dart'),
  );
  await testMain();
}

/// Accepts glyph antialiasing drift between macOS versions, nothing else.
///
/// The fonts are bundled, but glyphs are still rasterized by the host's
/// CoreText, which draws edge pixels slightly differently across macOS
/// releases (measured macOS 15 runner vs macOS 27 desktop, both ways: up to
/// 0.45% of pixels, never more than 49/255 on any channel). The committed
/// images come from both hosts, so neither renders all of them exactly. A real
/// UI change (moved widget, changed word, different colour) paints solid
/// pixels that differ by 150+, so it still fails.
///
/// ponytail: fixed thresholds, a future macOS whose edge drift exceeds
/// [maxChannelDelta] needs the images regenerated or the ceiling raised.
class HostTolerantGoldenComparator extends LocalFileComparator {
  HostTolerantGoldenComparator(super.testFile);

  /// Largest per-channel difference treated as antialiasing.
  static const maxChannelDelta = 64;

  /// Largest share of differing pixels tolerated, as a fraction.
  static const maxDiffFraction = 0.01;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || await _isAntialiasingDrift(result)) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }

  Future<bool> _isAntialiasingDrift(ComparisonResult result) async {
    final master = result.diffs?['masterImage'];
    final test = result.diffs?['testImage'];
    if (master == null ||
        test == null ||
        result.diffPercent > maxDiffFraction) {
      return false;
    }
    final a = await master.toByteData(format: ui.ImageByteFormat.rawRgba);
    final b = await test.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (a == null || b == null || a.lengthInBytes != b.lengthInBytes) {
      return false;
    }
    for (var i = 0; i < a.lengthInBytes; i++) {
      if ((a.getUint8(i) - b.getUint8(i)).abs() > maxChannelDelta) {
        return false;
      }
    }
    return true;
  }
}
