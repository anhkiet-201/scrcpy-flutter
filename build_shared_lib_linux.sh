#!/usr/bin/env bash
# build_shared_lib_linux.sh — Build libscrcpy_ffi shared library for Linux
# Output: scrcpy_flutter_plugin/linux/lib/libscrcpy_ffi.so

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="linux"
PLUGIN_SRC="$SCRIPT_DIR/scrcpy_flutter_plugin/src"
LOCAL_DEPS="$SCRIPT_DIR/.build/$PLATFORM/libs"
BUILD_TEMP="$SCRIPT_DIR/.build/$PLATFORM/deps_build"
LIB_EXT="so"
OUTPUT_DIR="$SCRIPT_DIR/scrcpy_flutter_plugin/linux/lib"
BUILD_DIR="$SCRIPT_DIR/.build/$PLATFORM/target"
FFMPEG_CONFIG="$BUILD_TEMP/ffmpeg/config_components.h"

echo "🖥️  Platform : Linux"
echo "📦 Output   : $OUTPUT_DIR/libscrcpy_ffi.$LIB_EXT"

ffmpeg_gpu_ready() {
    [ -f "$FFMPEG_CONFIG" ] \
        && grep -q '^#define CONFIG_HWACCELS 1$' "$BUILD_TEMP/ffmpeg/config.h" \
        && grep -q '^#define CONFIG_H264_VAAPI_HWACCEL 1$' "$FFMPEG_CONFIG" \
        && grep -q '^#define CONFIG_HEVC_VAAPI_HWACCEL 1$' "$FFMPEG_CONFIG" \
        && grep -q '^#define CONFIG_AV1_VAAPI_HWACCEL 1$' "$FFMPEG_CONFIG"
}

# Không đóng gói .so khi FFmpeg hiện có chỉ giải mã CPU.
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
    -DLOCAL_DEPS_DIR="$LOCAL_DEPS"

echo "Building target scrcpy_ffi..."
cmake --build "$BUILD_DIR" --target scrcpy_ffi --parallel

echo "Copying built library to $OUTPUT_DIR..."
cp "$BUILD_DIR/lib/libscrcpy_ffi.$LIB_EXT" "$OUTPUT_DIR/libscrcpy_ffi.$LIB_EXT"

echo "✅ Done: $OUTPUT_DIR/libscrcpy_ffi.$LIB_EXT"
