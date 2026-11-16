# Backlog (ordered)

0. Logic: verify placement with a real FCPXML export (needs the owner); track names; take folders
1. ADR-0008 recording architecture; input device selection; record-arm; monitoring
1b. Warp/flex markers editable inside clips (reuses the stretch cache per segment); transient detection
2. Crash-safe capture + recovery of partial takes; long-duration recording test
3. Disk streaming (needed for long recordings)
4. Autosave and crash recovery of the project
5. Multi-select and keyboard nudge
6. Palette: rank recent and frequent commands higher
7. RealtimeSanitizer job (Homebrew LLVM, `-fsanitize=realtime`) running the engine tests
8. Loudness metering (LUFS, RMS)
9. Custom fader and knob controls; light and analog themes
10. Unsaved-changes sheet: automated coverage
11. Device-unplug fallback: test with real hardware (Scarlett)
