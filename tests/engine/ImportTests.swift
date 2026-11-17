// Importers for other DAWs, tested with generated fixtures (no user projects).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Imports `path`, applies it to a 48 kHz engine; returns (engine, report JSON).
func importInto(_ path: String) throws -> (OpaquePointer, [String: Any]) {
    var data: OpaquePointer?
    var report = [CChar](repeating: 0, count: 65_536), err = [CChar](repeating: 0, count: 1024)
    let st = dalnok_project_import(path, 48_000, &data, nil, &report, report.count, &err, err.count)
    guard st == DALNOK_OK else { throw EngineErr(msg: cstr(err)) }
    let e = dalnok_engine_create(48_000)!
    #expect(dalnok_project_apply(e, data) == DALNOK_OK)
    let json = try JSONSerialization.jsonObject(with: Data(cstr(report).utf8)) as! [String: Any]
    return (e, json)
}
struct EngineErr: Error { let msg: String }

func clips(_ e: OpaquePointer) -> [(track: String, info: DalnokClipInfo)] {
    var out: [(String, DalnokClipInfo)] = []
    for i in 0..<dalnok_track_count(e) {
        let t = dalnok_track_at(e, i)
        var ti = DalnokTrackInfo(); dalnok_track_info(e, t, &ti)
        for k in 0..<ti.clip_count { out.append((name(ti.name), clipInfo(e, dalnok_track_clip_at(e, t, k)))) }
    }
    return out
}
func skipped(_ r: [String: Any], _ key: String) -> Int { (r["skipped"] as? [String: Any])?[key] as? Int ?? 0 }

@Suite struct ReaperImport {
    @Test func importsTracksItemsFadesAndReportsTheRest() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try writeTestWav(dir.appendingPathComponent("Media/gtr.wav"), frames: 96_000)   // 2 s
        try writeTestWav(dir.appendingPathComponent("Media/loop.wav"), frames: 24_000)  // 0.5 s
        let rpp = """
        <REAPER_PROJECT 0.1 "7.39/win64" 1755279602
          SAMPLERATE 48000 0 0
          TEMPO 137 7 8 0
          <TRACK {A}
            NAME "Guitar Left"
            VOLPAN 0.5 -0.5 -1 -1 1
            MUTESOLO 0 1 0
            <FXCHAIN
              <VST "VST3: ReaEQ" reaeq.vst3 0 "" 0
              >
            >
            <ITEM
              POSITION 1.5
              LENGTH 1
              FADEIN 0 0.1 0 1 0 0 0
              FADEOUT 1 0.2 0 1 0 0 0
              MUTE 0 0
              VOLPAN 0.25 0 1 -1
              SOFFS 0.5 0
              PLAYRATE 1 1 0 -1 0 0.0025
              NAME gtr
              <SOURCE WAVE
                FILE "Media\\gtr.wav" 1
              >
            >
            <ITEM
              POSITION 5
              LENGTH 1
              MUTE 1 0
              <SOURCE WAVE
                FILE "Media\\gtr.wav"
              >
            >
          >
          <TRACK {B}
            NAME Loops
            VOLPAN 1 0 -1 -1 1
            MUTESOLO 1 0 0
            <ITEM
              POSITION 0
              LENGTH 1.25
              LOOP 1
              SOFFS 0 0
              <SOURCE WAVE
                FILE "Media\\loop.wav"
              >
            >
            <ITEM
              POSITION 2
              LENGTH 1
              <SOURCE MIDI
                HASDATA 1 960 QN
              >
            >
          >
        >
        """
        let path = dir.appendingPathComponent("song.rpp")
        try rpp.write(to: path, atomically: true, encoding: .utf8)
        let (e, r) = try importInto(path.path); defer { dalnok_engine_destroy(e) }
        #expect(r["app"] as? String == "REAPER")
        var numerator: Int32 = 0, denominator: Int32 = 0
        dalnok_meter(e, &numerator, &denominator)
        #expect(dalnok_tempo_bpm(e) == 137 && numerator == 7 && denominator == 8)
        #expect(skipped(r, "midiClips") == 1 && skipped(r, "mutedItems") == 1 && skipped(r, "plugins") == 1)
        #expect(dalnok_track_count(e) == 2)
        var t = DalnokTrackInfo(); dalnok_track_info(e, dalnok_track_at(e, 0), &t)
        #expect(name(t.name) == "Guitar Left" && abs(t.gain_db - -6.0206) < 0.01 && abs(t.pan + 0.5) < 1e-6 && t.solo)
        dalnok_track_info(e, dalnok_track_at(e, 1), &t)
        #expect(t.muted)
        let c = clips(e)
        let g = c.first { $0.track == "Guitar Left" }!.info
        #expect(g.start == 72_000 && g.offset == 24_000 && g.length == 48_000, "position/offset/length from seconds")
        #expect(g.fade_in == 4_800 && g.fade_out == 9_600 && abs(g.gain_db + 12.04) < 0.01)
        #expect(!g.offline, "Windows-style relative path resolved")
        let loops = c.filter { $0.track == "Loops" }.map(\.info)
        #expect(loops.count == 3 && loops.map(\.start) == [0, 24_000, 48_000] && loops.map(\.length) == [24_000, 24_000, 12_000],
                "looped item expanded: \(loops.map(\.start)) \(loops.map(\.length))")
    }

    @Test func rejectsNonReaperFiles() throws {
        let p = tempDir().appendingPathComponent("x.rpp")
        try "hello".write(to: p, atomically: true, encoding: .utf8)
        #expect(throws: EngineErr.self) { try importInto(p.path) }
    }
}

