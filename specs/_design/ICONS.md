# Icons — exact specification

Everything here is reproducible from numbers alone. Two families: the **app mark**
(new) and the **UI icon set** (Lucide).

---

## 1. App mark — "Combinatore"

### Geometry

Canvas **100 × 100 units**, square, full bleed. All ink lives inside a group with
`transform="translate(50,50) scale(.75) translate(-50,-50)"` — i.e. scaled to 75 %
about the centre — so the whole mark fits Android's adaptive safe zone
(66 / 108 = 61 % of the layer) and survives every OEM mask.

| Element | Geometry (unscaled units) | Paint |
| --- | --- | --- |
| Background | `rect 0,0 100×100` | fill `#ffe1d0` |
| Dial ring | `circle cx 50 cy 50 r 31` | stroke `#f6a06b`, width `10`, no fill |
| Hand | `path M50 50 → 74 26` | stroke `#402310`, width `10`, `stroke-linecap: round` |
| Hub | `circle cx 50 cy 50 r 14` | fill `#402310` |
| Notch N | `circle cx 50 cy 19 r 5` | fill `#ccdbb2` |
| Notch E | `circle cx 81 cy 50 r 5` | fill `#ccdbb2` |
| Notch S | `circle cx 50 cy 81 r 5` | fill `#ccdbb2` |
| Notch W | `circle cx 19 cy 50 r 5` | fill `#ccdbb2` |

Draw order is exactly: background → ring → hand → hub → notches. The hand is
drawn **before** the hub so the hub covers its inner end; the notches sit on top
of the ring.

After the 0.75 scale the ink box is `x 26.5 → 73.5`, `y 23 → 77` of the 100-unit
canvas — inside the safe band `19.4 → 80.6`.

Palette: `#ffe1d0` = `--color-accent-200`, `#f6a06b` = `--color-accent-400`,
`#402310` = `--color-accent-900`, `#ccdbb2` = `--color-accent-2-300`. No other
colours, no gradient, no shadow, no rounded corners on the artwork itself — the
OS applies the mask.

### Vector masters

Shipped in this folder:

| File | Contents |
| --- | --- |
| `custode-mark.svg` | Full-bleed mark (background + ink) |
| `custode-mark-foreground.svg` | Ink only, transparent — adaptive foreground and monochrome master |

For the **monochrome** variant, take `custode-mark-foreground.svg` and set every
`stroke` and `fill` to `#ffffff` (white ink on alpha), matching the existing
`assets/logo/custode-monochrome.png` convention.

### Raster exports required

| File | Size | Background | Target |
| --- | --- | --- | --- |
| `custode-source-1024.png` | 1024 | `#ffe1d0` | `flutter_launcher_icons: image_path`, plus `image_path_ios_dark_transparent` / `image_path_ios_tinted_grayscale` |
| `custode-adaptive-foreground-1024.png` | 1024 | transparent | `adaptive_icon_foreground` |
| `custode-monochrome-1024.png` | 1024 | transparent, white ink | `adaptive_icon_monochrome` |
| `app-512.png` | 512 | `#ffe1d0` | `web/icons/Icon-512.png`, `Icon-maskable-512.png` |
| `app-192.png` | 192 | `#ffe1d0` | `web/icons/Icon-192.png`, `Icon-maskable-192.png` |
| `ext-128.png` | 128 | `#ffe1d0` | extension `icons/icon-128.png` |
| `ext-48.png` | 48 | `#ffe1d0` | extension `icons/icon-48.png` |
| `ext-32.png` | 32 | `#ffe1d0` | extension `icons/icon-32.png` |
| `ext-16.png` | 16 | `#ffe1d0` | extension `icons/icon-16.png` |

Pre-rendered PNGs exist in the design project under
`design_handoff_custode_restyle/icons/`. Regenerating from the SVG is fine —
render at 4× and downsample, no additional padding, no rounding.

### `pubspec.yaml` diff

```yaml
flutter_launcher_icons:
  image_path: icons/custode-source-1024.png            # was assets/logo/custode-source.png
  android: true
  ios: true
  remove_alpha_ios: true
  adaptive_icon_background: "#FFE1D0"                   # was "#FFFFFF"
  adaptive_icon_foreground: icons/custode-adaptive-foreground-1024.png
  adaptive_icon_monochrome: icons/custode-monochrome-1024.png
  image_path_ios_dark_transparent: icons/custode-adaptive-foreground-1024.png
  image_path_ios_tinted_grayscale: icons/custode-monochrome-1024.png
  desaturate_tinted_to_grayscale_ios: true
  web: { generate: true }
  windows: { generate: true }
  macos: { generate: true }
```

Also add the files under `flutter: assets:` — the mark is shown inside the UI
(unlock, lock overlay, database list header, tablet rail).

### In-app usage of the mark

| Where | Size | Corner radius |
| --- | --- | --- |
| Tablet/desktop rail | 38 × 38 | 13 px |
| Database list header | 40 × 40 | 14 px |
| Welcome screen | 88 × 88 | 26 px |
| Lock overlay | 76 × 76 | 24 px |
| Extension popup header | 22 × 22 | 7 px |
| In-page overlay header | 18 × 18 | 6 px |

### Extension toolbar state badges (new)

The manifest has four sizes and no state variants. Add a badge drawn over the
bottom-right corner of the 16/32/48 icon, diameter **28 % of the icon**, with a
**2 px** ring in the toolbar background colour:

