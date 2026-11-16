# Changelog

## [Unreleased]
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