@Suite struct AbletonImport {
    @Test func preservesConstantTempo() throws {
        let dir = tempDir(), path = dir.appendingPathComponent("Tempo.als")
        let xml = "<Ableton><LiveSet><Tracks/><MainTrack><DeviceChain><Mixer><Tempo><Manual Value=\"91\"/></Tempo></Mixer></DeviceChain></MainTrack></LiveSet></Ableton>"
        try gzip(xml, to: path)
        let (e, _) = try importInto(path.path); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_tempo_bpm(e) == 91)
    }
    func gzip(_ xml: String, to url: URL) throws {
        let raw = url.deletingPathExtension().appendingPathExtension("xml")
        try xml.write(to: raw, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c", raw.path]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try data.write(to: url)
    }

    @Test func convertsBeatsToTimeAndReportsMidiAndDevices() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Samples/Recorded"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Ableton Project Info"), withIntermediateDirectories: true)
        try writeTestWav(dir.appendingPathComponent("Samples/Recorded/vox.wav"), frames: 480_000) // 10 s
        func clip(_ time: Double, _ end: Double, _ loopStart: Double, warped: Bool = false, loopOn: Bool = false, loopEnd: Double = 9) -> String {
            """
            <AudioClip Id="0" Time="\(time)"><CurrentStart Value="\(time)"/><CurrentEnd Value="\(end)"/>
              <Loop><LoopStart Value="\(loopStart)"/><LoopEnd Value="\(loopEnd)"/><StartRelative Value="0"/><LoopOn Value="\(loopOn)"/></Loop>
              <Name Value="vox"/><Disabled Value="false"/><IsWarped Value="\(warped)"/><SampleVolume Value="0.5"/>
              <Fade Value="true"/><Fades><FadeInLength Value="0.25"/><FadeOutLength Value="0"/></Fades>
              <PitchCoarse Value="0"/><PitchFine Value="0"/>
              <WarpMarkers><WarpMarker Id="0" SecTime="0" BeatTime="0"/><WarpMarker Id="1" SecTime="1" BeatTime="2"/></WarpMarkers>
              <SampleRef><FileRef><RelativePathType Value="3"/><RelativePath Value="Samples/Recorded/vox.wav"/>
                <Path Value="/old/machine/Samples/Recorded/vox.wav"/></FileRef></SampleRef>
            </AudioClip>
            """
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ableton MajorVersion="5" MinorVersion="12.0_12300" Creator="Ableton Live 12.3.5">
        <LiveSet><Tracks>
          <AudioTrack Id="1"><Name><EffectiveName Value="Vocals"/></Name>
            <DeviceChain><Mixer><Volume><Manual Value="0.5"/></Volume><Pan><Manual Value="0.25"/></Pan>
              <Speaker><Manual Value="true"/></Speaker><SoloSink Value="false"/></Mixer>
              <MainSequencer><ClipSlotList/><Sample><ArrangerAutomation><Events>
                \(clip(4, 8, 1))
                \(clip(8, 10, 0, warped: true))
                \(clip(16, 22, 2, loopOn: true, loopEnd: 3))
              </Events></ArrangerAutomation></Sample></MainSequencer>
              <DeviceChain><Devices><Eq8/><Compressor2/></Devices></DeviceChain>
            </DeviceChain></AudioTrack>
          <MidiTrack Id="2"><Name><EffectiveName Value="Keys"/></Name><DeviceChain><Mixer/>
            <MainSequencer><ClipSlotList/><ClipTimeable><ArrangerAutomation><Events><MidiClip Time="0"/><MidiClip Time="8"/></Events></ArrangerAutomation></ClipTimeable></MainSequencer>
          </DeviceChain></MidiTrack>
        </Tracks>
        <MainTrack><DeviceChain><Mixer><Tempo><Manual Value="120"/></Tempo><Volume><Manual Value="1"/></Volume></Mixer></DeviceChain></MainTrack>
        </LiveSet></Ableton>
        """
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Backup"), withIntermediateDirectories: true)
        let als = dir.appendingPathComponent("Backup/Song [2026].als") // saved in Backup/: resolves via project root
        try gzip(xml, to: als)
        let (e, r) = try importInto(als.path); defer { dalnok_engine_destroy(e) }
        #expect(r["app"] as? String == "Ableton Live")
        #expect(skipped(r, "midiClips") == 2 && skipped(r, "devicesAndPlugins") == 2 && skipped(r, "midiTracks") == 1)
        #expect(dalnok_track_count(e) == 1)
        var t = DalnokTrackInfo(); dalnok_track_info(e, dalnok_track_at(e, 0), &t)
        #expect(name(t.name) == "Vocals" && abs(t.gain_db + 6.0206) < 0.01 && abs(t.pan - 0.25) < 1e-6)
        let c = clips(e).map(\.info)
        // 120 BPM: 1 beat = 0.5 s = 24000 frames.
        #expect(c[0].start == 96_000 && c[0].length == 96_000 && c[0].offset == 48_000 && !c[0].offline,
                "unwarped: start \(c[0].start) len \(c[0].length) off \(c[0].offset)")
        #expect(abs(c[0].gain_db + 6.0206) < 0.01 && c[0].fade_in == 12_000, "clip gain and fade (seconds when unwarped)")
        #expect(c[1].start == 192_000 && c[1].offset == 0 && c[1].length == 48_000 && c[1].fade_in == 6_000,
                "warped 1:1 (2 beats per source second at 120 BPM): \(c[1].offset), fade \(c[1].fade_in) (beats)")
        let loop = c.filter { $0.start >= 384_000 }
        #expect(loop.count == 3 && loop.map(\.length) == [48_000, 48_000, 48_000] && loop.allSatisfy { $0.offset == 96_000 },
                "looped clip expanded into repeats of the 1 s loop: \(loop.map(\.length)) \(loop.map(\.offset))")
        #expect(skipped(r, "warpedClipsNeedingStretch") == 0)
    }
}

@Suite struct FcpxmlImport {
    @Test func spineAndConnectedClipsBecomeTracks() throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("drums mix.wav"), b = dir.appendingPathComponent("vox.wav")
        try writeTestWav(a, frames: 480_000); try writeTestWav(b, frames: 480_000)
        let enc = { (u: URL) in u.absoluteString }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE fcpxml>
        <fcpxml version="1.10"><resources>
          <asset id="r1" name="drums" start="0s" duration="10s" hasAudio="1"><media-rep kind="original-media" src="\(enc(a))"/></asset>
          <asset id="r2" name="vox" src="\(enc(b))" start="0s" duration="10s" hasAudio="1"/>
        </resources><library><event><project name="Song"><sequence tcStart="0s"><spine>
          <asset-clip ref="r1" offset="0s" start="48000/48000s" duration="96000/48000s" name="Drums" audioRole="music.Drums">
            <adjust-volume amount="-6dB"/>
            <asset-clip ref="r2" lane="-1" offset="3s" start="2s" duration="1s" name="Vox" audioRole="dialogue.Vox"/>
          </asset-clip>
          <gap offset="2s" start="0s" duration="1s"/>
          <asset-clip ref="r1" offset="3s" start="0s" duration="1s" name="Drums 2" audioRole="music.Drums"/>
        </spine></sequence></project></event></library></fcpxml>
        """
        let path = dir.appendingPathComponent("Song.fcpxml")
        try xml.write(to: path, atomically: true, encoding: .utf8)
        let (e, r) = try importInto(path.path); defer { dalnok_engine_destroy(e) }
        #expect(r["app"] as? String == "Final Cut Pro XML" && dalnok_track_count(e) == 2)
        let c = clips(e)
        let drums = c.filter { $0.track == "Drums" }.map(\.info)
        #expect(drums.count == 2 && drums[0].start == 0 && drums[0].offset == 48_000 && drums[0].length == 96_000)
        #expect(abs(drums[0].gain_db + 6) < 1e-4 && drums[1].start == 144_000)
        let vox = c.first { $0.track == "Vox" }!.info
        // Connected clip: parent starts at timeline 0 with source start 1 s; offset 3 s in parent time = timeline 2 s.
        #expect(vox.start == 96_000 && vox.offset == 96_000 && vox.length == 48_000, "connected clip timing: \(vox.start)")
    }
}

