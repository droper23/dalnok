---
status: accepted
date: 2026-11-16
---
# ADR-0007: Time-stretch and pitch via background-rendered clip audio

**Context.** Real imports from the owner's projects included about 6,000 warped Ableton clips and many
REAPER items at changed rates. Logic users expect Flex-style stretching. The audio thread must stay
wait-free.

**Decision.**
- **Library.** Signalsmith Stretch 1.4.0 + Linear 0.6.6 (MIT, vendored, Accelerate FFT), in a
  separate `DalnokDSP` target compiled `-O3` in every build.
- **Clip model.** `rate` (source frames per timeline frame), `pitch` (semitones), and `preservePitch`
  (off = varispeed, cubic resampling). A stretched clip plays source `[offset, offset + length × rate)`.
- **Rendering.** Stretched audio is rendered **off the audio thread** into a `StretchCache` keyed by
  (media, offset, source span, output length, pitch, mode). A worker thread renders only what the current
  arrangement needs; stale jobs are dropped and a generation counter discards results from a previous
  project. Until a render is ready the clip is silent and marked "rendering…". Project loads and imports
  precompute renders in their background prepare step. Offline render and export render synchronously
  first, so output is deterministic.
- **Importers.**
  - REAPER `PLAYRATE` → rate, pitch, and preserve-pitch.
  - Ableton warp markers → **one clip per warp segment**, each with its own rate.
  - Ableton Re-Pitch mode and transposing unwarped clips → varispeed.

**Consequences.**
- The audio thread is unchanged: it still only copies samples.
- Memory: stretched audio is held decoded, like other media. Disk streaming later will cover both.
- Editing warp/flex markers inside a clip needs the same cache keyed per segment. Planned.

**Rejected:** real-time streaming stretch per clip on the audio thread. That means per-clip DSP state,
seek complexity, and CPU spikes, for no benefit at this stage.
