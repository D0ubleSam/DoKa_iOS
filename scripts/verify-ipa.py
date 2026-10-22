#!/usr/bin/env python3
"""Validate a Doka device app/IPA without claiming that it was runtime tested."""

import argparse
import hashlib
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath


def validate_resources(read_resource):
    manifest = json.loads((Path(__file__).resolve().parents[1] / "docs/lut-manifest.json").read_text(encoding="utf-8"))
    records = manifest["luts"]
    if len(records) != 24:
        raise ValueError("Expected a manifest for 24 LUTs")
    for record in records:
        data = read_resource(f"LUTs/{record['id']}.rgb8")
        if len(data) != 64 ** 3 * 3 or hashlib.sha256(data).hexdigest() != record["rgb8_sha256"]:
            raise ValueError(f"Missing or damaged bundled LUT: {record['id']}")
    return len(records)


def validate_macho(data):
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Executable is not a thin little-endian 64-bit Mach-O")
    _, cpu, _, filetype, command_count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if cpu != 0x0100000C or filetype != 2:
        raise ValueError("Expected an arm64 Mach-O executable")
    end = 32 + command_bytes
    if end > len(data):
        raise ValueError("Truncated Mach-O load commands")
    offset, platforms = 32, []
    for _ in range(command_count):
        if offset + 8 > end:
            raise ValueError("Truncated Mach-O command")
        command, size = struct.unpack_from("<2I", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError("Invalid Mach-O command size")
        if command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError("Truncated LC_BUILD_VERSION")
            platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS, older SDKs
            if size < 16:
                raise ValueError("Truncated LC_VERSION_MIN_IPHONEOS")
            platforms.append(2)
        elif command == 0x1D:  # LC_CODE_SIGNATURE
            if size < 16 or struct.unpack_from("<I", data, offset + 12)[0] != 0:
                raise ValueError("Executable already contains a code signature")
        offset += size
    if offset != end or not platforms or any(value != 2 for value in platforms):
        raise ValueError("Executable must target iOS devices; simulator/macOS binaries are rejected")
    return {"architecture": "arm64", "platform": "iOS device", "mach_o": True}


def validate_plist(info):
    expected = {"CFBundleIdentifier": "com.doublesam.doka.ios", "CFBundlePackageType": "APPL"}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Unexpected {key}: {info.get(key)!r}")
    executable = info.get("CFBundleExecutable", "")
    if not executable or "/" in executable or "\\" in executable or "$" in executable:
        raise ValueError("Missing or unresolved executable name")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("Info.plist does not describe an iPhoneOS device build")
    for key in ("NSCameraUsageDescription", "NSPhotoLibraryAddUsageDescription", "MinimumOSVersion"):
        if not info.get(key):
            raise ValueError(f"Missing {key}")
    return executable


def verify(path):
    if path.is_dir() and path.suffix == ".app":
        info = plistlib.loads((path / "Info.plist").read_bytes())
        executable = validate_plist(info)
        binary = (path / executable).read_bytes()
        if (path / "_CodeSignature").exists() or (path / "embedded.mobileprovision").exists():
            raise ValueError("Expected an unsigned app without embedded signature/profile")
        result = validate_macho(binary)
        result["verified_luts"] = validate_resources(lambda name: (path / name).read_bytes())
    elif path.is_file() and path.suffix.lower() == ".ipa":
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() is not None:
                raise ValueError("IPA ZIP integrity check failed")
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise ValueError("Duplicate ZIP entries")
            for name in names:
                entry = PurePosixPath(name)
                if entry.is_absolute() or ".." in entry.parts or "\\" in name:
                    raise ValueError("Unsafe ZIP member path")
            roots = {name.split("/")[1] for name in names if name.startswith("Payload/") and len(name.split("/")) > 2}
            if roots != {"Doka.app"}:
                raise ValueError("Expected exactly Payload/Doka.app")
            prefix = "Payload/Doka.app/"
            info = plistlib.loads(archive.read(prefix + "Info.plist"))
            executable = validate_plist(info)
            if any(name.startswith(prefix + "_CodeSignature/") or name == prefix + "embedded.mobileprovision" for name in names):
                raise ValueError("Expected an unsigned IPA without embedded signature/profile")
            binary = archive.read(prefix + executable)
            result = validate_macho(binary)
            result["verified_luts"] = validate_resources(lambda name: archive.read(prefix + name))
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        result["sha256"] = digest.hexdigest()
    else:
        raise ValueError("Provide a built .app directory or .ipa file")
    result.update({"path": str(path.resolve()), "bundle_id": info["CFBundleIdentifier"],
                   "minimum_ios": info["MinimumOSVersion"], "unsigned": True,
                   "runtime_tested": False})
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    arguments = parser.parse_args()
    try:
        print(json.dumps(verify(arguments.path), indent=2))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"Validation failed: {error}", file=sys.stderr)
        sys.exit(1)
