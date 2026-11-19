# Dalnok codebase, architecture and performance audit — 2026-11

**Revision audited:** `b15410a` (`main`, 0.1.0 preview), branch `audit/2026-11-codebase`
**Date:** 2026-11-18
**Scope:** engine (C++20), C API, macOS AppKit front end, tests, tools, build and CI. No feature work
was performed; one measurement-only CLI subcommand was added (documented below).

---

## 1. Executive summary

Dalnok is in materially better engineering shape than most pre-alpha DAWs. The three decisions that
matter most are already right:

1. **A real-time contract enforced by the compiler.** `DALNOK_NONBLOCKING` = `noexcept
   [[clang::nonblocking]]`, with `-Werror=function-effects`, checked from the Core Audio entry point
   down. A negative test proves an allocation fails the build. This is rare and should never be
   weakened.
2. **One owner of the model.** The engine owns the project; every mutation is a named, undoable
   command; the UI is a read-only view refreshed on a revision counter; the command catalog exposes
   the same operations as JSON. That gives scripting, palette, tests and future AI assistance one
   surface instead of five.
3. **A clean ABI boundary.** A plain C header, no engine headers in Swift, a separate scanner process
   for untrusted plug-in code at discovery time, and deterministic generated fixtures instead of
   owner material.

Measured on an M3 Max, the real-time path is comfortably inside budget: **31 µs** per 512-frame block
at 8 tracks, **142 µs** at 64, **561 µs** at 256 and **1.11 ms** at 512, against a 10.67 ms budget.
Offline rendering is 642x realtime at 8 tracks and 10x at 512. Nothing in the audio path is currently
a bottleneck at realistic sizes.

The risks are elsewhere, and they are concentrated in three places:

- **Failure containment.** Third-party plug-ins run in-process; a plug-in crash or hang takes the app
  and every unsaved edit with it. There is **no autosave** — only recording takes are journaled. This
  is the single largest data-loss exposure in the product and the reason two findings are P0.
- **Whole-model work per interaction.** Every edit, including a fader move, deep-copies the entire
  model (clip strings and plug-in state included) and pushes it onto a 500-deep undo stack;
  structural edits rebuild the whole render snapshot with an O(tracks × clips) loop; the UI re-reads
  the entire model through the C API on every revision change, including per mouse event during a
  drag. At 4,096 clips one UI read pass is **15.9 ms** — longer than a 60 Hz frame, before the views
  are even redrawn.
- **Growth assumptions that have not been paid for.** Media is fully decoded into RAM (23 MB per
  stereo minute); there is no disk streaming; the engine is a 2,526-line god object with 117 methods;
  and the project's own status document is stale enough to mislead contributors (it lists AU/CLAP
  hosting, plug-in editors, automation, latency compensation, punch and count-in as missing when all
  are implemented and tested).

None of this requires a rewrite. The architecture is sound and the correct next moves are
containment, incremental work, and paying down the model-copy debt — in that order.

### Audit scope and limitations

Read: all of `engine/src` structure and key files, `engine/include/dalnok/dalnok.h`, `app/macos/Dalnok`
key files, `tests/engine`, tools, scripts, CI, ADRs 0003–0011, architecture notes, CURRENT_STATE.
Ran: `swift build` (debug/release/clean), `swift test` (188 tests, 57 suites, 11.6 s), `dalnok-cli
bench` (4 sizes, repeats), a new `audit-bench`/`audit-scale` measurement, project load/render RSS,
snapshot timings in both themes.

Not run: the GUI self-test (required an interactive session; check counts quoted from CURRENT_STATE),
plug-in hosting scripts (they build fixture plug-ins; not needed for these findings), sanitizer runs
(CI covers them), and real third-party plug-ins. Timeline scroll/zoom frame time is **not measured**;
the UI finding rests on the measured model-read cost, which is a lower bound.

---

## 2. Architecture assessment

### What the design gets right

