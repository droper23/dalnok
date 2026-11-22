---
created: 2026-11-21
updated: 2026-11-22
status: implemented (light and dark); redrawn as a sketchbook 2026-11-22
related: "[[Theme System]]", "[[Prism]]"
---
# Atelier: the sketchbook

Owner brief (2026-11-22): redo Atelier so it looks **hand-drawn everywhere, especially the plug-ins**, with a visual
style of its own. Chosen direction: *sketchbook ink*: everything drawn in pen on drawing paper (or white gel pen in a
black sketchbook), shaded with cross-hatching, filled with ink washes. **The fonts stay as they were** (owner's
choice): IBM Plex Sans Condensed, IBM Plex Mono and Source Serif 4. Before the redo, Atelier was a precise drafting
table (ruled lines, crop marks, graph paper); the structure is kept, the hand is new.

## The hand (`app/macos/Dalnok/AtelierKit.swift`)
Every mark goes through a small set of primitives, so the whole theme shares one hand:
- **Pen lines** (`rule`, `pen`, `handPoints`): a slow drift plus a faint tremor across the line, growing with length;
  heavier pens are drawn as a filled outline whose width follows the pressure (thinner where the pen lands and lifts).
- **Boxes** (`box`): four strokes whose corners land a little off and overshoot, as a quick sketch does.
- **Circles** (`loop`): one stroke that runs a little past where it started and drifts outward as it closes.
- **Ink wash** (`wash`): dilute ink inside an uneven edge, darker where it pooled.
- **Hatching** (`hatch`, `cross:`): uneven 45° strokes; cross-hatching for shade and for "not in use".
- **Paper** (`grain`, `PaperGrainView`): tooth and fibres from a tile made once per version, laid over the main window
  as one pattern layer (no per-redraw cost).
- **Deterministic**: every wobble comes from a seed (the geometry, or a stable id: a clip's id, a track's id, a bar
  number), so nothing shimmers between redraws and a clip keeps its own hand while it scrolls.
- Layer-backed controls use the same hand through paths (`boxPath`, `loopPath`, `SketchBorderLayer`).

## Palette
- Light: cream drawing paper (window F0E8D7, lanes FBF7EE / F6F0E3), sepia-black pen 231D16, a red pen C73E26
  (playhead, record, selected), blue ink 2B5C8A for mute, ochre for solo and the cycle.
- Dark: a black sketchbook (1A1916–24231F) with white gel pen EDE6D6 and a brighter red E8684A.
- Track colours are inks: they wash clips, outline them, and draw waveforms and notes.

## Components
- **Arrangement**: lanes separated by hand-ruled lines; bar lines ruled by hand (heavier every four bars), beats as
  quick pen ticks at the top and bottom of each lane. Clips are **ink washes** in the track's ink inside a pen box that
  overshoots its corners, with a broad pen stroke down the start; the name is lettered above a short underline.
  **Waveforms are drawn with a pen**: the envelope traced above and below, shaded with vertical strokes. Muted clips are
  cross-hatched. Selection goes over the box again in black ink with sketched corner ticks.
- **Playhead**: a red-pen line with a quick, slightly lopsided arrowhead.
- **Track headers**: letters in boxes drawn by hand (record is a looped circle, a record mark); a chip that is on is
  filled in with its colour inside a rough edge. Knobs are looped circles with hatched value sweeps.
- **Mixer**: each channel's ink as a broad pen stroke at the top; faders are a pen stroke in the channel's ink with a
  sketched, hatched cap; scales are ticked by hand; meters are shaded in with hatching, cross-hatched red above
  −3 dB; the selected channel is underlined in red pen; inserts are sketched boxes.
- **Plug-ins (the centrepiece)**: every unit is a **pen sketch of a piece of hardware**: the front panel as a box with its
  top and right side receding in oblique projection, the side hatched in shade, rack ears with screws (a looped circle
  and a slot each), and the track's ink as a broad stroke along the foot. Screens sit in recessed windows with hatched
  bezels; toggles are sketched check boxes with a tick that runs out of the box; keys are sketched boxes, hatched when
  pressed; knobs and meters as above. Bypassed units are cross-hatched through.
- **Piano roll**: note heads are ink blots; each duration is one pen stroke whose pressure (weight) is the velocity;
  velocity stems end in looped heads; grid lines are ruled by hand.
- **Clip launcher**: slots are sketched boxes; filled slots are washed cards (darker and gone over again when playing).
- **Composition Overview**: coverage as hatched bars in sketched boxes; the chosen section washed in ochre and
  underlined in red pen.
- **Transport**: the clock in a sketched frame; the start page's cards and panels are sketched boxes on the paper.

## Accessibility
States stay shape plus colour: filled versus outlined chips, a looped record mark, cross-hatching for muted and
bypassed, a tick in a check box, a second, heavier outline for selection. Text contrast is unchanged (body text well
above 7:1 on both papers). Keyboard focus keeps the system focus colour (sketched in the overview).

## Performance
Pure vector drawing. Pen lines cost a few more segments than straight ones (at most 80 per line); the paper grain is a
single pattern layer. Everything is deterministic, so a redraw draws the same picture.
