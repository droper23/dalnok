---
status: living
---
# System Overview

```
┌─────────────────────────── macOS app (Swift/AppKit) ─────────────────────────┐
│ MainWindow · TimelineView · TrackHeaders · Transport · Session (read-only view)│
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │  plain C API  engine/include/dalnok/dalnok.h
┌───────────────────────────────┴──────────── engine (C++20) ──────────────────┐
│ Control thread: commands ─▶ Model (+undo) ──compile()──▶ RenderState snapshot  │
│                 command catalog (JSON) · media pool · project load/save        │
│                       │ atomic slot ▲ SPSC retire queue                        │
│ Audio thread:  device callback ─▶ Engine::process ─▶ renderBlock (nonblocking) │
│ Any thread:    media decode (ExtAudioFile) · peak pyramid · offline render     │
│ platform/macos: Core Audio output, audio file I/O                              │
└──────────────────────────────────────────────────────────────────────────────┘
```
The engine owns the model. The UI re-queries it whenever `dalnok_model_revision` changes. See [[ADR-0005 Project model and commands]].

## Subsystem boundaries (target)
| # | Responsibility | Where | Status |
|---|---|---|---|
| 1 | Real-time execution | `engine_audio.cpp` (`process`), `render.cpp` | implemented |
| 2 | Audio/MIDI processing graph | `render.cpp` (flat track sum today) | partial |
| 3 | Project/session model | `engine.hpp` `Model`, `PoolEntry` | implemented |
| 4 | Timeline and arrangement logic | engine | partial |
| 5 | Plugin hosting | `engine/src/plugins/` (out-of-process later) | planned |
| 6 | Disk streaming and media | `media.*`, `platform/*/audio_file_*` | in-memory only |
| 7 | UI rendering | `app/macos/` | implemented (CoreGraphics; Metal later) |
| 8 | Commands, scripting, automation | `commands.cpp` catalog + `dalnok_command_run` | implemented (no scripting host yet) |
| 9 | Persistence, recovery, history | `project.cpp`, snapshot undo | save/load/undo done; autosave planned |
| 10 | Intelligent assistance | separate non-RT service | future |

## Why a C API instead of Swift↔C++ interop
It's a stable ABI for any future front end (Windows or Linux UI, scripting, tests), it keeps engine
headers out of Swift compilation, and it forces a deliberate, small surface.

## Engine source layout (A-06, 2026-11-19)
`Engine` (engine.hpp) is the facade the C API calls. Its state and logic are split by concern:
- `plugin_service.*`: `PluginHostService`, which owns plug-in instances, load errors, deferred and isolated activation,
  offline copies, the device workgroup for isolated hosts, and their health.
- `undo_stack.*`: `UndoStack`, which owns undo and redo, groups, compact parameter steps and clip-delta compaction.
- `engine.cpp` (model edits: tracks, MIDI, markers, routing, plug-in slots, mixer), `engine_clips.cpp`, `engine_takes.cpp`,
  `engine_launcher.cpp`, `engine_device.cpp` (devices, capture, workgroup), `engine_compile.cpp` (RenderState snapshots),
  `engine_audio.cpp` (the real-time path), `engine_offline.cpp` (offline render, export, stats).
- `engine_internal.hpp`: helpers shared by those files, and the `edit()` template every edit goes through.
- `stream_cache.*` and `media.*`: long files stream from disk through a bounded block cache (ADR-0016).
