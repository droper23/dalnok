# Handoff prompt — Dalnok audit follow-ups, wave 2

You are continuing work in the Dalnok repository (portable C++20 engine behind a plain-C API, AppKit front end
on macOS). An independent audit produced 23 findings; wave 1 fixed six of them. Your job is wave 2: A-01a,
A-03a, A-05a and A-14, in that order, each with tests and measured evidence, then the docs and a commit.

Read `AGENTS.md` and `CURRENT_STATE.md` first. Do not trust this prompt over the source; it is a map, not
evidence. If something here disagrees with the code, the code wins and you should say so.

## Where the repo stands

- Audit branch `audit/2026-11-codebase` (commit `341a8b8`): report, `docs/audits/findings.json`,
  `docs/audits/modernization-roadmap.md`, benchmarks and a dashboard.
- Fixes on `fix/audit-followups`, currently at `bab598b`. Working tree clean, not pushed.
- Findings: 5 `fixed` (A-02, A-04, A-07, A-12, A-23), 1 `partial` (A-10), 17 `open`.
- Baseline: `swift build` clean except a pre-existing unused-variable warning at `record.cpp:214`;
  `swift test` = 191 tests in 59 suites passing.
- Wave-1 measurements at 4,096 clips (16 tracks x 256 clips, release, 48 kHz): structural edit
  0.770 -> 0.255 ms, undo 0.745 -> 0.238 ms, clip-by-clip build 1,272 -> 527 ms. Model read still 15.9 ms.
- A-02 (autosave/recovery) was **already implemented**; the audit misread it. Do not re-implement it.
  A-12 (flush-to-zero) is in place at the top of `Engine::process`, `renderOffline` and `renderToWav`.
- A-08's MODO BASS stall was **not reproduced** (CLI instantiation took 3.2 s; the built app's main thread
  stayed idle). It is not fixed. Do not claim otherwise.

## Hard rules (from AGENTS.md, non-negotiable)

- Anything reachable from the device callback is marked `DALNOK_NONBLOCKING`; Clang enforces no allocation,
  free, lock, I/O or throw. Data reaches the audio thread only as immutable `RenderState` snapshots or atomics.
- Every model mutation is an `Engine::edit` command (undoable), and every user-visible action also gets a
  catalog entry in `commands.cpp`. Front ends never cache model state; they re-query on revision change.
- New engine features need a test with explicit numeric tolerances; audio changes need an offline-render test.
- `engine/include/dalnok/dalnok.h` stays plain C. Append struct fields at the end, bump
  `DALNOK_API_VERSION` (currently 29), and keep the Swift `DalnokStats` layout in step.
- No invented measurements. Every speedup claim needs a before/after run from `dalnok-cli`.
- Generated fixtures only (`scripts/make-test-project.sh`); never the owner's projects, never anything
  outside `site/` published, never `git push`.
- At the end: `CURRENT_STATE.md`, `CHANGELOG.md`, `10 - Development Journal/`, `findings.json` (status +
  `resolution`), roadmap progress, rebuild the dashboard, then commit on `fix/audit-followups`.

## Task 1 — A-01a: crash-safe boundary before plug-in initialisation (S, do first)

**Why.** `dalnok_project_apply` -> `Engine::applyProject` -> `instantiatePlugins()`
(`engine/src/project.cpp:822`, `engine/src/engine.cpp:878`) loads third-party code on the calling thread.
The app applies on the main actor (`app/macos/Dalnok/EngineBridge.swift:211`), so a plug-in that crashes or
hangs during initialisation loses the incoming project before it was ever saved. Autosave does not cover
this window because the new project was never snapshotted.

**What to build.** The engine takes a settable recovery-directory/`std::string` hook (control thread only,
never visible to the audio path). In `applyProject`, after the model swap and **before**
`instantiatePlugins()`, write the incoming project atomically to that directory using the same serialiser
the app's recovery snapshots use, then instantiate. The app sets the directory at launch; the CLI and the
import tests pass none, so their behaviour is unchanged. The snapshot must never overwrite a real project
file, and writing it must not disturb `savedRevision_`/dirty state.

