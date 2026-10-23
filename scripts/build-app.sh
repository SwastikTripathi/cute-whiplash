#!/usr/bin/env bash
# Builds Whiplash.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Whiplash.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Whiplash" "$APP/Contents/MacOS/Whiplash"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
# Sign with the stable local identity (scripts/signing.sh) so macOS keeps the Screen Recording grant across
# rebuilds. Falls back to ad-hoc, which macOS treats as a brand-new app after every rebuild.
# (Quiet on success: codesign always says it replaced the linker's signature.)
if IDENTITY="$(scripts/signing.sh 2>/dev/null)" && [ -n "$IDENTITY" ]; then
    SIGN=(--sign "$IDENTITY" --keychain "$PWD/.signing/whiplash.keychain-db")
else
    echo "warning: no local signing identity; signing ad-hoc (Screen Recording will be re-asked after rebuilds)" >&2
    SIGN=(--sign -)
fi
if ! out="$(codesign --force "${SIGN[@]}" --timestamp=none "$APP" 2>&1)"; then
    echo "$out" >&2
    exit 1
fi
echo "Built $APP"