| Area | Evidence | Verdict |
|---|---|---|
| Real-time safety | `DALNOK_NONBLOCKING`, `-Werror=function-effects`, negative test | Keep. A genuine differentiator. |
| Handoff | Immutable `RenderState` through an atomic slot, retired via a 64-entry SPSC queue, freed on the control thread | Correct and simple. |
| Continuous parameters | `TrackRuntime` atomics shared across snapshots, linear ramps per block | Correct; avoids recompiling for fader moves. |
| Model ownership | Engine-owned, revision counter, no UI mirror | Correct; prevents two sources of truth. |
| Undo | Whole-model snapshot + `begin/end group`; transactional rollback | Correctness is excellent; the memory model is the cost. |
| Commands | 70 catalog commands, JSON in/out, same methods as the C API | Excellent foundation for scripting and testing. |
| Untrusted discovery | `dalnok-scan` loads one plug-in per process with a timeout and a cache | Right idea; the app itself is not yet protected. |
| Platform split | OS code confined to `engine/src/platform/macos/` | Ready for CMake and other front ends. |

### Subsystem health

| Subsystem | Files / size | Health | Notes |
|---|---|---|---|
| Real-time render | `render.cpp` 473, `render.hpp` 258 | Good | Clear, scalar, allocation-free. Headroom for SIMD and skip lists; no correctness smell. |
| Engine core | `engine.cpp` 2,526, `engine.hpp` 598 | Strained | 117 methods; device, transport, record, MIDI, plugins, routing, launcher, undo, render. |
| C API | `dalnok_api.cpp` 1,285, `dalnok.h` 761 | Strained | 211 functions, hand-written marshalling, manual version. |
| Persistence | `project.cpp` 851 | Fair | Atomic, durable writes are excellent; no schema or migration table. |
| Importers | `import/` ~1,300 | Fair | Good report discipline; complex parsing without fuzzing. |
| Plug-in hosting | `vst3_host.cpp` 708, `au_host.mm` 337, `clap_host.cpp` 344 | Fair | One interface for three formats is a real achievement; in-process is the risk. |
| App | 35 Swift files, 19,913 LOC | Fair | Clear ownership per view; `Session` refresh model does not scale. |
| Tests | 31 files, 5,093 LOC, 188 tests | Good | Numeric tolerances, generated fixtures, mutation checks. Gaps: fuzzing, UI performance. |

![dependency direction](dashboard) — the dashboard renders this as an interactive diagram:
`AppKit UI → C API → Engine → {DSP, platform/macOS, fx, import}` with `tests` and `dalnok-cli` entering
through the same C API, and `dalnok-scan` isolated.

### Architectural violations found

- **The app reaches into engine semantics it should not need to know.** `EngineBridge` applies
  projects on the main actor, and `applyProject` instantiates plug-ins synchronously
  (`project.cpp:820`), so plug-in initialisation runs on the AppKit main thread by construction. The
  MODO BASS stall is a consequence of that arrangement, not a mystery.
- **View-only state lives in the domain model and the undo stack.** Track height and hidden flags are
  saved model fields and undoable commands; a layout tweak consumes an audio undo slot.
- **The C API is a projection, not a boundary for bulk data.** Every clip field crosses the ABI as a
  128-byte struct, and the Swift side re-assembles it by hand. Measured cost is ~3.9 µs per clip,
  which is high for what is a memory read.

---

## 3. Performance (measured)

All figures: release build, 48 kHz, 512-frame blocks, M3 Max. Full data and raw output in
`benchmarks/results.json` and `benchmarks/raw/`.

### 3.1 Real-time path

| Tracks | Avg block | Worst block | Load | Offline |
|---|---|---|---|---|
| 8 | 31.3 µs | 52.2 µs | 0.3% | 642x |
| 64 | 141.7 µs | 272.5 µs | 1.3% | 80x |
| 256 | 560.7 µs | 1,111 µs | 5.3% | 20x |
| 512 | 1,113.9 µs | 2,148 µs | 10.4% | 10x |

