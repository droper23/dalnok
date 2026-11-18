---
status: accepted
date: 2026-11-18
---
# ADR-0011: Built-in plug-ins for Logic compatibility

## Context
The owner wants Logic projects to import into Dalnok and sound identical. Logic's own processors (Channel EQ, Limiter, Chorus, ChromaVerb, ChromaGlow, Drum Kit Designer and others) are compiled into Logic's private `MADSP.framework`. They aren't Audio Units, so no other host can load them. Owner decisions (2026-11-18):
- Dalnok gets its own suite of plug-ins that sound like these.
- Logic may be disassembled to learn how they work.
- Apple's installed samples may be used at runtime, with a fallback on other systems.
- The bar is an exact null where feasible, otherwise indistinguishable.

ADR-0009 deliberately kept stock processing minimal and favoured hosting third-party plug-ins. This ADR adds a narrowly scoped exception: processors whose job is compatibility with another DAW's projects.

## Decision
- **A fourth plug-in format, `dalnok`.**
  - Slots have `format: "dalnok"`, and `path` is the plug-in id (`channel-eq`). `dalnok_plugin_add` accepts `"dalnok:<id>"`.
  - The processors live in `engine/src/fx/`. They are portable C++ with no OS framework, and they run in-process: the code is ours, so ADR-0009's isolation concerns don't apply.
- **Same interface as hosted plug-ins.** They implement `PluginProcessor`, so the device panel, automation, bypass, offline render, save/load and undo all work unchanged.
  - `BuiltinProcessor` supplies a fixed parameter table (normalized 0–1 at the API, plain values in state), JSON state (`{"plugin", "version", "values": {id: value}}`) and lock-free parameter delivery.
  - Built-ins have no custom editor; the generic parameter view is their UI.
- **Parameter ids equal the source DAW's parameter slots.** For example, Dalnok Channel EQ ids are the indices of Logic's saved float block. The importer copies values without translation tables, and the research notes and the code use the same numbering.
- **Real-time:** `process` is `DALNOK_NONBLOCKING`. Coefficients are recomputed on the audio thread when parameters or automation change. That code calls libm (`sin`, `tan`, `pow`, `log10`), which neither allocates nor locks, and is allowed through a documented `-Wfunction-effects` exception. Anything else stays checked.
- **Clean implementation:** formulas are re-expressed in our own code. Apple code and data tables are never copied. Each behaviour is verified by null tests against Logic renders (`tools/logic-parity/`) and pinned by offline-render engine tests against an independent reference.
- **Naming:** our own names ("Dalnok Channel EQ"), and "compatible with Logic projects" in descriptions. No Apple names or artwork.
- **Project format 13** marks documents that use built-ins, so older Dalnok builds refuse them instead of dropping the plug-ins.

## Consequences
- Imported Logic projects can be edited in Dalnok with the same controls they had in Logic.
- Every built-in carries a verification status. The import report states what is exact and what is not yet verified.
- Sample-based instruments (Drum Kit Designer) read Apple content from the local Logic library only and need a bundled fallback kit for other systems. That will be a separate decision once the instrument is designed.
