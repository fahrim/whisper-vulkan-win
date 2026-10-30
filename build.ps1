#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Builds whisper.cpp for Windows x64 as two self-contained server binaries.

.DESCRIPTION
  Same sequence the CI workflow runs. Use this to produce a build without
  waiting for a release, or to test a change before pushing it.

  The package is deliberately two executables rather than a pile of DLLs:

  - whisper-server.exe carries the Vulkan backend and the OpenMP runtime
    dependency it ships beside itself.
  - whisper-server-cpu.exe carries the processor backend.

  Both are built with BUILD_SHARED_LIBS=OFF and the static MSVC runtime
  (/MT). A machine that has never had the Visual C++ redistributable can
  still start the engine, which is the failure this arrangement exists
  to remove.

  Two prerequisites beyond MSVC are easy to miss, and both fail the
  configure step with a misleading message:

  - ggml-vulkan requires find_package(SPIRV-Headers CONFIG REQUIRED). A
    stock Vulkan SDK install ships the glslc binary but not the CMake
    config, so SPIRV-Headers is built and installed here.
  - The import library is named vulkan-1.lib, not vulkan.lib.

.PARAMETER BuildDir
  CMake binary directory for the Vulkan build. Default: .\build-vulkan

.PARAMETER CpuBuildDir
  CMake binary directory for the processor build. Default: .\build-cpu

.PARAMETER DistDir
  Where the two executables and vcomp140.dll are staged.
  Default: .\dist\runtime

.PARAMETER VulkanSdk
  Vulkan SDK root. Default: $env:VULKAN_SDK, else the newest C:\VulkanSDK\*.

.PARAMETER Jobs
  Parallel compile jobs.

.EXAMPLE
  .\build.ps1

.EXAMPLE
  .\build.ps1 -Jobs 16
#>
[CmdletBinding()]
param(
    [string]$BuildDir = "$PSScriptRoot\build-vulkan",
    [string]$CpuBuildDir = "$PSScriptRoot\build-cpu",
    [string]$DistDir = "$PSScriptRoot\dist\runtime",
    [string]$VulkanSdk = $env:VULKAN_SDK,
    [int]$Jobs = [Environment]::ProcessorCount,
    [string]$SourceDir = "$PSScriptRoot\whisper.cpp"
)

$ErrorActionPreference = "Stop"

function Say([string]$m) { Write-Host "[build] $m" }

