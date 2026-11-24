// Standard MIDI Files: export a clip and import it back (notes, controllers, tempo), hand-built files, hostile bytes.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct MidiFiles {
    @Test func exportThenImportRoundTrips() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        _ = dalnok_tempo_set(e, 90, 3, 4)
        let t = dalnok_track_add_instrument(e, "Keys")
        let c = dalnok_midi_clip_add(e, t, 0, 96_000)
        let beat = 32_000 // 90 BPM at 48 kHz
        var notes = [DalnokNote(start: 0, length: Int64(beat), pitch: 60, velocity: 100),
                     DalnokNote(start: Int64(beat), length: Int64(beat / 2), pitch: 64, velocity: 70),
                     DalnokNote(start: Int64(beat) * 2, length: 1_000, pitch: 67, velocity: 127)]
        _ = dalnok_midi_clip_set_notes(e, c, &notes, 3)
        var ccs = [DalnokMidiCC(start: 0, controller: 64, value: 127), DalnokMidiCC(start: Int64(beat), controller: 128, value: 12_000)]
        _ = dalnok_midi_clip_set_controllers(e, c, &ccs, 2)
        let path = tempDir().appendingPathComponent("clip.mid").path
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_midi_file_export(e, c, path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let head = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(4)
        #expect(String(decoding: head, as: UTF8.self) == "MThd")
        // Into an empty project: it takes the file's tempo and meter, notes land on the same beats.
        let r = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(r) }
        var ids = [DalnokClipId](repeating: 0, count: 4)
        #expect(dalnok_midi_file_import(r, path, 0, 0, &ids, 4, &err, 256) == 1, "\(cstr(err))")
        #expect(abs(dalnok_tempo_bpm(r) - 90) < 1e-6)
        var num: Int32 = 0, den: Int32 = 0
        dalnok_meter(r, &num, &den)
        #expect(num == 3 && den == 4)
        var got = [DalnokNote](repeating: DalnokNote(), count: 8)
        #expect(dalnok_midi_clip_notes(r, ids[0], &got, 8) == 3)
        for (g, n) in zip(got.prefix(3), notes) {
            #expect(abs(g.start - n.start) <= 1 && abs(g.length - n.length) <= 1 && g.pitch == n.pitch && g.velocity == n.velocity, "\(g) vs \(n)")
        }
        var gotCC = [DalnokMidiCC](repeating: DalnokMidiCC(), count: 4)
        #expect(dalnok_midi_clip_controllers(r, ids[0], &gotCC, 4) == 2 && gotCC[1].controller == 128 && gotCC[1].value == 12_000 && abs(gotCC[1].start - Int64(beat)) <= 1)
        #expect(clipInfo(r, ids[0]).length == Int64(beat) * 3, "one bar of 3/4")
        #expect(undoName(r) == "Import MIDI File" && dalnok_undo(r) && dalnok_track_count(r) == 0, "one undo")
    }

    @Test func importsFormatOneWithRunningStatusIntoATrack() throws {
        // Format 1, 480 ppq: a tempo track (100 BPM), then a track with running status and a note-on velocity 0 as off.
        var b = Data("MThd".utf8) + Data([0, 0, 0, 6, 0, 1, 0, 2, 0x01, 0xE0])
        func trk(_ body: [UInt8]) -> Data { var d = Data("MTrk".utf8); let n = UInt32(body.count); d += Data([UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]); return d + Data(body) }
        b += trk([0, 0xFF, 0x51, 3, 0x09, 0x27, 0xC0, 0, 0xFF, 0x2F, 0])                  // 600,000 us = 100 BPM
        b += trk([0, 0x90, 60, 100, 0x83, 0x60, 60, 0, 0, 62, 80, 0x83, 0x60, 0x80, 62, 0, 0, 0xFF, 0x2F, 0]) // 480 ticks each
        let path = tempDir().appendingPathComponent("rs.mid")
        try b.write(to: path)
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let keys = dalnok_track_add_instrument(e, "Keys")
        var err = [CChar](repeating: 0, count: 256)
        var ids = [DalnokClipId](repeating: 0, count: 4)
        #expect(dalnok_midi_file_import(e, path.path, 96_000, keys, &ids, 4, &err, 256) == 1, "\(cstr(err))")
        #expect(abs(dalnok_tempo_bpm(e) - 100) < 1e-6, "an empty project takes 100 BPM")
        var got = [DalnokNote](repeating: DalnokNote(), count: 4)
        #expect(dalnok_midi_clip_notes(e, ids[0], &got, 4) == 2)
        #expect(clipInfo(e, ids[0]).track == keys && got[0].pitch == 60 && got[1].pitch == 62 && got[1].start - got[0].start == 28_800, "a beat at 100 BPM")
    }

    @Test func hostileBytesAreRefused() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var err = [CChar](repeating: 0, count: 256)
        for bytes in [Data("hello".utf8), Data("MThd".utf8) + Data([0, 0, 0, 6, 0, 1, 0, 1, 0x80, 0x00]) /* SMPTE */,
                      Data("MThd".utf8) + Data([0, 0, 0, 6, 0, 0, 0, 1, 0, 96]) + Data("MTrk".utf8) + Data([0xFF, 0xFF, 0xFF, 0xFF, 0])] {
            let path = tempDir().appendingPathComponent("bad.mid")
            try bytes.write(to: path)
            #expect(dalnok_midi_file_import(e, path.path, 0, 0, nil, 0, &err, 256) == 0 && !cstr(err).isEmpty)
        }
        #expect(dalnok_track_count(e) == 0)
    }
}
