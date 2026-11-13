# 007A — App icon family "Combinatore" asset generation

**Status**: Draft · **Kind**: Restyle asset work · **Depends on**: —
**Design source**: `13 Icona app & estensione.dc.html`,
`specs/_design/ICONS.md` §1, `specs/_design/custode-mark.svg`, and
`specs/_design/custode-mark-foreground.svg`.

## Milestone boundary

This implementation milestone is **007A only**. It generates and reviews the
actual selected Combinatore family; it is not a placeholder and does not retain
the current logo as a temporary result.

007A does not edit `pubspec.yaml`, Flutter UI, browser-extension runtime files,
Linux packaging, or generated platform resources. **007B is later and explicitly
out of this milestone.** Every 007B slice has common dependencies 001, 002, and
007A, then adds its owning surface dependency:

| 007B slice | Additional dependency |
| --- | --- |
| Launcher resources, manual web copies, Linux packaging | none beyond common dependencies |
| Welcome/database-selection/unlock marks | 003 |
| Security/lock and extension marks, base icons, state badges | 006 |
| In-page overlay mark | 009, only for that surface |

No 007B file is changed to claim 007A complete.

## Why

Direction **3d "Combinatore"** was selected: peach field and dial, dark hub and
hand, four sage notches. It must remain recognizable at 16 px and fit Android's
adaptive safe zone while supplying full-colour, foreground, monochrome,
web/Linux, extension, and extension-state review assets.

## FR-1 · Immutable masters and geometry record

These existing files are the only masters; 007A does not copy them into another
`icons/` directory:

| Master | SHA-256 | Meaning |
| --- | --- | --- |
| `specs/_design/custode-mark.svg` | `6d0c50c9b8e53fa678066a7b3a6eb19f9aa216163683beb7906616923eaeb5c3` | Full-bleed background plus mark |
| `specs/_design/custode-mark-foreground.svg` | `e8875c70faf2c5b7d4180f4ef2d497868f5b33b978d3971abdb9cb3094970b41` | Transparent mark only |

Both use a 100 × 100 `viewBox`. Ink is inside
`translate(50,50) scale(.75) translate(-50,-50)` and is drawn background → ring →
hand → hub → N/E/S/W notches. SVG strokes are centred on their paths. The hand
uses a round cap; the constrained renderer/oracle uses round joins, although the
current hand contains one segment and therefore has no visible join.

The transform scales geometry and stroke width because no `vector-effect` is
present. Analytic post-transform geometry is:

| Component | Geometry after transform | Analytic bounds |
| --- | --- | --- |
| Ring | centre `(50,50)`, centreline radius `23.25`, stroke `7.5` | outer `[23,77]²`; inner radius `19.5`, axis intercepts `30.5/69.5` |
| Hand | segment `(50,50)`→`(68,32)`, centred stroke `7.5`, round caps | x `[46.25,71.75]`, y `[28.25,53.75]` |
| Hub | centre `(50,50)`, radius `10.5` | `[39.5,60.5]²` |
| N notch | centre `(50,26.75)`, radius `3.75` | x `[46.25,53.75]`, y `[23,30.5]` |
| E notch | centre `(73.25,50)`, radius `3.75` | x `[69.5,77]`, y `[46.25,53.75]` |
| S notch | centre `(50,73.25)`, radius `3.75` | x `[46.25,53.75]`, y `[69.5,77]` |
| W notch | centre `(26.75,50)`, radius `3.75` | x `[23,30.5]`, y `[46.25,53.75]` |

The union's exact vector bounding box is **`[23,77] × [23,77]`**, inside the
Android safe band `[19.4,80.6]²`.

`specs/_design/ICONS.md` is a verbatim handoff record and remains unmodified. Its
recorded x bound `26.5→73.5` conflicts with the hashed master: centred ring stroke
and E/W notches reach x `23→77`. This spec records the discrepancy; computed
geometry from the hashed SVG masters governs implementation and review.

`assets/logo/app_icon_family/custode-mark-monochrome.svg` is a generated
derivative, not a third master. It preserves foreground element order, geometry,
transform, `fill="none"`, and transparent canvas while replacing every hex paint
with `#ffffff`.

## FR-2 · Canonical provisioned host

Byte reproducibility is promised only on this canonical host contract:

