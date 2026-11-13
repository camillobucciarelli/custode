# 001 — Organic design system

**Status**: Hardened draft · **Kind**: Restyle foundation · **Depends on**: —
**Design source**: `specs/_design/HANDOFF.md` (§Design tokens),
`specs/_design/PIXEL_SPEC.md` (§2 Core components, §3 Type scale, §5 Motion),
`specs/_design/ICONS.md` (§2 UI icon set), `specs/_design/tokens.css`,
`14 Dark mode.dc.html`.

## Why

The app uses an indigo/slate Material theme, Poppins and Material icons. This
spec adds the Organic theme foundation without requiring an atomic rewrite of
every screen. Each phase compiles. Screen composition and reusable screen
components land only when later specs have real call sites.

## Scope

**In**: colour/semantic tokens, bundled deterministic fonts, typography,
spacing/radius/elevation/motion tokens, global Material theme, deterministic
golden harness, Lucide delivery primitive and icon manifest.
`AppFocusRing`, the shared accessibility primitive required to implement FR-6's
exact external focus geometry, is also in scope.

**Out**: screen composition, speculative `Kv*` component library, app mark and
launcher icons (007), extension CSS (006), removal of compatibility aliases
still used by untouched screens.

## Delivery decisions

1. **Fonts**: bundle Caprasimo Regular and Figtree 400/600/700 under
   `assets/fonts/`; runtime and tests use those exact files. No network font
   fetch participates in rendering or goldens.
2. **Icons**: use `flutter_svg` with a curated, vendored Lucide SVG set. SVGs keep
   `viewBox="0 0 24 24"`, `fill="none"`, round caps/joins and stroke width 2.75.
   Record upstream Lucide commit, license and file SHA-256 values in
   `assets/icons/lucide/UPSTREAM.md` before adding the dependency.
3. Existing `AppIcons` `IconData` members remain as compatibility aliases in
   001. New/migrated surfaces use `KvIcon(AppGlyph.*)`. A later screen spec
   replaces a call site atomically; `AppIcons` is removed only when its tracked
   call-site count reaches zero.
4. 001 creates no list row, input, button, card, sheet, navigation or form widget.
   `AppFocusRing` is the sole accessibility-primitive exception because one
   implementation is shared by five real FR-6 gallery call sites. No speculative
   component kit is authorized. Other shared widgets are extracted on their
   second real use per constitution VIII.

## Functional requirements

### FR-1 · Colour ramps and compatibility

`AppColors` exposes these implementation values; no interpolation or extra hues.
Accessibility-approved deviations from the handoff are listed below the table:

| Ramp | 100 | 200 | 300 | 400 | 500 | 600 | 700 | 800 | 900 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| neutral | `#f9f4ed` | `#eee7db` | `#dcd3c4` | `#c0b6a5` | `#a19786` | `#82796a` | `#665f53` | `#474238` | `#2e2b25` |
| accent | `#fff2eb` | `#ffe1d0` | `#ffc6a5` | `#f6a06b` | `#d67f48` | `#b2622d` | `#8c491a` | `#643312` | `#402310` |
| accent2 | `#f0fae1` | `#e1eecc` | `#ccdbb2` | `#aebf92` | `#8fa073` | `#728157` | `#56633f` | `#3d472b` | `#272e1b` |

Also `text = #201e1d` and `divider = #201e1d @ 16%`.

**Deliberate handoff deviation**: `specs/_design/tokens.css` records neutral-700
as `#645c50`; implementation uses tester-approved `#665f53`. More importantly,
secondary/tertiary text moves from handoff neutral-600 / dark 58% or 50% to the
accessible mappings in FR-2. Constitution V wins over pixel-token fidelity.

Current public constants (`primary*`, `secondary*`, `tertiary*`, `darkSeed`,
`background*`, `surface*`, `textPrimary*`, `textSecondary*`, `divider*`,
`error`, `success`, `warning`) and `AppBackgrounds.gradient` stay compilable.
They map to the closest Organic role and carry a migration comment. New code
must not reference them. They are deleted only after later specs migrate all
call sites; 001 never fixes unrelated screens merely to satisfy a sweep.

### FR-2 · Semantic colours

`CustodeColors extends ThemeExtension<CustodeColors>` exposes roles, not ramp
indices:

