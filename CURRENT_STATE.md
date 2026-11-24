---
updated: 2026-11-24
phase: Phases 1, 3 and 4 complete; 2 (power-loss test) and 5 in progress
milestone: 0.4.0 released 2026-11-23 (four themes in six looks with their own figures, Library and Inspector, Settings in nine pages)
---
# Current State

## Guitar processors (2026-11-24)
- Added Guitar Tune (recorded single-note correction) and Guitar Studio (guitar effects chain), as native built-ins; see ADR-0017.
- GuitarTuneTests / GuitarStudioTests: 11 tests pass, including 44.1/48 kHz pitch correction within 5 cents, stereo consistency, compensated unity, scales, bend tolerance, state/save/load, delay/room, cabinet and alias attenuation.
- Self-test (`SelfTest+Guitar`, all six looks at 48 and 44.1 kHz, 37 checks each): insertion, the pitch display, Tune then Studio, all six factory presets through the real device menu with every parameter replaced and the prior settings restorable.
- Factory presets (device ▸ right-click ▸ Factory Presets) are not undo steps: plug-in parameters live outside the undoable model, like knob moves. Undoable plug-in state would be an engine change (ADR needed).
- Intended order: clean DI → Guitar Tune → Guitar Studio. Commercial sound parity and listening validation remain unproven; no chord correction, formant preservation or cabinet IR loader.

## Latest (2026-11-24, day): open bugs fixed, parity features
Same branch (API 47). Every bug from the ten-tester hunt fixed; then features toward Logic/Ableton parity.
- **Fixed:** tempo changes move markers, automation and the cycle with the beats (`remapMidi`, `cycleFollowsTempo`, also on
  undo); same start+pitch notes merge (`sortedNotes`, later wins); velocity lane draws chords loudest first; 16-bit
  export TPDF dither; `textFaint` ≥ 4.5:1 everywhere (self-test checks all palettes); commands reject out-of-range
  values; CLI warning on stderr; Logic preset ⌘T = split (Dalnok's ⌥⌘N already matches Logic's New Tracks).
- **New:** Dalnok Delay / Reverb / Gate (`fx/time_fx.*`); Bounce Track in Place (`Engine::bounceInPlace`, ⌃⌘B);
  BS.1770 loudness (`loudness.*`, master strip, `dalnok_render_loudness`); seven export formats (`openAudioWriter`,
  `dalnok_render_to_file`); Export Stems (`Scratch::stemL`, `dalnok_export_stems`); MIDI Functions
  (`Engine::transformNotes`, `dalnok_midi_transform`). Offline renders share `Engine::renderBlocks`.
- **Also new (later):** clip loop (`ClipState::loopLength/loopPhase`, compiled per pass, format 16); MIDI controllers
  and pitch bend (`MidiCC`, `PluginNote` kinds 2/3, AU/CLAP MIDI, VST3 `IMidiMapping`, live passthrough, piano roll
  controller lanes in `PianoRoll+Controllers.swift`, format 17).
- **Verified:** `swift test` 335 pass; self-test matrix 12/12 PASS after each UI change; `plugin-host.sh` and
  `plugin-isolation.sh` PASS (controller test in and out of process); fuzz 60 s clean after the reader changes.
- **Not reproduced:** "a hit near a trimmed audio clip's start isn't quantized" (two tests added, both pass before and after).
- **Next for parity (ranked):** sampler / drum instrument; recording controllers from a keyboard; editable warp markers
  and warp modes; region inspector; step input; built-in synth responding to bend and sustain; MP3 export (needs an
  encoder library); render queue; spectrum and correlation meters; racks / macros; capture MIDI; groove pool.

## Earlier (2026-11-24): ten-tester bug hunt
Same branch. Ten agents (one on real input), 12 fix commits; journal 2026-11-24 has the list.
- **Fixed:** transpose kept a quantized clip's warp; export rings out to silence (`dalnok_render_to_wav_tail`, trimmed
  to the last audible block); notes stay inside their clip on quantize/drag/nudge; strength 0 no-op; clip lamp with DC
  offset; NaN/Inf float samples; REAPER nesting crash; `clip.move` overflow; empty take folder; mixer I chip; themed
  toasts; empty-state hints; piano roll `[`/`]` and VoiceOver; Prism Light accent text; copy edits.
- **Verified:** `swift test` all pass (307), self-test matrix 12/12 PASS, perf 64 tracks 0 overloads.
- **Open (ranked):** tempo change leaves markers/automation/cycle behind (`remapMidi`, engine.cpp); same start+pitch
  notes collide (`NoteKey`); velocity lane hides chord stems; no 16-bit dither, LUFS or true-peak; `textFaint` < 4.5:1
  on controls; commands clamp out-of-range values silently; `session.describe` warning on stdout; no default
  create-track key (⌘T); hit near a trimmed audio clip's start not quantized; docked piano roll Prism Light keys unseen.
- **Gaps vs Logic/Ableton named most:** freeze/bounce-in-place, clip loop brace, warp modes, racks and Simpler, more
  stock effects (reverb, delay, gate), CC/pitch-bend lanes, scale quantize, step input, region inspector, LUFS meter.

## Earlier (2026-11-23, late night): clip editor, Logic-style quantize, audio quantize, editing fixes
Branch `feat/clip-editor-quantize` (API 47). See the journal for details.
- **Docked clip editor:** double-click a clip → it opens at the bottom (piano roll / audio sample view with transients);
  Clip / Devices switch, View ▸ Clip Editor (⌥⌘E). `ClipEditorPanel.swift`.
- **Q quantizes** notes or clips with the quantize value and strength (clip editor bar, Clip ▸ Quantize).
  **Audio Q** (`audio_quantize.cpp`, `warp.cpp`): one clip with a warp map (format 15, `dalnok_clip_warp`/`_set_warp`);
  attacks at their own speed, the rest stretched; rendered by the stretch cache (`renderWarp`).
- Editors show the playhead; themed Clip / Devices switch and Quantize button (⌥⌘E). Fixed Graphite knobs drawn as
  Atelier dials (faceplate `case … where`), Atelier dial light bars hidden by the skirt, the drag bubble's stale look.
  Input Monitoring prefers a connected interface over the built-in mic when no input is chosen.
- Double-click a lane → one-bar MIDI clip (empty audio tracks become instrument tracks, also on adding an instrument
  plug-in); double-click-drag draws notes; ⌘C/⌘X/⌘V/⌘D for notes; plug-in copy/paste (`dalnok_plugins_copy`);
  Duplicate Track in the track menu; hover playhead; Play from a selection.
- **Fixed:** MIDI clip right-edge resize made it vanish; ⌘C/⌘V/⌘X/⌘D never reached the piano roll.
- **Verified:** `swift test` all pass, AudioQuantizeTests (hits within 0.5 ms of the grid), self-test matrix 12/12 PASS.
- **Open:** audio quantize not yet heard on the owner's real drums; the docked piano roll is short at the default height;
  monitoring by ear with the Scarlett still not confirmed (engine path verified on the hardware: opens, meters, records).

## Earlier (2026-11-23, late): flakes fixed, fuzz clean, two-input recording on the Scarlett, stills
No new feature. Branch `chore/flakes-and-checks`.
- **CI `record-crash.sh` flake fixed:** a take killed after its journal was written but before capture created the spool
  could not be recovered ("invalid capture spool"). It now recovers as an empty take (`recoverCapture` emptyRate/emptyChannels);
  engine test `aTakeKilledBeforeCaptureBeganRecoversEmpty` (missing and partial spool recover; a corrupt header still fails).
- **Self-test crash under load fixed:** the first split used a fixed 0.3 s pause after a seek; when the seek had not landed the
  split was a no-op and the Undos undid the import (nil clip, crash at SelfTest.swift:156). Now `settle`, and a failed check
  instead of a crash. Matrix 12/12 PASS.
- **Fuzz 120 s clean** (156,688 runs, no findings; 1,000 round-trips pass). Needed: `#include <algorithm>` in `au_host.mm`
  (Homebrew clang 23), an LSan suppression for the stretch-cache worker's thread start state (macOS LSan doesn't scan
  that thread's stack), and the build stamp taken at build start (a header edited mid-build went unnoticed).
- **Two inputs on the Scarlett** (`dalnok-cli record "Scarlett Solo 4th Gen" 1,2 30 … --output default`): two takes, 0
  dropped frames, guitar and mic played by the owner. The two files are identical sample for sample, and so are channels 1
  and 2 recorded with ffmpeg outside Dalnok: the interface sends the same signal to both USB inputs (likely its routing in
  Focusrite Control 2). Dalnok's per-track channels (0 and 1) and capture map are right. Distinct signals not yet verified.
- **Stills:** the traveller seen on AUNewPitch's Pitch Scale (Atelier Dark and Light); it said L · C · R on a pitch
  control, now − · 0 · + unless the parameter is pan/balance/width. The two-line header seen in the self-test's
  `header-two-line.png` (Atelier Dark). The header check now uses the last row (the first can be a hidden track).
- **Open:** a one-block (512 frames) ⌘V paste offset seen once in a single run; distinct-signal two-input test after the
  Scarlett's routing is changed; the gallery's Inspector shows the system input device's name (the owner's).

## Earlier (2026-11-23, night): Scarlett hardware tests
Owner connected the Scarlett Solo 4th Gen. No engine change.
- **Loopback** (`DALNOK_TEST_LOOPBACK="Scarlett Solo 4th Gen:3" swift test --filter HardwareLoopback`): 2/2 pass.
  Measured 1143 vs 1200 reported; per stream 1137, 1137, 1143, 1137, 1137, 1143 (one frame above 2026-11-21's 1136/1142,
  same 6-frame step); every take placed on the sample (error 0 in 6 of 6).
- **Self-test with real input** (`DALNOK_TEST_AUDIO_INPUT="Scarlett Solo 4th Gen"`, renamed copy, 48 and 44.1 kHz): all 10
  real-input checks pass at both rates (monitoring opens the input and keeps the output, meter moves, take placed,
  input closes). It first failed one later check ("a track with two clips for clip selection"): the hardware step
  always stopped the device, so a later seek never landed. It now leaves the device as it found it; both rates PASS.
- **Still not verified:** the Scarlett's two inputs recorded at once; monitoring by ear (system output stayed muted).

## Earlier (2026-11-23, evening): plug-in multi-select, figure motion, fuller Atelier keys, folded strips
PR #21 merged (`main` a37d3c2); `dist/Dalnok.app` rebuilt from it. No engine change.
- **Multi-select:** ⌘/⇧-click units in the chain, ⌫ removes them (one undo step), right-click "Remove N Plug-ins",
  a click outside the units or Esc deselects (`DevicePanel.select`, `deselectIfOutside`, `KeyOwner`). Several rows in
  the Library or the Plug-ins window, or several dragged (`NSPasteboard.dalnokPluginPaths`), insert in order as one
  step (`MainWindowController.insertPlugins`).
- **Settings ▸ Appearance ▸ Figure motion** (`Faceplate.figureMotion`): hold under the pointer / always / only when
  pointed at.
- **Atelier:** short key sections stack in one column (`FaceplateColumn`), the key starts at the plate's top; the
  seismograph's strip clears both margin notes; folded units drawn as an engraved slip (`FoldStrip.drawPlateEdge`);
  folded names shrink to 8.5 pt before truncating, without "Dalnok".
- **Track headers:** the FX count and group take a second line when the source name is long (`TrackHeaderRow.setInput`).
- **README:** seismograph, key instruments, plain dials, figure motion, multi-select; Atelier figure stills regenerated.
- **Verified:** self-test matrix 12/12 PASS (one Warm Analog 48 kHz run crashed at an early clip drag under load and
  passed alone), a fresh-preferences run PASS, CI 6/6 (build-test passed on a re-run: `record-crash.sh` reported an
  invalid capture spool once; this PR touches no engine code; not investigated).
- **Open:** the early clip-drag flake under parallel load and the `record-crash.sh` flake; pan traveller still has no
  still.

