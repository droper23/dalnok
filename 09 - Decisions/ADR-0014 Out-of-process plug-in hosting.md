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
- *Rollout.* Off by default behind a setting until it has been verified on the owner's plug-in library. Editors
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
