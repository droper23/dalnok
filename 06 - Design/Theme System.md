---
created: 2026-11-21
status: implemented (Graphite, Warm Analog, Prism, Atelier)
related: "[[Prism]]", "[[Atelier]]", "[[Warm Analog]]", "[[Track Colors]]", "[[Theme Critique 2026-11-17]]"
---
# Theme system

Dalnok has four themes. They share every command, shortcut, accessibility label, editing behaviour and the
project file; only drawing differs. A theme never writes to the project.

| Theme | Identity | Versions | Core idea |
|---|---|---|---|
| Graphite | Modern digital workstation | Dark | Efficiency, clarity, minimalism |
| Warm Analog | Physical recording studio | Dark | Tactility, hardware, warmth |
| Prism | Spatial glass canvas | Dark, Light | Light, depth, material (Liquid-style glass) |
| Atelier | Sketchbook | Light, Dark | Pen, ink wash and hatching, drawn by hand |

## How a theme is put together (`app/macos/Dalnok/Theme.swift`)
A theme (`Theme.Style`) is four parts. Views ask for tokens and families, never "which theme is on".

1. **Palette** (per version: `Style.palette(Variant)`): surface tokens (window, panel, lanes, LCD), text tokens,
   state colours (mute, solo, monitor, record, clip) and *overlay* tokens: `ink` marks over a surface (grid lines,
   hairlines, highlights), `shade` darkens it, `well` is a recessed groove. `Theme.ink(a)` is white on dark versions
   and the text colour on light ones (alpha scaled ×1.6 so the same call reads alike), which is what lets one drawing
   path serve light and dark canvases.
2. **Look** (presentation families): `arrangement` (flat, glass, manuscript), `headers` (rows, channelStrips, glass,
   scoreLabels), `transport` (lcd, tapeDeck, glassCapsule, typeset), `mixer` (flat, console, glass, instrument),
   `controls` (flat, hardware, glass, drafted), `meters` (bars, ledLadder, lightPipe, graduated), `editors` (grid, tape,
   glass, engraved), `devices` (rack, pedalboard, cards, schematic), `trackColors` (rainbow, console, spectral, inks),
   `motion` (standard, lamp, glass, drafting). Warm Analog's older capability questions (`pedalboard`, `tapeDeck`…)
   are now derived from these families, so each has one source of truth.
3. **Typography** (roles, `Theme.ui/mono/title/display/note`): labels, tabular figures, titles (track and clip
   names, headings), the large clock and italic annotations. Faces are bundled (SIL OFL, `Resources/Fonts`,
   registered at launch by `Fonts.swift`) and fall back to the system faces if missing.
4. **Kits**: shared primitives per material, `PrismKit.swift` (light field, liquid pane, glass slab, light pipe,
   glass knob) and `AtelierKit.swift` (the hand: pen lines, sketched boxes and loops, ink wash, hatching, paper grain, sketched hardware). A view's
   family branch calls these; business logic is never duplicated.

A fifth theme is a new `Style` case, a palette per version, a choice of families (reusing existing ones or adding
one) and a typography. Nothing else needs to change.

## Light and dark
`Theme.Variant` (dark, light). Graphite and Warm Analog are dark studios only; Prism defaults to dark and Atelier to
light. Settings ▸ Appearance ▸ Light or dark and View ▸ Theme ▸ Match System / Light / Dark set it; Match System
follows macOS live (`AppleInterfaceThemeChangedNotification`). The window's `NSAppearance` follows the version, so
menus, sheets, text fields and scroll bars match. `DALNOK_THEME` and `DALNOK_VARIANT` pick both at launch (captures,
tests).

## Switching
View ▸ Theme lists every theme; ⌥⌘A is Next Theme (the command keeps its id `view.toggle_analog_mode`, so custom key
bindings carry over). Settings ▸ Appearance ▸ Theme does the same. Switching rebuilds the windows around the same
session (project, undo history, zoom and scroll stay); it is refused while recording.

## Evidence and review tools
- `Dalnok <project> --gallery <dir>` (with `DALNOK_THEME`, `DALNOK_VARIANT`) writes the eleven screens every theme must
  get right: start page, arrangement with states and sections, playback, the recording display, the mixer, the
  device chain, the plug-in browser, the piano roll, settings, the palette and a dense compact window.
- Self-test: every theme from View ▸ Theme (fonts, appearance, project and zoom kept), Light/Dark per theme, Next
  Theme, and the whole suite runs under each theme and version.

## Rules for new drawing code
- Never hard-code white or black overlays: use `Theme.ink` / `Theme.shade`, and the state tokens for states.
- States are always shape plus colour (a letter, a filled versus outlined form, hatching, crop marks).
- Static decoration is cached (Prism's light field is rendered once per window size); nothing ornamental animates
  during playback; everything honours Reduce Motion through `Motion`.
- Views don't clip their drawing to their bounds by default (macOS 14+): clip before drawing anything large.
