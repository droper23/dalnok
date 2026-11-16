# Technology Decisions (summary)

| Area | Choice | Why | ADR |
|---|---|---|---|
| Foundation | Independent engine on permissive libraries | Ownership. VST3 being MIT removes the GPL lock-in | [[ADR-0001 Foundation]] |
| License | GPL-3.0-or-later | Keeps the project and forks open | [[ADR-0002 License]] |
| Engine language | C++20 | VST3 and DSP ecosystem, compile-time real-time effect checks | [[ADR-0003 Language and UI]] |
| macOS UI | Swift + AppKit (Metal for heavy views later) | Native feel and performance | [[ADR-0003 Language and UI]] |
| Engine ↔ UI | Plain C API | Stable ABI for any front end and for scripting | [[ADR-0003 Language and UI]] |
| Build | SwiftPM (CMake added when non-macOS front ends start) | One tool for now, matches the RAV4-HeadUnit convention | [[ADR-0004 Real-time handoff and build]] |
| RT handoff | Immutable snapshots + atomic slot + SPSC retire queue | Wait-free audio thread | [[ADR-0004 Real-time handoff and build]] |
| Docs | Repo is the Obsidian vault | One copy of every document | — |
