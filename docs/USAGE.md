# User guide

## Load and play

Choose **Load sample** or drop a mono/stereo WAV, AIFF or FLAC file onto the editor. Play notes from your MIDI controller, the host's computer MIDI keyboard or the onscreen keyboard. The standalone app also supports the unmodified keys `A W S E D F T G Y H U J K O L P ;` starting at MIDI 60 in its initial octave.

The overview shows the entire sample. The large waveform shows the current zoomed region. The blue range between S and E is the playback region. Start, End and Length are editable in seconds.

## Waveform and controls

| Action | Gesture |
| --- | --- |
| Zoom around the pointer | Trackpad pinch or vertical scroll |
| Pan through the sample | Horizontal trackpad scroll; Shift-scroll also pans |
| Move the loop range | Drag inside the blue range; its length is preserved |
| Move a boundary | Drag S / E or drag outside the selected range |
| Set exact bounds | Edit Start or End in seconds |
| Change region length | Edit Length; Start stays fixed and End is clamped to the sample |
| Fit the waveform | Click Fit |
| Change keyboard octave | Click − / + beside the keyboard |
| Adjust Output | Drag its knob vertically; hold Shift for finer adjustment |
| Reset a slider or Output | Double-click |

Horizontal scrolling uses the direction introduced in 0.5.2. Boundary markers remain separately selectable even for very short regions. Changing octave releases notes held by the editor.

## Playback modes

| Mode | Behavior |
| --- | --- |
| One-shot | Plays Start to End once; ignores MIDI Note Off |
| Forward | Loops forwards; Note Off starts the Release envelope |
| Reverse | Loops backwards; Note Off starts Release |
| Ping-pong | Alternates direction without repeating the endpoint sample |
| Reverse shot | Plays End to Start once; ignores MIDI Note Off |

Changing playback mode stops existing voices; play a new note afterwards. Fade In applies near S and Fade Out near E, so reverse playback encounters those regions in reverse order. Fades repeat each cycle and are limited to half the loop region. They do not shorten the loop period.

## Pitch and time

**Root note** is the MIDI note corresponding to the sample's original pitch at Tune = 0. Octave names differ between DAWs; the MIDI note number is unambiguous.

**Tune** changes pitch by up to ±24 semitones without changing playback speed. **Keep duration** is on by default and also makes MIDI transposition independent of duration. Turning it off restores conventional sampler speed changes for MIDI notes; Tune still changes only pitch.

In **Free** mode, Speed ranges from 0.25× to 4×. For example, 2× halves duration and 0.5× doubles it while preserving pitch. Double-click Speed to return to 1×.

In **Sync**, the selected region is fitted to a musical length using the host's tempo and time signature:

| Length | Interpretation |
| --- | --- |
| 4 bars, 2 bars, 1 bar | Measures in the host's time signature |
| 1/2 | Half note; two quarter-note beats |
| 1/4 | Quarter note; one beat |
| 1/8, 1/16, 1/32 | Eighth, sixteenth and thirty-second notes |

At 120 BPM, one bar lasts 2 seconds in 4/4, 1.5 seconds in 3/4, or 1.75 seconds in 7/8. Ping-pong length covers the complete forward-and-back cycle. MIDI triggers playback immediately; it does not wait for a grid boundary.

Sync calculates speed automatically and keeps duration independent of MIDI pitch. Returning to Free restores the previous Speed and Keep duration settings. Tempo or region edits update active voices without restarting them. When host timing is unavailable, the editable Tempo field supplies a fallback BPM (120 by default), with 4/4 as the fallback meter. Standalone uses these fallback values.

## FX

Signal flow: **voices → Distortion → Chorus → Output**. The effects have independent bypass switches and both default to off. Changing tabs does not alter the sound.

| Effect | Controls |
| --- | --- |
| Distortion | Tube, Saturate, Clipping, Asymmetrical, Scream, Aliasing; Amount, Tone and Mix |
| Chorus | Depth, Width and Mix; Rate 0.05–5 Hz; Delay 1–30 ms; Feedback 0–90% |

Tone at 50% is neutral; lower settings darken the sound and higher settings brighten it. At neutral Tone, Amount = 0 leaves the distortion signal clean. Chorus Width = 0 makes its wet signal mono. Output follows the effects, so reducing Output does not change distortion drive.

Parameters and bypass transitions are smoothed. Moving chorus Delay or Rate may cause audible pitch modulation, as expected from a modulated delay.

## Keyboard focus

Hosted VST3 and AU editors leave keyboard shortcuts to the DAW. Backspace, Escape, Return/Enter, Space, Tab, arrows, function keys and modified combinations are not assigned plugin commands. While editing a number, Backspace edits that field; committing returns focus to the host.

The plugin's own letter-to-note mapping is standalone-only. Editor-triggered notes stop when its window loses focus, another app becomes active or the editor closes, including one-shots. MIDI voices from the DAW remain independent. Ordinary Note Off still does not interrupt one-shot playback.

## State and compatibility

The plugin embeds the sample's PCM and parameter state in the DAW project. The original file is not needed after saving. VST3 and AU share the internal state format, but changing plugin format in a DAW project is not an automatic migration.

- States from 0.1.0 load with the old Crossfade mapped to both loop fades and Keep duration disabled. Tune now preserves duration, so older sessions with nonzero Tune can sound different.
- Older 0.2.0 states receive Speed = 1×, Free mode and 120 BPM defaults.
- Pre-FX states receive disabled distortion and chorus. Versions before 0.5.0 cannot read newer 27-slot states.
- Existing VST3 plugin and parameter IDs remain unchanged. The old Crossfade slot is hidden and reserved.

## Sound and performance limits

The stereo phase vocoder uses a 2048-point FFT with 8× overlap. At zero shift, a fixed delay avoids FFT pitch processing. Latency remains constant when Tune or Keep duration changes; the DAW compensates recorded playback, while live playing still incurs the delay.

The 0.5.1 bandwidth fix preserves original high-frequency content during fast Sync playback, including Reverse + 1/32. At extreme compression, stronger attacks are prioritized within analysis intervals, and adjacent events can merge. This does not guarantee perceptual transparency for all material.

Conventional upward MIDI resampling can alias. There is no formant preservation or dedicated transient mode. See [verification](VERIFICATION.md) for measured behavior and the [README](../README.md) for platform limits.
