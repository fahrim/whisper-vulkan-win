#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fails when a packaged engine still depends on a DLL that is not shipped.

.DESCRIPTION
  The runtime is meant to be self-contained: one executable per backend,
  statically linked against the C runtime, plus the OpenMP runtime it
  ships beside itself. A build that silently reintroduces vcruntime140,
  msvcp140, the UCRT API set, or a separate ggml/whisper DLL produces an
  installer that fails on a clean machine with a loader error the
  application never gets to explain.

  This is deliberately a dependency check rather than a launch check.
  A launch on a build machine proves the build machine has the DLL; it
  does not prove a clean machine does.

.PARAMETER Binary
  Executable to inspect.

.PARAMETER Vulkan
  Require the Vulkan loader and forbid a Vulkan-free build.

.PARAMETER OpenMP
  Require vcomp140.dll, which the build stages beside the executable.

.EXAMPLE
  .\verify-imports.ps1 -Binary .\dist\runtime\whisper-server.exe -Vulkan -OpenMP
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Binary,

    [switch]$Vulkan,

    [switch]$OpenMP
)

$ErrorActionPreference = "Stop"

# The CRT, the C++ standard library, and the UCRT API set all mean a
# machine without the Visual C++ redistributable cannot load the engine.
# ggml/whisper DLLs mean BUILD_SHARED_LIBS was not actually off.
$forbidden = @(
    '^vcruntime\d+(_\d+)?\.dll$',
    '^msvcp\d+(_\d+)?\.dll$',
    '^concrt\d+\.dll$',
    '^ucrtbase\.dll$',
    '^api-ms-win-crt-',
    '^(whisper|ggml)[^\\/]*\.dll$'
)

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
    throw "Visual Studio with the C++ tools was not found"
}

function Find-Dumpbin {
    $root = Find-VisualStudioRoot
    $tools = Get-ChildItem (Join-Path $root 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($tool in $tools) {
        $dumpbin = Join-Path $tool.FullName 'bin\Hostx64\x64\dumpbin.exe'
        if (Test-Path $dumpbin) { return $dumpbin }
    }
    throw "dumpbin.exe was not found under $root"
}

function Get-Imports([string]$file) {
    $dumpbin = Find-Dumpbin
    $output = & $dumpbin /nologo /dependents $file 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin failed for $file`n$($output -join "`n")"
    }
    $imports = $output |
        Select-String -Pattern '^\s+([A-Za-z0-9_.-]+\.dll)\s*$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
    if (-not $imports) {
        throw "no import table was read from $file"
    }
    return $imports
}

foreach ($file in $Binary) {
    if (-not (Test-Path $file)) {
        throw "missing binary: $file"
    }
    $imports = Get-Imports $file
    $bad = $imports | Where-Object {
        $name = $_
        $forbidden | Where-Object { $name -match $_ }
    }
    if ($bad) {
        throw "$file still depends on $($bad -join ', ')"
    }
    $hasVulkan = $imports -contains 'vulkan-1.dll'
    if ($Vulkan -and -not $hasVulkan) {
        throw "$file does not import vulkan-1.dll"
    }
    if (-not $Vulkan -and $hasVulkan) {
        throw "$file imports vulkan-1.dll but is packaged as the processor build"
    }
    if ($OpenMP -and -not ($imports -contains 'VCOMP140.DLL' -or $imports -contains 'vcomp140.dll')) {
        throw "$file does not import vcomp140.dll, which this package expects to ship"
    }
    Write-Host "[imports] $file"
    $imports | ForEach-Object { Write-Host "  $_" }
}
