# Dark sampler editor

The user's supplied image is the visual reference: neutral graphite, restrained borders, system typography, blue selection/sliders, overview above detail, Pitch/Time on the right, fades/envelope/output below, keyboard at the bottom. Remove Preview and Panic entirely from the interface.

Approach: evolve the existing native Cocoa editor and keep its C++ sampler, parameter IDs, and state format. A web view would add dependencies and keyboard/focus risks; a theme-only recolor would not deliver the supplied composition. The native approach follows the existing implementation and the requested reference.

Builder choices: fixed 1280 × 860 canvas; keep the dedicated Output knob from the user's earlier request; introduce editable Start/End/Length fields, Root note dropdown, Free/Sync selector and keyboard octave buttons. Retain manual fallback BPM. Omit the reference's Snap toggle because snapping is not an existing/requested playback feature. Native window decorations belong to the host and are not painted as fake buttons.

Maintain loop dragging, S/E handles, zoom/pan, note-off on focus loss, host keyboard shortcuts, all playback modes, speed/pitch independence and existing host automation. New numeric edits clamp to the sample and a minimum two-frame region; invalid input restores the actual value. Unrelated MIDI must keep playing when UI focus changes.

Verify with native render inspection, control/event tests, existing keyboard/DSP/VST3 tests, signed bundles and release packaging. Source and builds stay in the authorized workspace; installation to ~/Dev and user VST3 remains the existing user-run updater under current write permissions.
