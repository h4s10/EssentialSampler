# Verification — 0.6.2

This update changes the displayed product name to Essential Sampler, bundle/executable filenames and upgrade handling. Audio processing and saved-state/parameter identities are unchanged. The user reported the preceding installation working; independent system-registry/Logic validation remains unavailable in this build sandbox.

The existing installer suite was extended with legacy-name migration and rollback tests. The original script fails against renamed release bundles; the new script installs the renamed bundle, preserves the old one as an unscanned backup, refreshes AU metadata after migration, and restores both original names on a forced replacement failure. The full DSP, FX, bandwidth, actual VST3 host, direct AU ABI, native UI/keyboard and installer suite passed. Bundle metadata checks confirm the new display/executable names with unchanged bundle IDs, VST3 class ID and AU identity. Both Sampler and FX screenshots were regenerated and visually checked with the new Essential Sampler header.

Current artifacts: `releases/0.6.2/Essential Sampler.{vst3,component,app}`. Run `bash scripts/build.sh`, `bash scripts/test.sh` and `bash scripts/package.sh`.

# Previous verification — 0.6.1

Build and complete regression suite passed on Apple Silicon, macOS 27.0.1: DSP/FX/bandwidth sanitizers, actual VST3 bundle host, native Cocoa UI/keyboard, file import, AU direct ABI and installer tests. The sampler and FX screenshots were regenerated from the actual native editor in this build, not from a design mockup.

The installer suite first reproduced failures with the 0.6.0 script, then passed with discovery checks, verified-bundle quarantine handling, arm64 execution and bounded registrar retries. A real signed AU bundle with a synthetic quarantine attribute was additionally installed twice in a temporary directory: quarantine removal, unchanged code-signature validity and previous-version backup all passed, with system validation explicitly skipped. The OS registration service is mocked in the service tests: they establish script behavior, not successful Audio Unit registration on the user's machine.

Current build/test commands (the second command exercises the direct ABI, not the system registry):

```sh
bash scripts/build.sh && bash scripts/test.sh
./build/au_host_tests "$PWD/releases/0.6.1/Hasio Loop.component" --direct
```

## Reported 0.6.0 installation failure

The user reported `FATAL ERROR: didn't find the component` after installing the AU release. Read-only inspection confirmed the installed bundle exists, its ad-hoc signature is valid, the executable is arm64 with a macOS 27 minimum, the host runs macOS 27.0.1, and the expected factory/class symbols and AudioComponents metadata are present. The installed bundle retains a `com.apple.quarantine` attribute. The old installer did not handle that attribute or check/wait for registry discovery before invoking validation.

The 0.6.1 installer addresses both installation conditions and provides a repair mode for 0.6.0. **The exact cause of the user's missing registry entry is not yet proven, and target-machine recovery has not been confirmed.** System AudioComponent access and unified logs remain unavailable inside this sandbox. No Logic/auval success is claimed. The local installer or repair command performs the real validation; a missing component produces a separate restart recommendation, while a registered component's validation failure retains its diagnostic log.

All project-facing documentation and release notes are English. README images reference actual checked-in screenshots, also included in binary archives. Historical source tags and older downloaded archives retain their original content.

# Previous verification — 0.6.0

Built on Apple Silicon, macOS 27, Apple clang 21. The existing DSP, FX, bandwidth, actual VST3 host, file loading, Cocoa UI and keyboard regression suite passes. AU uses the same engine/editor with a distinct Objective-C class name.

The AU test loads the actual `.component` binary and exercises its public factory and selector interface directly (`--direct`). It covers physical parameter units/labels, embedded-sample state, invalid state, MIDI offsets, automation ramps, same-sample ordering, duplicate render pulls, queue overflow recovery, owned/supplied buffers, reset, stream negotiation, stereo interleaving and editor/container lifetime. Property/ramp boundary and event-order regressions identified during review are included. Host tempo/time-signature timing (137 BPM, 3/4) and channel-specific MIDI all-notes/sound-off also pass. The AU adapter and host were additionally exercised with AddressSanitizer and UndefinedBehaviorSanitizer without reported errors. Combined installation, project update and repeat-install backups passed in isolated temporary folders (system auval explicitly skipped there).

**Validation boundary:** the system AudioComponent registry is unavailable in the sandbox (`AudioComponentRegister` returns null, even for a sandbox-safe component). Elevation to run the system registry test was rejected by the environment. Apple `auval` cannot discover an uninstalled bundle here. This is not an `auval` pass and Logic Pro was not exercised. Installers run `auval -v aumu HsLp Hasi` after installation; source includes a public-API test mode for a Mac with registry access:

```sh
bash scripts/build.sh
bash scripts/test.sh
./build/au_host_tests "$PWD/releases/0.6.0/Hasio Loop.component" validate
bash scripts/install-au.command
```

Release artifacts target **macOS 27+ / arm64**, carry ad-hoc signatures and preserve all dependency notices. They are not Developer ID signed or notarized. Version 0.6.0 is published as a prerelease pending native Logic/auval confirmation. VST3 and AU states are shared internally, but changing plugin format in an existing DAW project is not an automatic migration.

