# Master Roadmap

Status: ✅ verified · 🔶 in progress · ⬜ planned

## Phase 0: Research and architecture ✅
Foundation evaluated ([[Foundation Evaluation]]), license chosen (GPLv3+), architecture defined, repo and vault set up.

## Phase 1: Minimum working DAW ✅ ([[Phase 1 Exit Review]])
- **M1 ✅** Native window, audio device, import, waveform, play/pause/seek, multiple tracks, gain/pan/mute,
  offline render and WAV export (engine/CLI).
- **M2 ✅** Engine-owned model, command catalog, snapshot undo. Clip move, trim, split, and delete in the UI.
  Project save and open (JSON v1, atomic). Export Mix. Offline media.
- **M3 ✅** Command palette (⌘K), output device picker with unplug fallback, track and master meters,
  background project loading, live-path click tests, public parity page.
- **M4 ✅** Fades and crossfades, solo, track reorder, rename, and delete, relink offline media,
  copy-to-project option, typing-safe shortcuts, benchmark, Phase 1 exit review.

## Migration (M5) ✅ ([[ADR-0006 Migration and import]])
Import from REAPER, Ableton, Final Cut Pro XML (Logic), stems, and Logic `.logicx` (experimental).
Migration reports, "Coming from…" onboarding, shortcut presets, old-DAW vocabulary in ⌘K, and the
Concept Guide. Grows with each phase: MIDI (P3), plugins, automation, and sends (P4), launcher (P5).

## Time stretch (M6) ✅ ([[ADR-0007 Time stretch]])
Signalsmith-based stretch, pitch, and varispeed rendered in the background. ⌥-drag stretch and the Clip
menu. Imported REAPER playrates and Ableton warp markers now play correctly.

## Phase 2: Recording and editing 🔶 (track recording, take journal and crash recovery verified; loopback latency, power loss, punch, multi-input next)
Input and recording (with a Scarlett test rig), monitoring, split, fades, crossfades, autosave and crash
recovery, basic routing, disk streaming.

## Phase 3: MIDI and instruments 🔶 (MIDI clips, live input, recording, quantize, Dalnok Poly; piano roll, tempo map, metronome next)
MIDI tracks, recording and playback, piano roll, quantize, velocity, tempo and meter map, first stock instrument.

## Phase 4: Professional production 🔶 (read-only plugin discovery; hosting plan in [[ADR-0009 Plugin hosting]])
**VST3 hosting (first format)** with generic parameter panels, then AU and CLAP. Mixer, buses, sends,
sidechains, automation, delay compensation, **comping and take folders**, track stacks.

## Phase 5: Creative workflows ⬜
**Unified clip launcher** on the same tracks as the timeline. Flex-style time and pitch editing
(Signalsmith Stretch). Modulation system, racks, scripting API, macros, workspaces.

## Phase 6: Refinement ⬜
Performance, accessibility, theme system (including analog), DAWproject interchange, Windows and Linux front ends, local AI assistance.
