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
  header in total), then the payload. The u16 at chunk+14 carries a per-type index (e.g. region number).
- **Common tags:** Song, Trak, MSeq, EvSq, AuRg, AuFl, AuCU, AuCO, Envi, TxSt, Styl, AuCn.

## Audio files (AuFl) ✅
Payload +8: u16 char count, then the UTF-16LE file name. Files live in `Media/Audio Files/`.

## Audio regions (AuRg) ✅ (2,667/2,667 regions fit inside their source files)
Payload +6: u32 source offset (samples). +22: u32 length (samples). +74: u16 name length. +76: ASCII
name. **Regions follow their AuFl in document order.**

## Arrangement placement ⚠️ decoded, not yet verified
Placement events are in EvSq streams (16-byte events, `0xF1` terminator). Type `0x24` is 80 bytes:
- +4: u32 position, in 960-PPQ ticks with bar 1 = 34,560
- +0x14: u8 track number
- +0x2c: u32 region link (region index × 4; the numbering isn't confirmed)

Type `0x20` (80 bytes) appears to be MIDI-region placement.

**Open questions:**
- Overlap statistics are ambiguous because take folders legitimately stack takes.
- How regions in take folders and comps are placed.
- Custom track names: Envi records hold channel names at payload +158, but renamed tracks need more work.
- Tempo changes.

**Next step to verify:** export one project via Logic's File ▸ Export ▸ Project to Final Cut Pro XML
and compare its clip positions with this decoder's output.

## Controlled Logic export (2026-11-16)
A disposable Logic 12.2 project using the macOS Submarine sample and its FCPXML export both imported as one track and one clip with no missing media. Logic rendered a separate 65,536-frame audio file in the XML export, shorter than the original region, so this comparison does not establish sample-accurate placement or boundaries. The audio-only project also contains type 0x20 events: counting every such event as a MIDI region is not supported by this evidence. More controlled projects with known nonzero offsets, trims and tracks are needed.
