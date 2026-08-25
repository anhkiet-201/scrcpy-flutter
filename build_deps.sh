#!/usr/bin/env bash
# build_deps.sh — Tự biên dịch tĩnh dav1d, SDL3, và FFmpeg cho plugin
# Hỗ trợ: macOS (Darwin) và Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/scrcpy/app/deps/work/sources"

# ---------------------------------------------------------------------------
# Detect platform
# ---------------------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)
        echo "❌ Unsupported OS: $OS"
        exit 1
        ;;
esac
echo "🖥️  Platform: $PLATFORM"

LOCAL_DEPS="$SCRIPT_DIR/.build/$PLATFORM/libs"
BUILD_TEMP="$SCRIPT_DIR/.build/$PLATFORM/deps_build"

# Số CPU cores (cross-platform)
if [ "$PLATFORM" = "macos" ]; then
    NUM_CORES="$(sysctl -n hw.ncpu)"
else
    NUM_CORES="$(nproc)"
fi

rm -rf "$LOCAL_DEPS" "$BUILD_TEMP"
mkdir -p "$LOCAL_DEPS" "$BUILD_TEMP"

# 1. Biên dịch dav1d
echo "Building dav1d..."
mkdir -p "$BUILD_TEMP/dav1d"
cd "$BUILD_TEMP/dav1d"
meson setup "$SOURCES_DIR/dav1d-1.5.3" \
  --buildtype=release \
  --default-library=static \
  --prefix="$LOCAL_DEPS" \
  -Denable_tests=false \
  -Denable_tools=false
ninja install

# 2. Biên dịch SDL3
echo "Building SDL3..."
cd "$BUILD_TEMP"
if [ ! -d "SDL" ]; then
    git clone --depth 1 --branch release-3.4.12 https://github.com/libsdl-org/SDL.git
fi
cd "$BUILD_TEMP/SDL"
sed -i.bak 's/#define SDL_DYNAMIC_API 1/#define SDL_DYNAMIC_API 0/g' "$BUILD_TEMP/SDL/src/dynapi/SDL_dynapi.h"

SDL_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DSDL_SHARED=OFF
    -DSDL_STATIC=ON
    -DSDL_DYNAMIC_API=OFF
    -DSDL_AUDIO=ON
    -DSDL_TESTS=OFF
    -DSDL_EXAMPLES=OFF
    -DCMAKE_INSTALL_PREFIX="$LOCAL_DEPS"
)
if [ "$PLATFORM" = "macos" ]; then
    SDL_CMAKE_ARGS+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="11.0")
else
    # Build all common Linux output backends. Shared loading keeps the FFI
    # bundle portable: SDL selects PipeWire, PulseAudio or ALSA at runtime.
    SDL_CMAKE_ARGS+=(
        -DSDL_PIPEWIRE=ON
        -DSDL_PIPEWIRE_SHARED=ON
        -DSDL_PULSEAUDIO=ON
        -DSDL_PULSEAUDIO_SHARED=ON
        -DSDL_ALSA=ON
        -DSDL_ALSA_SHARED=ON
    )
fi

cmake -S "$BUILD_TEMP/SDL" -B "$BUILD_TEMP/sdl_build" "${SDL_CMAKE_ARGS[@]}"
cmake --build "$BUILD_TEMP/sdl_build" --target install --parallel "$NUM_CORES"

# 3. Biên dịch FFmpeg (không cần swscale vì dùng GPU)
echo "Building FFmpeg..."
mkdir -p "$BUILD_TEMP/ffmpeg"
cd "$BUILD_TEMP/ffmpeg"
export PKG_CONFIG_PATH="$LOCAL_DEPS/lib/pkgconfig"

EXTRA_CFLAGS="-O3 -fPIC"
FFMPEG_HW_ARGS=()
FFMPEG_REQUIRED_HWACCELS=()
if [ "$PLATFORM" = "macos" ]; then
    EXTRA_CFLAGS="$EXTRA_CFLAGS -mmacosx-version-min=11.0"
    FFMPEG_HW_ARGS=(
        --enable-videotoolbox
        --enable-hwaccel=h264_videotoolbox
        --enable-hwaccel=hevc_videotoolbox
        --enable-hwaccel=av1_videotoolbox
    )
    FFMPEG_REQUIRED_HWACCELS=(
        H264_VIDEOTOOLBOX
        HEVC_VIDEOTOOLBOX
        AV1_VIDEOTOOLBOX
    )
elif [ "$PLATFORM" = "linux" ]; then
    # VAAPI surfaces are exported as DMA-BUF and imported by FlTextureGL.
    # Keep FFmpeg's decoded pixels on the same GPU as the Flutter renderer.
    FFMPEG_HW_ARGS=(
        --enable-vaapi
        --enable-libdrm
        --enable-hwaccel=h264_vaapi
        --enable-hwaccel=hevc_vaapi
        --enable-hwaccel=av1_vaapi
    )
    FFMPEG_REQUIRED_HWACCELS=(
        H264_VAAPI
        HEVC_VAAPI
        AV1_VAAPI
    )
fi

"$SOURCES_DIR/ffmpeg-8.1.2/configure" \
  --prefix="$LOCAL_DEPS" \
  --extra-cflags="$EXTRA_CFLAGS" \
  --disable-programs \
  --disable-doc \
  --disable-everything \
  --enable-static \
  --disable-shared \
  --disable-swscale \
  --enable-swresample \
  --enable-libdav1d \
  --enable-decoder=h264 \
  --enable-decoder=hevc \
  --enable-decoder=av1 \
  --enable-decoder=pcm_s16le \
  --enable-decoder=opus \
  --enable-decoder=aac \
  --enable-decoder=flac \
  --enable-decoder=png \
  --enable-protocol=file \
  --enable-demuxer=image2 \
  --enable-parser=png \
  --enable-zlib \
  --enable-muxer=matroska \
  --enable-muxer=mp4 \
  --enable-muxer=opus \
  --enable-muxer=flac \
  --enable-muxer=wav \
  --disable-avdevice \
  "${FFMPEG_HW_ARGS[@]}" \
  --pkg-config-flags="--static"

# --disable-everything disables all hwaccels by default. Do not allow a
# successful configure to silently produce a CPU-only FFmpeg archive: the FFI
# intentionally rejects software decoded frames.
FFMPEG_COMPONENTS_CONFIG="$BUILD_TEMP/ffmpeg/config_components.h"
if ! grep -q '^#define CONFIG_HWACCELS 1$' "$BUILD_TEMP/ffmpeg/config.h"; then
    echo "❌ FFmpeg was configured without hardware acceleration"
    exit 1
fi
for hwaccel in "${FFMPEG_REQUIRED_HWACCELS[@]}"; do
    if ! grep -q "^#define CONFIG_${hwaccel}_HWACCEL 1$" "$FFMPEG_COMPONENTS_CONFIG"; then
        echo "❌ Required FFmpeg hardware accelerator is disabled: $hwaccel"
        exit 1
    fi
done

make -j"$NUM_CORES" install

echo "✅ Dependencies built successfully in: $LOCAL_DEPS"
