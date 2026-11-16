# Audio Unit and macOS release

Add an AUv2 stereo instrument (aumu / HsLp / Hasi) with the same engine and Cocoa editor as VST3. Keep all parameter IDs and the embedded-sample state format. AU values use physical units; the wrapper converts to the engine's normalized values. MIDI and automation events have sample offsets, rendering uses preallocated storage, and host callbacks supply tempo and meter. AU gets distinct Objective-C class names so both formats can coexist.

1. Write a public AudioUnit API host test: factory, parameters, audio/MIDI timing, state, stream formats, reset, native editor.
2. Implement a native AUv2 wrapper using the system AudioToolbox interfaces; compile and sign the component alongside VST3 and standalone.
3. Run host and existing regression tests, attempt Apple validation, review and fix issues.
4. Extend installers, document Logic setup and actual validation limits, package macOS arm64 releases.
5. Add MIT license (preserve dependency licenses), prepare EssentialSampler repository and publish source/release artifacts to the user-authorized GitHub repository if access permits.

## Completion evidence

- Native component, VST3 and standalone built/signed at 0.6.0.
- Existing regression suite passed; final AU direct-interface suite and ASAN/UBSAN pass.
- Independent review found automation ordering/lifetime issues and overflow recovery; all fixed with regressions and reviewed again.
- Public AudioComponent registry test unavailable in sandbox; installation and Logic validation documented as pending.
- Both installers and project updater verified twice in isolated temporary directories, including backups.
- MIT license and three binary packages prepared for user-authorized GitHub publication.
