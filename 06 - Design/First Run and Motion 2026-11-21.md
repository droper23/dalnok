---
updated: 2026-11-21
---
# First run and motion pass (2026-11-21)

Owner brief: make Dalnok appealing to new users, with simple navigation and full power underneath, and add more
animation, studying other DAWs and professional creative apps. See also [[UI Conventions]] and [[Overhaul Audit 2026-11-17]].

## What the best apps do

| App | First run | Navigation | Motion worth learning from |
|---|---|---|---|
| Logic Pro | Project chooser: templates by goal (Songwriter, Beat, Electronic), recents, "Learn" tour | Control bar buttons for Library, Inspector, Mixer, Editors, with lit state | Panels slide; regions settle when dropped; the playhead follows by page |
| Ableton Live | Opens a template set; Help View lessons | Info View: hovering anything describes it in a fixed box | Few, fast transitions; clip launch blinks on the beat |
| Bitwig Studio | Dashboard: Projects, recents, templates, demo songs | Panel buttons at the bottom edge, lit while open | Smooth, continuous zoom and scroll; new lanes are marked |
| Studio One | Start page: new song or project, recents, templates | Buttons for Mix, Browse, Edit | Smooth page scrolling while playing |
| FL Studio | Opens a template | Hint bar: what's under the pointer | Lively, bouncy dragging (Dalnok already has this; see `ClipMotion.swift`) |
| Final Cut Pro, Figma | Final Cut: library and event browser. Figma: recents grid. | Tool buttons with lit state | Brief notices name the action ("Undo …"). Camera moves glide; content rises in a stagger. |

What they share:
1. **Start from intent, not from an empty canvas.** Templates are named for what people come to make.
2. **Every view is one visible click away.** Shortcuts and menus are the fast path, not the only one.
3. **The app explains itself in place,** without making the user wait for a tooltip.
4. **Invisible actions get confirmed** (undo, save).
5. **The camera moves continuously** (zoom, fit, page turns), so the eye keeps its place.
6. **Motion is short and purposeful, and Reduce Motion turns it off.** It is never decoration that delays work.

## What this pass adds

| Area | Change | Learned from |
|---|---|---|
| Start page | First pass: six goal-named templates and recent projects. **Owner, same day: "they don't need six options, they just need to understand how to navigate a blank project."** Now: New Audio Track and New Instrument Track as cards; six essential keys (Space, R, ⌘K, X, ⌘Z, hover hints); links to open, import or bring in a project. Sections rise into place, and the emblem breathes. | Logic, Bitwig, Studio One |
| Control bar | Count-In (beside the metronome; owner request), Clip Launcher, Automation, Mixer and Device Panel buttons, lit while their view is open (the accent pill eases in and out). | Logic, Bitwig |
| Hint line | The line under the project name describes the control under the pointer: every tooltip, plus zone-aware text for clips (body, start, end, fades) and the ruler halves. Settings ▸ Appearance ▸ Hints. | Ableton Info View, FL hint bar |
| Toasts | "Undo Move Clip ⌘Z", "Redo …", "Saved", template confirmations. Spring rise in; a repeat nudges instead of re-entering. Announced to VoiceOver. | Final Cut, Figma |
| Camera | Keyboard and menu zoom, Zoom to Fit, Zoom to Selection and Go to Start glide (0.22–0.3 s). Zoom eases in log space around the one fixed point, so the anchor stays still; repeated keys build on the target. Page turns while playing glide in 0.2 s. A gesture takes over at once. | Bitwig, Studio One |
| Lanes | New tracks' lanes glow in their colour for 0.8 s (template, add, duplicate, undo or redo). Muting a track or clip cross-fades in 0.22 s. | Bitwig |
| Panels | The clip launcher slides open like the mixer and device panel. The command palette also grows from 97 %. | Logic, Spotlight |
| Recording | The count-in punches big beat numbers over the arrangement, readable from across the room. | Logic, GarageBand |
| Themes | Switching theme cross-fades from a picture of the old window. | macOS Light/Dark |

The engine is unchanged; everything is in the app. All motion goes through `Motion` (`Motion.drive` adds a display-linked
0→1 driver for drawn content) and is instant with Reduce Motion, in snapshots and in tests.

## Evidence
- Self-test passes: 614 checks at 48 kHz in Graphite and 599 at 44.1 kHz in Warm Analog (was 581 and 566).
  The new checks are in `SelfTest+FirstRun.swift`:
  - templates: tracks, one undo step, selection, toast, lane glow, return to the start page;
  - every view button: toggles and lights;
  - hints: shown for a button and a clip, and nothing when hints are off;
  - zoom: two zoom-ins land at a quarter of the frames per point, and the anchor drifts less than 0.5 pt while gliding;
  - Zoom to Fit returns to the whole project, and a gesture stops a glide;
  - count-in overlay.
- UI walk frames show the undo toast and the lit Mixer button; snapshots show the start page in both themes.

## Next candidates (not done)
- Inspector-style track panel (Logic's Inspector) and a browser sidebar shown from the control bar.
- Guided first-recording walkthrough: arm, count-in and record, with coach marks on the three controls involved.
- Live-mode clip launch animations: a progress ring until the quantized start, blinking on the beat.
- Meter and fader motion on automation playback, and a smooth vertical scroll when keyboard navigation reveals a track.
