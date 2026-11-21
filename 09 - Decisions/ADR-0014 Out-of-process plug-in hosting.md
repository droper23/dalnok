---
status: accepted
date: 2026-11-19
---
# ADR-0014: Out-of-process plug-in hosting

**Context.** Third-party plug-ins run inside Dalnok, so one crash ends the app and one hang freezes it (audit A-01,
P0). ADR-0009 already scans each plug-in in its own process; A-01a and ADR-0013 bound the damage at project load
but contain nothing at run time.

**Decision.** Each hosted plug-in instance can run in its own `dalnok-plughost` process, built from the engine
library so it reuses the VST3, Audio Unit and CLAP hosts unchanged. Built-in plug-ins stay in-process.

- *Audio.* A shared-memory block per instance carries one audio block each way, plus sidechain, notes and
  block-rate automation. The engine's audio thread writes the inputs, bumps a request counter and wakes the host
  (`os_sync_wake_by_address_any`, shared). It then waits for the done counter, with a timeout of 40 % of the block
  period. Processing stays in the same block, so isolation adds no latency. If the host is late, the block passes
  through dry (effects) or silent (instruments). While the host is still busy, no new request is issued, so the
  host never reads a buffer being rewritten. The host's processing thread uses a time-constraint scheduling policy.
- *Control.* State, parameters, parameter text, latency and the frequency response go over a socket pair as
  length-prefixed requests with a timeout. The host serves them on its main thread, inside a run loop, because
  VST3 and CLAP require it.
- *Failure.* A host that exits, crashes or misses its deadlines repeatedly marks the instance failed. Its slot
  shows the reason, the track keeps playing dry, and Load restarts it from the last saved state. The project and
  the app are unaffected.
- *Rollout.* Off by default behind a setting until it has been verified on the owner's plug-in library (on by
  default since 2026-11-20; see the end of this record). Editors
  are not hosted out of process in this first stage: a plug-in's window would belong to the host process, which
  needs its own design (remote layers or a host-owned window). Isolated instances offer the generic parameter
  panel only.

**Consequences.** A crash or hang in an isolated plug-in costs that plug-in, not the session. Each instance costs
a process (tens of MB) and two context switches per block. Measured overhead is recorded in the audit benchmarks.
Plug-ins whose editors are needed run in-process until editor hosting lands.

**Stage 2 amendment (2026-11-19).** Deferred activation (ADR-0013) no longer waits for an isolated plug-in: each
`dalnok_plugins_activate_next` call collects one host that has answered, or starts up to four hosts and returns. The
saved state travels with the start request and the host restores it before answering, so neither initialization nor
restoring runs on the engine's thread. Stop kills hosts still loading. A host's crash handler reports the signal over
the control socket at once, because the system crash reporter can hold a dying process for seconds. With isolation
on, a plug-in that blocks its own initialization no longer blocks the window (A-08 closed for isolated plug-ins).

**Editors (2026-11-19).** Isolated instances now show their editors in a window owned by the host process; see
ADR-0015. The stage 1 "parameter panel only" restriction no longer applies.

**Real-time amendment (2026-11-19).** *One budget per callback:* every isolated plug-in in a live callback shares one
deadline, 40 % of the callback's period from its start (`Scratch::deadlineNs`). Once the budget is spent, the rest pass
dry (effects) or silent (instruments) for that block without issuing a request. These budget skips are never counted
towards "stopped responding". *Audio workgroup:* the host's processing thread joins the running device's I/O workgroup.
At spawn the engine registers a send right to a rendezvous port in the host (`posix_spawnattr_set_registered_ports_np`,
exported by libSystem but undeclared in the SDK, so it is looked up at run time and its absence costs only membership).
The host answers with its own port. On every device start, change or stop, the engine sends it the workgroup's port
(`os_workgroup_copy_port`), and the processing thread leaves the old workgroup and joins the new one
(`os_workgroup_create_with_port`, `os_workgroup_join`) before its next block. The host answers the rendezvous only when
told to (`--rendezvous`), because otherwise it would hold ports inherited from the engine's own process.

**Default-on decision (2026-11-20): Safety stays opt-in.** Verified on the owner's plug-in library with real OS input
and on 24 of the owner's Logic projects (imported from clones; nothing derived from them is in the repository).
`dalnok-cli load-bench` opens a project as the app does and then plays 5 s of live blocks paced at the device period.

- *What isolation already does better.* All 24 projects load every plug-in in both modes, and none opens marked edited.
  The worst single call on the main thread while loading: in-process 281–1,903 ms (median ≈1.1 s, the plug-ins'
  own initialization); isolated 0.7–16 ms in 23 projects and 95 ms in one. Loading is faster isolated in 20 of 24
  (hosts start in parallel). Renders isolated and in-process are bit-identical, or differ only within a plug-in's own
  run-to-run nondeterminism. Editor windows, keys, save prompts, crashes and hangs behave as designed.
