---
updated: 2026-11-16
phase: 2 (Recording and editing) — Phase 1 complete
milestone: Phase 1 M1–M4 done; Phase 2 starting
---
# Current State

## Latest verified build
- `main`, 2026-11-16. macOS 27.3, Xcode 27.2, Swift 6.4.2, Apple clang 21, M3 Max.
- `swift build`: 0 warnings. `swift test`: 45 tests pass, including the mutation-checked click tests.
  `scripts/check.sh` passes, including the live audio smoke test and the app self-test (69 checks).
- Engine tests are clean under AddressSanitizer and ThreadSanitizer (CI job `sanitizers`). The app self-test is clean under ASan.
- Phase 1 exit review: [[Phase 1 Exit Review]].
- **Public parity page:** https://droper23.github.io/dalnok-status/ (source in `site/`, published by `scripts/publish-site.sh`).
- CI has two jobs: build + test, and real-time effect analysis with Homebrew LLVM.

## Architecture (now)
C++20 engine (`engine/`) → C API (`dalnok.h`, v2) → AppKit UI (`app/macos/`). The **engine owns the
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

## Not yet / incomplete
- Relinking offline media from the UI. Autosave and crash recovery (Phase 2).
- Disk streaming. Media is fully decoded into RAM, about 23 MB per stereo minute at 48 kHz.
- Device selection and handling sample-rate changes. The default output only; the engine rate is fixed at launch.

## Known defects
- Seeking while playing fades out and in (correct), but there's no automated test for click-free behavior.
- Files with more than 2 channels keep only the first two.
- The unsaved-changes sheet (Save / Don't Save / Cancel) is exercised manually only. The self-test avoids modal sheets.
- Device-unplug fallback is polled every 0.5 s and untested with real hardware (no Scarlett connected during development).
- Peak meters only. No LUFS or RMS yet.

## Active objective
Phase 2: recording. Recording integrity outranks everything else.

## Next recommended action
Write ADR-0006 (recording architecture): input via AUHAL or an aggregate device, a lock-free capture
ring from the audio thread, a disk-writer thread writing CAF or WAV with periodic header finalization,
and recovery of partial takes after a crash. Then build input device selection and record-arm, with a
long-duration capture test. At every milestone, update `site/parity.json`, regenerate screenshots
(`Dalnok <files> --screenshots site/screenshots`), and run `scripts/publish-site.sh`.

## Links
[[00 - Project Home]] · [[02 - Master Roadmap]] · [[Foundation Evaluation]] · [[Baseline 2026-11-16]] · [[2026-11-16]] · [[Project Format]]
