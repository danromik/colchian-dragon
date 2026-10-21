#!/bin/bash
# Builds Colchian Dragon.app into ./build.
#
#   scripts/build-app.sh                      # release build, ad-hoc signed (for local use)
#   CONFIG=debug scripts/build-app.sh         # debug build
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#                                             # signed with hardened runtime, ready to notarize
#   ARCHS="arm64" scripts/build-app.sh        # single-architecture build (default: universal)
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCHS="${ARCHS:-arm64 x86_64}"
NAME="Colchian Dragon"
APP="build/$NAME.app"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

swift build -c "$CONFIG" "${arch_flags[@]}"
bin_path="$(swift build -c "$CONFIG" "${arch_flags[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin_path/Colchian" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($CONFIG, $ARCHS, signed with: $SIGN_IDENTITY)"
