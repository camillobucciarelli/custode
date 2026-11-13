# 007A — Plan

## Approach

Build actual Combinatore assets from the two hashed masters in `specs/_design/`.
Do not copy design-project PNGs and do not create duplicate masters under a root
`icons/` directory.

Four small tool files implement one provisioned pipeline:

- `tool/app_icon_host.lock.json` — canonical host/wheel/features contract;
- `tool/bootstrap_app_icon_host.sh` — fail-fast venv/wheel bootstrap; and
- `tool/build_app_icon_family.py` — source/oracle/render/check into fresh output;
- `tool/test_build_app_icon_family.py` — stdlib `unittest` coverage.

No Dart/Flutter dependency changes. Pipeline order:

1. provision/verify canonical macOS arm64 host;
2. validate output path, master hashes, XML, and analytic geometry oracle;
3. derive and validate monochrome SVG in memory;
4. render each target at 4× and LANCZOS-downsample once;
5. validate component probes, coverage mask, safe zone, and no-crop separately;
6. normalize PNG mode/chunks/encoding;
7. derive six state icons at 16/32/48;
8. build review sheet and 19-line hash manifest;
9. validate generated 18-file tree independently; and
10. retain fresh output for review; copy accepted first run manually only while
    committed destination is absent.

## Canonical host bootstrap

Lock exact values from spec FR-2. Bootstrap first checks macOS 26.6.2 build 25G83,
arm64, 64-bit CPython 3.14.7, executable path/hash, and non-free-threaded `cp314`.
Only then it downloads:

```text
pillow-12.2.0-cp314-cp314-macosx_11_0_arm64.whl
sha256=80b2da48193b2f33ed0c32c38140f9d3186583ce7d516526d462645fd98660ae
```

It verifies SHA-256 before installation into
`.dart_tool/app_icon_host/venv`, using `pip install --no-index --no-deps` against
the verified local wheel. Post-install verification requires Pillow 12.2.0, zlib
1.3.1.zlib-ng, FreeType 2.14.3, arm64 `_imaging`, 64-bit pointers, and renderer
contract `pillow-imagedraw-svg-subset-v1`. Existing mismatched venv fails with an
explicit reset command; bootstrap never silently replaces or upgrades it.

Generator attestation additionally requires its exact canonical venv executable
and prefix, resolved locked base executable/prefix, and `PIL`/`_imaging` modules
inside that venv. System Python, `PYTHONPATH`/`PYTHONHOME`, and relocated module
spoofs fail before source or output access.

Generator commands use only
`.dart_tool/app_icon_host/venv/bin/python`. System `python3`, Homebrew Pillow,
Quick Look, `sips`, ImageMagick, browser rendering, and alternate wheels are not
fallbacks. Byte equality is scoped to this provisioned host; cross-host output is
not canonical until separately pinned and approved.

## Independent geometry oracle

Renderer and oracle share parsed numeric source values but no rasterization code.
Oracle uses Decimal/integer signed-distance math for:

- SVG transform order `T(50,50) · S(.75) · T(-50,-50)`;
- transform-scaled centred strokes;
- ring annulus outer radius 27 and inner radius 19.5;
- round-capped/round-joined hand segment `(50,50)`→`(68,32)`, stroke radius 3.75;
- hub/notch circles; and
- quantization from 100-unit coordinates to final pixel centres.

At 1024, and at smaller sizes only when a full final-pixel margin exists, it
predicts component bbox extrema and stable coverage-on/off probes. Detailed ring
centreline/inner/outer, hand midpoint/end-cap, hub, and notch bound probes run only
at compatible sizes. Expected union bbox remains `[23,77]²`.

At 16 px, one-pixel-margin probes are invalid for subpixel notches/strokes. Oracle
instead supplies expected fractional 0–255 coverage ranges for pixels containing
component centres and hand/ring samples. Decoded RGB is projected between the
documented underlying and component paints to obtain actual 8-bit coverage. Tests
assert coverage lies in those
ranges, each intended component has nonzero centre coverage, thresholded ink stays
safe, and separate no-crop checks pass.

Renderer exposes component and union 8-bit coverage masks before flattening.
Coverage ≥128 is ink for geometry/safe-zone decisions. Coverage 1–127 outside the
vector bbox is allowed LANCZOS halo. Separate no-crop assertions require zero
outer-edge coverage plus presence of all extrema/probes.

Validation does not reuse renderer masks as expected values. A pure
signed-distance raster oracle independently builds expected visible masks from
documented geometry, while decoded PNG colour/alpha supplies actual masks.
Size-aware comparisons cover each component's extents, coverage, and full-mask
tolerance; mutation tests prove collapsed, shifted, oversized, and cropped
components fail at 48 and 1024 px.

## Fresh-output design

Generator has no default destination and no publish/replacement mode. `--output`
must name a new absent leaf below an existing real safe parent. Caller first
canonicalizes temporary parent:

