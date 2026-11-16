# Audio Engine

## Signal flow (Phase 1)
Clip (planar float in RAM) → track bus (stereo; mono duplicated) → gain, pan, and mute (smoothed) → master sum → transport fade → device.

## Pan laws
- **Mono-source tracks:** constant power, compensated to unity at center (+3 dB at the extremes), like
  Logic's "−3 dB compensated". Implemented with a polynomial sine, max error about 1e-4.
- **Stereo-source tracks:** balance (attenuates the opposite side, unity at center).

## Gain
dB to linear, clamped at +12 dB. Anything ≤ −96 dB is silence.

## Media
`Media` is immutable decoded audio at the engine rate. ExtAudioFile handles format decoding and
sample-rate conversion. The peak pyramid uses blocks of 64 × 4ⁿ frames (up to 8 levels). Queries pick
the coarsest level that's still finer than a pixel, and use raw samples below 64 frames per column.

## Planned
A graph with buses, sends, and delay compensation (Phase 4). Disk streaming with prefetch (Phase 2).
Time stretching with Signalsmith (Phase 5).