# Previous verification — 0.5.2

Validated on the current Apple Silicon Mac, macOS 27, Apple clang 21.

| Check | Result |
| --- | --- |
| Native ARM64 VST3 bundle and standalone app build | Passed |
| FX bypass / 0% Mix bit transparency | Passed |
| Six distinct distortion responses, DC, neutral Amount/Tone, dark/bright spectral balance | Passed |
| Chorus exact impulse delay, feedback decay, width mono/stereo and rate modulation | Passed |
| FX extremes at 8, 44.1, 48, 96, 192 and 384 kHz; reset removes tails | Passed |
| FX v2 save/restore, 15-parameter legacy migration with FX disabled | Passed |
| Actual VST3 FX audio automation and state restore | Passed |
| FX page controls, hiding sampler controls, paired edits and shared piano | Passed |
| Hosted mouse click preserves NSWindow first responder; Backspace reaches host once | Failed against 0.4.0; passed after hosted focus fix |
| Numeric text Backspace stays local; commit returns focus to host | Passed |
| Native popup/segment actions after numeric editing release focus | Regression found during review; fixed and retested |
| DSP under AddressSanitizer and UndefinedBehaviorSanitizer | Passed |
| Forward, reverse and ping-pong sample sequences | Passed |
| Forward/reverse one-shot completion and loop release | Passed |
| Sample-rate conversion, octave transposition and custom loop bounds | Passed |
| Polyphony, stealing oldest voice and channel/note-ID isolation | Passed |
| Two-frame loops with extreme pitch ratios | Passed |
| Fade In/Out reduce discontinuous loop seam without shortening period | Passed |
| Measured pitch and source duration with Keep speed on/off | Passed; results below |
| Rate 0.25×, 0.5×, 2× and 4× retains 440 Hz while changing duration | Passed |
| All eight musical lengths at 120 BPM, including a non-4/4 bar | Passed |
| Forward/reverse/ping-pong full cycle length on a selected subregion | Passed |
| Speed/tempo automation updates running position without restart | Passed |
| Focus stop affects UI voices, including one-shots, independently of same-pitch/channel host MIDI | Passed |
| Tune automation does not change transport speed or rewind position | Passed |
| Exact 2048-sample delay at unity, including short one-shot tail | Passed |
| Identical stereo channels remain identical through pitch shifting | Passed |
| Concurrent sample replacement with audio rendering | Passed |
| Embedded PCM v2 round trip, v1 migration and malformed/truncated state rejection | Passed |
| Dynamic VST3 module loading, factory and single-component controller | Passed |
| Stereo output and MIDI input bus negotiation | Passed |
| Float32/float64 rendering at 48/44.1 kHz | Passed |
| MIDI sample offset and parameter automation offset | Passed |
| VST3 latency reporting, Keep speed switch and hidden legacy parameter | Passed |
| VST3 requests tempo/time signature; audio length follows 4/4, 7/8, 3/4 ProcessContext and manual fallback | Passed |
| Invalid/missing host timing safely uses manual BPM and 4/4 | Passed |
| VST3 editor creation, attachment, removal and reference lifecycle | Passed |
| Native Cocoa rendering and visual inspection | Passed: graphite/blue reference layout, Preview/Panic absent |
| Editable Start/End/Length, units, malformed/negative/oversized input and minimum region | Passed |
| Root dropdown and Free/Sync restoration of musical length | Passed |
| Octave controls remap mouse keys and release UI voices | Passed |
| Former Preview/Panic hit regions no longer trigger commands | Passed |
| S/E separation for short regions at both sample ends | Regression reproduced on old geometry, then passed after fix |
| VST3 reported editor size matches native child bounds | Passed |
| Whole-region dragging and both-edge clamping preserve region length | Passed |
| Outside clicks, S/E handle dragging without an initial jump | Passed |
| Dragging within two pixels of a boundary inside the region moves the range | Passed |
| Zoomed range dragging, Keep speed toggle, output knob/reset, fades | Passed |
| Playback/zoom buttons, onscreen keys and paired host edit gestures | Passed |
| Rate drag/reset, Length dropdown, locked sync speed, editable fallback BPM and host BPM display | Passed |
| Escape, Return/Enter, Space, Tab, navigation/delete and F1–F35 delivered to next responder | Passed |
| All 255 combinations of the eight independent modifier flags delivered to host, including repeats | Passed |
| Physical-key note ownership across changed modifiers/layout and repeat events | Passed |
| Keyboard/mouse note release on window/app focus loss, responder change and detach | Passed |
| WAV, AIFF and FLAC decoding of generated fixtures | Passed |
| Ad-hoc signatures | Passed |
| Runtime dependency inspection | Only macOS system frameworks/libraries |
| Project update and VST3 installation in isolated temporary directories | 0.5.0 updater/install/backup workflow checked in isolated temporary directories |
| Standalone application launch | 0.5.0 built/signed; native editor exercised by the Cocoa test, standalone audio not manually auditioned |
| Ableton Live integration and physical trackpad pinch | Not manually tested |
| Developer ID signing / notarization | Not performed |

