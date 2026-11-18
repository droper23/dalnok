---
updated: 2026-11-16
phase: Phases 1 and 3 complete; 2 and 4 in progress
milestone: M11 VST3 hosting (ADR-0009 stage 3) done; editors, parameters and AU hosting next
---
# Current State

## Latest session (Logic import and tape strip; 2026-11-17)
- Logic import handles continuation records, split-region pieces and MIDI notes; Drummer regions are reported as skipped. The owner's oviii project imports; 60 MIDI notes matched Logic's MIDI export. Audio placement has not been compared with a Logic export, and MIDI region lengths are rounded up from the last note to whole bars.
- Markers, duplicate and hidden tracks, track height and vertical zoom, and zoom to selection are implemented. Duplicate Track uses ⌃⇧D; its real-input shortcut check remains open.
- Warm Analog's control bar has the tape reels and seven transport keys; the bar and Tape Machine share winding and stop behavior. Engine tests passed (164); Warm Analog self-test passed 463 checks after fixing mixer accessibility names. The earlier Graphite self-test passed 447 checks. The saved real-input crops do not show the controls or playhead, so that check remains open.
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
C++20 engine (`engine/`) → C API (`dalnok.h`, v11) → AppKit UI (`app/macos/`). The **engine owns the
project model**: tracks, clips in z-order, and a media pool. Every edit is a named, undoable command with
whole-model snapshot undo, also reachable as JSON through the command catalog. The UI is a read-only view
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

## Not yet / incomplete
- Loopback latency measurement, power-loss validation, punch in/out, multiple armed audio tracks, separate input/output devices (built-in mic + speakers is refused with an explanation).
- Count-in, tempo ramps, importing tempo maps, sample-accurate MIDI input timing.
- Plug-in editors, parameters and automation, latency compensation, AU/CLAP hosting, out-of-process hosting.
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
Finish validating recording (loopback latency, power loss, real keyboard), then Phase 3 editing (piano roll, tempo map, metronome) and Phase 4 plugin hosting (sandboxed scan, then VST3). Recording integrity still outranks everything else.

## Next recommended action
1. With a cable from the Scarlett's output to input 1, add and run a loopback latency measurement (`dalnok-cli`), then decide whether reported latency is trustworthy.
2. Owner: play the MiniLab with `dalnok-cli midi-play <id> 20 --record`, and try recording in the app.
3. Piano roll marquee selection and keyboard note entry; tempo map; count-in.
4. Owner review of Warm Analog and the device panel; then automation lanes driving plug-in parameters, then latency compensation.

## Open migration items
- Expand Logic `.logicx` validation and decode mixer settings, routing, track stacks and take folders.
- Test the FCPXML importer on a real Logic export (only fixtures so far).

## Links
[[00 - Project Home]] · [[02 - Master Roadmap]] · [[Foundation Evaluation]] · [[Baseline 2026-11-16]] · [[2026-11-16]] · [[Project Format]]
