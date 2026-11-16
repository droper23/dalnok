---
status: accepted
date: 2026-11-16
---
# ADR-0006: Import from other DAWs

**Context.** The owner wants first-class onboarding and migration from Logic, Ableton, and REAPER,
built now and extended as Dalnok gains MIDI (Phase 3) and plugins (Phase 4).

**Decision.**
1. **Importers live in the engine** (`engine/src/import/`, C++, portable, scriptable via
   `dalnok-cli import`). Each one translates a foreign project into a **Dalnok project document**
   plus a **migration report**, and then reuses the normal loader. Offline media, sample-rate
   conversion, and background loading work for imports for free.
2. **Supported formats:**
   - REAPER `.rpp` (text)
   - Ableton `.als` (gzip XML via zlib + pugixml, MIT)
   - Final Cut Pro XML (Logic's documented export)
   - folders of stems
   - Logic `.logicx`, direct and **experimental**
3. **Honest reports.** Anything not imported is counted by reason (MIDI, plugins, automation, warped
   clips needing stretch, take lanes, …), so users know exactly what to check.
4. **Media relocation** searches the original path, the project-relative path, Live's path types
   (project, User Library, packs, built-ins), the longest shared path tail under ancestor folders
   (moved archives), and finally the file name.
5. **Clip gain** was added to the engine, because every source DAW has it.

**Logic reverse engineering (owner's choice).** We read only the user's own files, for
interoperability, and write independent code. Public notes are used as facts (MIT-licensed spec).
Nothing GPL-incompatible is copied. The format changes between Logic versions, so the importer
validates its framing and falls back to guidance ("export Final Cut Pro XML") when unsure.

**Consequences.** Real-file results (local, read-only):
- **REAPER:** 6/6 projects, all media found.
- **Ableton:** 493/495 sets (the 2 failures aren't Live sets). 95% of 6,929 referenced audio files resolved.
- **Logic:** 30/31 parse. Region data is verified; placement isn't yet.

Time-stretch (Signalsmith) becomes a high priority: about 6,000 warped Ableton clips and many REAPER
rate-changed items can't play correctly without it.
