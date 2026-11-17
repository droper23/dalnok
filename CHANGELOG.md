# Changelog

## [Unreleased]
### Added (2026-11-16, recovery snapshots)
- Periodic recovery snapshots while a project has unsaved changes, and File ▸ Recover Snapshot to open a copy as a new unsaved project. Snapshots are retained in Application Support/Dalnok/Recovery. Automatic timing and real crash recovery need validation.

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
