# Licensing

**Project license: GPL-3.0-or-later** (owner decision, 2026-11-16, [[ADR-0002 License]]).

## Dependency policy
Only permissive (MIT, BSD, ISC, zlib, MPL-2.0, Apache-2.0) or OS-provided dependencies, so that
relicensing stays possible while there are no outside contributors. GPL-only libraries such as Rubber
Band are allowed only as optional, clearly isolated components after an ADR.

## Current dependencies
| Dependency | License | Use |
|---|---|---|
| Apple AudioToolbox, CoreAudio, CoreMIDI, CoreFoundation, AppKit, AVFoundation | System | Device I/O, MIDI input, Audio Unit discovery and tags, decoding, plists, UI, microphone permission |
| pugixml 1.14 (vendored in `engine/third_party/pugixml`) | MIT | XML parsing for Ableton and FCPXML import |
| zlib (system `libz`) | zlib | Decompressing Ableton `.als` |
| Signalsmith Stretch 1.4.0 + Signalsmith Linear 0.6.6 (vendored in `engine/third_party/signalsmith`) | MIT | Time-stretch and pitch shift |
| Apple Accelerate | System | FFTs for Signalsmith; the engine's mix kernels (vDSP, A-13; platform/macos/vec_accelerate.cpp) |
| Sora (Regular, SemiBold), Geist Mono (Light, Regular, Medium) | SIL OFL 1.1 | Prism's label and figure faces (`app/macos/Dalnok/Resources/Fonts`, static instances cut from the variable fonts; no Reserved Font Names) |
| IBM Plex Sans Condensed (Regular, Medium, SemiBold), IBM Plex Mono (Regular, Medium) | SIL OFL 1.1 | Atelier's label and figure faces (unmodified files; "Plex" is a Reserved Font Name, so they are never altered or renamed) |
| Source Serif 4 (16 pt Regular, SemiBold, Italic; 48 pt Regular) | SIL OFL 1.1 | Atelier's titles, notes and clock (static instances of the variable font; no Reserved Font Names) |

SIL OFL fonts are bundled with their licence files (`OFL-*.txt` beside them). The OFL permits bundling with any
software, GPL included, as long as the fonts aren't sold on their own; modified versions (our static instances) must not
use a Reserved Font Name.

## Planned
| Dependency | License | Use |
|---|---|---|
| VST3 plugin interfaces (`vst3_pluginterfaces` v3.8.1_build_84, vendored in `engine/third_party/vst3`) | MIT | Plugin scanning and hosting (Phase 4) |
| CLAP headers 1.2.9 (vendored in `engine/third_party/clap`) | MIT | Plugin scanning and hosting |
| Signalsmith Stretch | MIT | Time and pitch |
| DAWproject | MIT | Interchange |

Third-party plugins are never bundled. "VST" trademarks are used only per Steinberg's guidelines.