@Suite struct StemsImport {
    @Test func folderOfStemsAlignsAtZeroAndStripsCommonPrefix() throws {
        let dir = tempDir()
        for n in ["Song#01 Kick", "Song#02 Bass", "Song#03 Vox"] { try writeTestWav(dir.appendingPathComponent("\(n).wav"), frames: 4_800) }
        try "not audio".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let (e, _) = try importInto(dir.path); defer { dalnok_engine_destroy(e) }
        let c = clips(e)
        #expect(c.map(\.track) == ["01 Kick", "02 Bass", "03 Vox"], "\(c.map(\.track))")
        #expect(c.allSatisfy { $0.info.start == 0 && $0.info.length == 4_800 })
    }
}

@Suite struct LogicImport {
    /// Builds a minimal ProjectData in the layout decoded from Logic 12.2 projects.
    /// `id` lands at chunk offset +10 and `sub` at +14 (region id / leftover sub-index in AuRg headers).
    func chunk(_ tag: String, _ payload: Data, id: UInt32 = 0, sub: UInt16 = 0) -> Data {
        var d = Data(tag.reversed().map { UInt8($0.asciiValue!) })
        var hdr = [UInt8](repeating: 0, count: 24) // tag(4) + 24 header bytes + u64 length = 36
        hdr.replaceSubrange(6..<10, with: le(id)); hdr.replaceSubrange(10..<12, with: le(sub))
        d.append(contentsOf: hdr)
        d.append(contentsOf: le(UInt64(payload.count)))
        d.append(payload)
        return d
    }
    func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    @Test func parsesFilesRegionsAndPlacements() throws {
        let pkg = tempDir().appendingPathComponent("Song.logicx")
        let alt = pkg.appendingPathComponent("Alternatives/000"), media = pkg.appendingPathComponent("Media/Audio Files")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try writeTestWav(media.appendingPathComponent("Take 🎵.wav"), frames: 480_000)
        // AuFl: 8 bytes, then UTF-16LE name with u16 char count.
        var fl = Data(repeating: 0, count: 8); let nm = "Take 🎵.wav"
        fl.append(contentsOf: le(UInt16(nm.utf16.count))); for u in nm.utf16 { fl.append(contentsOf: le(u)) }
        // AuRg: offset @6, length @22, name length @74, name @76.
        var rg = Data(repeating: 0, count: 120)
        rg.replaceSubrange(6..<10, with: le(UInt32(24_000))); rg.replaceSubrange(22..<26, with: le(UInt32(96_000)))
        let rn = "Take 1.1"; rg.replaceSubrange(74..<76, with: le(UInt16(rn.count)))
        rg.replaceSubrange(76..<(76 + rn.count), with: Array(rn.utf8))
        // EvSq: one 0x24 placement at bar 3 (34560 + 2 bars * 3840 ticks), track 2, region 0; then 0xF1 end.
        var ev = Data(repeating: 0, count: 80)
        ev.replaceSubrange(0..<4, with: le(UInt32(0x24))); ev.replaceSubrange(4..<8, with: le(UInt32(34_560 + 7_680)))
        ev[0x14] = 2; ev.replaceSubrange(0x2c..<0x30, with: le(UInt32(0)))
        var end = Data(repeating: 0, count: 16); end[0] = 0xf1
        ev.append(end)
        var body = chunk("Song", Data(repeating: 0, count: 8))
        body.append(chunk("AuFl", fl)); body.append(chunk("AuRg", rg)); body.append(chunk("EvSq", ev))
        // An event before the first MSeq must not borrow that later sequence's row names.
        var en = Data(repeating: 0, count: 170)
        en.replaceSubrange(158..<160, with: le(UInt16(5))); en.replaceSubrange(160..<165, with: Array("Later".utf8))
        body.append(chunk("Envi", en, id: 7)); body.append(chunk("MSeq", Data(repeating: 0, count: 8)))
        for _ in 0..<2 {
            var tk = Data(repeating: 0, count: 58); tk.replaceSubrange(8..<12, with: le(UInt32(7)))
            body.append(chunk("Trak", tk))
        }
        var file = Data([0x23, 0x47, 0xc0, 0xab]); file.append(Data(repeating: 0, count: 12))
        file.append(contentsOf: le(UInt64(body.count))); file.append(body)
        try file.write(to: alt.appendingPathComponent("ProjectData"))
        let plist = ["BeatsPerMinute": 90, "SampleRate": 48_000, "SongKey": "A", "SongGenderKey": "minor",
                     "SongSignatureNumerator": 3, "SongSignatureDenominator": 8] as [String: Any]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: alt.appendingPathComponent("MetaData.plist"))

