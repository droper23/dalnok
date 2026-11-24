// Clip tools: Normalize, Reverse, Strip Silence and Join (offline renders, exact or numeric tolerances).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct ClipTools {
    /// One audio track with `x` (mono, written to a file so it can be reversed and joined) at `start`.
    func session(_ x: [Float], start: Int64 = 0) -> (OpaquePointer, DalnokTrackId, DalnokClipId, URL) {
        let dir = tempDir()
        let path = dir.appendingPathComponent("src.wav").path
        do {
            let w = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(w) }
            let m = makeMedia([x, x]); defer { dalnok_media_release(m) }
            DalnokEngine.dalnok_clip_add(w, dalnok_track_add(w, "S"), dalnok_pool_add(w, m, ""), 0, 0, 0)
            _ = dalnok_render_to_wav(w, path, 0, Int64(x.count), 32, nil, 0)
        }
        let e = dalnok_engine_create(48_000)!
        var media: OpaquePointer?
        _ = dalnok_media_load(path, 48_000, &media, nil, 0)
        let t = dalnok_track_add(e, "A")
        let c = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, media, path), start, 0, 0)
        dalnok_media_release(media)
        return (e, t, c, dir)
    }
    var err: [CChar] { [CChar](repeating: 0, count: 256) }

    @Test func normalizeSetsThePeak() {
        let x = (0..<24_000).map { Float(0.25 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let (e, _, c, _) = session(x); defer { dalnok_engine_destroy(e) }
        var er = err
        #expect(dalnok_clip_normalize(e, c, -0.1, &er, 256) == DALNOK_OK && undoName(e) == "Normalize")
        let (l, _) = render(e, frames: 24_000)
        let peak = 20 * log10(Double(l.map { abs($0) }.max()!))
        #expect(abs(peak + 0.1) < 0.01, "peak \(peak) dBFS")
    }

    @Test func reversePlaysBackwards() {
        let x = (0..<10_000).map { Float($0) / 10_000 }
        let (e, _, c, dir) = session(x, start: 1_000); defer { dalnok_engine_destroy(e) }
        var er = err
        #expect(dalnok_clip_reverse(e, c, dir.appendingPathComponent("rev.wav").path, &er, 256) == DALNOK_OK, "\(cstr(er))")
        let (l, _) = render(e, frames: 12_000)
        #expect(abs(l[1_000] - x[9_999]) < 1e-6 && abs(l[10_999] - x[0]) < 1e-6 && l[999] == 0, "\(l[1_000]) \(l[10_999])")
        #expect(dalnok_undo(e))
        #expect(abs(render(e, frames: 12_000).0[1_000] - x[0]) < 1e-6, "undo plays it forwards")
    }

    @Test func stripSilenceKeepsTheLoudParts() {
        // Sound 0-0.25 s, silence to 0.75 s, sound 0.75-1 s.
        let x = (0..<48_000).map { i -> Float in (i < 12_000 || i >= 36_000) ? Float(0.5 * sin(2 * Double.pi * 300 * Double(i) / 48_000)) : 0 }
        let (e, t, c, _) = session(x); defer { dalnok_engine_destroy(e) }
        var er = err
        var ids = [DalnokClipId](repeating: 0, count: 8)
        #expect(dalnok_clip_strip_silence(e, c, -50, 0.15, &ids, 8, &er, 256) == 2, "\(cstr(er))")
        #expect(dalnok_track_clips(e, t, nil, 0) == 2 && undoName(e) == "Strip Silence")
        let a = clipInfo(e, ids[0]), b = clipInfo(e, ids[1])
        #expect(a.start == 0 && abs(a.length - 12_000 - 2_400) <= 480, "first part \(a.start)+\(a.length)")
        #expect(abs(b.start - 36_000 + 480) <= 480 && b.start + b.length == 48_000, "second part \(b.start)+\(b.length)")
        let (l, _) = render(e, frames: 48_000)
        #expect(zip(l[1_000..<11_000], x[1_000..<11_000]).allSatisfy { abs($0 - $1) < 1e-6 }, "the kept audio is unchanged")
        #expect(dalnok_undo(e) && dalnok_track_clips(e, t, nil, 0) == 1)
    }

    @Test func joinMixesAudioAndMergesMidi() {
        let x = (0..<20_000).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / 48_000)) }
        let (e, t, c1, dir) = session(x); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_clip_set_region(e, c1, 0, 0, 8_000) == DALNOK_OK)
        var media: OpaquePointer?
        _ = dalnok_media_load(dir.appendingPathComponent("src.wav").path, 48_000, &media, nil, 0)
        let c2 = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, media, dir.appendingPathComponent("src.wav").path), 12_000, 2_000, 6_000)
        dalnok_media_release(media)
        dalnok_clip_set_gain_db(e, c2, -6)
        let (before, _) = render(e, frames: 20_000)
        var er = err
        var ids = [c1, c2]
        let j = dalnok_clips_join(e, &ids, 2, dir.appendingPathComponent("join.wav").path, &er, 256)
        #expect(j != 0 && dalnok_track_clips(e, t, nil, 0) == 1 && undoName(e) == "Join Clips", "\(cstr(er))")
        let info = clipInfo(e, j)
        #expect(info.start == 0 && info.length == 18_000)
        let (after, _) = render(e, frames: 20_000)
        #expect(zip(before, after).map { abs($0 - $1) }.max()! < 1e-5, "the joined clip sounds the same")
        // MIDI: notes of both clips in one.
        let mt = dalnok_track_add_instrument(e, nil)
        let m1 = dalnok_midi_clip_add(e, mt, 0, 24_000), m2 = dalnok_midi_clip_add(e, mt, 48_000, 24_000)
        var n1 = DalnokNote(start: 1_000, length: 500, pitch: 60, velocity: 100), n2 = DalnokNote(start: 2_000, length: 500, pitch: 64, velocity: 90)
        _ = dalnok_midi_clip_set_notes(e, m1, &n1, 1); _ = dalnok_midi_clip_set_notes(e, m2, &n2, 1)
        var mids = [m1, m2]
        let mj = dalnok_clips_join(e, &mids, 2, nil, &er, 256)
        var got = [DalnokNote](repeating: DalnokNote(), count: 4)
        #expect(mj != 0 && dalnok_midi_clip_notes(e, mj, &got, 4) == 2 && got[0].start == 1_000 && got[1].start == 50_000, "\(cstr(er))")
        #expect(clipInfo(e, mj).length == 72_000)
    }
}
