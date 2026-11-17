---
status: accepted
date: 2026-11-17
---
# ADR-0010: Command registry and keyboard shortcuts

## Context
Before this ADR, shortcuts were scattered across menu key equivalents, a three-preset override table
(`Migration.keymap`), and `keyDown` handlers in the piano roll. Commands couldn't have more than one shortcut.
Keypad keys and shifted symbols didn't work as key equivalents. The same key couldn't mean different things in the
arrangement and the piano roll. The owner's overhaul brief asks for one authoritative registry, presets modelled on
other DAWs, a full editor with conflict handling, and reliable dispatch across focus contexts.

## Decision
- **Menu items stay the commands.** Menus, the palette, buttons and shortcuts already run the same selectors with
  the same validation. `ShortcutRegistry` (`app/macos/Dalnok/Shortcuts.swift`) reads the main menu after it's built.
  It gives each item a stable id (e.g. `transport.play_pause`), a category, a description, keywords and a context,
  then writes the effective shortcut back onto the menu item for display. View-handled actions (piano-roll
  editing keys) are registered without a menu item.
- **Contexts:** `global`, `arrangement`, `pianoRoll`. Two commands conflict only if they share a key in the same
  context. A context-specific binding overrides a global one where it applies (↩ inserts a note in the piano roll
  and goes to the start elsewhere).
- **Dispatch:** `MainMenu.performKeyEquivalent` asks the registry first. The registry runs the command bound in the
  active context through its menu item (same validation), leaves piano-roll actions to the piano roll, and never lets
  AppKit's looser menu matching fire anything else. Only ⌘/⌃ combinations it doesn't know reach AppKit (for
  system-added items). Modifier-free keys never fire while a text field is being edited.
- **Responder-chain commands** (Cut, Copy, Paste, Select All) have no fixed target, so text fields keep ⌘C/⌘V. The
  arrangement handles them otherwise.
- **Presets** are bindings layered on Dalnok's defaults: Logic Pro, Ableton Live, REAPER, Pro Tools, Cubase,
  Studio One. Each is labelled an approximation (not verified against the application) and lists that DAW's
  well-known commands Dalnok lacks. The owner's changes are stored as overrides on the chosen preset
  (`shortcuts.overrides`); named sets live in `shortcuts.userPresets`. A set exports and imports as JSON
  (`format: dalnok-shortcuts`). Choosing a preset never touches project data.

## Consequences
- Adding a menu item gives it a shortcut policy automatically. Give it a `Spec` entry for a stable id and description.
- `Migration.applyKeymap` remains as a thin call into the registry (onboarding's DAW choice).
- Per-key reserved-by-macOS warnings are advisory: Dalnok can't stop the system from taking them.
