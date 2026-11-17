---
updated: 2026-11-17
---
# Keyboard Shortcuts

Design: [[ADR-0010 Command registry and shortcuts]]. Code: `Shortcuts.swift` (registry, key parsing, presets,
dispatch) and `ShortcutEditor.swift` (Dalnok ▸ Keyboard Shortcuts…, ⌥⌘K).

## Using the editor
- Browse by category, or search by name, description, keywords or key (`split`, `⌘T`, `cmd+shift+z`). The filter
  shows All, Conflicts Only, Changed by You, or one category.
- Double-click a command (or select it and press **Add Shortcut**) and press the new keys. Escape cancels.
  While recording, the key runs nothing.
- If the key is taken in the same context, choose **Use It Here** (removes it from the other command), **Keep Both**
  or **Cancel**. Keys macOS reserves (⌘Space, ⌘Tab, Mission Control …) are assigned with a warning.
- Click a shortcut token to remove it. **Restore Default** undoes one command; **Restore All Defaults** undoes all
  your changes to the preset (asks first).
- **Preset** switches layouts (asks first if you changed anything). **Save As…** keeps your set as a named preset;
  **Export…**/**Import…** move it between machines as JSON.

## Presets
All presets are approximations of commonly documented macOS defaults. None has been checked against the application.

| Preset | Notable keys | Not in Dalnok yet |
|---|---|---|
| Dalnok Default | Space play, R record, C cycle, K click, ⌘T split, X mixer, P piano roll | — |
| Logic Pro | ⌥⌘A audio track, ⌥⌘S instrument track, ⌘←/⌘→ zoom, ⇧⌘I import | Smart Controls, Library, Loop Browser, Flex View, region mute |
| Ableton Live | ⌘E split, ⌘T/⇧⌘T tracks, F9 record, ⌘L loop selection, Tab launcher, ⌘D duplicate, ⌘R rename | Key/MIDI Map, Consolidate, Insert Silence |
| REAPER | S split, R repeat, ⌘R record, ⌘T track, ⌘M mixer, Home/W start | Actions list, Item properties, Ripple editing |
| Pro Tools | ⌘E separate, ⌘D duplicate, ⇧⌘N track, ⌘= mixer, ⌘[ ⌘] zoom, ⌘Space/F12 record, ⇧⌘L loop | Tab to transient, zoom presets, edit modes, memory locations |
| Cubase | ⌥X split, keypad * record, keypad / cycle, keypad . start, F3 mixer, C click, ⌘D duplicate | Key Editor, tool keys, MixConsole 2/3 |
| Studio One | ⌥X split, keypad * record, keypad / loop, F3 console, C click, ⌘D duplicate | Browser, Add Tracks dialog, Scratch Pads |

## Contexts
- **Everywhere**: menu commands.
- **Arrangement**: clip nudge, track selection (↑/↓), cut/copy/paste/duplicate of clips.
- **Piano Roll**: note editing (Q quantize, ↑/↓ transpose, ⇧↑/⇧↓ octave, ←/→ nudge, ↩ step entry, ⌘A select all).
  The ⌥-arrow step cursor is fixed.

## Policy for every command
Every registered command can take any number of shortcuts, including none. The Help menu's copy of the Command
Palette is the same command. Commands without a default key are reachable from their menu, the Command
Palette (⌘K) and, where one exists, a context menu.