```bash
tmp_dir="$(realpath "$(mktemp -d)")" &&
printf 'Temporary parent: %s\n' "$tmp_dir" &&
run_dir="$tmp_dir/run-a"
```

Path preflight first walks raw lexical components with `lstat`, before
normalization or resolution. It rejects `..` traversal (including
`symlink/../leaf`), symlinks, dangling links, and resolved-path drift, then rejects
`/`, home, repository root,
`.git`, existing paths, and unsafe/non-directory parents. Generator then creates
the leaf and writes only there. Crash leaves partial temp output; committed assets
remain untouched. Read-only `--check --output PATH` accepts only an existing real
directory after applying the same canonicalization, component, symlink, special
path, and safe-parent validation; it rejects files and dangling symlinks before
reading inventory.

First implementation keeps one validated/reviewed fresh run, confirms
`assets/logo/app_icon_family/` does not exist, and manually copies the run there
once. Generator does not publish it. Future regeneration uses another fresh temp
leaf; deliberate replacement is manual and reviewed through Git. No backup,
journal, rollback, recovery CLI, or destructive directory automation exists.

## Files in 007A

### Read-only inputs

- `specs/_design/custode-mark.svg`
- `specs/_design/custode-mark-foreground.svg`

### New implementation/provision files

- `tool/app_icon_host.lock.json`
- `tool/bootstrap_app_icon_host.sh`
- `tool/build_app_icon_family.py`
- `tool/test_build_app_icon_family.py`

### Generated outputs: exactly 18

- `assets/logo/app_icon_family/custode-mark-monochrome.svg`
- `assets/logo/app_icon_family/custode-source-1024.png`
- `assets/logo/app_icon_family/custode-adaptive-foreground-1024.png`
- `assets/logo/app_icon_family/custode-monochrome-1024.png`
- `assets/logo/app_icon_family/app-512.png`
- `assets/logo/app_icon_family/app-192.png`
- `assets/logo/app_icon_family/ext-128.png`
- `assets/logo/app_icon_family/ext-48.png`
- `assets/logo/app_icon_family/ext-32.png`
- `assets/logo/app_icon_family/ext-16.png`
- `assets/logo/app_icon_family/state/ext-16-locked.png`
- `assets/logo/app_icon_family/state/ext-32-locked.png`
- `assets/logo/app_icon_family/state/ext-48-locked.png`
- `assets/logo/app_icon_family/state/ext-16-nohost.png`
- `assets/logo/app_icon_family/state/ext-32-nohost.png`
- `assets/logo/app_icon_family/state/ext-48-nohost.png`
- `assets/logo/app_icon_family/review/app-icon-family-review.png`
- `assets/logo/app_icon_family/SHA256SUMS`

Payload count is 17: 1 SVG + 16 PNGs (9 unbadged, 6 state, 1 review).
Manifest is output 18 and contains hashes for two masters plus 17 payloads.

### Human evidence outside generated output

- `specs/007-app-icon-family/review-evidence.md`

Evidence file is explicitly allowed, manually completed, and excluded from output
inventory and `SHA256SUMS`.

## Source-to-output map

| Source | Transformation | Outputs |
| --- | --- | --- |
| Full master | 4× render, LANCZOS, RGB/sRGB | 1024 source, 192/512 app, 16/32/48/128 extension base |
| Foreground master | 4× render on alpha | 1024 adaptive foreground |
| Foreground master | replace only hex paints with white | generated monochrome SVG |
| Monochrome SVG | 4× render on alpha | 1024 monochrome PNG |
| Extension bases 16/32/48 | alpha 115 + transparent ring + opaque core | six state PNGs |
| All payload views | fixed 1600×1200 composition | review sheet |
| Two masters + 17 payloads | sorted repository-relative SHA-256 | 19-line manifest |

Badge checks use integer pixel-centre circle predicates. Decoded core/ring masks
must keep exact extents and centre, all quadrants, and reflected symmetry. Allowed
core symmetric differences are 0/0/3 pixels and ring differences 0/2/8 pixels at
16/32/48 after ring alpha thresholds 48/80/80.

## 007B integration/dependency map — deferred

Common dependencies for every row: **001, 002, 007A**.

| Integration | Additional dependency | 007B action/check |
| --- | --- | --- |
| Android | — | launcher generator; normal/adaptive/monochrome inventory and mask smoke |
| iOS | — | normal/dark/tinted paths; keep `desaturate_tinted_to_grayscale_ios: true`; catalog/alpha checks |
| macOS | — | launcher generator; AppIcon catalog inventory |
| Windows | — | launcher generator; ICO size inventory |
| Web | — | set `web.generate: false`; byte-copy 192/512 to normal+maskable; copy `ext-48.png` separately to favicon; `cmp` and decode checks |
| Linux | — | explicit 512 packaging/source copy and release-archive check |
| Welcome/database/unlock marks | 003 | asset declaration plus owning widget/golden checks |
| Security/lock and extension marks/states | 006 | base/state copies and service-worker/count-badge smoke |
| In-page overlay mark | 009 only | overlay-specific asset placement/screenshot check |

