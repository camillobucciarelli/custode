from __future__ import annotations

import hashlib
import os
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib
from decimal import Decimal
from pathlib import Path

from PIL import Image

from tool import build_app_icon_family as icons

PYTHON = icons.REPO / ".dart_tool/app_icon_host/venv/bin/python"
GENERATOR = icons.REPO / "tool/build_app_icon_family.py"
BOOTSTRAP = icons.REPO / "tool/bootstrap_app_icon_host.sh"
EXPECTED_OUTPUTS = {
    Path("SHA256SUMS"),
    Path("app-192.png"),
    Path("app-512.png"),
    Path("ext-128.png"),
    Path("ext-16.png"),
    Path("ext-32.png"),
    Path("ext-48.png"),
    Path("custode-adaptive-foreground-1024.png"),
    Path("custode-mark-monochrome.svg"),
    Path("custode-monochrome-1024.png"),
    Path("custode-source-1024.png"),
    Path("review/app-icon-family-review.png"),
    Path("state/ext-16-locked.png"),
    Path("state/ext-16-nohost.png"),
    Path("state/ext-32-locked.png"),
    Path("state/ext-32-nohost.png"),
    Path("state/ext-48-locked.png"),
    Path("state/ext-48-nohost.png"),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_cli(*args: object, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(PYTHON), str(GENERATOR), *(str(arg) for arg in args)],
        cwd=icons.REPO,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def rewrite_manifest(output: Path) -> None:
    entries = {
        "specs/_design/custode-mark.svg": sha256(icons.REPO / "specs/_design/custode-mark.svg"),
        "specs/_design/custode-mark-foreground.svg": sha256(
            icons.REPO / "specs/_design/custode-mark-foreground.svg"
        ),
    }
    for relative in EXPECTED_OUTPUTS - {Path("SHA256SUMS")}:
        entries[(Path("assets/logo/app_icon_family") / relative).as_posix()] = sha256(output / relative)
    (output / "SHA256SUMS").write_text(
        "\n".join(f"{digest}  {path}" for path, digest in sorted(entries.items())) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def add_png_chunk(path: Path, name: bytes, payload: bytes) -> None:
    data = path.read_bytes()
    offset = 8
    while data[offset + 4 : offset + 8] != b"IDAT":
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        offset += length + 12
    chunk = struct.pack(">I", len(payload)) + name + payload + struct.pack(">I", zlib.crc32(name + payload) & 0xFFFFFFFF)
    path.write_bytes(data[:offset] + chunk + data[offset:])


class GeometryOracleTest(unittest.TestCase):
    def test_transform_strokes_bboxes_and_signed_distances(self) -> None:
        geometry = icons.validate_sources()
        self.assertEqual(icons.transform_point(Decimal(74), Decimal(26)), (Decimal(68), Decimal(32)))
        self.assertEqual(geometry["ring"], (Decimal(23),) * 2 + (Decimal(77),) * 2)
        self.assertEqual(
            geometry["hand"],
            (Decimal("46.25"), Decimal("28.25"), Decimal("71.75"), Decimal("53.75")),
        )
        self.assertEqual(
            icons.union_bbox(geometry.values()),
            (Decimal(23), Decimal(23), Decimal(77), Decimal(77)),
        )
        self.assertEqual(
            icons.signed_distance_annulus(
                Decimal(50), Decimal("26.75"), Decimal(50), Decimal(50), Decimal("23.25"), Decimal("3.75")
            ),
            Decimal("-3.75"),
        )
        self.assertEqual(
            icons.signed_distance_round_segment(
                Decimal(68), Decimal(28), Decimal(50), Decimal(50), Decimal(68), Decimal(32), Decimal("3.75")
            ),
            Decimal("0.25"),
        )

    def test_fractional_ranges_and_quantization(self) -> None:
        ranges = icons.fractional_probe_ranges(16)
        self.assertEqual(set(ranges), set(icons.COMPONENTS))
        self.assertTrue(all(1 <= minimum <= maximum <= 255 for minimum, maximum in ranges.values()))
        self.assertEqual(icons.pixel_for_point(16, (Decimal("73.25"), Decimal(50))), (11, 8))
        self.assertEqual(icons.pixel_for_point(1024, (Decimal(23), Decimal(77))), (235, 788))

    def test_independent_masks_accept_documented_geometry(self) -> None:
        for size in (16, 32, 48, 128, 192, 512, 1024):
            icons.validate_component_mask_sets(size, icons.analytic_component_masks(size))

    def test_component_mutations_fail_at_48_and_1024(self) -> None:
        for size in (48, 1024):
            with self.subTest(size=size, mutation="collapsed"):
                masks = icons.analytic_component_masks(size)
                masks["ring"] = set()
                with self.assertRaises(icons.ValidationError):
                    icons.validate_component_mask_sets(size, masks)

            with self.subTest(size=size, mutation="shifted"):
                masks = icons.analytic_component_masks(size)
                delta = 3 if size == 48 else 8
                masks["hand"] = {
                    index + delta
                    for index in masks["hand"]
                    if index % size + delta < size
                }
                with self.assertRaises(icons.ValidationError):
                    icons.validate_component_mask_sets(size, masks)

            with self.subTest(size=size, mutation="oversized"):
                masks = icons.analytic_component_masks(size)
                delta = 3 if size == 48 else 8
                expanded = set(masks["hub"])
                for index in tuple(expanded):
                    x, y = index % size, index // size
                    for dx, dy in ((delta, 0), (-delta, 0), (0, delta), (0, -delta)):
                        if 0 <= x + dx < size and 0 <= y + dy < size:
                            expanded.add((y + dy) * size + x + dx)
                masks["hub"] = expanded
                with self.assertRaises(icons.ValidationError):
                    icons.validate_component_mask_sets(size, masks)

            with self.subTest(size=size, mutation="cropped"):
                masks = icons.analytic_component_masks(size)
                midpoint = int(73.25 * size / 100)
                masks["east"] = {index for index in masks["east"] if index % size < midpoint}
                with self.assertRaises(icons.ValidationError):
                    icons.validate_component_mask_sets(size, masks)


class BadgeGeometryTest(unittest.TestCase):
    def test_badge_ring_and_core_mutations_fail_at_every_size(self) -> None:
        for size in (16, 32, 48):
            core, ring = icons.expected_badge_masks(size)
            icons.validate_badge_masks(size, set(core), set(ring))
            centre2 = int(icons.BADGES[size][4] * 2)

            for horizontal, vertical in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
                with self.subTest(size=size, mutation="missing-quadrant", quadrant=(horizontal, vertical)):
                    missing_quadrant = {
                        index
                        for index in ring
                        if not (
                            (1 if 2 * (index % size) + 1 >= centre2 else -1) == horizontal
                            and (1 if 2 * (index // size) + 1 >= centre2 else -1) == vertical
                        )
                    }
                    with self.assertRaises(icons.ValidationError):
                        icons.validate_badge_masks(size, set(core), missing_quadrant)

            with self.subTest(size=size, mutation="shifted-ring"):
                shifted_ring = {
                    index + 1 for index in ring if index % size + 1 < size
                }
                with self.assertRaises(icons.ValidationError):
                    icons.validate_badge_masks(size, set(core), shifted_ring)

            with self.subTest(size=size, mutation="lopsided-ring"):
                lopsided_ring = {
                    index for index in ring if 2 * (index % size) + 1 < centre2
                }
                with self.assertRaises(icons.ValidationError):
                    icons.validate_badge_masks(size, set(core), lopsided_ring)

            with self.subTest(size=size, mutation="collapsed-core"):
                with self.assertRaises(icons.ValidationError):
                    icons.validate_badge_masks(size, set(), set(ring))

            with self.subTest(size=size, mutation="shifted-core"):
                shifted_core = {
                    index + 1 for index in core if index % size + 1 < size
                }
                with self.assertRaises(icons.ValidationError):
                    icons.validate_badge_masks(size, shifted_core, set(ring))


class OutputPathSafetyTest(unittest.TestCase):
    def test_absent_leaf_and_existing_check_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            leaf = parent / "new-leaf"
            self.assertEqual(icons.validate_output_path(leaf, existing=False), leaf)
            leaf.mkdir()
            self.assertEqual(icons.validate_output_path(leaf, existing=True), leaf)
            with self.assertRaises(icons.ValidationError):
                icons.validate_output_path(leaf, existing=False)

    def test_rejects_special_files_symlinks_and_dangling_links(self) -> None:
        for path in (Path("/"), Path.home().resolve(), icons.REPO, icons.REPO / ".git"):
            with self.assertRaises(icons.ValidationError):
                icons.validate_output_path(path, existing=True)
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "target"
            target.mkdir()
            link = parent / "link"
            link.symlink_to(target, target_is_directory=True)
            dangling = parent / "dangling"
            dangling.symlink_to(parent / "missing", target_is_directory=True)
            for path, existing in (
                (link, True),
                (link / "child", False),
                (dangling, True),
                (dangling, False),
                (f"{link}/../leaf", False),
                (f"{link}/../target", True),
            ):
                with self.subTest(path=path, existing=existing):
                    with self.assertRaises(icons.ValidationError):
                        icons.validate_output_path(path, existing=existing)

    def test_cli_rejects_symlink_traversal_for_generation_and_check(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "target"
            target.mkdir()
            link = parent / "link"
            link.symlink_to(target, target_is_directory=True)
            generation = run_cli("--output", f"{link}/../new-output")
            check = run_cli("--check", "--output", f"{link}/../target")
            self.assertNotEqual(generation.returncode, 0)
            self.assertNotEqual(check.returncode, 0)
            self.assertFalse((parent / "new-output").exists())

    def test_cli_rejects_dangling_link_and_accepts_canonical_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            dangling = parent / "dangling"
            dangling.symlink_to(parent / "missing", target_is_directory=True)
            self.assertNotEqual(run_cli("--output", dangling).returncode, 0)
            output = parent / "safe-output"
            generated = run_cli("--output", output)
            self.assertEqual(generated.returncode, 0, generated.stderr)
            checked = run_cli("--check", "--output", output)
            self.assertEqual(checked.returncode, 0, checked.stderr)


class ToolchainAttestationTest(unittest.TestCase):
    def test_valid_cli_and_bootstrap_subprocesses(self) -> None:
        printed = run_cli("--print-toolchain")
        self.assertEqual(printed.returncode, 0, printed.stderr)
        bootstrapped = subprocess.run(
            [str(BOOTSTRAP)], cwd=icons.REPO, text=True, capture_output=True, check=False
        )
        self.assertEqual(bootstrapped.returncode, 0, bootstrapped.stderr)

    def test_system_python_and_pythonpath_spoof_fail(self) -> None:
        lock = __import__("json").loads((icons.REPO / "tool/app_icon_host.lock.json").read_text(encoding="utf-8"))
        system = subprocess.run(
            [lock["python"]["executable"], str(GENERATOR), "--print-toolchain"],
            cwd=icons.REPO,
            env={key: value for key, value in os.environ.items() if key not in ("PYTHONPATH", "PYTHONHOME")},
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(system.returncode, 0)
        with tempfile.TemporaryDirectory() as temporary:
            env = os.environ.copy()
            env["PYTHONPATH"] = temporary
            spoofed = run_cli("--print-toolchain", env=env)
            self.assertNotEqual(spoofed.returncode, 0)
            bootstrap = subprocess.run(
                [str(BOOTSTRAP)], cwd=icons.REPO, env=env, text=True, capture_output=True, check=False
            )
            self.assertNotEqual(bootstrap.returncode, 0)


class GeneratedTreeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        icons.verify_toolchain()
        cls.temporary = tempfile.TemporaryDirectory()
        cls.parent = Path(cls.temporary.name).resolve()
        cls.run_a = icons.validate_output_path(cls.parent / "run-a", existing=False)
        icons.generate(cls.run_a)
        cls.run_b = icons.validate_output_path(cls.parent / "run-b", existing=False)
        icons.generate(cls.run_b)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def test_two_fresh_runs_are_byte_identical(self) -> None:
        files_a = sorted(path.relative_to(self.run_a) for path in self.run_a.rglob("*") if path.is_file())
        files_b = sorted(path.relative_to(self.run_b) for path in self.run_b.rglob("*") if path.is_file())
        self.assertEqual(files_a, files_b)
        for relative in files_a:
            self.assertEqual((self.run_a / relative).read_bytes(), (self.run_b / relative).read_bytes(), relative)

    def test_exact_inventory_and_independent_manifest_hashes(self) -> None:
        files = {path.relative_to(self.run_a) for path in self.run_a.rglob("*") if path.is_file()}
        self.assertEqual(files, EXPECTED_OUTPUTS)
        lines = (self.run_a / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 19)
        parsed: dict[str, str] = {}
        for line in lines:
            match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
            self.assertIsNotNone(match, line)
            assert match is not None
            parsed[match.group(2)] = match.group(1)
        expected_paths = {
            "specs/_design/custode-mark.svg",
            "specs/_design/custode-mark-foreground.svg",
            *(
                (Path("assets/logo/app_icon_family") / relative).as_posix()
                for relative in EXPECTED_OUTPUTS - {Path("SHA256SUMS")}
            ),
        }
        self.assertEqual(set(parsed), expected_paths)
        for manifest_path, digest in parsed.items():
            path = icons.REPO / manifest_path if manifest_path.startswith("specs/") else self.run_a / Path(manifest_path).relative_to("assets/logo/app_icon_family")
            self.assertEqual(digest, sha256(path), manifest_path)

    def test_metadata_corruption_is_rejected_before_manifest_can_hide_it(self) -> None:
        mutated = self.parent / "metadata-corrupt"
        shutil.copytree(self.run_a, mutated)
        add_png_chunk(mutated / "app-192.png", b"tIME", b"\x07\xe8\x01\x01\x00\x00\x00")
        rewrite_manifest(mutated)
        with self.assertRaisesRegex(icons.ValidationError, "metadata"):
            icons.validate_output(mutated)

    def test_state_geometry_corruption_is_rejected(self) -> None:
        mutated = self.parent / "state-corrupt"
        shutil.copytree(self.run_a, mutated)
        path = mutated / "state/ext-32-locked.png"
        with Image.open(path) as source:
            image = source.copy()
        image.putpixel((26, 26), (0, 0, 0, 0))
        icons.save_png(image, path)
        rewrite_manifest(mutated)
        with self.assertRaisesRegex(icons.ValidationError, "badge core"):
            icons.validate_output(mutated)

    def test_16px_all_and_individual_probe_erasure_is_rejected(self) -> None:
        with Image.open(self.run_a / "ext-16.png") as source:
            original = source.copy()
        under = {
            "ring": icons.PEACH[:3],
            "hand": icons.PEACH[:3],
            "hub": icons.PEACH[:3],
            "north": icons.ORANGE[:3],
            "east": icons.ORANGE[:3],
            "south": icons.ORANGE[:3],
            "west": icons.ORANGE[:3],
        }
        icons.validate_size_16_probes(original)

        erased = original.copy()
        for component, point in icons.PROBE_POINTS.items():
            erased.putpixel(icons.pixel_for_point(16, point), under[component])
        with self.assertRaisesRegex(icons.ValidationError, "probe coverage"):
            icons.validate_size_16_probes(erased)

        for component, point in icons.PROBE_POINTS.items():
            with self.subTest(component=component):
                erased_one = original.copy()
                erased_one.putpixel(icons.pixel_for_point(16, point), under[component])
                with self.assertRaisesRegex(icons.ValidationError, component):
                    icons.validate_size_16_probes(erased_one)

    def test_review_sheet_exposes_monochrome_alpha_on_checkerboard(self) -> None:
        with Image.open(self.run_a / "review/app-icon-family-review.png") as sheet:
            crop = sheet.crop((40, 590, 216, 766))
            colours = crop.getcolors(maxcolors=100000)
        self.assertIsNotNone(colours)
        assert colours is not None
        self.assertGreater(len(colours), 3)
        self.assertIn((255, 255, 255), {colour for _count, colour in colours})
        self.assertIn((226, 226, 226), {colour for _count, colour in colours})


if __name__ == "__main__":
    unittest.main()
