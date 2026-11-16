# Changelog

## [Unreleased]
### Added (2026-11-16, Migration M5)
- Project import: REAPER `.rpp`, Ableton Live `.als`, Final Cut Pro XML (Logic's export), folders of
  stems, and Logic `.logicx` (experimental). Each import comes with a migration report.
  File ▸ Import Project from Another DAW… (⇧⌘O). Open… and drag-and-drop also accept these.
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
