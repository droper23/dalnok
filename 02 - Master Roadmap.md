# Master Roadmap

Status: ✅ verified · 🔶 in progress · ⬜ planned

## Phase 0: Research and architecture ✅
Foundation evaluated ([[Foundation Evaluation]]), license chosen (GPLv3+), architecture defined, repo and vault set up.

## Phase 1: Minimum working DAW 🔶
- **M1 ✅** Native window, audio device, import, waveform, play/pause/seek, multiple tracks, gain/pan/mute,
  offline render and WAV export (engine/CLI).
- **M2 ✅** Engine-owned model, command catalog, snapshot undo. Clip move, trim, split, and delete in the UI.
  Project save and open (JSON v1, atomic). Export Mix. Offline media.
- **M3 ⬜** Command palette (⌘K), output device picker and sample-rate changes, meters, background project loading.
- **M4 ⬜** Relink offline media, copy-to-project option, project templates. Phase 1 exit review.

## Phase 2: Recording and editing ⬜
Input and recording (with a Scarlett test rig), monitoring, split, fades, crossfades, autosave and crash
recovery, basic routing, disk streaming.

## Phase 3: MIDI and instruments ⬜
MIDI tracks, recording and playback, piano roll, quantize, velocity, tempo and meter map, first stock instrument.

## Phase 4: Professional production ⬜
**VST3 hosting (first format)** with generic parameter panels, then AU and CLAP. Mixer, buses, sends,
sidechains, automation, delay compensation, **comping and take folders**, track stacks.

## Phase 5: Creative workflows ⬜
**Unified clip launcher** on the same tracks as the timeline. Flex-style time and pitch editing
(Signalsmith Stretch). Modulation system, racks, scripting API, macros, workspaces.

## Phase 6: Refinement ⬜
Performance, accessibility, theme system (including analog), DAWproject interchange, Windows and Linux front ends, local AI assistance.
