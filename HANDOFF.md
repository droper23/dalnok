# Handoff: Dalnok after M8 (recording and MIDI integration)

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
