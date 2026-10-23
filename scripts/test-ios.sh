#!/bin/bash
# macOS + Xcode + XcodeGen + Python 3. Optional first argument: xcodebuild destination.
# Example: bash scripts/test-ios.sh 'platform=iOS Simulator,id=SIMULATOR-UUID'
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [xcodebuild-destination]\n' "$0" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'iOS XCTest requires macOS and full Xcode. Tests have not run.' >&2
  exit 1
fi
for tool in xcodebuild xcrun xcodegen python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$tool" >&2
    exit 1
  fi
done
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
bash "$PROJECT_ROOT/scripts/generate-project.sh"

mkdir -p "$PROJECT_ROOT/work/tests"
TEST_RUN="$(mktemp -d "$PROJECT_ROOT/work/tests/ios.XXXXXX")"
TEST_DESTINATION="${1:-${DESTINATION:-}}"
if [[ -z "$TEST_DESTINATION" ]]; then
  xcrun simctl list devices available --json > "$TEST_RUN/simulators.json"
  TEST_DESTINATION="$(python3 - "$TEST_RUN/simulators.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    devices = json.load(source)["devices"]
candidates = []
for runtime, entries in devices.items():
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match.group(1).split("-"))
    if version < (17,):
        continue
    for device in entries:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            candidates.append((device.get("state") == "Booted", version, device["name"], device["udid"]))
if not candidates:
    sys.exit("No available iPhone simulator with iOS 17 or later. Install one in Xcode Settings > Platforms.")
print("platform=iOS Simulator,id=" + max(candidates)[3])
PY
)"
fi

printf 'Test destination: %s\nTest output: %s\n' "$TEST_DESTINATION" "$TEST_RUN"
xcodebuild \
  -project "$PROJECT_ROOT/Doka.xcodeproj" \
  -scheme Doka \
  -configuration Debug \
  -destination "$TEST_DESTINATION" \
  -derivedDataPath "$TEST_RUN/DerivedData" \
  -resultBundlePath "$TEST_RUN/DokaTests.xcresult" \
  -only-testing:DokaTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  test 2>&1 | tee "$TEST_RUN/xcodebuild.log"
printf 'XCTest passed. Result bundle: %s\n' "$TEST_RUN/DokaTests.xcresult"
