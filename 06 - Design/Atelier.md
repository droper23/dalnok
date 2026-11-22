---
created: 2026-11-21
status: implemented (light and dark); composition overview not built yet
related: "[[Theme System]]", "[[Prism]]"
---
# Atelier: the composer's workspace

A precision drafting table crossed with a beautifully set manuscript. Ink on ivory (or chalk on a charcoal board in
the dark version); hierarchy comes from line weight and type, not from fills; one vermilion for what must be seen.
It is meant for beat-making, mixing and recording as much as for composing, and it never pretends to be notation.

## Palette
- Light: ivory paper (window EFE9DC, lanes FAF7F0 / F6F2E8), ink 1D1B18, vermilion C4422A (playhead, record,
  selected margin), ochre cycle, a muted teal for mute.
- Dark: charcoal board (1A1916–24231F), chalk EDE6D6, a brighter vermilion E8684A.
- Track colours are drawing inks: deep, slightly muted pigments at an even lightness (lighter on the dark board),
  warm and cool alternating.

## Typography (a defining part of the theme)
- Labels: IBM Plex Sans Condensed (technical, compact, legible at small sizes).
- Figures: IBM Plex Mono (every value, scale and counter is tabular).
- Titles: Source Serif 4 (track names, clip names, plug-in names, headings, the master).
- Clock: Source Serif 4 display, lining tabular figures, large.
- Annotations: Source Serif 4 italic (clip tags, inputs, "§ Verse" headings, empty insert slots).

## Components
- **Arrangement**: lanes are separated by hairline rules. Bar lines are fine rules, **heavier every four bars**
  (phrases); beats are short ticks at the top and bottom of each lane, as on a drafting scale, and become dotted lines
  only when zoomed in far enough to need them. Clips are ink plates: a pale wash of the track's ink, a fine outline,
  a margin bar at the start, the name typeset in the serif above a fine rule, tags in italic. Waveforms are solid ink.
  MIDI clips show note heads with duration lines.
- **Ruler**: a drafting scale closed by a double rule; bar numbers in Plex Mono.
- **Playhead**: a vermilion hairline with a sharp caret; it never glows.
- **Track headers**: typeset score labels (serif names, old-style numbers in a ruled margin, italic inputs);
  selection is a vermilion margin rule on an ochre wash.
- **Controls**: chips are letters in drawn boxes; the record chip is round (a record mark), the others square; an
  active chip is solid (form changes, not only colour). Knobs are drawn dials: a printed arc of ticks, an ink arc for
  the value, an outlined face and a needle. Toggles on plug-ins are checkboxes.
- **Meters**: graduated columns: an ink fill, a vermilion zone above −3 dB and a peak line.
- **Transport**: no well: a ruled frame with the position typeset large; tempo in the display serif.
- **Mixer**: a precision instrument. Hairline fader slots with graduated scales typeset on both sides, and a
  slide-rule cursor cap: a hollow frame in the channel's ink with a hairline index exactly at the level. Channels are
  columns of the drawing with the channel's ink as a heavy rule at the top; the master stands apart behind a double
  rule.
- **Device chain**: plug-ins are sheets in a schematic: an ink border, a title rule, the track's ink in the margin,
  and a signal line with an arrow running through them. Screens become plots on graph paper (one ink-on-paper pass
  for every display, so each keeps its own drawing code); bypassed sheets are hatched.
- **Piano roll**: engraved. Each note is a round head where it starts and a duration line **whose weight is its
  velocity**, with a fine end tick where it stops (the resize edge). Bars are rules, heavier every four; beats fine;
  sixteenths dotted. Outside the clip the sheet is hatched. Velocities are stems with open heads (filled when
  selected). The keyboard margin marks the pitch classes the clip uses (from its notes).

## Signature details (each does a job)
1. **Crop-mark selection.** Selected clips carry printer's crop marks, which glide to the next selected clip like a
   drafting square (the glide follows Reduce Motion).
2. **Phrase rules and margin ticks.** Four-bar phrases read as structure at a glance; beat ticks keep timing precise
   without filling the canvas with lines.
3. **Section headings.** Markers become "§ Verse" headings with a fine rule through every lane.
4. **Velocity as line weight.** In the piano roll, loud notes are drawn heavier, the way a draughtsman weights lines.
5. **Schematic devices.** Signal flow and every display read as a technical drawing.

## Not built yet
- **Composition overview** (a zoomed-out roadmap of sections, groups and automation from real project data). Planned;
  not implemented in this pass.

## Accessibility
Text is ink on paper (contrast well above 7:1 for body text). States are always a shape: solid versus outlined chips,
hatching for muted and bypassed, crop marks for selection. Menus and sheets use the light system appearance in the
light version and the dark one on the board.

## Performance
Pure vector drawing with system-cached glyphs; no images except the bundled fonts. Screens use one blend pass per
redraw. Nothing animates except the shared Motion transitions.
