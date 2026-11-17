# Handoff: Dalnok (latest: 2026-11-17, Phases 2–4 session)

## 2026-11-17, nested stacks (read first)
Nested stacks and duplicate-name mixer destinations are covered by engine and both-theme GUI self-tests. Site parity remains unpublished. Next: separate input/output devices, disk streaming, lamp physics and patch-cable motion, and an AU sidechain fixture. Owner prohibits OS-level input and tape-style track labels.

## 2026-11-17, later
Added: master fader + mixer master strip and insert slots; track stacks; plug-in parameter automation; the clip
launcher (Phase 5 start). Theme critique plan: `06 - Design/Theme Critique 2026-11-17.md` (top items done; the
rest is ranked there). Format 9, C API 20. Launcher state is live-only (not undoable, not saved as "playing").
Open: launcher recording and timeline↔slot drag, follow actions; sidechains; CLAP; automation write modes;
disk streaming; separate in/out devices; theme material system and palette.

## 2026-11-17 session
Phase 3 closed (tempo/meter maps). Phase 2 recording workflow: cycle, punch/count-in, multi-input takes, crash
recovery prompt. Phase 4: buses/outputs/sends + mixer (X), volume/pan automation (A), plug-in delay compensation,
cycle recording into take folders + swipe comping (Takes window). UI review tooling: `--uiwalk`,
`DALNOK_WINDOW_DUMP`, `scripts/dev/drive.swift`. Warm Analog track names are lit scribble strips (owner request).
- Verify with `scripts/check.sh` (prints failing self-test checks), `DALNOK_HOST_SANITIZE=thread scripts/ci/plugin-host.sh`,
  `CXX=$(xcrun -f clang++) scripts/ci/rt-effects.sh` if Homebrew LLVM is missing. Self-test: 292 checks (296 with the test VST3).
- Project format 7 (written only as high as a project needs: 3 constant tempo, 4 maps, 5 routing, 6 automation, 7 take folders).
- Test VST3 effects now really delay by the latency they report (gain 7, delay 300); keep that true.
- Not verified on hardware: multi-input on the Scarlett's two inputs, count-in by ear, comp crossfades by ear.
- Open next: track stacks; plug-in parameter automation and write modes; mixer master strip and insert slots;
  take lanes inside the arrangement; CLAP hosting; sidechains; disk streaming; separate input/output devices;
  cycle wrap with compensation > 0 overshoots by the compensation; live MIDI while stopped ignores routing.

# Earlier handoff: Dalnok after M8 (recording and MIDI integration)

Continue `/Users/derek/Projects/Code/DAW`. Read `AGENTS.md`, `CURRENT_STATE.md`, the architecture notes and the
ADRs (especially ADR-0008 recording and ADR-0009 plugin hosting) before engine work.

## Owner direction
- Finish Phases 2 and 3 and start Phase 4. Recording reliability first, then MIDI input, recording, playback and
  instruments. Most instruments and plugins will be external: keep the stock instrument set minimal (Dalnok Poly
  only) and put the effort into plugin hosting.
- Keep verification claims honest. Site changes are local until the owner publishes them.

## Current checkpoint
- **Recording** (`engine/src/record.cpp`): one armed audio track (input from the explicitly selected duplex device,
  or `DALNOK_SIMULATED_INPUT` in tests) and/or one armed instrument track. The audio thread defines the take as the
  blocks where the transport advanced continuously. Stop: capture stops, spool is converted to WAV by atomic link,
  the folder is fsynced, the WAV is read back and compared, then the clip is placed as one undo step "Record".
  Failures keep spool and journal and write `… (recovered).wav`; nothing is placed.
- **MIDI**: notes live on clips as shared immutable lists (frames, relative to the clip's source origin).
  `synth.hpp` is Dalnok Poly. Core MIDI ports publish their parser through an atomic slot (TSan-visible ordering).
  Live input and recorded events are block-stamped.
- **Plugins**: `plugins.cpp` + `platform/macos/audiounits_macos.cpp` read metadata only.
- **App**: `Recording.swift` holds record, inputs, monitoring, instrument tracks, MIDI clip and quantize commands,
  and recovery. Self-test section `recordingAndMidi()` drives them with the simulated input.

## Verification (this session)
- `swift test --disable-sandbox`: 90 tests. `scripts/check.sh`: pass (now includes `scripts/ci/record-crash.sh`).
- GUI self-test: 154 checks in Graphite and Warm Analog.
- TSan: recording/MIDI/plugin/capture suites clean. Hardware TSan:
  `DALNOK_TEST_DUPLEX='Scarlett Solo 4th Gen' swift test --disable-sandbox --sanitize=thread --filter hardwareCapturePreservesFramesAndRejectsDeviceChanges` passed.
- Scarlett: `dalnok-cli record "Scarlett Solo 4th Gen" 1 120 <folder>` → 5,292,032 frames, 0 dropped.
- Mutation checks: latency removal and a 2 Hz tuning error are both caught.
- Not run: ASan on the app self-test this session; full `DALNOK_SANITIZE=1 scripts/check.sh` (only the targeted
  TSan suites above).

## M9 additions (same day)
Piano roll (`PianoRoll.swift`), bars-and-beats ruler and snapping (`TimelineView`), tempo/meter controls and a
metronome (engine `renderClick`, C API `dalnok_metronome_set`), `Motion.swift` animations, and
`scripts/make-test-project.sh`. 92 tests; self-test 185 checks in both themes; RT effects and TSan clean.

## M10–M14 (same day, continued)
Plug-in validation (`dalnok-scan`), VST3 and Audio Unit hosting with editors, the generic parameter panel, the
device panel with per-plug-in controllers, a zoomed main window at launch, and the Warm Analog hardware overhaul.
`scripts/check.sh` runs everything (plugin scan containment and hosting included). Self-test: 211 checks with
`DALNOK_TEST_VST3` set, in both themes.

## Not verified / open
- Latency compensation uses device-reported latency only (no loopback). Monitoring not checked by ear.
- No power-loss test; kill-during-finalization was not targeted (the kill script hits journal creation and mid-take).
- MiniLab not played into a recording. MIDI timing is block-accurate.
- No tempo map, count-in, plugin loading, live theme switching. Animations not judged by eye.
- VoiceOver, keyboard-only and musician usability testing.
- "Copy audio on save" may have been forced on by older self-test runs; the owner should check that setting.

## Next steps
1. Loopback latency measurement on the Scarlett (needs an output-to-input cable) and an owner MiniLab recording.
2. Tempo map and count-in; piano roll marquee selection.
3. Audio Unit hosting through the same `PluginProcessor` interface (VST3 hosting, editors and the parameter panel are done: `vst3_host.cpp`, `PluginWindow.swift`, `scripts/ci/plugin-host.sh`). `Dalnok --plugin-snapshot <bundle> <png>` captures a plug-in's editor for visual checks (needs Screen Recording access for the capture).
4. Review `git log` for this session's commit; publish `site/` only when the owner agrees.
