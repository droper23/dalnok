---
created: 2026-11-22
status: mostly done 2026-11-22 (see "Done and open" at the end); owner answers recorded below
related: "[[Atelier]]", "[[Theme System]]"
---
# Atelier audit and update plan (2026-11-22)

Sources: five reviewers (Codex fidelity light, Codex fidelity dark, cropping and spacing, producer workflow,
legibility), run on the Codex gallery stills (taken 20 minutes before PR #10 merged), and the owner's direction.
Claims were spot-checked against the stills; one was wrong and is dropped (M/S/R/I chips *do* carry letters).
Severity: **H** must fix, **M** should, **L** polish.

## Owner direction (2026-11-22)
- More like the **Mathematics** plate: many 3D engraved drawings with lettered parts, leaders and captions.
- **Controls become drawings too**: transport, faders, knobs and meters drawn as engraved 3D instruments, not only
  figures in spare space.
- **Atelier Dark gets gold title bands**: panel and section heads are flat ochre-gold bands with dark serif titles and
  an italic kicker, as on the plate. Everything else stays cream on umber.
- **Mathematics plate only**: no hues or motifs from the other plates.
- Unchanged rules: engraved and measured, never wobbly; no tape labels; no per-plug-in pedals.
- Second round of answers: **two densities**: drawn controls keep today's footprint by default, and a View option
  "Illustrated" allows larger, richer controls. **Light keeps ruled heads** (no band; bands are Dark's signature).
  **Header knobs get read-outs** in every theme; row height is unchanged. **Order:** panels first, then the audit.

## Guardrails (they apply to every item below)
1. Data first. Hatching, contour and texture never run under text, values, waveforms, notes or meter scales. A label
   sits on a clean plate patch.
2. Anything read rather than admired is upright, ≥ 10 pt, ≥ 7:1. Italic gold is for numerals and ornament only.
3. A drawn control keeps its hit area, value read-out, accessibility label and keyboard focus. Drawing replaces the
   skin, never the behaviour.
4. One saturated hue means *record*. The playhead, selection and accent each get their own treatment.
5. Figures are cached (drawn once per size), and nothing ornamental animates during playback.

## A. Theme breaks: the system look shows through (H)
| # | Where | Now | Change |
|---|---|---|---|
| A1 | Plug-in browser (both) | Grey sidebar, white table, macOS segmented control, pop-ups, buttons | Parchment/umber field, ruled table, serif section heads (with a gold band in Dark), ruled cartouche search and filter controls |
| A2 | Settings (both) | Stock check box, pop-ups, button; rounded grey selection pill; flat background | Kit check box (saltire), ruled pop-ups, gold rule marks the active section, window parchment |
| A3 | Command palette | Grey selection, system text selection, plain scroll bar | Plate frame with corner lozenges, ruled selection band, serif names, shortcut in mono |
| A4 | Mixer | "Master" output pop-ups are system controls; "+ Bus" barely visible | Ruled cartouche pop-ups with an engraved chevron; "+ Bus" as a full-contrast ruled key |
| A5 | Empty device chain | Plain box and a white "Add Plug-in…" button | Numbered empty plate ("Fig. — Signal path, no plates yet") with a ruled key |
| A6 | Piano roll (Dark) | Neon cyan notes and velocity stems | Notes in ink with a hatched body (cream on umber, sepia on parchment), velocity as engraved stems |
| A7 | Composition Overview | Teal-blue section frame | Double rule in red ochre (light) / gold (dark), lettered |
| A8 | Start page | Web-form tiles, white tempo field, system stepper, white button | A title page: track tiles as engraved figures (microphone and keyboard in section, parts lettered), ruled fields |
| A9 | Toolbar icons | Monoline modern glyphs | Engraved glyphs on the same 1 px rule weight as the kit |

## B. Controls redrawn as engraved instruments (owner: "controls become drawings")
| # | Control | Drawing |
|---|---|---|
| B1 | Transport | A counter mechanism: the clock as numbered drum wheels in a ruled housing; play, stop, record and cycle as engraved keys lettered A–D, with a caption |
| B2 | Faders | A slide rail in perspective: an engraved groove, a measured scale with serif numerals, the cap as a turned block with a hatched side face |
| B3 | Knobs | Turned dials in slight perspective: knurled rim, graduated ring, lozenge needle; value read-out below in upright serif figures |
| B4 | Meters | Engraved column with a measured scale (mixer); the top-right master as an arc indicator with a needle (like the Codex VU) |
| B5 | Track header chips (R I M S) | Square ruled cells; *on* = filled engraving (cross-hatched) plus colour; record keeps a ring |
| B6 | Mixer strips | Each strip a lettered plate column; the empty area right of the strips holds "Fig. · Signal flow" (strips → buses → master in perspective) |
| B7 | Plug-in plates | Double-rule border; features lettered on leaders in every figure; read-outs in serif figures |
| B8 | Library / Inspector (new) | Section heads as gold bands (Dark) / ruled heads (Light); Inspector dials as B3; foot figure of the selected insert, live |

## C. Cropping, truncation and spacing (H/M)
| # | Where | Issue | Fix |
|---|---|---|---|
| C1 | Device chain | The last plate is cut by the window edge with no cue | Edge fade and scroll cue; snap scrolling to plate boundaries |
| C2 | Plug-in parameter grid | "Low Freq Decay Ti…", "Randomize Reflec…" | Two-line labels with a fixed label box height; no ellipsis |
| C3 | Plug-in browser | "Not scanne…" status; "Modulation" cut at the sidebar foot; footer has no right gutter | Status column takes the remaining width; sidebar scrolls with a fade; 16 pt gutters |
| C4 | Piano roll | Lowest key label (C3) cut by the velocity divider; top row cut under the ruler | Pad the key column and the grid |
| C5 | Arrangement and mixer | The track row at the pane foot is cut mid-control with no cue | Fade at the pane edge |
| C6 | Device pane | The horizontal scroll bar sits on the plates' bottom border | Gutter under the plates |
| C7 | Mixer | Insert rows aren't aligned across strips; the selected-strip wash stops short of the divider; Master's rule is 1 px off | One insert-row component; wash to the divider; align the rules |
| C8 | Settings | Sidebar icons and labels on different x positions; two controls in a different font | Fixed icon column; app label style |
| C9 | Palette | "Export Mix…" truncated in a wide row | Fill the row |
| C10 | Composition Overview | "bars 17–17"; double outline; the right column touches the window edge | Check the end bar; single border; gutter |
| C11 | Arrangement | Adjacent clips have a double seam; the fade handle crosses the next clip's label; the note lane strikes through "Keys 32 notes" | Single seam; keep the label band clear |
| C12 | Title block, "B Verse" marker, "+ Bus" | Off the centreline or touching the edge | Align and add a margin |

## D. Legibility and state (H/M)
- D1 Captions, gold italic plate numbers, mixer scale numerals and "+ Bus" are at or below about 4:1 → bring to ≥ 7:1, ≥ 10 pt.
- D2 Playhead red over red clips → a dark umber (light) / cream (dark) line with a ruled cap; red stays for record.
- D3 Red means record, playhead and accent at once → per guardrail 4.
- D4 "muted" label sits on cross-hatch → clear label band.
- D5 Track colours: the two blues (Hats and Lead) and two warms (Kick and Vocal) are too close → separate them by lightness
  inside the inks palette.
- D6 Track header knobs show no value → a small upright read-out under each.

## E. Library and Inspector (the panels being built), from the reviews
- Library: Places, Favourites/Recent with counts, Collections (+), search that filters the category tree, categories
  from `PluginTaxonomy`, drag to a track or chain, double-click inserts. The figure sits only in spare space at the foot.
- Inspector: number, colour and name; Input/Output/Monitor; Volume and Pan dials **with read-outs**; M S R Ø
  labelled (Ø = phase invert, engine API 46); Inserts with a bypass lamp, numbered "01 ·"; sends lettered A, B with a
  level and dB; at the foot, a live meter or the selected insert's figure, never a static decoration.

## Order of work
1. Library and Inspector (the handoff's main task), built on the new kit pieces B3, B4 and B8.
2. A and C (theme breaks and cropping), all themes where shared (C applies to every theme).
3. B1–B7, one control family at a time, each with gallery stills in light and dark.
4. D, then the full self-test matrix, the a11y audit, perf, and gallery review.

## Done and open (2026-11-22, late)
- **Done:** A1–A8 (A6 by softer inks on the dark plate; A8 with an engraved microphone and keyboard on the start cards),
  B1 (counter housing), B2 (fader blocks and screwed rails), B3 (turned dials), B5 partly (chips unchanged in shape),
  B6 (signal figure in the mixer's spare room), B7 partly (plate numbers and figures as before), B8, C1, C2, C3, C7
  partly (+ Bus), C8, C9, C10, C11 (notes under the title), D1, D2 (paper casing; red kept, as in the owner's mock-up),
  D4 (by D1), D6 (read-outs in every theme). Two densities: View ▸ Illustrated Controls.
- **Open:** A9 (toolbar glyphs are still SF Symbols), B4 (the control bar's master meter as a needle indicator), C4 is
  scroll clipping (no change), C5 (a fade at the arrangement's lower edge), C6 (scroll bar gutter under the plates),
  C7 (insert rows aligned across strips, selected wash to the divider), C12, D3 (record still shares red with the
  playhead and accent), D5 (track inks separated by lightness).

## Owner review, third round (2026-11-22, night)
Owner's notes on the PR #11 build: the record chip's R off centre; plug-in power keys off-theme; keep the mixer's
fader boxes but make every 3D element share their direction and depth; an illustration at the Inspector's foot; Library
names missing until clicked and too close to their icons; text still cut off (Library search); a weak clock, cramped by
the second clock; fonts not unified; and plug-ins redesigned so they don't read as a Graphite reskin, with more of the
Mathematics plate's drawing everywhere.
Answers to the plug-in questions: **mix by plug-in type** (figure as the main drawing, parameters in the form that
suits the family); drawing **a mix: easy to navigate, still drawn**; third-party plug-ins get a **generic legend plate**;
iconography **everywhere with room** (data areas stay clean).

Done in `feat/atelier-polish`:
- One oblique for every solid (`Atelier.depth`, `recede`, `obliqueSide`): dials, fader blocks, plug-in cursors, glyph blocks.
- Plug-in plates: lettered legend rows with slide-rule scales (`FaceplateControl.legendRows`), Off | On cells for
  switches, knife-switch power key (`Atelier.knifeSwitch`). The family figure stays the plate's centre (EQ bands drag).
- A9 done: engraved glyphs (`AtelierGlyphs.swift`) for the control bar, tools and Library places.
- D3 done: red is record only (playhead ink, accent gold / burnt ochre). D5 done: inks separated by lightness per hue family.
- Type: Source Serif 4 throughout (`Typography.atelier`), `Atelier.unifyFonts` for system controls.
- Clock: split housing, two drums side by side when the second clock is on. Inspector Fig. 3 (signal path, live), sized
  to the spare room only.
- Still open: B4 (needle master meter), C5, C6, C7 (insert rows aligned), C12.
