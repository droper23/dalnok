---
date: 2026-11-16
status: Phase 1 complete
---
# Phase 1 Exit Review

## Deliverable check (from the brief)
| Required | Status | Evidence |
|---|---|---|
| Native application window | ✅ verified | Self-test, screenshots |
| Initialize an audio device | ✅ verified | Live smoke test, `Devices` tests (enumerate and switch) |
| Import an audio file | ✅ verified | Self-test (WAV, AIFF), resampling test |
| Display a waveform | ✅ verified | Screenshots, peak-pyramid tests |
| Play and pause | ✅ verified | `LivePath` click tests (mutation-checked) |
| Seek within a timeline | ✅ verified | `seekWhilePlayingIsClickFree` |
| Track gain and pan | ✅ verified | Offline-render tests for both pan laws |
| Multiple audio tracks | ✅ verified | Tests + self-test |
| Basic trimming and moving of clips | ✅ verified | Self-test drags, undo tests |
| Save and reopen a project | ✅ verified | `Persistence`, `TwoPhaseLoad`, self-test |
| Export a mixed audio file | ✅ verified | Round-trip tests, self-test export |

Beyond the brief: named undo and redo for everything, fades and crossfades, solo, track reorder,
rename, and delete, ⌘K command palette, output-device switching with fallback, meters, relinking, a
copy-to-project option, a JSON command API, a CLI, and a public parity page.

## Measurements (release build, M3 Max, single-threaded engine, 512-frame blocks)
| Tracks (stereo, equal-power fades) | Live path avg / worst per block | Load | Offline |
|---|---|---|---|
| 8 | 10.4 / 36.8 µs | 0.1% | 724× realtime |
| 64 | 79.5 / 183.1 µs | 0.7% | 92× realtime |
| 256 | 316.9 / 721.9 µs | 3.0% | 23× realtime |

Measured with `dalnok-cli bench`, which uses no plugins or DSP and keeps media in RAM. These numbers
show engine overhead scales linearly, at about 1.2 µs per track per block. They don't predict real
sessions, where plugins will dominate.

## What we learned
- **Self-tests that drive the real menus found bugs that unit tests couldn't:** menus disabled when the
  window wasn't key, and unmodified shortcuts stealing typed characters (AppKit consumes matching key
  equivalents even when the item is disabled).
- **Mutation checks are worth doing.** A click test passed with de-clicking turned off until it was
  fixed to compare across buffer boundaries.
- **Whole-model snapshot undo** has held up. Edit-heavy stress (≈950 structural edits per second
  during playback) shows no audio impact.

## Carried into Phase 2
- **Recording** (top priority): input devices, arming, monitoring, crash-safe capture.
- **Disk streaming.** Media is fully in RAM (≈23 MB per stereo minute).
- **Autosave and crash recovery.**
- Multi-core graph (not needed at current loads; revisit with plugins).
- Theme work (light and analog), custom controls, multi-select and nudge.

## Decision
Phase 1 is complete. Proceed to **Phase 2: recording and editing**, starting with an ADR for the
recording architecture: a lock-free capture ring, a disk-writer thread, and crash-safe file finalization.