        let (e, r) = try importInto(pkg.path); defer { dalnok_engine_destroy(e) }
        #expect(r["app"] as? String == "Logic Pro")
        var num: Int32 = 0, den: Int32 = 0
        dalnok_meter(e, &num, &den)
        #expect(dalnok_tempo_bpm(e) == 90 && num == 3 && den == 8)
        #expect((r["notes"] as? [String])?.first?.contains("key A minor") == true)
        let c = clips(e).map(\.info)
        #expect(clips(e).first?.track == "Audio 2")
        // 7680 quarter-note ticks at 90 BPM = 256000 frames.
        #expect(c.count == 1 && c[0].start == 256_000 && c[0].offset == 24_000 && c[0].length == 96_000 && !c[0].offline,
                "\(c.map { ($0.start, $0.offset, $0.length) })")
    }

    /// Placements link to the region's header id, not its document position: a leftover split region
    /// (same id, sub-index 1) sits between real regions.
    @Test func linksPlacementsByRegionIdNotOrder() throws {
        let pkg = tempDir().appendingPathComponent("Split.logicx")
        let alt = pkg.appendingPathComponent("Alternatives/000"), media = pkg.appendingPathComponent("Media/Audio Files")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var body = chunk("Song", Data(repeating: 0, count: 8))
        func region(_ name: String, offset: UInt32, length: UInt32) -> Data {
            var rg = Data(repeating: 0, count: 120)
            rg.replaceSubrange(6..<10, with: le(offset)); rg.replaceSubrange(22..<26, with: le(length))
            rg.replaceSubrange(74..<76, with: le(UInt16(name.count))); rg.replaceSubrange(76..<(76 + name.count), with: Array(name.utf8))
            return rg
        }
        for (file, frames) in [("A.wav", 480_000), ("B.wav", 240_000)] {
            try writeTestWav(media.appendingPathComponent(file), frames: frames)
            var fl = Data(repeating: 0, count: 8)
            fl.append(contentsOf: le(UInt16(file.utf16.count))); for u in file.utf16 { fl.append(contentsOf: le(u)) }
            body.append(chunk("AuFl", fl))
            if file == "A.wav" {
                body.append(chunk("AuRg", region("A", offset: 0, length: 300_000), id: 0))
                body.append(chunk("AuRg", region("A.1", offset: 300_000, length: 180_000), id: 0, sub: 1)) // leftover
            } else {
                body.append(chunk("AuRg", region("B", offset: 1_000, length: 200_000), id: 4))
            }
        }
        // Mixer section: channel strips (Envi: id in the header, u16 name length @158, name @160).
        for (id, name) in [(88, "Lead"), (92, "Rhythm"), (96, "Stack")] as [(UInt32, String)] {
            var en = Data(repeating: 0, count: 200)
            en.replaceSubrange(158..<160, with: le(UInt16(name.utf8.count))); en.replaceSubrange(160..<(160 + name.utf8.count), with: Array(name.utf8))
            body.append(chunk("Envi", en, id: id))
        }
        // Arrange section: MSeq, then one 58-byte Trak per row pointing at its channel strip (@8).
        body.append(chunk("MSeq", Data(repeating: 0, count: 8)))
        for strip in [96, 88, 92, 92] as [UInt32] { // rows 1-4: a stack, then tracks
            var tk = Data(repeating: 0, count: 58); tk.replaceSubrange(8..<12, with: le(strip))
            body.append(chunk("Trak", tk))
        }
        var ev = Data()
        // Stored in time order: row 4 ("Rhythm") plays first, row 2 ("Lead") second.
        for (bars, track, link) in [(0, 4, 0), (4, 2, 4), (8, 2, 4)] as [(UInt32, UInt8, UInt32)] {
            var e = Data(repeating: 0, count: 80)
            e.replaceSubrange(0..<4, with: le(UInt32(0x24))); e.replaceSubrange(4..<8, with: le(UInt32(34_560) + bars * 3_840))
            e[0x14] = track; e.replaceSubrange(0x2c..<0x30, with: le(link))
            ev.append(e)
        }
        var end = Data(repeating: 0, count: 16); end[0] = 0xf1
        ev.append(end)
        body.append(chunk("EvSq", ev))
        // Another sequence reuses row 2 for a different strip, while row 4 still means Rhythm.
        body.append(chunk("MSeq", Data(repeating: 0, count: 8)))
        for strip in [96, 96, 92, 92] as [UInt32] {
            var tk = Data(repeating: 0, count: 58); tk.replaceSubrange(8..<12, with: le(strip))
            body.append(chunk("Trak", tk))
        }
        var ev2 = Data()
        for track in [UInt8(2), UInt8(4)] {
            var e = Data(repeating: 0, count: 80)
            e.replaceSubrange(0..<4, with: le(UInt32(0x24))); e.replaceSubrange(4..<8, with: le(UInt32(34_560 + 12 * 3_840)))
            e[0x14] = track; e.replaceSubrange(0x2c..<0x30, with: le(UInt32(4)))
            ev2.append(e)
        }
        ev2.append(end); body.append(chunk("EvSq", ev2))
        var file = Data([0x23, 0x47, 0xc0, 0xab]); file.append(Data(repeating: 0, count: 12))
        file.append(contentsOf: le(UInt64(body.count))); file.append(body)
        try file.write(to: alt.appendingPathComponent("ProjectData"))
        try PropertyListSerialization.data(fromPropertyList: ["BeatsPerMinute": 120, "SampleRate": 48_000] as [String: Any],
                                           format: .binary, options: 0).write(to: alt.appendingPathComponent("MetaData.plist"))

        let (e, r) = try importInto(pkg.path); defer { dalnok_engine_destroy(e) }
        let c = clips(e).map(\.info).sorted { $0.start < $1.start }
        // Tracks follow Logic's rows (row 2 "Lead" before row 4 "Rhythm") and take the channel strip names.
        var names: [String] = []
        for i in 0..<dalnok_track_count(e) {
            var t = DalnokTrackInfo(); dalnok_track_info(e, dalnok_track_at(e, i), &t); names.append(name(t.name))
        }
        #expect(names == ["Lead", "Stack", "Rhythm"], "\(names)")
        #expect(clips(e).filter { $0.info.start == 1_152_000 }.map(\.track).sorted() == ["Rhythm", "Stack"])
        // Link 4 is region "B" (offset 1000, length 200000) at bar 5 = 8 s at 120 BPM; document index 1 would be "A.1".
        #expect(c.count == 5 && c[0].start == 0 && c[0].offset == 0 && c[0].length == 300_000 &&
                c[1].start == 384_000 && c[1].offset == 1_000 && c[1].length == 200_000 &&
                c[2].start == 768_000 && c[2].offset == 1_000 && c[2].length == 200_000,
                "\(c.map { ($0.start, $0.offset, $0.length) })")
        #expect((r["skipped"] as? [String: Any])?["unplacedRegions"] as? Int == 1)
        // Duplicate primary IDs are ambiguous: neither region may be chosen silently.
        body.append(chunk("AuRg", region("Duplicate", offset: 0, length: 48_000), id: 4))
        var ambiguousFile = Data([0x23, 0x47, 0xc0, 0xab]); ambiguousFile.append(Data(repeating: 0, count: 12))
        ambiguousFile.append(contentsOf: le(UInt64(body.count))); ambiguousFile.append(body)
        try ambiguousFile.write(to: alt.appendingPathComponent("ProjectData"))
        let (ambiguous, report) = try importInto(pkg.path); defer { dalnok_engine_destroy(ambiguous) }
        #expect(clips(ambiguous).count == 1 && skipped(report, "ambiguousRegionIds") == 1 &&
                skipped(report, "unresolvedPlacements") == 4)
    }

    @Test func rejectsInvalidChunkAndNameLengths() throws {
        let alt = tempDir().appendingPathComponent("Bad.logicx/Alternatives/000")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        let project = alt.deletingLastPathComponent().deletingLastPathComponent()
        func checkInvalid(_ body: Data) throws {
            var file = Data([0x23, 0x47, 0xc0, 0xab])
            file.append(Data(repeating: 0, count: 12))
            file.append(contentsOf: le(UInt64(body.count)))
            file.append(body)
            try file.write(to: alt.appendingPathComponent("ProjectData"))
            #expect(throws: (any Error).self) { try importInto(project.path) }
        }
        var oversized = chunk("Song", Data())
        oversized.replaceSubrange(28..<36, with: le(UInt64.max))
        try checkInvalid(oversized)
        var name = Data(repeating: 0, count: 11)
        name.replaceSubrange(8..<10, with: le(UInt16(100)))
        try checkInvalid(chunk("AuFl", name))
        var region = Data(repeating: 0, count: 77)
        region.replaceSubrange(74..<76, with: le(UInt16(100)))
        try checkInvalid(chunk("AuRg", region))
        var event = Data(repeating: 0, count: 16)
        event.replaceSubrange(0..<4, with: le(UInt32(0x24)))
        try checkInvalid(chunk("EvSq", event))
    }

    @Test func corruptDataFailsWithGuidance() throws {
        let pkg = tempDir().appendingPathComponent("Bad.logicx/Alternatives/000")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        var bad = Data([0x23, 0x47, 0xc0, 0xab]); bad.append(Data(repeating: 0xEE, count: 100))
        try bad.write(to: pkg.appendingPathComponent("ProjectData"))
        #expect { try importInto(pkg.deletingLastPathComponent().deletingLastPathComponent().path) } throws: {
            ($0 as? EngineErr)?.msg.contains("Final Cut Pro XML") == true
        }
    }
}

