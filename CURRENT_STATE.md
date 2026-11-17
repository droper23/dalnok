---
updated: 2026-11-16
phase: 2 (Recording and editing) — Phase 1 complete
milestone: Phase 1 + Migration (M5) + Time stretch (M6) + UI pass 1 (M7) done; Phase 2 recording next
---
# Current State

## Latest session
- Paused at the owner’s request; see `HANDOFF.md`. The optional full hardware ThreadSanitizer test was interrupted during its build and has no result. Site updates are local and have not been published.
- Experimental headless mono capture uses one selected duplex device and requires matching engine and device rates. Scarlett Solo at 44.1 kHz: both inputs captured and recovered; a 30-second take wrote 1,323,520 frames with zero reported drops. The opt-in hardware test passes. No track recording UI, monitoring, clip placement, latency calibration, durable journal, or power-loss guarantee yet.
- The capture writer's immediate-stop race was fixed; stress and ThreadSanitizer tests pass. Timestamp discontinuity and input failure are reported. `dalnok-cli inputs`, `capture-test`, and `recover-capture` are diagnostic paths, not a finished recording workflow.
- C API v9 discovers MIDI sources. Dalnok lists the Arturia MiniLab mkII; a separate 15-second Core MIDI probe observed nine note-on and eight note-off events without saving them. The MIDI 1 byte parser has native and ThreadSanitizer tests but is not connected to a device, model, or playback.
- Settings (⌘,) exposes appearance and copy-audio preference. Warm Analog and Graphite are available; theme changes apply on reopening. App self-tests and synthetic snapshots cover both themes. See [[UI Audit 2026-11-16 follow-up]] for the multi-perspective review and limitations.
- Periodic recovery snapshots and File ▸ Recover Snapshot are implemented. The app self-test verifies manual restore as a new unsaved project; `scripts/ci/recovery-smoke.sh` verifies the timer and rendering after killing an isolated app process. Power-loss validation, automatic prompting, and retention controls remain open. Snapshots are retained in Application Support/Dalnok/Recovery.
- Open accepts foreign projects and asks before import; the Logic package picker and experimental importer still need broader real-project validation. Exact Logic region placement remains unverified.

## Latest verified build
- `main`, 2026-11-16. macOS 27.3, Xcode 27.2, Swift 6.4.2, Apple clang 21, M3 Max.
- `swift build`: 0 warnings. `swift test`: 45 tests pass, including the mutation-checked click tests.
  `scripts/check.sh` passes, including the live audio smoke test and the app self-test (69 checks).
- Engine tests are clean under AddressSanitizer and ThreadSanitizer (CI job `sanitizers`). The app self-test is clean under ASan.
- Phase 1 exit review: [[Phase 1 Exit Review]].
- `swift test`: 64 tests (ASan/TSan clean). UI pass 1: [[UI Audit 2026-11-16]], [[Track Colors]]. Self-test passes, including migration, onboarding, and time stretch.
- **Public parity page:** https://droper23.github.io/dalnok-status/ (source in `site/`, published by `scripts/publish-site.sh`).
- CI has two jobs: build + test, and real-time effect analysis with Homebrew LLVM.

## Architecture (now)
C++20 engine (`engine/`) → C API (`dalnok.h`, v9) → AppKit UI (`app/macos/`). The **engine owns the
project model**: tracks, clips in z-order, and a media pool. Every edit is a named, undoable command with
whole-model snapshot undo, also reachable as JSON through the command catalog. The UI is a read-only view
that refreshes on `dalnok_model_revision`. Render snapshots reach the audio thread through an atomic
slot, and retired ones come back through an SPSC queue. See [[System Overview]],
[[Real-Time Processing]], [[ADR-0005 Project model and commands]], and [[Project Format]].

