# Real-Time Processing

## Threads
- **Control (main) thread:** edits the model, compiles snapshots, frees retired snapshots (`collect_garbage`).
- **Audio thread (Core Audio):** `Engine::audioCallback` → `process` → `renderBlock`.
- **Workers:** media decoding and peak building (immutable results, shared via `shared_ptr<const Media>`).

## Handoff protocol
1. The control thread runs `compile()`, which produces a new `RenderState*`, then `pending_.exchange(new)`.
   If an older pending state comes back, the audio thread never saw it, so it's deleted immediately.
2. Each callback, the audio thread checks whether the retire queue has space. If so, it takes
   `pending_.exchange(nullptr)`, pushes the old `current_` into the SPSC retire queue, and adopts the new one.
3. The control thread pops retired states and deletes them. Media refcounts only drop on this thread.

Continuous parameters (gain, pan, mute) are `std::atomic<float/bool>` in a `TrackRuntime` that every
snapshot shares. The audio thread ramps linearly per 512-frame block to avoid zipper noise.

## Transport
`playing_` and `seekRequest_` are atomics. A 5 ms gain ramp de-clicks play, pause, and seek. A seek
while audible fades to zero first, then jumps. `position_` is published once per callback.

## Recording and MIDI input
- `recordArmed_` (atomic) turns on take tracking. At the end of each callback the audio thread checks whether the
  transport advanced by exactly the callback's frames. The first such block sets `recordStart_`; a later gap or
  jump sets `recordBroken_`. Only blocks inside the take are pushed into the capture ring (`rtRecordingBlock_`).
- MIDI input: up to eight `MidiParser`s (slot 0 for injected events, the others for Core MIDI ports) published as
  atomic pointers. Core MIDI's receive thread is each port parser's only producer; the audio thread pops all of
  them at the start of each callback, plays note messages on the armed instrument's live voices, and, inside a
  take, forwards them stamped with the block's start position to an SPSC queue that the control thread drains.
- Each instrument track has two voice sets in its `TrackRuntime`: timeline playback and live input. Offline
  renders use their own voice sets, so exporting never disturbs live playback.

## Enforcement
- `DALNOK_NONBLOCKING` = `noexcept [[clang::nonblocking]]` on every function reachable from the callback,
  with `-Werror=function-effects`. The macOS SDK already marks `AURenderCallback` as real-time, so this
  chain is checked from the OS entry point down.
- The one suppression is `clock_gettime_nsec_np` (a commpage read) for callback timing stats.
- Planned: RealtimeSanitizer (`-fsanitize=realtime`) via Homebrew LLVM in CI. Apple clang 21 doesn't support it.

## Budgets
Internal block size is 512 frames. Overload means a render took longer than the callback period
(counted in `DalnokStats.overloads`).
