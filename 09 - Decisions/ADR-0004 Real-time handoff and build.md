---
status: accepted
date: 2026-11-16
---
# ADR-0004: Snapshot handoff and the SwiftPM build
**Decision.** Structural session changes compile to immutable `RenderState` snapshots, which pass
through a single atomic slot. A retired state returns through a 64-entry SPSC queue and is freed on the
control thread. Continuous parameters are atomics. Everything is built with SwiftPM for now, and CMake
is added for the engine when the first non-macOS front end starts.
**Consequences.** The audio thread is wait-free and allocation-free. Compiling a snapshot is
O(tracks + clips) per structural edit, which is fine for thousands of clips. Revisit with incremental
compilation if profiling says so.
**Rejected:** a mutex around the model (priority inversion), a command queue that mutates audio-thread state (complex ownership).
