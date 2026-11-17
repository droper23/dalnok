---
updated: 2026-11-16
phase: 2–4 in progress (recording, MIDI, plugin discovery) — Phase 1 complete
milestone: M11 VST3 hosting (ADR-0009 stage 3) done; editors, parameters and AU hosting next
---
# Current State

## Latest session (M12: plug-in editors and the generic parameter panel)
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
C++20 engine (`engine/`) → C API (`dalnok.h`, v10) → AppKit UI (`app/macos/`). The **engine owns the
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
| Import Logic `.logicx`: EXPERIMENTAL (metadata, files, region trims verified; placement unverified) | `LogicImport` test; 30/31 real projects parse |
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
- Tempo changes, count-in, piano roll marquee selection, sample-accurate MIDI input timing.
- Plug-in editors, parameters and automation, latency compensation, AU/CLAP hosting, out-of-process hosting.
- Automatic project-recovery prompting and retention controls; live theme switching.
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
4. Audio Unit hosting (the owner's Logic library), then automation lanes driving plug-in parameters, then latency compensation.

## Open migration items
- Verify Logic `.logicx` placement against a real Logic **Final Cut Pro XML export** of the same project
  (needs the owner to export one). Then decode track names and take folders.
- Test the FCPXML importer on a real Logic export (only fixtures so far).

## Links
[[00 - Project Home]] · [[02 - Master Roadmap]] · [[Foundation Evaluation]] · [[Baseline 2026-11-16]] · [[2026-11-16]] · [[Project Format]]