| Role | Light | Dark |
| --- | --- | --- |
| `ground` | neutral-100 | neutral-900 |
| `surface` | neutral-200 | neutral-800 |
| `surfaceNested` | neutral-100 | neutral-900 |
| `canvas` | neutral-300 | neutral-900 |
| `textPrimary` | `#201e1d` | neutral-100 |
| `textSecondary` | neutral-700 (`#665f53`) | neutral-100 @ 62% |
| `textTertiary` | neutral-700 (`#665f53`) | neutral-100 @ 62% |
| `divider` | `#201e1d` @ 16% | neutral-100 @ 22% |
| `actionFill` | accent-300 | accent-300 |
| `actionText` | accent-900 | accent-900 |
| `actionEmphasis` | accent-400 | accent-400 |
| `attentionTint` | accent-100 | accent-800 |
| `attentionText` | accent-900 | accent-200 |
| `linkText` | accent-800 | accent-300 |
| `positiveFill` | accent2-400 | accent2-400 |
| `positiveTint` | accent2-100 | accent2-800 |
| `positiveText` | accent2-900 | accent2-200 |
| `selectionBorder` | accent-400 | accent-300 |
| `iconNeutral` | neutral-700 | neutral-100 @ 72% |

Destructive/attention UI is accent-tinted, never red. Raw ramp values remain
inside theme code; migrated widgets consume semantic roles.

Declared text/background pairings are exhaustive and all require ≥4.5:1:

| Text role | Allowed background roles |
| --- | --- |
| `textPrimary` | `ground`, `surface`, `surfaceNested` |
| `textSecondary` | `ground`, `surface`, `surfaceNested` |
| `textTertiary` | `ground`, `surface`, `surfaceNested` |
| `actionText` | `actionFill`, `actionEmphasis` |
| `attentionText` | `attentionTint` |
| `linkText` | `ground`, `surface`, `surfaceNested` |
| `positiveText` | `positiveTint` |

No text is placed directly on `canvas` or `positiveFill`; `positiveFill` is for
non-text controls/indicators and positive copy uses `positiveTint`. A nested
surface is required on canvas. Any later spec declaring another pairing must add
it to the central parameterized contrast test before use. Visual hierarchy for
secondary versus tertiary text comes from type size/weight, not sub-WCAG opacity.

### FR-3 · Typography and deterministic rendering

- Heading: Caprasimo 400, line height 1.12–1.15, letter spacing −0.015em.
- Body: Figtree 400/600/700.
- Secrets/checksums/codes: platform monospace stack.
- Poppins remains available only to untouched compatibility call sites; migrated
  surfaces use named Organic styles.

Named scale: `heroHeadline` 38/1.10; `screenTitle` 28 (30 variant)/1.14;
`sheetTitle` 22 (24)/1.15; `panelTitle` 18 (20)/1.20; `numeric` 18–22/1.0;
`rowTitle` 15/600/1.25; `fieldValue` 15 (14.5 dense)/1.40; `body` 13.5/1.45;
`secondary` 12.5/1.40; `meta` 11.5 (12)/1.50; `labelUpper` 11/1.20/+0.09em;
`labelMicro` 10/1.20/+0.08em (popup only); `secret` 13.5–16/1.40;
`otpCode` 21/1.20/+0.16em. No rendered text below 11 px except the explicitly
approved 10 px popup label and 10.5 px navigation label in 002.

Golden setup calls `GoogleFonts.config.allowRuntimeFetching = false` before
pumping and fails if a declared bundled font asset is unavailable. Tests never
substitute Ahem or a host font for Caprasimo/Figtree.

### FR-4 · Metric and motion tokens

- `AppSpacing`: `s1 4.4`, `s2 8.8`, `s3 13.2`, `s4 17.6`, `s6 26.4`, `s8 35.2`.
- `AppRadii`: `row 22`, `rowCompact 20`, `rowNested 16`, `card 24`,
  `cardLarge 28`, `sheet 32`, `pill 999`, `iconSquare 14`, `avatar 999`,
  `frame 46`, `tabletFrame 22`.
- `AppElevation`: `sm 0 1px 2px #2e2b25 @14%`,
  `md 0 3px 10px #2e2b25 @16%`, `lg 0 12px 32px #2e2b25 @22%`; dark `lg`
  uses black @50%.
- `AppMotion`: row 190 ms, button 220 ms, sheet in/out 240/180 ms, unlock
  280 ms, copy visibility 1600 ms plus 200 ms in/out, spinner 900 ms linear;
  ease-out cubic in and ease-in cubic out.