## Earlier (2026-11-23, afternoon): Atelier seismograph, clearer controls, plain dials, fast self-test
PRs #18 (plug-in looks revert, fold, OPEN, matrix script) and #19 (seismograph) merged; `main` 3b8dadf. No engine change.
- **Graphite and Warm Analog plug-in figures reverted** at the owner's request (Prism's optics and Atelier's stay; Warm
  Analog keeps `PedalLabel` and the sidechain cable). Atelier: no crop marks between plug-ins, units fold.
- **Atelier compressor = two-pen seismograph** (`AtelierFigures.seismograph`, enum case still `.governor`): dashed in-pen,
  bold out-pen, gold hatching for the reduction, threshold rails and an inclined-plane ratio; live from
  `MovingCoilMeter.traceHistory`, a synthetic rhythm in silence.
- **Key controls by unit** (`FaceplateControl.rowInstrument`): knife switch, notched selector, inclined plane (ratio),
  lettered octave rule (Hz), stopwatch (time), vernier (dB), comparison slate (mix), traveller (pan), sextant (%), rule.
  Names written in full; columns fill one at a time; no label overlaps a drawing (gallery stills, both variants).
- **Settings ▸ Appearance ▸ Plug-in controls: Plain dials** (`Faceplate.plainDials`, Atelier only), with a self-test check.
- **Self-test matrix** `scripts/dev/selftest-matrix.sh`: 12 runs in parallel, ~85–115 s instead of ~14 min; each run a
  renamed copy with its own preferences domain, `DALNOK_BACKGROUND=1` keeps them out of the Dock. Last run 12/12 PASS.
- **Not done:** pan traveller checked only by the self-test (no still); Scarlett hardware tests (ask the owner); fuzz.

## Earlier (2026-11-23): UI audit of every look, figures for Graphite, Prism and Warm Analog, Settings in nine pages
Branch `feat/ui-audit-0.4` (from `main` ac85c86). Two review rounds, 12 reviewers in all, each finding checked against the
stills; decisions and what is still open in `06 - Design/UI Audit 2026-11-23.md`. No engine or API change.
- **Figures in every look** (`LookFigures.swift`: Graphite telemetry, Prism optics; `PedalScreen.swift`: Warm Analog
  circuits), sharing Atelier's roles, links, handles and `FigureClock` (now any `FigureAnimating` view).
- **Settings**: nine pages and search (`Settings.swift`). **Controls in the look** (`Theme.tintControls`,
  `Theme.checkbox`, `ThemedCheckCell`). **Prism glass** for Settings and first launch (`PrismBackdropView`).
- Solo fades silenced lanes (`Session.soloSilenced`), "muted" in every look, per-look meter ramps (`MeterView.ramp`),
  playhead afterglow (flat arrangement), empty-chain figures, start page without mixer, pedal labels (`PedalLabel`),
  Warm Analog sidechain cable, Prism EQ dispersion, recovery offer after first launch, `Motion.pageIn`.
- **Gallery**: `DALNOK_GALLERY_MOTION=1` (06-motion frames), `DALNOK_GALLERY_SETTINGS=1` (every page); 15-figures for
  Graphite and Prism. Live animation capture not done: the screen stayed locked.
- **Perf**: Prism `--perf 20` (64 tracks) Dark and Light: 0 overloads, 0 missed, main p99 8 ms, max 20 ms.
- **Released 0.4.0** (2026-11-23): PR #16 merged (857d40e), tag `v0.4.0`, GitHub release with `Dalnok-0.4.0.zip`
  (SHA-256 7fc9deb3…ae3f7). Round 3 done (code review + three reviewers). Final self-test matrix on the PR head: 12/12
  PASS, 0 FAIL; CI 6/6 green (incl. ASan/TSan).
- **Not done (needs the owner or an unlocked screen):** README tours and plug-in clips re-recorded (screen was locked);
  live animation capture; hardware loopback and input self-test on the Scarlett; fuzz 120 s (no parser changed);
  site screenshots and `publish-site.sh` (owner's go-ahead).
- **Next:** the "Still open" list in `06 - Design/UI Audit 2026-11-23.md` (Graphite flat telemetry cards, Warm Analog
  console furniture and twin VUs, Prism spectral master meter and glass browser/palette, Atelier drawn sliders and
  neatline, per-look motion for remaining transitions, producer toolbar: snap/zoom/follow, CPU readout).

## Earlier (2026-11-23, past midnight): moving figures, Library ▸ Files, first-launch looks
Branch `feat/atelier-motion-library-files` (from `main` f19f0c0). The owner's fifth round; decisions in
`06 - Design/Atelier Audit 2026-11-22.md`. No engine or API change (C API 46, format 14).
- **Fixed: Space after the Library** (and any clicked list): bare shortcut keys go to the registry before the focused
  view (`CommittingWindow.shortcutFirst`); text, `KeyOwner` views, navigation keys and FKA-focused controls keep theirs.
- **Atelier figures move** (`FigureClock`, 30 Hz, only while on screen; still under the pointer, Reduce Motion and in
  stills): governor spins, pendulum swings, crank (Scotch yoke) turns, the clipped wave runs, the chamber's sound
  travels. Drag-direction arrows on every part; part and key row light together with a named tag.
- **Device panel** height resizable in every theme (top edge; `devicePanelExtra`); Atelier keys one column when they fit;
  scroll-bar gutter (C6). **Inspector** marks the plug-ins in view in the device panel and the one clicked.
- **Library ▸ Files** (`LibraryFiles.swift`): places + added folders, unfold in place, click to preview, drag/Return to
  import, projects open; search over the project, added folders and places opened this session.
- **Start page** hides the Library and Inspector (remembered). **First launch** asks for the look first (live, pictures in
  `Resources/Looks`), then shortcuts. Audit **B4** (needle master meter), **C5** (lower-edge fades), C12 partly.
- Graphite README tour and plug-in clip retaken (every frame checked). Gallery frames 16-library-files, 17-first-launch;
  15-figures has a mid-motion row.
- **Verification:** self-test matrix (explicit rate, `caffeinate -du`), all PASS, 0 FAIL, 15 machine SKIPs each:
  Graphite 1047 / 1028, Warm Analog 1032 / 1013, Prism Dark and Light 1047 / 1028, Atelier Dark and Light 1056 / 1037
  (48 / 44.1 kHz). `swift test --disable-sandbox` 289 pass; gen-api up to date. Gallery stills of all six looks reviewed.
  Not verified with real keys: this terminal host lacks Accessibility permission, so `drive.swift` couldn't post input.
- **Next (for the next agent, in order):** 1. **Settings restructured** into clear pages (see the 0.4.0 plan).
  2. **Graphite, Warm Analog and Prism brought to Atelier's level** (one audit note per theme, then fixes: plug-in
  figures that move and link to their rows, meters, panels, first-launch cards). 3. A **full bug and edge-case pass**
  (checklist in `08 - Testing and Benchmarks/Release 0.4.0 Plan.md`, incl. real-key focus checks once Accessibility is
  granted). 4. Release **0.4.0** per that plan. Still open: audit C7, C12 (title block, marker), VoiceOver by ear,
  Prism `--perf 20` repeat, README tours/clips of the other five looks (they predate the moving figures).

## Earlier (2026-11-22, late night): Atelier plug-ins as one engraving
Same branch `feat/atelier-polish` (PR #12). The owner found the legend plates still too close to Graphite; decisions
in `06 - Design/Atelier Audit 2026-11-22.md` (fourth round), design in `06 - Design/Atelier.md`.
- The chain is one diagram: stations on the signal line, caption at the foot, mercury columns, margin notes, bypass shunt.
- Figures are instruments dragged by lettered parts (`AtelierFigures.swift`): governor, chamber, pendulum, clipped wave,
  crank and disc; EQ keeps the Frequency Atlas. Key rows are unit instruments (`FaceplateControl.rowInstrument`).
- Inspector: insert list "Show all N" past six; Atelier's Fig. 3 runs down the panel and folds long chains.
- New self-test checks: governor drag raises the threshold; nine inserts list six, Show all lists nine, the figure folds D–H.
- Gallery frames `14-inspector-long-chain`, `15-figures` (all five figures with sample values).
- Self-test matrix (explicit rate, `caffeinate -du`), all PASS, 0 FAIL, 15 machine SKIPs each: Graphite 1028 / 1009, Warm Analog 1013 / 994, Prism Dark and Light 1028 / 1009, Atelier Dark and Light 1033 / 1014 (48 / 44.1 kHz). `swift test` 289 pass.
- **Next:** README media for every theme (scripts/dev/readme-media.sh, screen recording), site screenshots (ask before
  publishing), then the audit's B4, C5, C6, C7, C12.

## Earlier (2026-11-22, night): Atelier, the owner's review round
Branch `feat/atelier-polish` (from `main` fbc01ae). No engine or API change (C API 46, format 14).
- **Plug-ins** (owner: "not a reskin"): Atelier plates keep their figure and show parameters as a lettered key with
  slide-rule scales (`FaceplateControl.legendRows`); switches are Off | On cells; the power key is a knife switch.
  Third-party plug-ins get the same legend plate with a category figure. Behaviour, keyboard and a11y unchanged.
- **One oblique** for every drawn solid (`Atelier.depth`/`recede`/`obliqueSide`): dials, fader blocks, cursors, glyphs.
- **Engraved glyphs** (`AtelierGlyphs.swift`) for the control bar, tools and Library places (audit A9).
- **Type:** Atelier is Source Serif 4 throughout (labels and figures too); `Atelier.unifyFonts` re-sets system controls.
- **Clock:** split counter housing, two drums side by side with the second clock. **Inspector:** Fig. 3, the live signal
  path, only in spare room. **Colour:** red means record only (D3); inks separated by lightness (D5).
- **Fixes:** Library place names blank after the panel slid closed and open (button cell cached a zero-width layout;
  now drawn directly, fixed icon column); clipped Library search; descenders clipped in plate labels; R chip low.
- Gallery has a new frame `13-panels` (Library closed and reopened with motion on, a category open).
- Self-test matrix (explicit `DALNOK_SAMPLE_RATE`, under `caffeinate -du`), all PASS, 0 FAIL, 15 machine SKIPs each:
Graphite 1025 / 1006, Warm Analog 1010 / 991, Prism Dark and Light 1025 / 1006, Atelier Dark and Light 1028 / 1009 (48 / 44.1 kHz).
`swift test --disable-sandbox` 289 pass.
- **Open:** audit B4, C5, C6, C7, C12; VoiceOver by ear; Prism `--perf 20` repeat; owner's review of the new plates.

## Earlier (2026-11-22, late): Library and Inspector, phase invert, Atelier controls drawn as instruments
Branch `feat/inspector-library` (from `main` 96faf9a). C API 46, project format 14.
- **View ▸ Library (Y)** and **View ▸ Inspector (I)** (`06 - Design/Side Panels.md`): left sidebar (places, collections,
  Effects/Instruments/MIDI tabs, fuzzy search, `PluginTaxonomy` categories, drag or double-click to insert) and right
  inspector (input, output, monitor; volume and pan dials with read-outs; M S R Ø; numbered inserts with bypass;
  lettered sends; live meter). Remembered open state and width, resizable, toolbar buttons left of the transport,
  rebindable shortcuts, every theme in its idiom. Every edit is one undo step; nothing is cached.
- **Engine: phase invert** (`dalnok_track_set_phase_invert`, `DalnokTrackInfo.phase_invert`, catalog
  `track.setPhaseInvert`): flips the source before the inserts, so sends carry it. `PhaseInvert` tests (2).
- **Atelier audit** (`06 - Design/Atelier Audit 2026-11-22.md`): five low-cost reviewers plus the owner's answers
  (controls become drawings, gold bands on the dark plate, ruled heads on the light, two densities, header read-outs in
  every theme). Done: turned dials, fader blocks on screwed rails, the counter housing, the empty chain as a lettered
  plate, the mixer's signal figure, engraved start cards, View ▸ Illustrated Controls, themed plug-in browser,
  Settings, palette and pop-ups, contrast (Light dim text 7.1:1, numerals 5.1:1), cropping fixes. Open items listed in
  the audit note.
- **Verification:** `swift test --disable-sandbox` 289 pass; gen-api up to date. Self-test matrix (explicit
  `DALNOK_SAMPLE_RATE`; Full Keyboard Access off, 12 machine SKIPs each), all PASS: Graphite, Prism Dark and Light 1025 at 48 kHz / 1006 at 44.1 kHz; Atelier Light and Dark 1028 / 1009
  (the Illustrated Controls check); Warm Analog 1010 / 991. Prism's motion checks fail while the display sleeps (three
  clip-lift checks): run long matrices under `caffeinate -du`.
  Accessibility pass with Full Keyboard Access on (`DALNOK_A11Y_ONLY=1 DALNOK_A11Y_REPORT=1`): 42 checks, 0 SKIP, 0 FAIL
  in all six looks, both panels open; the setting was restored afterwards. Gallery stills of every look at scale 2
  reviewed; the Atelier pair was sent to the owner. Perf (release, large project): no overloads or missed blocks; the
  panels add nothing measurable (table in `08 - Testing and Benchmarks/Theme Performance 2026-11-22.md`).
