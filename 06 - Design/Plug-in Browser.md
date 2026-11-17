---
updated: 2026-11-17
---
# Plug-in Browser

Audio ▸ Plug-ins… (⌥⌘P). Code: `PluginManager.swift` (browser), `PluginTaxonomy.swift` (categories).

## Organisation
- **Sidebar.** Library (All, Favorites, Recently Used, Most Used), your Collections, then Instruments, Audio Effects
  and MIDI Effects with their categories (only non-empty ones, with counts), and Problems (failed validation).
- **Categories** come from what a plug-in declares: VST3 subcategories (`Fx|Dynamics`), CLAP features
  (`audio-effect`, `reverb`), Audio Unit type and subtype codes (`aufx:dely`). Words in its name are the fallback.
  Matching is by whole word, so "amp" doesn't match "sample". Channel-layout tags ("Stereo", "Mono") don't decide a
  category. Anything unmatched is "Other Effects" or "Other Instruments".
  - Instruments: Synthesizers, Samplers, Pianos, Keyboards, Drums, Bass, Orchestral, Other.
  - Audio Effects: EQ, Compression, Limiting, Gate / Expander, Distortion / Saturation, Reverb, Delay / Echo,
    Chorus / Flanger / Phaser, Modulation, Pitch / Time, Filtering, Stereo Imaging, Spatial Audio,
    Restoration / Noise Reduction, Utility / Gain, Metering / Analysis, Other.
  - MIDI Effects: Arpeggiators, Chord Tools, Sequencers, Transposition, Velocity, MIDI Utilities.
- **Search** is fuzzy: every word must match the name, vendor, category, declared features or your tags. Name
  matches rank first; letters in order also match ("audly" finds AUDelay).
- **Filters:** format (All, VST3, AU, CLAP), vendor, sort (name, category, vendor, most used); column headers sort too.

## Library data (per user, not per project)
Favorites (star column), recents (last 20 inserted), use counts, collections (right-click the sidebar for New/Delete,
or "Add to Collection"), and tags (comma-separated field). Stored in user defaults under `plugins.*`, keyed by the
plug-in's add path.

## Inserting and ordering
- Double-click, Return or **Insert on <track>** adds the plug-in to the selected track.
- Drag a plug-in onto a **track header** (adds it to that track) or into the **device panel** (inserts it at the
  drop position; a line shows where). Add plus move is one undo step.
- Reorder a chain by dragging a unit by its surface, or with the unit's context menu: Move Left / Move Right
  (also Bypass, Open, Edit Controls, Remove). Reordering is undoable (`plugin.move`, C API 26).

## States
Installed (scanned OK), Not scanned (categories from metadata only), Failed (crashed, timed out, or failed to
load in `dalnok-scan`). Failed plug-ins can't be inserted, and the reason is shown. Plug-ins missing when a
project opens stay in the project bypassed with their state kept ("Not loaded" on the device).
The same plug-in in several formats is listed once per format; the detail line names the other formats.
