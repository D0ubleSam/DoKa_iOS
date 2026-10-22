"""CPU reference checks; actual Core Image/device rendering still needs macOS/iOS."""

import hashlib
import importlib.util
import io
import itertools
import json
import math
import os
from pathlib import Path
import random
import tempfile
import unittest
import zipfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("extract_luts", ROOT / "scripts/extract-luts.py")
EXTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXTRACT)


def encode_png(image):
    stream = io.BytesIO()
    image.save(stream, format="PNG")
    return stream.getvalue()


def clamp(value, low=0.0, high=1.0):
    return min(high, max(low, value))


def glsl_lut(pixels, color):
    """Original applyLut + normalized GL_LINEAR texture2D, in PNG row order."""
    red, green, blue = [clamp(value) for value in color]
    blue_index = blue * 63
    first = math.floor(blue_index)
    second = min(first + 1, 63)

    def texture2d(slice_index):
        u = ((slice_index % 8) * 64 + red * 63 + 0.5) / 512
        v = ((slice_index // 8) * 64 + green * 63 + 0.5) / 512
        x, y = u * 512 - 0.5, v * 512 - 0.5
        left, top = math.floor(x), math.floor(y)
        dx, dy = x - left, y - top
        value = [0.0, 0.0, 0.0]
        for ox, oy in itertools.product((0, 1), repeat=2):
            pixel = pixels[min(left + ox, 511), min(top + oy, 511)]
            weight = (dx if ox else 1 - dx) * (dy if oy else 1 - dy)
            for channel in range(3):
                value[channel] += pixel[channel] / 255.0 * weight
        return value

    a, b = texture2d(first), texture2d(second)
    fraction = blue_index - first
    return [x * (1 - fraction) + y * fraction for x, y in zip(a, b)]


def cube_trilinear(cube, color):
    """Independent eight-corner interpolation of R-fastest CIColorCube values."""
    position = [clamp(value) * 63 for value in color]
    lower = [math.floor(value) for value in position]
    fraction = [value - index for value, index in zip(position, lower)]
    output = [0.0, 0.0, 0.0]
    for corners in itertools.product((0, 1), repeat=3):
        indices = [min(low + corner, 63) for low, corner in zip(lower, corners)]
        weight = math.prod(frac if corner else 1 - frac for frac, corner in zip(fraction, corners))
        index = (indices[2] * 4096 + indices[1] * 64 + indices[0]) * 3
        for channel in range(3):
            output[channel] += cube[index + channel] / 255.0 * weight
    return output


def glsl_palette(color, tone, chroma, amount):
    """Sequential operations copied mathematically from applyPalette, including luma order."""
    tone, chroma, amount = clamp(tone, -1, 1), clamp(chroma, -1, 1), clamp(amount)
    graded = [value * 2 ** (tone * 0.18) for value in color]
    luma = sum(value * weight for value, weight in zip(graded, (0.299, 0.587, 0.114)))
    contrast = max(0.68, 1 - tone * 0.16)
    graded = [(value - 0.5) * contrast + 0.5 for value in graded]
    saturation = 1 + chroma * 0.42
    graded = [luma + (value - luma) * saturation for value in graded]
    return [clamp(original * (1 - amount) + changed * amount)
            for original, changed in zip(color, graded)]


def affine_palette(color, tone, chroma, amount):
    """FilterEngine's CIColorMatrix coefficients, followed by CIColorClamp."""
    t, c, a = clamp(tone, -1, 1), clamp(chroma, -1, 1), clamp(amount)
    exposure, contrast, saturation = 2 ** (t * 0.18), max(0.68, 1 - t * 0.16), 1 + c * 0.42
    diagonal = 1 - a + a * exposure * contrast * saturation
    luma = a * exposure * (1 - saturation)
    bias = a * 0.5 * (1 - contrast) * saturation
    weights = [luma * value for value in (0.299, 0.587, 0.114)]
    matrix = [[weight + (diagonal if row == column else 0)
               for column, weight in enumerate(weights)] for row in range(3)]
    return [clamp(sum(value * coefficient for value, coefficient in zip(color, row)) + bias)
            for row in matrix]


class SyntheticLUTTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pixels = bytearray(512 * 512 * 4)
        expected = bytearray()
        for blue, green, red in itertools.product(range(64), repeat=3):
            value = tuple(round(channel * 255 / 63) for channel in (red, green, blue))
            expected.extend(value)
            x, y = blue % 8 * 64 + red, blue // 8 * 64 + green
            index = (y * 512 + x) * 4
            pixels[index:index + 4] = bytes((*value, (red * 3 + green * 5 + blue * 7) % 256))
        cls.identity = Image.frombytes("RGBA", (512, 512), bytes(pixels))
        cls.expected = bytes(expected)

    def test_identity_axes_and_every_point(self):
        cube = EXTRACT.png_to_cube(encode_png(self.identity))
        self.assertEqual(cube, self.expected)
        self.assertEqual(len(cube), 64 ** 3 * 3)

    def test_alpha_is_ignored_even_when_zero(self):
        transparent = self.identity.copy()
        transparent.putalpha(0)
        self.assertEqual(EXTRACT.png_to_cube(encode_png(transparent)), self.expected)
        self.assertEqual(EXTRACT.png_to_cube(encode_png(self.identity.convert("RGB"))), self.expected)

    def test_identity_interpolation(self):
        cube = EXTRACT.png_to_cube(encode_png(self.identity))
        for color in ((0, 0, 0), (1, 1, 1), (0.13, 0.41, 0.79), (0.9, 0.3, 0.1)):
            for actual, expected in zip(cube_trilinear(cube, color), color):
                self.assertAlmostEqual(actual, expected, delta=1 / 255)

    def test_wrong_dimensions_rejected(self):
        with self.assertRaises(ValueError):
            EXTRACT.png_to_cube(encode_png(Image.new("RGB", (64, 64))))

    def test_archive_allowlist_and_manifest(self):
        png = encode_png(self.identity)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apk = root / "sample.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                for name in EXTRACT.LUT_NAMES:
                    archive.writestr(f"assets/luts/{name}.png", png)
                archive.writestr("assets/luts/../../escaped.txt", "must never extract")
            result = EXTRACT.extract_luts(apk, root / "project")
            self.assertEqual(len(result["luts"]), 24)
            self.assertEqual(result["source_apk_sha256"], hashlib.sha256(apk.read_bytes()).hexdigest())
            self.assertFalse((root / "project/escaped.txt").exists())
            outputs = list((root / "project").rglob("*.rgb8"))
            self.assertEqual(len(outputs), 24)
            self.assertTrue(all(path.read_bytes() == self.expected for path in outputs))
            for item in result["luts"]:
                self.assertEqual(item["png_sha256"], hashlib.sha256(png).hexdigest())
                self.assertEqual(item["rgb8_sha256"], hashlib.sha256(self.expected).hexdigest())
            with self.assertRaises(ValueError):
                EXTRACT.safe_output_path(root / "project", "../outside.rgb8")

    def test_missing_lut_does_not_write_partial_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apk = root / "missing.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr(f"assets/luts/{EXTRACT.LUT_NAMES[0]}.png", encode_png(self.identity))
            with self.assertRaises(ValueError):
                EXTRACT.extract_luts(apk, root / "project")
            self.assertFalse((root / "project").exists())


class ActualLUTTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("DOKA_SOURCE_APK"), "Set DOKA_SOURCE_APK explicitly to verify the real APK")
    def test_all_24_luts_match_glsl_sampling_and_manifest(self):
        source = Path(os.environ["DOKA_SOURCE_APK"])
        manifest = json.loads((ROOT / "docs/lut-manifest.json").read_text())
        self.assertEqual(manifest["source_apk_sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
        records = {item["id"]: item for item in manifest["luts"]}
        rng = random.Random(20261022)
        colors = list(itertools.product((0.0, 0.5, 1.0), repeat=3))
        # Include tile boundaries, near-white and clamped out-of-range input.
        colors += [(0.23, 0.71, value / 63) for value in (7, 8, 15, 16, 55, 56, 63)]
        colors += [(rng.random(), rng.random(), rng.random()) for _ in range(100)]
        colors += [(-0.2, 1.2, 0.5), (0.999999, 0.999999, 0.999999)]
        self.assertEqual(set(records), set(EXTRACT.LUT_NAMES))
        with zipfile.ZipFile(source) as archive:
            for name in EXTRACT.LUT_NAMES:
                with self.subTest(lut=name):
                    png = archive.read(f"assets/luts/{name}.png")
                    image = Image.open(io.BytesIO(png)).convert("RGB")
                    cube = (ROOT / f"Doka/Resources/LUTs/{name}.rgb8").read_bytes()
                    self.assertEqual(hashlib.sha256(png).hexdigest(), records[name]["png_sha256"])
                    self.assertEqual(hashlib.sha256(cube).hexdigest(), records[name]["rgb8_sha256"])
                    self.assertEqual(len(cube), 64 ** 3 * 3)
                    for color in colors:
                        expected = glsl_lut(image.load(), color)
                        actual = cube_trilinear(cube, color)
                        for left, right in zip(expected, actual):
                            self.assertAlmostEqual(left, right, delta=1e-12)


class PaletteTests(unittest.TestCase):
    def test_affine_matches_original_shader_order_and_clamp(self):
        rng = random.Random(721)
        cases = [(color, t, c, amount)
                 for color in itertools.product((0.0, 0.5, 1.0), repeat=3)
                 for t, c, amount in itertools.product((-1, 0, 1), (-1, 0, 1), (0, 0.5, 1))]
        cases += [(tuple(rng.uniform(-0.25, 1.25) for _ in range(3)),
                   rng.uniform(-2, 2), rng.uniform(-2, 2), rng.uniform(-1, 2)) for _ in range(1000)]
        for color, tone, chroma, amount in cases:
            expected = glsl_palette(color, tone, chroma, amount)
            actual = affine_palette(color, tone, chroma, amount)
            for left, right in zip(expected, actual):
                self.assertAlmostEqual(left, right, delta=1e-12)


if __name__ == "__main__":
    unittest.main()
