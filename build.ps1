#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Builds whisper.cpp with the Vulkan backend on Windows x64, locally.

.DESCRIPTION
  Same sequence the CI workflow runs. Use this to produce a build without
  waiting for a release, or to test a change before pushing it.

  Two prerequisites beyond MSVC are easy to miss, and both fail the configure
  step with a misleading message:

  - ggml-vulkan requires find_package(SPIRV-Headers CONFIG REQUIRED). A stock
    Vulkan SDK install ships the glslc binary but not the CMake config, so
    SPIRV-Headers is built and installed here.
  - The import library is named vulkan-1.lib, not vulkan.lib.

.PARAMETER BuildDir
  CMake binary directory. Default: .\build

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
    [string]$BuildDir = "$PSScriptRoot\build",
    [string]$VulkanSdk = $env:VULKAN_SDK,
    [int]$Jobs = [Environment]::ProcessorCount,
    [string]$SourceDir = "$PSScriptRoot\whisper.cpp"
)

$ErrorActionPreference = "Stop"

function Say([string]$m) { Write-Host "[build] $m" }

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
    & cmake -S $spvSrc -B "$spvSrc-build" "-DCMAKE_INSTALL_PREFIX=$spvInstall" "-DCMAKE_BUILD_TYPE=Release"
    & cmake --install "$spvSrc-build"
}

# ---- configure + build ----------------------------------------------------
$env:VULKAN_SDK = $VulkanSdk
$env:PATH = "$VulkanSdk\Bin;$env:PATH"

# Every -D value is quoted on purpose. PowerShell does not expand a variable
# in an unquoted `name=$var` argument passed to a native command - cmake
# receives the literal text "$var", and the failure surfaces much later as a
# confusing linker error about a file named '$var.obj'.
Say "Configuring..."
& cmake -B $BuildDir -S $SourceDir `
    "-DGGML_VULKAN=ON" `
    "-DGGML_NATIVE=OFF" `
    "-DBUILD_SHARED_LIBS=ON" `
    "-DWHISPER_BUILD_SERVER=ON" `
    "-DWHISPER_BUILD_EXAMPLES=ON" `
    "-DWHISPER_BUILD_TESTS=OFF" `
    "-DCMAKE_BUILD_TYPE=Release" `
    "-DCMAKE_PREFIX_PATH=$spvInstall" `
    "-DVulkan_LIBRARY=$vulkanLib"
if ($LASTEXITCODE -ne 0) { Say "configure failed"; exit 1 }

Say "Compiling with $Jobs jobs (this takes a few minutes)..."
& cmake --build $BuildDir --config Release --parallel $Jobs
if ($LASTEXITCODE -ne 0) { Say "build failed"; exit 1 }

$bin = Join-Path $BuildDir "bin\Release"
if (-not (Test-Path (Join-Path $bin "ggml-vulkan.dll"))) {
    Say "ggml-vulkan.dll was not produced - Vulkan backend did not build"
    exit 1
}

Say "Built. Binaries in $bin"
Say "Smoke test: whisper-cli.exe -m <model>.bin -f <audio>.wav -l tr -nt -np"
Say "Look for a 'Found 1 Vulkan devices' line."