| Property | Required value |
| --- | --- |
| OS | macOS `26.6.2`, build `25G83` |
| Architecture | `arm64`, 64-bit, non-free-threaded CPython ABI `cp314` |
| CPython | `3.14.7`; canonical executable `/opt/homebrew/opt/python@3.14/bin/python3.14`; SHA-256 `87d4df53fd91304be5bac391fb204643c36b7df2023c04a0953bcbc7d4fdf634` |
| Pillow wheel | `pillow-12.2.0-cp314-cp314-macosx_11_0_arm64.whl` |
| Wheel URL | `https://files.pythonhosted.org/packages/ba/8c/1a9e46228571de18f8e28f16fabdfc20212a5d019f3e3303452b3f0a580d/pillow-12.2.0-cp314-cp314-macosx_11_0_arm64.whl` |
| Wheel SHA-256 | `80b2da48193b2f33ed0c32c38140f9d3186583ce7d516526d462645fd98660ae` |
| Pillow features | Pillow `12.2.0`; zlib `1.3.1.zlib-ng`; FreeType `2.14.3`; `_imaging` arm64 |
| Renderer | `pillow-imagedraw-svg-subset-v1` |

`tool/app_icon_host.lock.json` stores these values.
`tool/bootstrap_app_icon_host.sh` verifies OS/architecture/Python first, downloads
only the exact HTTPS wheel, verifies SHA-256 before installation, creates
`.dart_tool/app_icon_host/venv`, installs with `--no-index --no-deps`, then verifies
Pillow, zlib, FreeType, ABI, pointer width, and native extension architecture.
Bootstrap fails before generation on any mismatch and never falls back to another
wheel or renderer.

`tool/build_app_icon_family.py --print-toolchain` repeats all checks from inside
the provisioned venv. It also attests the exact running `sys.executable`, venv
prefix, resolved base executable/prefix, and `PIL`/`_imaging` locations below the
canonical venv; `PYTHONPATH`, `PYTHONHOME`, system-Python, and relocated/spoofed
module execution fail. Cross-host semantic review may be added later, but no
cross-host byte-identical claim exists until that host receives a separate pinned
provisioning contract and approved hashes.

Pillow is required for antialiased drawing, alpha compositing, PNG encoding, and
inspection. No Dart/Flutter/pub dependency is added. All PNGs are 8-bit, carry one
perceptual PNG `sRGB` chunk, carry no `iCCP` or timestamp chunk, use compression
level 9 with optimization disabled, and use RGB or RGBA mode only.

## FR-3 · Independent geometry oracle and raster safety

Source validation and raster validation do not trust renderer output as their
oracle. A separate analytic module in the generator uses `Decimal`/integer math
and signed-distance predicates for centred circle strokes, annuli, filled circles,
round-capped/round-joined segments, and the declared transform. It never calls
Pillow drawing or resize APIs.

Expected component raster masks are produced only by this analytic oracle, never
by renderer helper output. Decoded PNG colours/alpha supply the actual masks;
component extents, threshold coverage, and full-mask differences are compared with
size-aware boundary tolerances for ring, hand, hub, and each notch.

For 1024 px, and for smaller sizes only where geometry leaves a full final-pixel
margin, it derives outer/inner ring, hub, hand, and notch pixel ranges plus stable
interior/exterior probes. The four notch centres, hub centre, hand midpoint/end
cap, ring annulus, inner hole, and outside-ring probes are mandatory at compatible
sizes. Detailed one-pixel-margin probes are never forced onto geometry too small
to contain them.

At 16 px, the oracle instead computes expected fractional coverage ranges for the
final pixels containing each component centre and the hand/ring sample locations.
Decoded RGB is projected from the documented underlying paint to component paint
to recover actual 0–255 coverage; tests require it to fall within those ranges,
require nonzero
coverage for every intended component centre, and retain threshold safe-zone and
separate no-crop checks. The thresholded union extrema at every size must agree
with the size-quantized `[23,77]²` bbox within one final pixel.

Each render also produces an in-memory 8-bit coverage mask before opaque
flattening. **Ink for safe-zone assertions is coverage ≥128.** Every such pixel
centre must remain inside `[19.4,80.6]²`. LANCZOS halo with coverage 1–127 may
extend beyond the vector bbox and is not misclassified as unsafe ink.

No-crop is a separate check: outermost coverage rows/columns are zero; opaque
outputs have exact `#ffe1d0` outer rows/columns; transparent outputs have alpha
zero there; all four analytic extrema and every mandatory component probe are
present. Passing safe-zone containment alone cannot hide a missing/cropped
component.

## FR-4 · Exact 007A output inventory

All generated outputs live under `assets/logo/app_icon_family/`; no repository
root `icons/` path is assumed.