## Verified working
| Feature | Evidence |
|---|---|
| Native window: timeline, ruler, waveforms, playhead, track headers | `--snapshot` PNGs reviewed |
| Import WAV/AIFF/CAF/MP3/AAC/ALAC/FLAC, resampled to the engine rate | `loadResamplesToEngineRate` (pitch preserved at 44.1k → 48k) |
| Live playback on the default output device | CLI: transport within 1% of wall clock, 0 overloads |
| Play, pause, and seek with 5 ms de-click fades | Exercised manually and via CLI; no automated click test yet |
| Multiple tracks; gain (dB), pan (mono constant power, stereo balance), mute | Offline-render tests |
| Snapshot handoff under heavy editing during playback | 4,700 structural edits in 3 s, no crash, 0 overloads |
| Offline render and WAV export at 16, 24, and 32-bit | Round-trip tests within ½ LSB |
| Compile-time real-time safety on the callback path | Negative test: allocation fails the build (local and CI) |
| Engine-owned model; undo and redo of every edit; drag = one undo step | `UndoAndEditing` tests + self-test |
| Clip move (snapped; ⌃ bypasses), cross-track move, left and right edge trim | Self-test with synthesized drags |
| Split at playhead (⌘T), Delete, Undo/Redo with named menu titles | Self-test drives the real menu items |
| Overlapping clips: top wins; split renders seamlessly | Offline-render tests |
| Project save/open (JSON v1, atomic), relocation via relative paths, offline missing media, rejection of bad files, sample-rate rescaling | `Persistence` tests |
| New/Open/Save/Save As with unsaved-changes prompt; window title and edited dot | Self-test (prompt path: manual only) |
| Export Mix (⌘B, 24-bit WAV) | Self-test: export decodes to the session length |
| Command catalog (18 commands, JSON in and out), also from `dalnok-cli command` | `CommandCatalog` tests; CLI run |
| Click-free play, pause, seek, and gain changes on the live path | `LivePath` tests via `dalnok_engine_pump`; a mutation check proves they catch regressions |
| Command palette (⌘K): fuzzy search over every menu command with location and shortcut | Self-test |
| Output device selection (Audio ▸ Output Device), fallback when a device disappears | `Devices` tests + self-test (fallback: implemented, not automated) |
| Track and master peak meters with hold and clip indicator | `metersReportPostFaderPeaksAndReset` + self-test during playback |
| Background project open (prepare off-thread, apply on main) | `TwoPhaseLoad` test + self-test |
| Fades and crossfades (linear and equal power, drag handles, Clip menu) | `Fades` tests (numeric weights) + self-test |
| Solo (smoothed), track reorder (drag or menu), rename, delete, new | `TracksSoloOrder` tests + self-test |
| Relink missing audio (search a folder by name) | `relinkBringsOfflineClipsBack` + self-test |
| Copy audio into "Audio Files/" on save (identical files reused, clashes numbered) | `saveCopyingMediaMakesProjectSelfContained` + self-test |
| Single-key shortcuts don't steal typed text | Self-test (rename field + Space) |
| Engine scales linearly: 256 tracks = 3% of the real-time budget | `dalnok-cli bench` (see the exit review) |
| Import REAPER `.rpp` (tracks, items, fades, item gain, loops, Windows/moved paths) | `ReaperImport` tests; 6/6 of the owner's projects, all audio found |
| Import Ableton `.als` (arrangement audio, beats→time, warp markers, loops, clip gain, Live path types) | `AbletonImport` tests; 493/495 real sets parse; 95% of 6,929 file references resolved |
| Import Final Cut Pro XML (Logic's export) and stems folders | `FcpxmlImport`, `StemsImport` tests |
| Import Logic `.logicx`: EXPERIMENTAL (metadata, files, region trims verified; placement unverified) | `LogicImport` test; 30/31 real projects parse |
| Clip gain | `clip.setGain`, used by every importer |
| Time stretch, pitch, and varispeed (Signalsmith; rendered in the background; ⌥-drag a clip's end; Clip menu) | `TimeStretch` tests measure pitch and level on output; mutation-checked; self-test |
| Imports use stretch: REAPER playrate and pitch; Ableton warp markers (piecewise), Re-Pitch, transpose | `StretchImports` tests; a real set with 334 stretched clips imports in 1.7 s |
| Onboarding: "Coming from…", shortcut presets, project finder with preview, import report, Concept Guide, old-DAW words in ⌘K | Self-test |

## Not yet / incomplete
- Automatic recovery prompting, power-loss validation, and retention controls (Phase 2).
- Disk streaming. Media is fully decoded into RAM, about 23 MB per stereo minute at 48 kHz.
- Input selection in the UI and handling sample-rate changes; the engine rate is fixed at launch.

## Known defects
- Seeking while playing fades out and in (correct), but there's no automated test for click-free behavior.
- Files with more than 2 channels keep only the first two.
- The unsaved-changes sheet (Save / Don't Save / Cancel) is exercised manually only. The self-test avoids modal sheets.
- Device-unplug fallback is polled every 0.5 s and untested with real hardware (no Scarlett connected during development).
- Peak meters only. No LUFS or RMS yet.

## Active objective
Phase 2: recording, with Phase 3 MIDI foundations underway. Recording integrity outranks everything else. Time-stretch landed first (M6,
[[ADR-0007 Time stretch]]) because real imports needed it.

## Next recommended action
Connect experimental duplex capture to track arm, monitoring, take placement and the model; add a durable journal, latency calibration and power-loss testing. Connect the MIDI parser to a Core MIDI port, then implement a MIDI model, recording and playback. The Scarlett is needed for hardware and loopback validation.

## Open migration items
- Verify Logic `.logicx` placement against a real Logic **Final Cut Pro XML export** of the same project
  (needs the owner to export one). Then decode track names and take folders.
- Test the FCPXML importer on a real Logic export (only fixtures so far).

## Links
[[00 - Project Home]] · [[02 - Master Roadmap]] · [[Foundation Evaluation]] · [[Baseline 2026-11-16]] · [[2026-11-16]] · [[Project Format]]
