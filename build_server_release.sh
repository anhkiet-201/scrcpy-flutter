#!/usr/bin/env bash
# build_server_release.sh — Build scrcpy server in release mode and copy it to plugin assets

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRCPY_DIR="$SCRIPT_DIR/scrcpy"
ASSETS_DIR="$SCRIPT_DIR/scrcpy_flutter_plugin/assets"

mkdir -p "$ASSETS_DIR"

echo "Building scrcpy server in release mode..."
cd "$SCRCPY_DIR"
./gradlew :server:assembleRelease

# Find the output APK (could be named server-release.apk or server-release-unsigned.apk)
APK_PATH=""
for f in "$SCRCPY_DIR/server/build/outputs/apk/release"/*.apk; do
    if [ -f "$f" ]; then
        APK_PATH="$f"
        break
    fi
done

if [ -z "$APK_PATH" ]; then
    echo "❌ Error: Could not find built release APK in $SCRCPY_DIR/server/build/outputs/apk/release"
    exit 1
fi

echo "Copying built APK from: $APK_PATH"
cp "$APK_PATH" "$ASSETS_DIR/scrcpy-server"

echo "✅ Done: $ASSETS_DIR/scrcpy-server"