function Find-VisualStudioRoot {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if ($found) { return $found }
    }
    foreach ($candidate in @(
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Enterprise",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Professional",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\Community",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    throw "Visual Studio 2022 with the C++ tools was not found"
}

function Find-Vcomp {
    $root = Find-VisualStudioRoot
    $redist = Get-ChildItem (Join-Path $root 'VC\Redist\MSVC') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($version in $redist) {
        $found = Get-ChildItem (Join-Path $version.FullName 'x64') -Recurse -Filter vcomp140.dll `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if ($found) { return $found }
    }
    throw "vcomp140.dll was not found in the Visual Studio redistributable directory"
}

# ---- locate the SDK -------------------------------------------------------
if (-not $VulkanSdk) {
    $VulkanSdk = Get-ChildItem "C:\VulkanSDK" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $VulkanSdk) {
    Say "No Vulkan SDK found. Install it from https://vulkan.lunarg.com/sdk/home"
    exit 1
}
if (-not (Test-Path "$VulkanSdk\Bin\glslc.exe")) {
    Say "glslc.exe missing from $VulkanSdk\Bin - is this a complete SDK install?"
    exit 1
}
Say "Vulkan SDK: $VulkanSdk"

# vulkan.lib does not exist in this SDK layout; the import library is
# vulkan-1.lib. Probe rather than assume.
$vulkanLib = @("vulkan-1.lib", "vulkan.lib") |
    ForEach-Object { Join-Path $VulkanSdk "Lib\$_" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vulkanLib) {
    Say "No Vulkan import library under $VulkanSdk\Lib"
    exit 1
}
Say "import lib: $vulkanLib"

foreach ($tool in @("cmake", "git")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Say "$tool not found on PATH"
        exit 1
    }
}
if (-not (Test-Path $SourceDir)) {
    Say "whisper.cpp sources not found at $SourceDir"
    Say "Clone them first:  git clone --recursive https://github.com/ggml-org/whisper.cpp `"$SourceDir`""
    exit 1
}

# Let CMake choose the installed Visual Studio generator. Naming one by
# version made the script fail on a runner that had moved to a newer
# Visual Studio, and the generator does not change the bytes in a way the
# import guard and smoke test do not already cover. The host is x64, so
# the default architecture is the one this package ships.
$generator = @()

# ---- SPIRV-Headers --------------------------------------------------------
$spvInstall = "$PSScriptRoot\spirv-headers-install"
if (Test-Path (Join-Path $spvInstall "share\cmake\SPIRV-Headers\SPIRV-HeadersConfig.cmake")) {
    Say "SPIRV-Headers already installed"
} else {
    Say "Building SPIRV-Headers (ggml-vulkan requires it)..."
    $spvSrc = "$PSScriptRoot\spirv-headers"
    if (Test-Path $spvSrc) { Remove-Item $spvSrc -Recurse -Force }
    & git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers $spvSrc
    if ($LASTEXITCODE -ne 0) { Say "clone failed"; exit 1 }
    & cmake -S $spvSrc -B "$spvSrc-build" @generator `
        "-DCMAKE_INSTALL_PREFIX=$spvInstall" "-DCMAKE_BUILD_TYPE=Release"
    if ($LASTEXITCODE -ne 0) { Say "SPIRV-Headers configure failed"; exit 1 }
    & cmake --install "$spvSrc-build" --config Release
    if ($LASTEXITCODE -ne 0) { Say "SPIRV-Headers install failed"; exit 1 }
}

# ---- common configuration -------------------------------------------------
$env:VULKAN_SDK = $VulkanSdk
$env:PATH = "$VulkanSdk\Bin;$env:PATH"

# Every -D value is quoted on purpose. PowerShell does not expand a variable
# in an unquoted `name=$var` argument passed to a native command - cmake
# receives the literal text "$var", and the failure surfaces much later as a
# confusing linker error about a file named '$var.obj'.
$common = @(
    "-DGGML_NATIVE=OFF",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DGGML_OPENMP=ON",
    # whisper.cpp v1.9.5 has no working WHISPER_BUILD_SERVER switch: the
    # server target is added by examples/CMakeLists.txt, and that whole
    # directory is gated on WHISPER_BUILD_EXAMPLES. The build below asks
    # for the whisper-server target only, so the other examples are
    # configured but never compiled.
    "-DWHISPER_BUILD_EXAMPLES=ON",
    "-DWHISPER_BUILD_TESTS=OFF",
    "-DCMAKE_BUILD_TYPE=Release",
    # whisper.cpp declares cmake_minimum_required(VERSION 3.5), which
    # leaves CMP0091 at OLD and makes CMake ignore the runtime-library
    # setting below. The default has to be raised explicitly.
    "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
    # Static MSVC runtime: no vcruntime140, no msvcp140, no UCRT API set.
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"
)

# ---- Vulkan build ---------------------------------------------------------
Say "Configuring the Vulkan build..."
& cmake -B $BuildDir -S $SourceDir @generator @common `
    "-DGGML_VULKAN=ON" `
    "-DCMAKE_PREFIX_PATH=$spvInstall" `
    "-DVulkan_LIBRARY=$vulkanLib"
if ($LASTEXITCODE -ne 0) { Say "Vulkan configure failed"; exit 1 }

Say "Compiling the Vulkan build with $Jobs jobs (this takes a few minutes)..."
& cmake --build $BuildDir --config Release --target whisper-server --parallel $Jobs
if ($LASTEXITCODE -ne 0) { Say "Vulkan build failed"; exit 1 }

# Multi-config generators put the executable under bin\Release; a
# single-config generator puts it under bin. Find it rather than assume,
# so the script works with whichever generator CMake selected.
$vulkanServer = Get-ChildItem (Join-Path $BuildDir "bin") -Recurse -Filter whisper-server.exe `
    -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $vulkanServer) {
    Say "Vulkan build did not produce whisper-server.exe"
    exit 1
}

# ---- processor build ------------------------------------------------------
Say "Configuring the processor build..."
& cmake -B $CpuBuildDir -S $SourceDir @generator @common `
    "-DGGML_VULKAN=OFF"
if ($LASTEXITCODE -ne 0) { Say "processor configure failed"; exit 1 }

Say "Compiling the processor build with $Jobs jobs..."
& cmake --build $CpuBuildDir --config Release --target whisper-server --parallel $Jobs
if ($LASTEXITCODE -ne 0) { Say "processor build failed"; exit 1 }

$cpuServer = Get-ChildItem (Join-Path $CpuBuildDir "bin") -Recurse -Filter whisper-server.exe `
    -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $cpuServer) {
    Say "processor build did not produce whisper-server.exe"
    exit 1
}

# ---- stage ----------------------------------------------------------------
if (Test-Path $DistDir) { Remove-Item $DistDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Copy-Item $vulkanServer.FullName (Join-Path $DistDir "whisper-server.exe")
Copy-Item $cpuServer.FullName (Join-Path $DistDir "whisper-server-cpu.exe")
$vcomp = Find-Vcomp
Copy-Item $vcomp (Join-Path $DistDir "vcomp140.dll")
Say "vcomp: $vcomp"

# A clean machine is the only machine that can prove this, so the check
# runs against the packaged bytes rather than the build tree.
& "$PSScriptRoot\verify-imports.ps1" `
    -Binary (Join-Path $DistDir "whisper-server.exe") -Vulkan -OpenMP
if ($LASTEXITCODE -ne 0) { Say "Vulkan import check failed"; exit 1 }
& "$PSScriptRoot\verify-imports.ps1" `
    -Binary (Join-Path $DistDir "whisper-server-cpu.exe") -OpenMP
if ($LASTEXITCODE -ne 0) { Say "processor import check failed"; exit 1 }

# ---- smoke test -----------------------------------------------------------
foreach ($name in @("whisper-server.exe", "whisper-server-cpu.exe")) {
    $exe = Join-Path $DistDir $name
    $output = & $exe --help 2>&1
    if ($LASTEXITCODE -ne 0) {
        Say "$name did not start (exit $LASTEXITCODE)"
        $output | Select-Object -First 20 | ForEach-Object { Say "  $_" }
        exit 1
    }
    Say "$name starts"
}

$files = Get-ChildItem $DistDir -File
$bytes = ($files | Measure-Object Length -Sum).Sum
Say ("staged {0} files, {1:N1} MB, in {2}" -f $files.Count, ($bytes / 1MB), $DistDir)
