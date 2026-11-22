# Backlog (ordered)

Overhaul follow-ups (2026-11-17, from [[Overhaul Audit 2026-11-17]]):
- VoiceOver pass and keyboard-only walkthrough of every window
- Warm Analog open time (5.5 s vs 2.6 s on the 64-track project): profile
- Opt-in tape coloration effect (separate from the Tape Machine view)
- Review plug-in categories on a scanned real library

0. Logic: verify placement with a real FCPXML export (needs the owner); track names; take folders
1. Warp/flex markers editable inside clips (reuses the stretch cache per segment); transient detection
2. Palette: rank recent and frequent commands higher
3. RealtimeSanitizer job (Homebrew LLVM, `-fsanitize=realtime`) running the engine tests
4. Loudness metering (LUFS, RMS)
5. Custom fader and knob controls; light and analog themes
6. Unsaved-changes sheet: automated coverage
7. Device-unplug fallback: test with real hardware (Scarlett)
