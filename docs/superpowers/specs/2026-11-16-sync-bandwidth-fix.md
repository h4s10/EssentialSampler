# Sync bandwidth fix — 0.5.1

Reported symptom: upper frequencies disappear at 1/32 in Reverse.

Reproduction: 3-second sine samples at 48 kHz, Sync 1/32 at 120 BPM (speed 48×), Tune=0, FX/fades off. Both Forward and Reverse lose the original 1, 6, 10 and 18 kHz components (original-frequency amplitude about 1e-16–1e-10 instead of 0.5). 220 Hz survives. The engine resampled at the accelerated transport speed before shifting pitch down; the missing bandwidth was already irreversibly lost.

Correction: for non-unity independent speed, construct FFT source windows at the natural reading rate. Window centres follow source transport, so tempo still controls duration. A nearby fixed 256-sample analysis window supplies instantaneous frequency regardless of extreme jumps between transport centres. Synthesis advances at the output hop and uses the actual requested pitch, without inverse-speed pitch correction. Reverse, ping-pong and one-shot boundaries are mapped in source coordinates. Fades stay source-spatial; velocity, attack/release and one-shot ending are delayed and applied to spectral output exactly once. Existing exact dry path at initial speed=1 remains unchanged.

On the first speed edit during a voice, retain processed streaming overlap separately while starting source overlap, preserving synthesis phase. Only initially dry voices warm against delayed dry audio before crossfading. Keep the source path for that voice when speed returns to 1 to avoid combining envelope-scaled streaming overlap and unscaled source overlap. Note reset clears all mode/history state. No audio-thread allocation, new parameter IDs, state-format or advertised latency change.

Verification: fail/pass high-frequency regression at 48× in both directions; velocity-safe speed automation 1→4→1→.25→1; Tune ±12; short one-shots; original engine, FX, VST3 audio, UI and keyboard regressions; performance with 16 voices. This establishes spectral/transport behavior, not perceptual transparency on arbitrary music at extreme compression.

Review-driven regressions: preserved transposed output during the first speed edit; excluded draining voices from configure-time position clamping; compared continuous and block-wise one-shot renders. At source hops wider than an FFT window, peak-pyramid searches select a stronger attack in the covered transport interval, so isolated bursts between nominal windows are not discarded. This prioritizes dominant events and does not guarantee every overlapping event is individually retained at extreme compression.
