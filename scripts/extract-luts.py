#!/usr/bin/env python3
"""Convert the 24 fixed APK LUT PNGs to RGB8 cubes. Requires Pillow."""

import argparse
import hashlib
import io
import json
import os
import tempfile
import zipfile
from pathlib import Path

from PIL import Image


LUT_NAMES = (
    "lut_agfa_ap_100", "lut_agfa_vista_800", "lut_doka_s100", "lut_doka_s160",
    "lut_doka_s200", "lut_doka_s400", "lut_doka_s50", "lut_doka_x100",
    "lut_doka_x400", "lut_f_160c", "lut_f_400h", "lut_f_c200", "lut_f_cc",
    "lut_f_classic_chrome", "lut_f_classic_neg", "lut_f_cn", "lut_f_pro_neg",
    "lut_f_provia", "lut_f_s100", "lut_f_s400", "lut_f_velvia",
    "lut_k_gold_200", "lut_k_portra_160", "lut_k_portra_400",
)
CUBE_DIMENSION = 64
PNG_DIMENSIONS = (512, 512)
MAX_PNG_BYTES = 8 * 1024 * 1024


def png_to_cube(png_bytes):
    """R varies fastest; alpha is discarded, never composited/premultiplied."""
    with Image.open(io.BytesIO(png_bytes)) as image:
        if image.format != "PNG" or image.size != PNG_DIMENSIONS:
            raise ValueError("Each LUT must be a 512 by 512 PNG")
        # convert('RGB') discards an RGBA alpha channel without compositing it.
        rgb = image.convert("RGB").tobytes()
    output = bytearray(CUBE_DIMENSION ** 3 * 3)
    row_bytes = CUBE_DIMENSION * 3
    for blue in range(CUBE_DIMENSION):
        tile_x, tile_y = blue % 8 * 64, blue // 8 * 64
        for green in range(CUBE_DIMENSION):
            source = ((tile_y + green) * 512 + tile_x) * 3
            target = (blue * 64 * 64 + green * 64) * 3
            output[target:target + row_bytes] = rgb[source:source + row_bytes]
    return bytes(output)


def safe_output_path(root, relative):
    root = root.resolve()
    result = (root / relative).resolve()
    if not result.is_relative_to(root):
        raise ValueError("Output path must remain within the project directory")
    return result


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".lut-", delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def extract_luts(apk, project_root):
    """Read only exact allowlisted archive members; never extract archive paths."""
    apk, project_root = Path(apk), Path(project_root).resolve()
    converted, manifest_items = [], []
    with apk.open("rb") as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
        source.seek(0)
        with zipfile.ZipFile(source) as archive:
            entries = archive.namelist()
            for name in LUT_NAMES:
                member = f"assets/luts/{name}.png"
                if entries.count(member) != 1:
                    raise ValueError(f"Expected exactly one archive member: {member}")
                if archive.getinfo(member).file_size > MAX_PNG_BYTES:
                    raise ValueError(f"LUT PNG is unexpectedly large: {member}")
                png = archive.read(member)
                cube = png_to_cube(png)
                relative = f"Doka/Resources/LUTs/{name}.rgb8"
                converted.append((safe_output_path(project_root, relative), cube))
                manifest_items.append({
                    "id": name, "source_member": member,
                    "png_sha256": hashlib.sha256(png).hexdigest(),
                    "png_dimensions": list(PNG_DIMENSIONS),
                    "output": relative, "rgb8_sha256": hashlib.sha256(cube).hexdigest(),
                    "rgb8_bytes": len(cube), "cube_dimension": CUBE_DIMENSION,
                })
    manifest = {
        "schema_version": 1,
        "source_apk_name": apk.name,
        "source_apk_sha256": digest.hexdigest(),
        "cube_dimension": CUBE_DIMENSION,
        "format": "RGB8, R fastest, G second, B third; PNG alpha discarded",
        "mapping": "cube[(b*64*64+g*64+r)*3] = PNG[(b%8)*64+r, (b//8)*64+g].rgb",
        "luts": manifest_items,
    }
    manifest_path = safe_output_path(project_root, "docs/lut-manifest.json")
    # Validate and convert all inputs before modifying any resource.
    for destination, cube in converted:
        atomic_write(destination, cube)
    atomic_write(manifest_path, (json.dumps(manifest, indent=2) + "\n").encode("utf-8"))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path, help="Explicit path to the source APK (required)")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    try:
        result = extract_luts(args.apk, project)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, f"LUT conversion failed: {error}\n")
    print(f"Converted {len(result['luts'])} LUTs to {project / 'Doka/Resources/LUTs'}")
    print(f"Source APK SHA-256: {result['source_apk_sha256']}")