**Acceptance / evidence.** A fixture plug-in that exits or blocks during `initialize` leaves a recovery file
that reloads with every edit and with plug-ins in their saved/unloaded state. Existing recovery smoke
(`scripts/ci/recovery-smoke.sh`) and `plugin-scan` fixtures are the starting points; `scripts/ci/plugin-scan.sh`
already builds crashing and hanging fake plug-ins. Run the crash case under `DALNOK_SANITIZE=1` too.

## Task 2 — A-03a: parameter edits skip the whole-model copy (M)

**Why.** `Engine::edit` starts with `Model before = model_;` (`engine/src/engine.cpp:282`) for every mutation,
including gain/pan/mute/master, whose real effect is an atomic store in `syncRuntimes()`. Undo keeps up to
`kMaxUndo = 500` full copies, each holding every clip, every plug-in slot and its state blob. Measured:
0.075 ms per gain edit at 4,096 clips before wave 1; the copy is also O(model) memory per retained step.

**What to build.** Split the path rather than special-casing call sites:
- Parameter-only edits (`setGainDb`, `setPan`, `setMute`, `setMasterGainDb`, and any other command whose
  effect is a scalar on a runtime) write the atomic and record a **compact undo entry** (track id, field,
  old value) instead of copying `Model`.
- Coalesce one entry per drag using the existing `beginGroup`/`endGroup`/`groupRecorded_` machinery, so a
  fader drag is one undo step, matching today's behaviour.
- Structural edits keep snapshot undo and stay the only path that copies `Model`; `restore(Model)` remains
  their rollback and redo mechanism.
- Preserve failure atomicity: if `fn` returns false, the pre-edit state must be exactly restored (today that
  is the copy). Keep `undoName()`/`redoName()`, the 500-step cap and redo clearing identical.
- Commands that touch both a scalar and structure stay structural. When in doubt, keep the copy.

**Acceptance / evidence.**
- Existing `UndoAndEditing`, `ModelTests` and command-catalog suites pass unchanged.
- New test: a simulated fader drag (begin, N parameter edits, end) produces exactly one undo step and the
  recorded cost per edit is independent of clip count.
- Property test: random command sequence then full undo returns the exact serialised model — reuse the
  save -> load -> save JSON comparison from `tests/engine/ParserFuzzTests.swift`.
- Measure with `dalnok-cli audit-bench` at 4,096 clips before/after: per-edit cost and RSS after 500 edits.
  Record the numbers in `benchmarks/results.json`; a 5x RSS reduction is the finding's target for the full
  A-03, but wave 2 only claims what it measures.

## Task 3 — A-05a: no full model read on parameter-only revisions (S)

**Why.** `Session.refresh()` (`app/macos/Dalnok/Session.swift:95`) walks every track, clip, note list,
plug-in, send and automation lane whenever the revision moves. `MainWindow.tick()` calls it at 60 Hz
(`MainWindow.swift:530-533`) and every edit helper calls it directly, so a fader drag pays a full
O(tracks + clips) C-API pass per event — 15.9 ms per pass at 4,096 clips.

**What to build.** Distinguish structural from parameter revisions (either a small revision-kind value
returned by a new accessor, or separate counters). On a parameter-only change, `refresh()` takes a fast path
that updates gain/pan/mute (and only those fields) in the existing `TrackView`s and invalidates the mixer
strips, without calling `dalnok_track_count`/`dalnok_track_clip_at`/`dalnok_clip_info`/note readers. Coalesce
to at most one refresh per display frame. Keep the engine authoritative: any hint that is missing or stale
falls back to the full refresh.

**Acceptance / evidence.**
- Self-test and both-theme `--uiwalk` show no stale view after edits, undo and scripted changes.
- Measured: refresh pass at 4,096 clips, and the drag path's per-event cost, before/after.
- A test that a parameter edit performs zero clip reads (a debug counter around the C-API reads is fine);
  an unrelated track's mutation must not re-read untouched clips.

