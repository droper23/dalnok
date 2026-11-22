---
created: 2026-11-21
status: implemented (dark and light)
related: "[[Theme System]]", "[[Atelier]]"
---
# Prism: the spatial glass studio

Making music inside an illuminated canvas. The window is a field of soft coloured light, and everything you
touch is a pane of glass floating over it. Inspired by Apple's Liquid Glass (materials that bend the light behind
them and catch it at their rims), but drawn by Dalnok itself, so it works the same on every platform and shows in
captures. Light, depth and material carry the hierarchy, not boxes and borders.

## Owner direction (2026-11-21)
"Way more like it's entirely made of glass", leaning on Liquid Glass, with a light and a dark version.

## Materials
- **Light field** (`Prism.lightField`): large soft pools of colour over a deep gradient. Night: electric blue,
  violet, magenta and teal over ink blue. Day: sky, lilac, peach and mint over pale grey-blue. One image per window
  size and version, shared by every view so panes join seamlessly; a frosted copy is blurred once (Core Image).
- **Liquid pane** (`Prism.liquidPane`): the frosted field behind the pane, magnified 6% about its centre (light bends
  at the rim), a body tint for legibility (smoky at night, milky by day), a sheen across the top third, light gathered
  along the inner bottom edge, a specular rim brightest at the top-left and fading round the pane, a hairline outer
  edge and a soft shadow beneath (the pane floats).
- **Glass slab** (`Prism.slab`): smaller tinted glass for clips, strips, cards, notes and capsule buttons: lighter at
  the top, a specular top edge and a rim of its own colour. `lift` raises it (more opaque, brighter rim, coloured
  shadow).

## Layout treatment
No bars: the control bar is three floating capsules (title, transport, tools) with the light field between them.
The track list, ruler, arrangement canvas, mixer and device chain are each one pane, with 4–8 pt gutters where the
light shows. Panes are per region, not per track, so a 200-track session draws the same number of panes.

## Components
- **Arrangement**: clips are tinted glass with a denser frosted band carrying the name; waveforms are light
  suspended in the glass. Grid lines are faint; the selected track's lane gets a beam of its colour from the left.
- **Playhead**: an optical guide, a fine bright core in a soft column of light. Its head is a small triangular prism
  that splits the light into a spectrum fan over the ruler, marking the position without covering bar numbers.
  It brightens while the transport runs and turns red while recording.
- **Track headers**: rows on the column's pane, each with a breath of its colour; the colour edge is a light pipe
  that glows (it goes out when the track is muted). The selected row is a raised pane.
- **Controls**: chips are glass capsules; a lit chip is a coloured gel with light behind it (letter plus fill).
  Knobs are clear glass beads in a ring of light that always shows the value. Faders are a thin track of light lit
  in the channel colour, with a glass bead cap.
- **Meters**: light pipes, glass tubes filling with light from cool to warm to red near 0 dBFS, with a bright peak
  bead.
- **Transport**: a glass-encased clock with light-weight Geist Mono figures; recording turns them red and the well
  glows red.
- **Mixer**: floating modules of glass with a light bar in the channel colour; the selected module rises.
- **Device chain**: plug-ins are floating cards; a spectral beam runs through them as the signal path. Bypassed
  cards turn to clear frosted glass. Screens are dark glass wells.
- **Piano roll**: notes are glass capsules whose body thickens with velocity; velocities are pillars of light with
  bright beads; pitch classes used by the clip are lit dots on the keyboard.

## Signature details (each does a job)
1. **Elevation is state.** Selected clips, strips, notes and the selected header rise (opacity, rim, shadow);
   hover lifts a little; muted clips frost over (grain, desaturation, and the word "muted").
2. **The prism playhead.** Position is readable at a glance even over dense clips, and the spectrum fan never hides
   a bar number.
3. **Floating chrome over one light field.** Hierarchy by material: content sits on the large canvas pane, controls
   on small capsules, and gutters of light separate regions without lines.
4. **Light pipes.** Track colour edges and meters are the same material, so "lit" always means "signal" or "this
   track".
5. **Spectral signal path.** The device chain reads left to right as light passing through the cards.

## Typography
Sora (labels, set at 93% so layouts keep their widths, tabular figures on), Geist Mono (figures, values, clock;
Light for the clock).

## Accessibility
Text sits on tinted glass (smoky or milky) rather than raw colour, so contrast doesn't depend on the light field.
States always have a letter or shape. The window's appearance follows the version (Dark Aqua / Aqua). Reduce Motion
removes all transitions; nothing in Prism animates on its own.

## Performance
The light field is static and cached per window size and version; the frosted copy is blurred once per size. Panes
draw a region of that image, so there is no live blur and no per-frame compositing; nothing animates during
playback. Shadows are drawn only for raised items. To measure: `Dalnok <project> --perf 20` (release) with
`DALNOK_THEME=prism`, compared with Graphite.
