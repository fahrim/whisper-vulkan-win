# whisper.cpp — Vulkan backend, Windows x64

Ready-to-run [whisper.cpp](https://github.com/ggml-org/whisper.cpp) builds for the GPUs upstream does not ship Windows binaries for.

Upstream publishes Windows builds for **CUDA** and plain **CPU**. That leaves every AMD, Intel Arc, and older NVIDIA user on the CPU path — which is roughly an order of magnitude slower. `ggml` has had a Vulkan backend for a long time; these builds just turn it on.

These are unmodified builds of official whisper.cpp sources, compiled in CI with `-DGGML_VULKAN=ON`. No patched code, no bundled surprises.

Each release carries two single executables: a Vulkan build and a processor-only build. Both are linked with the static MSVC runtime (`/MT`) and `BUILD_SHARED_LIBS=OFF`, so they do not need the Visual C++ redistributable. `vcomp140.dll` travels beside them because OpenMP is still the faster processor path; it imports only `KERNEL32.dll`, so it brings no CRT of its own.

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

> **Requires an AVX2 CPU** (roughly 2013 or newer) — `GGML_NATIVE=OFF` picks a
> portable baseline, but that baseline includes AVX2. Both executables carry
> the same requirement. On older CPUs, use upstream's generic CPU build.

> **Requires a Vulkan driver for the accelerated build.** AMD Adrenalin,
> Intel's Windows driver, and NVIDIA's driver all ship one. Nothing extra to
> install. Check yours with `vulkaninfo` from the Vulkan SDK, or just run
> `whisper-server.exe --help` and watch for a device line. The processor
> build has no such requirement.

## What is in the zip

```
whisper-server.exe       HTTP server with the Vulkan backend
whisper-server-cpu.exe   HTTP server with the processor backend
vcomp140.dll             OpenMP runtime, imported by both
```

No `whisper.dll`, no `ggml*.dll`, and no Visual C++ runtime DLLs. A clean
machine can unpack the zip and run either executable.

## Quick check

```powershell
whisper-server.exe --model <model>.bin --host 127.0.0.1 --port 8811
```

A healthy Vulkan start prints:

```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = <your GPU> | fp16: 1 | bf16: 1 | ...
```

If that line says `Found 0 Vulkan devices`, the driver is the problem, not the
build. Update your GPU driver. If the accelerated executable will not start at
all, run `whisper-server-cpu.exe` instead: the processor build is the honest
floor.

## Models

Not bundled — they are multi-hundred-megabyte downloads. Any ggml model works:

```powershell
curl.exe -L -o ggml-large-v3-turbo-q5_0.bin `
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

**Pass `--language` explicitly.** With no language hint, Whisper auto-detects,
which both costs roughly twice the transcription time and gets Turkish wrong —
it reads a Turkish recording as English and returns Latin-script nonsense. Use
`--language tr`, `--language en`, and so on.

## Building it yourself

The point of keeping this public. On Windows:

1. Install [CMake](https://cmake.org/download/), the
   [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) and Visual Studio 2022.
2. Fetch whisper.cpp with its submodules next to this repository:

```powershell
git clone --recursive https://github.com/ggml-org/whisper.cpp
```

3. Run the build script:

```powershell
.\build.ps1
```

It builds SPIRV-Headers, configures both backends with `BUILD_SHARED_LIBS=OFF`
and `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`, verifies the import tables,
smoke-tests both executables, and stages the three files in `dist\runtime`.
The same script is what CI runs, so a local success and a release build mean
the same thing.

Two notes if the configure step fails:

- The import library is `vulkan-1.lib`, not `vulkan.lib`, and not every SDK
  layout ships one. Point `Vulkan_LIBRARY` at whichever exists.
- `ggml-vulkan` calls `find_package(SPIRV-Headers CONFIG REQUIRED)`. A default
  Vulkan SDK install does not ship that CMake config. The script builds and
  installs [SPIRV-Headers](https://github.com/KhronosGroup/SPIRV-Headers) for
  you.

See `.github/workflows/build.yml` for the release sequence.

## License

whisper.cpp is MIT-licensed. These are unmodified builds of its sources. The
models are separate downloads under their own licenses.