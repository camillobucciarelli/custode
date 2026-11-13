# 001 — Plan

## Approach

Small compiling passes. Build foundation and its test harness before any screen
component. Do not migrate unrelated call sites in 001.

1. Baseline current aliases/icon use; record Lucide upstream/license/checksums.
2. Bundle fonts and register assets; prove deterministic loading.
3. Add ramps, semantic extension and metric/motion tokens while preserving old
   public constants and `AppBackgrounds.gradient`.
4. Rebuild `AppTheme`; add theme-state tests and four-gallery golden harness.
5. Add `flutter_svg`, curated glyph assets, `AppGlyph` and the first real
   `KvIcon` use in the gallery.

## Affected files

### New

| Path | Contents |
| --- | --- |
| `assets/fonts/Caprasimo-Regular.ttf` | deterministic heading font |
| `assets/fonts/Figtree-Regular.ttf` | deterministic body 400 |
| `assets/fonts/Figtree-SemiBold.ttf` | deterministic body 600 |
| `assets/fonts/Figtree-Bold.ttf` | deterministic body 700 |
| `assets/fonts/OFL.txt` | font licences |
| `assets/icons/lucide/UPSTREAM.md` | pinned commit, licence, source URLs and SHA-256 manifest |
| `assets/icons/lucide/*.svg` | only mapped glyphs from ICONS §2 plus custom composites |
| `lib/core/theme/custode_colors.dart` | semantic `ThemeExtension` |
| `lib/core/theme/app_spacing.dart` | spacing values |
| `lib/core/theme/app_radii.dart` | radius values |
| `lib/core/theme/app_elevation.dart` | light/dark shadows |
| `lib/core/theme/app_motion.dart` | durations, curves, reduced-motion helper |
| `lib/core/theme/app_text_styles.dart` | bundled-font named scale |
| `lib/core/theme/app_glyph.dart` | semantic glyph-to-asset mapping |
| `lib/core/widgets/kv_icon.dart` | SVG renderer used by gallery and migrated screens |
| `lib/core/widgets/app_focus_ring.dart` | FR-6 external focus ring with caller-owned shared `FocusNode` |
| `test/core/theme/app_theme_test.dart` | token, state, contrast, font and motion assertions |
| `test/core/widgets/app_focus_ring_test.dart` | focus geometry, ownership, hit testing, semantics and switch/checkbox focus assertions |
| `test/fixtures/001_direct_material_icons_baseline.txt` | untouched-file direct `Icons.` baseline; no-new-occurrence gate |
| `test/goldens/organic_theme_gallery_test.dart` | fixed-surface harness |
| `test/goldens/organic_theme_gallery_*.png` | exact four images from spec |

### Modified

| Path | Change |
| --- | --- |
| `pubspec.yaml` | declare font/icon assets and `flutter_svg`; never edit `version:` |
| `lib/core/theme/app_colors.dart` | add ramps; retain compatibility constants mapped to Organic values |
| `lib/core/theme/app_theme.dart` | bundled typography, semantic extension and Organic Material component themes |
| `lib/core/theme/app_backgrounds.dart` | keep `gradient()` signature, return Organic ground-compatible fill until callers migrate |
| `lib/core/theme/app_icons.dart` | compatibility documentation only; members/types stay unchanged |

No application screen file changes. No `lib/core/widgets/` kit beyond `KvIcon`
and FR-6's `AppFocusRing`; both have real gallery uses in this spec. The focus
primitive does not authorize speculative controls or wrappers.

## Sequencing and compile gates

```text
T1 baseline/asset manifest
 -> T2 bundled fonts + pubspec -> analyze/font test
 -> T3 tokens + compatibility aliases -> analyze/theme tests
 -> T4 AppTheme + AppFocusRing + golden harness -> analyze/widget tests
 -> T5 flutter_svg + glyphs + KvIcon -> analyze/widget tests/goldens
 -> T6 scoped sweeps
```

No tasks edit the same file concurrently.

## Risks

| Risk | Mitigation |
| --- | --- |
| Global theme change makes old screens imperfect | Keep compatibility API and behaviour; migrate composition in later screen specs |
| Network/host font changes goldens | Bundle exact static fonts; disable Google Fonts runtime fetching in tests |
| SVG supply-chain drift | Vendor curated files, pin commit/licence and verify SHA-256 manifest |
| `AppIcons` mistaken for direct `Icons` usage | Use boundary-aware regex and explicit path exclusion from spec AC-5 |
| Global zero-icon sweep contradicts untouched screens | Require zero only in 001-touched files and diff untouched files against T1 baseline |
| Handoff secondary opacity fails WCAG | Use neutral-700 `#665f53` light and neutral-100 @62% dark; parameterize every declared pairing |
| Premature component API freezes wrong geometry | Build no component library; allow only KvIcon and FR-6's exact AppFocusRing primitive |

## Verification

T1 baseline capture, once before edits:

```bash
rg -n '(^|[^[:alnum:]_])Icons\.' lib --glob '*.dart' --glob '!lib/core/theme/**' --glob '!lib/core/widgets/**' > test/fixtures/001_direct_material_icons_baseline.txt || true
```

Final checks:

```bash
flutter analyze
flutter test test/core/theme/app_theme_test.dart
flutter test test/core/widgets/app_focus_ring_test.dart
flutter test test/goldens/organic_theme_gallery_test.dart
flutter test --update-goldens test/goldens/organic_theme_gallery_test.dart # reviewed regeneration only
rg -n '(^|[^[:alnum:]_])Icons\.' lib/core/theme lib/core/widgets --glob '*.dart' --glob '!lib/core/theme/app_icons.dart'
tmp="$(mktemp)"; rg -n '(^|[^[:alnum:]_])Icons\.' lib --glob '*.dart' --glob '!lib/core/theme/**' --glob '!lib/core/widgets/**' > "$tmp" || true; diff -u test/fixtures/001_direct_material_icons_baseline.txt "$tmp"; rm "$tmp"
rg -n '\bAppIcons\.' lib --glob '*.dart' --glob '!lib/core/theme/app_icons.dart'
rg -n '0x[0-9A-Fa-f]{8}' lib/core/theme --glob '*.dart' --glob '!app_colors.dart'
```

Full `flutter test` remains the pre-commit gate, not a per-task gate.
