---
updated: 2026-11-17
---
# UI Conventions

Rules every panel follows. Check new UI against them.

## Dismissal
- **Transient UI** (menus, popovers such as Edit Controls, the command palette, value bubbles) closes on a click
  outside and on Escape. A click outside a popover closes it and still reaches what was clicked (observed with real
  input: closing Edit Controls by clicking a lane also selected that lane's track). No single click in Dalnok is
  destructive, so this is safe; keep it that way.
- **Decisions that can lose work** (unsaved changes, replacing a file, switching a shortcut preset with changes,
  restoring all shortcuts) are sheets with explicit buttons. They never close on an outside click.
- While a sheet or alert is open, Return and Escape belong to it. Shortcuts stay out of the way.

## Keyboard
- One registry runs every shortcut ([[Keyboard Shortcuts]]). Keys without ⌘/⌃/⌥ never fire while a text field is
  being edited. Cut, Copy, Paste and Select All reach a text field first, otherwise the arrangement.
- Every interactive control is focusable where AppKit allows. Custom controls draw a focus ring and take arrow keys
  (knobs, faders, pedal controls), Space or Return (keys, footswitch), and VoiceOver actions (increment/decrement or press).

## Scrolling
- The track headers, the clip launcher and the arrangement share one vertical offset (the timeline owns it). Wheel
  and trackpad scrolling anywhere over them moves the tracks; controls inside headers pass scrolling through.
- ⇧ scrolls horizontally with a mouse wheel; ⌘ or ⌥ zooms; pinch zooms.

## Direct manipulation
- Double-click a track name to rename; drag headers to reorder; drag clips to move, edges to trim.
- Drag a plug-in from the browser onto a track or the device panel; drag a device to reorder the chain.
- Right-click opens the relevant context menu (track, clip, device or pedal, pedal control, plug-in row, sidebar).
- Views accept the first click when it starts a drag, even when another window is key.

## Honesty
Nothing looks usable while doing nothing. Unavailable commands are disabled with a reason (tooltip or status line),
or listed as planned in the Command Palette and the shortcut presets. The self-test scans for menu commands without
a handler and enabled buttons without an action.
