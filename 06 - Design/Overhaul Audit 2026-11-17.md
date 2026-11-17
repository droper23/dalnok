---
date: 2026-11-17
type: audit
status: in progress
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
| 6 | Shortcuts | Shortcuts live in `MainMenu` key equivalents plus scattered `keyDown`s; no registry, presets, editor or conflict detection | P2 | Organic growth | Open. Next phase |
| 7 | Transient UI | Only the Edit Controls picker is an `NSPopover(.transient)`; the command palette is a `KeyPanel`; menus are AppKit (fine) | P2 | No shared component | Open. Audit each window/panel for click-outside + Escape |
| 8 | Plug-in browser | Flat list in Plug-in Manager; no categories, favourites or recents | P2 | n/a | Open |
| 9 | Analog Mode | No full tape-deck view (only small reels beside the counter) | P2 | n/a | Open |

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

## Verification log
- Engine: `scripts/ci/plugin-host.sh` — 11 tests incl. `bypassPassesAudioThroughAndSurvivesSaveAndUndo`.
- GUI self-test, both themes (see the journal for counts).
- Snapshot review of the pedalboard with AUHipass, AUDelay, AUDistortion, AUPeakLimiter on a generated project.
- Real OS input: see the journal entry for this session.
