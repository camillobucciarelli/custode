#!/usr/bin/env python3
"""Deterministically build and validate 007A Combinatore icon assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import site
import stat
import struct
import subprocess
import sys
import sysconfig
import xml.etree.ElementTree as ET
import zlib
from decimal import Decimal, getcontext
from functools import lru_cache
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCK_PATH = REPO / "tool/app_icon_host.lock.json"
FULL_MASTER = REPO / "specs/_design/custode-mark.svg"
FOREGROUND_MASTER = REPO / "specs/_design/custode-mark-foreground.svg"
OUTPUT_PREFIX = Path("assets/logo/app_icon_family")
SS = 4
RENDERER = "pillow-imagedraw-svg-subset-v1"
SAFE_MIN = Decimal("19.4")
SAFE_MAX = Decimal("80.6")
VECTOR_MIN = Decimal(23)
VECTOR_MAX = Decimal(77)
PEACH = (255, 225, 208, 255)
ORANGE = (246, 160, 107, 255)
DARK = (64, 35, 16, 255)
SAGE = (204, 219, 178, 255)
WHITE = (255, 255, 255, 255)
LOCKED = (161, 151, 134, 255)
NOHOST = (246, 160, 107, 255)

MASTER_HASHES = {
    Path("specs/_design/custode-mark-foreground.svg"): "e8875c70faf2c5b7d4180f4ef2d497868f5b33b978d3971abdb9cb3094970b41",
    Path("specs/_design/custode-mark.svg"): "6d0c50c9b8e53fa678066a7b3a6eb19f9aa216163683beb7906616923eaeb5c3",
}
UNBADGED = {
    Path("custode-source-1024.png"): (1024, "full"),
    Path("custode-adaptive-foreground-1024.png"): (1024, "foreground"),
    Path("custode-monochrome-1024.png"): (1024, "monochrome"),
    Path("app-512.png"): (512, "full"),
    Path("app-192.png"): (192, "full"),
    Path("ext-128.png"): (128, "full"),
    Path("ext-48.png"): (48, "full"),
    Path("ext-32.png"): (32, "full"),
    Path("ext-16.png"): (16, "full"),
}
BADGES = {
    16: (1, 4, 1, 2, Decimal(13)),
    32: (1, 9, 2, 5, Decimal("26.5")),
    48: (2, 13, 2, 9, Decimal("39.5")),
}
STATE_PATHS = {
    Path(f"state/ext-{size}-{state}.png"): (size, state)
    for size in (16, 32, 48)
    for state in ("locked", "nohost")
}
SVG_PATH = Path("custode-mark-monochrome.svg")
REVIEW_PATH = Path("review/app-icon-family-review.png")
MANIFEST_PATH = Path("SHA256SUMS")
PAYLOAD_PATHS = frozenset({SVG_PATH, REVIEW_PATH, *UNBADGED, *STATE_PATHS})
OUTPUT_PATHS = frozenset({*PAYLOAD_PATHS, MANIFEST_PATH})
COMPONENTS = ("ring", "hand", "hub", "north", "east", "south", "west")

getcontext().prec = 40
D = Decimal


class ValidationError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def verify_toolchain() -> dict[str, object]:
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    canonical_python = Path(lock["python"]["executable"])
    canonical_venv = REPO / ".dart_tool/app_icon_host/venv"
    running_executable = Path(sys.executable)
    base_executable = Path(getattr(sys, "_base_executable", ""))
    expected_base_prefix = canonical_python.resolve(strict=True).parent.parent
    environment_mismatches = [name for name in ("PYTHONPATH", "PYTHONHOME") if os.environ.get(name)]
    runtime_checks = {
        "running executable": running_executable == canonical_venv / "bin/python",
        "venv prefix": Path(sys.prefix) == canonical_venv,
        "base executable": base_executable.resolve(strict=True) == canonical_python.resolve(strict=True),
        "base prefix": Path(sys.base_prefix).resolve(strict=True) == expected_base_prefix,
        "isolated user site": not site.ENABLE_USER_SITE,
        "canonical venv": canonical_venv.resolve(strict=True) == canonical_venv,
    }
    runtime_failed = [name for name, ok in runtime_checks.items() if not ok]
    if environment_mismatches or runtime_failed:
        details = [*(f"environment {name} must be unset" for name in environment_mismatches), *runtime_failed]
        raise ValidationError("toolchain attestation failed:\n  " + "\n  ".join(details))

    try:
        import PIL
        from PIL import Image, _imaging, features
    except ImportError as error:
        raise ValidationError("Pillow is unavailable; run ./tool/bootstrap_app_icon_host.sh") from error

    expected_pil = canonical_venv / "lib/python3.14/site-packages/PIL/__init__.py"
    pil_file = Path(PIL.__file__)
    imaging_file = Path(_imaging.__file__)
    if pil_file != expected_pil or pil_file.resolve(strict=True) != expected_pil:
        raise ValidationError(f"toolchain attestation failed: unexpected PIL module: {pil_file}")
    if not imaging_file.is_relative_to(expected_pil.parent) or imaging_file.resolve(strict=True) != imaging_file:
        raise ValidationError(f"toolchain attestation failed: unexpected _imaging module: {imaging_file}")

    soabi = str(sysconfig.get_config_var("SOABI"))
    imaging_arch = _run("file", "-b", str(imaging_file))
    actual = {
        "os_name": _run("sw_vers", "-productName"),
        "os_version": _run("sw_vers", "-productVersion"),
        "os_build": _run("sw_vers", "-buildVersion"),
        "architecture": platform.machine(),
        "python_version": platform.python_version(),
        "python_executable": str(canonical_python),
        "running_executable": str(running_executable),
        "venv_prefix": str(canonical_venv),
        "base_executable": str(base_executable),
        "pillow_file": str(pil_file),
        "python_sha256": _sha256(canonical_python),
        "python_abi": "cp314" if soabi.startswith("cpython-314-") else soabi,
        "pointer_bits": struct.calcsize("P") * 8,
        "free_threaded": bool(sysconfig.get_config_var("Py_GIL_DISABLED")),
        "pillow_version": Image.__version__,
        "zlib": features.version_codec("zlib"),
        "freetype": features.version_module("freetype2"),
        "imaging_architecture": "arm64" if "arm64" in imaging_arch else imaging_arch,
        "renderer": RENDERER,
    }
    expected = {
        "os_name": lock["os"]["name"],
        "os_version": lock["os"]["version"],
        "os_build": lock["os"]["build"],
        "architecture": lock["os"]["architecture"],
        "python_version": lock["python"]["version"],
        "python_executable": lock["python"]["executable"],
        "python_sha256": lock["python"]["sha256"],
        "python_abi": lock["python"]["abi"],
        "pointer_bits": lock["python"]["pointer_bits"],
        "free_threaded": lock["python"]["free_threaded"],
        "pillow_version": lock["pillow"]["version"],
        "zlib": lock["pillow"]["zlib"],
        "freetype": lock["pillow"]["freetype"],
        "imaging_architecture": lock["pillow"]["imaging_architecture"],
        "renderer": lock["renderer"],
    }
    mismatches = [f"{key}: expected {expected[key]!r}, got {actual[key]!r}" for key in expected if actual[key] != expected[key]]
    if mismatches:
        raise ValidationError("toolchain mismatch:\n  " + "\n  ".join(mismatches))
    return actual


def _tag(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def _expect_element(element: ET.Element, tag: str, attributes: dict[str, str]) -> None:
    if _tag(element) != tag or element.attrib != attributes or (element.text or "").strip():
        raise ValidationError(f"unexpected SVG element: {_tag(element)} {element.attrib}")


def _validate_group(group: ET.Element) -> None:
    _expect_element(
        group,
        "g",
        {
            "transform": "translate(50,50) scale(.75) translate(-50,-50)",
            "fill": "none",
            "stroke-linecap": "round",
        },
    )
    expected = [
        ("circle", {"cx": "50", "cy": "50", "r": "31", "stroke": "#f6a06b", "stroke-width": "10"}),
        ("path", {"d": "M50 50 74 26", "stroke": "#402310", "stroke-width": "10"}),
        ("circle", {"cx": "50", "cy": "50", "r": "14", "fill": "#402310"}),
        ("circle", {"cx": "50", "cy": "19", "r": "5", "fill": "#ccdbb2"}),
        ("circle", {"cx": "81", "cy": "50", "r": "5", "fill": "#ccdbb2"}),
        ("circle", {"cx": "50", "cy": "81", "r": "5", "fill": "#ccdbb2"}),
        ("circle", {"cx": "19", "cy": "50", "r": "5", "fill": "#ccdbb2"}),
    ]
    children = list(group)
    if len(children) != len(expected):
        raise ValidationError("unexpected SVG foreground child count")
    for child, (tag, attributes) in zip(children, expected, strict=True):
        _expect_element(child, tag, attributes)
        if list(child):
            raise ValidationError("nested SVG content is not supported")


def validate_sources() -> dict[str, tuple[D, D, D, D]]:
    for relative, expected_hash in MASTER_HASHES.items():
        actual_hash = _sha256(REPO / relative)
        if actual_hash != expected_hash:
            raise ValidationError(f"master hash mismatch for {relative}: {actual_hash}")

    root_attributes = {"viewBox": "0 0 100 100", "width": "1024", "height": "1024"}
    full = ET.parse(FULL_MASTER).getroot()
    foreground = ET.parse(FOREGROUND_MASTER).getroot()
    for root in (full, foreground):
        if _tag(root) != "svg" or root.attrib != root_attributes:
            raise ValidationError(f"unexpected SVG root: {root.attrib}")
    full_children = list(full)
    foreground_children = list(foreground)
    if len(full_children) != 2 or len(foreground_children) != 1:
        raise ValidationError("unexpected SVG root child count")
    _expect_element(full_children[0], "rect", {"width": "100", "height": "100", "fill": "#ffe1d0"})
    _validate_group(full_children[1])
    _validate_group(foreground_children[0])

    geometry = analytic_geometry()
    if union_bbox(geometry.values()) != (D(23), D(23), D(77), D(77)):
        raise ValidationError("analytic union is not [23,77]²")
    return geometry


def transform_point(x: D, y: D) -> tuple[D, D]:
    scale = D(".75")
    return D(50) + scale * (x - D(50)), D(50) + scale * (y - D(50))


def analytic_geometry() -> dict[str, tuple[D, D, D, D]]:
    ring_center = transform_point(D(50), D(50))
    ring_outer = D(31) * D(".75") + D(10) * D(".75") / 2
    hand_start = transform_point(D(50), D(50))
    hand_end = transform_point(D(74), D(26))
    hand_radius = D(10) * D(".75") / 2
    geometry = {
        "ring": (ring_center[0] - ring_outer, ring_center[1] - ring_outer, ring_center[0] + ring_outer, ring_center[1] + ring_outer),
        "hand": (
            min(hand_start[0], hand_end[0]) - hand_radius,
            min(hand_start[1], hand_end[1]) - hand_radius,
            max(hand_start[0], hand_end[0]) + hand_radius,
            max(hand_start[1], hand_end[1]) + hand_radius,
        ),
    }
    for name, x, y, radius in (
        ("hub", D(50), D(50), D(14)),
        ("north", D(50), D(19), D(5)),
        ("east", D(81), D(50), D(5)),
        ("south", D(50), D(81), D(5)),
        ("west", D(19), D(50), D(5)),
    ):
        cx, cy = transform_point(x, y)
        r = radius * D(".75")
        geometry[name] = (cx - r, cy - r, cx + r, cy + r)
    return geometry


def union_bbox(boxes: object) -> tuple[D, D, D, D]:
    values = list(boxes)  # type: ignore[arg-type]
    return (
        min(box[0] for box in values),
        min(box[1] for box in values),
        max(box[2] for box in values),
        max(box[3] for box in values),
    )


def _distance(x1: D, y1: D, x2: D, y2: D) -> D:
    return ((x1 - x2) ** 2 + (y1 - y2) ** 2).sqrt()


def signed_distance_circle(x: D, y: D, cx: D, cy: D, radius: D) -> D:
    return _distance(x, y, cx, cy) - radius


def signed_distance_annulus(x: D, y: D, cx: D, cy: D, radius: D, half_stroke: D) -> D:
    return abs(_distance(x, y, cx, cy) - radius) - half_stroke


def signed_distance_round_segment(x: D, y: D, ax: D, ay: D, bx: D, by: D, radius: D) -> D:
    abx, aby = bx - ax, by - ay
    denominator = abx * abx + aby * aby
    t = ((x - ax) * abx + (y - ay) * aby) / denominator
    t = max(D(0), min(D(1), t))
    return _distance(x, y, ax + t * abx, ay + t * aby) - radius


def component_contains(component: str, x: D, y: D) -> bool:
    if component == "ring":
        return signed_distance_annulus(x, y, D(50), D(50), D("23.25"), D("3.75")) <= 0
    if component == "hand":
        return signed_distance_round_segment(x, y, D(50), D(50), D(68), D(32), D("3.75")) <= 0
    circles = {
        "hub": (D(50), D(50), D("10.5")),
        "north": (D(50), D("26.75"), D("3.75")),
        "east": (D("73.25"), D(50), D("3.75")),
        "south": (D(50), D("73.25"), D("3.75")),
        "west": (D("26.75"), D(50), D("3.75")),
    }
    return signed_distance_circle(x, y, *circles[component]) <= 0


PROBE_POINTS = {
    "ring": (D("33.56"), D("33.56")),
    "hand": (D(59), D(41)),
    "hub": (D(50), D(50)),
    "north": (D(50), D("26.75")),
    "east": (D("73.25"), D(50)),
    "south": (D(50), D("73.25")),
    "west": (D("26.75"), D(50)),
}


def pixel_for_point(size: int, point: tuple[D, D]) -> tuple[int, int]:
    return min(size - 1, int(point[0] * size / 100)), min(size - 1, int(point[1] * size / 100))


def analytic_fractional_coverage(component: str, size: int, point: tuple[D, D], samples: int = 24) -> int:
    px, py = pixel_for_point(size, point)
    hits = 0
    total = samples * samples
    for sy in range(samples):
        y = (D(py) + (D(sy) + D(".5")) / samples) * 100 / size
        for sx in range(samples):
            x = (D(px) + (D(sx) + D(".5")) / samples) * 100 / size
            hits += component_contains(component, x, y)
    return (hits * 255 + total // 2) // total


def fractional_probe_ranges(size: int = 16) -> dict[str, tuple[int, int]]:
    if size != 16:
        raise ValueError("fractional probe ranges are defined for 16 px")
    ranges = {}
    for component, point in PROBE_POINTS.items():
        expected = analytic_fractional_coverage(component, size, point)
        ranges[component] = (max(1, expected - 96), min(255, expected + 96))
    return ranges


def _component_contains_scaled(component: str, px: int, py: int, size: int) -> bool:
    """Integer predicates in quarter-SVG units scaled by final raster size."""
    x = (2 * px + 1) * 200
    y = (2 * py + 1) * 200
    scale = size
    if component == "ring":
        dx = x - 200 * scale
        dy = y - 200 * scale
        distance_squared = dx * dx + dy * dy
        return (78 * scale) ** 2 <= distance_squared <= (108 * scale) ** 2
    if component == "hand":
        ax, ay, bx, by = 200 * scale, 200 * scale, 272 * scale, 128 * scale
        abx, aby = bx - ax, by - ay
        apx, apy = x - ax, y - ay
        dot = apx * abx + apy * aby
        length_squared = abx * abx + aby * aby
        radius_squared = (15 * scale) ** 2
        if dot <= 0:
            return apx * apx + apy * apy <= radius_squared
        if dot >= length_squared:
            bpx, bpy = x - bx, y - by
            return bpx * bpx + bpy * bpy <= radius_squared
        cross = apx * aby - apy * abx
        return cross * cross <= radius_squared * length_squared
    circles = {
        "hub": (200, 200, 42),
        "north": (200, 107, 15),
        "east": (293, 200, 15),
        "south": (200, 293, 15),
        "west": (107, 200, 15),
    }
    cx, cy, radius = circles[component]
    dx = x - cx * scale
    dy = y - cy * scale
    return dx * dx + dy * dy <= (radius * scale) ** 2


@lru_cache(maxsize=None)
def _analytic_component_masks_cached(size: int, visible: bool) -> tuple[frozenset[int], ...]:
    """Return pure signed-distance masks; never calls Pillow or renderer helpers."""
    geometry = analytic_geometry()
    masks: dict[str, set[int]] = {}
    for component in COMPONENTS:
        left, top, right, bottom = geometry[component]
        min_x = max(0, int(left * size / 100) - 1)
        max_x = min(size - 1, int(right * size / 100) + 1)
        min_y = max(0, int(top * size / 100) - 1)
        max_y = min(size - 1, int(bottom * size / 100) + 1)
        mask = set()
        for py in range(min_y, max_y + 1):
            for px in range(min_x, max_x + 1):
                if _component_contains_scaled(component, px, py, size):
                    mask.add(py * size + px)
        masks[component] = mask
    if visible:
        notches = masks["north"] | masks["east"] | masks["south"] | masks["west"]
        masks = {
            "ring": masks["ring"] - masks["hand"] - masks["hub"] - notches,
            "hand": masks["hand"] - masks["hub"] - notches,
            "hub": masks["hub"] - notches,
            "north": masks["north"],
            "east": masks["east"],
            "south": masks["south"],
            "west": masks["west"],
        }
    return tuple(frozenset(masks[component]) for component in COMPONENTS)


def analytic_component_masks(size: int, *, visible: bool = True) -> dict[str, set[int]]:
    cached = _analytic_component_masks_cached(size, visible)
    return {component: set(mask) for component, mask in zip(COMPONENTS, cached, strict=True)}


def _mask_extents(mask: set[int], size: int) -> tuple[int, int, int, int]:
    if not mask:
        raise ValidationError("component mask is empty")
    xs = [index % size for index in mask]
    ys = [index // size for index in mask]
    return min(xs), min(ys), max(xs), max(ys)


def validate_component_mask_sets(size: int, actual: dict[str, set[int]]) -> None:
    expected = analytic_component_masks(size)
    extent_tolerance = 2 if size <= 48 else 3
    ratio_tolerance = 0.65 if size == 16 else 0.35 if size == 32 else 0.22 if size == 48 else 0.12 if size <= 128 else 0.08 if size <= 192 else 0.045 if size <= 512 else 0.03
    for component in COMPONENTS:
        expected_mask = expected[component]
        actual_mask = actual.get(component, set())
        if not actual_mask:
            raise ValidationError(f"analytic raster oracle: missing {component} at {size}px")
        expected_extents = _mask_extents(expected_mask, size)
        actual_extents = _mask_extents(actual_mask, size)
        if any(abs(expected_value - actual_value) > extent_tolerance for expected_value, actual_value in zip(expected_extents, actual_extents, strict=True)):
            raise ValidationError(
                f"analytic raster oracle: {component} extents at {size}px: expected {expected_extents}, got {actual_extents}"
            )
        coverage_delta = abs(len(actual_mask) - len(expected_mask)) / len(expected_mask)
        mismatch = len(actual_mask ^ expected_mask) / len(expected_mask)
        if coverage_delta > ratio_tolerance or mismatch > ratio_tolerance * 1.6:
            raise ValidationError(
                f"analytic raster oracle: {component} coverage/mask at {size}px: "
                f"expected {len(expected_mask)}, got {len(actual_mask)}, mismatch {mismatch:.3f}"
            )

    union = set().union(*actual.values())
    if not union:
        raise ValidationError(f"analytic raster oracle: empty union at {size}px")
    for index in union:
        x, y = index % size, index // size
        ux = (D(x) + D(".5")) * 100 / size
        uy = (D(y) + D(".5")) * 100 / size
        if not (SAFE_MIN <= ux <= SAFE_MAX and SAFE_MIN <= uy <= SAFE_MAX):
            raise ValidationError(f"analytic raster oracle: unsafe ink at {size}px: {(x, y)}")
        if x in (0, size - 1) or y in (0, size - 1):
            raise ValidationError(f"analytic raster oracle: cropped ink at {size}px: {(x, y)}")


def _actual_component_masks(image: object, size: int, variant: str) -> dict[str, set[int]]:
    from PIL import Image

    if not isinstance(image, Image.Image):
        raise TypeError("image must be a Pillow image")
    expected = analytic_component_masks(size)
    masks = {component: set() for component in COMPONENTS}
    palette = {"background": PEACH[:3], "ring": ORANGE[:3], "dark": DARK[:3], "sage": SAGE[:3]}
    notch_centres = {
        "north": (200, 107),
        "east": (293, 200),
        "south": (200, 293),
        "west": (107, 200),
    }
    for py in range(size):
        for px in range(size):
            pixel = image.getpixel((px, py))
            if variant != "full" and pixel[3] < 128:
                continue
            rgb = pixel[:3]
            distances = {
                name: sum((channel - target) ** 2 for channel, target in zip(rgb, colour, strict=True))
                for name, colour in palette.items()
                if variant != "foreground" or name != "background"
            }
            if rgb[1] - rgb[0] < -20:
                distances.pop("sage", None)
            label = min(distances, key=distances.get)
            if label == "background":
                continue
            index = py * size + px
            if label == "ring":
                masks["ring"].add(index)
            elif label == "sage":
                x, y = (2 * px + 1) * 200, (2 * py + 1) * 200
                notch = min(
                    notch_centres,
                    key=lambda name: (x - notch_centres[name][0] * size) ** 2
                    + (y - notch_centres[name][1] * size) ** 2,
                )
                masks[notch].add(index)
            else:
                if index in expected["hub"]:
                    masks["hub"].add(index)
                elif index in expected["hand"]:
                    masks["hand"].add(index)
                else:
                    x, y = (px + 0.5) * 100.0 / size, (py + 0.5) * 100.0 / size
                    hub_distance = abs(signed_distance_circle(D(str(x)), D(str(y)), D(50), D(50), D("10.5")))
                    hand_distance = abs(signed_distance_round_segment(D(str(x)), D(str(y)), D(50), D(50), D(68), D(32), D("3.75")))
                    masks["hub" if hub_distance < hand_distance else "hand"].add(index)
    return masks


def decoded_probe_coverages(image: object) -> dict[str, int]:
    under = {
        "ring": PEACH[:3],
        "hand": PEACH[:3],
        "hub": PEACH[:3],
        "north": ORANGE[:3],
        "east": ORANGE[:3],
        "south": ORANGE[:3],
        "west": ORANGE[:3],
    }
    target = {
        "ring": ORANGE[:3],
        "hand": DARK[:3],
        "hub": DARK[:3],
        "north": SAGE[:3],
        "east": SAGE[:3],
        "south": SAGE[:3],
        "west": SAGE[:3],
    }
    coverages = {}
    for component, point in PROBE_POINTS.items():
        pixel = image.getpixel(pixel_for_point(16, point))[:3]  # type: ignore[union-attr]
        base = under[component]
        paint = target[component]
        numerator = sum((pixel[index] - base[index]) * (paint[index] - base[index]) for index in range(3))
        denominator = sum((paint[index] - base[index]) ** 2 for index in range(3))
        coverages[component] = max(0, min(255, (numerator * 255 + denominator // 2) // denominator))
    return coverages


def validate_size_16_probes(image: object) -> None:
    actual_coverages = decoded_probe_coverages(image)
    for component, (minimum, maximum) in fractional_probe_ranges().items():
        coverage = actual_coverages[component]
        if not minimum <= coverage <= maximum:
            raise ValidationError(
                f"analytic raster oracle: 16px {component} probe coverage {coverage} "
                f"outside [{minimum},{maximum}]"
            )


def validate_raster_oracle(image: object, size: int, variant: str) -> None:
    if variant == "monochrome":
        expected = set().union(*analytic_component_masks(size).values())
        actual = {
            py * size + px
            for py in range(size)
            for px in range(size)
            if image.getpixel((px, py))[3] >= 128  # type: ignore[union-attr]
        }
        if not actual:
            raise ValidationError(f"analytic raster oracle: empty monochrome at {size}px")
        tolerance = 0.06 if size >= 512 else 0.25
        mismatch = len(actual ^ expected) / len(expected)
        if mismatch > tolerance:
            raise ValidationError(f"analytic raster oracle: monochrome mask mismatch at {size}px: {mismatch:.3f}")
        return
    validate_component_mask_sets(size, _actual_component_masks(image, size, variant))
    if size == 16 and variant == "full":
        validate_size_16_probes(image)


def monochrome_svg() -> bytes:
    source = FOREGROUND_MASTER.read_text(encoding="utf-8")
    result, count = re.subn(r"#[0-9a-fA-F]{6}", "#ffffff", source)
    if count != 7 or re.search(r"#[0-9a-fA-F]{6}", result.replace("#ffffff", "")):
        raise ValidationError("unexpected monochrome paint replacement count")
    result = result.replace("\r\n", "\n").replace("\r", "\n").rstrip("\n") + "\n"
    return result.encode("utf-8")


def _scaled_box(box: tuple[float, float, float, float], high_size: int) -> tuple[float, float, float, float]:
    scale = high_size / 100
    return tuple(value * scale for value in box)  # type: ignore[return-value]


def _draw_component(draw: object, component: str, high_size: int, fill: object) -> None:
    from PIL import ImageDraw

    assert isinstance(draw, ImageDraw.ImageDraw)
    scale = high_size / 100
    if component == "ring":
        draw.ellipse(_scaled_box((23, 23, 77, 77), high_size), outline=fill, width=max(1, round(7.5 * scale)))
    elif component == "hand":
        width = max(1, round(7.5 * scale))
        start = (50 * scale, 50 * scale)
        end = (68 * scale, 32 * scale)
        draw.line((start, end), fill=fill, width=width)
        radius = 3.75 * scale
        for cx, cy in (start, end):
            draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=fill)
    else:
        circles = {
            "hub": (50, 50, 10.5),
            "north": (50, 26.75, 3.75),
            "east": (73.25, 50, 3.75),
            "south": (50, 73.25, 3.75),
            "west": (26.75, 50, 3.75),
        }
        cx, cy, radius = circles[component]
        draw.ellipse(_scaled_box((cx - radius, cy - radius, cx + radius, cy + radius), high_size), fill=fill)


def render_mark(size: int, variant: str) -> object:
    from PIL import Image, ImageDraw

    high_size = size * SS
    background = PEACH if variant == "full" else (0, 0, 0, 0)
    high = Image.new("RGBA", (high_size, high_size), background)
    colors = {
        "ring": ORANGE,
        "hand": DARK,
        "hub": DARK,
        "north": SAGE,
        "east": SAGE,
        "south": SAGE,
        "west": SAGE,
    }
    if variant == "monochrome":
        colors = {component: WHITE for component in COMPONENTS}
    draw = ImageDraw.Draw(high)
    for component in COMPONENTS:
        _draw_component(draw, component, high_size, colors[component])
    image = high.resize((size, size), Image.Resampling.LANCZOS)
    return image.convert("RGB") if variant == "full" else image


def _circle_mask(size: int, diameter: int, center: D) -> object:
    from PIL import Image, ImageDraw

    high_size = size * SS
    mask = Image.new("L", (high_size, high_size), 0)
    draw = ImageDraw.Draw(mask)
    c = float(center) * SS
    radius = diameter * SS / 2
    draw.ellipse((c - radius, c - radius, c + radius, c + radius), fill=255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def render_state(base: object, size: int, state: str) -> object:
    from PIL import Image

    if not isinstance(base, Image.Image):
        raise TypeError("base must be a Pillow image")
    _inset, outer, ring, core, center = BADGES[size]
    if outer - core != 2 * ring:
        raise ValidationError(f"invalid badge ring geometry at {size}")
    image = base.convert("RGBA")
    image.putalpha(Image.new("L", image.size, 115))
    outer_mask = _circle_mask(size, outer, center)
    alpha = image.getchannel("A")
    alpha.paste(0, mask=outer_mask)
    image.putalpha(alpha)
    core_mask = _circle_mask(size, core, center)
    core_mask = core_mask.point(lambda value: 255 if value >= 254 else value)
    color = LOCKED if state == "locked" else NOHOST
    core_layer = Image.new("RGBA", image.size, color)
    image.paste(core_layer, mask=core_mask)
    return image


def _png_info() -> object:
    from PIL.PngImagePlugin import PngInfo

    info = PngInfo()
    info.add(b"sRGB", b"\x00")
    return info


def save_png(image: object, path: Path) -> None:
    from PIL import Image

    if not isinstance(image, Image.Image):
        raise TypeError("image must be a Pillow image")
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", compress_level=9, optimize=False, pnginfo=_png_info())


def _checkerboard(size: tuple[int, int], cell: int = 16) -> object:
    from PIL import Image, ImageDraw

    image = Image.new("RGB", size, (255, 255, 255))
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2:
                draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=(226, 226, 226))
    return image


def _contain(image: object, box: tuple[int, int], nearest: bool = False) -> object:
    from PIL import Image

    assert isinstance(image, Image.Image)
    ratio = min(box[0] / image.width, box[1] / image.height)
    size = (max(1, round(image.width * ratio)), max(1, round(image.height * ratio)))
    method = Image.Resampling.NEAREST if nearest else Image.Resampling.LANCZOS
    return image.resize(size, method)


def build_review_sheet(images: dict[Path, object]) -> object:
    from PIL import Image, ImageDraw, ImageFont

    sheet = Image.new("RGB", (1600, 1200), (249, 244, 237))
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()

    def label(x: int, y: int, text: str) -> None:
        draw.text((x, y), text, fill=(64, 35, 16), font=font)

    # Kept as rendered in the committed review sheet: changing it means
    # regenerating that PNG on the attested macOS toolchain.
    label(40, 24, "KEYVAULT 007A / COMBINATORE / DETERMINISTIC REVIEW")
    source = images[Path("custode-source-1024.png")]
    assert isinstance(source, Image.Image)
    label(40, 62, "FULL + MASK PREVIEWS / NO-CROP")
    for index, shape in enumerate(("full", "circle", "squircle", "rounded-square")):
        x, y, side = 40 + index * 260, 88, 220
        preview = source.resize((side, side), Image.Resampling.LANCZOS)
        if shape != "full":
            mask = Image.new("L", (side, side), 0)
            mask_draw = ImageDraw.Draw(mask)
            if shape == "circle":
                mask_draw.ellipse((0, 0, side - 1, side - 1), fill=255)
            else:
                radius = 54 if shape == "squircle" else 34
                mask_draw.rounded_rectangle((0, 0, side - 1, side - 1), radius=radius, fill=255)
            tile = Image.new("RGB", (side, side), (39, 46, 27))
            tile.paste(preview, mask=mask)
            preview = tile
        sheet.paste(preview, (x, y))
        label(x, y + side + 8, shape)

    label(40, 352, "FOREGROUND + MONOCHROME ON WHITE / PEACH / DARK")
    foregrounds = (
        ("foreground", images[Path("custode-adaptive-foreground-1024.png")]),
        ("monochrome", images[Path("custode-monochrome-1024.png")]),
    )
    backgrounds = (("white", (255, 255, 255)), ("peach", PEACH[:3]), ("dark", (39, 46, 27)))
    for row, (name, image) in enumerate(foregrounds):
        assert isinstance(image, Image.Image)
        for column, (background_name, background) in enumerate(backgrounds):
            x, y, side = 40 + column * 230, 380 + row * 210, 176
            if name == "monochrome" and background_name == "white":
                tile = _checkerboard((side, side))
                ImageDraw.Draw(tile).rectangle((0, 0, side // 2 - 1, side - 1), fill=background)
                background_name = "white + alpha checker"
            else:
                tile = Image.new("RGB", (side, side), background)
            scaled = image.resize((side, side), Image.Resampling.LANCZOS)
            tile.paste(scaled, mask=scaled.getchannel("A"))
            sheet.paste(tile, (x, y))
            label(x, y + side + 6, f"{name} / {background_name}")

    label(760, 352, "READY / NATIVE 1x + NEAREST-NEIGHBOUR")
    ready_layout = {
        16: (760, 380, 8, 42),
        32: (940, 380, 4, 42),
        48: (760, 590, 3, 60),
        128: (40, 810, 2, 160),
    }
    for size, (x, y, factor, enlarged_x) in ready_layout.items():
        image = images[Path(f"ext-{size}.png")]
        assert isinstance(image, Image.Image)
        sheet.paste(image, (x, y))
        enlarged = image.resize((size * factor,) * 2, Image.Resampling.NEAREST)
        sheet.paste(enlarged, (x + enlarged_x, y))
        label(x, y + 4 + max(size, enlarged.height), f"ready {size}px / 1x + {factor}x nearest")

    label(1120, 62, "STATES / 1x + NEAREST")
    for row, size in enumerate((16, 32, 48)):
        for column, state in enumerate(("locked", "nohost")):
            image = images[Path(f"state/ext-{size}-{state}.png")]
            assert isinstance(image, Image.Image)
            x, y = 1120 + column * 220, 92 + row * 230
            checker = _checkerboard((176, 176))
            enlarged = image.resize((176, 176), Image.Resampling.NEAREST)
            checker.paste(enlarged, mask=enlarged.getchannel("A"))
            sheet.paste(checker, (x, y))
            sheet.paste(image, (x, y + 182), mask=image.getchannel("A"))
            label(x + 58, y + 184, f"{state} {size}px")

    label(40, 1128, "Machine checks: analytic [23,77]^2 bbox / safe [19.4,80.6]^2 / outer-edge no-crop")
    label(40, 1152, "Human decision intentionally lives in specs/007-app-icon-family/review-evidence.md")
    return sheet


def _inspect_lexical_path(raw: str, *, existing: bool) -> Path:
    if "\x00" in raw:
        raise ValidationError("output path contains NUL")
    lexical = Path(raw)
    if not lexical.is_absolute():
        lexical = Path.cwd() / lexical
    parts = lexical.parts
    current = Path(parts[0])
    normal_parts = [part for part in parts[1:] if part not in ("", ".")]
    for index, part in enumerate(normal_parts):
        if part == "..":
            raise ValidationError(f"output path contains lexical traversal: {lexical}")
        current /= part
        is_leaf = index == len(normal_parts) - 1
        must_exist = existing or not is_leaf
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError as error:
            if must_exist:
                raise ValidationError(f"output path component does not exist: {current}") from error
            continue
        if stat.S_ISLNK(mode):
            raise ValidationError(f"output path contains symlink: {current}")
        if must_exist and not stat.S_ISDIR(mode):
            raise ValidationError(f"output path component is not a directory: {current} ({mode:o})")
    return Path(os.path.normpath(os.fspath(lexical)))


def validate_output_path(raw_path: str | Path, *, existing: bool) -> Path:
    raw = os.fspath(raw_path)
    if not raw:
        raise ValidationError("output path is empty")
    path = _inspect_lexical_path(raw, existing=existing)
    forbidden = {Path("/"), Path.home().resolve(), REPO, REPO / ".git"}
    if path in forbidden or path.is_relative_to(REPO / ".git"):
        raise ValidationError(f"unsafe output path: {path}")

    if existing:
        if not os.path.lexists(path):
            raise ValidationError(f"output directory does not exist: {path}")
        if path.is_symlink() or not path.is_dir():
            raise ValidationError(f"output path is not a real directory: {path}")
        resolved = path.resolve(strict=True)
    else:
        if os.path.lexists(path):
            raise ValidationError(f"generation output already exists: {path}")
        parent = path.parent
        if parent in forbidden or parent.is_relative_to(REPO / ".git"):
            raise ValidationError(f"unsafe output parent: {parent}")
        if not os.access(parent, os.W_OK | os.X_OK):
            raise ValidationError(f"output parent is not writable: {parent}")
        resolved = parent.resolve(strict=True) / path.name
    if resolved != path:
        raise ValidationError(f"resolved output path drift: {path} -> {resolved}")
    return path


def _png_chunks(path: Path) -> tuple[bytes, list[tuple[bytes, bytes]]]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValidationError(f"not PNG: {path}")
    chunks = []
    offset = 8
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValidationError(f"truncated PNG: {path}")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        if offset + 12 + length > len(data):
            raise ValidationError(f"truncated PNG chunk: {path}")
        name = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length : offset + 12 + length])[0]
        actual_crc = zlib.crc32(name + payload) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValidationError(f"PNG CRC mismatch in {path}: {name!r}")
        chunks.append((name, payload))
        offset += 12 + length
    if offset != len(data) or not chunks or chunks[-1][0] != b"IEND":
        raise ValidationError(f"invalid PNG chunk stream: {path}")
    return data, chunks


def validate_png(path: Path, size: tuple[int, int], mode: str) -> None:
    from PIL import Image

    _data, chunks = _png_chunks(path)
    names = [name for name, _payload in chunks]
    if names.count(b"sRGB") != 1 or b"iCCP" in names or b"tIME" in names:
        raise ValidationError(f"invalid PNG metadata policy: {path}: {names}")
    if next(payload for name, payload in chunks if name == b"sRGB") != b"\x00":
        raise ValidationError(f"invalid PNG sRGB rendering intent: {path}")
    ihdr = chunks[0]
    if ihdr[0] != b"IHDR" or len(ihdr[1]) != 13:
        raise ValidationError(f"invalid PNG IHDR: {path}")
    width, height, bit_depth, color_type = struct.unpack(">IIBB", ihdr[1][:10])
    expected_color_type = 2 if mode == "RGB" else 6
    if (width, height) != size or bit_depth != 8 or color_type != expected_color_type:
        raise ValidationError(f"invalid PNG header: {path}")
    with Image.open(path) as image:
        image.load()
        if image.size != size or image.mode != mode:
            raise ValidationError(f"invalid decoded PNG: {path}: {image.size}/{image.mode}")


def expected_badge_masks(size: int) -> tuple[set[int], set[int]]:
    _inset, outer, _ring, core, center = BADGES[size]
    centre2 = int(center * 2)
    core_mask: set[int] = set()
    ring_mask: set[int] = set()
    for y in range(size):
        for x in range(size):
            distance_squared = (2 * x + 1 - centre2) ** 2 + (2 * y + 1 - centre2) ** 2
            index = y * size + x
            if distance_squared <= core**2:
                core_mask.add(index)
            elif distance_squared <= outer**2:
                ring_mask.add(index)
    return core_mask, ring_mask


def _reflect_badge_mask(mask: set[int], size: int) -> set[int]:
    centre2 = int(BADGES[size][4] * 2)
    reflected = set()
    for index in mask:
        x, y = index % size, index // size
        reflected_x = (2 * centre2 - (2 * x + 1) - 1) // 2
        reflected_y = (2 * centre2 - (2 * y + 1) - 1) // 2
        if 0 <= reflected_x < size and 0 <= reflected_y < size:
            reflected.add(reflected_y * size + reflected_x)
    return reflected


def validate_badge_masks(size: int, actual_core: set[int], actual_ring: set[int]) -> None:
    expected_core, expected_ring = expected_badge_masks(size)
    difference_tolerance = {
        16: {"core": 0, "ring": 0},
        32: {"core": 0, "ring": 2},
        48: {"core": 3, "ring": 8},
    }[size]
    symmetry_tolerance = {
        16: {"core": 0, "ring": 0},
        32: {"core": 0, "ring": 4},
        48: {"core": 6, "ring": 6},
    }[size]
    for label, expected_mask, actual_mask in (
        ("core", expected_core, actual_core),
        ("ring", expected_ring, actual_ring),
    ):
        if not actual_mask:
            raise ValidationError(f"badge {label} missing at {size}px")
        if _mask_extents(actual_mask, size) != _mask_extents(expected_mask, size):
            raise ValidationError(f"badge {label} extents mismatch at {size}px")
        difference = len(actual_mask ^ expected_mask)
        if difference > difference_tolerance[label]:
            raise ValidationError(
                f"badge {label} per-pixel mismatch at {size}px: {difference} > {difference_tolerance[label]}"
            )
        asymmetry = len(actual_mask ^ _reflect_badge_mask(actual_mask, size))
        if asymmetry > symmetry_tolerance[label]:
            raise ValidationError(
                f"badge {label} asymmetry at {size}px: {asymmetry} > {symmetry_tolerance[label]}"
            )

    centre = int(BADGES[size][4])
    if centre * size + centre not in actual_core:
        raise ValidationError(f"badge core centre missing at {size}px")
    centre2 = int(BADGES[size][4] * 2)
    quadrant_tolerance = {16: 0, 32: 1, 48: 3}[size]
    for horizontal, vertical in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        expected_quadrant = {
            index
            for index in expected_ring
            if (1 if 2 * (index % size) + 1 >= centre2 else -1) == horizontal
            and (1 if 2 * (index // size) + 1 >= centre2 else -1) == vertical
        }
        missing = len(expected_quadrant - actual_ring)
        if missing > quadrant_tolerance:
            raise ValidationError(f"badge ring quadrant missing at {size}px")


def validate_state_image(image: object, base: object, size: int, state: str) -> None:
    from PIL import Image

    if not isinstance(image, Image.Image) or not isinstance(base, Image.Image):
        raise TypeError("state and base must be Pillow images")
    inset, outer, ring, core, center = BADGES[size]
    if outer != round(size * 0.28):
        raise ValidationError(f"badge outer diameter mismatch at {size}px")
    if center + D(outer) / 2 != D(size - inset):
        raise ValidationError(f"badge inset mismatch at {size}px")
    if outer - core != ring * 2:
        raise ValidationError(f"badge ring width mismatch in {state} {size}px")

    expected_colour = LOCKED if state == "locked" else NOHOST
    ring_alpha_threshold = {16: 48, 32: 80, 48: 80}[size]
    actual_core: set[int] = set()
    actual_ring: set[int] = set()
    centre2 = int(center * 2)
    for y in range(size):
        for x in range(size):
            index = y * size + x
            state_pixel = image.getpixel((x, y))
            base_pixel = base.getpixel((x, y))[:3]
            core_distance = sum((state_pixel[channel] - expected_colour[channel]) ** 2 for channel in range(3))
            base_distance = sum((state_pixel[channel] - base_pixel[channel]) ** 2 for channel in range(3))
            if state_pixel[3] >= 128 and core_distance < base_distance:
                actual_core.add(index)
            if state_pixel[3] <= ring_alpha_threshold:
                actual_ring.add(index)
            distance_squared = (2 * x + 1 - centre2) ** 2 + (2 * y + 1 - centre2) ** 2
            if distance_squared >= (outer + 6) ** 2:
                if state_pixel[:3] != base_pixel or state_pixel[3] != 115:
                    raise ValidationError(f"base layer corruption in {state} {size}px at {(x, y)}")
    validate_badge_masks(size, actual_core, actual_ring)


def _expected_manifest(output: Path) -> list[str]:
    entries = {relative.as_posix(): expected for relative, expected in MASTER_HASHES.items()}
    entries.update({(OUTPUT_PREFIX / relative).as_posix(): _sha256(output / relative) for relative in PAYLOAD_PATHS})
    return [f"{digest}  {path}" for path, digest in sorted(entries.items())]


def write_manifest(output: Path) -> None:
    lines = _expected_manifest(output)
    if len(lines) != 19:
        raise ValidationError(f"manifest line count is {len(lines)}, expected 19")
    (output / MANIFEST_PATH).write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def generate(output: Path) -> None:
    validate_sources()
    output.mkdir(mode=0o755)
    (output / SVG_PATH).write_bytes(monochrome_svg())
    images: dict[Path, object] = {}
    for relative, (size, variant) in UNBADGED.items():
        image = render_mark(size, variant)
        images[relative] = image
        save_png(image, output / relative)
    for relative, (size, state) in STATE_PATHS.items():
        image = render_state(images[Path(f"ext-{size}.png")], size, state)
        images[relative] = image
        save_png(image, output / relative)
    review = build_review_sheet(images)
    images[REVIEW_PATH] = review
    save_png(review, output / REVIEW_PATH)
    write_manifest(output)
    validate_output(output)


def validate_output(output: Path) -> None:
    from PIL import Image, ImageChops

    symlinks = [path.relative_to(output) for path in output.rglob("*") if path.is_symlink()]
    if symlinks:
        raise ValidationError(f"output contains symlinks: {sorted(symlinks, key=str)}")
    actual = {path.relative_to(output) for path in output.rglob("*") if path.is_file()}
    directories = {path.relative_to(output) for path in output.rglob("*") if path.is_dir()}
    if actual != OUTPUT_PATHS or directories != {Path("state"), Path("review")}:
        raise ValidationError(
            f"output inventory mismatch; missing={sorted(OUTPUT_PATHS - actual, key=str)}, extra={sorted(actual - OUTPUT_PATHS, key=str)}"
        )
    if (output / SVG_PATH).read_bytes() != monochrome_svg():
        raise ValidationError("monochrome SVG mismatch")

    rendered: dict[Path, object] = {}
    for relative, (size, variant) in UNBADGED.items():
        mode = "RGB" if variant == "full" else "RGBA"
        validate_png(output / relative, (size, size), mode)
        with Image.open(output / relative) as decoded:
            decoded.load()
            image = decoded.copy()
        validate_raster_oracle(image, size, variant)
        rendered[relative] = image
        if variant == "full":
            edge = (
                [image.getpixel((x, 0)) for x in range(size)]
                + [image.getpixel((x, size - 1)) for x in range(size)]
                + [image.getpixel((0, y)) for y in range(size)]
                + [image.getpixel((size - 1, y)) for y in range(size)]
            )
            if any(pixel != PEACH[:3] for pixel in edge):
                raise ValidationError(f"opaque outer edge mismatch: {relative}")
        else:
            edge_alpha = (
                [image.getpixel((x, 0))[3] for x in range(size)]
                + [image.getpixel((x, size - 1))[3] for x in range(size)]
                + [image.getpixel((0, y))[3] for y in range(size)]
                + [image.getpixel((size - 1, y))[3] for y in range(size)]
            )
            if any(edge_alpha):
                raise ValidationError(f"transparent outer edge mismatch: {relative}")
    for relative, (size, state) in STATE_PATHS.items():
        validate_png(output / relative, (size, size), "RGBA")
        with Image.open(output / relative) as decoded:
            decoded.load()
            image = decoded.copy()
        validate_state_image(image, rendered[Path(f"ext-{size}.png")], size, state)
        rendered[relative] = image

    validate_png(output / REVIEW_PATH, (1600, 1200), "RGB")
    expected_review = build_review_sheet(rendered)
    with Image.open(output / REVIEW_PATH) as decoded_review:
        decoded_review.load()
        if ImageChops.difference(decoded_review, expected_review).getbbox() is not None:
            raise ValidationError("review sheet mismatch")

    manifest = (output / MANIFEST_PATH).read_bytes()
    if not manifest.endswith(b"\n") or b"\r" in manifest:
        raise ValidationError("manifest must use LF and final newline")
    lines = manifest.decode("utf-8").splitlines()
    expected_lines = _expected_manifest(output)
    paths = [line.split("  ", 1)[1] for line in lines if "  " in line]
    if len(lines) != 19 or paths != sorted(paths) or lines != expected_lines:
        raise ValidationError("manifest coverage/hash mismatch")
    if any("SHA256SUMS" in line or "review-evidence.md" in line for line in lines):
        raise ValidationError("manifest contains excluded path")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--print-toolchain", action="store_true")
    modes.add_argument("--check-sources", action="store_true")
    modes.add_argument("--check", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args(argv)
    if args.output and (args.print_toolchain or args.check_sources):
        parser.error("--output is only valid for generation or --check")
    if args.check and not args.output:
        parser.error("--check requires --output PATH")
    if not args.output and not (args.print_toolchain or args.check_sources):
        parser.error("generation requires --output PATH")
    return args


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
        fingerprint = verify_toolchain()
        if args.print_toolchain:
            print(json.dumps(fingerprint, sort_keys=True, separators=(",", ":")))
        elif args.check_sources:
            validate_sources()
            print("sources/oracle: OK")
        elif args.check:
            output = validate_output_path(args.output, existing=True)
            validate_sources()
            validate_output(output)
            print(f"output check: OK: {output}")
        else:
            output = validate_output_path(args.output, existing=False)
            generate(output)
            print(f"generated: {output}")
        return 0
    except (ValidationError, OSError, ET.ParseError, ValueError) as error:
        print(f"app icon family: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