Cost is ~2.2 µs per track per block, linear, because `renderBlock` visits every track unconditionally.
That is acceptable today and is the headroom that A-11 targets. Repeat runs varied by 0.4% (64 tracks)
and 6% (256 tracks) on the average, more on the worst block.

### 3.2 Model, edit and undo cost (the real scaling problem)

| Model | Build | Model read | Structural edit | Parameter edit | Undo |
|---|---|---|---|---|---|
| 8 × 8 (64 clips) | 1 ms | 0.006 ms | 0.012 ms | 0.003 ms | 0.011 ms |
| 32 × 32 (1,024) | 49 ms | 0.673 ms | 0.098 ms | 0.031 ms | 0.086 ms |
| 64 × 32 (2,048) | 230 ms | 3.386 ms | 0.257 ms | 0.054 ms | 0.244 ms |
| 128 × 32 (4,096) | 1,272 ms | **15.931 ms** | 0.770 ms | 0.075 ms | 0.745 ms |

Three separate effects are visible:

1. **Model read is super-linear in clips** because each clip crosses the C ABI with string fields and
   the UI walks the whole model. 4,096 clips → 15.9 ms. A fader drag calls this per mouse event.
2. **Structural edit is linear in clips × tracks** because `compile()` loops the entire clip vector
   once per track. 4,096 clips → 0.77 ms, and building the project one clip at a time took 1.27 s
   because every add recompiled.
3. **Undo is the same cost as the edit** (whole-model restore plus recompile).

At currently realistic sessions (64 tracks, one to a few clips each) all three are sub-millisecond and
invisible. The finding is about the trend line: a real 64-track song with 20 clips per track is 1,280
clips, and a long session with takes reaches the 4,096 row quickly.

### 3.3 Memory

| Case | Peak RSS |
|---|---|
| Generated band project (8 tracks, 35 MB audio) | 78 MB |
| 64 tracks × 30 s (352 MB audio, fully decoded) | 382 MB |
| 256 tracks × 10 s (469 MB audio, fully decoded) | 542 MB |

Media decoding dominates. There is no leak visible in these runs (RSS after 200 undoable edits grows
by 0.7–5.3 MB, consistent with retained undo snapshots), but there is also no soak test, so
long-session growth is unverified.

### 3.4 App launch and snapshot

`DALNOK_SNAPSHOT_DELAY=0`, process start to exit including NSApplication, project load, window
construction, drawing and PNG encoding: **741–807 ms** Graphite, **718–805 ms** Warm Analog. Both
themes are comparable; there is no evidence for the "Warm Analog is slow to open" backlog item at
this project size. Real cold/warm launch without the snapshot path is not measured.

### 3.5 Build

| Case | Time |
|---|---|
| Clean debug | 21 s |
| Clean release | 69 s |
| Incremental, CLI only | 6.9 s |
| No-op | 0.44 s |

Build time is not a current pain point, but the engine is one C++ target: any header change rebuilds
all 15k lines, and CI builds cold every run. A-19 proposes target splits plus a cache.

---

## 4. Data model and synchronisation

The revision-counter design is simple and safe, and the absence of a UI mirror is a genuine strength.
The costs are structural:

- **Full refresh, always.** `Session.refresh()` re-reads every track, clip, note list, plug-in, send
  and automation lane. There is no change set and no per-track revision, so the UI cannot know what
  changed. `MainWindow.tick()` calls refresh at 60 Hz, and `modelChanged()` rebuilds the device panel
  and mixer on top.
- **Duplicate reads.** Each track is read twice in `refresh()` (once in the main loop, once for
  height), and `dalnok_track_hidden` is a separate call per track.
- **Linear lookups.** `Session.track(id)` and `Session.clip(id)` scan arrays; call sites in hot paths
  (playhead follow, header selection, device panel) turn into O(tracks × calls).
