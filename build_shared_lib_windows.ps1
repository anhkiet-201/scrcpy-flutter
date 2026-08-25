#Requires -Version 5.1

<#
.SYNOPSIS
Build scrcpy_ffi.dll with a project-local LLVM/MinGW toolchain.

.PARAMETER Architecture
Target architecture. The default is x64.

.PARAMETER NoDependencyInstall
Do not build missing dependencies with vcpkg.
#>
[CmdletBinding()]
param(
    [ValidateSet("x64", "arm64")]
    [string] $Architecture = "x64",

    [switch] $NoDependencyInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function ConvertTo-CMakePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # CMake writes some explicitly supplied tool paths into generated .cmake
    # files. Forward slashes prevent Windows paths such as C:\Workspace from
    # being parsed as invalid CMake escape sequences (for example, "\W").
    return $Path.Replace([char] 92, [char] 47)
}

function Save-VerifiedDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [string] $Sha256
    )

    $ExpectedHash = $Sha256.ToLowerInvariant()
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $CurrentHash = (Get-FileHash -LiteralPath $Destination `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($CurrentHash -eq $ExpectedHash) {
            return
        }

        Remove-Item -LiteralPath $Destination -Force
    }

    $DestinationDirectory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $DestinationDirectory -Force |
        Out-Null

    $Partial = "$Destination.part"
    if (Test-Path -LiteralPath $Partial) {
        Remove-Item -LiteralPath $Partial -Force
    }

    Write-Host "Downloading $Uri"
    $Curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($Curl) {
        Invoke-NativeCommand -Command $Curl.Source -Arguments @(
            "--location",
            "--fail",
            "--retry", "3",
            "--output", $Partial,
            $Uri
        )
    } else {
        Invoke-WebRequest -Uri $Uri -OutFile $Partial -UseBasicParsing
    }

    $DownloadedHash = (Get-FileHash -LiteralPath $Partial `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($DownloadedHash -ne $ExpectedHash) {
        Remove-Item -LiteralPath $Partial -Force
        throw "Checksum mismatch for $Uri"
    }

    Move-Item -LiteralPath $Partial -Destination $Destination
}