- Self-test notes: a "48 kHz" run follows the device unless `DALNOK_SAMPLE_RATE=48000` is set, and a 44.1 kHz run
  leaves the built-in speakers at 44.1 kHz (they still are); the side-panel steps undo only named steps.
- **Next:** PR and merge after green CI; the open audit items; VoiceOver by ear (needs the owner); README media at the
  next release (Atelier now differs again).

## Latest (2026-11-22, night): Atelier redrawn as the Codex
Branch `feat/atelier-codex` (from `main` 6227550, PR #9 merged). The owner rejected the sketchbook Atelier; it is now a
codex of engraved plates (`06 - Design/Atelier.md`): ruled and measured drawing, sepia on parchment or cream and gold
on umber, plug-ins as numbered plates whose displays are captioned figures from live data (reverbs as a vaulted acoustic
chamber). Evidence: gallery review in both versions (including AUReverb2, AUDistortion, AUPeakLimiter via
`DALNOK_GALLERY_CHAIN`), self-test matrix below. README Atelier stills retaken; its tours and plug-in clips predate both
redesigns and are retaken at the next release.
- Self-test (Codex build), all PASS: Atelier Light and Dark 967 at 48 kHz and 948 at 44.1 kHz; Graphite, Prism Dark and
  Light 967 / 948; Warm Analog 952 / 933. The EQ-handle check now asks the screen where the handle is (each theme lays
  out its plot differently; the first Codex run failed it). `swift test` 287 pass.

## Earlier (2026-11-22, evening): launcher, accessibility, per-stream latency, Atelier sketchbook
Branch `feat/launcher-recording-and-drag` (from `main` 076706d, which has PR #8: Prism plug-ins drawn as glass, with
README media retaken). C API 45. Not merged yet.
- **Clip launcher (Phase 5):** record into a slot from its record mark (click again to stop; whole bars, one undo
  step); drops on a filled slot replace it; drags each way are one undo step; queued launches (`dalnok_launcher_queued`),
  launch sweeps and arrivals animate through Motion and respect Reduce Motion; the grid works from the keyboard.
  Evidence: `LauncherSlots` (4 engine tests); self-test (drags, record mark, motion on and reduced, keyboard).
- **VoiceOver and keyboard pass, every window, all six looks:** `SelfTest+Accessibility.swift` audits 13 windows
  (accessible names; Tab reaches every control; the loop closes). Tab had reached 0–2 controls in most windows; fixed
  (key-view loops, 5 pop-ups named, Tab-only focus for the tempo field and launcher grid, Edit ▸ Select Previous/Next
  Clip, Tab yields to focus even in the Ableton preset). Tab checks need Full Keyboard Access (SKIP otherwise); verified
  locally with it on. **Not done:** listening with VoiceOver itself.
- **Latency re-measured on every device stream** (`dalnok_latency_auto_set`): inaudible burst train correlated with the
  output. Evidence: `LatencyAuto` (3 engine tests), self-test, and the Scarlett Solo loopback: six streams measured
  1136, 1142, 1136, 1142, 1136, 1142, every take on the sample (`HardwareLoopback/everyStreamIsChecked…`).
- **Atelier redrawn as a sketchbook** (owner brief; fonts unchanged): `06 - Design/Atelier.md`. Plug-ins are pen sketches
  of hardware. README Atelier stills retaken; its tours and plug-in clips are pre-redo until the next release.
- **Theme performance:** `08 - Testing and Benchmarks/Theme Performance 2026-11-22.md` (Prism +0.55 ms main-thread p50
  over Graphite, Atelier +0.4 ms; no overloads, no missed blocks).
- **Verification:** `swift test --disable-sandbox` 287 pass; gen-api up to date. Self-test matrix (Full Keyboard Access
  off, so 9 Tab checks SKIP with the reason, plus 3 that need the test VST3), all PASS: 967 checks at 48 kHz and 948 at
  44.1 kHz in Graphite, Prism Dark and Light, Atelier Light and Dark; Warm Analog 952 / 933. With Full Keyboard Access
  on, the Graphite run passes 971 with no Tab SKIPs, and the audit-only pass is clean in all six looks.
- Cleanup: `docs/readme-media` deleted on GitHub.
- **Next:** open the PR, merge after green CI; a listening pass with VoiceOver; retake all README media at the next
  release (Atelier tours and plug-in clips especially).


## Latest (2026-11-21, night): Prism and Atelier themes, Dalnok Compressor, Composition Overview
Merged to `main` (2026-11-22): PR #4 (compressor, 484b9bf), then PR #5 (themes, 1a4cb73); CI green on both. Not released yet.
- **Backlog** cleaned (done items removed).
- **Dalnok Compressor** (built-in, `engine/src/fx/compressor.*`): feed-forward, stereo-linked, peak/RMS, soft knee,
  attack/release in dB, make-up, auto gain, mix; sidechain key from another track with a high-pass filter and Listen; a
  read-only Gain Reduction meter. `CompressorTests` (8): reference renders within 2e-6, static curve and meter within
  0.01 dB, attack/release one time constant within 0.01 dB, sidechain keying sample-accurate. Its sound is Dalnok's own:
  Logic's Compressor isn't in the parity template yet (needs the owner; see Logic Effect Parity).
- **Fixed:** a disconnected sidechain kept reading the old key buffer (freed memory) in every format; live test fails
  without the fix.
- **Themes** (owner brief 2026-11-21): Prism (Liquid-style glass, dark and light) and Atelier (drafting/typography, light
  and dark). Architecture in `06 - Design/Theme System.md`; designs in `Prism.md`, `Atelier.md`. Bundled OFL fonts.
  View ▸ Theme, ⌥⌘A Next Theme, Settings ▸ Appearance ▸ Light or dark (Match System follows macOS).
- **View ▸ Composition Overview (⌥⌘O)**, every theme: sections from markers, per-track coverage and automation.
- **Review tool:** `Dalnok <project> --gallery <dir>` (DALNOK_THEME, DALNOK_VARIANT): hero frame plus eleven screens.
- **Verification:** `swift test --disable-sandbox` 279 pass. Self-test PASS in every look: Graphite 908, Prism Dark
  908, Atelier Dark 908 (48 kHz); Prism Light 889, Atelier Light 889, Warm Analog 874 (44.1 kHz).
- **README** rewritten with media for all six looks (PR from `docs/readme-media-v2`): hero stills, mixer, piano roll and
  Composition Overview per look, window tours and new plug-in clips (add, turn, key, bypass, fold, reorder, remove)
  cropped to the device panel. `scripts/dev/readme-media.sh` regenerates all of it (`--tour` with
  `DALNOK_TOUR_MODE=plugin-ops` is the plug-in script).
- **Known issue (pre-existing, not theme-related):** the self-test's save/relink step sometimes fails ("save copied 14/15
  audio files"): takes from an earlier run's workdir appear in the new workdir's Audio Files and take numbering
  continues from them. Seen on Graphite and on the compressor branch before any theme work.
- **Not done yet from the queue:** clip launcher recording/dragging/animations, VoiceOver and keyboard pass of every
  window, automatic latency re-measure on stream restart. Prism vs Graphite `--perf` comparison (release build). VoiceOver in
  the new themes.

## Latest (2026-11-21, later): 0.3.0 released, recording I/O, sidechains, latency, groups
**Released:** PR #2 (`fix/audit-followups`) and PR #3 (`feat/recording-io`, which carried `feat/first-run-and-motion`)
are merged into `main` with merge commits; `v0.3.0` is tagged on `main` (662c1a5) and published on GitHub with
`Dalnok-0.3.0.zip`. CI is green on every job, including the self-test (three hover-check fixes for the runner's
smaller screen). Release standard: `08 - Testing and Benchmarks/Release Checklist.md`. Next work starts from `main`.
- **Recording keeps the output** (ADR-0008 amendment): different input and output devices run as one private
  aggregate (output = clock, input drift-corrected). Real check: recording from the Scarlett while the output stayed on
  the MacBook speakers (self-test `DALNOK_TEST_AUDIO_INPUT="Scarlett Solo 4th Gen"`, CLI `record … --output default`).
- **Input Monitoring (I)** per track (saved; ⌃I) and Monitor Armed Tracks, through the track's strip and routing,
  stopped or playing; the input stays open while monitored and a take attaches without a restart. C API 42.
- **Live waveform** while recording (`dalnok_record_live_peaks`, one peak per 256 frames).
- **Latency measured** (C API 43, Audio ▸ Recording Input ▸ Measure Recording Latency…, per device pair). Scarlett @48k:
  loopback 1136 vs 1200 reported (converters), speakers → Scarlett mic 2163 vs 2006 (≈1.1 m of air). HardwareLoopback:
  a take recorded back through the loopback lands on the exact sample. The Scarlett's round trip is 1136 or 1142 per
  stream start (6 samples, 0.13 ms); with the input kept open (Input Monitoring) measurement and take share a session
  and line up exactly (6 of 6 runs, both values). Release gate 2026-11-21: all 13 checks pass.
- **AU sidechains verified** with a test AU (`tools/dalnok-scan/fixtures/host_au.cpp`, `DALNOK_TEST_AU`), in-process and
  isolated. TDR Nova and Guitar Rig 7 FX expose sidechain buses; Nova accepted the connection (its own dynamics settings
  weren't made to duck in the probe, so that's not a behavioural check of Nova).
- **Track groups** (C API 44): linked volume/pan (relative), mute, solo, record, monitoring; one undo step; ⌘G clutch.
- **Fixed:** cycle wrap with delay compensation overshot by the compensation; live MIDI ignored routing (now through
  `renderBlock`; `renderLiveInput` removed).
- Not verified: the Scarlett's two inputs recorded at once on hardware (simulated only); acoustic monitoring by ear;
  power loss during a take. The system output was muted at volume 0; it was unmuted briefly for the acoustic latency
  runs and restored.

## Current priorities (2026-11-21)
- **First run and motion pass, then big-project performance** (branch `feat/first-run-and-motion`). Design notes and evidence: `06 - Design/First Run and Motion 2026-11-21.md`.
  - The new project screen (`06 - Design/New Project Screen 2026-11-21.md`) has three parts, and no shortcuts or templates:
    - project basics: tempo, time signature, and the output and input devices with the rate;
    - Audio Track or Instrument Track;
    - recent projects and the other ways in.
  - At first launch, people choose which app's shortcuts they know, and nothing else.
  - Control bar: Count-In, Clip Launcher, Automation, Mixer and Device Panel buttons.
  - Also new: a hint line, undo/redo/save notices, gliding zoom and page turns, a glow on new lanes, a count-in overlay.
- **Performance, measured with `--perf` on generated 128-track projects** (release build, real device, silent):
  - The isolated budget now adapts (ADR-0014 amendment). Effect skips on 512 isolated effects: 150 → 0.
  - UI stalls over 50 ms (128 isolated effects): 52 → 0 per 20 s.
  - Recovery snapshots reuse unchanged isolated states.
  - Remaining: the first recovery snapshot after loading still asks every plug-in (about 260 ms with 512 units).
  - The owner's own projects haven't been measured: that needs their go-ahead.
- Verification: `swift test` 255/255; `plugin-isolation.sh` PASS; `rt-effects.sh` clean.
  - Self-test 621 checks (Graphite, 48 kHz) and 606 (Warm Analog, 44.1 kHz), both PASS, run with the screen locked.

## Priorities (2026-11-20)
- **Safety is on by default** (ADR-0014, 2026-11-20). Both blockers from the first pass are fixed:
  - Isolated plug-ins on independent tracks process in parallel.
  - The main thread never waits on a host: edit counts and latency come from shared memory, and automation ranges are cached.
  - Hosts also warm up with 0.75 s of silence before reporting ready.
- **Real-project results** (`load-bench`, release; it now runs the run loop between blocks, as the app does): every plug-in loads in all 24 projects, and none opens Edited.
  - The worst isolated main-thread call while loading is ≤13 ms (in-process 0.28–1.7 s), and isolated loading is faster in 23 of 24 projects.
  - No isolated block runs over the period; 4 projects in-process do.
  - Isolated misses: 22 projects miss nothing. Two miss 6–13 blocks once, from one sampler script's 36 ms of work on its audio thread; in-process the same work stalls everything for 70–124 ms.
  - Known limit: on a heavily loaded machine (load average 5–14) isolated hosts miss blocks where in-process ones just get slower. The audio workgroup protects hosts in the app; `load-bench` has no device.
  - Off switch: Settings ▸ Plug-ins ▸ Safety; an explicit choice is kept.
- Earlier, the same day: verified with real OS input on the owner's plug-in library (14 plug-ins). Stress: 64 instances (22.6 MB/host, ≈54 µs per instance per block), 10× open/close, host killed mid-play (contained).
- **Fixed during the pass (each with a test):** isolated editors stuck on another Space; AUSampler's editor crashing its host (re-entrant fit) and growing to 3,937 pt; a 1.2 s main-thread block sending large states (macOS ignores MSG_DONTWAIT on the socket pair); VST3/AU/CLAP reports with no editor open marking projects Edited; a host crash counting as an edit; switching theme squeezing the arrangement's zoom.
- **Owner's UI requests (done):** plug-ins fold (C API 40, saved, undoable; Graphite rack blank, Warm Analog pedal tipped onto its side with cables following frame by frame; on/off works folded); arrival/departure animations; one Open button per unit with Controls in the plug-in window's title bar (isolated: the host's title bar sends DALNOK_EDITOR_SHOW_CONTROLS); Warm Analog pedals with a readout window and signal LEDs.
- **Known issues (generic):** a CLAP sampler with no instrument loaded ignores input; one CLAP synth reports editor edits only while processing; typing into AUDelay's value field sends no gesture end, so it is caught only by the state comparison at close; a host killed mid-play once produced one 117 ms block in the CLI (not reproduced by the crash test's 50 ms bound); an AU drum sampler's editor went blank once after its promo dialog (not reproduced).
- **Verification (Phase 2, final build):** `swift test` 242/242 (with the test VST3/CLAP); `DALNOK_SANITIZE=1 scripts/check.sh` PASS (normal, ASan, TSan, live smoke, self-test); `plugin-isolation.sh` with the isolated self-test PASS; `plugin-recovery.sh`, `record-crash.sh`, `rt-effects.sh` PASS; `fuzz.sh 120` clean (145,649 runs; the harness had failed since A-09 on a by-design singleton, now suppressed); self-tests plain Graphite 564 / Warm Analog 549, with the test plug-ins 601 / 586, and with `DALNOK_REAL_INPUT=1` 616 / 602, all PASS. The verification caught one regression from this session (changed slots animated as arrivals while slow plug-ins loaded: 102–112 ms main-thread gaps), bisected and fixed.
- **Releases:** 0.2.0 (Safety on by default, folding, pedal readouts, FL-style clip motion) and 0.2.1 (clips no longer swell when dragged) are published on GitHub. Both are tagged on `fix/audit-followups`, because PR #2 isn't merged yet.
- **Phase 3 done (2026-11-20), one commit each, with numbers in `docs/audits/findings.json`:**
  - A-19: CI jobs run in parallel (about 9 min → about 5.5 min wall time); `compile_commands.json` script. Changing one hosting adapter already rebuilds in 3 s.
  - A-15: `engine/api/views.def` generates the clip/track structs, fill code and Swift fields; one-pass clip reads (C API 41), 102x faster.
  - A-16: project format migration chain, schema (`engine/api/project-format.json`), 150 random round trips and fixtures v1–13. Found and fixed two under-versioned writes (sidechain, master gain).
  - A-18: self-test split by area. It passes at 44.1 and 48 kHz (`DALNOK_SAMPLE_RATE`; this fixed the LCD half-frame bug). Environment-dependent checks report SKIP, and CI runs a self-test job.
  - A-17: themes are a palette plus look capabilities; views no longer test for Warm Analog. Pixel check: 71 of 72 frames identical or within noise.
  - A-11: measured, already met: 256 tracks with 8 audible cost 24.5 µs vs 19.3 µs for 8 tracks.
  - A-13: vDSP kernels and block meters make live mixing 3x faster (64 tracks 143 → 46.5 µs, 256 tracks 567 → 180 µs), within 9e-8 of the scalar path.
  - The flaky `instrumentPluginPlaysNotesSampleAccurately` was a live deadline miss under load. It is reproduced by a forced miss, and the test now checks a miss as a miss.
- Next: merge PR #2 (owner's call). Then the remaining audit items, and the self-test CI job, which is informational until it proves stable on hosted runners.

## Earlier priorities (2026-11-19)
- **A-03 done:** undo steps below the top are clip deltas against the state they'll be applied to (`Engine::ModelDelta`). 500 structural edits at 4,096 clips: RSS growth 268.9 → 3.3 MB; edit p50 0.274 → 0.299 ms, undo 0.27 → 0.36 ms. `UndoDeltas` random-history test. 
- **A-06 partial:** `PluginHostService` and `UndoStack` extracted; Engine definitions split across engine.cpp (1,024 lines), engine_clips, engine_takes, engine_launcher, engine_device, engine_compile, engine_audio and engine_offline; layout in [[System Overview]]. `Transport` (transport.hpp) extracted too, and recording state is grouped as `RecordingState` (recording_state.hpp; its logic is still in record.cpp). Render compilation is still Engine members.
- **A-09 done:** files over 60 s stream from a decoded cache file through a bounded block cache (ADR-0016, C API 38). One hour of stereo: RSS 1,390 MB → 48.6 MB peak while playing, 0 missed frames. The time stretcher now uses a fixed seed (renders were not reproducible). Launched slots are prefetched along their own loop (a 2 MB-budget test went from 660,480 missed frames to 0). Cache files: least recently used first, kept within `DALNOK_STREAM_DISK_MB` (default 8 GiB), tested. 
- **Drawing time measured:** `audit-ui` includes drawing and the layer commit. A one-track structural edit cost 53.7 / 51.5 ms (Graphite / Warm Analog) with drawing. The timeline now redraws only changed lanes (applyCycle had invalidated it on every change), and mixer strips update in place unless their contents changed: 22.2 / 23.4 ms. Still above one frame; about 15 ms of the commit is unattributed. Self-tests: Graphite 539 / Warm Analog 522 (572 / 553 with the plug-in fixtures).
- **A-01 stage 2** (owner's wave-4 list: isolated deferred loading, editors out of process, shared deadline budget + audio workgroup, before/after measurements; then A-03, A-06, A-09, drawing time). **Item 1 done:** with Safety on, deferred activation starts isolated hosts (up to 4 in parallel) and returns at once; the host restores saved state before answering; Stop kills hosts still loading (C API 35, ADR-0014 amendment). Slow fixture (`DALNOK_TEST_INIT_FAILURE=slow`): 3 × 1.5 s load in 1.52 s, worst activate call 1.1 ms; GUI self-test with 3 × 4 s: worst main-thread gap 10–13 ms, Stop to done ≈0.15 s. Host crash handler reports crashes at once (fixed a baseline failure in `crashOrHangWhileLoadingFailsTheLoadOnly`). Isolation stays opt-in until verified on the owner's plug-in library. **Item 2 done:** isolated editors open in a non-activating floating window owned by the host (ADR-0015, C API 36). Tested with the test VST3 and Apple's AUDelay (engine tests plus self-test). Real input confirmed (`DALNOK_REAL_INPUT=1`): click, ⌘A and typing in AUDelay's field in the host window set Dry/Wet 50 → 25, and Dalnok stays active. **Item 3 done:** one deadline per callback shared by all isolated plug-ins (worst callback with 3 hung plug-ins 13.1 → 4.5 ms of a 10.67 ms period). The host processing thread joins the device's audio workgroup via a Mach rendezvous (real device: joined, and joins again after restart). C API 37 `dalnok_plugin_isolation_stats`. **Item 4:** before/after in `docs/audits/benchmarks/results.json` (`a01Stage2`). Isolation overhead unchanged (≈31–37 µs p50 per block), self-tests 538/520 both before and after, and with fixtures 572/552. **Real input (`DALNOK_REAL_INPUT=1`, both themes, PASS):**
  - Drag and undo: a real drag moved a clip 0 → 24000 frames. The redrawn timeline matched a full draw exactly (0 bytes, playhead overlay excluded). ⌘Z and ⇧⌘Z undid and redid it exactly.
  - Streaming: Space played a streamed 90 s file with 0 missed frames. A ruler click seeked to about 11.6 s, with 0 missed frames while it settled and after. The cache stayed at 7.0 of 63.8 MB.
  - Stop: a real click on Stop during slow isolated loading ended it in 92 ms. The worst main-thread gap was 37 ms (under the 50 ms limit), 38 ms after loading started, which suggests it was drawing the newly opened project.
  - AUDelay: typing into its field still gives Dry/Wet 50 → 25.
- **Audit follow-ups, wave 3** (owner asked for roadmap items A-04, A-08, A-10, A-05, A-01 in that order). **A-04 done:** per-track render content is shared between snapshots and rebuilt only for tracks whose clips changed; a random-edit test compares it with a fresh build (`dalnok_engine_snapshot_mismatches`, C API 31). 4,096 clips: structural edit p50 0.238 → 0.163 ms, undo 0.257 → 0.173 ms. **A-08 done for isolated plug-ins:** projects open and import with plug-ins queued and loaded one per run-loop turn (progress, Stop, track-menu Load; ADR-0013, C API 32); isolated ones load in their hosts without blocking (stage 2 above). In-process, a plug-in that blocks its own initialization still blocks the UI for that long. **A-10 done:** `scripts/ci/fuzz.sh` fuzzes the project reader and every importer (libFuzzer + ASan; 10-minute run clean after fixing a ZIP over-allocation and an FCPXML abort it found) and runs 1,000 random save/load round-trips; `scripts/check.sh` always runs parser tests under ASan. **A-05 done:** per-track revisions (C API 33) let the window re-read only changed tracks; mixer parameter path. 4,096 clips: parameter refresh ≈4.0 → 0.155 ms, one-track structural refresh 24.6 → 0.56 ms (drawing not measured). **A-01 stage 1:** opt-in out-of-process hosting (`dalnok-plughost`, Settings ▸ Plug-ins ▸ Safety, ADR-0014, C API 34); crash and hang contained and reloadable; existing hosting suites pass isolated (`scripts/ci/plugin-isolation.sh`). Not yet: default-on (needs a pass over the owner's plug-in library).
- **Audit follow-ups, wave 2.** Before activating incoming plug-ins, project apply writes a unique atomic recovery copy; if the write fails, the current project remains open. Recovery opens plug-in slots unloaded with their saved state. A crashing or hanging VST3 initialization fixture leaves a reloadable snapshot (`scripts/ci/plugin-recovery.sh`, normal and AddressSanitizer); `scripts/ci/recovery-smoke.sh` also passes. Synchronous project load now reports snapshot-write failure as an I/O error, with failure atomicity covered by `preactivationRecoveryAndFailure`. The crash/hang fixture compares the full normalized incoming model. Recovery markers retain unresolved copies across repeated crashes and clean quits; the self-test covers selection of both an older recovery and a newer incoming snapshot. This bounds the project-apply exposure; plug-ins remain in-process and A-01 crash isolation is open.
- Scalar gain, pan, mute, solo and master-gain edits use compact coalesced undo; mixed groups promote to a snapshot (ADR-0012). On the same generated 16-track × 256-clip project, `audit-bench --edits 500` measured gain-edit p50 0.058 ms → below its 0.001 ms display precision, and RSS after 500 edits 302.6 MB → 34.5 MB (starting RSS 34.2 MB and 34.4 MB). Snapshot undo and failure rollback remain for other edits; structural sharing remains open (A-03).
- Parameter-revision hints and a clip-free scalar refresh path are implemented; scalar setters and undo/redo defer refresh to the display tick. On the same generated 16 × 256 project, release `dalnok-cli audit-ui` measured AppKit drag p50/p95/p99/max 27.771875/30.493334/31.077125/31.706958 → 0.025000/0.031333/0.033625/0.037625 ms and parameter refresh 28.385333/29.191209/29.532209/29.715750 → 3.865959/3.934792/3.967375/3.967375 ms. Each used 30 warmups and 100 samples, Graphite and a visible mixer. Drag events were a tight burst; refresh includes synchronous UI callbacks but excludes deferred drawing/compositing and normal frame pacing. A-05a is **fixed**: the self-test verifies display-tick coalescing, unrelated-track edits without clip reads, scripted changes, undo and same-frame Touch recording; final generated-project walks in both themes cover gain drag, undo and scripted change.
- A-14 is **fixed**: an instrumented test withheld automatic collection for 100 callbacks, measured depth/high-water 64 and age/skips 36, then verified reset, collection and adoption on the next callback. A structural edit became audible within one 256-frame callback. `commit()` and the public pump normally collect automatically. If the queue is full and collection stops, adoption has no finite bound; no free-list was added.
- Verification: `DALNOK_SANITIZE=1 scripts/check.sh` passed on the final recovery changes: 197 tests in normal, ASan and TSan runs, live audio smoke and self-test. The self-test covers coalescing, unrelated-track clip reads, same-frame Touch and recovery-marker selection. `scripts/ci/recovery-smoke.sh` passed after the marker changes; the normal and ASan plug-in recovery fixtures passed the full normalized-model crash/hang comparison. Final corrected UI walks in both themes loaded a generated project and captured gain drag, undo and scripted changes for review. Full-frame drawing/compositing timing remains open. The UI walk now waits for project load; the reel self-test waits for the forward animation to settle before testing rewind.
- **Audit follow-ups (branch `fix/audit-followups`).** Wave 1 landed: linear snapshot compilation (A-04),
  shared plug-in state blobs (A-07), a flush-to-zero render environment (A-12), property and mutated-project
  parser tests (A-10, partial), and corrected status documentation (A-23). A-02 turned out to be already
  implemented — periodic recovery snapshot, launch prompt and `scripts/ci/recovery-smoke.sh` — and was
  misread in the audit. Measured at 4,096 clips: structural edit 0.770 -> 0.255 ms, clip-by-clip build
  1,272 -> 527 ms, undo 0.745 -> 0.238 ms. 191 engine tests pass. The remaining findings stay sequenced in
  `docs/audits/modernization-roadmap.md`. The later wave-2 update above supersedes the count and next steps here.
- **Independent audit (branch `audit/2026-11-codebase`).** Findings, measurements and an ordered plan are in
  `docs/audits/` (report, `findings.json`, roadmap, `benchmarks/`, dashboard). Headline results: the audio path
  is well inside budget (1.11 ms per 512-frame block at 512 tracks), while one UI model read costs 15.9 ms at
  4,096 clips, structural edits recompile in O(tracks × clips), every edit deep-copies the model, plug-ins run
  in-process with no autosave behind them, and media is fully decoded into RAM. Two P0 items: project autosave
  and out-of-process plug-in hosting. Note that the tables below are stale: plug-in editors, parameters and
  automation, latency compensation, AU/CLAP hosting, punch, count-in and multi-input recording are implemented
  and tested (audit finding A-23).
- **Release-app retest (later 2026-11-18).** A generated Logic project (three audio tracks, two audio files, duplicate channel-strip names including a track named `None`) imported through the built app's Open ▸ Import UI: the report appeared, the window showed the three tracks, the main thread returned to its run loop and the process stayed up. `scripts/make-test-project.sh` and a generated `.logicx` fixture supplied the material; nothing from the owner's projects was written or committed.
- **MODO BASS did not stall here.** `dalnok-cli render-project` instantiates MODO BASS 2 on a generated project in 3.2 s, and opening the same project in the built app left the main thread idle (sampled) with the project shown. The earlier multi-minute app-only stall therefore is not reproduced and is **not** fixed. Structure worth knowing: `dalnok_project_apply` calls `Engine::instantiatePlugins()` synchronously on the caller's thread, and `EngineBridge.importForeign` applies on the main actor, so plug-in initialization runs on the AppKit main thread — the arrangement that would turn a plug-in's main-queue wait into an app block. Changing that needs a designed, measured change (or the separate host process), not a quick move.
- **The owner's two reported projects were not available on this machine** (no paths in the repo, preferences or scratch space), so the full real-project import retest is still outstanding; it is the one remaining step for the crash report.
- **Logic import gaps are blocked on sample data.** Tempo and meter changes, automation, routing, stacks and native processors all need Logic-saved projects (or Logic renders) to decode; the importer's event layouts will not be guessed from public notes, because a wrong tempo map or routing guess would silently change timing. Next: a disposable Logic project with a tempo change, a meter change and a stack, saved from Logic, kept in the scratchpad.
- Owner's goal: Logic projects should sound the same in both DAWs, including plug-ins. Import, routing, automation and native processor parity need measured verification; this is not yet achieved.
- Logic import/device-panel crash: the debugger caught an AppKit assertion in the sidechain menu when tracks have duplicate names. `NSPopUpButton.addItems` silently de-duplicates titles; indexing the missing entries raises an Objective-C exception that unwinds through Swift and leaves its executor record stale. Constructing menu items directly preserves duplicate names and distinct track IDs. Generated self-tests pass in both themes, including a track named None. Full real-project retest is pending: an unrelated MODO BASS initialization blocked the main thread for several minutes, and desktop access then became unavailable.
- Both theme self-tests also pass with the generated CLAP sidechain fixture: a device is created with duplicate-name tracks and restores the chosen track by ID.
- UI retest: both reported projects imported and Guitar Rig devices opened in a diagnostic build with only MODO BASS omitted; its original state was retained. Without that omission, MODO BASS blocked the main thread while enumerating its pattern folders, including when loaded before the other plug-ins. The normal build has no exclusion. Headless import of the same project completed in about six seconds. The cause of the app-only stall is not yet established.
- The 44.1 kHz timing issue remains open. The display floors ticks after converting integer frames to beats; some self-test expectations also multiply rounded beat lengths, so diagnose those separately from quantization.
- A test that dispatched project application outside the importing Swift task did not fix the crash and was reverted. In-process plug-in hosting remains uncontained; crash isolation requires a separately designed and tested host process. Logic's import report now explicitly warns that tempo and meter changes are omitted; importing those changes remains work to do.
- Verification: `swift test --disable-sandbox` outside the sandbox: 188 tests pass; `scripts/ci/plugin-host.sh` and `scripts/ci/rt-effects.sh` pass. Both theme self-tests pass, with hosted plug-in UI checks skipped (test plug-in not configured).

## Latest session (0.1.0 follow-ups; 2026-11-18, later)
- Bypass is animated and configurable (explicit CA animations on the unit layer plus a veil; light levels driven by a 60 Hz fade in `DeviceView`). `PlateButton` keys track their own presses so they work while the unit is drawn shrunk.
- Self-test note: when the owner uses the Mac during a run, focus- and timing-sensitive checks can fail; the LCD check now waits for the next frame.
- **Gain ring lit on silent tracks: found.** oviii's `leaving-consolidatedMaster8.wav` carries a constant DC offset of 0.04 (−27 dBFS) through its silent parts; the meters read it as signal. Track and master meters now remove DC (`meterLevel`, render.hpp; engine test `metersIgnoreDcOffset`). The earlier hover fix stays.
- **Settings overhaul**: `Settings.swift` is a sidebar window with General, Appearance, Audio & MIDI, Recording, Plug-ins and Keyboard Shortcuts panes. The shortcut editor's content moved into the Shortcuts pane (`shortcutsEditor` now returns `settings.shortcuts`; its sheets attach to the Settings window).
- **Track heights**: per-track (engine `TrackState.height`, saved, undoable, C API 29) plus the default height (48–400 pt). All lane math goes through `Session.laneTop/laneHeight/laneIndex`. ⌥-scroll sizes all tracks (⌘-scroll still zooms time). Rows under 76 pt hide their knobs.
- Secondary clock, tape reels that stop transferring past the last clip, visible VU glass wear, header input label truncates before the pan knob.
- **Guitar Rig/device-panel crash:** the matching import crash was traced to duplicate track names in the sidechain menu and fixed; generated regression checks pass. Retest the original project in the fixed UI when desktop access is available. Out-of-process hosting is still needed to contain third-party plug-in crashes.
- **Open: "1 FX" with no plug-ins** (owner report). Every oviii track's count matched its plug-ins in testing; ask the owner for a project where it happens.

## Earlier session (0.1.0 release preparation; 2026-11-18)
- **Version 0.1.0** (first preview). `scripts/release.sh` builds and zips `dist/Dalnok-0.1.0.zip`; the GitHub release is a draft until the owner publishes it. The app is ad-hoc signed, not notarized (the README explains the first-launch Open).
- **EQ handles for any EQ**: `EqBands` (FaceplateDisplays.swift) finds bands by parameter name with fixed rules. Verified on TDR Nova (4 bands + HP/LP), AUNBandEQ (repeated names, Bypass inverted), AUParametricEQ, AUGraphicEQ (fixed-frequency sliders), MEqualizer, MAutoEqualizer, kHs Filter and Dalnok Channel EQ. Drag: frequency and gain (values set by bisecting the plug-in's own value text); scroll: Q; double-click: on/off. Presses on screens no longer drag the unit.
- **Crash fixes**: VST3 hosts now create IMessage/IAttributeList (iZotope Trash crashed on add; the CI test plug-in now refuses hosts that can't). Quit skips library teardown after shutdown (Guitar Rig 7 VST3 crashed in its Qt teardown). A headless sweep loaded 401 installed effects (194 VST3 + 207 AU) one per process: no other crashes; Melodyne (2.6 s, PACE licensing) and Analog Lab V (1.8 s) block the UI while loading, which is likely the "hang after double-click" the owner saw. Loading plug-ins asynchronously needs thought: many plug-ins require the main thread.
- **Nova "broke the plug-in area"**: not reproduced in snapshots (VST3 or AU). Found and fixed: the AU got a compressor meter (dynamic EQ), and drags on its screen moved the unit. Ask the owner what they saw if it recurs.
- **Faceplates**: wear slider (Settings ▸ Plug-ins; plate scratches, grime, glass dust and smudges, seeded per unit name); selected unit has a white outline glow; bypassed units scale to 95.5 % with all lights off (LED rings, switch lamps, readouts, meters, screens, VU lamps) and the metal unchanged.
- **Tempo**: drag the BPM readout (⇧ fine, one undo step), digits-only typing, lit edit box. Clicking outside an edited text field (track name, tempo) commits it (`CommittingWindow`).
- **Gain-knob ring lit on silent tracks** (owner, oviii): the offline render of the import is silent between clips, so the likely cause is a missed mouse-exit leaving the knob in its hover state (tracking only in the key window). The ring now re-checks the pointer every frame. Ask the owner to confirm.
- Verification: self-tests Graphite 497 / Warm Analog 481 pass (48 kHz); 186 engine tests; `scripts/ci/plugin-host.sh` passes (and fails with the old host).

## Earlier session (Channel EQ shelves and cuts; Graphite faceplates; 2026-11-18)
- **Channel EQ** now matches Logic for the shelves (−139 to −149 dB) and all cut slopes (6–48 dB/Oct). Steep slopes below Q 1 use cascades measured at every shown Q (199 renders, `tools/logic-parity/cut_table.py` generates `engine/src/fx/channel_eq_cuts.inc`). The low and high cuts had been swapped. Still to do: master gain and HQ (oversampling).
- **Graphite device panel**: each plug-in is drawn on a brushed graphite faceplate (`app/macos/Dalnok/Faceplate.swift`). Parameters get knobs with printed scales, stepped selectors or lit push switches. Related parameters share engraved sections, and IN/OUT LED meters can be turned off in Settings ▸ Plug-ins. The owner asked for "more realistic, more than just knobs".
- **Faceplate displays** (`FaceplateDisplays.swift`), chosen by plug-in category:
  - Dynamics: a backlit moving-coil gain-reduction meter with spring ballistics. It reads the plug-in's own reported reduction, or else the level change measured through it.
  - EQs and filters: a response screen. Dalnok's EQs draw their exact curve (`dalnok_plugin_response`) with numbered band markers; hosted EQs get a curve measured from the signal, marked MEASURED. Both draw over a live spectrum.
  - Everything else: a phosphor oscilloscope.
  - The engine adds a lock-free per-plug-in display tap (`dalnok_plugin_tap`).
- **Sorting audit** (`--plugin-report`, with the sandboxed scan in a temporary cache): 454 installed plug-ins.
  - 451 declare categories once scanned.
  - Effects in "Other Effects" fell from 140 to 47. The rest have bare product names, and their parameters decide the display when they load.
  - Instruments have no IN meter, and the oscilloscope scales itself to the signal.
- **Self-tests at 48 kHz**: 484 in Graphite and 477 in Warm Analog, with no failures. The 44.1 kHz beat/frame rounding issue (below) is still open; it only shows when the output device runs at 44.1 kHz.
- Displays by category:
  - Dynamics: VU gain reduction.
  - EQ and filters: response.
  - Distortion: transfer curve.
  - Reverb and delay: energy history.
  - Modulation and stereo: goniometer.
  - Pitch, restoration and analysis: LED analyzer.
  - Utility: VU output.
  - Everything else: oscilloscope.

  Checked visually with Apple's AUs and a VST3 flanger (`p1`–`p3` test projects in the scratchpad; nothing committed). The VU design follows the VU standard: a −20…+3 scale, 0 VU at 71 %, about 300 ms to settle and about 1.5 % overshoot.
- Faceplate hardware details (owner feedback): etched unit names (`EtchedLabel`), machined keys for CONTROLS, EDITOR and power (`PlateButton`), and LED-ladder meters with peak hold and a printed scale.
- Self-tests at 44.1 kHz: six timing checks (16th quantize, step entry, the LCD at beat boundaries) fail with and without these changes. Every check passes at 48 kHz. This looks like a real beat/frame rounding bug at 44.1 kHz (the LCD reads 2.1.4.239 at bar 2), so investigate it next.
- Engine: per-plug-in input and output peak meters (`dalnok_meter_plugin`) and value text for any parameter value (`dalnok_plugin_parameter_text`), implemented for VST3, CLAP, AU and built-ins. C API version 28.
- Verification: 186 engine tests pass. Self-tests at 48 kHz: 470 Graphite and 477 Warm Analog, all passing; the display checks were added afterwards and run at 44.1 kHz (see above). The real-time analysis is clean, and `rt-effects.sh` now finds Homebrew's versioned `llvm@N`.
- Next:
  1. Faceplate polish with the owner: Channel EQ's default controller, a bespoke layout for built-ins (an EQ curve display), and gain-reduction meters for dynamics plug-ins.
  2. Channel EQ master gain and HQ (Logic time needed), then Limiter, Chorus, ChromaVerb, ChromaGlow and Drum Kit.

## Latest session (Dalnok Channel EQ; 2026-11-18)
- Owner decisions: disassembling Logic is allowed (no verbatim copying), Apple samples may be used with a fallback, and the bar is exact or indistinguishable. See [[Logic Effect Parity]] (Working rules).
- Q-Couple law read from MADSP; with it, every Channel EQ peak-band render nulls at −132 to −148 dB (75 variants).
- ADR-0011 built-in plug-ins: `dalnok:channel-eq` in `engine/src/fx/`. The importer converts Logic Channel EQ records with the GAMETSPP block. Records with a knob-position table before the block (the 12 KB layout) convert too; both oviii instances convert.
- Verification: 181 engine tests; the real-time effect analysis is clean (script fixed). GUI self-tests: 459 Graphite / 476 Warm Analog pass. "REWIND turns the reels backwards" fails, including on the unchanged baseline: it is environmental, and the screen was locked overnight.
- Next:
  1. With the screen unlocked, run `tools/logic-parity` batches for the shelves, the cuts (slope codes, then fit cascades), HQ and master gain, and the 12 KB Channel EQ layout.
  2. Then Limiter, Chorus, ChromaVerb, ChromaGlow and Drum Kit (Apple samples with a fallback).
  3. `batch.sh` now refuses to run while the screen is locked. An earlier run typed at the lock screen; that must not happen again.

## Latest session (Logic effect parity research; 2026-11-17)
- Guitar Rig works after activation in Native Access (NTKDaemon must be running). All 7 oviii Audio Units load with their saved state.
- Clean-room measurement loop: `tools/logic-parity/`. It patches a Logic project made in Logic, exports all tracks, and fits the results. Logic renders are deterministic.
- Channel EQ parametric band with Q-Couple off is reproduced exactly: the model nulls against Logic at −132 to −148 dB over 30 variants. The Q-Couple modes and measured curves are recorded in [[Logic Effect Parity]]. Next: the Q-Couple closed form, shelves and cuts, then a Dalnok Channel EQ in the engine.
- Measurement renders and Logic projects stay in the session scratchpad. Never commit them; they derive from the owner's project.

## Latest session (Logic mixer, region mute, Drummer notes; 2026-11-17)
- Logic import maps channel-strip volume, pan and track mute (AuCO records linked through Envi; ambiguous records are skipped and reported). MIDI region mute is imported as clip mute; clips can be muted in Dalnok (Clip ▸ Mute Clip, C API 27, format 12). Drummer regions now import their notes as editable MIDI; Logic's Drum Kit is not hostable, so they need a replacement instrument.
- Audio Units restore with ClassInfoFromDocument first. Audio Unit creation/teardown is serialized (a parallel test run crashed in Apple's DLS synth during concurrent teardown).
- oviii: 17 tracks, 37 clips, 7 Audio Units. Guitar Rig 7 rejects even its own freshly read state with kAudioUnitErr_Unauthorized: no Guitar Rig licence is registered in Native Access on this Mac, so that needs activation, not a Dalnok change. Still not identical: 13 Logic-native processors (Channel EQ, Chorus, ChromaGlow, ChromaVerb, Drum Kit, Limiter), sends/buses/stacks, automation.
- Guitar Rig: after activation in Native Access, all 7 oviii Audio Units (including 3 Guitar Rig) load with their saved state. Logic-native effect parity research: [[Logic Effect Parity]]. Logic's effects are private (MADSP.framework), so they need clean-room rebuilds measured against Logic renders. The next step is a Logic-made measurement template.
- Verification: 176 engine tests (5 parallel runs), 17 hosting tests, self-tests 458 Graphite / 475 Warm Analog.

## Latest session (Logic MIDI and Audio Units; 2026-11-17)
- Logic MIDI import now uses MSeq region lengths and the note-sequence origin observed in Logic's arrangement. Notes outside or crossing a region are reported; compare unfamiliar Logic versions carefully.
- Recognized Audio Units are assigned to their channel strips with saved class-info state. Missing or state-rejecting plug-ins retain their original state and are reported in the import sheet and device panel. Logic-native processors are reported as unsupported; they are not replaced with equivalent sound. Mixer levels, pan, routing, automation, Drummer and take folders remain incomplete, so an imported project is not necessarily identical.
- Plug-in playback now handles notes that start and end in one audio block. A missing or bypassed instrument no longer silently plays Dalnok Poly. Generated Logic and Audio Unit fixtures cover state, channel mapping, MIDI positions and rendering; hosting fixtures cover state rejection and short notes. Verification: 171 engine tests, 17 generated plug-in hosting tests, and GUI self-tests with 455 Graphite / 472 Warm Analog checks.

## Latest session (Phase 4 verification; 2026-11-17)
- Fixed Touch/Latch automation after a backward transport jump: committing the previous pass keeps the live control override active for the next pass. The Warm Analog self-test passed 471 checks, including generated-audio checks for both modes (0.5 output within 0.001).
- CLAP sidechain processing is verified with a generated ducking plug-in: silent and active key signals, a muted pre-fader source, and disconnection (1e-4 tolerance). `scripts/ci/plugin-host.sh` passed 14 tests. An Audio Unit sidechain fixture is still needed; the built-in dynamics units probed here did not expose one through the host.
- Phase 4 still needs Audio Unit sidechain verification and folder groups; other overhaul and hardware-dependent items are tracked below and in the audit.

## Latest session (tape keyboard access; 2026-11-17)
- Focused tape keys receive Space and Return instead of the global transport shortcut; wind keys run only while held and stop if focus leaves. Warm Analog self-test passed 468 checks, including the shortcut handoff and wind press/release. Real Space and Return input toggled the focused LOOP key after accessibility focus was set; Tab navigation to the key was not established and remains part of the keyboard-only pass.

## Latest session (Logic import and tape strip; 2026-11-17)
- Logic import handles continuation records, split-region pieces and MIDI notes; Drummer regions are reported as skipped. The owner's oviii project imports; 60 MIDI notes matched Logic's MIDI export. Audio placement has not been compared with a Logic export, and MIDI region lengths are rounded up from the last note to whole bars.
- Markers, duplicate and hidden tracks, track height and vertical zoom, and zoom to selection are implemented. Duplicate Track uses ⌃⇧D, verified with real keyboard input on a generated project.
- Warm Analog's control bar has the tape reels and seven transport keys; the bar and Tape Machine share winding and stop behavior. Engine tests passed (164); Warm Analog self-test passed 463 checks after fixing mixer accessibility names. The earlier Graphite self-test passed 447 checks. Real-input checks on a generated project confirmed PLAY, FF and RTZ; window captures show playback, winding and return to bar 1.
- Open: track groups, tape coloration, out-of-process hosting, a full VoiceOver and keyboard-only pass, and measuring on-screen Warm Analog cost. See [[Overhaul Audit 2026-11-17]].

## Latest session (overhaul parts 2–3; 2026-11-17)
- Done from the owner's brief: shortcut registry, presets and editor (ADR-0010); plug-in browser and chain reordering; clip clipboard; Tape Machine; dialog-safe shortcuts; dead-control scan. Status and the honest not-done list: [[Overhaul Audit 2026-11-17]].
- Verification: 158 engine tests, 12 hosting tests, self-test 424 (Graphite) / 435 (Warm Analog) checks, real keyboard and mouse input for every new interaction (see the audit). Format 10, C API 26.
- Real-input rules (AGENTS.md): confirm Dalnok is frontmost, use `DALNOK_RECOVERY_DIR`, restore preferences.
- Next: track height/hide/duplicate/groups, markers, VoiceOver and keyboard-only pass, Warm Analog open time, tape coloration (opt-in), out-of-process hosting.

## Earlier session (overhaul part 1; 2026-11-17)
- The owner's overhaul brief is tracked in [[Overhaul Audit 2026-11-17]]. Done: track-header scrolling (shared viewport), plug-in bypass (engine, C API 25, format 10), the Warm Analog pedalboard (seeded generated pedals, `Pedals.swift`), and tape-reel physics.
- Owner direction: test with real OS-level keyboard and mouse input when the screen is unlocked (`scripts/dev/drive.swift` + `DALNOK_WINDOW_DUMP`). This replaces the earlier ban. Header scrolling, footswitch bypass, ⌘S, ⌘Z, knob drag, and palette and popover dismissal (outside click, Escape) were all checked with real input.
- Verification: 154 engine tests; `scripts/ci/plugin-host.sh` (11, incl. bypass null test); GUI self-test passes in Graphite and Warm Analog.
- Next, per the audit: action registry with shortcut presets and an editor; plug-in browser taxonomy; full tape-deck view; a control-by-control audit.

## Latest session (visual audit; 2026-11-17)
- Reviewed both themes on generated projects; aligned mixer controls, improved device and track hierarchy, and refined analog lamp and cable motion. See [[Visual Audit 2026-11-17]] for findings and remaining work.
- Verification: 153 engine tests and both-theme GUI self-tests. Animation behavior is checked programmatically; timing has not been reviewed in motion. Site updates remain unpublished.

## Latest session (nested stacks; 2026-11-17)
- Nested summing stacks retain their descendants, support collapse through ancestors, and return members to the parent on ungroup or deletion. The mixer supports duplicate bus names.
- Verification: `swift test --disable-sandbox` (153 tests); GUI self-test in Graphite and Warm Analog. Site changes remain unpublished.
- Next: separate input/output devices, disk streaming, lamp and patch-cable motion, and an AU sidechain fixture.

## Latest session, part 4 (Phase 4 completion and Phase 5 start; theme critique)
- Master fader and mixer master strip (Warm Analog: ballistic VU needle), insert slots on strips; track stacks (summing, collapsible); plug-in parameter automation (block-rate); **clip launcher** (slots beside every track lane, bar-quantized launch, scenes; ⌘L).
- Theme critique by four reviewer agents: [[Theme Critique 2026-11-17]]. Done from it: Warm Analog lit-cap lamp buttons with lamp physics, channel modules (colour caps, printed dB scales, screws), VU needle, display lamp test, count-in countdown; Graphite header tint and quiet chips. Many ideas remain (material system, hero accent palette, tape reels, knob redesign, splice bay, pin piano roll).
- 145 engine tests, self-test passes in both themes, full check, TSan and RT-effects clean. Format 9, C API 20.
- Next: launcher recording and drag between timeline and slots; sidechains; CLAP hosting; automation write modes; disk streaming; remaining theme ideas.

## Latest session, part 3 (Phase 2 recording workflow, Phase 4 routing; 2026-11-17)
- **Warm Analog track names** are now lit scribble strips (recessed display, name in the track color, dark when muted), replacing the tape labels the owner disliked.
- **Cycle** (C, ruler band, ⌘U Set Cycle to Selection, cycle export), **punch in/out** (Autopunch, red ruler range, sample-accurate) and **count-in** (⇧K, one bar of clicks, take starts at the record point). Fixed: fresh engines had no metronome schedule; a seek pending at record start could break count-in takes.
- **Multi-input recording**: every armed audio track records its own device input into one spool; stop writes and verifies one mono WAV per track and places them as one undo step; recovery splits per channel. Not yet tried on the Scarlett's two inputs.
- **Crash recovery prompt** at launch from the session marker and newest autosave snapshot.
- **Routing**: bus tracks, outputs, pre/post sends, solo through routing, feedback rejected (C API 14, format 5). **Mixer** (X) with channel strips.
- Verified: 129 engine tests, self-test 277 checks in both themes, `scripts/check.sh` (now prints failing checks), TSan on routing/recording suites, RT-effects clean.
- **Automation** (volume, pan; A) and **plug-in delay compensation** (per connection, render-ahead live, export pre-roll; the test VST3s now really delay by the latency they report).
- **Take folders and comping**: cycle recording makes one take per pass; the Takes window (double-click a comp) swipes between takes; 256-frame equal-power crossfades.
- Next: track stacks, plug-in parameter automation, master strip and insert slots in the mixer, disk streaming. Known: a cycle wrap with compensation > 0 plays up to the compensation's length past the loop end before the jump.

## Latest session, part 2 (UI/UX review, both themes)
- Reviewed every main interaction in Graphite and Warm Analog with the new `--uiwalk` (real NSEvents through the windows, every window captured per step). Findings and fixes: [[UI Review 2026-11-17]]. Highlights: clips no longer draw over track headers when scrolled; Escape cancels rename; Warm Analog rename and tape fixed; AU editors no longer clipped; quitting then cancelling the save prompt no longer hangs the quit; palette ranking; snapped playhead clicks; device-panel Add tile; empty-state track buttons; piano-roll subtitle; Relaunch Now for themes.
- Self-test 243 checks in both themes; `scripts/check.sh` passes. OS-level input not exercised (screen locked); `scripts/dev/drive.swift` + `DALNOK_WINDOW_DUMP` are ready for that.

## Latest session, part 1 (tempo and meter maps; Phase 3 closed)
- **Tempo and meter maps** (C API 12, project format 4): stepped tempo changes at any beat and time-signature changes at bars. Any tempo edit remaps MIDI clips and notes through beats (old map → new map), so MIDI stays on its beats and audio keeps its time; split pieces keep sharing their note source. The metronome schedule (tempo and meter segments) lives in the RenderState; quantize follows the map. Constant-tempo projects are still written as version 3.
- **UI:** ruler, grid, snapping, LCD, piano-roll grid/ruler/snap and "New MIDI Clip" walk bars through the maps. The control bar shows and edits the tempo and meter in effect at the playhead. Transport ▸ Add/Remove Tempo Change and Time Signature Change at Playhead (⌥⇧⌘T adds a tempo change and focuses the field). Changes appear as flags on the ruler.
- **Marquee selection** in the arrangement (drag on empty space; Shift adds; a click without dragging still seeks).
- Verified: `scripts/check.sh` (113 engine tests incl. 8 TempoMaps tests, self-test 238 checks), TSan on Midi/Metronome/TempoMaps suites, RT effect analysis (Xcode clang; `CXX=$(xcrun -f clang++) scripts/ci/rt-effects.sh` when Homebrew LLVM is absent).
- Not done: tempo ramps, importing tempo maps (importers keep the first tempo), count-in (belongs with punch recording), sample-accurate MIDI input (needs output host time in the device callbacks and mid-block live voice starts), MiniLab recording by the owner.

## Earlier (arrangement multi-selection)
- Shift-click selects clips across tracks; left/right arrows nudge, horizontal drag moves, and Delete removes the selection. Each is undoable as a group. Generated engine tests and GUI self-test cover boundaries, keyboard routing and undo. Group drag is horizontal only; marquee selection is not implemented. C API version 11 adds atomic clip nudging and deletion.

## Earlier (tempo-map groundwork)
- Added an internal validated piecewise-constant beat/frame converter with negative-origin support and generated native tests; it is not yet connected to the model, playback, MIDI, recording or UI. Tempo and meter maps remain unimplemented. Piano-roll beat lines now follow the meter denominator; GUI self-test passes.
- Next: design and implement canonical beat-domain MIDI, project migration and tempo-map persistence, then update playback, metronome, quantize, recording and UI as one consistent feature. Keep audio time-locked.

## Earlier (MIDI group editing)
- Keyboard and drag movement clamp selected notes as a group at timeline and pitch limits; the GUI self-test verifies spacing and passes.

## Earlier (MIDI persistence validation)
- A generated corrupt shared MIDI source is rejected without changing the open project; offline rendering confirms the prior project survives.

## Earlier (Logic import validation)
- Duplicate primary region IDs now report ambiguity and unresolved placements; truncated known event records abort import. Generated fixtures verify both. Logic mixer and take-folder semantics remain incomplete.

## Earlier (self-test reliability)
- Hardened several GUI self-test array accesses and release timing checks; the self-test passed in Graphite and Warm Analog. The earlier intermittent index crash has no stack trace and is not confirmed resolved.

## Earlier (MIDI timing)
- Constant tempo changes keep MIDI clips and notes on their beats, while audio remains time-locked. Split MIDI notes continue across adjacent pieces and after save/reopen; offline-render tests and the full `scripts/check.sh` pass. Project format is now version 3; old projects load, but old splits do not retain shared-source identity.
- Tempo and meter maps remain unimplemented; Phase 3 is not complete. MIDI is still stored in frames and repeated tempo changes round to frames.

## Earlier (import reliability)
- REAPER imports retain constant tempo and meter; Ableton imports retain constant tempo. Logic sequence rows with different channel strips no longer merge. Generated import tests pass. Logic multi-sequence and take-folder semantics still need further validation.
- Full `scripts/check.sh` passed after the preceding MIDI and Logic changes. Phone Remote access was restored by moving the active remote connection to the shared daemon.

## Earlier (MIDI and Logic import)
- Piano roll supports drag marquee (Shift adds) and step entry (Option-arrows move the cursor, Return inserts); GUI self-test covers both. The metronome and ruler count eighth-note meters correctly.
- Logic import now preserves constant tempo and meter, supports supplementary Unicode filenames, and reports unplaced regions correctly when regions repeat. Generated LogicImport tests pass.
- Phase 3 is still in progress: tempo/meter maps and remaining MIDI features are not complete.

## Earlier (Logic import)
- Fixed region ID links and imported track names and order; generated LogicImport regression tests pass. Logic import remains experimental: volume, pan, stacks, routing, plug-ins, automation and take folders are missing.
- GUI self-test has intermittently failed two timing checks and once crashed at launch with an index out of range; investigate.

## Earlier (M14: Warm Analog overhaul)
- Owner asked for a total visual overhaul of the analog theme with the same design language: done as a first pass (`Analog.swift`, `06 - Design/Warm Analog.md`). Self-test passes in both themes (211 checks with the test plug-in). Reviewed in still snapshots only; the cable plug-in animation and LED breathing were not watched.

## Earlier (M13: Audio Units, device panel, zoomed window)
- Audio Units host like VST3 (Apple delay/synth tests). Device panel with per-plug-in controllers (owner request: Ableton-style). Window opens zoomed to the screen. 98 tests; self-test 210 checks with the test plug-in (both themes pass). Next (owner request): a full Warm Analog visual overhaul (LEDs, cables, hardware surfaces) with the same layout.

## Earlier (M12: plug-in editors and the generic parameter panel)
- Plug-in windows show the VST3's own editor (Vital's opened at 1440×907 pt inside Dalnok) and a searchable parameter panel for any plug-in (an owner priority). Parameters reach the processor live and in exports (test plug-in). Not automated: editing inside a real editor; automation lanes.

## Earlier (M11: VST3 hosting, ADR-0009 stage 3)
- VST3 instruments and insert effects run on tracks (in-process, as ADR-0009 decided), with state saved in the project, separate offline instances, and missing plug-ins bypassed with their state kept. Verified with a test VST3 (exact gain, bit-exact null test, sample-accurate notes, live MIDI, save/reopen, TSan) and with Vital rendering offline. Not yet: plug-in editor windows, parameters/automation, latency compensation, Audio Units and CLAP hosting, out-of-process hosting, load/unload during playback under sanitizers.

## Earlier (M10: plugin validation, ADR-0009 stage 2)
- `dalnok-scan` validates plugins out of process (timeout, parallel, cached); Audio ▸ Plug-ins… lists them. Fixture crash/hang/no-code plugins are contained (`scripts/ci/plugin-scan.sh`). Vital validates in all three formats. The owner's full library has not been scanned yet (Scan button in the app). Hosting (loading onto tracks) is next.

## Earlier (M9: piano roll, bars and beats, metronome, motion)
- Piano roll (P or double-click a MIDI clip), bars-and-beats ruler/grid/snap/LCD, tempo and meter in the control bar, metronome (K), and app-wide motion that respects Reduce Motion. `scripts/make-test-project.sh` generates test projects.
- Verified: 92 tests, GUI self-test 185 checks (both themes), RT effects and TSan clean. Animations are checked by state, not by eye.
- Fixed a launch bug where the tempo field stole keyboard focus and disabled Space, R and Delete.

## Previous session (M8: recording and MIDI integration)
- **Recording to tracks works** on one duplex device: R chip / ⌃R arms a track, the header's input button picks the channel, Transport ▸ Record (R) records, and the take is placed as one undo step, shifted by the device-reported latency. Takes go to the project's `Audio Files` (unsaved projects: Application Support/Dalnok/Recordings). A take begins when the transport rolls; pausing or seeking ends it as failed, and a failed take is never placed (its valid part is saved as `… (recovered).wav`).
- **Journals and crash recovery:** each take has a journal; File ▸ Recover Recordings… and `dalnok-cli recover-takes` convert unfinished takes without touching the capture file. `scripts/ci/record-crash.sh` kills real-time takes at three points; every recovered sample was exact. Power loss is untested.
- **Hardware:** Scarlett Solo 4th Gen at 44.1 kHz, `dalnok-cli record`: 10 s and 120 s takes, 0 dropped frames. Latency compensation uses the device's own figures (1,186 frames ≈ 27 ms round trip) and has **not** been checked with a loopback measurement. Input monitoring is opt-in and was not checked by ear.
- **MIDI:** instrument tracks (⌥⇧⌘N) with the built-in Dalnok Poly, MIDI clips with notes drawn in the clip, quantize, constant tempo and meter, Core MIDI input from all sources playing the armed instrument live, and MIDI recording. Timing is quantized to the audio callback. Tested with a Core MIDI virtual source and the GUI self-test; the MiniLab has not been played into a recording.
- **Phase 4 start:** read-only plugin discovery (VST3/CLAP bundles, registered Audio Units; no plugin code loaded) and [[ADR-0009 Plugin hosting]]. The owner expects most instruments to be plugins, so the stock instrument set stays minimal.
- **UI pass 2:** see [[UI Audit 2026-11-16 follow-up]] (Warm Analog track palette, theme tokens, Concept Guide wrapping, MIDI-clip menu states). VoiceOver and musician testing still not done; theme changes still apply on reopening.
- Site updates (parity, screenshots) are local; the previous session's site changes were also unpublished. Publishing is the owner's call (`scripts/publish-site.sh`).

## Latest verified build
- `main`, 2026-11-16. macOS 27.3, Xcode 27.2, Swift 6.4.2, Apple clang 21, M3 Max.
- `swift build` and release build: 0 warnings. `swift test --disable-sandbox`: 90 tests pass. `scripts/check.sh` passes (tests, capture/MIDI harnesses, record-crash, live smoke, GUI self-test).
- GUI self-test: 185 checks, both Graphite and Warm Analog. `swift test`: 92 tests.
- TSan: recording, MIDI, plugin, live-path and capture suites clean; hardware capture test under TSan passed with the Scarlett. RT effect analysis (`scripts/ci/rt-effects.sh` with Xcode clang) clean, including the negative check.
- Phase 1 exit review: [[Phase 1 Exit Review]]. UI audits: [[UI Audit 2026-11-16]], [[UI Audit 2026-11-16 follow-up]].
- **Public parity page:** https://droper23.github.io/dalnok-status/ (source in `site/`, published by `scripts/publish-site.sh`).

## Architecture (now)
C++20 engine (`engine/`) → C API (`dalnok.h`, v30) → AppKit UI (`app/macos/`). The **engine owns the
project model**: tracks, clips in z-order, and a media pool. Every edit is a named, undoable command with
compact scalar undo and whole-model snapshot undo for other edits, also reachable as JSON through the command catalog. The UI is a read-only view
that refreshes on `dalnok_model_revision`. Render snapshots reach the audio thread through an atomic
slot, and retired ones come back through an SPSC queue. See [[System Overview]],
[[Real-Time Processing]], [[ADR-0005 Project model and commands]], and [[Project Format]].

## Verified working
| Feature | Evidence |
|---|---|
| Native window: timeline, ruler, waveforms, playhead, track headers | `--snapshot` PNGs reviewed |
| Import WAV/AIFF/CAF/MP3/AAC/ALAC/FLAC, resampled to the engine rate | `loadResamplesToEngineRate` (pitch preserved at 44.1k → 48k) |
| Live playback on the default output device | CLI: transport within 1% of wall clock, 0 overloads |
| Play, pause, and seek with 5 ms de-click fades | Exercised manually and via CLI; no automated click test yet |
| Multiple tracks; gain (dB), pan (mono constant power, stereo balance), mute | Offline-render tests |
| Snapshot handoff under heavy editing during playback | 4,700 structural edits in 3 s, no crash, 0 overloads |
| Offline render and WAV export at 16, 24, and 32-bit | Round-trip tests within ½ LSB |
| Compile-time real-time safety on the callback path | Negative test: allocation fails the build (local and CI) |
| Engine-owned model; undo and redo of every edit; drag = one undo step | `UndoAndEditing` tests + self-test |
| Clip move (snapped; ⌃ bypasses), cross-track move, left and right edge trim | Self-test with synthesized drags |
| Split at playhead (⌘T), Delete, Undo/Redo with named menu titles | Self-test drives the real menu items |
| Overlapping clips: top wins; split renders seamlessly | Offline-render tests |
| Project save/open (JSON v1, atomic), relocation via relative paths, offline missing media, rejection of bad files, sample-rate rescaling | `Persistence` tests |
| New/Open/Save/Save As with unsaved-changes prompt; window title and edited dot | Self-test (prompt path: manual only) |
| Export Mix (⌘B, 24-bit WAV) | Self-test: export decodes to the session length |
| Command catalog (18 commands, JSON in and out), also from `dalnok-cli command` | `CommandCatalog` tests; CLI run |
| Click-free play, pause, seek, and gain changes on the live path | `LivePath` tests via `dalnok_engine_pump`; a mutation check proves they catch regressions |
| Command palette (⌘K): fuzzy search over every menu command with location and shortcut | Self-test |
| Output device selection (Audio ▸ Output Device), fallback when a device disappears | `Devices` tests + self-test (fallback: implemented, not automated) |
| Track and master peak meters with hold and clip indicator | `metersReportPostFaderPeaksAndReset` + self-test during playback |
| Background project open (prepare off-thread, apply on main) | `TwoPhaseLoad` test + self-test |
| Fades and crossfades (linear and equal power, drag handles, Clip menu) | `Fades` tests (numeric weights) + self-test |
| Solo (smoothed), track reorder (drag or menu), rename, delete, new | `TracksSoloOrder` tests + self-test |
| Relink missing audio (search a folder by name) | `relinkBringsOfflineClipsBack` + self-test |
| Copy audio into "Audio Files/" on save (identical files reused, clashes numbered) | `saveCopyingMediaMakesProjectSelfContained` + self-test |
| Single-key shortcuts don't steal typed text | Self-test (rename field + Space) |
| Engine scales linearly: 256 tracks = 3% of the real-time budget | `dalnok-cli bench` (see the exit review) |
| Import REAPER `.rpp` (tracks, items, fades, item gain, loops, Windows/moved paths) | `ReaperImport` tests; 6/6 of the owner's projects, all audio found |
| Import Ableton `.als` (arrangement audio, beats→time, warp markers, loops, clip gain, Live path types) | `AbletonImport` tests; 493/495 real sets parse; 95% of 6,929 file references resolved |
| Import Final Cut Pro XML (Logic's export) and stems folders | `FcpxmlImport`, `StemsImport` tests |
| Import Logic `.logicx`: EXPERIMENTAL (region links, placements, track names and order covered by generated tests) | `LogicImport` test; 30/31 real projects parse |
| Clip gain | `clip.setGain`, used by every importer |
| Time stretch, pitch, and varispeed (Signalsmith; rendered in the background; ⌥-drag a clip's end; Clip menu) | `TimeStretch` tests measure pitch and level on output; mutation-checked; self-test |
| Imports use stretch: REAPER playrate and pitch; Ableton warp markers (piecewise), Re-Pitch, transpose | `StretchImports` tests; a real set with 334 stretched clips imports in 1.7 s |
| Record to an armed track (one undo step, latency-shifted, saved and reopened) | `RecordingTests` (bit-exact) + self-test through menus |
| Take journal and process-kill recovery | `record-crash.sh` (every sample exact), `journalRecovery…` test, self-test |
| Hardware recording, Scarlett Solo 44.1 kHz | `dalnok-cli record`: 120 s, 0 dropped frames |
| Instrument tracks, MIDI clips, Dalnok Poly, quantize, tempo/meter | `MidiTests` (pitch ±0.5 Hz, onset, velocity, persistence) + self-test |
| Live MIDI input and MIDI recording | Core MIDI virtual-source test (TSan clean), self-test via running device |
| Plugin discovery (no code loaded) | `PluginDiscovery` tests; 217 bundles + 230 AUs on the dev Mac |
| Onboarding: "Coming from…", shortcut presets, project finder with preview, import report, Concept Guide, old-DAW words in ⌘K | Self-test |
| Plug-in editors: VST3/AU/CLAP windows plus the generic parameter panel | `PluginHostingTests`, `AudioUnitHostingTests`, `ClapHostingTests`; self-test (test plug-in) |
| Plug-in parameters, device-panel controls and parameter automation (block-rate), Touch/Latch | `PluginHostingTests`, `AutomationTests`, `BuiltinPluginTests` |
| Plug-in delay compensation (per connection, render-ahead live, export pre-roll) | `DelayCompensationTests` |
| Punch in/out, count-in, and several armed audio tracks each recording its own input | `PunchTests`, `CycleTests`, `MultiInputTests` |
| Audio Units and CLAP host like VST3 (state, missing plug-in keeps state, sidechain) | `AudioUnitHostingTests`, `AudioUnitDocumentTests`, `ClapHostingTests`; `scripts/ci/plugin-host.sh` |

## Not yet / incomplete
Every row in "Verified working" names the test, self-test or command behind it. This list is what has no such evidence yet.
- Out-of-process hosting is opt-in (Settings ▸ Plug-ins ▸ Safety); not the default until isolated plug-ins process in parallel (ADR-0014, audit A-01).
- Recovery snapshots do not isolate the app from plug-in crashes or hangs; power-loss durability has not been verified.
- Loopback latency measurement and power-loss validation.
- Separate input/output devices (built-in mic + speakers is refused with an explanation).
- Tempo ramps, importing tempo maps, sample-accurate MIDI input timing.
- Live theme switching (Relaunch Now is the stopgap).
- Disk streaming. Media is fully decoded into RAM, about 23 MB per stereo minute at 48 kHz.
- Input selection in the UI and handling sample-rate changes; the engine rate is fixed at launch.

## Known defects
- Seeking while playing fades out and in (correct), but there's no automated test for click-free behavior.
- Files with more than 2 channels keep only the first two.
- The unsaved-changes sheet (Save / Don't Save / Cancel) is exercised manually only. The self-test avoids modal sheets.
- Device-unplug fallback is polled every 0.5 s and untested with real hardware (no Scarlett connected during development).
- Peak meters only. No LUFS or RMS yet.

## Active objective
Work the audit's ordered plan (`docs/audits/modernization-roadmap.md`): autosave and plug-in crash containment first, then model/sync scaling, reliability, module shape, and media/DSP headroom. Recording integrity still outranks everything else.

## Next recommended action
1. Autosave and crash recovery, then the pre-plug-in-init snapshot and out-of-process plug-in hosting (audit A-02, A-01a, A-01).
2. Model scaling: linear compile, no whole-model copy per parameter edit, change-set refresh (A-04, A-03, A-05).
3. Reliability: fuzz/property tests, handoff health metrics, project schema and migrations (A-10, A-14, A-16).
4. Media and DSP: disk streaming, denormal guard, SIMD (A-09, A-12, A-13).

## Open migration items
- Expand Logic `.logicx` validation and decode mixer settings, routing, track stacks and take folders.
- Test the FCPXML importer on a real Logic export (only fixtures so far).

## Links
[[00 - Project Home]] · [[02 - Master Roadmap]] · [[Foundation Evaluation]] · [[Baseline 2026-11-16]] · [[2026-11-16]] · [[Project Format]]
