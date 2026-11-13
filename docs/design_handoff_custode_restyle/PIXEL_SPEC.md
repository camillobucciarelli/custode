# Pixel spec — measurements, per surface

Every number below is taken from the design files. Units are logical pixels at
1× (Flutter dp). Where a value is a token, the token name is given so it stays
consistent if the scale is retuned.

---

## 1. Frames and page structure

| Surface | Size | Notes |
| --- | --- | --- |
| Phone | 390 × 844 | iPhone 14/15 logical size; corner radius 46 |
| Tablet / desktop | 1024 × 768 | corner radius 22; also the desktop baseline |
| Extension popup | 400 × auto | Chrome popup max width 800, we use 400 |
| In-page overlay | 320 wide | anchored under the focused field |

### Mobile screen padding

| Zone | Value |
| --- | --- |
| Status bar height | 52 (content baseline 6 above the bottom edge) |
| Screen side padding | 20 (18 on list-dense screens, 22 on hero/marketing screens) |
| Header top padding | 6–8 below the status bar |
| Between header and first content block | 16–18 |
| Between groups | 16 |
| Between rows in a group | 8–9 |
| Bottom padding above the tab bar | 16 |
| Bottom padding on screens without a tab bar | 30–34 |

### Bottom tab bar

Height **82** (10 top padding, 22 bottom safe area), background `neutral-200`
(dark `neutral-800`), 4 equal items, icon **23**, gap 3, label **10.5** px,
active colour `accent-800` (dark `accent-300`), inactive `neutral-600` (dark
`#f9f4ed` @ 52 %).

### Tablet columns

| Column | Width |
| --- | --- |
| Icon rail | 72 |
| Folder column | 236 |
| List column | 330 (400 in the two-pane conflict view) |
| Detail pane | remaining, min 300; padding 26–30 |
| Generator column | 290, divider on its left |

The rail and list are single values. The `76` and `352` that appear in one
artboard each are drift, corrected here rather than promoted to variants
(spec 018, DQ-3). Derived thresholds: detail pane from 704, folder column from
941, generator column from 995, folders and generator together only from 1232 —
so at the 1024 baseline an open generator collapses the folder column, never
the records list (DQ-2).

Rail: mark 38 at top, then 36 px icon buttons with 14 gap, settings pinned to the
bottom. Columns separated by a 1 px `--color-divider` line, never a shadow.

---

## 2. Core components

### List row (entry, database, setting, attachment)

- Radius **22** (20 for compact rows inside cards, 16 for nested rows).
- Padding **13 / 16** (compact 10–11 / 12–14).
- Background `neutral-200` on `neutral-100` ground; nested rows invert to
  `neutral-100` inside a `neutral-200` card. Dark: `neutral-800` on
  `neutral-900`, nested `neutral-900`.
- Min height 62 for entry rows (matches the existing
  `_VaultUiTokens.recordItemHeight`), 54 for compact.
- Internal gap **12**.
- Leading: letter avatar 38 circle, or 40 rounded square radius 14 (32/12 in
  compact lists).
- Title 15 / 600 / line-height 1.25. Subtitle 12.5 / 400, colour `neutral-600`.
- Trailing: 8 px health dot, then 36 px icon buttons with 6–8 gap.
- Selected row: background `accent-200`, subtitle colour `accent-900`, avatar
  becomes `accent-300` on `accent-900` (dark: `accent-800` / `accent-200`).

### Field row (detail screen)

Radius 22, padding 13 / 16, label 11 uppercase 0.09em `neutral-600`, value 15
(14.5 in dense grids), gap between label and value 2–4. Copy button 36 circle,
`neutral-100` background inside a `neutral-200` row.

### Input

Min height **52**, padding 8 / 16, radius **22**, background `neutral-200`,
placeholder `neutral-500`. Focused: 2 px border `accent-400` (no colour change of
the fill). Error: 2 px border `accent-700`, message 12.5 `accent-800` with a 15 px
icon, 8 above. Multiline: min height 88, top padding 14.
Label above the field: 11 uppercase, margin-bottom 6–7.

### Buttons

| Kind | Height | Radius | Fill | Text |
| --- | --- | --- | --- | --- |
| Primary pill | 52 | 999 | `accent-300` | `accent-900`, Caprasimo 15 |
| Primary compact | 46 | 999 | `accent-300` | `accent-900`, Caprasimo 14 |
| Secondary pill | 52 | 999 | transparent + 1 px divider | text colour |
| Chip / inline action | 34–40 | 999 | `neutral-200` | 12.5–13 / 600 |
| Icon button | 36 × 36 | 999 | `neutral-100` or `neutral-200` | glyph 17–19 |
| Destructive | 52 | 999 | `accent-300` | `accent-900` (never red) |

Gap between stacked buttons 9–10; between side-by-side 10, with flex ratios
1 : 1.4 or 1 : 1.6 when one action dominates.

### Bottom sheet