Integration targets are Android/iOS/macOS/Windows/web. Launcher package generates
four here; web uses reviewed manual copies. Linux remains explicit packaging, not
a launcher-generator target.

## Risks

| Risk | Mitigation |
| --- | --- |
| Handoff bbox conflicts with masters | preserve verbatim ICONS record; document discrepancy; hashed SVG computed geometry governs |
| Renderer validates itself | independent Decimal/signed-distance oracle and stable probes |
| Lanczos halo causes false safe-zone failure | coverage ≥128 defines ink; 1–127 halo permitted; no-crop tested separately |
| Host/library drift changes bytes | canonical macOS/arch/Python/wheel/features lock and fail-fast bootstrap |
| Generator damages accepted output | no default/publish path; absent safe leaf required; committed assets never touched |
| Unsafe output path | no symlinks/existing/root/home/repo root; safe real parent required |
| Fractional tiny badge is impossible | exact 4/1/2, 9/2/5, 13/2/9 outer/ring/core geometry |
| 007A leaks into runtime | explicit allowlist and 007B gate |

## Verification commands

Run sequentially from repository root. Every success path is chained with `&&`:

```bash
./tool/bootstrap_app_icon_host.sh &&
PY=".dart_tool/app_icon_host/venv/bin/python" &&
"$PY" tool/build_app_icon_family.py --print-toolchain &&
"$PY" tool/build_app_icon_family.py --check-sources &&
"$PY" -m unittest tool/test_build_app_icon_family.py
```

Determinism uses two absent safe leaves. Temp data is removed only on success and
is preserved with its printed path on failure:

```bash
PY=".dart_tool/app_icon_host/venv/bin/python" &&
tmp_dir="$(realpath "$(mktemp -d)")" &&
printf 'Temporary parent: %s\n' "$tmp_dir" &&
if "$PY" tool/build_app_icon_family.py --output "$tmp_dir/run-a" &&
   "$PY" tool/build_app_icon_family.py --check --output "$tmp_dir/run-a" &&
   "$PY" tool/build_app_icon_family.py --output "$tmp_dir/run-b" &&
   "$PY" tool/build_app_icon_family.py --check --output "$tmp_dir/run-b" &&
   cmp "$tmp_dir/run-a/SHA256SUMS" "$tmp_dir/run-b/SHA256SUMS" &&
   diff -rq "$tmp_dir/run-a" "$tmp_dir/run-b"; then
  rm -rf -- "$tmp_dir"
else
  rc=$?
  printf 'FAILED: preserved deterministic outputs at %s\n' "$tmp_dir" >&2
  exit "$rc"
fi
```

Create one separate review run and retain it:

```bash
PY=".dart_tool/app_icon_host/venv/bin/python" &&
tmp_dir="$(realpath "$(mktemp -d)")" &&
printf 'Temporary parent: %s\n' "$tmp_dir" &&
review_run="$tmp_dir/review-run" &&
"$PY" tool/build_app_icon_family.py --output "$review_run" &&
"$PY" tool/build_app_icon_family.py --check --output "$review_run" &&
printf 'Validated review run retained at %s\n' "$review_run"
```

If any command fails, shell stops and preserves temp parent. Open its review sheet
at 100% and complete visual rows in `review-evidence.md`. After approval, export
the printed directory as `REVIEW_RUN` and copy once:

```bash
PY=".dart_tool/app_icon_host/venv/bin/python" &&
review_run="$(realpath "${REVIEW_RUN:?set REVIEW_RUN to approved review-run}")" &&
"$PY" tool/build_app_icon_family.py --check --output "$review_run" &&
test ! -e assets/logo/app_icon_family &&
test ! -L assets/logo/app_icon_family &&
cp -R "$review_run" assets/logo/app_icon_family &&
"$PY" tool/build_app_icon_family.py --check --output assets/logo/app_icon_family
```

Remove temp parent manually only after evidence and copy checks pass. Future
regeneration never runs this initial-copy command; Git review owns replacement.

Repository checks:

```bash
flutter analyze && flutter test
```

Checkout-clean read-only smoke after accepted outputs are present:

```bash
PY=".dart_tool/app_icon_host/venv/bin/python" &&
test -z "$(git status --porcelain=v1)" &&
"$PY" tool/build_app_icon_family.py --check --output assets/logo/app_icon_family &&
test -z "$(git status --porcelain=v1)"
```

Finalize hashes and copy result in
`specs/007-app-icon-family/review-evidence.md`. No launcher/platform/device claim
is made until 007B.
