# Handoff: Dalnok Phases 2 and 3

Continue `/Users/derek/Projects/Code/DAW`. Read `AGENTS.md`, `CURRENT_STATE.md`, the architecture and real-time notes, and accepted ADRs before engine work. The owner asked to finish Phases 2 and 3, add a multi-perspective UI audit, Settings, and a warm analog theme. Work is paused at the owner's request; neither phase is complete.

## Current checkpoint

- **Audio:** Experimental same-device mono capture is exposed through C API v9 and `dalnok-cli capture-test`. `engine/src/platform/macos/coreaudio_device.cpp` uses one AUHAL instance for input/output, requires matching device and engine sample rates, checks sample-clock continuity, and pushes into the bounded writer/spool. Errors and dropped frames are reported; the original spool remains recoverable via `dalnok-cli recover-capture`. Capture is **not** connected to track arm, monitoring, clip creation, latency compensation, a durable journal, or the app UI. Do not call it finished or crash-safe.
- **Scarlett:** Solo 4th Gen was detected at 44.1 kHz during this session. Both physical inputs produced independent signals. A 30-second headless capture before the final shutdown-race fix wrote 1,323,520 frames with zero reported drops. The opt-in hardware test passed after the race fix, clock checks, and transport-advance assertion. It uses a temporary recording and removes it.
- **MIDI:** C API/CLI source discovery finds the Arturia MiniLab mkII. A separate 15-second Core MIDI probe counted 9 note-on and 8 note-off events; no performance was saved. `engine/src/midi_parser.hpp` is a separately tested MIDI 1 channel-message parser; it is **not connected to a Core MIDI input port**, a MIDI model, transport, or playback.
- **UI:** `Dalnok ▸ Settings…` (⌘,) offers Graphite, Warm Analog, and the existing copy-audio preference. The theme takes effect after reopening; it is not a live switch. Both themes passed the GUI self-test and synthetic screenshot review. See `06 - Design/UI Audit 2026-11-16 follow-up.md` for the review and open accessibility/usability issues. VoiceOver was not tested. Some older self-test runs forced “Copy audio on save” on; the self-test now restores the previous preference, but the owner should check this setting because its earlier value is unknown.
- **Recovery:** Periodic project snapshots and manual restore exist; `scripts/ci/recovery-smoke.sh` verified a timer-triggered snapshot after killing an isolated process. Power-loss durability, startup prompting, and retention controls remain open.

## Verification and limits

- `swift test --disable-sandbox`: 74 tests reported passing, with the opt-in hardware test skipped in the ordinary run.
- `DALNOK_TEST_DUPLEX='Scarlett Solo 4th Gen' swift test --disable-sandbox --filter hardwareCapturePreservesFramesAndRejectsDeviceChanges`: passed, including same-device capture, no-overwrite, device-change rejection, recovered frame count, and silent transport advancement.
- `scripts/ci/capture-ring.sh` and `DALNOK_CAPTURE_TSAN=1 scripts/ci/capture-ring.sh`: passed after the immediate-stop writer race fix. `scripts/ci/midi-parser.sh` and its `DALNOK_MIDI_TSAN=1` variant passed. `scripts/ci/duplex-probe.sh` passed validation; its optional device-name argument runs a silent-output hardware probe.
- `CXX="$(xcrun --find clang++)" scripts/ci/rt-effects.sh`: passed, including the negative check. The default Homebrew LLVM path is absent locally.
- Graphite and Warm Analog `--selftest` runs passed; `--snapshot` verified the warm arrangement and exits cleanly. A release build passed with elevated permissions before the final small self-test-only changes.
- An additional full hardware integration ThreadSanitizer run was **interrupted at the owner's pause request** after its build; it did not report a test result. Run it on resume if useful: `DALNOK_TEST_DUPLEX='Scarlett Solo 4th Gen' swift test --disable-sandbox --sanitize=thread --filter hardwareCapturePreservesFramesAndRejectsDeviceChanges`.

## Next steps

1. Review and validate the experimental duplex path, especially failure propagation, device loss/rate changes, and the control-thread shutdown contract. Re-run the full hardware integration TSan test. Keep audio-thread code `DALNOK_NONBLOCKING` and allocation/lock/I/O free.
2. Design durable recording journal/finalization and recovery, then implement input selection, record-arm, monitoring, take placement as one undoable engine command, and measured latency alignment. Test real failures, long captures, crash recovery, and the full UI. Do not delete the spool or report success on incomplete capture.
3. Connect a Core MIDI input port to the tested parser with bounded high-priority-thread handoff and explicit overflow/device-loss behavior. Then build the MIDI model, recording/playback, piano roll, tempo/meter map, and instrument with meaningful tests.
4. Follow up the UI audit: live theme switching, complete panel/state contrast review, VoiceOver and keyboard testing, and real musician usability testing. Keep unproven parity steps honest.
5. Review `git status` and `git diff` before resuming. `site/parity.json` and synthetic screenshots were updated locally but **not published after this pause**. The repository rules call for updating the state, changelog, journal, parity page, and committing at a milestone; publish only `site/` using `scripts/publish-site.sh` when work resumes.
