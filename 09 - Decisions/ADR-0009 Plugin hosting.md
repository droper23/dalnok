---
status: accepted
date: 2026-11-16
---
# ADR-0009: Plugin hosting

## Context
Most instruments and effects that Dalnok users rely on are third-party plugins. The owner's stated priority is
that plugins are the main source of instruments, so stock instruments stay minimal (Dalnok Poly only) and hosting
matters more than a stock library. Plugins also run untrusted native code: one bad plugin must never take
the project with it. The audio thread is checked at compile time (`DALNOK_NONBLOCKING`), but plugin code cannot be.
The VST3 SDK (MIT since 3.8) and CLAP (MIT) are permissive; Audio Units are a system framework.

## Decision
- **Formats in order:** VST3, then Audio Units (v2 through AudioToolbox, v3 through AVFoundation), then CLAP. One
  internal `Processor` interface (process block, parameters, state, latency, bus layout) with one adapter per format.
- **Discovery is two-stage.** Stage 1 (implemented, `plugins.cpp`) reads only metadata: VST3 `moduleinfo.json`
  and bundle `Info.plist`, CLAP bundle metadata, and the Audio Unit component registry. It never loads plugin code.
  Stage 2 (implemented, `tools/dalnok-scan`, `validatePlugins`) loads each bundle in a separate `dalnok-scan` helper process with a timeout, caches the
  result by path, modification time and version, and puts crashing or hanging plugins on a visible "failed" list.
  A scan crash must never affect the app.
- **Processing starts in-process.** Plugins run on the audio thread inside an instrument slot or an insert chain,
  called through one explicit boundary where the nonblocking check is suppressed. The engine measures each plugin's
  processing time and reports overruns per plugin. Out-of-process hosting for individual plugins (crash isolation at
  the cost of a buffer of latency) is a later option, not the default.
- **Instrument tracks** keep one instrument slot: Dalnok Poly or a plugin instrument. MIDI from clips and live
  input reaches it the same way as today. Effects form an insert chain per track, then per bus when buses exist.
- **Parameters and state.** Every plugin gets a generic, searchable parameter panel (an owner priority); the
  plugin's own editor opens in a separate window when available. Parameter changes from the UI reach the audio
  thread through bounded lock-free queues; automation will use the same path. Plugin state is saved in the project
  as a base64 chunk with format, identifier and version, and a missing plugin keeps its state so nothing is lost.
- **Latency** reported by plugins feeds delay compensation (Phase 4). Until compensation exists, latency is shown.
- Loading, unloading and replacing a plugin are undoable engine commands with catalog entries, like every other edit.

## Verification gates
1. Metadata scan: generated fixtures (instrument, effect, missing metadata, nested bundles) and a real-system count.
2. Helper-process scan: a deliberately crashing and a hanging test plugin end up on the failed list and the app
   keeps running; cached results are reused until a bundle changes.
3. A passthrough test plugin nulls bit-exactly against the dry signal; offline renders are deterministic.
4. State round-trip through save and reopen; a missing plugin keeps its state.
5. Load, unload and parameter changes during playback under ASan and TSan; per-plugin overrun reporting.
6. At least one real VST3 instrument and effect from the owner's installed set, checked manually and recorded.

## Consequences
Hosting work starts with the scanner helper and the VST3 adapter. Until gate 2 passes, the plugin list may show
"unknown" kinds for bundles without metadata (211 of 217 bundles on the development machine). Stage 1 is
discovery only: Dalnok cannot load or play a plugin yet.