| Output | Dimensions | Mode/background | Source and later consumer |
| --- | --- | --- | --- |
| `custode-mark-monochrome.svg` | viewBox 100×100; width/height 1024 | transparent white ink | foreground derivative |
| `custode-source-1024.png` | 1024×1024 | RGB, opaque `#ffe1d0` | normal launcher source |
| `custode-adaptive-foreground-1024.png` | 1024×1024 | RGBA | Android foreground; iOS dark source |
| `custode-monochrome-1024.png` | 1024×1024 | RGBA, white ink | Android monochrome; iOS tinted source |
| `app-512.png` | 512×512 | RGB, opaque `#ffe1d0` | web normal/maskable and Linux source |
| `app-192.png` | 192×192 | RGB, opaque `#ffe1d0` | web normal/maskable source |
| `ext-128.png` | 128×128 | RGB, opaque `#ffe1d0` | extension ready/base icon only |
| `ext-48.png` | 48×48 | RGB, opaque `#ffe1d0` | extension ready/base; web favicon source |
| `ext-32.png` | 32×32 | RGB, opaque `#ffe1d0` | extension ready/base icon |
| `ext-16.png` | 16×16 | RGB, opaque `#ffe1d0` | extension ready/base icon |
| `state/ext-16-locked.png` | 16×16 | RGBA | 45% base + locked badge |
| `state/ext-32-locked.png` | 32×32 | RGBA | 45% base + locked badge |
| `state/ext-48-locked.png` | 48×48 | RGBA | 45% base + locked badge |
| `state/ext-16-nohost.png` | 16×16 | RGBA | 45% base + host-missing badge |
| `state/ext-32-nohost.png` | 32×32 | RGBA | 45% base + host-missing badge |
| `state/ext-48-nohost.png` | 48×48 | RGBA | 45% base + host-missing badge |
| `review/app-icon-family-review.png` | 1600×1200 | RGB, opaque sRGB | deterministic visual review sheet |
| `SHA256SUMS` | text | UTF-8, LF, final newline | provenance manifest |

Count is unambiguous:

- 9 unbadged PNGs;
- 6 state PNGs, only locked/no-host at 16/32/48;
- 1 review-sheet PNG;
- 1 generated monochrome SVG;
- **17 payload outputs** total; plus 1 `SHA256SUMS` manifest = **18 generated
  outputs** below `assets/logo/app_icon_family/`.

`SHA256SUMS` contains 19 sorted repository-relative hash lines: two read-only
masters plus 17 payload outputs. It excludes itself and excludes
`specs/007-app-icon-family/review-evidence.md`.

## FR-5 · iOS source semantics

Locked `flutter_launcher_icons 0.14.4` supports normal, dark-transparent, and
tinted-grayscale paths. 007B will map:

- normal → `custode-source-1024.png`;
- dark-transparent → `custode-adaptive-foreground-1024.png`; and
- tinted-grayscale → `custode-monochrome-1024.png`.

007B keeps `desaturate_tinted_to_grayscale_ios: true` as an explicit generator
guard even though the reviewed source already has equal RGB channels. 007A does
not wire these paths or generate duplicate `ios-dark`/`ios-tinted` files.

## FR-6 · Integer extension-state geometry

Ready state uses `ext-{16,32,48,128}.png`. State PNGs exist only for 16/32/48.
Locked/no-host variants set the complete base layer to alpha 115, erase a
transparent outer circle so the real toolbar colour forms the ring, then draw an
opaque core:

| Size | Edge inset | Outer diameter | Transparent ring | Core diameter | Centre |
| --- | --- | --- | --- | --- | --- |
| 16 | 1 px | 4 px | **1 px approved legibility deviation** | 2 px | `(13,13)` |
| 32 | 1 px | 9 px | 2 px | 5 px | `(26.5,26.5)` |
| 48 | 2 px | 13 px | 2 px | 9 px | `(39.5,39.5)` |

Outer diameters are nearest integer to 28% of icon size. The 16 px ring deviates
from handoff's 2 px ring because a 4 px badge would otherwise have no visible
core. Locked core is `#a19786`; host-missing core is `#f6a06b`. No 128 state badge
is generated without later design approval. Count badges remain 007B/006 runtime
work via `chrome.action.setBadgeText` and `setBadgeBackgroundColor`.

Badge validation compares analytic integer-circle masks pixel-for-pixel with
decoded masks. Ring alpha thresholds are 48 at 16 px and 80 at 32/48 px. Maximum
symmetric differences for core are 0/0/3 pixels and for ring 0/2/8 pixels at
16/32/48. Extents and centre are exact; reflected symmetry and every quadrant are
checked with size-aware antialias allowances.

## FR-7 · Safe fresh output only

Generation always requires `--output PATH`; there is no default destination and
no publish/replace/recover mode. `PATH` must be a **new, nonexistent safe leaf**
below an existing safe parent. Caller canonicalizes temporary parent first, for
example `tmp_dir="$(realpath "$(mktemp -d)")"`, then passes an absent child such
as `--output "$tmp_dir/run-a"`. Caller prints canonical `tmp_dir` immediately so
every failed run reports where partial output remains.

