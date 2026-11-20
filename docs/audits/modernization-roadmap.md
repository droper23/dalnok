# Dalnok modernization roadmap (from the 2026-11 audit)

Companion to `codebase-audit-2026-11.md` and `findings.json`. Effort: S ≤ 1 day, M 2–5 days,
L 2–4 weeks, XL > 1 month. Priority follows the audit's P0–P3 scale.

The order is chosen so that **nothing here breaks existing behaviour**, each phase leaves the test
suite green, and later work depends only on earlier work that has landed.

---

## Phase 0 — Stop the bleeding (P0, ~2–3 weeks)

Do these before any new feature. They bound every other failure.

| Order | ID | Item | Effort | Depends on | Acceptance |
|---|---|---|---|---|---|
| 1 | A-02 | Autosave + project crash recovery | M | — | Kill -9 at any point; relaunch restores edits newer than one interval; saved file untouched |
| 2 | A-23 | Regenerate the capability matrix from tests | S | — | Every "works / not yet" row links a test, self-test check or benchmark |
| 3 | A-01a | Crash-safe boundary: pre-plug-in-init snapshot | S | A-02 | A plug-in crash during project apply loses no edits |
| 4 | A-01 | Out-of-process plug-in hosting (design → effects → instruments) | XL | A-02, A-01a | Crashing/hanging plug-in leaves app alive; pass-through nulls bit-exactly |

**Why this order:** autosave is the cheapest way to make every other risk survivable, and the
capability matrix must be trustworthy before contributors act on the audit. Out-of-process hosting is
XL and must not block the rest of the roadmap.

---

## Phase 1 — Make the model scale (P1, ~6–8 weeks)

The measured ceilings: 15.9 ms per UI read and 0.77 ms per structural edit at 4,096 clips, and a full
model copy per parameter edit.

| Order | ID | Item | Effort | Depends on | Acceptance |
|---|---|---|---|---|---|
| 5 | A-04a | Linear compile: bucket clips by track once | S | — | Compile no longer O(T×C); existing tests unchanged |
| 6 | A-03a | Parameter edits skip the model copy (coalesced undo) | M | — | Fader drag = one undo step, no copy; measured RSS flat |
| 7 | A-07 | Share plug-in state (immutable blobs) | S | A-03a | No byte copies of plug-in state on model copy |
| 8 | A-05a | Skip full refresh for parameter-only revisions | S | A-03a | Drag path does no model read; measured stall gone |
| 9 | A-05 | Change sets + incremental UI refresh | L | A-05a, A-15 | One-track edit re-reads only that track; 4,096 clips < 4 ms/frame |
| 10 | A-04 | Incremental snapshot compilation | M | A-04a | Incremental == full on randomised edits; < 0.2 ms at 4,096 clips |
| 11 | A-03 | Structurally shared undo model | L | A-03a, A-07 | 500-edit RSS reduced by ≥5x at 4,096 clips |

**Gate:** re-run `audit-scale` and `audit-bench`; publish before/after numbers in
`benchmarks/results.json`. No speedup claim without a measured run.

---

## Phase 2 — Reliability hardening (P1, ~4 weeks, partly parallel)

| Order | ID | Item | Effort | Depends on | Acceptance |
|---|---|---|---|---|---|
| 12 | A-08 | Async plug-in activation with progress/cancel/watchdog | L | A-01a | Slow fixture plug-in never freezes the UI |
| 13 | A-10 | libFuzzer targets + property tests + local sanitizer pass | M | — | 10-minute fuzz run clean; 1,000 random round-trips pass |
| 14 | A-14 | Handoff health metrics + test | S | — | Backlog observable; edit audible within N callbacks |
| 15 | A-16 | Project schema + migration chain + round-trip tests | M | A-10 | Versions 1–13 load; save/load stable |
| 16 | A-18 | Split self-test harness; inject clock and sample rate | M | — | Deterministic at 44.1/48 kHz; check count unchanged |

---

## Phase 3 — Structural clarity (P1/P2, ~6 weeks)

Do this **after** Phase 1, because the service boundaries are easier to see once edit/compile paths
are split.

