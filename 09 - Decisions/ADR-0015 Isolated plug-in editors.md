---
status: accepted
date: 2026-11-19
---
# ADR-0015: Editors for isolated plug-ins

**Context.** An isolated plug-in (ADR-0014) runs in its own `dalnok-plughost` process, so its editor view is built
there and cannot be added to one of Dalnok's windows. Stage 1 offered isolated instances the generic parameter panel
only. Two designs were considered.

- *Remote layers.* The host renders the editor into a `CAContext` and Dalnok shows it with a `CALayerHost` inside its
  plug-in window. This looks embedded, but `CAContext`/`CALayerHost` are private SPI that can change with any macOS
  release. Only pixels cross the boundary: every mouse, scroll, key, text-input, cursor, tooltip, drag-and-drop and
  accessibility event would have to be forwarded and re-synthesized in the host. Plug-ins also open their own menus,
  pop-ups and dialogs, which would still appear from the host's process.
- *A window owned by the host.* The host becomes an AppKit application and shows the editor in its own window. All
  input, menus, dialogs, cursors and accessibility work natively, and only public API is used. The cost is that the
  window is not a child of Dalnok's windows (child windows cannot cross processes), so Dalnok has to manage its level,
  placement and visibility indirectly.

**Decision.** Host-owned window.

- The first editor request turns the host into an accessory application (no Dock icon or menu bar) and switches its
  main thread from a plain run loop to `NSApp run`. Control requests stay a run-loop source in the common modes, so they
  are served while an editor tracks a knob or runs a modal dialog.
- The editor is a titled, closable, non-activating floating panel. Clicks and typing reach it while Dalnok stays the
  active application, keeping its menu bar and shortcuts. The host finishes launching while activation is prohibited
  and returns any activation the system still hands it to Dalnok (`yieldActivationToApplication`). A hidden Edit menu
  provides the standard text key equivalents (⌘A, ⌘C, ⌘V, ⌘Z) to editor text fields.
- It follows Dalnok: hidden while another application is active, and shown again when Dalnok is.
- Size: a resizable editor (autoresizing in both directions, as Audio Unit views are) fills a resizable panel. A fixed
  one sets the panel's size, including later changes (the plug-in's resize request, or its view changing frame).
- C API 36: `dalnok_plugin_show_editor_window` (title and top-left placement; Dalnok puts it beside its own plug-in
  window), `dalnok_plugin_editor_window` (open, visible, frame, window number and owning process) and
  `dalnok_plugin_editor_snapshot` (PNG of the editor's pixels for tests). `dalnok_plugin_close_editor` closes it, and
  `dalnok_plugin_open_editor` refuses isolated instances and says why. Dalnok's plug-in window keeps the parameter
  panel; its Editor tab brings the host's window forward, and closing it closes the editor.

**Consequences.** Isolated plug-ins get their real editors with native input and no private API. The editor is a
separate window rather than a tab, and it floats above Dalnok's windows while Dalnok is active. Opening an editor
connects that host to the window server (memory and launch cost only for instances whose editor was opened). An editor
that takes longer than the 5 s control timeout to open marks the instance failed, as any hung request does.

**Keys (2026-11-20).** Verified with real input on the owner's library: a click in an isolated editor gives the host's
panel the keyboard (it must, so plug-in text fields work), and Dalnok then lost Space, ⌘S and every other shortcut until
the user clicked back into one of its windows. The panel now passes back keys its editor does not use: `keyDown:` that
falls off the responder chain, and key equivalents that no view takes (the hidden Edit menu still serves ⌘A/C/V/X/Z while
a text field is being edited). They travel through a 16-entry ring in the shared block, and the engine returns them with
`dalnok_plugin_take_editor_key` (C API 39). Dalnok replays each one on its display tick through its shortcut registry,
as if typed in an editor embedded in its own window. A focused search field in Dalnok's plug-in window does not swallow
them. Self-test (DALNOK_REAL_INPUT=1): a real click in the test VST3's editor followed by two real Space presses plays and
stops Dalnok.
