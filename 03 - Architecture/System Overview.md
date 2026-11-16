---
status: living
---
# System Overview

```
┌─────────────────────────── macOS app (Swift/AppKit) ─────────────────────────┐
│ MainWindow · TimelineView · TrackHeaders · Transport   (Session.swift mirror*) │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │  plain C API  engine/include/atrium/atrium.h
┌───────────────────────────────┴──────────── engine (C++20) ──────────────────┐
│ Control thread: session model ──compile()──▶ RenderState snapshot             │
│                       │ atomic slot ▲ SPSC retire queue                        │
│ Audio thread:  device callback ─▶ Engine::process ─▶ renderBlock (nonblocking) │
│ Any thread:    media decode (ExtAudioFile) · peak pyramid · offline render     │
│ platform/macos: Core Audio output, audio file I/O                              │
└──────────────────────────────────────────────────────────────────────────────┘
```
\* The UI mirror is temporary. M2 moves the authoritative project model and commands into the engine.

## Subsystem boundaries (target)
| # | Responsibility | Where | Status |
|---|---|---|---|
| 1 | Real-time execution | `engine.cpp` (`process`), `render.cpp` | implemented |
| 2 | Audio/MIDI processing graph | `render.cpp` (flat track sum today) | partial |
| 3 | Project/session model | engine (`Engine::tracks_/clips_`) plus UI mirror | partial |
| 4 | Timeline and arrangement logic | engine | partial |
| 5 | Plugin hosting | `engine/src/plugins/` (out-of-process later) | planned |
| 6 | Disk streaming and media | `media.*`, `platform/*/audio_file_*` | in-memory only |
| 7 | UI rendering | `app/macos/` | implemented (CoreGraphics; Metal later) |
| 8 | Commands, scripting, automation | engine command bus, exposed in C API | planned (M2) |
| 9 | Persistence, recovery, history | engine | planned (M3) |
| 10 | Intelligent assistance | separate non-RT service | future |

## Why a C API instead of Swift↔C++ interop
It's a stable ABI for any future front end (Windows or Linux UI, scripting, tests), it keeps engine
headers out of Swift compilation, and it forces a deliberate, small surface.
