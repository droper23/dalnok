---
status: accepted
date: 2026-11-16
---
# ADR-0005: Engine-owned project model, snapshot undo, and a command catalog

**Context.** Front ends, scripts, and future natural-language assistance must all edit the same project
in the same way, with reliable undo. Logic's closed, menu-buried actions are a stated pain point.

**Decision.**
1. **The engine owns the model** (`Model`: tracks and clips in z-order, plus a media pool). Front ends are
   read-only views that re-query when `atrium_model_revision` changes. No UI mirror.
2. **Every mutation is a command** that goes through `Engine::edit(name, structural, fn)`:
   - copy the model, run `fn`, and roll back on failure;
   - otherwise push the previous model as an undo step named `name`;
   - bump the revision and, if the change is structural, recompile the render snapshot.
   - Parameter edits (gain, pan, mute) write atomics and skip recompiling.
3. **Undo uses whole-model snapshots** (capped at 500), not inverse operations. An edit can't be undone
   incorrectly, and a failed edit is rolled back for free ("transactional edits").
   **Groups** (`atrium_undo_begin_group/end_group`) turn a drag into one step.
4. **Command catalog.** Named commands (`clip.move`, `track.setVolume`, …) take JSON arguments and return
   JSON results through `atrium_command_run`. They call the same methods as the typed C API. This is the
   surface for scripting, the command palette, and natural-language automation later.
5. **Overlaps:** the top clip wins (z-order). Moving a clip brings it to the top.

**Consequences.** Undo memory is O(model × steps). That's fine for thousands of clips. Revisit with
persistent data structures if profiling shows a problem. Media lives in the pool for the session, so undo
can always restore clips.

**Rejected.**
- Inverse-operation undo: more code and a bug surface on every command.
- Model in Swift: not portable, not scriptable.
- Callback notifications into Swift: polling the revision is simpler and thread-safe.
