---
status: research (experimental importer)
date: 2026-11-16
logic-version: Logic Pro Creator Studio 12.2 (6644)
---
# Logic ProjectData format: our findings

Interoperability research on the user's own projects (read-only). No Apple code or assets were used.
Facts were cross-checked against public notes, with the MIT-licensed
[LogicProFormatWriter](https://github.com/jonkubis/LogicProFormatWriter) spec used as facts only.
Our parser (`engine/src/import/logic.cpp`) is independent code.

## Package
`Song.logicx/Alternatives/000/ProjectData` (binary), `…/MetaData.plist` (tempo `BeatsPerMinute`,
`SampleRate`, `SongKey`, `SongGenderKey`, signature, `NumberOfTracks`, `AudioFiles`),
`Resources/ProjectInformation.plist` (`LastSavedFrom`), and `Media/Audio Files/`.

## Framing ✅ verified (30/30 projects walk exactly to EOF)
- **File header:** 24 bytes. Magic `23 47 C0 AB`. The u64 at +16 = file size − 24.
- **Chunks:** a reversed FourCC (`gRuA` = AuRg), then 24 header bytes, then a u64 LE payload length (36-byte
  header in total), then the payload. The u32 at chunk+10 is an object ID; AuRg uses the u16 at +14 as a sub-index.
- **Common tags:** Song, Trak, MSeq, EvSq, AuRg, AuFl, AuCU, AuCO, Envi, TxSt, Styl, AuCn.

## Audio files (AuFl) ✅
Payload +8: u16 char count, then the UTF-16LE file name. Files live in `Media/Audio Files/`.

## Audio regions (AuRg) ✅ (2,667/2,667 regions fit inside their source files)
Payload +6: u32 source offset (samples). +22: u32 length (samples). +74: u16 name length. +76: ASCII
name. **Regions follow their AuFl in document order.**

## Arrangement placement and track names
Placement events are in EvSq streams (16-byte events, `0xF1` terminator). Type `0x24` is 80 bytes:
- +4: u32 position, in 960-PPQ ticks with bar 1 = 34,560
- +0x14: u8 arrange row number
- +0x2c: u32 AuRg header ID; use the region with sub-index zero.

Each MSeq begins a section; 58-byte Trak chunks give arrange rows in order, with an Envi ID at payload +8.
Row numbers may be reused by different channel strips across sequences; the importer distinguishes row and strip identity. The role of every sequence and take folder remains uncertain.
Envi has a u16 name length at payload +158 followed by name bytes at +160. Type `0x20` may represent MIDI.
Generated fixtures cover region IDs, leftover sub-indices, names and row order. Duplicate primary IDs are treated as ambiguous; truncated known event records cause import failure. Take folders, tempo changes,
channel volume and pan, track stacks, routing, plug-ins and automation remain undecoded.

## Controlled Logic export (2026-11-16)
A disposable Logic 12.2 project using the macOS Submarine sample and its FCPXML export both imported as one track and one clip with no missing media. Logic rendered a separate 65,536-frame audio file in the XML export, shorter than the original region, so this comparison does not establish sample-accurate placement or boundaries. The audio-only project also contains type 0x20 events: counting every such event as a MIDI region is not supported by this evidence. More controlled projects with known nonzero offsets, trims and tracks are needed.

## Record framing, split pieces and MIDI regions (2026-11-17)
Found on a Logic 12.2 project from the owner's library that imported 1 of 24 audio placements and no MIDI.
Nothing from that project is stored in this repo; the regression test uses a generated fixture.
- **Framing.** Records are 16-byte lines. A record can run past its base size (80 bytes for 0x20–0x28,
  32 for 0x60/0x90) with extra lines: fades, flex and other per-placement data. One placement ran to 40,880 bytes.
  A continuation line has the top bit of its second word set; a new record's second word is a position and doesn't.
  Assuming fixed sizes made the parser read the middle of records as types and lose every later placement.
- **Split pieces.** A placement's +0x28 (u32) is the piece of the region it plays. Pieces of a split region share
  the AuRg header id and differ in the header sub-index (+14). The pieces observed were consecutive source ranges.
  Earlier projects only used piece 0, so "use sub-index zero" was a coincidence.
- **MIDI regions.** Event 0x20 at +0x20 names an event sequence by header id. In the main arrangement sequence those are
  MIDI regions; one 0x20 per row at bar 1 in another sequence points at empty sequences (track folders), so a 0x20 is
  a MIDI region only if its sequence holds notes.
- **Notes** (record 0x90, 32 bytes): +4 position (960 PPQ, bar 1 of the region = 34,560), +11 velocity, +12 pitch,
  +28 length in ticks. Verified against Logic's own File ▸ Export ▸ All MIDI Tracks as MIDI File: 60 of 60 notes
  matched in position, pitch, velocity and length. +10 was a constant 65 and +15 varied (0x01, 0x81, 0x80), meaning
  unknown.
- **Drummer regions** hold 48-byte 0x4090 records. Logic's MIDI export leaves them out, so they're not decoded: the
  importer skips and reports them.
- The region length of a MIDI region wasn't found; clips run to the last note's end, rounded up to whole bars.
