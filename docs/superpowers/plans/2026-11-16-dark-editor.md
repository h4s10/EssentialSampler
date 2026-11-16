# Dark Editor Implementation Plan

> For agentic workers: execute inline using the executing-plans workflow. The workspace is not a git repository; use release archives as checkpoints and do not invent branch/commit operations.

**Goal:** implement the supplied dark minimal sampler reference without Preview/Panic.
**Architecture:** native Cocoa layout and controls over the existing model; preserve audio/state contracts. Share editor dimensions with VST3/standalone.
**Tech Stack:** Objective-C++, Cocoa, C++17, existing scripts and VST3 interfaces.
**Spec:** ../specs/2026-11-16-dark-editor-design.md

## Global Constraints
- Apple Silicon / macOS 27; no new dependencies.
- Fixed 1280 × 860 canvas; no Preview or Panic actions.
- Preserve existing parameter IDs and focus/keyboard behavior.

## Review Focus
- Numeric boundaries at sample ends and malformed text.
- Free/Sync switching preserves the chosen musical duration.
- Octave changes release held UI keys before remapping.
- New controls and waveform hit areas do not overlap.
- Host automation refreshes native controls without overwriting text being edited.

### Task 1: Native editor and interaction coverage
- [x] Rewrite UI smoke assertions for the reference layout and add numeric-region, Root, Free/Sync and octave behaviors; run against old editor and observe expected failure.
- [x] Implement geometry, drawing, native fields and interaction wiring in src/Editor.mm; share canvas dimensions via src/Editor.hpp and host wrappers.
- [x] Update keyboard test mouse coordinates; run build/test scripts and inspect native render. Correct functional/visual failures at their cause.

### Task 2: Release and review
- [x] Update README, CHANGELOG and verification evidence; build/package 0.4.0 preserving older bundles.
- [x] Review the final code and test evidence against the supplied reference and this spec; resolve important findings.
- [x] Verify signatures and archives; deliver actual screenshot and updater path without claiming installation outside writable roots.
