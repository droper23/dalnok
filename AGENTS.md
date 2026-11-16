# AGENTS.md — guidance for coding agents

Dalnok is an open-source DAW: a portable C++20 engine behind a plain-C API, with a native
Swift/AppKit front end on macOS. GPL-3.0-or-later. This repo is also the project's Obsidian vault.

## Start here
1. Read `CURRENT_STATE.md`: what works, what doesn't, and the next task.
2. Read `03 - Architecture/System Overview.md` and `Real-Time Processing.md` before touching `engine/`.
3. Read the ADRs in `09 - Decisions/`, and don't contradict an accepted ADR without writing a new one.

## Layout
- `engine/include/dalnok/dalnok.h` is the only public engine surface. Keep it plain C, versioned with `DALNOK_API_VERSION`.
- `engine/src/`: C++20 internals. `platform/macos/` holds the only OS-specific engine code.
- `app/macos/Dalnok/` is the AppKit UI, which talks to the engine only through the C API.
- `tools/dalnok-cli/` is a headless driver for smoke tests, rendering, and benchmarks.
- `tests/engine/` holds engine tests (Swift Testing, run through the C API).
- The numbered folders (`00 - …` to `12 - …`) are project documentation and Obsidian notes.

## Commands
- `swift build` and `swift test` for fast verification.
- `scripts/check.sh` builds, tests, and runs a live audio smoke test (needs an output device).
  `DALNOK_SANITIZE=1 scripts/check.sh` also runs the engine tests under ASan and TSan (CI always does).
- `scripts/bundle.sh` creates `dist/Dalnok.app`.
- `.build/debug/Dalnok <files…> --snapshot out.png [--play]` renders the UI to a PNG for visual checks.
- `.build/debug/Dalnok <files…> --selftest <dir>` drives real menus and synthesized drags end to end.
  Extend `app/macos/Dalnok/SelfTest.swift` for every new UI interaction.
- `.build/debug/dalnok-cli commands`, `command <proj> <name> '<json>' [--save]`, `render-project`,
  `bench --tracks N` (release build for meaningful numbers).
- `scripts/ci/rt-effects.sh` runs the real-time effect analysis (uses Homebrew LLVM on CI).
- `Dalnok <audio files> --screenshots site/screenshots` regenerates the parity-page screenshots from the real app.
- `scripts/publish-site.sh` publishes `site/` (only) to the public repo `droper23/dalnok-status` (GitHub Pages).

## Hard rules
- **Audio thread:** anything reachable from the device callback is marked `DALNOK_NONBLOCKING`. Clang
  checks it at compile time, and violations are build errors. That code must never allocate, free, lock,
  do I/O, or throw. Data reaches the audio thread as immutable `RenderState` snapshots or atomics only.
- **Model:** every mutation is an `Engine::edit` command (undoable), and every user-visible action also gets
  a catalog entry in `commands.cpp`. Front ends never cache model state; they re-query on revision change.
- New engine features need a test with explicit numeric tolerances. Audio changes need an offline-render test.
- Never report a feature as working without evidence: test output, CLI output, or a snapshot.
- Dependencies must be permissive or system frameworks. Record each one in `04 - Research/Licensing.md`.
- Menu shortcuts without a modifier key must never steal typed text. `MainMenu` passes them through while a
  field is being edited. Keep the self-test check when adding shortcuts.
- Don't copy code or assets from proprietary DAWs. Workflows can inspire us, but implementations can't be copied.
- At session end, update `CURRENT_STATE.md`, `CHANGELOG.md`, and `10 - Development Journal/`, then commit.
- **Parity page:** when a feature step changes state, update `site/parity.json`. Mark a step `verified`
  only with a test, self-test, or benchmark behind it, and `implemented` if it's built but unproven.
  Publish at each milestone. Never publish anything outside `site/`.
