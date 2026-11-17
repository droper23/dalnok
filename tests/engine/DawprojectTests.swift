// DAWproject export and import: a generated project round-trips its arrangement and mixer.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct Dawproject {
    @Test func exportsAndImportsTheArrangementAndMixer() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        let url = dir.appendingPathComponent("gtr.wav")
        _ = try writeTestWav(url, frames: 96_000)
        var media: OpaquePointer?
        #expect(dalnok_media_load(url.path, 48_000, &media, nil, 0) == DALNOK_OK)
        let m = dalnok_pool_add(e, media, url.path); dalnok_media_release(media)
        let gtr = dalnok_track_add(e, "Guitar")
        #expect(dalnok_track_set_gain_db(e, gtr, -6) == DALNOK_OK && dalnok_track_set_pan(e, gtr, -0.5) == DALNOK_OK)
        let a = dalnok_clip_add(e, gtr, m, 24_000, 12_000, 48_000)
        #expect(dalnok_clip_set_fades(e, a, 4_800, 2_400, DALNOK_FADE_LINEAR) == DALNOK_OK)
        let b = dalnok_clip_add(e, gtr, m, 120_000, 0, 40_000)
        #expect(dalnok_clip_set_stretch(e, b, 80_000, 0.5, 0, true) == DALNOK_OK) // 40,000 source frames over 80,000
        let bus = dalnok_track_add_bus(e, "Verb")
        #expect(dalnok_track_set_output(e, gtr, bus) == DALNOK_OK)
        let keys = dalnok_track_add_instrument(e, "Keys")
        _ = dalnok_midi_clip_add(e, keys, 0, 96_000)

        let out = dir.appendingPathComponent("song.dawproject")
        var notes = [CChar](repeating: 0, count: 4096), err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_project_export_dawproject(e, out.path, &notes, notes.count, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        // A real ZIP that the system unzip lists, with the project, metadata and the audio.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-l", out.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0 && listing.contains("project.xml") && listing.contains("metadata.xml") && listing.contains("audio/gtr.wav"), "\(listing)")
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); t.arguments = ["-tq", out.path]
        try t.run(); t.waitUntilExit()
        #expect(t.terminationStatus == 0, "CRCs check out")

        let (e2, report) = try importInto(out.path); defer { dalnok_engine_destroy(e2) }
        #expect((report["app"] as? String) == "DAWproject from Dalnok")
        let all = clips(e2)
        let guitar = all.filter { $0.track == "Guitar" }.map(\.info).sorted { $0.start < $1.start }
        #expect(guitar.count == 2, "\(all.map { ($0.track, $0.info.start, $0.info.length) }) \(report)")
        if guitar.count == 2 {
            #expect(guitar[0].start == 24_000 && guitar[0].offset == 12_000 && guitar[0].length == 48_000, "\(guitar[0])")
            #expect(guitar[0].fade_in == 4_800 && guitar[0].fade_out == 2_400)
            #expect(guitar[1].start == 120_000 && guitar[1].length == 80_000 && abs(guitar[1].rate - 0.5) < 1e-9, "\(guitar[1])")
        }
        var ti = DalnokTrackInfo()
        let g2 = (0..<dalnok_track_count(e2)).map { dalnok_track_at(e2, $0) }.first { var i = DalnokTrackInfo(); dalnok_track_info(e2, $0, &i); return name(i.name) == "Guitar" }
        #expect(g2 != nil && dalnok_track_info(e2, g2!, &ti) == DALNOK_OK && abs(ti.gain_db + 6) < 1e-3 && abs(ti.pan + 0.5) < 1e-6)
        #expect(skipped(report, "midiClips") == 1 && skipped(report, "groupTracks") == 1, "\(report)")
        // Sample-exact audio: the first clip's region renders identically after the round trip.
        _ = dalnok_track_set_output(e, gtr, 0)
        for (eng, id) in [(e, gtr), (e2, g2!)] { _ = dalnok_track_set_gain_db(eng, id, 0); _ = dalnok_track_set_pan(eng, id, 0) }
        #expect(dalnok_track_set_mute(e, keys, true) == DALNOK_OK)
        let x = renderStereo(e, 80_000), y = renderStereo(e2, 80_000)
        #expect(zip(x.0, y.0).allSatisfy { abs($0 - $1) < 1e-5 }, "same audio in the first 80,000 frames")
    }
}
