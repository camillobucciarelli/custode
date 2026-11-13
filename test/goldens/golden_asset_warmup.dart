// Deterministic asset decoding for golden tests.
//
// `Image.asset` resolves its bytes through `instantiateImageCodec`, which
// completes on the *real* event loop. `tester.pumpAndSettle()` only advances
// the fake-async zone, so it can — and does — return before the decode has
// finished. The result is that the first test in a file to mount a given
// asset paints an empty box where the image belongs, while every later test
// paints it, because `PaintingBinding.imageCache` is per-isolate and survives
// between `testWidgets` cases.
//
// `cacheWidth` / `cacheHeight` wrap an `AssetImage` in a `ResizeImage`, whose
// cache key includes the decoded dimensions. Warm every size used by goldens;
// warming only the raw 1024 px asset does not populate those resized entries.
//
// Warming the cache once from `setUpAll` — which runs in real async, outside
// the fake-async zone — makes the decode complete before any test body runs,
// so every case paints the image regardless of its position in the file.
import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// Image variants that goldens render and therefore must be decoded up front.
final _goldenImageProviders = <ImageProvider<Object>>[
  for (final size in [40, 76, 88])
    ResizeImage(
      AssetImage(
        'assets/logo/app_icon_family/custode-source-1024.png',
        bundle: rootBundle,
      ),
      width: size,
      height: size,
    ),
];

/// Decodes every golden-visible asset into the image cache and keeps it alive
/// for the rest of the test file.
///
/// Call from `setUpAll` in any golden test file that renders one of these
/// assets. Safe to call more than once.
Future<void> warmUpGoldenAssets() async {
  for (final provider in _goldenImageProviders) {
    final completer = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);

    // The listener is intentionally never removed: holding it keeps the
    // decoded frame in the cache's live set for the whole file, so no later
    // test can evict it and reintroduce the cold-cache frame.
    stream.addListener(
      ImageStreamListener(
        (_, _) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
        onError: (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      ),
    );

    await completer.future;
  }
}