| Order | ID | Item | Effort | Depends on | Acceptance |
|---|---|---|---|---|---|
| 17 | A-06 | Extract Transport, Recording, PluginHost, RenderCompiler, UndoStack services | L | Phase 1 | 188 tests unchanged; no file > ~1,200 engine lines |
| 18 | A-15 | Generate or bulk-load the C API model DTOs | L | A-05, A-06 | One definition per field; measured per-clip read cost down |
| 19 | A-19 | Split engine targets + build cache + compile_commands.json | M | A-06 | Adapter-only change rebuilds < 10 s; CI time down |
| 20 | A-17 | Inject theme values; enable live switching | M | — | Both themes pixel-identical; switch without relaunch |

---

## Phase 4 — Media and DSP headroom (P1/P2, ~8–12 weeks)

| Order | ID | Item | Effort | Depends on | Acceptance |
|---|---|---|---|---|---|
| 21 | A-09 | Disk streaming with block cache and guaranteed residency | XL | A-04 | 2-hour file plays, bounded RSS, zero dropouts, bit-identical renders |
| 22 | A-11 | Skip silent/no-op tracks per block | M | A-04 | 256-track/8-active costs near 8-track; bit-identical output |
| 23 | A-12 | Denormal/FP-environment guard | S | — | No decay-tail penalty; output unchanged above −140 dBFS |
| 24 | A-13 | SIMD for copy, fades, ramp, meters | M | A-11 | ≥25% live-path gain at 64–256 tracks (measured) |

---

## Phase 5 — Optional / speculative (P3, opportunistic)

| ID | Item | Effort | Note |
|---|---|---|---|
| A-20 | Central policy header for real-time constants | S | Do alongside any engine edit |
| A-21 | Error classes in the C API | S | Additive enum |
| A-22 | Decide the undo rule for view-only state | S | Product decision; document it |

---

## Dependency graph (text form)

```
A-02 ──► A-01a ──► A-01
  │                  │
  └──────────► A-08 ◄┘

A-04a ──► A-04 ──► A-11 ──► A-13
A-03a ──► A-07
   └────► A-05a ──► A-05 ──► A-15
                      │        │
                      └──► A-03 (needs A-03a, A-07)
A-10 ──► A-16
A-06 ──► {A-15, A-19}
```

Rules the roadmap enforces:

- Nothing in Phase 1 depends on A-01 (XL) or A-09 (XL), so slow programmes cannot stall quick wins.
- A-15 (C API generation) waits for A-05 because the change-set shape determines what the API should
  return.
- A-19 (build split) waits for A-06 because target seams follow service seams.
- A-09 (streaming) waits for A-04 so media residency assumptions are made against a stable snapshot.

## Milestones

1. **M-A "Cannot lose work"** — Phase 0 items 1–3. Recovery bounds the project-apply initialization window; in-process hosting and other crash windows remain open.
2. **M-B "Scale without jank"** — items 5–9. A 4,096-clip session edits and refreshes under a frame.
3. **M-C "Trustworthy failures"** — Phase 2. Plug-in faults, parse faults and formatting faults are
   contained and observable.
4. **M-D "Module shape"** — Phase 3. A new effect or importer touches one service.
5. **M-E "Long sessions"** — Phase 4. Hours of audio, bounded memory, DSP headroom.

## Verification discipline for every item

1. Do not claim a performance result without a before/after run of the same command on the same
   machine; append it to `benchmarks/results.json`.
2. Do not weaken an existing test to make a refactor pass; if a test must change, say why in the PR.
3. Keep `scripts/ci/rt-effects.sh` clean for anything reachable from the callback.
4. Update `site/parity.json` only with a test, self-test or benchmark behind the claim.

---

## Progress (2026-11-18, branch `fix/audit-followups`)

