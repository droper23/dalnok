# Changelog

## [Unreleased]

## [0.1.0] - 2026-11-18
First preview release (pre-alpha): recording and editing, MIDI, mixing, VST3/CLAP/AU hosting, project import from
Logic, Ableton, REAPER and Final Cut, the clip launcher, and the Graphite and Warm Analog appearances. The entries below
cover the development up to this release.

### Added (2026-11-18, release preparation)
- EQ screens show every band of any EQ as a handle, not only Dalnok's own. Bands are found by parameter name with fixed rules (frequency, with the gain, on/off and Q that belong to it; repeated names pair by position; graphic-EQ sliders are fixed-frequency bands). Drag a handle to move the band (frequency and gain), scroll over it for Q, double-click to switch it on or off. Values are set by reading the plug-in's own value text, so any mapping works.
- Settings ▸ Plug-ins ▸ "Wear on plug-in units": scratches, rubbed edges and grime on the metal, dust, smudges and hairline scratches on the displays' glass. Each unit's pattern is fixed by its name.
- The selected plug-in unit has a white outline glow (click any unit to select it).
- A bypassed Graphite unit sets back slightly and its lights go out (LED rings, switch lamps, readouts, meters, screens, the VU lamps) while the metal stays as it is.
- The tempo readout can be dragged up or down to change the tempo (⇧ for 0.1 BPM steps, one undo step per drag). Typing accepts only numbers, in a clearly lit edit box.
- `scripts/release.sh` packages `dist/Dalnok-<version>.zip`.
- README screenshots and animations (`assets/screenshots/`), captured from generated projects. `Dalnok <project> --tour <dir>` records a scripted walk (playback, mixer shown and hidden, a bypass, a track switch) as frames for the README GIFs. Snapshots, screenshots and tours never show the audio device's name.
- Settings is one window for every preference, in panes: General (the DAW you're coming from, project saving, automation mode), Appearance (theme, ruler, second clock, track height), Audio & MIDI (output, recording input, MIDI inputs), Recording (count-in, metronome, monitoring), Plug-ins (meters, wear, display choices) and Keyboard Shortcuts (the shortcut editor now lives here).
- Tracks can be sized one at a time (drag a header's bottom edge; double-click it for the default) or all at once (⌥-scroll over the tracks, View ▸ Taller/Shorter Tracks, or Settings). Heights are saved with the project (view only; C API 29 `dalnok_track_set_height`, command `track.setHeight`). Short tracks show their name and buttons without the knobs.
- View ▸ Secondary Clock (or Settings): a small second readout under the position display, real time when the main display shows bars and bars when it shows real time.
- Warm Analog's tape reels hold exactly as much tape as the project has sound; past the last clip they keep turning without transferring tape.
- The VU meter's glass now shows wear clearly (dark dust, greasy smudges and scratches over the light face) and its paper yellows with age.
### Fixed (2026-11-18, release preparation)
- Some VST3 plug-ins crashed Dalnok when added (seen with iZotope Trash): the host could not create the message and attribute-list objects plug-ins use to talk between their parts. Dalnok now provides them.
- Quitting with some plug-ins loaded crashed in the plug-ins' own teardown (seen with a Qt-based VST3); Dalnok now leaves without running library teardown once everything is saved and shut down.
- Dragging on an EQ screen moved the whole unit; presses on a screen no longer start a unit drag.
- Dynamic EQs (TDR Nova as an Audio Unit) got a compressor meter; many frequency-and-gain bands now mean an EQ screen.
- Clicking outside a track name (or the tempo) being edited keeps the typed text instead of leaving the field in edit mode.
- A track's gain-knob ring could stay lit with no signal when a mouse-exit was missed (the window lost focus or the rows scrolled under the pointer); the ring now checks the pointer each frame.
- Track and master meters (and the gain-knob rings that follow them) lit up on silent audio: some recordings carry a constant DC offset, which is inaudible but read as signal. The meters now track out DC (a one-pole tracker near 4 Hz); every audible frequency reads as before.
- A long instrument name on a track header ran over the pan knob; it now truncates before it.

### Added (2026-11-18, Graphite faceplates)
- Graphite draws each plug-in in the device panel as a hardware unit on a brushed graphite faceplate. Knobs carry printed scales with the plug-in's own end values. On/off parameters become lit push switches and short choices become stepped selectors. Related parameters share engraved sections, and every control has a value readout.
- Faceplate displays: a moving-coil gain-reduction meter for dynamics, a response screen for EQs (the exact curve with band markers for Dalnok's EQs; a measured curve for hosted ones; both over a live spectrum), and a phosphor oscilloscope for everything else. The engine adds `dalnok_plugin_tap` and `dalnok_plugin_response`.
- Value readouts are small dot-matrix screens: 5 × 7 characters glowing like a VFD, with the unlit dots faintly visible.
- Plug-in sorting works for any plug-in, using fixed rules only:
  - Loaded plug-ins report what they declare (`dalnok_plugin_categories`: VST3 subcategories, CLAP features, Audio Unit system tags), and the Audio Unit registry now carries tags too.
  - Declarations decide first. Broad tags ("Fx", "Tools", "Mastering", a VST3 "Stereo" layout tag) don't count as a category.
  - Then the name decides, split at case changes ("MAutoDynamicEq") and matched against a wider audio vocabulary.
  - Then the parameter names: for example, Threshold plus Ratio means dynamics.
  - The browser reads categories from the scan cache at launch.
  - Right-click a unit ▸ Display to choose its display; the choice is remembered per plug-in.
- `--plugin-report <out.tsv>` lists every installed plug-in with its declarations, category and display. `DALNOK_SNAPSHOT_DELAY` sets how long `--snapshot` waits.
- More faceplate displays, by category:
  - Distortion: a transfer-curve screen (output against input).
  - Reverb and delay: an energy-history screen.
  - Modulation and stereo: a goniometer with a correlation bar.
  - Pitch, restoration and analysis: a third-octave LED analyzer.
  - Utility: an output VU meter.
- Gain reduction now shows on a VU movement modelled on real meters (−20…+3 VU face, needle resting at 0 VU in GR mode, 300 ms ballistics, bridge, curved glass). Third-party plug-ins whose names carry a vendor prefix ("MFlanger") are categorized correctly. The engine adds `dalnok_plugin_tap_stereo`.
- Faceplate hardware details: the unit's name is laser-etched into the plate. CONTROLS and EDITOR are machined keys, and the power button is a glowing icon. The meters are recessed LED ladders with domed lenses, peak hold and a printed dB scale.
- Input/output LED meters on each unit. Settings ▸ Plug-ins can hide them. The engine adds `dalnok_meter_plugin` and `dalnok_plugin_parameter_text` (C API 28).
### Fixed (2026-11-18, Channel EQ parity)
- Dalnok Channel EQ's low and high cuts were swapped. Shelves and all cut slopes now match Logic (measured cascades for every shown Q below 1).
- `rt-effects.sh` finds Homebrew's versioned LLVM.
### Added (2026-11-18, Logic effect parity)
- Built-in plug-in format (`dalnok:`; ADR-0011) and **Dalnok Channel EQ**. Its peak bands and Gain-Q coupling match Logic's Channel EQ to float precision. Oversampling (HQ) is not modelled yet. Logic Channel EQ settings import directly (parameter ids equal Logic's slots). Project format 13.
- Logic import maps channel volume, pan and mute, imports MIDI region mute as clip mute (Clip ▸ Mute Clip), and imports Drummer regions' notes.
- `tools/logic-parity/`: clean-room measurement loop (patch a Logic project, export from Logic, fit and null).
### Fixed (2026-11-18)
- Audio Unit creation and teardown are serialized (Apple's DLS synth crashed on concurrent teardown).
- `scripts/ci/rt-effects.sh` was missing the CLAP include path.
### Changed (Logic import)
- Import MIDI region boundaries and note positions from Logic's sequence metadata, avoiding overlaps caused by estimated lengths. Notes beyond region boundaries are reported.
- Restore recognized Audio Units on their channel strips using their saved class-info state. Report unsupported Logic-native processors and plug-ins that cannot load; preserve rejected state.
- Fix same-block plug-in note-offs and prevent missing or bypassed instruments from silently substituting Dalnok Poly.
### Fixed and tested (2026-11-17, Phase 4)
- Touch and Latch automation retain the live control override across a backward transport jump or cycle wrap.
- Added generated CLAP sidechain coverage for an unconnected input, a muted pre-fader key, and disconnection.
### Fixed (2026-11-17, tape keyboard access)
- Focused tape keys receive Space and Return; keyboard wind keys run until release and stop if focus leaves.
### Added and fixed (2026-11-17, Logic import and tape strip)
- Logic import handles long continuation records, split-region pieces and MIDI notes; unsupported Drummer regions are reported. MIDI region lengths still derive from the last note, rounded to bars.
- Markers with navigation, duplicate and hidden tracks, track height, vertical zoom and zoom to selection. Only ⌘ shortcuts run while editing text.
- Warm Analog puts tape reels and transport keys in the control bar, sharing wind and stop behavior with the Tape Machine window.
- Mixer channel volume and pan controls now have track-specific accessibility names.
- Real-input checks confirmed the control-bar PLAY, FF and RTZ keys and the ⌃⇧D Duplicate Track shortcut on a generated project.
### Added (2026-11-17, overhaul parts 2–3)
- Keyboard shortcut registry and editor (⌥⌘K): every command with a stable id, category and context; any number of shortcuts; presets approximating Logic Pro, Ableton Live, REAPER, Pro Tools, Cubase and Studio One; conflicts, macOS-reserved keys, saved sets, JSON import/export (ADR-0010).
- Plug-in browser: categories, fuzzy search, format/vendor filters, favorites, recents, most used, collections, tags; double-click or drag onto a track or the device panel. Plug-in chain reordering (drag or Move Left/Right; C API 26).
- Clip Cut/Copy/Paste/Duplicate/Select All with an engine clipboard; Track ▸ Select Previous/Next Track; Bypass Plug-ins; View ▸ Warm Analog Style, Tape Machine (⇧⌘T), Enter Full Screen; Window ▸ Close Window.
- Tape Machine: a two-track recorder view of the same transport with physically modelled reels, wind keys, counter, VU meters and track lamps.
### Fixed (2026-11-17, overhaul parts 2–3)
- A plain K could toggle Count-In; Return didn't answer an open sheet; dragging a device failed while another window was key; the plug-in list said CLAP couldn't be added.
### Added (2026-11-17, overhaul part 1)
- Plug-in bypass: an undoable engine edit, saved with the project (format 10, C API 25, `plugin.setBypassed`). A bypassed effect nulls against the dry signal; a bypassed instrument is silent. Graphite shows a power button on each device.
- Warm Analog pedalboard: every plug-in is a stomp box generated from seeded parameters (finish, colour, knobs, artwork, lettering, LED, footswitch). Its size follows the number of controls, the footswitch is the real bypass, each control can be shown as a knob, small knob, selector, switch or slider, and the look can be re-rolled or overridden part by part.
### Fixed (2026-11-17, overhaul part 1)
- Scrolling over the track headers or the clip launcher now scrolls the tracks; knobs in a header no longer take the scroll. The vertical offset stays valid after tracks are removed or collapsed.
- Analog tape reels turn at a real deck's rate (ω = v/r on a spiral tape pack) instead of almost not at all.
### Changed (2026-11-17, visual audit)
- Refined both themes with aligned mixer controls, clearer track and device hierarchy, and readable muted labels. Warm Analog lamps now warm and cool and patch cables settle when connected; Reduce Motion remains supported.
### Added (2026-11-17, nested stacks)
- Nested track stacks with ancestor-aware collapse, summing and parent-preserving ungroup and deletion.
### Fixed (2026-11-17, mixer)
- Mixer output menus retain identically named buses and stacks.
### Added (2026-11-17, recording workflow and routing)
- Cycle playback, punch in/out (Autopunch), count-in, multi-track recording from several inputs, crash-recovery prompt at launch, bus tracks with outputs and pre/post-fader sends, and a mixer with channel strips (View ▸ Mixer, X).
### Changed (2026-11-17)
- Warm Analog track names are lit scribble strips instead of handwritten tape labels.

### Fixed (2026-11-17, UI review)
- Clips drew over track headers when zoomed or scrolled; Escape didn't cancel track renames; Warm Analog rename text was invisible and the tape label disappeared after renaming; Audio Unit editors were clipped; cancelling the save prompt while quitting left the quit pending; command-palette ranking favored scattered letter matches; the gain value bubble covered the track name.
### Changed (2026-11-17, UI review)
- Playhead clicks snap to the grid (⌃ for exact); keyboard zoom keeps the playhead in place; device panel gains an Add Plug-in tile, centred knobs and wrapped names; empty state offers new audio and instrument tracks; piano-roll subtitle shows snap and selection; MIDI clips are named after their track; welcome and Settings polish (Relaunch Now). Review tooling: `--uiwalk`, `DALNOK_WINDOW_DUMP`, `scripts/dev/drive.swift`.

### Added (2026-11-17, tempo and meter maps)
- Tempo changes and time-signature changes: Transport menu commands, ruler flags, and a control bar that shows and edits the values at the playhead. MIDI keeps its beats across changes; audio keeps its time. Metronome, quantize, ruler, grid, snapping, LCD and piano roll follow the maps. C API 12 (`dalnok_tempo_map_set` and conversions), command `project.setTempoMap`, project format 4 (only when a project has changes).
- Marquee selection of clips across tracks in the arrangement.

### Added (2026-11-16, arrangement multi-selection)
- Shift-click selects clips across tracks. Arrow keys nudge them together; horizontal group drag and Delete operate as one undo step. The command catalog and C API expose atomic group nudging and deletion.

### Changed (2026-11-16, tempo-map groundwork)
- Added an internal, tested beat/frame converter for piecewise-constant tempos. Tempo maps are not yet exposed or used by playback. Piano-roll beat lines now follow the meter denominator.

### Fixed (2026-11-16, MIDI group editing)
- Moving or transposing multiple notes now clamps the whole selection at timeline and pitch boundaries, preserving spacing instead of collapsing notes.

### Tested (2026-11-16, shared MIDI sources)
- Added a regression proving inconsistent shared MIDI sources are rejected without changing the open project.

### Fixed (2026-11-16, Logic import validation)
- Ambiguous duplicate region IDs are reported instead of assigning arbitrary audio; truncated known events fail import rather than being silently ignored.

### Changed (2026-11-16, self-test reliability)
- The GUI self-test reports missing tracks or controls instead of indexing absent elements, and its ring-release checks tolerate UI scheduling and clock rounding.

### Fixed (2026-11-16, MIDI tempo and split continuity)
- Changing constant tempo keeps MIDI clips and notes on their beats while audio remains time-locked. Notes crossing adjacent split MIDI clips continue without retriggering. Project format version 3 preserves shared MIDI source identity on save.

### Fixed (2026-11-16, import timing and tracks)
- Preserve REAPER tempo and meter and Ableton constant tempo when importing; distinguish Logic sequence rows that point to different channel strips.

### Added and fixed (2026-11-16, MIDI editing and Logic import)
- Piano roll supports marquee selection and keyboard step entry; eighth-note meters use the correct metronome beat and ruler numbering.
- Logic import preserves constant tempo and meter, reads supplementary Unicode filenames, and counts distinct unplaced regions when placements repeat.

### Fixed (2026-11-16, Logic import)
- Resolve audio placements by region ID and use arrange rows and channel names for track order and names. Logic import remains experimental; mixer settings, routing, plug-ins and automation are not imported.

### Changed (2026-11-16, knob rings)
- Gain dials put 0 dB at the top center (+6 dB at full, −∞ at zero); the dial face grows back in step with the falling level ring after stop, so there is no jump at the end.
- Clicking a knob or fader no longer takes keyboard focus, and a focused one passes Space and other shortcuts to the menu (the real Space key previously did nothing).
- When playback stops, every gain knob's level ring falls to empty over the same 0.8 s, each at its own rate, so they all go dark together (self-test checks the timing to 0.01 dB).

### Changed (2026-11-16, Warm Analog overhaul)
- Warm Analog is now a hardware-style interface with the same layout: LED-lens buttons, knurled metal knobs with LED-dot rings, segmented LED meters, a vacuum-fluorescent position display, grained faceplates with screws, masking-tape scribble strips for track names, and plug-ins as rack units joined by patch cables that plug in when added. See `06 - Design/Warm Analog.md`.
### Added (2026-11-16, Audio Units, device panel)
- Audio Unit hosting (effects and instruments, state, parameters, AUv2 Cocoa editors) through the same track slots as VST3; Audio ▸ Plug-ins adds AUs too.
- Device panel (View ▸ Device Panel, ⌥⌘D): the selected track's plug-ins as devices, each with a controller of knobs; Edit Controls chooses its parameters (saved in the project, one undo step). Knobs follow changes made in the plug-in's window.
### Changed
- The main window opens filling the screen's usable area (zoomed, not full-screen mode).
### Fixed
- At launch the empty state and the timeline could both show.
- `--snapshot` waits until a project has finished opening.
### Added (2026-11-16, plug-in editors and parameters)
- Plug-in windows (Open … in the track's Plug-ins menu or the header input menu): the plug-in's own editor, sized by the plug-in, and a generic, searchable parameter panel with sliders and the plug-in's value text for every VST3.
- Parameter changes from editors and the panel reach the audio thread through a bounded queue (applied at the next block) and are replayed into export instances; editor edits mark the project changed.
- C API: `dalnok_plugin_parameter_count/parameter/set_parameter`, `dalnok_plugin_has_editor/open_editor/close_editor`.
### Added (2026-11-16, VST3 hosting, ADR-0009 stage 3)
- VST3 plug-ins on tracks: instruments on instrument tracks (notes from clips and live MIDI, sample-accurate) and insert effects on any track, processed every block so tails continue. Add from Audio ▸ Plug-ins (Add to Selected Track); remove from the track's context menu. Adding and removing are undo steps.
- Plug-in state is saved in the project (base64) and restored on open; a missing plug-in keeps its state and is bypassed. Offline renders and exports use separate instances with the same state.
- C API `dalnok_plugin_add/remove`, `dalnok_track_plugin_info`, `dalnok_plugin_get_state/set_state`; catalog commands `plugin.add`, `plugin.remove`; `scripts/ci/plugin-host.sh` with a test VST3.
### Fixed
- Adding an insert to a mono track switched it to the stereo balance pan law, changing its level; mono sources keep their pan law.
- The scanner binary no longer links the test plug-in sources that live next to it.
### Added (2026-11-16, plugin validation, ADR-0009 stage 2)
- `dalnok-scan`: loads one VST3, CLAP or Audio Unit per process and reports what it declares; Dalnok runs it with a timeout, four at a time, and caches results until a bundle changes. Crashing, hanging and broken plugins are listed with their status instead of affecting Dalnok.
- Audio ▸ Plug-ins… (⌥⌘P): searchable list of installed plugins with type, vendor and scan status, and a Scan button. Loading plugins onto tracks is not available yet.
- `dalnok-cli plugins --validate`, C API `dalnok_plugins_validate`, `scripts/ci/plugin-scan.sh` (fake crashing/hanging plugins). VST3 interfaces 3.8.1 and CLAP 1.2.9 headers vendored (MIT).
### Added (2026-11-16, MIDI editing, tempo and motion, M9)
- Piano roll (Clip ▸ Piano Roll, P, or double-click a MIDI clip): add, move, resize, delete, transpose and nudge notes, a velocity lane, quantize the selection; each gesture is one undo step.
- Bars-and-beats ruler, grid, snapping and position display (View ▸ Bars and Beats Ruler, ⌥⌘B); tempo and meter in the control bar (⌥⌘T edits the tempo).
- Metronome (Transport ▸ Metronome, K; control-bar button) with accented downbeats; never in exports.
- Motion: chips light up with a glow and press in, knobs glide and show their ring when undo or scripts change them, the record button and armed chips pulse while recording, the metronome button ticks on the beat, the selection halo glides between clips, and rows, the palette, the empty state and status text fade. Everything is instant with Reduce Motion.
- `scripts/make-test-project.sh` and `dalnok-cli make-test-project`: deterministic generated projects (demo, band, midi, states, large) with optional screenshots in both themes.
### Fixed
- At launch the tempo field took keyboard focus, so Space, R and Delete counted as typing and did nothing.
- Long track names squeezed the R/M/S chips.
- Delete in the piano roll could have deleted the selected timeline clip; it now removes notes.
### Added (2026-11-16, recording and MIDI integration, M8)
- Recording to tracks: R chip and ⌃R record-arm, per-track input channel, Transport ▸ Record (R) and a record button. A take starts when the transport rolls and is placed on the armed track as one undo step ("Record"), shifted by the device-reported latency. Takes are saved in the project's `Audio Files` (or Application Support/Dalnok/Recordings for unsaved projects).
- Take journals and File ▸ Recover Recordings…: unfinished takes (after a crash) are converted to `<name> (recovered).wav` without touching the capture file. Interrupted takes (transport paused or moved) are never placed; their valid part is saved and reported.
- Audio ▸ Recording Input and opt-in Audio ▸ Input Monitoring (while recording).
- Instrument tracks (⌥⇧⌘N) with the built-in Dalnok Poly synth, MIDI clips (Clip ▸ New MIDI Clip), notes drawn in clips, Clip ▸ Quantize, and project tempo and meter.
- Core MIDI input from every connected source plays the armed instrument live (also while stopped) and is recorded into MIDI clips. Timing is quantized to the audio callback.
- Read-only plugin discovery (`dalnok-cli plugins`, `dalnok_plugins_scan`): VST3 and CLAP bundles and registered Audio Units, without loading plugin code. ADR-0009 plans hosting.
- C API v10; project format version 2. CLI: `record`, `simulate-record`, `recover-takes`, `midi-play`, `plugins`. `scripts/ci/record-crash.sh` kills real-time takes and verifies every recovered sample.
### Changed
- Warm Analog has its own amber-to-olive track palette; the selected-lane and position-display colors now follow the theme.
- The Concept Guide wraps long entries and lists recording, instrument tracks and quantize.
### Fixed
- Clip menu commands that only apply to audio are disabled for MIDI clips.
- UI self-tests restore every preference they change (copy audio, coming-from DAW, onboarding, recording input).
- Finished and recovered takes are ordinary readable files (0644) instead of owner-only.
### Added (2026-11-16, capture, MIDI, and appearance)
- Experimental same-device mono capture to a retained spool through the C API and `dalnok-cli capture-test`; no track UI, monitoring, clip placement, or latency compensation yet. Device sample rates must match. Scarlett hardware and recovery tests passed.
- MIDI source discovery and a separately tested MIDI 1 channel-message parser. Live MIDI recording, playback, and instruments are not implemented.
- Settings (⌘,) with copy-audio preference and Graphite / Warm Analog appearance. Reopen Dalnok to apply an appearance change.
### Fixed
- Capture writer shutdown could miss a final block; a repeated immediate-stop test covers the race.
- Graphite secondary text contrast and gain/pan caption size; snapshot automation exits cleanly. UI self-tests now restore the prior copy-audio preference.

### Added (2026-11-16, capture recovery)
- C API v7 and `dalnok-cli recover-capture` convert stopped mono/stereo capture spools into new float WAVs, preserving the original and reporting incomplete trailing bytes. Live recording is not yet connected.

### Fixed (2026-11-16, project saves)
- Atomic saves use unique temporary files and preserve an existing project file’s permissions.

### Added (2026-11-16, recovery snapshots)
- Periodic recovery snapshots while a project has unsaved changes, and File ▸ Recover Snapshot to open a copy as a new unsaved project. Snapshots are retained in Application Support/Dalnok/Recovery. The automatic timer and recovery after an isolated process kill are smoke-tested; power-loss behavior and automatic recovery prompting remain to be addressed.

### Added (2026-11-16, recovery foundation)
- C API v5 adds a project snapshot operation that preserves the saved/dirty state. Automatic snapshots and manual recovery now use this operation.

### Added (2026-11-16, capture writer foundation)
- Independently tested capture drain and exclusive temporary PCM spool, with failure reporting and read-only inspection of incomplete frames. These components are not yet integrated into recording.

### Added (2026-11-16, recording foundation)
- A bounded capture buffer with dropped-frame accounting, tested in isolation and under ThreadSanitizer. Recording is not yet connected.

### Changed (2026-11-16, Open projects)
- Open now selects Dalnok and other DAW projects, including Logic packages and stem folders. Foreign projects prompt to import or cancel; the separate import menu was removed.

### Fixed (2026-11-16, Logic import)
- Reject malformed Logic chunk and name lengths, avoid reporting unverified MIDI event counts, and clarify limitations of the Final Cut Pro XML alternative.

### Changed (2026-11-16, track controls)
- Track gain is now a labeled rotary knob, paired with a labeled pan knob. Its halo displays post-fader peak level during playback and the gain setting while adjusting.

### Changed (2026-11-16, UI pass 1, M7; see "06 - Design/UI Audit 2026-11-16")
- Track colors: a rainbow gradient from green (12 steps in OKLCH, equal brightness, alternating
  lightness for color-blind users). New tracks continue the gradient. Custom colors via Track ▸ Track
  Color or the header's context menu. Track ▸ Recolor Tracks as Gradient. Everything derives from the
  track color.
- Track headers: number, color strip, custom fader (audio taper, value bubble, ⌥-click reset, ⇧ fine,
  scroll, arrows), rotary pan knob, M/S chips (blue/yellow), vertical stereo meter, "+" to add a track.
- Clips: tinted body and title, contrast-aware text, quieter tags (speed, pitch, gain, rendering…),
  lighter waveform tint, hatching when muted or offline, crisper border and selection.
- Control bar moved into the title bar: project name and output status, centered transport and
  position display, output meter, palette and import buttons. The status sentence is gone.
- Ruler with a playhead cap, highlighted lane for the selected track, and an empty-state drop zone with actions.
### Added (2026-11-16, Time stretch M6)
- Clip time-stretch, pitch shift, and varispeed (Signalsmith Stretch, MIT), rendered off the audio thread.
  ⌥-drag a clip's right edge to stretch it. Clip menu: Double/Half Speed, Transpose Up/Down a Semitone,
  Preserve Pitch When Stretching, Reset Speed and Pitch. Clip titles show speed and pitch while rendering.
- Imports: REAPER playback rate and pitch, Ableton warp markers (one clip per warp segment), Re-Pitch, and
  transposition now play correctly.
- C API: `dalnok_clip_set_stretch`, `dalnok_engine_poll_jobs`, clip info rate/pitch/processing. Command `clip.setStretch`.
### Added (2026-11-16, Migration M5)
- Project import: REAPER `.rpp`, Ableton Live `.als`, Final Cut Pro XML (Logic's export), folders of
  stems, and Logic `.logicx` (experimental). Each import comes with a migration report.
  Open… and drag-and-drop accept these.
- Onboarding: "Where are you coming from?" sets shortcut presets (Logic, Ableton, or REAPER). The
  project finder searches your Mac and previews each import. Help ▸ Migration Assistant and Concept Guide.
- ⌘K understands other DAWs' words ("bounce", "region", "item", "collect all and save"…) and lists
  planned features with their status.
- Clip gain. `dalnok-cli import`. Media relocation for moved archives.
### Fixed
- Clips using offline media collapsed to 1 frame on load.
- Duplicate "Enter Full Screen" menu item; preset restore could give two items the same shortcut.
### Added (2026-11-16, Phase 1 M4, completing Phase 1)
- Clip fades and crossfades (linear and equal power): drag handles at the top corners, Clip menu (curve,
  remove, add short fades). Fades over a lower clip crossfade with it.
- Solo (smoothed on the live path). Track menu: New (⌥⌘N), Rename, Delete (⌘⌫), Move Up/Down (⌥⌘↑/↓),
  Mute (⌃M), Solo (⌃S). Drag track headers to reorder. Double-click a name to rename.
- File ▸ Relink Missing Audio… (search a folder by file name). Copy audio into `Audio Files/` on save
  (default on; identical files reused, name clashes numbered).
- `dalnok-cli bench`. Phase 1 exit review.
### Fixed
- Test-only use-after-free in the relink test (caught by ASan after a CI segfault). Added an ASan/TSan CI job.
- Unmodified shortcuts (Space, ↩, ⌫) captured keystrokes while typing in text fields. AppKit consumes
  matching key equivalents even for disabled items, so the main menu now passes them through while a field is edited.
### Added (2026-11-16, Phase 1 M3)
- Command palette (⌘K): fuzzy search over every menu command, showing its menu location and shortcut.
- Audio ▸ Output Device menu. Switching devices is safe: a failed switch keeps the previous device, and an unplugged device falls back to System Default.
- Track and master peak meters (instant attack, 24 dB/s fall, 1.5 s hold, clip indicator).
- Background project opening (`dalnok_project_prepare` / `dalnok_project_apply`).
- `dalnok_engine_pump` drives the live render path without a device. Click tests cover play, pause,
  seek, and gain changes, and a mutation check confirms they catch regressions.
- Public feature-parity page (https://droper23.github.io/dalnok-status/), published from `site/`.
  Screenshots come from the app's `--screenshots` mode.
### Fixed
- Top-level menus had the default title "NSMenuItem", which leaked into the palette's paths.
### Changed (2026-11-16)
- **Renamed from the placeholder "Atrium" to Dalnok.** C API prefix `dalnok_`, header `dalnok/dalnok.h`,
  targets `Dalnok`, `DalnokEngine`, and `dalnok-cli`, project extension `.dalnok` (format `dalnok-project`),
  bundle id `io.github.droper23.Dalnok`, and repo `droper23/dalnok`.
### Added (2026-11-16, Phase 1 M2)
- Engine-owned project model with a media pool, z-ordered clips, and whole-model snapshot undo/redo
  (500 steps) with named steps and groups.
- Clip move, trim, and split commands. Overlapping clips: top wins.
- Command catalog (18 commands) with JSON in and out (`dalnok_command_run`). `dalnok-cli commands|command|render-project`.
- Project files: versioned JSON, atomic save, relative-path relocation, offline media, sample-rate rescaling.
- macOS app: clip drag/trim with grid snapping (⌃ bypasses), selection, Delete, Split at Playhead (⌘T),
  Undo/Redo with step names, New/Open/Save/Save As with unsaved-changes prompt, Export Mix (⌘B).
- App `--selftest` mode (28 end-to-end checks). CI job enforcing real-time effect analysis with Homebrew LLVM.
### Changed
- C API v2: `dalnok_clip_add` takes a pool media id; model queries replace the UI mirror.
### Fixed
- Menu commands did nothing when the main window wasn't key. They now target the window controller.
- Track header rows no longer draw over the ruler area when scrolled.
### Added (2026-11-16)
- Engine: C API, Core Audio output, lock-free snapshot handoff, transport with de-click fades,
  per-track gain, pan, and mute with smoothing, in-memory media decoding with sample-rate conversion,
  a min/max peak pyramid, offline rendering, and WAV export (16/24/32-bit).
- Compile-time real-time safety checks on the audio callback path.
- macOS app: timeline with ruler, waveforms, playhead, zoom and scroll, track headers, import via
  ⌘I or drag-and-drop, and keyboard transport.
- `dalnok-cli` for live playback smoke tests (including a snapshot-churn stress mode) and WAV rendering.
- Engine test suite: 10 tests, 21 cases. CI on GitHub Actions.
