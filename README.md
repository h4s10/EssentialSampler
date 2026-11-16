# Essential Sampler

A native macOS and Windows sampler with independent pitch and time controls, hands-on loop editing, distortion and chorus. Available as **VST3** and a standalone app on both platforms, plus **Audio Unit (AUv2)** on macOS.

The instrument appears in your DAW as **hasio → Essential Sampler**. Previously released as Hasio Loop; internal plugin and parameter identifiers are unchanged so hosts can recognize existing sessions after rescanning.

![Essential Sampler sampler interface with waveform overview, loop editor, pitch and time controls, envelopes and keyboard](docs/preview.png)

[Download v0.7.0](https://github.com/h4s10/EssentialSampler/releases/tag/v0.7.0) · [User guide](docs/USAGE.md) · [Build and test](docs/DEVELOPMENT.md) · [Changelog](CHANGELOG.md)

## Requirements and release status

- **macOS:** Apple Silicon (arm64), macOS 27 or newer. Intel and older macOS builds are not included.
- **Windows:** Windows 10/11 x64 and a 64-bit VST3 host, or the included standalone app. No 32-bit or Windows ARM build is included.
- A VST3 host, or Logic Pro / another AUv2 instrument host. The standalone app does not require a DAW.
- macOS binaries are **ad-hoc signed**, not Developer ID signed or notarized. Windows binaries are unsigned.

**0.7.0 is the first stable release.** Automated tests exercise DSP, decoders, plugin loading, state and native editor behavior. Windows builds run on a native Windows CI runner. Commercial DAW compatibility and system AU validation are separate from these tests; see [verification details](docs/VERIFICATION.md).

## Install on macOS

1. Download and unzip **AU**, **VST3** or **all** from [Releases](https://github.com/h4s10/EssentialSampler/releases).
2. Close your DAW and run `Install.command`. Existing plugin versions are backed up beside the installed bundle.
3. Reopen your DAW. In Logic, create a Software Instrument track and select **AU Instruments → hasio → Essential Sampler → Stereo**. In Ableton Live, enable system VST3 folders and rescan plugins.

| Download | Contents | Install location |
| --- | --- | --- |
| `…-AU.zip` | Audio Unit instrument | `~/Library/Audio/Plug-Ins/Components/Essential Sampler.component` |
| `…-VST3.zip` | VST3 instrument | `~/Library/Audio/Plug-Ins/VST3/Essential Sampler.vst3` |
| `…-all.zip` | Both plugins and the standalone app | Plugins as above; open the included `.app` directly |
| `…-source.zip` | Source and bundled build dependencies | Build locally using the instructions below |

The installer verifies each bundle's signature and identity, removes download quarantine **only from that verified Essential Sampler bundle**, and checks AU registration before running native arm64 `auval`. It does not disable Gatekeeper, delete shared plugin caches or stop your DAW.

### AU installed, but not found

Version 0.6.0 could immediately run validation before macOS discovered the new component. A message such as `FATAL ERROR: didn't find the component` means discovery failed; audio/DSP validation has not started.

Use the latest **0.7.0 installer**, or run `Repair-AU.command` from its archive to repair the existing installation without replacing the plugin. The repair verifies the installed bundle, handles its quarantine flag, and refreshes the current user's Audio Unit registrar if the component is missing. It then waits briefly for registration and runs:

```sh
arch -arm64 auval -v aumu HsLp Hasi
```

If it remains unregistered, restart your Mac once and try again. Apple also documents this step for newly installed Audio Units: [Plugin discovery troubleshooting](https://support.apple.com/en-gb/122179).

If the component **is listed** but validation fails, keep the validation log printed by the installer and [open an issue](https://github.com/h4s10/EssentialSampler/issues). Repeated cache resets do not resolve a plugin API or rendering failure. If Logic lists the plugin as failed, use **Settings → Plug-in Manager → Reset & Rescan Selection** after resolving the reported error.

## Install on Windows

1. Download **EssentialSampler-0.7.0-Windows-x64-VST3.zip** or **…-all.zip**, and extract the entire archive.
2. Close your DAW and run **Install.cmd**. Accept the Windows administrator prompt to install into `C:\Program Files\Common Files\VST3`. The installer verifies the packaged binary checksum and keeps a backup of an existing version.
3. Reopen the DAW, rescan VST3 plugins and select **hasio → Essential Sampler**. You can also copy the entire **Essential Sampler.vst3** folder to that directory manually; keep its `Contents` hierarchy intact.

The **all** archive also contains **Essential Sampler.exe**; run it directly from the extracted folder. The standalone uses the default Windows output device; use the VST3 in your DAW for its configured audio driver. The compiled Microsoft C++ runtime is included in each executable, so no separate redistributable is required.

Windows SmartScreen may ask for confirmation because these builds are unsigned. The installer applies its PowerShell execution setting only to its own process. It does not change the system execution policy. To uninstall, close the DAW and remove the installed **Essential Sampler.vst3** folder.

## Updating from Hasio Loop

Use `Install.command` from the new release with your DAW closed. It installs **Essential Sampler.vst3** / **Essential Sampler.component** and backs up the old Hasio Loop bundles outside their scanned file extensions. This prevents duplicate plugins with the same internal identity. Reopen or rescan your DAW to refresh the displayed name.

Existing project folders do not need to be renamed. No audio settings or sample-state format have changed.

## Features

- Load mono/stereo **WAV, AIFF and FLAC** with a file picker or drag and drop.
- Full-sample overview plus a detailed waveform, movable loop range and editable Start / End / Length fields.
- Trackpad pinch zoom, vertical scroll zoom and horizontal panning.
- **One-shot, Forward, Reverse, Ping-pong and Reverse shot** playback modes.
- **Tune ±24 semitones** without changing playback speed. Keep duration also separates MIDI pitch from playback duration.
- Independent **0.25×–4× Speed**, or host-synced lengths from **4 bars to 1/32**.
- Loop Fade In / Fade Out, Attack / Release and a dedicated Output knob.
- **16 voices**, 26 automatable controls and sample-accurate MIDI/automation offsets.
- Samples embedded in saved DAW state, so the original audio file is not required when reopening the project.
- Separate **FX** tab with six distortion types and a stereo chorus. Both effects default to off.

![Essential Sampler FX page with distortion and chorus controls](docs/fx-preview.png)

See the [user guide](docs/USAGE.md) for gestures, timing behavior, effects and compatibility details.

## Current limits

One sample layer and one loop region; fixed 1280 × 860 editor. No spectral selection, spectrogram, filter section, automatic BPM detection, launch quantization, sustain pedal, MPE, pitch bend, preset browser or standalone session saving.

Pitch/time processing reports a fixed **2048-sample latency** (42.7 ms at 48 kHz). Extreme stretching or compression can soften transients or merge nearby events; formants are not preserved. Polyphonic output can exceed 0 dBFS, so adjust Output. Maximum decoded sample size is **192 MiB**, at **8–384 kHz**, mono or stereo. Embedded PCM increases DAW project size.

## Build from source

### macOS

Install Apple Command Line Tools and Python 3 on an Apple Silicon Mac running macOS 27+. The build uses C++17, Objective-C++, Cocoa, AudioToolbox and Accelerate. No JUCE, CMake, full Xcode installation or network download is required.

```sh
git clone https://github.com/h4s10/EssentialSampler.git
cd EssentialSampler
bash scripts/build.sh
bash scripts/test.sh
bash scripts/package.sh
```

Bundles are written to `releases/0.7.0/`; zip archives are written to `releases/`. See [development documentation](docs/DEVELOPMENT.md) for architecture, validation and installation commands.

### Windows

Install Visual Studio 2022 Build Tools with **Desktop development with C++**, a Windows SDK and CMake 3.22+. From a developer terminal:

```powershell
cmake -S . -B build/windows -A x64
cmake --build build/windows --config Release --parallel
ctest --test-dir build/windows -C Release --output-on-failure
./scripts/package-windows.ps1 -BuildDir build/windows/Release
```

The Windows build uses Win32, WinMM, a portable FFT backend and bundled audio decoders. The [Windows CI workflow](.github/workflows/windows.yml) builds, tests and packages the same source.

## License and credits

Project code is licensed under **[MIT](LICENSE)**. You may use, modify and distribute it, including commercially, while retaining the copyright and license notice.

VST3 interface headers, Xiph FLAC/Ogg and dr_libs dependencies retain their own notices; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Source, artwork and the oscillator-generated demo sample are part of this project.