| Item | State | Evidence |
|---|---|---|
| A-01a pre-activation recovery | **Done** | `scripts/ci/plugin-recovery.sh`: crash and hang, full normalized-model comparison, normal and ASan; `scripts/ci/recovery-smoke.sh`; `preactivationRecoveryAndFailure` covers I/O status and rollback. Pending marker copies survive repeated crashes and clean quits; old/new selection is covered by self-test. Final full sanitizer check passed: 197 tests each under normal, ASan and TSan, plus live audio smoke and self-test |
| A-03a compact scalar undo | **Done** | 4,096 clips, 500 gain edits: p50 0.058 ms → <0.001 ms display precision; final RSS 302.6 → 34.5 MB. Group, failure and random full-undo tests; ADR-0012 |
| A-05a parameter refresh | **Done** | 4,096-clip AppKit audit: drag p50/p95/p99/max 27.771875/30.493334/31.077125/31.706958 → 0.025000/0.031333/0.033625/0.037625 ms; refresh 28.385333/29.191209/29.532209/29.715750 → 3.865959/3.934792/3.967375/3.967375 ms. Graphite, visible mixer, 30 warmups + 100 samples; tight-burst events, synchronous callbacks included, deferred drawing excluded. `scripts/check.sh` self-test verifies display-tick coalescing, unrelated-track zero clip reads, scripted edits, undo and same-frame Touch; final generated-project walks cover gain drag, undo and scripted change in both themes |
| A-14 handoff health | **Done** | Instrumented 100-callback test reaches depth 64 and 36 skips, verifies reset and adoption after collection; audible edit in one callback. A full queue has no finite adoption bound without collection |
| A-02 autosave + recovery | **Already implemented** (audit misread the timer) | `MainWindow.tick` snapshot every 30 s, launch prompt, `scripts/ci/recovery-smoke.sh`, self-test |
| A-04a linear compile | **Done** | 4,096 clips: structural 0.770 -> 0.255 ms, build 1,272 -> 527 ms, undo 0.745 -> 0.238 ms; 191 tests |
| A-04 incremental compile | **Done** | Per-track `TrackContent` reused when clip inputs are unchanged; random-edit equivalence test (4 seeds × 300 steps) via `dalnok_engine_snapshot_mismatches`. 4,096 clips: structural p50 0.238 → 0.163 ms, compile alone ≈0.149 → 0.098 ms, undo 0.257 → 0.173 ms |
| A-08 deferred plug-in activation | **Done (isolated)** | ADR-0013 + ADR-0014 stage 2: isolated plug-ins load in their hosts in parallel without blocking (C API 35). Slow fixture (sleeps in `initialize`): 3 × 1.5 s load in 1.52 s, worst activate call 1.1 ms, Stop 2.3 ms with no host left (`PluginIsolation`); GUI self-test with 3 × 4 s: worst main-thread gap 10.4/13.2 ms, Stop to done 143/158 ms. In-process (Safety off) still blocks per plug-in |
| A-07 shared plug-in state | **Done** | `SharedPluginState` blob; state round-trip and missing-plug-in suites pass |
| A-12 denormal guard | **Done** | FPCR.FZ / MXCSR FTZ|DAZ around live and offline render; subnormal test requires exact silence |
| A-10 fuzz/property tests | **Done** | `scripts/ci/fuzz.sh`: libFuzzer + ASan over the project reader and all importers; found and fixed a ZIP size-allocation bug and an FCPXML abort (regression tests). 10-minute run clean (834,391 inputs); 1,000 random save/load/save round-trips pass; parser suites always run under ASan in `scripts/check.sh` |
| A-05 change sets / incremental UI | **Done** | Per-track revisions (C API 33); Session re-reads only changed tracks; mixer parameter-only path. 4,096 clips: parameter refresh p50 ≈4.0 → 0.155 ms; one-track structural refresh 24.6 → 0.56 ms. Randomized revision property test, self-test re-read counts. Drawing/compositing still unmeasured |
| A-01 out-of-process hosting | **Stage 2** | ADR-0014: opt-in `dalnok-plughost` per instance; existing VST3/CLAP/delay-compensation suites pass isolated; crash and hang mid-session or while loading are contained, reported and reloadable; ≈34 µs per plug-in per block. Stage 2: isolated deferred loading (A-08), editors in a host-owned window (ADR-0015, test VST3 and AUDelay: engine tests and self-test). Shared per-callback deadline (3 hung plug-ins: worst callback 13.1 → 4.5 ms of a 10.67 ms period) and audio-workgroup membership (real device, join = 0, rejoins after restart). Default-on remains |
| A-03 structural undo | **Done** | Undo steps below the top become clip deltas against the state they will be applied to. 500 structural edits at 4,096 clips: RSS growth 268.9 → 3.3 MB; edit p50 0.274 → 0.299 ms, undo 0.27 → 0.36 ms. `UndoDeltas` random history (3 seeds) |
| A-23 status documentation | **Done** | capability table now links tests; C API references corrected to v29 |

The larger A-01 and A-03 programmes remain open; their smaller safety and performance steps do not establish crash isolation, structural sharing or incremental UI change sets. Other unfinished items remain as written above.
