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
of silence until its blocks arrive (none were missed in the tests). Launcher clips originally kept only their first blocks
resident ahead of a launch, so a long launched clip could miss blocks after its first 1.4 s; see the amendment below.

**Amendment (2026-11-19): launched clips.** A slot's segment in the stream plan now carries its track's launcher state.
- While a slot plays, the disk thread prefetches its current loop and the next one from the slot's own start frame, the same position the renderer uses.
- A pending launch is prefetched from its launch frame.
- Test `Streaming/launchedStreamedSlotIsPrefetchedAlongItsLoop`: with a 2 MB budget, a 12 s streamed slot over 26 s of looping missed 660,480 frames before this change and 0 after, and is bit-exact against memory.

**Amendment (2026-11-19): cache-file cleanup.**
- Each long-file load keeps the cache directory within `DALNOK_STREAM_DISK_MB` (default 8 GiB, about 12 stereo hours) by deleting the least recently used cache files.
- Loading a cache file updates its modification time, which counts as use.
- The file just loaded is never deleted. A deleted file that some Media still has open stays readable through its descriptor until that Media is released; a later load decodes it again.
- Partial files left by a process that no longer exists are removed.
- Test: `Streaming/cacheDirectoryIsPrunedLeastRecentlyUsedFirst`.
