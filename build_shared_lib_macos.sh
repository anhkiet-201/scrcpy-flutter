#!/usr/bin/env bash
# build_shared_lib_macos.sh — Build the libscrcpy_ffi XCFramework for macOS
# Output: scrcpy_flutter_plugin/macos/scrcpy_flutter_plugin/Frameworks/libscrcpy_ffi.xcframework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="macos"
PLUGIN_SRC="$SCRIPT_DIR/scrcpy_flutter_plugin/src"
LOCAL_DEPS="$SCRIPT_DIR/.build/$PLATFORM/libs"
BUILD_TEMP="$SCRIPT_DIR/.build/$PLATFORM/deps_build"
OUTPUT_DIR="$SCRIPT_DIR/scrcpy_flutter_plugin/macos/scrcpy_flutter_plugin/Frameworks"
BUILD_DIR="$SCRIPT_DIR/.build/$PLATFORM/target"
FFMPEG_CONFIG="$BUILD_TEMP/ffmpeg/config_components.h"
XCFRAMEWORK="$OUTPUT_DIR/libscrcpy_ffi.xcframework"

echo "🖥️  Platform : macOS"
echo "📦 Output   : $XCFRAMEWORK"

ffmpeg_gpu_ready() {
    [ -f "$FFMPEG_CONFIG" ] \
        && grep -q '^#define CONFIG_HWACCELS 1$' "$BUILD_TEMP/ffmpeg/config.h" \
        && grep -q '^#define CONFIG_H264_VIDEOTOOLBOX_HWACCEL 1$' "$FFMPEG_CONFIG" \
        && grep -q '^#define CONFIG_HEVC_VIDEOTOOLBOX_HWACCEL 1$' "$FFMPEG_CONFIG" \
        && grep -q '^#define CONFIG_AV1_VIDEOTOOLBOX_HWACCEL 1$' "$FFMPEG_CONFIG"
}

# Không đóng gói dylib khi FFmpeg hiện có chỉ giải mã CPU.
if [ ! -f "$LOCAL_DEPS/lib/libavcodec.a" ] \
        || [ ! -f "$LOCAL_DEPS/lib/libSDL3.a" ] \
        || ! ffmpeg_gpu_ready; then
    echo "GPU FFmpeg dependency missing or stale. Compiling it now..."
    "$SCRIPT_DIR/build_deps.sh"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "Configuring CMake build..."
cmake \
    -S "$PLUGIN_SRC" \
    -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLOCAL_DEPS_DIR="$LOCAL_DEPS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="11.0"

echo "Building target scrcpy_ffi..."
cmake --build "$BUILD_DIR" --target scrcpy_ffi --parallel

echo "Creating xcframework for Swift Package Manager..."
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/lib/libscrcpy_ffi.dylib" \
    -output "$XCFRAMEWORK"

echo "✅ Done: $XCFRAMEWORK"
