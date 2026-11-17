# Handoff prompt: continue the Dalnok DAW

You are continuing development of **Dalnok**, an open-source (GPL-3.0-or-later) DAW for macOS.
Repo: `~/Projects/Code/DAW` (GitHub `droper23/dalnok`, private). The repo is also the owner's Obsidian
vault. The public parity page is built from `site/` and published to `droper23/dalnok-status` by
`scripts/publish-site.sh`. The owner is the product owner and doesn't write code. They want
world-class UI, honest verification, and milestone check-ins.

## Read first (in order)
1. `AGENTS.md`: rules. The audio thread must stay nonblocking, every edit is an engine command,
   nothing is reported without evidence, and nothing derived from the owner's projects is ever published.
2. `CURRENT_STATE.md`: what's verified, known defects, and the next action.
3. `09 - Decisions/ADR-0001…0007`, `06 - Design/UI Audit 2026-11-16.md`, `06 - Design/Track Colors.md`.

## Current objective (update this section each milestone)
**Phase 2: recording.** ADR-0008 is written. Implement its bounded capture ring and disk writer with failure and recovery tests, then same-device AUHAL input, record-arm, monitoring, and long-duration capture. Scarlett hardware is needed for loopback and hardware validation.

**Just finished (M8):** knobs are now a layer-based `RotaryKnob` (`Controls.swift`): a flat face and pointer
at rest. On hover, drag or focus, the face shrinks (0.68×, 160 ms) to reveal a glowing ring in the track
color. `PanKnob` subclasses it. `site/screenshots/knobs.png` shows the rest and revealed states.
**Latest:** gain and pan are labeled knobs; the gain halo follows the post-fader peak. Space play/pause is already present and self-tested. More keyboard shortcuts were requested. A synthetic Logic project and FCPXML export both import, but the XML rendered and shortened the audio, so exact native placement remains unverified.

## Done so far (all committed, CI green)
- **Phase 1:** engine, C API, AppKit UI, undo, projects, export, fades, solo, relink, copy-on-save, meters,
  device switching, ⌘K palette.
- **Migration (M5):** import REAPER, Ableton, FCPXML, stems, and Logic `.logicx` (experimental). Plus
  onboarding, shortcut presets, the Concept Guide, and old-DAW vocabulary in ⌘K.
- **Time stretch (M6):** Signalsmith, rendered in the background (`stretch_cache.*`, `engine/dsp`).
- **UI pass 1 (M7):**
  - OKLCH rainbow track colors starting at green (`Theme.swift`)
  - custom `FaderControl`, `PanKnob`, `ToggleChip`
  - new headers, clips, control bar, and empty state

## Verify
- `swift build && swift test`: 64 tests.
- `scripts/check.sh`: tests, the live audio smoke test, and the app self-test (needs a GUI session).
- `DALNOK_SANITIZE=1 scripts/check.sh` adds ASan and TSan.
- `.build/debug/Dalnok <wav files> --selftest <dir>`: end-to-end UI checks, ending in `SELFTEST: PASS`.
- `.build/debug/Dalnok <wav files> --screenshots site/screenshots`: real-app screenshots (no personal data).
- `scripts/ci/rt-effects.sh`: real-time effect analysis. CI runs build-test, sanitizers, and rt-effects.

## Open items and known gaps
- Logic `.logicx` region placement is unverified. Needs a Final Cut Pro XML export from the owner.
- VoiceOver labels exist but haven't been tested with VoiceOver running.
- No group tracks yet (Phase 4); group color tinting is specified but unbuilt.
- No disk streaming: media is fully decoded in RAM.

## Session-end checklist
Update `CURRENT_STATE.md`, `CHANGELOG.md`, `10 - Development Journal/<date>.md`, `site/parity.json`
(only mark steps `verified` with evidence), and this file. Commit with the attribution trailer
(`Co-Authored-By: …`). Run `scripts/publish-site.sh`, then check CI with `gh run watch`.