- *What blocks the default.* Isolated plug-ins run one after another inside a single budget of 40 % of the callback
  period (4.27 ms at 512 frames, 48 kHz). In 7 of the 24 projects the plug-ins' own processing in series costs more
  than that (in-process mean block cost 3.8–16.5 ms), and isolated, 29–97 % of blocks were missed by at least one
  plug-in, which then passes dry or silent; 2 more projects missed 1–6 %. Those projects would audibly drop plug-ins. Raising the budget only moves the line: it must also leave the
  rest of the graph its time.
- *Required before default-on.* (1) Process isolated plug-ins on independent tracks concurrently: issue every request
  whose inputs are ready, then wait, so the budget covers the longest chain rather than the sum (hosts already run on
  their own cores and join the device's workgroup). Measure with `load-bench` on the same 24 projects: 0 budget skips
  where in-process keeps up. (2) Re-check the one project with a 95 ms load call.
- *Migration note for when it is on by default.* Existing projects need no change: the saved state is the same in
  both modes. Settings ▸ Plug-ins ▸ Safety stays as the off switch, and a plug-in that fails isolated keeps its state
  and can be reloaded in-process.

Stress (release build): 64 isolated instances of one effect load in 2.5 s (worst call 6.4 ms), take 22.6 MB per host
(1.45 GB in all) and cost about 54 µs per instance per block (mean block 4.11 ms vs 0.66 ms in-process; 0 misses, one
block over the period), so the per-block overhead alone also approaches the shared budget at that count. A real project
opened and closed 10 times isolated: all 33 plug-ins every time, 3.3–3.5 s, worst call 4–9 ms, never edited, no host left
running. A host killed during playback: reported as crashed with Load to restart it, playback continued, no host left.

Found and fixed during this verification (each with a test): isolated editors stayed on another Space; a re-entrant
fit crashed a host on an Apple sampler's editor; sending multi-megabyte saved states blocked the main thread for up to
1.2 s (macOS ignores MSG_DONTWAIT on the socket pair); VST3, AU and CLAP reports made with no editor open marked
projects edited; a host crashing during playback marked the project edited.

**Default-on (2026-11-20, same day, superseding "stays opt-in" above): Safety is on by default.** Both blockers are
fixed, measured with `dalnok-cli load-bench` on the same 24 projects. `load-bench` now runs the main run loop between
blocks, as the app does. Before, it slept, which hid main-thread work that plug-ins schedule and made in-process
playback look better than it is.

- *Parallel processing.* Isolated plug-ins on different tracks are started together and collected in order
  (`beginProcess`/`finishProcess`, rounds in `renderBlock`), so the 40 % budget covers the longest chain, not the
  sum. The 7 projects that missed 29-97 % of blocks now miss none.
- *Warm-up.* A host processes 0.75 s of silence before it reports ready (live hosts only; offline renders start
  cold so they stay deterministic). Some plug-ins do one-off work a moment of audio after loading. In one project
  it caused every first play to skip blocks; now it doesn't (`hostWarmUpAbsorbsOneOffStartUpWork`: 3 missed
  without, 0 with, about 40 ms more loading).
- *No waiting on hosts from the main thread.* Edit counts and latency are published in the shared block, and
  automation ranges are cached per instance. Asking each host for its latency on every snapshot compile waited on
  that host's main thread: 47-132 ms main-thread blocks while loading, also after ordinary edits.
  `pollingEditsNeverWaitsOnABusyHost`: worst structural edit 0.42 ms with a host whose main thread sleeps 200 ms
  at a time.
- *Results (release, quiet machine).*
  - Every plug-in loads in all 24 projects, and none opens marked edited.
  - The worst main-thread call while loading isolated is at most 13 ms in every project. In-process it is
    0.28-1.7 s.
  - Loading is faster isolated in 23 of 24 projects.
  - No isolated block runs over the period. One earlier run had two 32 ms blocks in one project; three reruns
    didn't reproduce them. In-process, 4 projects have blocks over it: one runs over in all 302
    of its blocks, and three have a single 21-124 ms block.
  - 22 projects miss no isolated blocks. The other 2 miss 6-13 blocks in total, once, about 0.4 s into play.
    That is one sampler's script doing about 36 ms of work on its audio thread. In-process, the same work stalls
    the whole output for 70-124 ms; isolated, only that track drops, briefly.
- *Known limit.* Isolated hosts are more sensitive to a busy machine than in-process plug-ins, because each block
  must wake another process within the budget. During one run, other work drove the load average to 5-14, and 10 of
  the 24 projects missed blocks; the worst had 762 misses and skips across 13 plug-ins in 5 s. The same build
  rerun right afterwards, interleaved with the previous one, missed none in those projects. Joining the device's
  audio workgroup (live only, ADR-0014 workgroups) is what protects hosts in the app. `load-bench` has no device,
  so it measures the unprotected case.
- *Migration note.* Nothing in a project changes: saved state is identical in both modes. On first launch of 0.2,
  third-party plug-ins load isolated unless the user had turned Safety off (an explicit choice, either way, is
  kept). Settings ▸ Plug-ins ▸ Safety is the off switch, and it applies to plug-ins loaded afterwards. A plug-in
  that fails isolated keeps its state and can be reloaded. Built-in plug-ins always run in-process.
