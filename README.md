# Dalnok

An open-source digital audio workstation for macOS (and later Windows and Linux). The goal is pro-grade
recording, editing, and mixing in a fast, focused native app.

> **Feature parity tracker:** https://droper23.github.io/dalnok-status/
>
> **Status: pre-alpha, Phase 1.** It imports audio files, shows their waveforms, plays them back with
> per-track gain, pan, and mute, and renders to WAV from the CLI. See [CURRENT_STATE.md](CURRENT_STATE.md).

## Build & run (macOS 14+, Apple Silicon)
```sh
xcode-select --install        # or a full Xcode 16+ install
swift build                   # engine + app + CLI
swift run Dalnok              # launch; drop audio files on the window or press ⌘I
swift test                    # engine test suite
scripts/check.sh              # build + tests + live audio smoke test
scripts/bundle.sh             # dist/Dalnok.app
```
No third-party dependencies are needed for the current build.

## Architecture in one paragraph
A C++20 engine (`engine/`) owns the real-time audio path, media decoding, and offline rendering, and
exposes a small C API (`engine/include/dalnok/dalnok.h`). The macOS UI (`app/macos/`) is native AppKit.
The audio callback is checked for real-time safety at compile time (`[[clang::nonblocking]]`). Details are
in [`03 - Architecture/System Overview.md`](<03 - Architecture/System Overview.md>).

## License
GPL-3.0-or-later. See [LICENSE](LICENSE) and [`04 - Research/Licensing.md`](<04 - Research/Licensing.md>).
