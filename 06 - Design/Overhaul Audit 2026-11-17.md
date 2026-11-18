---
date: 2026-11-17
type: audit
status: first pass complete
---
# Usability and Reliability Overhaul: Audit (2026-11-17)

The owner asked for a full overhaul brief covering: every control works or is honestly disabled, a central action registry with
shortcut presets and an editor, plug-in browser taxonomy, consistent dismissal of transient UI, track-header scrolling,
an authentic Analog Mode tape deck, and tests for all of it. Mid-session the owner added two requests: Warm Analog plug-ins
become **pedals on a pedalboard**, and testing should use **real keyboard and mouse input** where possible.
That second request replaces the earlier rule against OS-level input. The screen still has to be unlocked.

This note is the durable inventory. Severity: **P0** data loss, crash, or corrupt audio. **P1** broken primary workflow.
**P2** inconsistency or poor discoverability. **P3** polish.

## Baseline (start of session)
- `swift build`: clean. GUI self-test: 346 checks pass (Graphite).
- Not yet audited this session: every menu item, the piano roll, the takes window, import/export flows, and long-session stress.

## Findings and status

| # | Area | Finding | Sev | Root cause | Status |
|---|------|---------|-----|-----------|--------|
| 1 | Track headers | Vertical scroll over the header column did nothing; over a GAIN/PAN knob it changed the value instead | P1 | `TrackHeaderColumn` and `LauncherView` had no `scrollWheel`, so events died in the responder chain; `FaderControl`/`RotaryKnob` consumed wheel events | **Fixed.** One shared vertical viewport owned by `TimelineView.scroll(with:zoomAnchorX:)`; headers and launcher forward to it (`TrackScrollHost`); controls inside a host pass scrolling up. Self-test: 6 checks, incl. hit-testing |
| 2 | Track headers | After deleting or collapsing tracks, the vertical offset could exceed the content (blank area, headers past the end) | P2 | `scrollY` was clamped only while scrolling | **Fixed.** `clampScrollY()` on model change and layout. Self-test |
| 3 | Plug-ins | No way to bypass a plug-in (the brief's `plugin.bypass`; a pedal footswitch would otherwise be a dead control) | P1 | Not implemented in the engine | **Fixed.** `Engine::setPluginBypassed` (undoable; a bypassed effect leaves the chain and its latency, a bypassed instrument is silent), C API 25, project format 10, `plugin.setBypassed` command. Engine test: bit-exact null when bypassed, save/reopen, undo |
| 4 | Analog Mode | Reels turned at 1.2 pt of tape per second (about 0.08 rad/s), effectively still | P1 | Arbitrary scale constant | **Fixed.** ω = v/r integrated exactly on a spiral pack (Δθ = 2π·Δr/h); v scaled from 15 ips on a 10.5-inch reel; position-driven, so frame drops don't desync. Self-test checks against the closed form |
| 5 | Analog Mode | Plug-ins were rack units; owner wants pedals on a pedalboard | owner request | n/a | **Done.** See [[#Pedalboard]] |
| 6 | Shortcuts | Shortcuts lived in menu key equivalents, a three-preset table and scattered `keyDown`s; no registry, presets, editor or conflict detection | P2 | Organic growth | **Done.** `ShortcutRegistry` + editor ([[Keyboard Shortcuts]], [[ADR-0010 Command registry and shortcuts]]). Self-test plus real input (search, record ⌃⌥M, use it, old key free) |
| 7 | Shortcuts | After K was freed, a plain K toggled Count-In (⇧K) | P1 | AppKit's menu matching ignores Shift for letters; unbound keys fell through to it | **Fixed.** The registry owns all keys; only unknown ⌘/⌃ combinations reach AppKit. Found by the self-test (Count-In left on broke later recording checks) |
| 8 | Dialogs | Return didn't answer a sheet: the registry ran Go to Start first | P1 | Shortcut dispatch ignored dialogs | **Fixed.** `dialogInFront` (modal session, sheet or alert): shortcuts step aside. Regression test; real Return now answers the recovery sheet |
| 9 | Transient UI | Command palette and Edit Controls popover: dismissal unverified | P2 | — | **Verified with real input:** both close on an outside click and on Escape and reopen. An outside click also reaches what's under it (non-destructive). See [[UI Conventions]] |
| 10 | Plug-in browser | Flat list; no categories, favourites or recents; still said "CLAP comes later" and refused to add CLAP after CLAP hosting shipped | P1 (stale, dishonest control) | UI not updated with the engine | **Done.** Taxonomy, sidebar, fuzzy search, filters, favourites, recents, most used, collections, tags, failed states, double-click and drag to insert. [[Plug-in Browser]] |
| 11 | Plug-in chain | No reordering | P2 | Not in the engine | **Done.** `plugin.move` (C API 26), drag and Move Left/Right; engine test |
| 12 | Device drag | Dragging a unit failed when another window was key | P2 | The deepest view (a stack view) refused the first click | **Fixed** with `acceptsFirstMouse` and surface hit-testing; verified with a real drag while the browser was key |
| 13 | Editing | No cut, copy, paste, duplicate or select all for clips | P1 | Not built | **Done.** Engine clipboard (cut then paste works), `clips.copy`, Edit menu (responder chain keeps text fields working). Engine tests plus real ⌘X/⌘V in the self-test |
| 14 | Analog Mode | No tape-deck view | P2 | — | **Done.** View ▸ Tape Machine ([[Tape Machine]]). Self-test plus real input (open, play, hold F.FWD and REWIND) |
| 15 | Dead controls | No automated check | P2 | — | **Done.** Self-test fails on a menu command without a handler or an enabled button without an action (all windows currently pass) |

## Not done (honest list)
- **Track features:** track height, hide/show, duplicate, markers and marker navigation, vertical zoom and zoom to selection are implemented and covered by tests or self-test. Track groups remain unbuilt. Real ⌃⇧D input duplicated the selected track on a generated project.
- **Plug-in isolation:** hosting stays in-process (ADR-0009); scanning is out of process. A crashing hosted plug-in can
  still take Dalnok down.
- **Tape coloration** (saturation, wow and flutter) as an opt-in effect: not built. The Tape Machine is visual only.
- **Accessibility:** labels and keyboard operation exist for the new controls, but a full VoiceOver pass and a
  keyboard-only walkthrough of every window have not been done.
- **Warm Analog capture time:** the 64-track generated project capture takes about 5.5 s in Warm Analog vs 2.6 s in Graphite; layer shadows render on the CPU. On-screen cost is not measured.
- **Plug-in categories on your real library** (453 plug-ins, metadata only, not scanned) were not reviewed one by one.
  A scan (Scan Plug-ins) gives VST3 and CLAP their declared categories.
- **Not exhaustively audited:** every menu item by hand, the piano roll, the Takes window and the import flows.
  The dead-control scan covers handlers, not behaviour.

## Pedalboard
- `Pedals.swift`. Each plug-in on the selected track becomes a stomp box. Its look comes from a seeded generator
  (FNV-1a + SplitMix64 over the plug-in's name), so it stays the same across launches. The generator picks:
  18 enclosure colours; a finish (powder coat, hammertone, metal flake, brushed, anodized); a knob style
  (ribbed, chicken head, knurled chrome, skirted cream, jelly bean); artwork (stripe, border, pinstripes, circle,
  chevron); one of 10 system typefaces; an LED colour; a footswitch type (chrome or rubber pad); corner radius;
  corner screws; and numbered scales.
- **Size follows the control count.** Up to 4 controls sit in one row: a 1-knob mini, then 2-, 3- and 4-knob boxes.
  Five or more fill two rows and the pedal grows wider.
- **Controls.** Continuous parameters default to knobs, stepped parameters (2–11 positions) to rotary selectors, and
  on/off parameters to toggle switches. Right-click any control to change it to Knob, Small Knob, Rotary Selector,
  Toggle Switch or Slider. The choice is remembered per plug-in. Drag (⇧ for fine), scroll and the arrow keys work;
  double-click resets. VoiceOver sees each control as a slider or checkbox.
- **Footswitch** = real bypass (undoable); the LED shows it. Graphite gets a power button in the device header.
- **Right-click the pedal**: Bypass/Turn On, Open Plug-in Window, Edit Controls, New Random Look, and Colour,
  Finish, Knobs, Artwork, LED and Footswitch submenus, plus Reset Look.
  Looks are presentation only (user defaults, keyed by plug-in name), never project data.
- The board is drawn as an aluminium frame with carpeted rails. Patch cables are unchanged. The panel is 268 pt tall in
  Warm Analog (196 in Graphite).

## Measurements (release build, M3 Max, 2026-11-17)
- Engine live path: 64 tracks avg 88.7 µs per 512-frame block (worst 222.9 µs); 256 tracks avg 352 µs (worst 768 µs)
  of a 10.7 ms budget. Offline: 159× real time at 64 tracks, 40× at 256.
- UI: the generated 64-track project opened, played and rendered with 0 audio overloads in both themes.

## Verification log
- Engine: `scripts/ci/plugin-host.sh` — 11 tests incl. `bypassPassesAudioThroughAndSurvivesSaveAndUndo`.
- GUI self-test: Graphite 424 checks, Warm Analog 435 checks, all pass.
- Engine: 158 tests (`swift test`), plus 12 hosting tests with the test VST3/CLAP (`scripts/ci/plugin-host.sh`).
- Snapshot review of the pedalboard with AUHipass, AUDelay, AUDistortion, AUPeakLimiter on a generated project.
- Real OS input (owner's request): header scrolling, footswitch, knob drag, ⌘S/⌘Z/⌘W, palette and popover
  dismissal, the shortcut editor (search, record, use), a browser drag onto the device panel, a device drag
  reorder, and the tape machine keys.

- Later self-tests passed 447 checks in Graphite and 464 in Warm Analog, including the control-bar tape strip. A later real-input check on a generated project confirmed PLAY, FF and RTZ, with window captures showing the playhead and controls.