If the revision-kind accessor is added, it is a C-API addition: append, bump once, and update the Swift
mirror. Coordinate the version bump with Task 4 so there is a single bump to 30.

## Task 4 — A-14: make the snapshot handoff observable (S)

**Why.** `Engine::process` adopts a pending snapshot only when the 64-entry retire queue has space
(`engine.cpp:2302`). If the control thread stops collecting, edits silently stop taking effect and nothing
reports it. `swaps_` is counted but never surfaced or asserted.

**What to build.** Add control-thread-readable atomics: retired-queue depth and high-water mark, callbacks
since the last successful adoption (pending age), and adoption skips. Add a `size()`/`depth()` to
`SpscQueue` (`engine/src/rt.hpp`) if needed — reading both indices from the consumer is safe. Append the
fields to `DalnokStats` (`dalnok.h:753`), fill them in `Engine::stats` (`engine.cpp:2542`), reset them in
`resetStats`, and mirror them in Swift.

**Acceptance / evidence.**
- Test: stop calling `collectGarbage()` for 100 pumped callbacks, then assert the backlog is reported.
- Test: an edit made during playback becomes audible within N callbacks (state the N and assert it).
- `swift test` still green; `dalnok-cli` stats output still parses.
- Document the bound: if backlog can exceed N, either add the lock-free free-list (only if measured) or
  state the limitation in `CURRENT_STATE.md` honestly.

## After these four

If time remains, the next roadmap items are A-10 completion (libFuzzer targets, nightly seed corpus, sanitizer
in the default local check), A-16 (schema/migrations), A-18 (self-test split, injected clock/sample rate).
Do **not** start A-01, A-03, A-05, A-06, A-08 or A-09 — they are L/XL programmes and each needs its own design.

## Verification gates (run all; keep exit statuses visible)

```bash
swift build
swift test                     # note: may need --disable-sandbox outside a sandboxed shell
scripts/check.sh               # builds, tests, live audio smoke (needs an output device)
DALNOK_SANITIZE=1 scripts/check.sh
swift build -c release && .build/release/dalnok-cli audit-bench --tracks 16 --clips 256
.build/release/dalnok-cli audit-scale --tracks 16 --clips 256
.build/debug/Dalnok <generated-project> --uiwalk /tmp/walk   # both themes: DALNOK_THEME=warmAnalog
```

Also: rebuild the dashboard (`python3 docs/audits/dashboard/build.py`), re-check it headlessly at 1440 px in
both themes, and update `site/parity.json` only if a feature step's state changes.

## Traps that have already cost time

- `audit-scale --clips` means clips **per track**: `--tracks 16 --clips 256` is 4,096 clips; `--tracks 64
  --clips 1024` is 65,536 and looks like a hang while it runs. Budget for it, don't file it as a bug.
- Do not add a second denormal guard (A-12 landed) or "fix" autosave (A-02 already exists).
- Do not move plug-in instantiation off the main thread as part of A-01a; many plug-ins require it. That is
  A-08, and it needs a designed, measured activation queue.
- `Model` copies are the rollback mechanism; any replacement must keep failed edits atomic and must not
  expose half-applied state to `compile()`/`syncRuntimes()`.
- The app caches nothing; if you add a revision kind, make it a hint with a full-refresh fallback.
- Pre-existing warning `record.cpp:214` is not yours to chase unless it is trivially in the way.

## Definition of done

A-01a, A-03a, A-05a and A-14 are `fixed` in `findings.json` with a `resolution` that names the test and the
measured numbers; the roadmap's Phase 0/1/2 rows are updated; `swift test` passes with the new tests; the
benchmark file has before/after entries; `CURRENT_STATE.md`, `CHANGELOG.md` and the journal describe what
changed and what is still open; one commit on `fix/audit-followups`, not pushed.