Commands: `bash scripts/build.sh`, `bash scripts/test.sh`, `bash scripts/benchmark.sh`.
Native screenshots are produced as `build/ui-preview.png`, `build/ui-zoom-preview.png` `build/ui-sync-preview.png` and `build/ui-fx-preview.png`.
The checked initial view is also kept at `docs/preview.png`.

## Pitch measurements

Input: stereo 440 Hz sine, 96000 frames at 48 kHz, root note 60. Output frequency measured by FFT with interpolated peak; source duration counted separately from the processing delay and tail.

| MIDI note | Tune | Keep speed | Output frequency | Source duration |
| --- | --- | --- | --- | --- |
| 60 | +12 st | On | 879.977 Hz | 2.000 s |
| 60 | −12 st | On | 220.019 Hz | 2.000 s |
| 60 | +7 st | On | 659.261 Hz | 2.000 s |
| 72 | 0 st | On | 879.977 Hz | 2.000 s |
| 72 | −12 st | Off | 440.020 Hz | 1.000 s |
| 60 | +12 st | Off | 879.977 Hz | 2.000 s |

Rate tests use a four-second 440 Hz sample with Tune = 0 and Keep speed on:

| Rate | Measured frequency | Source duration |
| --- | --- | --- |
| 0.25× | 440.020 Hz | 16.000 s |
| 0.5× | 440.020 Hz | 8.000 s |
| 2× | 440.020 Hz | 2.000 s |
| 4× | 440.020 Hz | 1.000 s |

## Performance observation

Release-optimized 0.5.0 engine, **Distortion + Chorus enabled**, 16 simultaneous stereo voices, Keep speed on, Tune +7, 48 kHz: 10 seconds of audio rendered in **5.019 seconds** on this Mac (50.19% of one realtime interval). This is an offline average, not a guarantee of glitch-free operation for every DAW buffer size or system load. Buffers and FFT setup are allocated before rendering.

Actual Ableton shortcut routing, physical trackpad gestures and sound quality on music still need manual testing in the user's DAW. Focus-loss and keyboard ownership are exercised by native Cocoa tests. The VST3 test loads the actual built bundle in an NSWindow, clicks the editor, sends Backspace through window dispatch, edits a numeric field and verifies focus return. Live itself has not been used to validate this build. Phase-vocoder processing can smear transients; the tests establish frequency, duration and state/event behavior, not perceptual transparency.

## Redesign review

A separate read-only code review found overlapping S/E tags on short loops near sample edges. A new regression reproduced the wrong-boundary edit (Start moved from 0.99 to 0.979163 when targeting E); drawing and hit testing now share separated tag geometry, and the full test suite passes. No other critical, important or minor findings were reported. Reference fidelity was checked by inspecting native screenshots; actual Ableton shortcut handling and musical audition remain manual checks.

## 0.5.0 review

Independent read-only review checked DSP stability/realtime behavior, reset paths, old state loading, routing, UI hit handling and hosted focus. It identified the numeric-field → popup/segment focus case. The added regression failed before the fix, passed after it, and the fresh full suite passed. Reviewer reported no remaining Critical/Important/Minor findings.

## 0.5.1 source-spectrum correction

Failing reproduction: 3-second 48 kHz sine, 120 BPM, Sync 1/32 (48×), FX/fades off. Before correction, original-frequency amplitude at 1–18 kHz was approximately 1e-16 to 1e-10. After correction, every tested tone (220, 1000, 6000, 10000, 18000 Hz) measures **0.5** in both Forward and Reverse, matching its input amplitude.

Fresh `build/test-0.5.1.log` reports all tests passed, including ASAN/UBSAN, source bandwidth, velocity-safe 1→4→1→.25→1 speed edits, Tune ±12, one-shot duration/latency, block-vs-continuous drain audio identity, an already-transposed first speed edit, and localized Hann-windowed 6 kHz attacks at six source positions in both one-shot directions. Existing engine, FX, native VST3 host, UI, keyboard and signature checks also pass.

Independent review identified and verified the transposed-transition and sparse-source-window attack cases. After fixes, a separate probe found the intended 2 kHz transposed output at amplitude≈0.272 before/during/after the edit, with wrong 1 kHz≈0.00004. Localized attacks remained audible across all five modes and at sample endings; no remaining actionable findings. Source selection prioritizes stronger attacks and cannot preserve every overlapping event independently at extreme compression.

Release benchmark with16 voices, Tune+7 and both FX enabled: 10 seconds at48kHz took **5.234s** in Free1× and **5.773s** in Reverse1/32 (52.34% and57.73% of realtime). Offline averages only. Actual Live playback and this user's specific sample were not auditioned.

## 0.5.2 horizontal panning

The horizontal-scroll delta is subtracted from viewport start instead of added. This reverses X panning over both waveform views and Shift-scroll panning. The vertical/pinch zoom branches and mouse-drag handlers are unchanged. Code inspection confirms the isolated sign change; physical trackpad behavior has not been exercised in Live. Release build and the existing native/DSP/host regression suite are recorded in `build/build-0.5.2.log` and `build/test-0.5.2.log`.
