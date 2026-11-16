# Licensing

**Project license: GPL-3.0-or-later** (owner decision, 2026-11-16, [[ADR-0002 License]]).

## Dependency policy
Only permissive (MIT, BSD, ISC, zlib, MPL-2.0, Apache-2.0) or OS-provided dependencies, so that
relicensing stays possible while there are no outside contributors. GPL-only libraries such as Rubber
Band are allowed only as optional, clearly isolated components after an ADR.

## Current dependencies
| Dependency | License | Use |
|---|---|---|
| Apple AudioToolbox, CoreAudio, CoreFoundation, AppKit | System | Device I/O, decoding, plists, UI |
| pugixml 1.14 (vendored in `engine/third_party/pugixml`) | MIT | XML parsing for Ableton and FCPXML import |
| zlib (system `libz`) | zlib | Decompressing Ableton `.als` |

## Planned
| Dependency | License | Use |
|---|---|---|
| VST3 SDK 3.8+ | MIT | Plugin hosting (Phase 4) |
| CLAP | MIT | Plugin hosting |
| Signalsmith Stretch | MIT | Time and pitch |
| DAWproject | MIT | Interchange |

Third-party plugins are never bundled. "VST" trademarks are used only per Steinberg's guidelines.
