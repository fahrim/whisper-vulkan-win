# whisper.cpp — Vulkan backend, Windows x64

Ready-to-run [whisper.cpp](https://github.com/ggml-org/whisper.cpp) builds for the GPUs upstream does not ship Windows binaries for.

Upstream publishes Windows builds for **CUDA** and plain **CPU**. That leaves every AMD, Intel Arc, and older NVIDIA user on the CPU path — which is roughly an order of magnitude slower. `ggml` has had a Vulkan backend for a long time; these builds just turn it on.

These are unmodified builds of official whisper.cpp sources, compiled in CI with `-DGGML_VULKAN=ON`. No patched code, no bundled surprises.

## Why Vulkan

One backend covers the GPUs CUDA does not:

| Vendor | CUDA | Vulkan here |
| --- | --- | --- |
| NVIDIA (Turing+) | ✅ upstream | ✅ works too |
| AMD (RX 5000+, RDNA) | ❌ | ✅ |
| Intel Arc | ❌ | ✅ |
| NVIDIA (pre-Turing) | ❌ | ✅ |

Measured on an **AMD Radeon RX 7700 XT** with `ggml-large-v3-turbo-q5_0`:

| Backend | 5s Turkish clip |
| --- | ---: |
| CPU (12 threads) | 11.1s |
| Vulkan (this build) | 0.99s |

**~11x faster**, same output.

## Downloads

Grab the latest zip from [Releases](../../releases). Files are named
`whisper-vulkan-win-x64-<whisper-build>.zip`.

Verify before you run it:

```powershell
Get-FileHash whisper-vulkan-win-x64-*.zip -Algorithm SHA256
```

Compare against `SHA256SUMS.txt` on the same release page.

> **Requires an AVX2 CPU** (roughly 2013 or newer) — `GGML_NATIVE=OFF` still
> targets a baseline. On older CPUs the binary exits immediately; use a
> CPU-only upstream build instead.

> **Requires a Vulkan driver.** AMD Adrenalin, Intel's Windows driver, and
> NVIDIA's driver all ship one. Nothing extra to install. Check yours with
> `vulkaninfo` from the Vulkan SDK, or just run `whisper-cli.exe --help` and
> watch for a device line.

## What is in the zip

```
whisper-cli.exe      transcription from the command line
whisper-server.exe   HTTP server, incl. an OpenAI-compatible /inference
whisper.dll
ggml.dll             base dispatch
ggml-cpu.dll         CPU fallback, used for work the GPU cannot take
ggml-vulkan.dll      the Vulkan backend
ggml-base.dll
```

## Quick check

```powershell
whisper-cli.exe -m <model>.bin -f <audio>.wav -l tr -nt -np
```

A healthy run starts with:

```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = <your GPU> | fp16: 1 | bf16: 1 | ...
```

If that line says `Found 0 Vulkan devices`, the driver is the problem, not the
build. Update your GPU driver.

## Models

Not bundled — they are multi-hundred-megabyte downloads. Any ggml model works:

```powershell
curl.exe -L -o ggml-large-v3-turbo-q5_0.bin `
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

**Pass `-l` explicitly.** With no language hint, Whisper auto-detects, which
both costs roughly twice the transcription time and gets Turkish wrong — it
reads a Turkish recording as English and returns Latin-script nonsense. Use
`-l tr`, `-l en`, and so on.

## Building it yourself

The point of keeping this public. On Windows:

1. Install [CMake](https://cmake.org/download/), the
   [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) and Visual Studio 2022.
2. Fetch whisper.cpp with its submodules (`git clone --recursive`).
3. Configure and build:

```powershell
$env:VULKAN_SDK = "C:\VulkanSDK\1.4.363.0"
$env:PATH = "$env:VULKAN_SDK\Bin;$env:PATH"

cmake -B build -S . `
  -DGGML_VULKAN=ON `
  -DGGML_NATIVE=OFF `
  -DBUILD_SHARED_LIBS=ON `
  -DWHISPER_BUILD_SERVER=ON `
  -DWHISPER_BUILD_TESTS=OFF `
  -DCMAKE_BUILD_TYPE=Release `
  -DVulkan_LIBRARY="$env:VULKAN_SDK\Lib\vulkan-1.lib"

cmake --build build --config Release --parallel
```

Two notes if the configure step fails:

- The import library is `vulkan-1.lib`, not `vulkan.lib`, and not every SDK
  layout ships one. Point `Vulkan_LIBRARY` at whichever exists.
- `ggml-vulkan` calls `find_package(SPIRV-Headers CONFIG REQUIRED)`. A default
  Vulkan SDK install does not ship that CMake config. Build and install
  [SPIRV-Headers](https://github.com/KhronosGroup/SPIRV-Headers), then pass
  `-DCMAKE_PREFIX_PATH=<install-prefix>`.

See `.github/workflows/build.yml` for the exact sequence CI runs.

## License

whisper.cpp is MIT-licensed. These are unmodified builds of its sources. The
models are separate downloads under their own licenses.