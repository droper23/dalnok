---
updated: 2026-11-17
---
# Tape Machine (Analog Mode transport)

View ▸ Tape Machine (⇧⌘T). Code: `TapeDeck.swift`; physics in `ReelModel` (`Analog.swift`), shared with the small
reels beside the counter in Warm Analog.

## What it is
A second view of the same project and transport, drawn as an original two-track studio recorder: walnut cheeks,
a brushed top plate, two NAB-style metal reels with window cut-outs, tension-arm rollers, guides, an
erase/record/play head block, capstan and pinch roller, a counter, two VU meters and lit piano-key transport keys.
It never processes audio. Tape coloration would be a separate, opt-in effect (not built).

## Keys (all run the main window's commands)
RTZ (Go to Start) · REWIND / F.FWD (hold: winds the playhead at 12×; stops playback first; refused while
recording) · STOP (stops and returns to where playback started) · PAUSE (stops in place) · PLAY · REC (Record) ·
LOOP (Cycle). Lamps show the real state. PAUSE is lit when stopped away from zero. The track lamps are amber for
record-ready tracks and red while recording.

## Reel physics
- Linear tape speed v (15 ips scaled to the drawing; the 7½ / 15 / 30 switch scales it); hub radius r₀ = 5,
  full pack 15 (model units).
- Tape on the take-up reel follows the playhead. Pack radii come from conserved area:
  r² = r₀² + (R² − r₀²)·f, where f is the fraction of the project wound across.
- Angular velocity ω = v / r, integrated exactly for a spiral pack: dθ = 2π·dr / h, with tape thickness h set so the
  project fills one reel. A near-empty reel spins fastest. Both reels turn the same way. Rewinding reverses them.
- Driven by position, not time: seeks, loops and dropped frames keep the reels consistent. A jump of more than
  a second winds there quickly; holding a wind key moves the tape directly.
- Reduce Motion: the reels don't turn; the packs still show the position.

## Meters
The VU needles take the master peak levels the main window reads each frame (meters reset on read, so the deck
never reads them itself). Ballistics: a mass-spring settling in about 300 ms; 0 VU = −18 dBFS; a peak lamp within
1 dB of full scale.

## Performance
Drawn on the display link (`NSView.displayLink`) while the window is open. A frame redraws only when the tape moved,
the counter or the lamps changed (the meters redraw themselves). Nothing runs on the audio thread.

## Verified
Self-test (both themes) checks: Play lights and turns both reels forward, Pause holds them, F.FWD winds about 12×,
REWIND turns them back, Stop returns to the start point, RTZ, LOOP toggles the shared cycle, and the speed switch.
Real input: ⇧⌘T, Space, holding F.FWD for 1 s (counter 00:12.2) and REWIND for 0.5 s (back to 00:06.0).
Not judged: smoothness by eye over long runs.
