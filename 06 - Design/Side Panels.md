---
created: 2026-11-22
status: implemented (all four themes, light and dark)
related: "[[Atelier]]", "[[Theme System]]", "[[Atelier Audit 2026-11-22]]"
---
# Side panels: Library and Inspector

The owner asked for a left sidebar and a right inspector "in the spirit of Logic's Library and Inspector and Ableton's
Browser", taking the ideas of the Atelier mock-up rather than its pixels.

## Layout
```
┌ control bar ──────────── [Library][Inspector] ◀ ■ ▶ ● ↻  1.1.1.000 ──────────────┐
│ Library │ track headers │ launcher │ arrangement                    │ Inspector │
│         ├──────────────── mixer ──────────────────────────────────── ┤           │
│         ├──────────────── device chain ───────────────────────────── ┤           │
└─────────┴──────────────────────────────────────────────────────────────┴───────────┘
```
- Both panels run the full height under the control bar; the arrangement, mixer, device chain and Composition
  Overview sit between them (`MainWindow.swift`, Auto Layout).
- **View ▸ Library (Y)** and **View ▸ Inspector (I)**, also in the command palette and as two buttons left of the
  transport. Bare keys, like X for the mixer; they never fire while a text field is being edited (self-test). Both
  are rebindable in Settings ▸ Shortcuts (`view.library`, `view.inspector`); Logic uses the same keys.
- Open state and width are remembered (`showLibrary`, `showInspector`, `libraryWidth`, `inspectorWidth`). Drag the
  inner edge to resize (Library 200–360 pt, Inspector 210–360 pt). Toggles slide through `Motion.gentle` and are
  instant under Reduce Motion.
- The window's minimum width is 720 pt plus each open panel, and opening a panel in a narrow window widens it
  (within the screen), so the arrangement keeps its headers and a strip of timeline.

## Library (`Library.swift`)
- **Places:** Plug-ins (all), Favourites, Recently Used, Projects (recent documents; double-click opens).
- **Collections:** the owner's plug-in collections (shared with Audio ▸ Plug-ins); + makes one; right-click to rename
  or delete; right-click a plug-in to file it or make it a favourite.
- **Browser:** tabs for Effects, Instruments and MIDI (the taxonomy's groups), a search field (the browser's fuzzy
  search), and the categories of `PluginTaxonomy` with disclosure triangles and counts. A search opens the matching
  categories.
- Drag a plug-in onto a track header, the device chain or the Inspector; double-click or Return inserts it on the
  selected track (one undo step). The list is metadata only: no plug-in code is loaded.
- Not taken from the mock-up: "Sounds" (Dalnok has no sample library yet) and the MIDI/Editor tabs (replaced by the
  three plug-in groups).

## Inspector (`Inspector.swift`)
- **Header:** the track's colour, number and name.
- **Track:** Input (audio tracks: the recording device's inputs), Output (master or a bus), Monitor (Input
  Monitoring off or on, audio tracks).
- **Channel:** Volume and Pan as large dials with read-outs; M, S, R and Ø. Ø is phase invert, added to the engine for
  this (C API 46, project format 14): the whole source flips before the inserts, so sends carry it too.
- **Inserts:** numbered like plates ("01 · Dalnok Channel EQ"); click opens the plug-in, the B lamp bypasses it.
- **Sends:** lettered A, B, …, each a level rail with its dB; right-click for pre/post and removal; + Send.
- **Level:** the track's live meter at the foot.
- Every control uses the mixer's engine calls: a dial or rail drag is one undo step, a click one step. Nothing is
  cached: the panel re-reads the session when the selection, the model or a parameter changes, and shows automated
  volume and pan at the playhead during playback.

## Themes
Each theme keeps its idiom through `SidePanelView` and `PanelHead`: Graphite a flat raised panel with small-caps heads,
Warm Analog the faceplate, Prism a liquid pane, Atelier the parchment or umber with a double rule at the inner edge.
Atelier heads are serif titles over a heavy and a fine rule (Light) or the Mathematics plate's gold band (Dark);
numbers and letters are gold italic; pop-ups are ruled boxes; the Library's foot carries Fig. 1 (the diapason) when
the window is tall enough.

## Evidence
`SelfTest+Inspector.swift` (toggles, widths, every edit as one undo step, live meter and automation, search, tabs,
places, collections, library drag and double-click, typing never toggles a panel); the accessibility audit runs with
both panels open. See CURRENT_STATE for the matrix and the gallery review.
