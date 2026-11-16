---
status: implemented (groups pending Phase 4)
---
# Track colors

## How other DAWs handle it
- **Logic Pro:** tracks get colors on creation, regions inherit the track color unless recolored, and a
  large swatch palette is available. Track stacks don't recolor their children by default.
- **Ableton Live:** "Auto-Assign Track Colors" picks a color per new track from a fixed palette. Clips
  take the track color. Group tracks have their own color.
- **Studio One and Bitwig:** folder or group colors can propagate to their children.
- **The shared lesson:** a track's color is part of its **identity**. People find "the vocals" by
  color, so colors must not jump around when you reorder tracks.

## Dalnok rules
1. **New tracks follow a rainbow gradient that starts at green.** The color for track *n* is step *n*
   of a 12-step hue cycle, 30° apart in **OKLCH**: green → teal → cyan → azure → blue → indigo →
   violet → magenta → rose → red → orange → yellow → back to green. Neighboring tracks read as a
   gradient, and a typical session reads as a spectrum. (22.5° steps were tried first and rejected:
   with 3–5 tracks everything looked green.)
2. **Perceptually uniform.** Every step shares the same OKLCH lightness and chroma (gamut-clamped), so
   no hue looks louder than another. In practice that means no neon yellow next to a murky blue.
3. **Color-blind separation.** Odd steps are slightly lighter (ΔL ≈ 0.05), so adjacent tracks differ in
   lightness as well as hue.
4. **Stable identity.** A track keeps its color when moved. **Track ▸ Recolor Tracks as Gradient**
   re-applies the gradient in the current order (one undo step) whenever you want a clean spectrum again.
5. **Custom colors stick.** Picking a swatch pins the track's color. "Automatic" returns it to the gradient.
6. **Sections and groups win.** Tracks inside a colored group or section take **shades of the group's
   hue** (lightness ramp), so the family reads as one unit. Leaving the group restores the track's own
   color. The model supports this now; group tracks arrive in Phase 4.
7. **Everything derives from one color:**
   - header strip: full color
   - clip body: color at about 18% over the lane
   - clip title strip: color at about 45%
   - waveform: lighter tint
   - border: darker shade
   - text: black or white, chosen by contrast
8. **State colors are reserved and use form as well:** mute desaturates and hatches, solo is a yellow
   chip, the playhead is a white line with a cap, and selection is a white outline. They never rely on
   hue alone.

## Data model
`TrackState.color` = gradient step index. `TrackState.customColor` = 0xRRGGBB, or −1 for automatic.
Project JSON: `"color": n` and `"customColor": "#rrggbb"`. Imports assign gradient steps in source order.
