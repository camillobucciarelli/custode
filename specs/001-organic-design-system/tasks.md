# 001 — Tasks

Tasks are ordered. Complete command/check before starting the next task; no
parallel flags because theme and `pubspec.yaml` changes overlap.

## Phase 1 · Deterministic inputs

- [x] **T1** Snapshot direct Material-icon occurrences outside 001-touched files
      into `test/fixtures/001_direct_material_icons_baseline.txt` using the plan
      command, excluding all of `lib/core/widgets/**`; also record `AppIcons` and
      `rg -n 'AppColors\.|AppBackgrounds\.gradient' lib --glob '*.dart'` baselines.
      Pin one Lucide upstream commit, copy its licence, list only required glyphs
      from `specs/_design/ICONS.md` §2, and record SHA-256 values in
      `assets/icons/lucide/UPSTREAM.md`. Do not add a dependency before this
      delivery record exists.
- [x] **T2** Add Caprasimo Regular and Figtree 400/600/700 static TTF files plus
      OFL licence; declare families/assets in `pubspec.yaml` without touching
      `version:`. Add a font-loading test with runtime fetching disabled. Run
      `flutter pub get`, `flutter analyze` and that test.

## Phase 2 · Tokens and theme

- [x] **T3** Add Organic ramps to `app_colors.dart`, `CustodeColors`,
      `AppSpacing`, `AppRadii`, `AppElevation`, `AppMotion` and
      `AppTextStyles`. Keep every existing `AppColors` public constant and
      `AppBackgrounds.gradient` signature mapped to closest Organic values;
      mark them compatibility-only. Implement neutral-700 as `#665f53`, map
      secondary/tertiary text to neutral-700 light and neutral-100 @62% dark, and
      document the handoff deviation in code. Add parameterized ≥4.5:1 tests for
      every FR-2 text/background pairing, plus reduced-motion tests. Run
      `flutter analyze` and theme tests.
- [x] **T4** Rebuild `app_theme.dart` with bundled Caprasimo/Figtree, register
      `CustodeColors`, and style Material buttons, inputs, sheets, snackbars,
      focus/hover/pressed/disabled states. Add the sole accessibility primitive
      `lib/core/widgets/app_focus_ring.dart`: caller-owned shared `FocusNode`,
      configurable radius, unclipped 2 px external gap plus 2 px ring, no added
      semantics or hit-test interception. Use it for real focused button, input,
      icon, switch and checkbox gallery call sites; test exact paint geometry,
      ownership, hit testing, semantics and real switch/checkbox focus in
      `test/core/widgets/app_focus_ring_test.dart`. Keep existing per-platform
      `PageTransitionsTheme`. Add `organic_theme_gallery_test.dart` with fixed
      390×844 and 1024×768 surfaces, fixed DPR 1.0, text scale 1.0, locale
      `en_US`, animations disabled and runtime font fetching disabled. Generate
      and review the four exact goldens. Run `flutter analyze`, theme tests and
      gallery test.

## Phase 3 · Lucide primitive

- [x] **T5** Add `flutter_svg`, curated vendored SVGs, `AppGlyph` and `KvIcon`.
      Enforce 24-unit viewBox, no fill, round caps/joins and 2.75 stroke in asset
      validation. Add the icon state row to the existing gallery and tests.
      Leave `AppIcons` members and all screen call sites untouched. Regenerate
      and review only the four named gallery goldens; run analyze and targeted
      tests.

## Phase 4 · Verify

- [x] **T6** Run scoped touched-file icon and theme-literal sweeps from spec
      AC-5/6 across `lib/core/theme` and all of `lib/core/widgets`; both must be
      empty. Regenerate untouched-file icon output with
      `--glob '!lib/core/widgets/**'` and diff it against T1 baseline; no new
      occurrence is allowed. Record remaining `AppIcons` compatibility call
      sites for later screen specs; do not require global `Icons.` zero in 001.
- [x] **T7** Run `flutter analyze`, `flutter test test/core/theme/app_theme_test.dart`
      and `flutter test test/goldens/organic_theme_gallery_test.dart`. Run full
      `flutter test` once before commit.
