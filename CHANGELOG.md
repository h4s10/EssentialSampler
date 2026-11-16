# 0.6.0

- Added native AUv2 `.component` instrument for Logic Pro (aumu / HsLp / Hasi), alongside VST3 and standalone.
- Shares the full sampler/FX editor, 26 parameters, MIDI, embedded PCM state and host tempo/time signature with the existing engine.
- AU reports physical parameter units, 2048-sample latency, supports offset MIDI/automation, linear parameter ramps, planar/interleaved stereo float32 and repeat render pulls.
- AU uses a separate Cocoa editor class to coexist with VST3 in the same process; releasing the unit before its editor is safe.
- Installers support both formats with backups and run Apple `auval` after AU installation.
- Initial public EssentialSampler repository, MIT license, separate macOS arm64 VST3/AU release archives.
- System registry/Logic validation remains a manual post-install check: the build environment blocks AudioComponent registration. Direct AU ABI tests are separate from Apple validation.

# 0.5.2

- Reversed horizontal scroll direction over the sample overview/detail, including Shift-scroll horizontal panning.
- Vertical scroll zoom, pinch zoom, mouse dragging and audio behavior remain unchanged.

# 0.5.1

- Fixed loss of high-frequency content when independent playback speed or Sync compresses the sample, especially Reverse + 1/32.
- Spectral analysis now reads source windows at natural spacing before time compression; fixed nearby analysis hops keep frequency estimation stable at extreme ratios.
- Stronger attacks inside gaps between source windows are prioritized using the existing peak pyramid, avoiding silent omission of isolated transients.
- First speed edits of already-transposed voices retain processed overlap instead of briefly reverting to unshifted dry audio.
- Draining one-shot analysis positions no longer rewind when the host reapplies settings each block.
- Preserves velocity/envelopes, original parameter IDs/state format and reported latency; initial speed=1 dry behavior remains unchanged.

# 0.5.0

- Separate Sampler / FX tabs with the shared keyboard and Output control.
- Master Distortion → Chorus chain, both default bypassed; 12 new automatable parameters appended without changing old IDs.
- Six distortion families (Tube, Saturate, Clipping, Asymmetrical, Scream, Aliasing), Amount/Tone/Mix; nonlinear modes use 4× interpolation and output low-pass filtering.
- Stereo modulated-delay chorus with Depth, Rate, Width, Delay, Feedback and Mix; preallocated delay buffers, smoothed parameters/bypass and resettable tails.
- New ARM DSP informed by Iris 1 binary strings and bundled documentation; not a recovered or sound-identical Iris DSP port. No iZotope payload redistributed.
- Fixed host keyboard focus capture on mouse clicks. Hosted VST3 leaves computer keys to the DAW; standalone keeps note-key mapping. Numeric-field Backspace remains local during editing and commit returns focus to the host.
- Reads existing v1 and v2 states (9, 12 or 15 original parameters); old sessions default to FX off.

# 0.4.0

- Native 1280 × 860 graphite interface with blue waveform selection, Pitch/Time sidebar, lower fades/envelope/output sections and dark keyboard.
- Removed Preview, Panic and Demo buttons; samples are played from MIDI or the keyboard.
- Editable Start/End/Length fields in seconds with validation and sample-boundary clamping.
- Root note dropdown, Free/Sync selector retaining the last musical duration, and keyboard octave buttons.
- Output retains its dedicated knob and a peak meter.
- Short-region S/E labels separate vertically when they would overlap, keeping both handles reachable at sample edges.
- Existing pitch, timing, state and host-keyboard behavior preserved; UI dimensions reported consistently to VST3 hosts.

# 0.3.0

- Reserved keys and all modifier combinations pass to the host. Space and Escape no longer trigger Preview or Panic.
- Keyboard note ownership follows physical key codes; modifier/layout changes and autorepeat do not leave stuck notes.
- Losing window/app/editor focus stops UI voices, including one-shots, without interrupting host MIDI voices.
- Playback Rate 0.25×–4× changes speed independently of pitch.
- Length fits the selected region to 4 bars, 2 bars, 1 bar, 1/2, 1/4, 1/8, 1/16 or 1/32. Host tempo/time signature are requested via VST3; editable fallback BPM is available without host tempo.
- Synced length takes priority over MIDI varispeed; a ping-pong cycle includes both directions. Tempo/range changes update running voices without retriggering.
- Existing 0.1.0 and 0.2.0 states load with new timing controls at their defaults.

# 0.2.0

- Tune changes pitch independently of transport speed.
- Keep speed enables constant-duration MIDI transposition; enabled for new instances.
- Separate Output rotary knob with fine adjustment and double-click reset.
- Fade In / Fade Out replace crossfade without shortening the loop period.
- Dragging inside a loop translates its complete range and preserves its length at sample boundaries. Only S/E handles or clicks outside the region resize it.
- VST3 reports a constant 2048-sample processing latency. Pitch shifting uses a preallocated stereo phase vocoder.
- State v2 embeds the new parameters and reads v1 sessions, preserving parameter IDs and the plugin class ID.
- Update script backs up the existing project before syncing to ~/Dev/HasioLoop and installing VST3. Installers verify the staged bundle before replacing the previous plugin.

# 0.1.0

Initial Apple Silicon VST3 and standalone sampler with WAV/AIFF/FLAC loading, overview/detail waveforms, trackpad zoom, 16 voices and five playback modes.
