# AGENTS.md — guidance for coding agents

Atrium (working name) is an open-source DAW: a portable C++20 engine behind a plain-C API, with a native
Swift/AppKit front end on macOS. GPL-3.0-or-later. This repo is also the project's Obsidian vault.

## Start here
1. Read `CURRENT_STATE.md`: what works, what doesn't, and the next task.
2. Read `03 - Architecture/System Overview.md` and `Real-Time Processing.md` before touching `engine/`.
3. Read the ADRs in `09 - Decisions/`, and don't contradict an accepted ADR without writing a new one.

## Layout
- `engine/include/atrium/atrium.h` is the only public engine surface. Keep it plain C, versioned with `ATRIUM_API_VERSION`.
- `engine/src/`: C++20 internals. `platform/macos/` holds the only OS-specific engine code.
- `app/macos/Atrium/` is the AppKit UI, which talks to the engine only through the C API.
- `tools/atrium-cli/` is a headless driver for smoke tests, rendering, and benchmarks.
- `tests/engine/` holds engine tests (Swift Testing, run through the C API).
- The numbered folders (`00 - …` to `12 - …`) are project documentation and Obsidian notes.

## Commands
- `swift build` and `swift test` for fast verification.
- `scripts/check.sh` builds, tests, and runs a live audio smoke test (needs an output device).
- `scripts/bundle.sh` creates `dist/Atrium.app`.
- `.build/debug/Atrium <files…> --snapshot out.png [--play]` renders the UI to a PNG for visual checks.

## Hard rules
- **Audio thread:** anything reachable from the device callback is marked `ATRIUM_NONBLOCKING`. Clang
  checks it at compile time, and violations are build errors. That code must never allocate, free, lock,
  do I/O, or throw. Data reaches the audio thread as immutable `RenderState` snapshots or atomics only.
- New engine features need a test with explicit numeric tolerances. Audio changes need an offline-render test.
- Never report a feature as working without evidence: test output, CLI output, or a snapshot.
- Dependencies must be permissive or system frameworks. Record each one in `04 - Research/Licensing.md`.
- Don't copy code or assets from proprietary DAWs. Workflows can inspire us, but implementations can't be copied.
- At session end, update `CURRENT_STATE.md`, `CHANGELOG.md`, and `10 - Development Journal/`, then commit.