Radius **32** top corners, padding 20 / 18 / 26, grabber 46 × 5 radius 999
`neutral-300`, centred. Backdrop `neutral-900` @ 42 % (30 % for confirmations,
22 % for the saving overlay). Content order: grabber → optional 52 px feature
circle → title (Caprasimo 22–23) → body 13.5 `neutral-600` → content → actions.
Gap 14 between blocks.

### Card / panel

Radius **24–28**, padding 14–20, background `neutral-200` (light) or
`neutral-800` (dark). Elevated panels only on the tablet detail pane and the
extension popup: `--shadow-md`.

### Progress and meters

- Step bars: 3–4 bars, height 4, radius 999, gap 5–6; done `accent-400`,
  pending `neutral-300`.
- Password strength: 4 notches, height 6, radius 999, gap 8, label 12.5 / 600
  at the end. Weak = 1 notch `accent-400`; Fair 2; Good 3; Strong 4 in
  `accent-2-400`.
- Reveal countdown: height 4 bar inside the password row.
- Slider (generator): track height 8 radius 999 `neutral-200`, filled part
  `accent-400`, thumb 24 circle `accent-400` with a 3 px `neutral-100` ring and
  `--shadow-sm`; min/max labels 11 `neutral-600`.
- Spinner: 34 circle, 3 px ring `neutral-300` with `accent-400` top arc.

### Switch / radio / checkbox

Switch 44 × 26, radius 999, knob 20 with 3 px inset; on `accent-2-400`, off
`neutral-300`. Radio 20 circle: selected `accent-400` with a 4 px inset ring of
the surface colour; unselected 1.5 px divider border. Checkbox 22, radius 8;
checked `accent-300` fill with `accent-900` tick, stroke-width 3.2.

### Tags / badges

Padding 3 / 9, radius 999, size 10–11 / 600. Variants: `accent-200` on
`accent-900` (attention), `accent-2-200` on `accent-2-900` (positive),
`neutral-200` on `neutral-800` (neutral), 1 px divider outline (meta).

### Snackbar / toast

Radius 22, padding 14 / 16, background `accent-2-300` for success with
`accent-2-900` text, `--shadow-md`, 20 px leading glyph, 13.5 / 600 text,
trailing underlined action 12.5. Side margin 16, above the tab bar.

---

## 3. Type scale in use

| Role | Font | Size / weight | Line height |
| --- | --- | --- | --- |
| Hero headline | Caprasimo | 38 | 1.1 |
| Screen title | Caprasimo | 28–30 | 1.14 |
| Section / sheet title | Caprasimo | 22–24 | 1.15 |
| Panel title | Caprasimo | 18–20 | 1.2 |
| Numeric emphasis (counts, score) | Caprasimo | 18–22 | 1 |
| Row title | Figtree 600 | 15 | 1.25 |
| Field value | Figtree 400 | 14.5–15 | 1.4 |
| Body | Figtree 400 | 13.5 | 1.45 |
| Secondary | Figtree 400 | 12.5 | 1.4 |
| Meta / caption | Figtree 400 | 11.5–12 | 1.5 |
| Uppercase label | Figtree 400 | 11, +0.09em, uppercase | 1.2 |
| Micro label (popup) | Figtree 400 | 10, +0.08em, uppercase | 1.2 |
| Secret / checksum | ui-monospace | 13.5–16 | 1.4 |
| One-time code | ui-monospace | 21, +0.16em | 1.2 |

Never below 11 px; tap targets never below 44.

---

## 4. Screen-by-screen anchors

Only the values that are not derivable from the components above.

### Welcome (01)
Mark 88 radius 26; headline 38 max 15ch; body 15 max 34ch; three pills stacked
with gap 10; block vertically centred, bottom padding 34.

### Database list (01)
Header row: mark 40, title Caprasimo 26 flexed, add button 40 circle
`accent-300`. `Recent` label 20 above the list. Rows radius 24, padding 14,
leading square 40 radius 14. "Add" section label 24 above, its rows are
borderless 12 / 6 padding with a trailing chevron 17.

### Create database (01)
Back button 40 circle, then the 3-bar progress flexed beside it with gap 14.
Step label 11 uppercase, title Caprasimo 28–30, body 13.5. Fields gap 16.
Footer: primary pill + caption 12 centred.

### Unlock (02)
Feature square 66 radius 24 (`accent-200` / `accent-900`); title Caprasimo 32;
subtitle 13.5; password field 56 tall; primary pill; two inline links 13
`accent-800` separated by a 1 × 14 divider. Biometric gate (dark): circle 104
with a 50 px glyph, centred text, two stacked pills.

### Entry detail (04)
Header: avatar 56 (font 22), title Caprasimo 28, subtitle 13.5, 14 gap; header
actions 36 circles. Rows gap 9. "More" chips 9 / 14 padding, 13 px.
Strength strip: radius 20, padding 12 / 16, 32 circle glyph, text 12.5.
Revealed password row: `accent-100` background, monospace 16 with word-break,
4 px countdown; TOTP row: 38 circle with the seconds in 11 / 700, code 21
monospace.

