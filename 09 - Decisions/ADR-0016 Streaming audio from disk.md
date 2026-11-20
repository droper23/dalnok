---
status: accepted
date: 2026-11-19
---
# ADR-0016: Streaming audio from disk

**Context.** Every audio file was decoded completely into memory (audit A-09). An hour of stereo audio cost 1.39 GB
of RAM, and a long session could exhaust memory. The audio thread may not read files or allocate (Real-Time
Processing), so streaming cannot simply read on demand.

**Decision.**
- *Cache file.* A file longer than a threshold (default 60 s) is decoded once, in chunks, into a cache file at the
  engine's rate, in the user's cache directory. The file is named after the source path, size, modification time and
  rate. It holds a header, blocks of 32,768 frames (each channel's block in turn), and the waveform's base peak level
  (1,024-frame blocks, about 5 MB per stereo hour; coarser levels are built from it). Decoding never holds the whole
  file. The header is written last, so an interrupted decode is never mistaken for a complete cache, and reopening the
  project reuses the cache without decoding. Shorter files stay in memory, as before.
- *Block cache.* A process-wide cache holds at most a fixed budget of blocks (default 256 MB). Its disk thread looks
  at every engine's stream plan, refreshed on each commit: the streamed clip segments plus the playhead and delay
  compensation. It loads the next six seconds after each playhead first, then the first two blocks of every clip
  (so starts, seeks and launches are covered), and evicts least recently wanted blocks.
- *Audio thread.* `StreamSource::readResident` copies from resident blocks only, through a per-block atomic pointer
  table. A missing block plays as silence and is counted. A block is reused only after it has been unpublished and no
  reader is inside a copy (a seq_cst reader count), so the audio thread never takes a lock, reads a file or allocates.
- *Offline work.* Offline renders and exports lease (pin) the blocks each second needs before rendering it, so they use
  the same read path and never miss. The stretch worker and close-up waveform peaks read the cache file directly
  (they may block).

**Consequences.** Memory for audio is bounded by the budget plus peaks: one hour of stereo audio went from 1,390 MB
to under 50 MB peak RSS while playing. Streamed files need disk space for their decoded cache (about 690 MB per stereo
hour at 48 kHz) and take one decode pass to prepare. A seek far from the playhead can play up to a few milliseconds
of silence until its blocks arrive (none were missed in the tests). Launcher clips keep only their first blocks
resident ahead of a launch, so a long launched clip could miss blocks after its first 1.4 s. Cache files are not
cleaned up automatically yet.
