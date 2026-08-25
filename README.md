# Scrcpy Workspace

A multi-platform workspace integrating the core [scrcpy](https://github.com/Genymobile/scrcpy) C library and the [scrcpy_flutter_plugin](https://github.com/anhkiet-201/scrcpy_flutter_plugin) Flutter FFI plugin, with cross-platform build support (macOS, Linux, Windows) and GPU hardware acceleration (HWACCEL).

---

## 📁 Workspace Structure

```text
scrcpy/ (Workspace Root)
├── .build/                         # Intermediate build artifacts directory (git-ignored)
├── build_deps.sh                   # Script to statically build dav1d, SDL3, and FFmpeg (macOS & Linux)
├── build_dylib.sh                  # Compatibility alias for the macOS XCFramework build
├── build_server_release.sh         # Script to build scrcpy-server JAR
├── build_shared_lib_linux.sh       # Script to build libscrcpy_ffi.so for Linux
├── build_shared_lib_macos.sh       # Script to build libscrcpy_ffi.xcframework for macOS
├── build_shared_lib_windows.ps1    # PowerShell script to build libscrcpy_ffi.dll for Windows
├── scrcpy/                         # [Git Submodule] C scrcpy core library & server
└── scrcpy_flutter_plugin/          # [Git Submodule] Flutter FFI plugin & demo app
```

---

## 🖥️ Supported Host Operating Systems & CPU Architectures

| Host Operating System | Supported CPU Architectures | Native Binary Output | Hardware Acceleration (GPU) | Native Audio Backend |
| :--- | :--- | :--- | :--- | :--- |
| **macOS** (11.0+) | `arm64` (Apple Silicon) | `libscrcpy_ffi.xcframework` | VideoToolbox (H.264, HEVC, AV1) | CoreAudio (SDL3) |
| **Linux** (Ubuntu/Debian) | `x86_64`, `aarch64` | `libscrcpy_ffi.so` | VA-API / DRM | PipeWire / PulseAudio / ALSA (SDL3) |
| **Windows** (10/11) | `x86_64` (x64) | `scrcpy_ffi.dll` | D3D11VA / DXVA2 | WASAPI (SDL3) |

---

## 🛠️ Prerequisites & System Requirements

### 1. General Build Tools
- **Git**
- **CMake** (>= 3.16)
- **Ninja** & **Meson** (used for compiling dav1d and SDL3)
- **Pkg-config**
- **Yasm** / **Nasm** (for FFmpeg assembly optimizations)
- **Flutter SDK** (>= 3.0.0) & Dart SDK

### 2. OS-Specific Requirements

- **macOS**:
  - Xcode Command Line Tools (`xcode-select --install`)
  - Homebrew packages: `brew install cmake meson ninja pkg-config yasm`

- **Linux (Ubuntu/Debian)**:
  - `sudo apt update && sudo apt install -y build-essential cmake meson ninja-build pkg-config yasm libva-dev libdrm-dev`

- **Windows**:
  - Visual Studio 2022 (with C++ Desktop Development workload) or LLVM/Clang
  - PowerShell 7+

---

## 🔄 Initializing Submodules

When cloning this workspace repository for the first time, make sure to fetch all Git Submodules:

```bash
git clone --recursive <WORKSPACE_REPO_URL>
cd scrcpy
```

If you have already cloned the repository without submodules:

```bash
git submodule update --init --recursive
```

---

## ⚙️ Shared FFI Library Build Instructions

The build scripts automatically compile static dependencies (`dav1d`, `SDL3`, and GPU-accelerated `FFmpeg`) and package them into a shared FFI library placed directly inside the Flutter plugin directory.

### 1. macOS (`libscrcpy_ffi.xcframework`)
```bash
chmod +x build_shared_lib_macos.sh build_deps.sh
./build_shared_lib_macos.sh
```
*Output:* `scrcpy_flutter_plugin/macos/scrcpy_flutter_plugin/Frameworks/libscrcpy_ffi.xcframework`

### 2. Linux (`libscrcpy_ffi.so`)
```bash
chmod +x build_shared_lib_linux.sh build_deps.sh
./build_shared_lib_linux.sh
```
*Output:* `scrcpy_flutter_plugin/linux/libscrcpy_ffi.so`

### 3. Windows (`scrcpy_ffi.dll`)
Open PowerShell as Administrator or Developer PowerShell:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\build_shared_lib_windows.ps1
```
*Output:* `scrcpy_flutter_plugin/windows/scrcpy_ffi.dll`

### 4. Build `scrcpy-server` (Optional - when updating Server APK/JAR)
```bash
chmod +x build_server_release.sh
./build_server_release.sh
```

---

## 🚀 Running the Flutter Example App

After building the shared library for your target platform:

```bash
cd scrcpy_flutter_plugin/example
flutter pub get
flutter run
```

---

## 📄 License

This project complies with open-source software licenses, primarily the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0), as governed by individual components.
