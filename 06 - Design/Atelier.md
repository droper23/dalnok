---
created: 2026-11-21
updated: 2026-11-22
status: implemented (light and dark); redrawn as the Codex 2026-11-22 (replaces the sketchbook of the same day)
related: "[[Theme System]]", "[[Prism]]"
---
# Atelier: the Codex

Owner brief (2026-11-22, second pass, with a mock-up and references): not sloppy notebook sketches but **detailed,
mathematically constructed drawings**, like Da Vinci's notebooks or the engraved plates of an old natural-philosophy book
(the reference: "Mathematics & Astronomy" plates of scientific instruments, parts lettered A, B, f). Plug-ins must have a
style of their own, not Graphite in white; use "Fig. 1" captions and architectural-drawing ideas so the theme stands
apart. Fonts are unchanged (Source Serif 4, IBM Plex): the serif carries titles, numerals and the italic annotations.

## Principles
- **Ruled and measured.** Every line is straight or drawn with the compass; nothing wobbles. Shade is engraved: fine
  parallel lines, never gradients or glow.
- **Plates and figures.** A plug-in is a plate (heavy and fine rule, lozenges in the corners); its display is a numbered
  figure in a neatline frame with a caption ("Fig. 2 · Indicator of Reduction").
- **Lettered.** Parts are called out with small italic letters on fine leaders (A, B, C); sections of the song are
  lettered A, B, C in gold; plates are numbered "01 ·", "02 ·" in gold italic before their name.
- **Construction shows.** Light dashed construction circles and guides are left in, as on a working drawing.
- **Two plates.** Light: sepia ink on parchment (mottled, with fibres and a little foxing), red ochre for what must be
  seen, ochre gold for numbers and letters. Dark: the "Mathematics" plate: cream engraving on dark umber with gold and
  terracotta.

## The kit (`app/macos/Dalnok/AtelierKit.swift`)
`rule`, `box` (with optional construction overshoot), `loop` (compass circle), `hatch` (engraved shade at any angle,
crossed or not), `scribble` (engraved level fill), `meter`, `knob` (graduated dial, globe shaded by an engraved crescent,
hatched value sector, lozenge needle), `hardware` (the plate), `ornament`, `screen` (neatline with a graduated border),
`checkbox` (a saltire when on), `cartouche`, `ornamentRule`, `arrowhead`, `note` (italic annotation), `callout`
(lettered leader), `construction` (dashed circle), `diapason` (Fig. 1: tuning fork and sine), the parchment
(`PaperGrainView`, one pattern layer). `SketchBorderLayer` gives layer-backed views a ruled frame.

## Plug-ins: figures from live data (`FaceplateDisplays.swift`, "Codex figures")
Each display kind keeps its live data and becomes a figure:
- **EQ, filters: Frequency Atlas.** Log-frequency and dB axes lettered in the serif, dotted graticule, the spectrum as a
  dotted measured profile, the response in red ochre with the area to 0 dB engraved in vertical lines; band rings are
  numbered and the moved bands annotated ("92 Hz +4.5 dB") on leaders. Handles still drag (the plot geometry is shared).
- **Dynamics, VU: Indicator.** A surveying-instrument dial: graduated arc, serif numerals, engraved red zone, a long
  lozenge needle from a pivot below the scale, over a construction circle.
- **Reverb: Acoustic Chamber.** A vaulted hall in one-point perspective (elliptical front and back arches, coffer ribs,
  transverse arches, arcades of columns, a jointed floor) with sound rays from the source (A) by the vault (B) and walls
  to the listener (C); the rays darken with the output level. Reverbs are recognised by name and parameters.
- **Delay: Chronograph of Echoes; other time effects: Envelope in Time.** Output engraved under its line, the input
  dotted, axes in dB, "A(t) = A₀ e^(−t/τ)".
- **Distortion: Transfer Curve** inside a construction circle, unity diagonal dashed.
- **Modulation, stereo: The Stereo Field.** A compass disc with L, R, M, the trace, and a correlation scale with an
  arrow pointer.
- **Analysis: Spectral Census** (hatched columns with red peak rules). **Instruments: Form of the Wave.**
- Controls on plates: graduated dials, ruled check boxes with a saltire, ruled keys; the plate number in gold italic
  before the name; IN and OUT lettered on the signal's course, with arrows between plates.

## The rest of the window
- Arrangement: ruled lanes and bar lines (heavier every four bars), beat ticks, clips with a pale wash and a ruled frame
  in the track's ink, waveforms engraved (envelope traced, vertical strokes), sections lettered "A  Verse" in gold,
  bar numbers in the serif. Playhead: a red-ochre line.
- Headers, mixer, launcher, piano roll, Composition Overview: ruled boxes, graduated scales lettered in the serif,
  engraved meters, dials with lozenge needles.
- Start page: the frontispiece figure (Fig. 1, the diapason: a tuning fork with its sine and f = 1/T).

## Accessibility
States stay shape plus colour (filled versus ruled chips, a saltire in a check box, engraving over bypassed plates).
Body text contrast stays above 7:1 on both plates. Figures are decorative or already exposed by their displays.