- **Undo is value semantics over the whole model.** Correct, transactional, and the source of the
  memory and edit-cost findings (A-03, A-07).

The recommended direction is a **change set published with each revision** (track/clip ids and a
kind), with full refresh kept as the correctness fallback. That keeps one source of truth while
letting the UI touch only what moved. Do not introduce a second model.

---

## 5. Reliability and correctness

Strengths: durable atomic saves with directory fsync; take journals and verified WAV read-back;
process-kill recovery tests that assert every sample; out-of-process scanning; a real-time check that
fails the build; ASan/TSan jobs in CI; explicit rejection of corrupt project and MIDI data.

Gaps, in order of blast radius:

1. **In-process plug-in hosting (A-01).** Real crashes are already recorded in the changelog.
2. **No project autosave (A-02).** A crash loses everything since the last manual save.
3. **Plug-in initialisation on the main thread (A-08).** A slow plug-in is indistinguishable from a
   hung app; MODO BASS produced minutes of stall.
4. **Silent handoff degradation (A-14).** If the retire queue fills, edits stop taking effect with no
   signal.
5. **No fuzzing of parsers (A-10).** Importers process complex third-party files with hand-written
   arithmetic.

Suggested posture: containment first (autosave, then out-of-process hosting), then fault-injection
coverage — a plug-in that crashes, hangs, allocates, throws across the boundary, returns NaNs and
changes its latency mid-stream should each have a fixture and an expected behaviour.

---

## 6. Readiness for the next several years

| Capability | Ready? | Why |
|---|---|---|
| Thousands of clips | No | Compile O(T×C), UI read 3.9 µs/clip, undo copies the model |
| Thousands of tracks | Partly | Audio path is linear and fine at 512; UI and edit paths are not |
| Long recordings / large sessions | No | Full decode into RAM, no streaming |
| Complex routing and sidechains | Yes | Topological order, compensation graph, cycle rejection, tests |
| Many plug-ins | Partly | Interface is good; process isolation is missing |
| Surround / spatial | No | Stereo is baked into render, sends, meters and C API; needs a channel-layout refactor |
| Scripting / automation APIs | Yes | 70-command catalog with JSON is the right foundation |
| Windows / Linux | Partly | Platform code isolated; UI is AppKit-only and build is SwiftPM-only |
| New themes | No | Global theme state, relaunch to switch |
| Collaboration | No | Single-document, single-user; snapshot undo would need operational transformation or CRDT |
| Background analysis / AI | Partly | Command catalog and revision model help; no worker infrastructure beyond stretch/peaks |

The important distinction: routing, commands, real-time handoff and persistence are **already
foundations**. Streaming, change sets, containment and channel layout are **not**, and they are much
cheaper to build before there are ten features depending on the current shape.

---

## 7. Technology evaluation

| Choice | Verdict | Reasoning |
|---|---|---|
| C++20 engine | Keep | The VST3 SDK and Signalsmith are C++; `[[clang::nonblocking]]` is unique to Clang and directly enforces the product's hardest invariant. C++23 adds little here. |
| Rust for the engine | No | Would discard the compile-time real-time checker, force FFI for VST3/Signalsmith, and rewrite 15k tested lines for no measured gain. Revisit only for a new isolated service (e.g. an analysis worker or the plug-in supervisor). |
| Swift/AppKit UI | Keep | Custom-drawn timeline needs the control; measured render cost is not the problem, the model read is. SwiftUI would not help. |
| Metal | Not yet | No frame-time measurement shows CoreGraphics is the bottleneck. Measure first with a scroll/zoom harness; the UI read pass must be fixed regardless. |
| Accelerate | Use more | Already linked for stretch. vDSP for clip copy, fades, meters and the ramp is a low-risk, dependency-free win (A-13). |
| Serialization | Keep JSON | Human-readable projects have real support value. Add a schema and migrations rather than switching formats (A-16). |
| Out-of-process hosting | Yes, but staged | The only credible answer to plug-in crashes. Start with the supervisor process that already exists as the scanner (A-01). |
| Disk streaming | Yes, foundational | Without it, "long recordings" and "large sessions" are not achievable (A-09). |
| Sanitizers / fuzzing | Expand | CI already runs ASan/TSan; add libFuzzer targets and a default local sanitizer pass (A-10). |

