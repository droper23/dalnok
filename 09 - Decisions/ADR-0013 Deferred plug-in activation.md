---
status: accepted
date: 2026-11-19
---
# ADR-0013: Deferred plug-in activation

**Context.** `dalnok_project_apply` instantiated every plug-in synchronously, and the app applies projects on the
main thread, so opening a project with many or slow plug-ins froze the UI until all of them were loaded (audit
A-08; MODO BASS, Melodyne and Analog Lab measured 1.8 s to minutes). Plug-in creation cannot simply move to a
worker thread: CLAP requires `create`/`init` on the main thread, VST3 calls everything except processing on the
UI thread, and many Audio Units assume the main thread as well.

**Decision.** Project apply swaps the model in immediately and queues each plug-in slot, in track order, as
*loading* (the same unloaded-with-saved-state condition recovery mode uses: missing inserts are bypassed,
missing instruments are silent, and saving keeps the saved state). The host then activates the queue one
plug-in at a time on the main thread (`dalnok_plugins_activate_next`) and returns to the run loop between
plug-ins, so the window draws, shows progress and accepts Cancel. Cancel marks the remaining slots not loaded
with their state preserved; any unloaded slot can be loaded later (`dalnok_plugin_reload`). Each activation is
timed, and slow plug-ins are named in a message after they finish. Synchronous apply keeps its old behavior for
the CLI and tests.

**Consequences.** The UI is never blocked by more than one plug-in's own initialization. A single plug-in that
blocks its own initialization still blocks the main thread for that long; containing that requires the separate
host process (A-01, ADR-0009), whose main thread would absorb the wait. Playback during activation hears the
loaded subset. A crash during activation is covered by the pre-activation recovery copy (A-01a).