@Suite struct MediaRelocation {
    @Test func movedArchiveIsFoundBySharedPathTail() throws {
        let root = tempDir()
        let moved = root.appendingPathComponent("Archive/Zene/ABLETON/Wait Project")
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("Samples/Recorded"), withIntermediateDirectories: true)
        try writeTestWav(moved.appendingPathComponent("Samples/Recorded/gtr.wav"), frames: 4_800)
        let rpp = """
        <REAPER_PROJECT 0.1 "7.0/macOS"
          <TRACK
            <ITEM
              POSITION 0
              LENGTH 0.1
              <SOURCE WAVE
                FILE "/Users/someone-else/Downloads/Zene/ABLETON/Wait Project/Samples/Recorded/gtr.wav"
              >
            >
          >
        >
        """
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("Backup"), withIntermediateDirectories: true)
        let path = moved.appendingPathComponent("Backup/p.rpp")
        try rpp.write(to: path, atomically: true, encoding: .utf8)
        let (e, r) = try importInto(path.path); defer { dalnok_engine_destroy(e) }
        #expect((r["imported"] as? [String: Any])?["missingMedia"] as? Int == 0)
        #expect(!clips(e)[0].info.offline)
    }

    @Test func offlineMediaKeepsClipLengths() throws {
        let dir = tempDir()
        let rpp = """
        <REAPER_PROJECT 0.1 "7.0/macOS"
          <TRACK
            <ITEM
              POSITION 2
              LENGTH 3.5
              SOFFS 1
              <SOURCE WAVE
                FILE "gone.wav"
              >
            >
          >
        >
        """
        let path = dir.appendingPathComponent("p.rpp")
        try rpp.write(to: path, atomically: true, encoding: .utf8)
        let (e, _) = try importInto(path.path); defer { dalnok_engine_destroy(e) }
        let c = clips(e)[0].info
        #expect(c.offline && c.start == 96_000 && c.length == 168_000 && c.offset == 48_000, "length kept: \(c.length)")
    }
}