### Editor (05)
Header is text-only: Cancel 14 `neutral-700` — title Caprasimo 16 — Save 14
(`neutral-500` when disabled). Fields gap 14. Optional list: three rows radius 20,
padding 13 / 16, glyph 17, trailing chevron 17 — identical on tablet (radius 20,
padding 12 / 16, background `neutral-100` on the `neutral-200` pane).

### Generator (06)
Sheet gap 16. Result box radius 22 padding 16 `neutral-200`, monospace 16 with
`word-break: break-all`, 36 regenerate button. Length header: label left, value
Caprasimo 18 right. Checkbox rows gap 10, label 14.

### Sync (07)
Status hero: radius 26, padding 20, 52 circle, title Caprasimo 20, meta 12.5;
key/value list 12.5 with `space-between`. Activity rows compact (11 / 14).
Conflict sheet: two version cards radius 20 padding 14 / 16 with a 40 square,
checksum monospace 11.

### Health (08)
Score circle 64 with Caprasimo 22; category rows standard with a Caprasimo 18
count before the chevron.

### Duplicates (08)
Group card radius 24 padding 14; inner entry rows radius 16 padding 11 / 13;
"Some data will be copied" strip radius 14 padding 9 / 12, 12 px text;
merge action full-width 11 px padding, radius 999.

### Field diff (07 · new)
Two segmented pills at the top (flex 1 each, padding 9, radius 999).
Per field: card radius 24 padding 14, label row with a `differs` tag; two value
cards radius 18 padding 12 / 14 on `neutral-100`, the chosen one with a 2 px
`accent-400` border and a filled 20 px radio; "keep both" link 12 / 600.
Identical-fields summary strip radius 20 padding 13 / 16.
Tablet: two columns gap 12, each value card radius 20 padding 14; identical
fields at 60 % opacity.

### Settings (10)
Group label 11 uppercase, rows standard, section gap 16. Theme selector: three
equal pills, padding 9, radius 999, selected `accent-300` / `accent-900`.
"Close database" is a secondary pill with `accent-800` text.

### Browser setup (11)
Step cards radius 24 padding 16; done card `accent-2-100` with a 40 square check;
active card `neutral-200` with a numbered 40 square `accent-300`; pending card at
60 % opacity. Command block: radius 18 padding 12 / 14, background
`neutral-900`, monospace 11.5 `neutral-100`, 30 px copy button.

### Extension popup (12)
Width 400. Header 38 tall, background `neutral-200`, mark 22 radius 7, title
12.5 / 600, beta tag right. Body padding 14, gap 12. Status cards: two flex-1,
radius 14, padding 10 / 12, micro label 10 uppercase + value 13 / 600.
Current-tab row radius 14 padding 10 / 12 with a 26 square. Match rows radius 14
padding 11 / 12, title 13 / 600, meta 11, `strong` tag, Fill button padding
7 / 12 radius 999 `accent-300`. Search field height 34 radius 999. Footer note 11
`neutral-600`, line-height 1.5.

### In-page overlay (12 · new)
Width 320, radius 16, `--shadow-lg`. Header 10 / 12 padding on `neutral-200`,
mark 18 radius 6, text 11.5 / 600, `esc` hint 11 right. Rows radius 12 padding
9 / 10, selected on `accent-200` with a `↵ fill` hint 11 / 600. Footer action row
separated by a 1 px divider, 11 px text with a 13 px sparkle glyph.

---

## 5. Motion

| Transition | Duration | Curve |
| --- | --- | --- |
| Row hover / selection | 190 ms | ease-out-cubic |
| Button state | 220 ms | ease-out-cubic |
| Sheet in | 240 ms | ease-out-cubic |
| Sheet out | 180 ms | ease-in-cubic |
| Screen push | platform default (`ZoomPageTransitionsBuilder` Android, Cupertino iOS/macOS, fade desktop) | — |
| Unlock card entry | 280 ms, scale 0.98 → 1 + fade | ease-out-cubic |
| TOTP tick | 1 s step, no easing | — |
| Copy toast | in 200 ms, visible 1600 ms, out 200 ms | — |
| Spinner | 900 ms per rotation | linear |

All of them respect `MediaQuery.disableAnimations` (the codebase already checks
it in two places).

---

## 6. Accessibility floor

- Body text contrast ≥ 4.5:1 — that is why paragraph text on tinted backgrounds
  uses the 800–900 ramp step, never the 400/500 accent.
- Never colour-only: the health dot is always paired with words in the detail
  screen; `strong` / `possible` in the popup are text labels, not hues.
- Focus ring 2 px `accent` with 2 px offset on every focusable element.
- Minimum tap target 44 × 44 even where the glyph is 17 px.
- Secrets are masked by default; reveal is an explicit action, and on databases
  with biometrics enabled it goes through the gate first.