---

## 8. Technical debt distribution (judgement, not measurement)

| Category | Share | Character |
|---|---|---|
| Reliability / containment | 30% | In-process plug-ins, no autosave, main-thread plug-in init |
| Model and sync scalability | 30% | Whole-model copies, O(T×C) compile, full UI refresh |
| Architecture / module shape | 20% | Engine god object, hand-written C facade, theme globals |
| Media and memory | 10% | Full decode, no streaming |
| Tooling and docs | 10% | Fuzzing, build caching, stale CURRENT_STATE |

This is a subjective allocation based on the findings' severity and effort, not a measured quantity.

---

## 9. The ten most important improvements

1. **Autosave and project crash recovery** (A-02, P0, M). Bounds every other failure.
2. **Out-of-process plug-in hosting** (A-01, P0, XL). The only fix for third-party crashes.
3. **Stop copying the whole model on parameter edits; share structure** (A-03, P1, L).
4. **Make snapshot compilation linear, then incremental** (A-04, P1, M).
5. **Publish change sets and refresh the UI incrementally** (A-05, P1, L).
6. **Move plug-in instantiation off the main thread with progress and cancel** (A-08, P1, L).
7. **Disk streaming for long media** (A-09, P1, XL).
8. **Split the Engine god object into services** (A-06, P1, L).
9. **Fuzz the project and import parsers; make sanitizers routine** (A-10, P1, M).
10. **Fix the stale capability matrix so docs match the code** (A-23, P2, S).

---

## 10. Most concerning risks

- **Unsaved work plus an untrusted plug-in** is a data-loss incident waiting for a user.
- **A 4,096-clip session will feel sluggish** in the UI while the audio engine remains fast, which
  will look like an audio problem to users and be misdiagnosed by contributors.
- **Undo memory with large plug-in states** can multiply a project's footprint by the undo depth.
- **Long-session memory growth** is untested; a soak test is cheap insurance.
- **Documentation drift** already misleads: a contributor reading CURRENT_STATE would rebuild features
  that exist.

## 11. Most promising performance opportunities

- Incremental UI refresh (measured upper bound: 15.9 ms → target under 1 ms for a one-track edit).
- Linear/incremental snapshot compile (0.77 ms → target under 0.2 ms at 4,096 clips).
- Streaming media (memory becomes independent of project length).
- Track skipping in the audio callback (worth ~2.2 µs per silent track per block).
- SIMD for copy, fades, ramps and meters (hypothesis: 25%+ at 64–256 tracks; must be measured).

---

## 12. Method, reproducibility and confidence

Commands, environment and raw output are in `benchmarks/method.md` and `benchmarks/raw/`.

Measurement-only change: `tools/dalnok-cli/main.swift` gained `audit-bench` and `audit-scale`
subcommands. They call the public C API only, add no engine or app behaviour, and can be deleted
without touching the product. No other application code was modified.

Confidence: findings A-03, A-04, A-05, A-06, A-09, A-11, A-19 and A-23 are backed by direct
measurement or source contradiction and are high confidence. A-01, A-02, A-07, A-10, A-14, A-16,
A-18, A-20, A-21 and A-22 are source- and incident-backed and high confidence on the problem, medium
on the exact fix. A-08, A-12, A-13, A-15 and A-17 are medium: the problem is visible, the fix needs a
spike. Nothing in this report claims a speedup that was not measured; where a number is a target it
is labelled as a target.

See `modernization-roadmap.md` for order, dependencies and acceptance criteria, and
`dashboard/index.html` for the interactive version of all of the above.