- `AppMotion.duration(context, value)` returns zero under
  `MediaQuery.disableAnimationsOf(context)`.

### FR-5 · Icon contract

`AppGlyph` contains the mapping in `specs/_design/ICONS.md` §2 plus
`shieldCheck`, `duplicates`, `clock`, `rowsDiff`. `KvIcon` accepts only glyph,
size, colour and optional semantic label; it has no BLoC dependency.
`cloudDone` is a reviewed composite asset; `duplicates` is the two-circle custom
asset from the handoff. Sizes remain 17–19 inline, 23 navigation, 26–34 feature,
14–16 chip/meta. Hit-area sizing belongs to callers.

### FR-6 · Theme primitive states

The deterministic gallery renders these exact states using Material primitives
styled by `AppTheme`; it does not invent reusable application widgets:

| Primitive | States in gallery/test |
| --- | --- |
| Filled button | enabled, hovered, focused, pressed, disabled |
| Outlined button | enabled, focused, disabled |
| Text input | empty, populated, focused, error, disabled |
| Icon | neutral, hovered, focused, pressed, disabled |
| Switch/checkbox | off, on, focused, disabled |
| Colour/type samples | all semantic roles; every named text style |

Focus is a 2 px accent ring with 2 px offset. Hover moves one ramp step; pressed
moves one further step. Disabled state remains legible and never uses colour as
its only signal.

`lib/core/widgets/app_focus_ring.dart` implements that geometry around a child
with a caller-owned `FocusNode`: 2 px clear external gap followed by a 2 px
stroke, configurable border radius, unclipped paint, no added semantics and no
hit-test interception. The same node is passed to the ring and Material control;
the caller remains responsible for disposal. Button, input, icon, switch and
checkbox gallery call sites use this primitive. Geometry, ownership, hit testing,
semantics, and real focused switch/checkbox behaviour are covered by
`test/core/widgets/app_focus_ring_test.dart`.

## Exact golden inventory — 4 files

| File | Surface | Theme |
| --- | --- | --- |
| `organic_theme_gallery_390x844_light.png` | 390×844 | light |
| `organic_theme_gallery_390x844_dark.png` | 390×844 | dark |
| `organic_theme_gallery_1024x768_light.png` | 1024×768 | light |
| `organic_theme_gallery_1024x768_dark.png` | 1024×768 | dark |

Each image contains colour/type samples plus the enabled/focused/error/disabled
representative states. Hover and pressed are asserted in widget tests because
pointer-state capture in a composite golden is brittle.

## Acceptance criteria

1. Each ordered implementation task leaves `flutter analyze` clean.
2. Untouched screens compile through compatibility aliases; new theme/gallery
   code uses no compatibility alias.
3. Four named goldens above render with bundled fonts and no network access.
4. Widget tests assert every state in FR-6, semantic-role values in both themes,
   every text/background pair in FR-2 at ≥4.5:1, and reduced-motion zero
   durations. Tests explicitly pin light `textSecondary = #665f53` on
   neutral-200 and dark `textSecondary = neutral-100 @ 62%` on neutral-800.
   The semantic-role assertion uses independent expected light/dark tables for
   all 19 roles. Focus tests include geometric paint proof of the 2 px gap and
   2 px ring.
5. Direct Material icon sweep is empty only in files touched by 001 and does not
   false-match `AppIcons`:
   `rg -n '(^|[^[:alnum:]_])Icons\.' lib/core/theme lib/core/widgets --glob '*.dart' --glob '!lib/core/theme/app_icons.dart'`
   is empty. Outside those files, T1 records
   `test/fixtures/001_direct_material_icons_baseline.txt`; final verification
   excludes all of `lib/core/widgets/**` and requires no added occurrence, not
   global zero. Remaining compatibility use is reported for later migrations by
   `rg -n '\bAppIcons\.' lib --glob '*.dart' --glob '!lib/core/theme/app_icons.dart'`.
6. Theme literal sweep
   `rg -n '0x[0-9A-Fa-f]{8}' lib/core/theme --glob '*.dart' --glob '!app_colors.dart'`
   is empty.

## Open product assumptions

- Exact curated Lucide upstream commit is recorded during T1 because handoff does
  not pin one. Delivery mechanism, stroke geometry and no-runtime-fetch policy are
  already decided and must not be reopened during implementation.