Generator walks raw lexical path components with `lstat` before any normalization
or resolution, then normalizes and verifies realpath identity. It rejects every
`..` traversal, including `symlink/../leaf`, plus symlinks, dangling links, and
resolved-path drift. It also
rejects `/`, user home, repository root, `.git`, any existing file/directory, and
an unsafe/non-directory parent. Generator creates the requested leaf and writes
only below it. A crash may leave partial temporary output there; it never touches
committed assets. Read-only `--check --output PATH` is the sole mode allowed to
inspect an existing output directory. It validates its supplied path before
reading: path must exist as a real directory, every component must pass the same
canonicalization/symlink checks, and root, home, repository root, `.git`, unsafe
parent, file, and dangling-symlink targets are rejected.

For initial implementation/review, operator validates one fresh run, reviews it,
then copies it once into the currently absent
`assets/logo/app_icon_family/`. Copy is allowed only after both
`test ! -e assets/logo/app_icon_family` and
`test ! -L assets/logo/app_icon_family`; this rejects existing paths and dangling
symlinks. Copy failure remains visible as an uncommitted Git change and is removed
manually before retry.

Future regeneration always targets another fresh temporary leaf. Git diff/review
owns any deliberate replacement of committed assets. Generator has no automated
destructive publish path, directory replacement, backup, journal, rollback, or
crash-recovery workflow.

## FR-8 · Visual review and evidence

The deterministic 1600×1200 sheet contains full/masked previews,
foreground/monochrome on white/peach/dark, ready icons at 16/32/48/128, and
locked/no-host states at 16/32/48, each at 1× and nearest-neighbour enlargement.

Reviewer, UTC date, canonical host fingerprint, manifest hash, command results,
and checklist decisions are written only to
`specs/007-app-icon-family/review-evidence.md`. That file is outside generated
output and excluded from `SHA256SUMS`; generated PNGs are never edited to record
review metadata.

## Acceptance criteria

1. Bootstrap and `--print-toolchain` verify every FR-2 host, wheel, feature, ABI,
   architecture, and hash value before source/output work.
2. `--check-sources` verifies master hashes/XML and the independent analytic
   geometry table, including the `[23,77]²` union and mandatory component probes.
3. `--check --output PATH` first validates supplied existing output path per FR-7,
   then requires exactly 18 generated paths and no unlisted file; manifest
   coverage is exactly 19 lines as FR-4.
4. Every PNG passes exact dimensions, bit depth, RGB/RGBA, sRGB/chunk, alpha,
   background, corner, analytic probe, coverage-threshold safe-zone, Lanczos-halo,
   and separate no-crop checks.
5. State inventory is exactly ready 16/32/48/128 plus locked/no-host 16/32/48;
   badge geometry, alpha 115 base, transparent rings, and core colours match FR-6.
6. Two new safe-leaf output roots generated sequentially on the canonical host
   are byte-identical file-for-file and have equal manifests.
7. `.dart_tool/app_icon_host/venv/bin/python -m unittest
   tool/test_build_app_icon_family.py` covers size-aware geometry oracle behavior,
   output-path safety, deterministic fresh-directory generation, manifest hashes,
   and exact inventory using temporary directories.
8. Review sheet passes FR-8; reviewer/date and results are completed in
   `review-evidence.md`, never embedded in generated output.
9. Initial copy into `assets/logo/app_icon_family/` occurs once only while that
   path is absent. Generator never writes there. Later replacement is manual and
   reviewed through Git from another validated fresh run.
10. From a clean checkout containing accepted outputs, `--check --output
    assets/logo/app_icon_family` leaves `git status --porcelain=v1` empty.
11. 007A changes only four provision/generator/test files, exact generated
    inventory, and `review-evidence.md`. It does not modify 007B destinations.

## 007B contract — explicitly out of this milestone

Launcher integration targets are Android, iOS, macOS, Windows, and web. The
launcher package generates only Android/iOS/macOS/Windows for this project. 007B
sets `web.generate: false`, then performs reviewed byte copies:

- `app-192.png` → `web/icons/Icon-192.png` and
  `web/icons/Icon-maskable-192.png`;
- `app-512.png` → `web/icons/Icon-512.png` and
  `web/icons/Icon-maskable-512.png`; and
- `ext-48.png` → `web/favicon.png` as a separate favicon operation.

Each copy receives `cmp` and decoded dimension/mode checks. Linux is not a sixth
launcher-generator target: 007B copies `app-512.png` to
`linux/packaging/dev.camillobucciarelli.kdbxKeyVault.png`, includes it as
`share/icons/hicolor/512x512/apps/dev.camillobucciarelli.kdbxKeyVault.png`, and
checks byte equality plus release-archive presence.

007B owns superseded asset/reference removal. Checks target explicit changed
runtime/config paths; no repository-wide scan of stale design documents is a gate.

## Out of scope for 007A

- `pubspec.yaml` and launcher generation.
- Android/iOS/macOS/Windows resources, manual web copies, and Linux packaging.
- In-app/extension/overlay placement and extension runtime badge logic.
- Deletion of old logo files or references.