| State | Icon | Badge |
| --- | --- | --- |
| Ready, no matches | 100 % opacity | none |
| App locked | 45 % opacity | solid `#a19786` (`neutral-500`) |
| Native host missing | 45 % opacity | solid `#f6a06b` (`accent-400`) |
| N matches on this site | 100 % opacity | `#aebf92` (`accent-2-400`) pill with the count in `#272e1b`, 10 px bold |

Implement with `chrome.action.setIcon` (pre-rendered PNGs per state) plus
`chrome.action.setBadgeText` / `setBadgeBackgroundColor` for the count.

---

## 2. UI icon set — Lucide

Source: https://lucide.dev. **stroke-width 2.75**, `stroke-linecap: round`,
`fill: none`, `currentColor`, 24-unit viewBox. Sizes actually used:

| Context | Size |
| --- | --- |
| Inline in a row / field | 17–19 px |
| Tab bar | 23 px |
| Feature circle (empty states, gates) | 26–34 px |
| Chip / meta | 14–16 px |
| Status bar glyphs | 16 × 12 and 22 × 12 |

Tap targets stay ≥ 44 px even when the glyph is 17 px: the icon button is a
36 px circle inside a 44 px hit area.

### Mapping to the current `AppIcons` (Material → Lucide)

| `AppIcons` | Lucide name | Used in |
| --- | --- | --- |
| `add` | `plus` | New item, add key file, create database |
| `back` | `chevron-left` | Every screen header |
| `chevronRight` | `chevron-right` | Row drill-in |
| `chevronDown` | `chevron-down` | Technical details, sort |
| `close` | `x` | Sheets, remove key file, dismiss |
| `more` | `more-vertical` | Row overflow menus |
| `search` | `search` | Search fields |
| `searchOff` | `search-x` | No-results empty state |
| `copy` | `copy` | Every copy affordance |
| `edit` / `edit2` | `pencil` | Edit entry |
| `delete` | `trash-2` | Recycle bin rows |
| `deleteSweep` | `trash-2` + `minus` | Empty bin (destructive) |
| `warning` | `alert-triangle` | Invalid file, weak password, conflict |
| `info` | `info` | Explanatory rows |
| `check` | `check` | Confirmations, merge preview, verified steps |
| `lock` | `lock` | Unlock, locked states |
| `fingerprint` | `fingerprint` | Biometric gate, Face ID rows |
| `key` | `key-round` | Key file |
| `eye` / `eyeOff` | `eye` / `eye-off` | Reveal toggles |
| `folder` / `folderOpen` | `folder` | Groups |
| `folderAdd` | `folder-plus` | New folder |
| `cloud` | `cloud` | Drive, not linked |
| `cloudOff` | `cloud-off` | Offline, disconnected |
| `cloudDone` | `cloud-check`* | Synced (\* compose `cloud` + `check` if absent) |
| `sync` / `refresh` | `refresh-cw` | Sync now, regenerate, retry |
| `attachment` | `paperclip` | Attachments |
| `fileText` / `file` | `file-text` | .kdbx, CSV, attachments |
| `qrCode` | `qr-code` | Scan OTP |
| `magic` | `sparkles` | Generate password |
| `export` | `download` | Export / backup |
| `import` | `upload` | Import |
| `settings` | `settings` | Settings tab |
| `globe` / `linkSimple` | `globe` / `external-link` | Website row, open site |
| `desktop` | `monitor` | Desktop browsers |
| `sun` / `moon` | `sun` / `moon` | Theme selector |
| — (new) | `lock` | Vault tab, vault slot of the rail |
| — (new) | `arrow-up-down` | Vault sort (phone header) |
| — (new) | `shield-check` | Health tab, strength strip |
| — (new) | `circles-intersecting`* | Duplicates (\* two overlapping `circle`s, r 5, cx 9/15, cy 9/15) |
| — (new) | `clock` | Auto-lock, password age |
| — (new) | `rows-2` | Field-level diff |

In Flutter: add the `lucide_icons` package, or vendor the SVGs you need and draw
them with `flutter_svg`. Do **not** mix Material and Lucide glyphs on one screen —
the stroke weights don't match.

### Status / semantic colour of icons

| Meaning | Light | Dark |
| --- | --- | --- |
| Neutral glyph on a row | `#645c50` (`neutral-700`) | `#f9f4ed` @ 72 % |
| Needs attention | `#402310` on `#ffe1d0` | `#ffe1d0` on `#643312` |
| Positive / verified | `#272e1b` on `#e1eecc` | `#e1eecc` on `#3d472b` |
| On a primary action | `#402310` on `#ffc6a5` | same |
| Disabled | 45 % opacity | 45 % opacity |

### Entry avatars (not icons)

Rows use a **letter avatar**, not a favicon: 38 px circle (34 px in dense tablet
lists, 44–56 px on detail headers), background `#ffe1d0`, letter in `#402310`,
Caprasimo, 15 px (17 px at 44, 22 px at 56). First character of the title,
uppercase. Dark: background `#643312`, letter `#ffe1d0`.

### Password-health dot

8 px circle at the end of a list row: `#aebf92` (`accent-2-400`) strong,
`#f6a06b` (`accent-400`) needs changing, `#c0b6a5` (`neutral-400`, dark
`neutral-600`) not evaluated. Never the only signal — the detail screen spells it
out in words.
