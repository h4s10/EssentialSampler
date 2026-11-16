# Development

## Build on macOS

Requirements: Apple Silicon, macOS 27+, Apple Command Line Tools and Python 3. The checked-in FLAC/Ogg static archives target macOS 27; rebuilding for older systems requires rebuilding those dependencies and updating deployment targets and bundle metadata.

```sh
bash scripts/build.sh
bash scripts/test.sh
bash scripts/package.sh
```

Builds are local and do not fetch dependencies. The output formats are `Essential Sampler.vst3`, `Essential Sampler.component` and `Essential Sampler.app` under `releases/0.7.0/`. All are ad-hoc signed.

## Build on Windows

Requirements: Windows x64, Visual Studio 2022 C++ Build Tools, Windows SDK and CMake 3.22+. Dependencies are checked in; the build does not fetch packages.

```powershell
cmake -S . -B build/windows -A x64 -DBUILD_TESTING=ON
cmake --build build/windows --config Release --parallel
ctest --test-dir build/windows -C Release --output-on-failure
./tests/windows_installer_tests.ps1
./scripts/package-windows.ps1 -BuildDir build/windows/Release
```

Release tests deliberately retain assertions. MSVC links its runtime statically. The VST3 DLL is packaged as `Essential Sampler.vst3/Contents/x86_64-win/Essential Sampler.vst3`, following the [VST3 bundle format](https://steinbergmedia.github.io/vst3_dev_portal/pages/Technical+Documentation/Locations+Format/Plugin+Format.html). The installer uses the [standard shared VST3 folder](https://steinbergmedia.github.io/vst3_dev_portal/pages/Technical+Documentation/Locations+Format/Plugin+Locations.html).

On macOS, `bash scripts/test-portable.sh` additionally runs the Windows DSP/decoder code under AddressSanitizer and UndefinedBehaviorSanitizer without linking Apple audio/DSP frameworks.

GitHub Actions uses `windows-2022` to compile and execute the tests and uploads the release archives and test logs. This verifies Windows APIs and binary loading independently of the macOS build; it is not a test inside a commercial DAW.

## Architecture

| Path | Responsibility |
| --- | --- |
| `src/Engine.*` | Voices, resampling, loop transport and sample exchange |
| `src/PitchShifter.*` | Stereo pitch/time processing and preallocated FFT buffers |
| `src/Effects.*` | Distortion, chorus, smoothing and delay buffers |
| `src/Plugin.mm`, `src/PluginWindows.cpp` | Shared VST3 component/controller, buses, automation and state; platform editor adapters |
| `src/AudioUnit.mm` | AUv2 factory, properties, MIDI, automation, rendering and Cocoa view factory |
| `src/Editor.mm` | Shared native Cocoa editor and gestures |
| `src/WindowsEditor.*` | Native Win32 editor, gestures and file loading lifecycle |
| `src/WindowsStandalone.cpp` | WinMM output and Windows application lifecycle |
| `src/AudioFileWindows.cpp` | Portable WAV/AIFF/FLAC decoding |
| `src/FFT.hpp` | Accelerate adapter and allocation-free portable FFT |
| `src/AudioFile.mm` | WAV/AIFF via AudioToolbox; FLAC via libFLAC |
| `src/State.hpp` | Versioned normalized parameters and embedded stereo PCM |
| `src/Standalone.mm` | Standalone Core Audio output and application lifecycle |
| `tests/` | DSP, host, UI, file-loading and installer regressions |

Published samples are immutable. The render thread pins a sample using a hazard pointer; allocation and reclamation happen on the control thread. Do not call `configure` or `render` after releasing a sample without a new `setSample`. The editor note queue has one producer and one consumer. The AU adapter has separate bounded host-event queues and preserves ordering across MIDI and parameter events.

AU parameters expose physical units and convert to the same normalized engine values as VST3. AU has a separate Objective-C editor class name so AU and VST3 can coexist in one process. Scheduled AU parameter events apply only to their current render call; a host resubmits a ramp for each subsequent block.

## Validation

`scripts/test.sh` runs DSP/FX/bandwidth tests under sanitizers, loads the actual VST3 bundle, checks the native editor and keyboard focus, and exercises the AU bundle's direct factory/selector ABI. Installer tests mock the OS registry service and never modify the user's plugins or stop a real registrar.

```sh
python3 tests/installer_tests.py
./build/au_host_tests "$PWD/releases/0.7.0/Essential Sampler.component" --direct
```

Direct ABI tests do **not** prove OS discovery or Logic compatibility. On a Mac with system registry access, also run:

```sh
./build/au_host_tests "$PWD/releases/0.7.0/Essential Sampler.component" validate
bash scripts/install-au.command
arch -arm64 auval -v aumu HsLp Hasi
```

See [VERIFICATION.md](VERIFICATION.md) for actual results and limitations. `bash scripts/benchmark.sh` measures the engine's offline processing time; it is not a guarantee of glitch-free realtime behavior.

## Install and update locally

- `bash scripts/install-vst3.command`: install VST3 only.
- `bash scripts/install-au.command`: install AU and validate it.
- `bash scripts/repair-au.command`: repair discovery of the existing installed AU without replacing its binary.
- `bash scripts/setup-dev.command`: copy a new project to `~/Dev/EssentialSampler`; refuses to overwrite an existing folder.
- `bash scripts/update-dev.command`: update `~/Dev/EssentialSampler`, back up the previous project and install both formats. If only the legacy `~/Dev/HasioLoop` checkout exists, the updater continues using that folder.

`HASIO_DEV_DIR`, `HASIO_VST3_DIR` and `HASIO_AU_DIR` override destinations for isolated tests. `HASIO_SKIP_AUVAL=1` skips system validation when installing to a nonstandard test folder; it must not be interpreted as an AU validation pass. The installer verifies bundle identity/signature before removing only its `com.apple.quarantine` attribute. It refreshes only the current user's AudioComponentRegistrar, when the requested component is absent or a legacy bundle has just been renamed.

Exit codes: **1** for installation/verification errors, **2** for a discovered AU that fails validation, **3** for a component still missing from the registry. The last case recommends a Mac restart, as documented by Apple. Shared caches are not deleted.

## Release packaging

`scripts/package.sh` creates separate AU, VST3 and combined zip archives with English documentation, screenshots, license notices, installer and AU repair command. Release checksums are generated in `releases/SHA256SUMS.txt`. Source archives are generated from a Git commit. Build caches, local analysis artifacts and plugin binaries are excluded from source control.

Preserve existing VST3 IDs and AU identity (`aumu / HsLp / Hasi`) when publishing updates. Keep the CFBundle versions, editor version label, script release paths and release notes in sync. Developer ID signing and notarization are separate distribution steps and are not part of the current ad-hoc build.

The Windows installer accepts `-Destination` and `-PackageRoot` for isolated tests. Without a destination override it requests administrator access for Common Files/VST3. It stages and verifies the bundle before replacing an existing installation, preserves a timestamped backup and restores it if promotion fails.