function Expand-PortableZip {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Archive,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [string] $MarkerRelativePath
    )

    $MarkerAtDestination = Join-Path $Destination $MarkerRelativePath
    if (Test-Path -LiteralPath $MarkerAtDestination -PathType Leaf) {
        return
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    $Staging = "$Destination.extracting"
    if (Test-Path -LiteralPath $Staging) {
        Remove-Item -LiteralPath $Staging -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Staging -Force | Out-Null

    try {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Staging -Force

        $MarkerName = Split-Path -Leaf $MarkerRelativePath
        $Markers = @(
            Get-ChildItem -LiteralPath $Staging -Filter $MarkerName `
                -File -Recurse
        )
        if ($Markers.Count -ne 1) {
            throw "Could not locate $MarkerRelativePath in $Archive"
        }

        $SourceRoot = $Markers[0].FullName
        foreach ($Unused in ($MarkerRelativePath -split "[\\/]")) {
            $SourceRoot = Split-Path -Parent $SourceRoot
        }

        Move-Item -LiteralPath $SourceRoot -Destination $Destination
    } finally {
        if (Test-Path -LiteralPath $Staging) {
            Remove-Item -LiteralPath $Staging -Recurse -Force
        }
    }

    if (-not (Test-Path -LiteralPath $MarkerAtDestination -PathType Leaf)) {
        throw "Portable tool extraction failed: $MarkerAtDestination"
    }
}

function Get-PortableMinGWToolchain {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TargetArchitecture,

        [Parameter(Mandatory = $true)]
        [string] $DependencyBuildRoot
    )

    $TargetPrefix = if ($TargetArchitecture -eq "arm64") {
        "aarch64-w64-mingw32"
    } else {
        "x86_64-w64-mingw32"
    }

    $IsArm64Host = $env:PROCESSOR_ARCHITECTURE -eq "ARM64" `
        -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64"
    $HostPackageArchitecture = if ($IsArm64Host) {
        "aarch64"
    } else {
        "x86_64"
    }

    $LlvmMingwVersion = "20260407"
    $LlvmMingwArchiveName = `
        "llvm-mingw-$LlvmMingwVersion-ucrt-$HostPackageArchitecture.zip"
    $LlvmMingwSha256 = if ($HostPackageArchitecture -eq "aarch64") {
        "0d2839944f1e0538502cb2d2dbf89e344c6a0af2a444a62bb066ca0cfb5ea01c"
    } else {
        "3fc6e54b5f1102089d4d37095ba49f7b24e22290da78178b514a86b3126c6d9e"
    }

    $NinjaVersion = "1.13.2"
    $NinjaArchiveName = if ($HostPackageArchitecture -eq "aarch64") {
        "ninja-winarm64.zip"
    } else {
        "ninja-win.zip"
    }
    $NinjaSha256 = if ($HostPackageArchitecture -eq "aarch64") {
        "e52f0bdef9dfb1003229dbd6508a508c4073fd017247002adc66e5e806cb0391"
    } else {
        "07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65"
    }

    $ToolsRoot = Join-Path $DependencyBuildRoot "tools"
    $DownloadsRoot = Join-Path $DependencyBuildRoot "downloads"
    $LlvmMingwArchive = Join-Path $DownloadsRoot $LlvmMingwArchiveName
    $NinjaArchive = Join-Path $DownloadsRoot $NinjaArchiveName
    $LlvmMingwRoot = Join-Path $ToolsRoot `
        "llvm-mingw-$LlvmMingwVersion-ucrt-$HostPackageArchitecture"
    $NinjaRoot = Join-Path $ToolsRoot `
        "ninja-$NinjaVersion-$HostPackageArchitecture"

    Save-VerifiedDownload `
        -Uri "https://github.com/mstorsjo/llvm-mingw/releases/download/$LlvmMingwVersion/$LlvmMingwArchiveName" `
        -Destination $LlvmMingwArchive `
        -Sha256 $LlvmMingwSha256
    Expand-PortableZip `
        -Archive $LlvmMingwArchive `
        -Destination $LlvmMingwRoot `
        -MarkerRelativePath "bin\$TargetPrefix-gcc.exe"

    Save-VerifiedDownload `
        -Uri "https://github.com/ninja-build/ninja/releases/download/v$NinjaVersion/$NinjaArchiveName" `
        -Destination $NinjaArchive `
        -Sha256 $NinjaSha256
    Expand-PortableZip `
        -Archive $NinjaArchive `
        -Destination $NinjaRoot `
        -MarkerRelativePath "ninja.exe"

    $Bin = Join-Path $LlvmMingwRoot "bin"
    $CCompiler = Join-Path $Bin "$TargetPrefix-gcc.exe"
    $CxxCompiler = Join-Path $Bin "$TargetPrefix-g++.exe"
    $RcCompiler = Join-Path $Bin "$TargetPrefix-windres.exe"
    $HostPrefix = if ($HostPackageArchitecture -eq "aarch64") {
        "aarch64-w64-mingw32"
    } else {
        "x86_64-w64-mingw32"
    }
    $HostCCompiler = Join-Path $Bin "$HostPrefix-gcc.exe"
    $Nm = Join-Path $Bin "llvm-nm.exe"
    $Ninja = Join-Path $NinjaRoot "ninja.exe"
    foreach ($RequiredTool in @(
        $CCompiler, $CxxCompiler, $RcCompiler, $HostCCompiler, $Nm, $Ninja
    )) {
        if (-not (Test-Path -LiteralPath $RequiredTool -PathType Leaf)) {
            throw "Portable build tool was not found: $RequiredTool"
        }
    }

    return [PSCustomObject] @{
        Root = $LlvmMingwRoot
        Bin = $Bin
        C = $CCompiler
        Cxx = $CxxCompiler
        Rc = $RcCompiler
        HostC = $HostCCompiler
        Nm = $Nm
        Generator = "Ninja"
        MakeProgram = $Ninja
        MakeProgramDirectory = $NinjaRoot
    }
}

function Get-SystemPowerShellShimDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $Toolchain,

        [Parameter(Mandatory = $true)]
        [string] $DependencyBuildRoot
    )

    $InstalledPwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($InstalledPwsh) {
        $InstalledPwshVersion = & $InstalledPwsh.Source --version 2>$null
        if ($InstalledPwshVersion -eq "PowerShell 7.6.2") {
            return (Split-Path -Parent $InstalledPwsh.Source)
        }
    }

    $ShimDirectory = Join-Path $DependencyBuildRoot `
        "tools\system-powershell-shim"
    $ShimSource = Join-Path $ShimDirectory "pwsh-shim.c"
    $ShimExecutable = Join-Path $ShimDirectory "pwsh.exe"
    if (Test-Path -LiteralPath $ShimExecutable -PathType Leaf) {
        return $ShimDirectory
    }

    New-Item -ItemType Directory -Path $ShimDirectory -Force | Out-Null
    $ShimCode = @'
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <wctype.h>

static const wchar_t *
skip_program_name(const wchar_t *command_line) {
    const wchar_t *p = command_line;
    while (iswspace(*p)) {
        ++p;
    }
    if (*p == L'"') {
        ++p;
        while (*p && *p != L'"') {
            ++p;
        }
        if (*p == L'"') {
            ++p;
        }
    } else {
        while (*p && !iswspace(*p)) {
            ++p;
        }
    }
    while (iswspace(*p)) {
        ++p;
    }
    return p;
}

int
wmain(int argc, wchar_t **argv) {
    if (argc == 2 && wcscmp(argv[1], L"--version") == 0) {
        /*
         * vcpkg 2026.06.24 requires this exact version only for its ABI tag.
         * Build ports do not execute PowerShell Core; other arguments are
         * forwarded to the Windows PowerShell already present on the system.
         */
        fputws(L"PowerShell 7.6.2\n", stdout);
        return 0;
    }

    wchar_t powershell[MAX_PATH];
    UINT length = GetSystemDirectoryW(powershell, MAX_PATH);
    static const wchar_t suffix[] =
        L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    if (!length || length + _countof(suffix) > MAX_PATH) {
        return 1;
    }
    wcscat_s(powershell, MAX_PATH, suffix);

    const wchar_t *tail = skip_program_name(GetCommandLineW());
    size_t command_length = wcslen(powershell) + wcslen(tail) + 6;
    wchar_t *command = malloc(command_length * sizeof(*command));
    if (!command) {
        return 1;
    }
    swprintf_s(command, command_length, L"\"%ls\" %ls", powershell, tail);

    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    BOOL created = CreateProcessW(
        powershell,
        command,
        NULL,
        NULL,
        TRUE,
        0,
        NULL,
        NULL,
        &startup,
        &process
    );
    free(command);
    if (!created) {
        return 1;
    }

    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return (int) exit_code;
}
'@
    [System.IO.File]::WriteAllText(
        $ShimSource,
        $ShimCode,
        [System.Text.Encoding]::ASCII
    )

    Write-Host "Preparing the system PowerShell adapter..."
    Invoke-NativeCommand -Command $Toolchain.HostC -Arguments @(
        "-municode",
        "-Os",
        "-s",
        "-static",
        $ShimSource,
        "-o", $ShimExecutable
    )
    if (-not (Test-Path -LiteralPath $ShimExecutable -PathType Leaf)) {
        throw "Could not create the PowerShell adapter: $ShimExecutable"
    }

    return $ShimDirectory
}

function New-FFmpegOverlayPort {
    param(
        [Parameter(Mandatory = $true)]
        [string] $VcpkgRoot,

        [Parameter(Mandatory = $true)]
        [string] $DependencyBuildRoot
    )

    $SourcePort = Join-Path $VcpkgRoot "ports\ffmpeg"
    $OverlayRoot = Join-Path $DependencyBuildRoot "vcpkg-overlay-ports"
    $OverlayPort = Join-Path $OverlayRoot "ffmpeg"
    if (Test-Path -LiteralPath $OverlayPort) {
        Remove-Item -LiteralPath $OverlayPort -Recurse -Force
    }
    New-Item -ItemType Directory -Path $OverlayRoot -Force | Out-Null
    Copy-Item -LiteralPath $SourcePort -Destination $OverlayPort `
        -Recurse -Force

    $Portfile = Join-Path $OverlayPort "portfile.cmake"
    $PortfileContents = [System.IO.File]::ReadAllText($Portfile)
    $Marker = 'message(STATUS "Building Options: ${OPTIONS}")'
    if (-not $PortfileContents.Contains($Marker)) {
        throw "Could not customize the vcpkg FFmpeg port."
    }

    $WindowsFeatureOptions = @'
# Keep the Windows build functionally aligned with build_deps.sh:
# the same decoders, muxers, demuxer, parser, protocol and zlib, with
# Direct3D/DXVA hardware decoding replacing VideoToolbox/VAAPI.
string(APPEND OPTIONS
    " --disable-everything"
    " --enable-avcodec"
    " --enable-avformat"
    " --enable-swresample"
    " --enable-swscale"
    " --disable-avdevice"
    " --disable-avfilter"
    " --enable-libdav1d"
    " --enable-zlib"
    " --enable-w32threads"
    " --enable-decoder=h264"
    " --enable-decoder=hevc"
    " --enable-decoder=av1"
    " --enable-decoder=libdav1d"
    " --enable-decoder=pcm_s16le"
    " --enable-decoder=opus"
    " --enable-decoder=aac"
    " --enable-decoder=flac"
    " --enable-decoder=png"
    " --enable-protocol=file"
    " --enable-demuxer=image2"
    " --enable-parser=png"
    " --enable-muxer=matroska"
    " --enable-muxer=mp4"
    " --enable-muxer=opus"
    " --enable-muxer=flac"
    " --enable-muxer=wav"
    " --enable-d3d11va"
    " --enable-d3d12va"
    " --enable-dxva2"
    " --enable-hwaccel=h264_d3d11va"
    " --enable-hwaccel=h264_d3d11va2"
    " --enable-hwaccel=h264_d3d12va"
    " --enable-hwaccel=h264_dxva2"
    " --enable-hwaccel=hevc_d3d11va"
    " --enable-hwaccel=hevc_d3d11va2"
    " --enable-hwaccel=hevc_d3d12va"
    " --enable-hwaccel=hevc_dxva2"
    " --enable-hwaccel=av1_d3d11va"
    " --enable-hwaccel=av1_d3d11va2"
    " --enable-hwaccel=av1_d3d12va"
    " --enable-hwaccel=av1_dxva2"
)

'@
    $PortfileContents = $PortfileContents.Replace(
        $Marker,
        "$WindowsFeatureOptions$Marker"
    )
    [System.IO.File]::WriteAllText(
        $Portfile,
        $PortfileContents,
        [System.Text.Encoding]::ASCII
    )

    return $OverlayRoot
}

function Test-MinGWDependencies {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Directory
    )

    $LibraryDirectory = Join-Path $Directory "lib"
    return (Test-Path -LiteralPath (Join-Path $LibraryDirectory "libavformat.a") -PathType Leaf) `
        -and (Test-Path -LiteralPath (Join-Path $LibraryDirectory "libavcodec.a") -PathType Leaf) `
        -and (Test-Path -LiteralPath (Join-Path $LibraryDirectory "libavutil.a") -PathType Leaf) `
        -and (Test-Path -LiteralPath (Join-Path $LibraryDirectory "libswscale.a") -PathType Leaf) `
        -and (Test-Path -LiteralPath (Join-Path $LibraryDirectory "libswresample.a") -PathType Leaf) `
        -and (Test-Path -LiteralPath (Join-Path $LibraryDirectory "libdav1d.a") -PathType Leaf) `
        -and (Test-Path -LiteralPath (Join-Path $LibraryDirectory "libzs.a") -PathType Leaf) `
        -and (Test-Path -LiteralPath (Join-Path $LibraryDirectory "libSDL3.a") -PathType Leaf)
}

function Test-WindowsFFmpegGpuSupport {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Dependencies,

        [Parameter(Mandatory = $true)]
        [string] $Nm
    )

    $Avcodec = Join-Path $Dependencies "lib\libavcodec.a"
    $Avutil = Join-Path $Dependencies "lib\libavutil.a"
    $SymbolOutput = & $Nm --defined-only $Avcodec 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    $Symbols = $SymbolOutput -join "`n"
    foreach ($RequiredSymbol in @(
        "ff_h264_d3d11va2_hwaccel",
        "ff_hevc_d3d11va2_hwaccel",
        "ff_av1_d3d11va2_hwaccel",
        "ff_dxva2_decode_init"
    )) {
        if (-not $Symbols.Contains($RequiredSymbol)) {
            return $false
        }
    }

    $SymbolOutput = & $Nm --defined-only $Avutil 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    $Symbols = $SymbolOutput -join "`n"
    if (-not $Symbols.Contains("ff_hwcontext_type_d3d11va")) {
        return $false
    }

    return $true
}

function Install-MinGWDependencies {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Triplet,

        [Parameter(Mandatory = $true)]
        [string] $InstallRoot,

        [Parameter(Mandatory = $true)]
        [string] $DependencyBuildRoot,

        [Parameter(Mandatory = $true)]
        [string] $TripletDirectory
    )

    $VcpkgVersion = "2026.06.24"
    $VcpkgRoot = Join-Path $DependencyBuildRoot "vcpkg-$VcpkgVersion"
    $VcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"

    if (-not (Test-Path -LiteralPath $VcpkgExe -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $VcpkgRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $DependencyBuildRoot -Force |
                Out-Null
            Write-Host "Downloading vcpkg $VcpkgVersion..."
            Invoke-NativeCommand -Command "git" -Arguments @(
                "clone",
                "--branch", $VcpkgVersion,
                "--depth", "1",
                "https://github.com/microsoft/vcpkg.git",
                $VcpkgRoot
            )
        }

        Write-Host "Bootstrapping vcpkg..."
        Invoke-NativeCommand `
            -Command (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat") `
            -Arguments @("-disableMetrics")
    }

    $env:VCPKG_DISABLE_METRICS = "1"
    $env:VCPKG_DEFAULT_TRIPLET = $Triplet
    $env:VCPKG_DEFAULT_HOST_TRIPLET = $Triplet
    $env:VCPKG_USE_LEGACY_APPLOCAL = "OFF"
    Remove-Item Env:VCPKG_FORCE_SYSTEM_BINARIES `
        -ErrorAction SilentlyContinue
    $env:VCPKG_DOWNLOADS = Join-Path $DependencyBuildRoot "downloads\vcpkg"
    New-Item -ItemType Directory -Path $env:VCPKG_DOWNLOADS -Force |
        Out-Null

    $OverlayPortsDirectory = New-FFmpegOverlayPort `
        -VcpkgRoot $VcpkgRoot `
        -DependencyBuildRoot $DependencyBuildRoot

    Write-Host "Building static dependencies for $Triplet..."
    Invoke-NativeCommand -Command $VcpkgExe -Arguments @(
        "install",
        "ffmpeg[core,avcodec,avformat,dav1d,swresample,swscale,zlib]:$Triplet",
        "sdl3[core]:$Triplet",
        "--host-triplet=$Triplet",
        "--x-install-root=$InstallRoot",
        "--overlay-triplets=$TripletDirectory",
        "--overlay-ports=$OverlayPortsDirectory",
        "--recurse",
        "--allow-unsupported",
        "--clean-after-build"
    )
}

if ($env:OS -ne "Windows_NT") {
    throw "This script must be run on Windows."
}
$CMakeCommand = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $CMakeCommand) {
    throw "CMake was not found in PATH."
}
$CMakeExecutable = $CMakeCommand.Source

$ScriptDirectory = $PSScriptRoot
$PluginSource = Join-Path $ScriptDirectory "scrcpy_flutter_plugin\src"
$PlatformRoot = Join-Path $ScriptDirectory ".build\windows"
$WindowsDependenciesRoot = Join-Path $PlatformRoot "libs"
$VcpkgInstallRoot = Join-Path $WindowsDependenciesRoot "vcpkg_installed"
$Triplet = if ($Architecture -eq "arm64") {
    "arm64-llvm-mingw-static"
} else {
    "x64-llvm-mingw-static"
}
$Dependencies = Join-Path $VcpkgInstallRoot $Triplet
$DependencyBuildRoot = Join-Path $PlatformRoot "deps_build"
$TripletDirectory = Join-Path $DependencyBuildRoot "vcpkg-triplets"
$BuildDirectory = Join-Path $PlatformRoot "target_$Architecture"
$RuntimeDirectory = Join-Path $BuildDirectory "lib"
$OutputDirectory = Join-Path $ScriptDirectory "scrcpy_flutter_plugin\windows"
$OutputDll = Join-Path $OutputDirectory "scrcpy_ffi.dll"
$OutputImportLibrary = Join-Path `
    $OutputDirectory "scrcpy_ffi.dll.a"

$Toolchain = Get-PortableMinGWToolchain `
    -TargetArchitecture $Architecture `
    -DependencyBuildRoot $DependencyBuildRoot
$PowerShellShimDirectory = Get-SystemPowerShellShimDirectory `
    -Toolchain $Toolchain `
    -DependencyBuildRoot $DependencyBuildRoot
$env:Path = "$PowerShellShimDirectory;$($Toolchain.Bin);$($Toolchain.MakeProgramDirectory);$env:Path"

$VcpkgArchitecture = if ($Architecture -eq "arm64") {
    "arm64"
} else {
    "x64"
}
New-Item -ItemType Directory -Path $TripletDirectory -Force | Out-Null
$TripletFile = Join-Path $TripletDirectory "$Triplet.cmake"
$TripletContents = @"
set(VCPKG_TARGET_ARCHITECTURE $VcpkgArchitecture)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_ENV_PASSTHROUGH PATH)
set(VCPKG_CMAKE_SYSTEM_NAME MinGW)
set(VCPKG_USE_LEGACY_APPLOCAL OFF)
"@
[System.IO.File]::WriteAllText(
    $TripletFile,
    $TripletContents,
    [System.Text.Encoding]::ASCII
)

$DependenciesReady = Test-MinGWDependencies -Directory $Dependencies
$GpuReady = $DependenciesReady -and (
    Test-WindowsFFmpegGpuSupport `
        -Dependencies $Dependencies `
        -Nm $Toolchain.Nm
)
if (-not $DependenciesReady -or -not $GpuReady) {
    if ($NoDependencyInstall) {
        throw "Release dependencies with D3D11VA support were not found: $Dependencies"
    }
    Install-MinGWDependencies `
        -Triplet $Triplet `
        -InstallRoot $VcpkgInstallRoot `
        -DependencyBuildRoot $DependencyBuildRoot `
        -TripletDirectory $TripletDirectory
}
if (-not (Test-MinGWDependencies -Directory $Dependencies)) {
    throw "Dependencies are incomplete: $Dependencies"
}
if (-not (Test-WindowsFFmpegGpuSupport `
            -Dependencies $Dependencies `
            -Nm $Toolchain.Nm)) {
    throw "FFmpeg was built without complete H.264/HEVC/AV1 D3D11VA decoder and hardware-context support."
}

Write-Host "Platform     : Windows ($Architecture)"
Write-Host "Toolchain    : $($Toolchain.Root)"
Write-Host "Compiler     : $($Toolchain.C)"
Write-Host "Generator    : $($Toolchain.Generator)"
Write-Host "Dependencies : $Dependencies"
Write-Host "Output       : $OutputDll"

if (Test-Path -LiteralPath $BuildDirectory) {
    Remove-Item -LiteralPath $BuildDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$WindowsCompatibilityHeader = Join-Path `
    $BuildDirectory "windows_build_compat.h"
$WindowsCompatibilitySource = @'
#ifndef SCRCPY_FFI_WINDOWS_BUILD_COMPAT_H
#define SCRCPY_FFI_WINDOWS_BUILD_COMPAT_H

#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

/*
 * FFmpeg 8 exposes the D3D11 hardware pixel format as AV_PIX_FMT_D3D11.
 * Keep the plugin's older spelling source-compatible without editing it.
 */
#ifndef AV_PIX_FMT_D3D11VA
#define AV_PIX_FMT_D3D11VA AV_PIX_FMT_D3D11
#endif

/*
 * The plugin's ADB reference counter uses a POSIX mutex. Map that tiny API
 * surface to the native Windows exclusive SRW lock supplied by llvm-mingw.
 */
typedef SRWLOCK pthread_mutex_t;
#ifndef PTHREAD_MUTEX_INITIALIZER
#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT
#endif

static inline int
pthread_mutex_lock(pthread_mutex_t *mutex) {
    AcquireSRWLockExclusive(mutex);
    return 0;
}

static inline int
pthread_mutex_unlock(pthread_mutex_t *mutex) {
    ReleaseSRWLockExclusive(mutex);
    return 0;
}
#endif

#endif
'@
[System.IO.File]::WriteAllText(
    $WindowsCompatibilityHeader,
    $WindowsCompatibilitySource,
    [System.Text.Encoding]::ASCII
)

$SystemLinkLibraries = @(
    "advapi32", "bcrypt", "cfgmgr32", "crypt32", "d3d11", "d3d12",
    "dinput8", "dxgi", "dxguid", "dxva2", "hid", "mf", "mfplat",
    "mfreadwrite", "mfuuid", "ncrypt", "psapi", "secur32", "strmiids",
    "user32", "userenv", "uxtheme", "wbemuuid", "windowscodecs"
) | ForEach-Object { "-l$_" }
$ZlibLibrary = ConvertTo-CMakePath -Path (
    Join-Path $Dependencies "lib\libzs.a"
)
$SystemLinkLibraries += $ZlibLibrary

$CMakePluginSource = ConvertTo-CMakePath -Path $PluginSource
$CMakeBuildDirectory = ConvertTo-CMakePath -Path $BuildDirectory
$CMakeRuntimeDirectory = ConvertTo-CMakePath -Path $RuntimeDirectory
$CMakeDependencies = ConvertTo-CMakePath -Path $Dependencies
$CMakeCCompiler = ConvertTo-CMakePath -Path $Toolchain.C
$CMakeCxxCompiler = ConvertTo-CMakePath -Path $Toolchain.Cxx
$CMakeRcCompiler = ConvertTo-CMakePath -Path $Toolchain.Rc
$CMakeMakeProgram = ConvertTo-CMakePath -Path $Toolchain.MakeProgram
$CMakeCompatibilityHeader = ConvertTo-CMakePath `
    -Path $WindowsCompatibilityHeader

$WindowsCommandSource = Join-Path `
    $ScriptDirectory "scrcpy\app\src\util\command.c"
if (-not (Test-Path -LiteralPath $WindowsCommandSource -PathType Leaf)) {
    throw "Windows command serializer source was not found: $WindowsCommandSource"
}
$CMakeWindowsCommandSource = ConvertTo-CMakePath `
    -Path $WindowsCommandSource
$CMakeProjectOverlay = Join-Path `
    $BuildDirectory "windows_build_overlay.cmake"
$CMakeProjectOverlaySource = @"
# Generated by build_shared_lib_windows.ps1. Project sources stay untouched.
# Match the runtime name loaded by Dart: scrcpy_ffi.dll (without MinGW's
# default "lib" prefix). The generated import library refers to this name.
set(CMAKE_SHARED_LIBRARY_PREFIX "")

cmake_language(DEFER CALL target_sources scrcpy_core PRIVATE
    "$CMakeWindowsCommandSource"
)
"@
[System.IO.File]::WriteAllText(
    $CMakeProjectOverlay,
    $CMakeProjectOverlaySource,
    [System.Text.Encoding]::ASCII
)
$CMakeProjectOverlay = ConvertTo-CMakePath -Path $CMakeProjectOverlay

$ConfigureArguments = @(
    "-G", $Toolchain.Generator,
    "-S", $CMakePluginSource,
    "-B", $CMakeBuildDirectory,
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_C_COMPILER=$CMakeCCompiler",
    "-DCMAKE_CXX_COMPILER=$CMakeCxxCompiler",
    "-DCMAKE_RC_COMPILER=$CMakeRcCompiler",
    "-DCMAKE_MAKE_PROGRAM=$CMakeMakeProgram",
    "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=$CMakeRuntimeDirectory",
    "-DLOCAL_DEPS_DIR=$CMakeDependencies",
    "-DCMAKE_C_FLAGS=-include $CMakeCompatibilityHeader",
    "-DCMAKE_PROJECT_INCLUDE=$CMakeProjectOverlay",
    "-DCMAKE_C_STANDARD_LIBRARIES=$($SystemLinkLibraries -join ' ')",
    "-DCMAKE_CXX_STANDARD_LIBRARIES=$($SystemLinkLibraries -join ' ')"
)

Write-Host "Configuring CMake build..."
Invoke-NativeCommand -Command $CMakeExecutable -Arguments $ConfigureArguments

# Correct only the generated build config. Project source files stay untouched.
$GeneratedConfig = Join-Path $BuildDirectory "config.h"
if (-not (Test-Path -LiteralPath $GeneratedConfig -PathType Leaf)) {
    throw "Generated config was not found: $GeneratedConfig"
}
$WindowsConfigOverrides = @'

/* Overrides generated by build_shared_lib_windows.ps1 for MinGW. */
#ifdef _WIN32
#undef HAVE_ASPRINTF
#undef HAVE_VASPRINTF
#undef HAVE_NRAND48
#undef HAVE_JRAND48
#undef HAVE_REALLOCARRAY
#undef HAVE_SOCK_CLOEXEC
#endif
'@
[System.IO.File]::AppendAllText(
    $GeneratedConfig,
    $WindowsConfigOverrides,
    [System.Text.Encoding]::ASCII
)

Write-Host "Building target scrcpy_ffi..."
Invoke-NativeCommand -Command $CMakeExecutable -Arguments @(
    "--build", $CMakeBuildDirectory,
    "--target", "scrcpy_ffi",
    "--parallel"
)

$BuiltDll = Join-Path $RuntimeDirectory "libscrcpy_ffi.dll"
if (-not (Test-Path -LiteralPath $BuiltDll -PathType Leaf)) {
    $BuiltDll = Join-Path $RuntimeDirectory "scrcpy_ffi.dll"
    if (-not (Test-Path -LiteralPath $BuiltDll -PathType Leaf)) {
        $Candidates = @(
            Get-ChildItem -LiteralPath $BuildDirectory `
                -Filter "*scrcpy_ffi.dll" -File -Recurse |
                Where-Object {
                    $_.Name -eq "scrcpy_ffi.dll" `
                        -or $_.Name -eq "libscrcpy_ffi.dll"
                }
        )
        if ($Candidates.Count -ne 1) {
            throw "scrcpy_ffi.dll was not found under: $BuildDirectory"
        }
        $BuiltDll = $Candidates[0].FullName
    }
}

$BuiltImportLibrary = Join-Path `
    $BuildDirectory "libscrcpy_ffi.dll.a"
if (-not (Test-Path -LiteralPath $BuiltImportLibrary -PathType Leaf)) {
    $ImportLibraryCandidates = @(
        Get-ChildItem -LiteralPath $BuildDirectory `
            -Filter "*scrcpy_ffi.dll.a" -File -Recurse
    )
    if ($ImportLibraryCandidates.Count -ne 1) {
        throw "scrcpy_ffi import library was not found under: $BuildDirectory"
    }
    $BuiltImportLibrary = $ImportLibraryCandidates[0].FullName
}

Copy-Item -LiteralPath $BuiltDll -Destination $OutputDll -Force
Copy-Item -LiteralPath $BuiltImportLibrary `
    -Destination $OutputImportLibrary -Force
Write-Host "Done: $OutputDll"
Write-Host "Done: $OutputImportLibrary"
