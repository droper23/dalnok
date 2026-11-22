# Changelog

## [Unreleased]

- **Two new themes, Prism and Atelier, each with a light and a dark version** (View ▸ Theme, Settings ▸ Appearance; Match System follows macOS). They change how everything is drawn, not what it does: every command, shortcut and control works the same in all four themes.
  - **Prism** is made of glass. A field of soft coloured light fills the window and every surface floats over it as a pane of glass that bends and catches the light at its rim (in the spirit of Apple's Liquid Glass, drawn by Dalnok so it looks the same everywhere). The control bar is three floating capsules; clips, strips, cards and notes are tinted glass that rises when selected; meters are light pipes; the playhead's prism head casts a small spectrum over the ruler.
  - **Atelier** is a codex: the studio drawn like an engraved plate from an old book of natural philosophy, still set in Source Serif 4 and IBM Plex. Everything is ruled and measured; shade is engraved in fine lines; sepia on parchment, or cream and gold on dark umber. Plug-ins are numbered plates ("02 · Compressor") and their displays are captioned figures drawn from the live signal: a Frequency Atlas for EQs (bands annotated), a surveying-instrument dial for dynamics, a vaulted Acoustic Chamber with sound rays for reverbs, a Chronograph of Echoes for delays, a Transfer Curve, the Stereo Field. Song sections are lettered A, B, C; the start page carries Fig. 1, a tuning fork and its sine.
  - Fonts (Sora, Geist Mono, IBM Plex Sans Condensed, IBM Plex Mono, Source Serif 4) are bundled under the SIL Open Font License.
- **View ▸ Composition Overview (⌥⌘O):** the project as a roadmap. Its sections come from your markers (or 8-bar ranges if there are none), with each track's part in every section and its volume automation; click a section, or use the arrow keys and Return, to show it in the arrangement. Esc returns. Works in every theme.
- **Dalnok Compressor**, a built-in compressor with a sidechain: threshold, ratio, soft knee, attack, release, make-up and auto gain, peak or RMS detection, a side-chain filter with Listen, and Mix, with a gain-reduction meter. Choose another track in the unit's sidechain menu to key it (ducking). Its sound is Dalnok's own; it has not yet been matched to Logic's Compressor.
- Prism plug-ins are all glass: each unit is a pane of liquid glass, and its screens, VU meter, values, knobs and level meters are drawn straight onto it (no boxes or wells). Knobs are just a coloured arc and a white dot on the glass.
- View ▸ Next Theme (⌥⌘A) steps through the themes; it was Warm Analog Style. Custom key bindings for it carry over.
- Fixed: after a plug-in's sidechain was disconnected, the plug-in kept reading the old key signal from memory that had been freed (all formats).
- Developer: `Dalnok <project> --gallery <dir>` captures every screen a theme has to get right (`DALNOK_THEME`, `DALNOK_VARIANT`).
- README: screenshots, tours and plug-in clips for all four themes in both versions. Developer: `scripts/dev/readme-media.sh` regenerates them; `--tour` with `DALNOK_TOUR_MODE=plugin-ops` plays the plug-in script (add, adjust, sidechain, bypass, fold, reorder, remove).
- Fixed: in a narrow window the transport could overlap the tools in the control bar (every theme).
- **Clip launcher:** record straight into a slot: on a record-enabled track every empty slot has a record mark; click it to record into that slot (the take keeps the whole bars it covers) and click again to stop. Dragging an arrangement clip onto a filled slot replaces it (⌘Z brings the old one back); each drag between the arrangement and the launcher is one undo step. A launch waiting for its bar shows a dashed outline, a launch sweeps light across its slot and new clips settle into their slots (all instant with Reduce Motion).
- **Latency is measured again every time the device starts.** An interface's round trip can change by a few samples from one start of its audio stream to the next (a Scarlett Solo reads 1136 or 1142 samples). After you measure once on a loopback input, every new stream measures itself inaudibly in its first moment, even while the project plays, and its takes use that. On a Scarlett Solo 4th Gen, six takes in a row landed on the exact sample. Audio ▸ Recording Input ▸ Re-measure on Every Device Start turns it off.
- **Keyboard and VoiceOver:** Tab now reaches every control in every window (with Keyboard navigation on in System Settings), in all themes; before, it reached almost nothing. Pop-up menus without names got them. The launcher grid works from the keyboard (arrows, Space or Return, Esc stops all), Edit ▸ Select Previous/Next Clip (⌥← / ⌥→) chooses clips without a mouse, and Tab moves on from a focused control even in the Ableton shortcut preset, where Tab shows the launcher.
- Developer: C API 45 (`dalnok_launcher_queued`, `dalnok_latency_auto_set`, `dalnok_latency_auto_result`); `DALNOK_A11Y_ONLY=1` runs only the self-test's accessibility audit; `DALNOK_SNAPSHOT_SCALE=2` captures galleries at Retina resolution and `DALNOK_GALLERY_CHAIN` chooses their plug-ins; theme performance in `08 - Testing and Benchmarks/Theme Performance 2026-11-22.md`.

## [0.3.0] - 2026-11-21

Phase 4 (professional production) is complete, and recording got its input and output right. Release standard: `08 - Testing and Benchmarks/Release Checklist.md`.

- **Recording no longer changes your output.** Recording from an interface while listening on another device (the Mac's speakers, headphones) used to switch the output to the interface for every take. Dalnok now pairs the input and the output itself (a private aggregate, clocked by the output, with the input drift-corrected), so you keep listening where you were. Any device with inputs can record.
- **Input Monitoring (I):** each audio track has an I button (Track ▸ Input Monitoring, ⌃I) to hear its input now, recording or not, through the track's plug-ins, fader, pan and routing. It's saved with the project. Audio ▸ Monitor Armed Tracks (was Input Monitoring) does the same for every record-enabled track; it used to add the input straight to the output.
- **The waveform draws while you record**, as the take comes in.
- **Measured latency compensation:** Audio ▸ Recording Input ▸ Measure Recording Latency plays short tones and listens for them on an input that hears the output (a cable, or the interface's loopback input). The correction is kept for that input and output pair and used for every take; Use Reported Latency goes back. On a Scarlett Solo 4th Gen the loopback measures 1136 samples at 48 kHz (the device reports 1200, including its converters), and a take recorded back through the loopback lands on exactly the sample it was played from. The interface's own round trip varies by 6 samples (0.13 ms) from one start of its audio stream to the next (1136 or 1142); while the input stays open, as it does with Input Monitoring on, takes line up exactly.
- **Track groups** (like Logic's Groups): track context menu ▸ Group. Members move together: volume and pan relatively, mute, solo, record enable and Input Monitoring the same, in one undo step. Each group chooses what it links. Track ▸ Suspend Groups (⌘G) is the clutch. Groups are saved; older versions open the project and ignore them.
- **Audio Unit sidechains verified:** a test Audio Unit with a sidechain bus ducks exactly as keyed by another track, in-process and with Safety on. TDR Nova and Guitar Rig 7 FX expose their sidechain inputs.
- Fixed: with plug-in delay compensation, cycle playback ran on past the cycle end by the compensation (300 frames with a 300-frame plug-in) and skipped as much of the start on every pass.
- Fixed: notes played live on an instrument track ignored its routing: a bus, its fader and sends were skipped (always while stopped, and while playing for Dalnok Poly without inserts). Live notes now go through the track's whole channel strip.
- Developer: `dalnok-cli latency <input> <channel> [--output <name|default>]`; `dalnok-cli record … --output <name|default>`; self-test `DALNOK_TEST_AUDIO_INPUT=<device>` (real-input checks); `DALNOK_TEST_LOOPBACK=<device>:<input>` (HardwareLoopback suite); `DALNOK_TEST_AU` (test Audio Unit). C API 44.

- Fixed: effects dropping out on big projects with Safety on. Isolated plug-ins shared a fixed 40 % of each audio block, so a heavy chain was skipped even when the block had time to spare: 150 of 1,972 blocks skipped an effect in a 512-effect test project. The budget now adapts to what the rest of the block needs. The same project plays with 0 skips and 0 overloads.
- Fixed: the interface lagging during playback on big projects. On a 128-track project with 128 isolated effects, main-thread stalls over 50 ms went from 52 to 0 in 20 s, and the slowest 1 % of passes from 50 ms to 16 ms.
  - The device panel redrew every control four times a second, even when nothing had changed.
  - Each isolated plug-in parameter read was its own round trip; now one round trip reads them all.
  - Track header meters and mixer strips that are scrolled out of view are no longer updated.
  - Crash-recovery snapshots reuse unchanged isolated plug-in states (260 ms → under 6 ms on 512 units).
- Animations always land on their final state, even while the display sleeps or the screen is locked.
- Count-In button in the control bar, beside the metronome, lit while on.
- New project screen, modelled on Logic, Studio One, Pro Tools, Cubase and Bitwig:
  - the project's tempo and time signature;
  - the audio output and input with the sample rate, and a link to Audio Settings;
  - Audio Track or Instrument Track to start;
  - recent projects, with Open, Import Audio and Bring in a project.
  - No shortcut lessons.
- First launch asks one question, "Which keyboard shortcuts do you know?" (Logic Pro, Ableton Live, Pro Tools, Cubase, Studio One, REAPER or Dalnok's own), applies that set and gets out of the way.
- Control bar buttons for the Clip Launcher, Automation, Mixer and Device Panel, lit while their view is open.
- Hints: the line under the project name says what the control under the pointer does, including each part of a clip and the two halves of the ruler (Settings ▸ Appearance ▸ Hints, on by default).
- Undo, Redo and Save are confirmed in a short notice that names the step ("Undo Move Clip ⌘Z"), and VoiceOver announces it.
- Motion (all off with Reduce Motion):
  - Keyboard and menu zoom, Zoom to Fit, Zoom to Selection and Go to Start glide, with the zoom anchor held still.
  - Page turns while playing glide.
  - New tracks' lanes glow for a moment, and muting cross-fades.
  - The clip launcher slides open, the command palette grows in, and switching themes cross-fades.
  - The count-in shows big beat numbers over the arrangement.
- Developer: `Dalnok <project> --perf <seconds>` plays a project silently on the real device and reports audio overloads, isolated misses and budget skips, and main-thread stalls.

- Faster mixing (A-13): each track's gain ramp, meter and output now use vector routines (Accelerate's vDSP on macOS).
  - A 64-track block takes 46 µs instead of 143 µs, and a 256-track block 180 µs instead of 567 µs (about 3x faster).
  - Offline export is 3.8x faster at 64 and at 256 tracks.
  - Output matches the previous scalar mix within 1e-7. Only the meters' DC tracking moved from per sample to per block.

- Internal (A-17): a theme is now a palette of colour tokens plus a set of look capabilities (pedalboard devices, console mixer, tape-deck transport, and so on). Views ask for the capability they draw instead of checking whether Warm Analog is on, so a third theme needs no view changes. Both themes render the same as before: 71 of 72 frames are identical or within run-to-run noise, and the remaining one differs only in playhead timing.

- Fixed: at 44.1 kHz the position display could read one tick early on bar and beat lines. For example, bar 2 showed as 2.1.4.239, because a beat at 96 BPM is 27,562.5 frames. Step-entered MIDI notes were also a frame short.
- Internal (A-18): the self-test is split into a harness and one file per area. It passes at both 44.1 and 48 kHz (`DALNOK_SAMPLE_RATE`). Checks that depend on the machine rather than on Dalnok report SKIP with the reason instead of failing. CI also runs the self-test.

- Fixed: two kinds of project could be written with a format version too old for what they contain. A sidechain alone was written as version 5 (sidechains need 9), and a master-fader change as version 3 (master gain needs 7). An older Dalnok would have opened such a file and played it without the sidechain or at the wrong master level.
- Internal (A-16): the project format has an explicit migration chain and a machine-readable schema (`engine/api/project-format.json`).
  - Tests save 150 random projects, reload them and save again: the files come out identical, and every key matches the schema.
  - A hand-written file for each of the 13 format versions loads.

- Internal (A-15): the clip and track structs of the C API are defined once, in `engine/api/views.def`. `scripts/gen-api.py` generates the C structs, the engine code that fills them and the app's Swift fields, and CI checks that the generated files are current.
  - Reading a track's clips takes one pass (C API 41, `dalnok_track_clips`): about 100x faster for a track with 1,638 clips.
  - The app no longer re-reads every track's info on each refresh.
- Internal (A-19): CI runs the release build, AddressSanitizer and ThreadSanitizer as parallel jobs. Before, ASan and TSan ran one after the other in a single job. `scripts/dev/compile-commands.sh` writes `compile_commands.json` for clangd.

## [0.2.1] - 2026-11-20

- Fixed: a dragged clip grew in proportion to its length, so a long clip swelled by 100 pt or more, swung far when it leaned and squashed hard when dropped. The lift, lean, squash and pop are now sized in points: every clip grows by the same few points (6.5 pt at the default Clip bounce).

## [0.2.0] - 2026-11-20

- **Safety is on by default:** third-party plug-ins run in their own processes, so a crash or hang in one is reported on its track instead of taking Dalnok down. Projects are unchanged. If you had turned Safety off, it stays off. Settings ▸ Plug-ins ▸ Safety is the off switch (ADR-0014). On 24 real projects:
  - Isolated plug-ins on different tracks now process in parallel. 7 projects that used to drop plug-ins in 29-97 % of blocks now drop none.
  - Opening a project never blocks the window for more than 13 ms. With plug-ins loading in-process, the worst single block is 0.3-1.7 s.
  - Loading is faster in 23 of 24 projects.
  - Fixed: each edit asked every isolated plug-in for its latency and waited for the answer, which caused 47-132 ms stalls while loading.
  - An isolated plug-in now processes 0.75 s of silence before it starts, so one-off start-up work some instruments do no longer drops blocks on the first play.
- Clips move with more life, in the spirit of FL Studio's playlist:
  - A dragged clip lifts off its lane (a little larger, with a shadow) and springs from grid step to grid step and lane to lane as you drag, leaning into the direction it travels.
  - Settings ▸ Appearance ▸ Clip bounce sets how lively all of this is, from Calm to Bouncy (default a little bouncier than the first tuning).
  - A dashed ghost shows where it will land on the grid. Dropped, it glides onto the ghost and settles with a small squash.
  - Pasted, duplicated or recorded clips pop in, and deleted ones shrink away.
  - All of it follows Reduce Motion.
- `dalnok-cli load-bench` now runs the main run loop between blocks, as the app does. Its in-process numbers were too optimistic: some plug-ins' main-thread work stalls playback, and the benchmark never let that work run.
- Plug-ins fold, like Ableton's devices, so a long chain fits the panel (fold chevron, unit menu, or click the strip to unfold; saved with the project and undoable; C API 40). Graphite folds a unit to a slim rack blank with its name, power key and output level column. Warm Analog stands the pedal on its side edge: seen from above, the box tips over (its face foreshortens and darkens while its side panel comes up beside it), the patch cables stay plugged into its sides throughout, and the folded edge keeps its LED, a working footswitch and jack sockets. On/off works while folded.
- More motion in the device chain: an added plug-in opens its place and settles in (Warm Analog: set down on the board with a small bounce, then its cables are plugged in); a removed one lifts off while the gap closes and the neighbours are re-patched. Units that didn't change are no longer rebuilt. All of it follows Reduce Motion.
- Each unit has one Open button for the plug-in's own window. That window's title bar has Controls, which shows Dalnok's view of every parameter (searchable, automatable). For an isolated plug-in, Open shows only its own window; before, Dalnok's parameter window opened beside it. Edit Controls… (which parameters the unit shows) is in the unit's menu.
- Warm Analog pedals show as much as a Graphite faceplate: a backlit readout window in the pedal's LED colour shows the control being turned (name and value), otherwise a gain-reduction LED ladder, the frequency response or the output trace with a one-line reading, and IN/OUT signal LEDs sit by the jacks.
- Fixed: switching between Graphite and Warm Analog squeezed the arrangement into a few hundred points (the rebuilt window zoomed to fit before it had a width). The zoom and scroll position now carry over.
- Safety (isolated plug-ins), verified on the owner's plug-in library and 24 real projects (first pass; see the default-on entry above). Fixed on the way, each with a test:
  - An isolated plug-in's editor could open on another Space and stay invisible.
  - Opening an Apple sampler's editor isolated crashed its host (a re-entrant resize), and its editor grew to 3,937 pt wide.
  - Loading a plug-in with a multi-megabyte saved state blocked the main thread for up to 1.2 s (macOS ignores MSG_DONTWAIT on the socket pair).
  - Projects opened marked Edited when a VST3, Audio Unit or CLAP plug-in reported values on its own after loading (only an open editor's changes count now).
  - A plug-in crashing during playback marked the project edited.
- New: `dalnok-cli load-bench <project> [--play S]` opens a project as the app does and reports load time, the worst main-thread block, failures, memory, block cost and isolated misses.

- Internal: the transport state (play, playhead, cycle, punch, metronome, count-in) is now its own type, `Transport`, outside the engine class. Recording state is likewise grouped as `RecordingState`. No behaviour change: all 225 engine tests pass and the real-time checks are clean.

- Faster redraw after edits:
  - Clip names are no longer re-typeset every time a lane redraws.
  - Faders only repaint when their value actually changes; before, every fader repainted on any edit.
  - On a 4,096-clip project, a one-track edit including drawing went from 12.4 to 10.1 ms, which fits in one 60 Hz frame. Snapshots are pixel-identical.
  - The UI audit now reports main-thread CPU time per tick, so the time spent waiting on the window server is separated out.

- Long audio clips played from the clip launcher no longer drop out. Previously only their first 1.4 s was guaranteed to be ready in memory; now Dalnok loads the audio ahead of where the playing clip is in its loop. In a test with a small cache, a 12 s clip looped for 26 s went from 13.8 s of silence to none.

- The streaming cache folder no longer grows without limit. It stays under 8 GiB (`DALNOK_STREAM_DISK_MB`) by deleting the least recently used files, and partial files left by a crash are removed. A file still in use keeps playing even after it's deleted.
- Fixed: `scripts/ci/plugin-recovery.sh` left one stuck test process running after every run (from the plug-in that hangs while loading).

- Tests: `DALNOK_REAL_INPUT=1` now drives this release's changes with real mouse and keyboard input in the self-test. It drags a clip, undoes and redoes with ⌘Z / ⇧⌘Z, plays a streamed 90 s file with Space, seeks with a ruler click and clicks Stop during slow isolated loading. It checks the screen is unlocked and Dalnok is in front first. The timeline redraw check now ignores the playhead overlay, which `draw` never paints, so it compares exactly (0 differing bytes).

- Editing a clip no longer repaints the whole arrangement and mixer: only the changed tracks redraw. On a 4,096-clip project, an edit including drawing went from about 54 ms to 22 ms. The UI timing audit now includes drawing time.
- Long audio files now play from disk instead of being held in memory (ADR-0016). Files over a minute are decoded once into a cache and played from a bounded memory cache. An hour of stereo audio used 1.39 GB of memory and now uses under 50 MB, with nothing dropped in testing. Reopening a project reuses the cache, so it opens instantly.
- Time-stretched clips now render identically every time. The stretcher used a random seed, so the last few milliseconds of a stretched clip could differ between renders.
- Internal: the engine's 3,000-line implementation is split by concern. Plug-in hosting (`PluginHostService`) and undo (`UndoStack`) are now their own classes, and the remaining code is in eight files of at most about 1,000 lines. No behaviour change.
- Undo history for structural edits is about 80 times smaller: steps keep only the clips they changed. On a 4,096-clip project, 500 clip moves used to add 269 MB of memory and now add about 3 MB. Edits and undo take about the same time (0.30 ms and 0.36 ms).
- Isolated plug-ins now share one time budget per audio callback, so several plug-ins stalling at once can no longer make the callback overrun. With three hung plug-ins the worst callback fell from 13.1 ms, longer than its 10.7 ms period, to 4.5 ms. Plug-ins skipped because others used the budget are not reported as unresponsive. Each plug-in process's audio thread also joins the output device's audio workgroup, so macOS schedules it with Dalnok's audio thread (C API 37).
- Isolated plug-ins now show their own editors (ADR-0015, C API 36). The editor opens in a floating window beside the plug-in window, owned by the plug-in's process. Dalnok stays the active app, the editor hides while you're in another app, and closing the plug-in window closes it. Dalnok's plug-in window keeps the parameter list, and its Editor tab brings the editor forward.
- With Safety on (Settings ▸ Plug-ins), a project's plug-ins now load in their own processes in the background, up to four at a time (ADR-0014 stage 2, C API 35): a plug-in that takes seconds to initialize no longer freezes the window, and Stop ends loading at once. In a self-test with three plug-ins that each sleep 4 s while initializing, the window never paused for more than 13 ms and Stop took effect in about 0.15 s. A plug-in that crashes while loading is now reported within milliseconds instead of after the load timeout.
- Crash isolation for plug-ins (experimental, Settings ▸ Plug-ins ▸ Safety; ADR-0014, C API 34): each third-party plug-in can run in its own `dalnok-plughost` process. A plug-in that crashes or stops responding is switched off and reported instead of taking Dalnok down, and Load restarts it. Audio stays sample-identical to in-process hosting; each isolated plug-in costs about 34 µs per block. Plug-in editor windows aren't available in this mode yet.
- The window now re-reads only the tracks an edit changed (per-track revisions, C API 33), and the mixer updates faders and buttons in place while they move. On a generated 4,096-clip project, refresh after a fader change fell from about 4 ms to 0.16 ms and after a one-clip edit from 24.6 ms to 0.56 ms.
- Fuzzing for every project and import parser (`scripts/ci/fuzz.sh`, libFuzzer + AddressSanitizer). Fixed what it found: a damaged `.dawproject` could make the ZIP reader allocate gigabytes, and a malformed escape or volume in an FCPXML file crashed the app. Parser errors can no longer escape the engine as exceptions. `scripts/check.sh` always runs the parser tests under AddressSanitizer.
- Opening or importing a project no longer waits for its plug-ins (ADR-0013, C API 32): the project appears at once, plug-ins load one at a time with “Loading plug-ins n of N” and a Stop button, and stopped or recovered plug-ins can be loaded later from the track menu (Load). Slow plug-ins are named afterwards.
- Incremental snapshot compilation (A-04): each track's clip-derived render content is shared between snapshots and rebuilt only when that track's clips change. Randomized edit/undo/redo sequences compare reused content with a fresh build (`dalnok_engine_snapshot_mismatches`, C API 31). On a generated 4,096-clip project, structural edit p50 0.238 → 0.163 ms and undo p50 0.257 → 0.173 ms.
- Project application now writes an atomic, uniquely named recovery snapshot before incoming plug-in activation. If the snapshot cannot be written the existing project stays open; recovery retains plug-in state without loading the plug-ins. Synchronous load reports a snapshot-write failure as an I/O error. Generated VST3 crash and hang fixtures compare the complete normalized incoming model and pass normally and with AddressSanitizer, as does the existing recovery smoke. Recovery markers preserve pending copies across repeated crashes and clean quits; the self-test covers selecting both older and newer copies. The final full sanitizer check passed with 197 tests in normal, ASan and TSan runs, live audio smoke and self-test. Plug-in hosting remains in-process.
- Mixer scalar edits use compact grouped undo, with snapshot promotion for mixed groups (ADR-0012). On a generated 4,096-clip project, 500 gain edits measured p50 0.058 ms → below 0.001 ms display precision and final RSS 302.6 MB → 34.5 MB. Randomized full-undo, mixed-group and failed-edit checks pass.
- Added parameter revision hints and handoff health counters (C API 30). Parameter-only reads avoid clip traversal. Matching 4,096-clip AppKit drag dispatch p50/p95/p99/max was 27.771875/30.493334/31.077125/31.706958 → 0.025000/0.031333/0.033625/0.037625 ms; parameter refresh was 28.385333/29.191209/29.532209/29.715750 → 3.865959/3.934792/3.967375/3.967375 ms. Graphite, mixer visible, 30 warmups and 100 samples; drag events were a tight burst and refresh includes synchronous callbacks, with deferred drawing excluded. Self-tests verify display-tick coalescing, unrelated-track edits with zero clip reads, and same-frame Touch; final generated-project UI walks in both themes cover gain drag, undo and scripted changes. The UI walk now waits for project load, and the reel self-test waits for forward animation to settle. An instrumented saturation test verifies queue depth, skipped adoptions and recovery after collection.

- Added an independent engineering audit on `audit/2026-11-codebase`: `docs/audits/codebase-audit-2026-11.md`
  (findings with evidence), `findings.json`, `modernization-roadmap.md`, reproducible benchmark data and an
  interactive dashboard. It measures the real-time path, model/edit/undo scaling and memory instead of
  estimating them, and adds two measurement-only `dalnok-cli` subcommands. No product behaviour changed.

- Audit follow-ups (branch `fix/audit-followups`): render-snapshot compilation is linear in clips (4,096-clip
  structural edits 0.77 -> 0.26 ms, clip-by-clip build 1.27 s -> 0.53 s), plug-in state is an immutable shared
  blob so model copies and undo snapshots no longer copy it, the live and offline render paths flush denormals
  to zero, and new property/mutation tests exercise the project parser. `CURRENT_STATE.md` was corrected: it
  listed already-tested features as missing. Autosave/recovery already existed; the audit misread its timer.

- Retested the import path in the built app with a generated Logic project (three tracks, duplicate channel-strip names including a track named None): the import completed through Open ▸ Import and the app stayed responsive. The owner's real projects were not available on this machine, so that retest remains outstanding.
- MODO BASS 2 loads in 3.2 s headlessly and did not stall the built app on a generated project; the earlier app-only stall is still unexplained and is not claimed as fixed. Plug-in initialization runs on the main thread during project apply, which is where such a block would come from.
- Fixed a device-panel crash when sidechain choices have duplicate track names, including a track named None. Sidechain choices retain their distinct track IDs.
- Added a hosted sidechain regression using the generated CLAP fixture.
- Both reported Guitar Rig cases were retested in a diagnostic build; a separate MODO BASS load stall remains under investigation.
- Logic import reports now state that tempo and meter changes are not imported.
- Investigating Logic project opening crashes and audio parity; no compatibility fix is claimed yet.
- Reproduced a Logic import crash through the published app UI; two other projects reached their import reports.
- Tested and rejected an import scheduling workaround after a repeated import crashed; no crash fix is claimed.

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
- README screenshots and animations (`assets/screenshots/`), captured from generated projects. `Dalnok <project> --tour <dir>` plays a scripted walk (playback, mixer shown and hidden, a bypass, a track switch; or, with `DALNOK_TOUR_MODE=plugins`, a looping cycle for the device panel) for README screen recordings (`assets/videos/`, with smooth GIFs from them). Snapshots, screenshots and tours never show the audio device's name.
- Settings is one window for every preference, in panes: General (the DAW you're coming from, project saving, automation mode), Appearance (theme, ruler, second clock, track height), Audio & MIDI (output, recording input, MIDI inputs), Recording (count-in, metronome, monitoring), Plug-ins (meters, wear, display choices) and Keyboard Shortcuts (the shortcut editor now lives here).
- Tracks can be sized one at a time (drag a header's bottom edge; double-click it for the default) or all at once (⌥-scroll over the tracks, View ▸ Taller/Shorter Tracks, or Settings). Heights are saved with the project (view only; C API 29 `dalnok_track_set_height`, command `track.setHeight`). Short tracks show their name and buttons without the knobs.
- View ▸ Secondary Clock (or Settings): a small second readout under the position display, real time when the main display shows bars and bars when it shows real time.
- Warm Analog's tape reels hold exactly as much tape as the project has sound; past the last clip they keep turning without transferring tape.
- The VU meter's glass now shows wear clearly (dark dust, greasy smudges and scratches over the light face) and its paper yellows with age.
- Bypassing a Graphite unit is now a gradual change: it sits back and dims slightly over half a second while its lights fade out (they warm up again when it's turned on). Settings ▸ Plug-ins sets how far it shrinks, how much it dims, how long the motion and the fade take, and whether the dot-matrix readouts fade too or switch off at once (the default, like a VFD).
- More Settings: IN/OUT meter peak hold, VU needle speed (standard 300 ms or fast), the selected-unit outline, whether gain knobs light with their track's level, and Restore Plug-in Defaults. Long Settings panes scroll.
### Fixed (2026-11-18, release preparation)
- Some VST3 plug-ins crashed Dalnok when added (seen with iZotope Trash): the host could not create the message and attribute-list objects plug-ins use to talk between their parts. Dalnok now provides them.
- Quitting with some plug-ins loaded crashed in the plug-ins' own teardown (seen with a Qt-based VST3); Dalnok now leaves without running library teardown once everything is saved and shut down.
- Dragging on an EQ screen moved the whole unit; presses on a screen no longer start a unit drag.
- Dynamic EQs (TDR Nova as an Audio Unit) got a compressor meter; many frequency-and-gain bands now mean an EQ screen.
- Clicking outside a track name (or the tempo) being edited keeps the typed text instead of leaving the field in edit mode.
- A track's gain-knob ring could stay lit with no signal when a mouse-exit was missed (the window lost focus or the rows scrolled under the pointer); the ring now checks the pointer each frame.
- Track and master meters (and the gain-knob rings that follow them) lit up on silent audio: some recordings carry a constant DC offset, which is inaudible but read as signal. The meters now track out DC (a one-pole tracker near 4 Hz); every audible frequency reads as before.
- A long instrument name on a track header ran over the pan knob; it now truncates before it.
- Turning a bypassed unit back on needed a pinpoint press: the shrunk unit's power key only registered presses near its centre. The key is larger and acts on any press that starts on it.

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
