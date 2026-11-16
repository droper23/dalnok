---
updated: 2026-11-16
phase: 1 (Minimum working DAW)
milestone: M1 done, M2 next
---
# Current State

## Latest verified build
- `main`, 2026-11-16. macOS 27.3, Xcode 27.2, Swift 6.4.2, Apple clang 21, M3 Max.
- CI: green on GitHub Actions (run 43959596606).
- `swift build`: 0 warnings. `swift test`: 10 tests (21 cases) pass. The `atrium-cli play --churn` live smoke test passes.

## Architecture (now)
C++20 engine (`engine/`) → C API (`atrium.h`) → AppKit UI (`app/macos/`). The control thread compiles the
session into immutable `RenderState` snapshots and hands them over through an atomic slot. Retired
snapshots come back through an SPSC queue and are freed off the audio thread. Gain, pan, and mute are
atomics. See [[System Overview]] and [[Real-Time Processing]].

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
| Compile-time real-time safety on the callback path | Negative test: allocation fails the build |

## Not yet / incomplete
- Moving and trimming clips in the UI. The engine supports offset and length; the UI can't edit them yet.
- Saving and reopening projects. Export from the UI.
- An engine-side project model with a command system and undo. The UI currently mirrors session state (`Session.swift`).
- Disk streaming. Media is fully decoded into RAM, about 23 MB per stereo minute at 48 kHz.
- Device selection and handling sample-rate changes. The default output only; the engine rate is fixed at launch.

## Known defects
- Seeking while playing fades out and in (correct), but there's no automated test for click-free behavior.
- Files with more than 2 channels keep only the first two.
- When scrolled, track header rows can draw over the "TRACKS" label area.
- CI (GitHub `macos-15`, Xcode 16.4, Apple clang 17) passes, but that clang lacks `[[clang::nonblocking]]`, so the real-time effect checks only run locally (Apple clang 21). Fix: a newer runner image or a Homebrew LLVM job.

## Active objective
Phase 1, M2: a project model and command system in the engine, then clip move and trim, save and open
(a versioned JSON project), and export from the UI.

## Next recommended action
Write ADR-0005 (project model and command architecture). Then implement `atrium_cmd_*` commands with undo
in the engine, expose model queries through the C API, and delete the UI mirror.

## Links
[[00 - Project Home]] · [[02 - Master Roadmap]] · [[Foundation Evaluation]] · [[Baseline 2026-11-16]] · [[2026-11-16]]
