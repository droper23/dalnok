# Changelog

## [Unreleased]
### Added (2026-11-16)
- Engine: C API, Core Audio output, lock-free snapshot handoff, transport with de-click fades,
  per-track gain, pan, and mute with smoothing, in-memory media decoding with sample-rate conversion,
  a min/max peak pyramid, offline rendering, and WAV export (16/24/32-bit).
- Compile-time real-time safety checks on the audio callback path.
- macOS app: timeline with ruler, waveforms, playhead, zoom and scroll, track headers, import via
  ⌘I or drag-and-drop, and keyboard transport.
- `atrium-cli` for live playback smoke tests (including a snapshot-churn stress mode) and WAV rendering.
- Engine test suite: 10 tests, 21 cases. CI on GitHub Actions.
