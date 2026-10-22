#!/bin/bash
# Requires macOS, full Xcode, XcodeGen and Python 3. Produces an unsigned device IPA.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'iOS compilation requires macOS and the iPhoneOS SDK from Xcode.' >&2
  printf '%s\n' 'No IPA has been generated. Run this script on a Mac or the prepared macOS workflow.' >&2
  exit 1
fi
for tool in xcodebuild xcrun xcodegen python3 ditto shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$tool" >&2
    exit 1
  fi
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null
xcodebuild -version
bash "$PROJECT_ROOT/scripts/generate-project.sh"

# Each build gets a new directory: stale products cannot be packaged accidentally.
mkdir -p "$PROJECT_ROOT/work/build" "$PROJECT_ROOT/artifacts"
BUILD_RUN="$(mktemp -d "$PROJECT_ROOT/work/build/unsigned.XXXXXX")"
DERIVED_DATA="$BUILD_RUN/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/Doka.app"
IPA_PATH="$BUILD_RUN/Doka-unsigned.ipa"

xcodebuild \
  -project "$PROJECT_ROOT/Doka.xcodeproj" \
  -scheme Doka \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  build 2>&1 | tee "$BUILD_RUN/xcodebuild.log"

python3 "$PROJECT_ROOT/scripts/verify-ipa.py" "$APP_PATH"
mkdir -p "$BUILD_RUN/package/Payload"
ditto "$APP_PATH" "$BUILD_RUN/package/Payload/Doka.app"
(
  cd "$BUILD_RUN/package"
  ditto -c -k --norsrc --keepParent Payload "$IPA_PATH"
)
python3 "$PROJECT_ROOT/scripts/verify-ipa.py" "$IPA_PATH" > "$BUILD_RUN/verification.json"
cat "$BUILD_RUN/verification.json"
cp "$IPA_PATH" "$PROJECT_ROOT/artifacts/Doka-unsigned.ipa"
cp "$BUILD_RUN/verification.json" "$PROJECT_ROOT/artifacts/Doka-unsigned.verification.json"
(
  cd "$PROJECT_ROOT/artifacts"
  shasum -a 256 Doka-unsigned.ipa > Doka-unsigned.ipa.sha256
)
printf '\nUnsigned IPA: %s\n' "$PROJECT_ROOT/artifacts/Doka-unsigned.ipa"
printf 'Build log: %s\n' "$BUILD_RUN/xcodebuild.log"
printf '%s\n' 'This IPA must be signed for your device before installation.'
